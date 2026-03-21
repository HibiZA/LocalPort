use crate::router::Router;
use anyhow::Result;
use devspace_core::config::GlobalConfig;
use std::sync::Arc;
use tokio::process::{Child, Command};
use tokio::sync::RwLock;

pub struct CaddyManager {
    config: GlobalConfig,
    caddy_bin: String,
    router: Arc<RwLock<Router>>,
    child: Option<Child>,
}

impl CaddyManager {
    pub fn new(config: GlobalConfig, router: Arc<RwLock<Router>>) -> Self {
        let caddy_bin = config.resolve_caddy_bin();
        Self {
            config,
            caddy_bin,
            router,
            child: None,
        }
    }

    /// Write the Caddyfile and start the Caddy process.
    /// Auto-downloads Caddy if not found.
    pub async fn start(&mut self) -> Result<()> {
        // Check if caddy binary exists, download if needed
        if !self.caddy_exists().await {
            tracing::info!("caddy not found, downloading...");
            download_caddy().await?;
            // Update resolved path after download
            self.caddy_bin = self.config.resolve_caddy_bin();
        }

        self.write_caddyfile().await?;

        let caddyfile_path = self.config.caddyfile_path();
        let child = Command::new(&self.caddy_bin)
            .args(["run", "--config", &caddyfile_path.to_string_lossy()])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .map_err(|e| anyhow::anyhow!("failed to start caddy: {}", e))?;

        tracing::info!("caddy started (pid {})", child.id().unwrap_or(0));
        self.child = Some(child);
        Ok(())
    }

    /// Stop the Caddy process gracefully.
    pub async fn stop(&mut self) {
        if let Some(ref mut child) = self.child {
            let pid = child.id().unwrap_or(0);
            tracing::info!("stopping caddy (pid {})", pid);

            // Send SIGTERM to Caddy process group
            if pid > 0 {
                // SAFETY: kill() is a standard POSIX signal call. Sending SIGTERM to a
                // known child PID is safe. Errors are ignored since this is best-effort cleanup.
                unsafe {
                    libc::kill(pid as i32, libc::SIGTERM);
                }
            }

            // Wait up to 5 seconds
            match tokio::time::timeout(tokio::time::Duration::from_secs(5), child.wait()).await {
                Ok(Ok(status)) => {
                    tracing::info!("caddy exited with {}", status);
                }
                Ok(Err(e)) => {
                    tracing::warn!("error waiting for caddy: {}", e);
                }
                Err(_) => {
                    tracing::warn!("caddy didn't exit, sending SIGKILL");
                    let _ = child.kill().await;
                }
            }
        }
        self.child = None;
    }

    /// Rewrite the Caddyfile from current routes and reload Caddy.
    pub async fn reload(&self) -> Result<()> {
        self.write_caddyfile().await?;

        let caddyfile_path = self.config.caddyfile_path();
        let status = Command::new(&self.caddy_bin)
            .args(["reload", "--config", &caddyfile_path.to_string_lossy()])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .await?;

        if !status.success() {
            tracing::warn!("caddy reload exited with {}", status);
        } else {
            tracing::debug!("caddy reloaded");
        }

        Ok(())
    }

    async fn caddy_exists(&self) -> bool {
        Command::new(&self.caddy_bin)
            .args(["version"])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .await
            .is_ok_and(|s| s.success())
    }

    async fn write_caddyfile(&self) -> Result<()> {
        let routes = self.router.read().await.list_routes();
        let content = self.generate_caddyfile(&routes);

        // Ensure config directory exists
        let config_dir = GlobalConfig::config_dir();
        std::fs::create_dir_all(&config_dir)?;

        let path = self.config.caddyfile_path();
        std::fs::write(&path, &content)?;
        tracing::debug!("wrote Caddyfile with {} route(s)", routes.len());

        Ok(())
    }

    pub(crate) fn generate_caddyfile(&self, routes: &[(String, std::net::SocketAddr)]) -> String {
        let mut cf = String::new();

        if self.config.tld == devspace_core::validation::LOCALHOST_TLD {
            // Localhost mode: HTTP only, single port, host-based matching
            cf.push_str(&format!(
                "{{\n    admin localhost:2019\n    http_port {}\n}}\n\n",
                self.config.caddy.http_port
            ));

            for (hostname, addr) in routes {
                cf.push_str(&format!(
                    "http://{hostname} {{\n    reverse_proxy {addr}\n}}\n\n",
                ));
            }
        } else {
            // Custom TLD mode (e.g., .test): HTTPS with internal CA
            cf.push_str(&format!(
                "{{\n    admin localhost:2019\n    http_port {}\n    https_port {}\n}}\n\n",
                self.config.caddy.http_port, self.config.caddy.https_port
            ));

            for (hostname, addr) in routes {
                cf.push_str(&format!(
                    "{hostname} {{\n    reverse_proxy {addr}\n    tls internal\n}}\n\n",
                ));
            }
        }

        cf
    }
}

