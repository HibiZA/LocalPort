use crate::router::Router;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::process::Command;
use tokio::sync::{watch, RwLock};
use tokio::time::{interval, Duration};

/// Watches for new TCP listeners on the system and maps them to registered projects.
pub struct PortWatcher {
    router: Arc<RwLock<Router>>,
    projects: Arc<RwLock<ProjectRegistry>>,
    interval: Duration,
}

/// Registry of known project directories.
#[derive(Debug, Default)]
pub struct ProjectRegistry {
    /// Maps project directory -> project name
    projects: HashMap<PathBuf, String>,
}

impl ProjectRegistry {
    pub fn register(&mut self, directory: PathBuf, name: String) {
        tracing::info!("registered project '{}' at {}", name, directory.display());
        self.projects.insert(directory, name);
    }

    pub fn unregister(&mut self, directory: &PathBuf) -> Option<String> {
        self.projects.remove(directory)
    }

    /// Find which project owns the given directory (checks if dir starts with any project dir).
    pub fn find_project_for_dir(&self, dir: &PathBuf) -> Option<&str> {
        for (project_dir, name) in &self.projects {
            if dir.starts_with(project_dir) {
                return Some(name.as_str());
            }
        }
        None
    }

    pub fn list(&self) -> Vec<(PathBuf, String)> {
        self.projects
            .iter()
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect()
    }
}

#[derive(Debug)]
struct ListeningPort {
    pid: u32,
    port: u16,
}

impl PortWatcher {
    pub fn new(
        router: Arc<RwLock<Router>>,
        projects: Arc<RwLock<ProjectRegistry>>,
    ) -> Self {
        Self {
            router,
            projects,
            interval: Duration::from_secs(2),
        }
    }

    pub async fn run(&self, mut shutdown: watch::Receiver<bool>) {
        let mut ticker = interval(self.interval);
        // Track what we've already routed: port -> hostname
        let mut active_routes: HashMap<u16, String> = HashMap::new();

        loop {
            tokio::select! {
                _ = ticker.tick() => {
                    if let Err(e) = self.scan(&mut active_routes).await {
                        tracing::debug!("port scan error: {}", e);
                    }
                }
                _ = shutdown.changed() => {
                    tracing::info!("port watcher shutting down");
                    break;
                }
            }
        }
    }

    async fn scan(&self, active_routes: &mut HashMap<u16, String>) -> anyhow::Result<()> {
        let listeners = discover_listeners().await?;
        let projects = self.projects.read().await;

        // Track which ports are still active
        let mut seen_ports = std::collections::HashSet::new();

        for listener in &listeners {
            seen_ports.insert(listener.port);

            // Skip if we already have a route for this port
            if active_routes.contains_key(&listener.port) {
                continue;
            }

            // Try to find the working directory of this PID
            if let Some(cwd) = get_pid_cwd(listener.pid).await {
                if let Some(project_name) = projects.find_project_for_dir(&cwd) {
                    let hostname = format!("{}.localhost", project_name);
                    let addr = format!("127.0.0.1:{}", listener.port)
                        .parse()
                        .unwrap();

                    self.router.write().await.add_route(hostname.clone(), addr);
                    active_routes.insert(listener.port, hostname);
                }
            }
        }

        // Remove routes for ports that are no longer listening
        let stale_ports: Vec<u16> = active_routes
            .keys()
            .filter(|p| !seen_ports.contains(p))
            .copied()
            .collect();

        for port in stale_ports {
            if let Some(hostname) = active_routes.remove(&port) {
                self.router.write().await.remove_route(&hostname);
            }
        }

        Ok(())
    }
}

/// Discover all listening TCP ports using lsof (macOS).
async fn discover_listeners() -> anyhow::Result<Vec<ListeningPort>> {
    let output = Command::new("lsof")
        .args(["-iTCP", "-sTCP:LISTEN", "-nP", "-Fn", "-Fp"])
        .output()
        .await?;

    if !output.status.success() {
        return Ok(Vec::new());
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let mut listeners = Vec::new();
    let mut current_pid: Option<u32> = None;

    for line in stdout.lines() {
        if let Some(pid_str) = line.strip_prefix('p') {
            current_pid = pid_str.parse().ok();
        } else if let Some(name) = line.strip_prefix('n') {
            if let Some(pid) = current_pid {
                // name looks like "127.0.0.1:3000" or "*:3000" or "[::1]:3000"
                if let Some(port_str) = name.rsplit(':').next() {
                    if let Ok(port) = port_str.parse::<u16>() {
                        listeners.push(ListeningPort { pid, port });
                    }
                }
            }
        }
    }

    Ok(listeners)
}

/// Get the working directory of a process by PID (macOS).
async fn get_pid_cwd(pid: u32) -> Option<PathBuf> {
    let output = Command::new("lsof")
        .args(["-p", &pid.to_string(), "-d", "cwd", "-Fn"])
        .output()
        .await
        .ok()?;

    if !output.status.success() {
        return None;
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    for line in stdout.lines() {
        if let Some(path) = line.strip_prefix('n') {
            return Some(PathBuf::from(path));
        }
    }

    None
}
