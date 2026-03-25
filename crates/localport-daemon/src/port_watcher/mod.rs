mod ffi;

#[cfg(test)]
mod tests;

use crate::router::Router;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::{Notify, RwLock};
use tokio::time::{interval, Duration};

use libproc::libproc::file_info::{pidfdinfo, ListFDs, ProcFDType};
use libproc::libproc::net_info::SocketFDInfo;
use libproc::libproc::proc_pid::{listpidinfo, pidinfo};
use libproc::libproc::task_info::TaskAllInfo;
use libproc::processes::{pids_by_type, ProcFilter};

use ffi::ProcVnodePathInfo;

// ---------------------------------------------------------------------------
// Port watcher types
// ---------------------------------------------------------------------------

/// Watches for new TCP listeners on the system and maps them to registered projects.
pub struct PortWatcher {
    router: Arc<RwLock<Router>>,
    projects: Arc<RwLock<ProjectRegistry>>,
    tld: String,
    interval: Duration,
    /// Notified when a project is registered so we scan immediately instead of
    /// waiting for the next tick.
    scan_notify: Arc<Notify>,
}

/// Registry of known project directories.
#[derive(Debug, Default)]
pub struct ProjectRegistry {
    /// Maps project directory -> project name
    projects: HashMap<PathBuf, String>,
    /// Incremented on every register/unregister so the port watcher knows
    /// when to re-evaluate existing routes against the updated registry.
    generation: u64,
}

impl ProjectRegistry {
    pub fn register(&mut self, directory: PathBuf, name: String) {
        tracing::info!("registered project '{}' at {}", name, directory.display());
        self.projects.insert(directory, name);
        self.generation += 1;
    }

    #[allow(dead_code)]
    pub fn unregister(&mut self, directory: &std::path::Path) -> bool {
        let removed = self.projects.remove(directory).is_some();
        if removed {
            self.generation += 1;
        }
        removed
    }

    /// Find which project owns the given directory.
    ///
    /// When multiple registered directories match (e.g. `/a/b` and `/a/b/c`
    /// both match a CWD of `/a/b/c/src`), the **most specific** (longest path)
    /// wins. This lets monorepo sub-apps override the parent project.
    pub fn find_project_for_dir(&self, dir: &std::path::Path) -> Option<&str> {
        self.projects
            .iter()
            .filter(|(project_dir, _)| dir.starts_with(project_dir))
            .max_by_key(|(project_dir, _)| project_dir.as_os_str().len())
            .map(|(_, name)| name.as_str())
    }

    pub fn list(&self) -> Vec<(PathBuf, String)> {
        self.projects
            .iter()
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect()
    }

    pub fn is_empty(&self) -> bool {
        self.projects.is_empty()
    }

    pub fn generation(&self) -> u64 {
        self.generation
    }
}

#[derive(Debug)]
struct ListeningPort {
    pid: u32,
    port: u16,
}

// ---------------------------------------------------------------------------
// PortWatcher implementation
// ---------------------------------------------------------------------------

impl PortWatcher {
    pub fn new(
        router: Arc<RwLock<Router>>,
        projects: Arc<RwLock<ProjectRegistry>>,
        tld: String,
        scan_notify: Arc<Notify>,
    ) -> Self {
        Self {
            router,
            projects,
            tld,
            interval: Duration::from_secs(2),
            scan_notify,
        }
    }

