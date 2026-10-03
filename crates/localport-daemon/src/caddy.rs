use crate::router::Router;
use anyhow::{Context, Result};
use localport_core::config::GlobalConfig;
use serde::Serialize;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use tokio::process::{Child, Command};
use tokio::sync::{watch, RwLock};
use tokio::time::{Duration, Instant};

/// Caddy release downloaded when no binary is installed. Pinned (with
/// checksums from the release's `caddy_<ver>_checksums.txt`) so the daemon
/// never executes an unverified download.
const CADDY_VERSION: &str = "2.11.4";
const CADDY_SHA512_ARM64: &str = "3190ae0df98b59ab4b6021556fa35adc3c526a4f3e138776b0eaec8a037cc26121cbbb1ad53453f565551b47d37d5ba4755e2c2c3652256737fe2ce9e53c8ec0";
const CADDY_SHA512_AMD64: &str = "e04eb10f9ce7e2e079bc9bff1bd5d3a3164888d1edbb1a49e5d15be4eab691b57e89ed36bb29c65ba43f1ba8d9279e0967b1003991c13fe4cb78384c3caf25de";

/// Rotate a log file once it grows past this size.
const MAX_LOG_BYTES: u64 = 10 * 1024 * 1024;

/// What the proxy is doing, reported to the app via `daemon.status`.
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(tag = "state", content = "error", rename_all = "lowercase")]
pub enum ProxyStatus {
    Starting,
    Downloading,
    Running,
    Failed(String),
    Stopped,
}

/// Owns the Caddy reverse proxy: downloads it if needed, keeps it running
/// (restarting with backoff if it exits), and reloads it on route changes.
pub struct CaddyManager {
    config: GlobalConfig,
    router: Arc<RwLock<Router>>,
    caddy_bin: Mutex<String>,
    status: Mutex<ProxyStatus>,
    /// Serializes Caddyfile writes + reloads.
    reload_lock: tokio::sync::Mutex<()>,
}

impl CaddyManager {
    pub fn new(config: GlobalConfig, router: Arc<RwLock<Router>>) -> Self {
        let caddy_bin = config.resolve_caddy_bin();
        Self {
            config,
            router,
            caddy_bin: Mutex::new(caddy_bin),
            status: Mutex::new(ProxyStatus::Starting),
            reload_lock: tokio::sync::Mutex::new(()),
        }
    }

    pub fn status(&self) -> ProxyStatus {
        self.status.lock().unwrap().clone()
    }

    fn set_status(&self, status: ProxyStatus) {
        *self.status.lock().unwrap() = status;
    }

    fn bin(&self) -> String {
        self.caddy_bin.lock().unwrap().clone()
    }

    fn admin_address(&self) -> String {
        format!("localhost:{}", self.config.caddy.admin_port)
    }

    /// Run Caddy until shutdown, restarting it with exponential backoff
    /// whenever it fails to start or exits unexpectedly.
    pub async fn supervise(self: Arc<Self>, mut shutdown: watch::Receiver<bool>) {
        let mut backoff = Duration::from_secs(1);
        loop {
            if *shutdown.borrow() {
                break;
            }
            match self.spawn().await {
                Ok(mut child) => {
                    self.set_status(ProxyStatus::Running);
                    let started = Instant::now();
                    tokio::select! {
                        status = child.wait() => {
                            let msg = match status {
                                Ok(s) => format!("caddy exited ({s})"),
                                Err(e) => format!("caddy wait failed: {e}"),
                            };
                            tracing::error!("{msg} — see {}", caddy_log_path().display());
                            self.set_status(ProxyStatus::Failed(format!(
                                "{msg}; see {}",
                                caddy_log_path().display()
                            )));
                            if started.elapsed() > Duration::from_secs(30) {
                                backoff = Duration::from_secs(1);
                            }
                        }
                        _ = shutdown.changed() => {
                            stop_child(&mut child).await;
                            break;
                        }
                    }
                }
                Err(e) => {
                    tracing::error!("failed to start caddy: {e:#}");
                    self.set_status(ProxyStatus::Failed(format!("{e:#}")));
                }
            }

            tokio::select! {
                _ = tokio::time::sleep(backoff) => {}
                _ = shutdown.changed() => break,
            }
            backoff = (backoff * 2).min(Duration::from_secs(30));
        }
        self.set_status(ProxyStatus::Stopped);
    }