/// Download the Caddy binary to ~/.config/devspace/bin/caddy
async fn download_caddy() -> Result<()> {
    let arch = if cfg!(target_arch = "aarch64") {
        "arm64"
    } else {
        "amd64"
    };

    let url = format!(
        "https://caddyserver.com/api/download?os=darwin&arch={}",
        arch
    );

    let bin_dir = GlobalConfig::config_dir().join("bin");
    std::fs::create_dir_all(&bin_dir)?;

    let bin_path = bin_dir.join("caddy");
    let tmp_path = bin_dir.join("caddy.tmp");

    tracing::info!("downloading caddy from {}", url);

    // Use system curl to download — available on all macOS systems
    let status = Command::new("curl")
        .args([
            "-fSL",
            "--progress-bar",
            "-o",
            &tmp_path.to_string_lossy(),
            &url,
        ])
        .status()
        .await?;

    if !status.success() {
        // Clean up partial download
        let _ = std::fs::remove_file(&tmp_path);
        anyhow::bail!("failed to download caddy (curl exited with {})", status);
    }

    // Make executable
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&tmp_path, std::fs::Permissions::from_mode(0o755))?;
    }

    // Atomic rename
    std::fs::rename(&tmp_path, &bin_path)?;

    // Verify it works
    let output = Command::new(&bin_path).args(["version"]).output().await?;

    if output.status.success() {
        let version = String::from_utf8_lossy(&output.stdout);
        tracing::info!("caddy downloaded: {}", version.trim());
    } else {
        let _ = std::fs::remove_file(&bin_path);
        anyhow::bail!("downloaded caddy binary failed version check");
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::router::Router;
    use std::net::SocketAddr;
    use std::sync::Arc;
    use tokio::sync::{Notify, RwLock};

    fn make_manager(tld: &str) -> CaddyManager {
        let notify = Arc::new(Notify::new());
        let router = Arc::new(RwLock::new(Router::new(notify)));
        let mut config = GlobalConfig::default();
        config.tld = tld.to_string();
        CaddyManager::new(config, router)
    }

    #[test]
    fn test_generate_caddyfile_test_tld_empty() {
        let mgr = make_manager("test");
        let cf = mgr.generate_caddyfile(&[]);

        assert!(cf.contains("admin localhost:2019"));
        assert!(cf.contains("http_port 8080"));
        assert!(cf.contains("https_port 8443"));
        assert!(!cf.contains("reverse_proxy"));
    }

    #[test]
    fn test_generate_caddyfile_test_tld_with_routes() {
        let mgr = make_manager("test");
        let addr: SocketAddr = "127.0.0.1:3000".parse().unwrap();
        let routes = vec![("myapp.test".to_string(), addr)];
        let cf = mgr.generate_caddyfile(&routes);

        assert!(cf.contains("myapp.test {"));
        assert!(cf.contains("reverse_proxy 127.0.0.1:3000"));
        assert!(cf.contains("tls internal"));
    }

    #[test]
    fn test_generate_caddyfile_localhost_tld() {
        let mgr = make_manager("localhost");
        let addr: SocketAddr = "127.0.0.1:3000".parse().unwrap();
        let routes = vec![("myapp.localhost".to_string(), addr)];
        let cf = mgr.generate_caddyfile(&routes);

        assert!(cf.contains("http://myapp.localhost {"));
        assert!(cf.contains("reverse_proxy 127.0.0.1:3000"));
        assert!(!cf.contains("tls internal"));
        assert!(!cf.contains("https_port"));
    }

    #[test]
    fn test_generate_caddyfile_multiple_routes() {
        let mgr = make_manager("test");
        let routes = vec![
            ("app1.test".to_string(), "127.0.0.1:3000".parse().unwrap()),
            ("app2.test".to_string(), "127.0.0.1:5173".parse().unwrap()),
        ];
        let cf = mgr.generate_caddyfile(&routes);

        assert!(cf.contains("app1.test {"));
        assert!(cf.contains("reverse_proxy 127.0.0.1:3000"));
        assert!(cf.contains("app2.test {"));
        assert!(cf.contains("reverse_proxy 127.0.0.1:5173"));
    }
}