    pub async fn run(&self, mut shutdown: tokio::sync::watch::Receiver<bool>) {
        let mut ticker = interval(self.interval);
        // Track what we've already routed: port -> hostname
        let mut active_routes: HashMap<u16, String> = HashMap::new();
        // Track the project registry generation so we re-evaluate routes
        // when projects are added or removed at runtime.
        let mut last_generation: u64 = 0;

        loop {
            tokio::select! {
                _ = ticker.tick() => {
                    if let Err(e) = self.scan(&mut active_routes, &mut last_generation).await {
                        tracing::debug!("port scan error: {}", e);
                    }
                }
                _ = self.scan_notify.notified() => {
                    tracing::info!("immediate scan triggered (project registered)");
                    if let Err(e) = self.scan(&mut active_routes, &mut last_generation).await {
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

    async fn scan(
        &self,
        active_routes: &mut HashMap<u16, String>,
        last_generation: &mut u64,
    ) -> anyhow::Result<()> {
        // Check if the project registry changed since our last scan.
        let current_generation = self.projects.read().await.generation();
        if self.projects.read().await.is_empty() {
            return Ok(());
        }

        // If projects were added/removed, clear active_routes so every
        // listener is re-evaluated against the updated registry. This
        // handles the case where a more specific sub-project was registered
        // after a parent directory already claimed a port.
        if current_generation != *last_generation {
            if *last_generation > 0 {
                tracing::info!(
                    "project registry changed (gen {} -> {}) — re-evaluating all routes",
                    last_generation,
                    current_generation
                );
                // Remove all existing routes so they can be re-matched.
                for (_port, hostname) in active_routes.drain() {
                    self.router.write().await.remove_route(&hostname);
                }
            }
            *last_generation = current_generation;
        }

        let listeners = discover_listeners().await?;

        // Guard: if the scan returned nothing but we have active routes,
        // this is likely a transient failure (permissions, timing, etc.).
        // Don't nuke existing routes based on an empty/failed scan.
        if listeners.is_empty() && !active_routes.is_empty() {
            tracing::debug!(
                "scan returned 0 listeners but {} routes are active — skipping stale cleanup",
                active_routes.len()
            );
            return Ok(());
        }

        // Track which ports are still active
        let mut seen_ports = std::collections::HashSet::new();

        // Snapshot the project registry for matching.
        let registry = self.projects.read().await;

        for listener in &listeners {
            seen_ports.insert(listener.port);

            // Skip if we already have a route for this port
            if active_routes.contains_key(&listener.port) {
                continue;
            }

            // Try to find the working directory of this PID
            let cwd = match get_pid_cwd(listener.pid).await {
                Some(cwd) => cwd,
                None => {
                    tracing::trace!(
                        "could not get cwd for pid={} port={} — skipping",
                        listener.pid,
                        listener.port
                    );
                    continue;
                }
            };

            // Check if CWD matches any registered project (most specific wins).
            let project_name = registry.find_project_for_dir(&cwd);

            if let Some(project_name) = project_name {
                let hostname = format!("{}.{}", project_name, self.tld);
                let addr: std::net::SocketAddr = format!("127.0.0.1:{}", listener.port)
                    .parse()
                    .expect("hardcoded 127.0.0.1 with valid port always parses");

                tracing::info!(
                    "auto-routing {hostname} -> 127.0.0.1:{} (pid={}, cwd={})",
                    listener.port,
                    listener.pid,
                    cwd.display()
                );

                self.router.write().await.add_route(hostname.clone(), addr);
                active_routes.insert(listener.port, hostname);
            }
        }

        // Must drop the registry read lock before acquiring write locks below.
        drop(registry);

        // Remove routes for ports that are no longer listening
        let stale_ports: Vec<u16> = active_routes
            .keys()
            .filter(|p| !seen_ports.contains(p))
            .copied()
            .collect();

        for port in stale_ports {
            if let Some(hostname) = active_routes.remove(&port) {
                tracing::info!("removing stale route {hostname} (port {port} no longer listening)");
                self.router.write().await.remove_route(&hostname);
            }
        }

        Ok(())
    }
}

// ---------------------------------------------------------------------------
// libproc-based listener discovery (replaces `lsof -iTCP -sTCP:LISTEN`)
// ---------------------------------------------------------------------------

/// Discover all listening TCP ports using macOS `libproc` APIs.
///
/// This replaces the previous approach of shelling out to `lsof` every scan
/// cycle. Instead we use in-process syscalls via `libproc`:
///   1. Enumerate all PIDs
///   2. For each PID, list its file descriptors
///   3. For socket FDs, query TCP socket info
///   4. Collect those in LISTEN state with their local port
async fn discover_listeners() -> anyhow::Result<Vec<ListeningPort>> {
    tokio::task::spawn_blocking(discover_listeners_blocking)
        .await
        .map_err(|e| anyhow::anyhow!("spawn_blocking join error: {}", e))
}

fn discover_listeners_blocking() -> Vec<ListeningPort> {
    let pids = match pids_by_type(ProcFilter::All) {
        Ok(p) => p,
        Err(e) => {
            tracing::warn!("pids_by_type failed: {} — returning empty listener list", e);
            return Vec::new();
        }
    };

    let mut listeners = Vec::new();

    for pid in pids {
        let pid_i32 = pid as i32;

        // Get task info to learn how many FDs this process has open.
        let nfiles = match pidinfo::<TaskAllInfo>(pid_i32, 0) {
            Ok(info) => info.pbsd.pbi_nfiles as usize,
            Err(_) => continue, // no permission or process already exited
        };

        if nfiles == 0 {
            continue;
        }

        // List all file descriptors.
        let fds = match listpidinfo::<ListFDs>(pid_i32, nfiles.max(1)) {
            Ok(fds) => fds,
            Err(_) => continue,
        };

        for fd in &fds {
            // Only interested in socket FDs (ProcFDType::Socket = 2).
            if fd.proc_fdtype != ProcFDType::Socket as u32 {
                continue;
            }

            let socket_info = match pidfdinfo::<SocketFDInfo>(pid_i32, fd.proc_fd) {
                Ok(info) => info,
                Err(_) => continue,
            };

            // Only interested in TCP sockets (SocketInfoKind::Tcp = 2).
            if socket_info.psi.soi_kind != 2 {
                continue;
            }

            // Safety: soi_kind == 2 guarantees the pri_tcp union variant is valid.
            let tcp_info = unsafe { socket_info.psi.soi_proto.pri_tcp };

            // Only interested in LISTEN state (TcpSIState::Listen = 1).
            if tcp_info.tcpsi_state != 1 {
                continue;
            }

            // Local port is stored in network byte order in the lower 16 bits.
            let port = u16::from_be(tcp_info.tcpsi_ini.insi_lport as u16);

            if port > 0 {
                listeners.push(ListeningPort { pid, port });
            }
        }
    }

    tracing::trace!("discovered {} listening ports", listeners.len());
    listeners
}

// ---------------------------------------------------------------------------
// libproc-based CWD lookup (replaces `lsof -a -p <pid> -d cwd -Fn`)
// ---------------------------------------------------------------------------

/// Get the working directory of a process by PID using `proc_pidinfo`
/// with `PROC_PIDVNODEPATHINFO`.
async fn get_pid_cwd(pid: u32) -> Option<PathBuf> {
    tokio::task::spawn_blocking(move || get_pid_cwd_blocking(pid))
        .await
        .ok()
        .flatten()
}

fn get_pid_cwd_blocking(pid: u32) -> Option<PathBuf> {
    let mut info: ProcVnodePathInfo = unsafe { std::mem::zeroed() };
    let ret = unsafe {
        ffi::proc_pidinfo(
            pid as libc::c_int,
            ffi::PROC_PIDVNODEPATHINFO,
            0,
            &mut info as *mut _ as *mut libc::c_void,
            std::mem::size_of::<ProcVnodePathInfo>() as libc::c_int,
        )
    };

    if ret <= 0 {
        return None;
    }

    // Extract the null-terminated path from the cwd vnode info.
    let path_bytes = &info.pvi_cdir.vip_path;
    let nul_pos = path_bytes
        .iter()
        .position(|&b| b == 0)
        .unwrap_or(ffi::MAXPATHLEN);
    if nul_pos == 0 {
        return None;
    }

    std::str::from_utf8(&path_bytes[..nul_pos])
        .ok()
        .map(PathBuf::from)
}