    /// Ensure the binary exists, write the Caddyfile and start Caddy.
    async fn spawn(&self) -> Result<Child> {
        self.set_status(ProxyStatus::Starting);
        if !caddy_works(&self.bin()).await {
            tracing::info!("caddy not found, downloading v{CADDY_VERSION}...");
            self.set_status(ProxyStatus::Downloading);
            download_caddy().await?;
            *self.caddy_bin.lock().unwrap() = self.config.resolve_caddy_bin();
            self.set_status(ProxyStatus::Starting);
        }

        {
            let _guard = self.reload_lock.lock().await;
            self.write_caddyfile().await?;
        }

        // A Caddy orphaned by a crashed daemon would still hold our ports.
        // Our admin port is LocalPort-specific, so ask whatever is there to stop.
        let _ = Command::new(self.bin())
            .args(["stop", "--address", &self.admin_address()])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .await;

        let log = open_log(&caddy_log_path())?;
        let caddyfile_path = self.config.caddyfile_path();
        let child = Command::new(self.bin())
            .args(["run", "--adapter", "caddyfile", "--config"])
            .arg(&caddyfile_path)
            // Never inside a project directory, so the port watcher can't
            // attribute Caddy's own listeners to a project.
            .current_dir(GlobalConfig::config_dir())
            .stdout(log.try_clone()?)
            .stderr(log)
            .kill_on_drop(true)
            .spawn()
            .context("failed to spawn caddy")?;

        tracing::info!("caddy started (pid {})", child.id().unwrap_or(0));
        Ok(child)
    }

    /// Rewrite the Caddyfile from current routes and reload Caddy.
    pub async fn reload(&self) -> Result<()> {
        let _guard = self.reload_lock.lock().await;
        self.write_caddyfile().await?;

        // Not running: the next (re)start reads the file we just wrote.
        if self.status() != ProxyStatus::Running {
            return Ok(());
        }

        let output = Command::new(self.bin())
            .args([
                "reload",
                "--adapter",
                "caddyfile",
                "--address",
                &self.admin_address(),
                "--config",
            ])
            .arg(self.config.caddyfile_path())
            .output()
            .await?;

        if !output.status.success() {
            anyhow::bail!(
                "caddy reload exited with {}: {}",
                output.status,
                String::from_utf8_lossy(&output.stderr).trim()
            );
        }
        tracing::debug!("caddy reloaded");
        Ok(())
    }

    async fn write_caddyfile(&self) -> Result<()> {
        let routes = self.router.read().await.list_routes();
        let content = self.generate_caddyfile(&routes);

        std::fs::create_dir_all(GlobalConfig::config_dir())?;
        std::fs::create_dir_all(GlobalConfig::caddy_data_dir())?;

        // Write-then-rename so Caddy never reads a half-written file.
        let path = self.config.caddyfile_path();
        let tmp = path.with_extension("tmp");
        std::fs::write(&tmp, &content)?;
        std::fs::rename(&tmp, &path)?;
        tracing::debug!("wrote Caddyfile with {} route(s)", routes.len());
        Ok(())
    }

    pub(crate) fn generate_caddyfile(&self, routes: &[(String, std::net::SocketAddr)]) -> String {
        let caddy = &self.config.caddy;
        let localhost = self.config.tld == localport_core::validation::LOCALHOST_TLD;
        let mut cf = String::from("{\n");
        cf.push_str(&format!("\tadmin {}\n", self.admin_address()));
        cf.push_str(&format!("\thttp_port {}\n", caddy.http_port));
        if !localhost {
            cf.push_str(&format!("\thttps_port {}\n", caddy.https_port));
        }
        let storage = GlobalConfig::caddy_data_dir()
            .to_string_lossy()
            .into_owned();
        cf.push_str(&format!(
            "\tstorage file_system \"{}\"\n",
            storage.replace('\\', "\\\\").replace('"', "\\\"")
        ));
        // The app installs trust itself (Caddy can't prompt for a password).
        cf.push_str("\tskip_install_trust\n");
        if !localhost {
            // Declaring the CA makes Caddy create its root at startup rather
            // than on the first certificate, so the app can trust it right
            // away — before any project is running.
            cf.push_str(
                "\tpki {\n\t\tca local {\n\t\t\tname \"LocalPort Local Authority\"\n\t\t}\n\t}\n",
            );
        }
        cf.push_str("}\n\n");

        for (hostname, addr) in routes {
            if localhost {
                cf.push_str(&format!(
                    "http://{hostname} {{\n\treverse_proxy {addr}\n}}\n\n"
                ));
            } else {
                cf.push_str(&format!(
                    "{hostname} {{\n\treverse_proxy {addr}\n\ttls internal\n}}\n\n"
                ));
            }
        }

        cf
    }
}

/// SIGTERM Caddy, then SIGKILL if it hasn't exited within 5 seconds.
async fn stop_child(child: &mut Child) {
    let Some(pid) = child.id() else { return };
    tracing::info!("stopping caddy (pid {pid})");
    // SAFETY: kill() is a standard POSIX signal call on our own child's pid.
    unsafe {
        libc::kill(pid as i32, libc::SIGTERM);
    }
    match tokio::time::timeout(Duration::from_secs(5), child.wait()).await {
        Ok(Ok(status)) => tracing::info!("caddy exited with {status}"),
        Ok(Err(e)) => tracing::warn!("error waiting for caddy: {e}"),
        Err(_) => {
            tracing::warn!("caddy didn't exit, sending SIGKILL");
            let _ = child.kill().await;
        }
    }
}

async fn caddy_works(bin: &str) -> bool {
    Command::new(bin)
        .arg("version")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .await
        .is_ok_and(|s| s.success())
}

pub fn caddy_log_path() -> PathBuf {
    GlobalConfig::log_dir().join("caddy.log")
}

/// Open a log file for appending, rotating it to `<name>.1` if it's too big.
fn open_log(path: &Path) -> Result<std::fs::File> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    if std::fs::metadata(path).is_ok_and(|m| m.len() > MAX_LOG_BYTES) {
        let _ = std::fs::rename(path, path.with_extension("log.1"));
    }
    std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .with_context(|| format!("failed to open {}", path.display()))
}

/// Download the pinned Caddy release to ~/.config/localport/bin/caddy,
/// verifying its SHA-512 before installing it.
async fn download_caddy() -> Result<()> {
    let (arch, expected) = if cfg!(target_arch = "aarch64") {
        ("arm64", CADDY_SHA512_ARM64)
    } else {
        ("amd64", CADDY_SHA512_AMD64)
    };
    let url = format!(
        "https://github.com/caddyserver/caddy/releases/download/v{CADDY_VERSION}/caddy_{CADDY_VERSION}_mac_{arch}.tar.gz"
    );

    let bin_dir = GlobalConfig::config_dir().join("bin");
    std::fs::create_dir_all(&bin_dir)?;
    let archive = bin_dir.join("caddy.tar.gz");
    let extract_dir = bin_dir.join("caddy-extract");
    let cleanup = || {
        let _ = std::fs::remove_file(&archive);
        let _ = std::fs::remove_dir_all(&extract_dir);
    };

    tracing::info!("downloading caddy from {url}");
    let status = Command::new("curl")
        .args(["-fsSL", "--retry", "3", "-o"])
        .arg(&archive)
        .arg(&url)
        .status()
        .await?;
    if !status.success() {
        cleanup();
        anyhow::bail!("failed to download caddy (curl exited with {status})");
    }

    let output = Command::new("shasum")
        .args(["-a", "512"])
        .arg(&archive)
        .output()
        .await?;
    let actual = String::from_utf8_lossy(&output.stdout);
    let actual = actual.split_whitespace().next().unwrap_or("");
    if actual != expected {
        cleanup();
        anyhow::bail!("caddy download checksum mismatch (expected {expected}, got {actual})");
    }

    let _ = std::fs::remove_dir_all(&extract_dir);
    std::fs::create_dir_all(&extract_dir)?;
    let status = Command::new("tar")
        .arg("-xzf")
        .arg(&archive)
        .arg("-C")
        .arg(&extract_dir)
        .arg("caddy")
        .status()
        .await?;
    if !status.success() {
        cleanup();
        anyhow::bail!("failed to extract caddy archive (tar exited with {status})");
    }

    let bin_path = GlobalConfig::caddy_bin_path();
    std::fs::rename(extract_dir.join("caddy"), &bin_path)?;
    cleanup();

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&bin_path, std::fs::Permissions::from_mode(0o755))?;
    }

    let output = Command::new(&bin_path).arg("version").output().await?;
    if !output.status.success() {
        let _ = std::fs::remove_file(&bin_path);
        anyhow::bail!("downloaded caddy binary failed version check");
    }
    tracing::info!(
        "caddy installed: {}",
        String::from_utf8_lossy(&output.stdout).trim()
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::SocketAddr;
    use tokio::sync::Notify;

    fn make_manager(tld: &str) -> CaddyManager {
        let router = Arc::new(RwLock::new(Router::new(Arc::new(Notify::new()))));
        let config = GlobalConfig {
            tld: tld.to_string(),
            ..Default::default()
        };
        CaddyManager::new(config, router)
    }

    #[test]
    fn test_generate_caddyfile_test_tld_empty() {
        let cf = make_manager("test").generate_caddyfile(&[]);

        assert!(cf.contains("admin localhost:47019"));
        assert!(cf.contains("http_port 47080"));
        assert!(cf.contains("https_port 47443"));
        assert!(cf.contains("skip_install_trust"));
        assert!(cf.contains("storage file_system"));
        assert!(cf.contains("ca local"));
        assert!(!cf.contains("reverse_proxy"));
    }

    #[test]
    fn test_generate_caddyfile_test_tld_with_routes() {
        let addr: SocketAddr = "127.0.0.1:3000".parse().unwrap();
        let cf = make_manager("test").generate_caddyfile(&[("myapp.test".to_string(), addr)]);

        assert!(cf.contains("myapp.test {"));
        assert!(cf.contains("reverse_proxy 127.0.0.1:3000"));
        assert!(cf.contains("tls internal"));
    }

    #[test]
    fn test_generate_caddyfile_ipv6_upstream() {
        let addr: SocketAddr = "[::1]:5173".parse().unwrap();
        let cf = make_manager("test").generate_caddyfile(&[("web.test".to_string(), addr)]);
        assert!(cf.contains("reverse_proxy [::1]:5173"));
    }

    #[test]
    fn test_generate_caddyfile_localhost_tld() {
        let addr: SocketAddr = "127.0.0.1:3000".parse().unwrap();
        let cf =
            make_manager("localhost").generate_caddyfile(&[("myapp.localhost".to_string(), addr)]);

        assert!(cf.contains("http://myapp.localhost {"));
        assert!(cf.contains("reverse_proxy 127.0.0.1:3000"));
        assert!(!cf.contains("tls internal"));
        assert!(!cf.contains("https_port"));
        assert!(!cf.contains("pki"));
    }

    #[test]
    fn test_generate_caddyfile_multiple_routes() {
        let routes = vec![
            ("app1.test".to_string(), "127.0.0.1:3000".parse().unwrap()),
            ("app2.test".to_string(), "127.0.0.1:5173".parse().unwrap()),
        ];
        let cf = make_manager("test").generate_caddyfile(&routes);

        assert!(cf.contains("app1.test {"));
        assert!(cf.contains("reverse_proxy 127.0.0.1:3000"));
        assert!(cf.contains("app2.test {"));
        assert!(cf.contains("reverse_proxy 127.0.0.1:5173"));
    }

    #[test]
    fn test_proxy_status_serialization() {
        let json = serde_json::to_value(ProxyStatus::Failed("boom".into())).unwrap();
        assert_eq!(
            json,
            serde_json::json!({"state": "failed", "error": "boom"})
        );
        let json = serde_json::to_value(ProxyStatus::Running).unwrap();
        assert_eq!(json, serde_json::json!({"state": "running"}));
    }
}
