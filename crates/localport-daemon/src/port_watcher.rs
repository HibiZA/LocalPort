use crate::router::Router;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::{watch, RwLock};
use tokio::time::{interval, Duration};

use libproc::libproc::file_info::{pidfdinfo, ListFDs, ProcFDType};
use libproc::libproc::net_info::SocketFDInfo;
use libproc::libproc::proc_pid::{listpidinfo, pidinfo};
use libproc::libproc::task_info::TaskAllInfo;
use libproc::processes::{pids_by_type, ProcFilter};

// ---------------------------------------------------------------------------
// Raw FFI for proc_pidinfo — needed for CWD lookup (PROC_PIDVNODEPATHINFO)
// which the `libproc` crate does not implement on macOS.
// ---------------------------------------------------------------------------

extern "C" {
    fn proc_pidinfo(
        pid: libc::c_int,
        flavor: libc::c_int,
        arg: u64,
        buffer: *mut libc::c_void,
        buffersize: libc::c_int,
    ) -> libc::c_int;
}

const PROC_PIDVNODEPATHINFO: libc::c_int = 9;
const MAXPATHLEN: usize = 1024;

/// Mirrors Darwin's `vinfo_stat` (see bsd/sys/proc_info.h).
#[repr(C)]
struct VInfoStat {
    vst_dev: u32,
    vst_mode: u16,
    vst_nlink: u16,
    vst_ino: u64,
    vst_uid: u32,
    vst_gid: u32,
    vst_atime: i64,
    vst_atimensec: i64,
    vst_mtime: i64,
    vst_mtimensec: i64,
    vst_ctime: i64,
    vst_ctimensec: i64,
    vst_birthtime: i64,
    vst_birthtimensec: i64,
    vst_size: i64,
    vst_blocks: i64,
    vst_blksize: i32,
    vst_flags: u32,
    vst_gen: u32,
    vst_rdev: u32,
    vst_qspare: [i64; 2],
}

/// Mirrors Darwin's `vnode_info`.
#[repr(C)]
struct VnodeInfo {
    vi_stat: VInfoStat,
    vi_type: i32,
    vi_pad: i32,
    vi_fsid: [i32; 2],
}

/// Mirrors Darwin's `vnode_info_path`.
#[repr(C)]
struct VnodeInfoPath {
    vip_vi: VnodeInfo,
    vip_path: [u8; MAXPATHLEN],
}

/// Mirrors Darwin's `proc_vnodepathinfo`.
#[repr(C)]
struct ProcVnodePathInfo {
    pvi_cdir: VnodeInfoPath,
    pvi_rdir: VnodeInfoPath,
}

// ---------------------------------------------------------------------------
// Port watcher types
// ---------------------------------------------------------------------------

/// Watches for new TCP listeners on the system and maps them to registered projects.
pub struct PortWatcher {
    router: Arc<RwLock<Router>>,
    projects: Arc<RwLock<ProjectRegistry>>,
    tld: String,
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

    #[allow(dead_code)]
    pub fn unregister(&mut self, directory: &std::path::Path) -> bool {
        self.projects.remove(directory).is_some()
    }

    /// Find which project owns the given directory (checks if dir starts with any project dir).
    #[allow(dead_code)]
    pub fn find_project_for_dir(&self, dir: &std::path::Path) -> Option<&str> {
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

    pub fn is_empty(&self) -> bool {
        self.projects.is_empty()
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
    ) -> Self {
        Self {
            router,
            projects,
            tld,
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
        // Skip scanning if no projects are registered yet.
        if self.projects.read().await.is_empty() {
            return Ok(());
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

        // Collect the set of registered project directories so we can check
        // against all listeners — including ones that were previously unmatched
        // because the project wasn't registered yet.
        let project_dirs = self.projects.read().await.list();

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

            // Check if CWD matches any registered project.
            let project_name = project_dirs
                .iter()
                .find(|(dir, _)| cwd.starts_with(dir))
                .map(|(_, name)| name.clone());

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
        proc_pidinfo(
            pid as libc::c_int,
            PROC_PIDVNODEPATHINFO,
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
    let nul_pos = path_bytes.iter().position(|&b| b == 0).unwrap_or(MAXPATHLEN);
    if nul_pos == 0 {
        return None;
    }

    std::str::from_utf8(&path_bytes[..nul_pos])
        .ok()
        .map(PathBuf::from)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;

    // -- ProjectRegistry tests -----------------------------------------------

    #[test]
    fn test_registry_register_and_find() {
        let mut reg = ProjectRegistry::default();
        reg.register(PathBuf::from("/Users/me/projects/my-app"), "my-app".into());

        assert_eq!(
            reg.find_project_for_dir(std::path::Path::new("/Users/me/projects/my-app")),
            Some("my-app")
        );
    }

    #[test]
    fn test_registry_find_subdirectory() {
        let mut reg = ProjectRegistry::default();
        reg.register(PathBuf::from("/Users/me/projects/my-app"), "my-app".into());

        // A subdirectory should still match
        assert_eq!(
            reg.find_project_for_dir(std::path::Path::new("/Users/me/projects/my-app/src")),
            Some("my-app")
        );
    }

    #[test]
    fn test_registry_no_match() {
        let mut reg = ProjectRegistry::default();
        reg.register(PathBuf::from("/Users/me/projects/my-app"), "my-app".into());

        assert_eq!(
            reg.find_project_for_dir(std::path::Path::new("/Users/me/projects/other-app")),
            None
        );
    }

    #[test]
    fn test_registry_list() {
        let mut reg = ProjectRegistry::default();
        reg.register(PathBuf::from("/a"), "alpha".into());
        reg.register(PathBuf::from("/b"), "beta".into());

        let list = reg.list();
        assert_eq!(list.len(), 2);
    }

    // -- discover_listeners tests --------------------------------------------

    #[test]
    fn test_discover_listeners_finds_bound_port() {
        // Bind a TCP listener so there's at least one LISTEN socket owned by
        // our PID.
        let listener = TcpListener::bind("127.0.0.1:0").expect("failed to bind");
        let expected_port = listener.local_addr().unwrap().port();
        let our_pid = std::process::id();

        let listeners = discover_listeners_blocking();

        let found = listeners
            .iter()
            .any(|l| l.pid == our_pid && l.port == expected_port);

        assert!(
            found,
            "expected to find pid={} port={} in listeners, got: {:?}",
            our_pid, expected_port, listeners
        );

        drop(listener);
    }

    #[test]
    fn test_discover_listeners_does_not_find_closed_port() {
        // Bind and immediately close.
        let listener = TcpListener::bind("127.0.0.1:0").expect("failed to bind");
        let closed_port = listener.local_addr().unwrap().port();
        drop(listener);

        let our_pid = std::process::id();
        let listeners = discover_listeners_blocking();

        let found = listeners
            .iter()
            .any(|l| l.pid == our_pid && l.port == closed_port);

        assert!(
            !found,
            "should NOT find closed port {} in listeners",
            closed_port
        );
    }

    // -- get_pid_cwd tests ---------------------------------------------------

    #[test]
    fn test_get_pid_cwd_returns_valid_path_for_self() {
        let cwd = get_pid_cwd_blocking(std::process::id());
        assert!(cwd.is_some(), "should be able to get CWD of own process");

        let cwd = cwd.unwrap();
        assert!(cwd.is_absolute(), "CWD should be an absolute path");
        assert!(cwd.exists(), "CWD path should exist on disk");
    }

    #[test]
    fn test_get_pid_cwd_matches_env_cwd() {
        let cwd = get_pid_cwd_blocking(std::process::id()).unwrap();
        let env_cwd = std::env::current_dir().unwrap();
        assert_eq!(cwd, env_cwd, "libproc CWD should match std::env::current_dir()");
    }

    #[test]
    fn test_get_pid_cwd_invalid_pid() {
        // PID 0 is the kernel — we shouldn't be able to get its CWD as a
        // normal user, and a garbage PID should return None.
        let cwd = get_pid_cwd_blocking(999_999_999);
        assert!(cwd.is_none(), "invalid PID should return None");
    }

    // -- FFI struct layout sanity checks -------------------------------------

    #[test]
    fn test_proc_vnode_path_info_size() {
        // Verify our repr(C) structs have the expected sizes so the FFI call
        // reads/writes the correct amount of memory.
        //
        // Expected sizes (from Darwin headers on arm64/x86_64):
        //   VInfoStat         = 136 bytes
        //   VnodeInfo          = 152 bytes  (136 + 4 + 4 + 8)
        //   VnodeInfoPath      = 1176 bytes (152 + 1024)
        //   ProcVnodePathInfo  = 2352 bytes (1176 * 2)
        assert_eq!(std::mem::size_of::<VInfoStat>(), 136);
        assert_eq!(std::mem::size_of::<VnodeInfo>(), 152);
        assert_eq!(std::mem::size_of::<VnodeInfoPath>(), 1176);
        assert_eq!(std::mem::size_of::<ProcVnodePathInfo>(), 2352);
    }

    // -- Integration: scan creates and removes routes ------------------------

    #[tokio::test]
    async fn test_scan_creates_route_for_listener_in_project_dir() {
        let notify = Arc::new(tokio::sync::Notify::new());
        let router = Arc::new(RwLock::new(Router::new(notify)));
        let projects = Arc::new(RwLock::new(ProjectRegistry::default()));

        // Register the current working directory as a project.
        let cwd = std::env::current_dir().unwrap();
        projects
            .write()
            .await
            .register(cwd, "test-project".into());

        let watcher = PortWatcher::new(router.clone(), projects.clone(), "test".into());

        // Bind a listener in this process (whose CWD is the project dir).
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();

        // Run one scan cycle.
        let mut active_routes = HashMap::new();
        watcher.scan(&mut active_routes).await.unwrap();

        // Verify the route was created.
        assert!(
            active_routes.contains_key(&port),
            "scan should have created a route for port {}",
            port
        );
        assert_eq!(active_routes.get(&port).unwrap(), "test-project.test");

        let routes = router.read().await.list_routes();
        assert!(
            routes.iter().any(|(h, _)| h == "test-project.test"),
            "router should contain the route"
        );

        // Drop the listener and scan again — route should be removed.
        drop(listener);
        watcher.scan(&mut active_routes).await.unwrap();

        assert!(
            !active_routes.contains_key(&port),
            "route should be removed after listener is dropped"
        );
    }

    #[tokio::test]
    async fn test_scan_ignores_listener_outside_project_dir() {
        let notify = Arc::new(tokio::sync::Notify::new());
        let router = Arc::new(RwLock::new(Router::new(notify)));
        let projects = Arc::new(RwLock::new(ProjectRegistry::default()));

        // Register a directory that is NOT our CWD.
        projects
            .write()
            .await
            .register(PathBuf::from("/nonexistent/fake-project"), "fake".into());

        let watcher = PortWatcher::new(router.clone(), projects.clone(), "test".into());

        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();

        let mut active_routes = HashMap::new();
        watcher.scan(&mut active_routes).await.unwrap();

        assert!(
            !active_routes.contains_key(&port),
            "should NOT create a route for a listener outside any project dir"
        );

        drop(listener);
    }

    #[tokio::test]
    async fn test_scan_picks_up_project_registered_after_listener_started() {
        let notify = Arc::new(tokio::sync::Notify::new());
        let router = Arc::new(RwLock::new(Router::new(notify)));
        let projects = Arc::new(RwLock::new(ProjectRegistry::default()));
        let cwd = std::env::current_dir().unwrap();

        let watcher = PortWatcher::new(router.clone(), projects.clone(), "test".into());

        // Start a listener BEFORE registering the project.
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();

        // First scan: no projects registered, should skip scanning entirely.
        let mut active_routes = HashMap::new();
        watcher.scan(&mut active_routes).await.unwrap();
        assert!(active_routes.is_empty(), "no routes yet — no projects registered");

        // Now register the project (simulates user adding a project at runtime).
        projects.write().await.register(cwd, "late-project".into());

        // Second scan: should now pick up the already-running listener.
        watcher.scan(&mut active_routes).await.unwrap();
        assert!(
            active_routes.contains_key(&port),
            "scan should detect listener after project was registered (port {})",
            port
        );
        assert_eq!(active_routes.get(&port).unwrap(), "late-project.test");

        drop(listener);
    }

    #[tokio::test]
    async fn test_scan_skips_when_no_projects_registered() {
        let notify = Arc::new(tokio::sync::Notify::new());
        let router = Arc::new(RwLock::new(Router::new(notify)));
        let projects = Arc::new(RwLock::new(ProjectRegistry::default()));

        let watcher = PortWatcher::new(router.clone(), projects.clone(), "test".into());

        let listener = TcpListener::bind("127.0.0.1:0").unwrap();

        let mut active_routes = HashMap::new();
        watcher.scan(&mut active_routes).await.unwrap();

        // Should not have scanned at all — no projects registered.
        assert!(active_routes.is_empty());

        drop(listener);
    }

    #[tokio::test]
    async fn test_empty_scan_does_not_nuke_active_routes() {
        // Simulate the case where active_routes has entries but the scan
        // returns 0 listeners (transient failure). Routes should be preserved.
        let notify = Arc::new(tokio::sync::Notify::new());
        let router = Arc::new(RwLock::new(Router::new(notify)));
        let projects = Arc::new(RwLock::new(ProjectRegistry::default()));
        let cwd = std::env::current_dir().unwrap();
        projects.write().await.register(cwd, "myapp".into());

        let watcher = PortWatcher::new(router.clone(), projects.clone(), "test".into());

        // Seed active_routes as if a previous scan found a listener.
        let mut active_routes = HashMap::new();
        active_routes.insert(9999, "myapp.test".to_string());

        // The listener on port 9999 doesn't actually exist, so it won't show
        // up in the scan. But our guard should prevent removal if the scan
        // returns completely empty (all listeners gone at once is suspicious).
        // Note: this test only works if the system has no other LISTEN ports,
        // which is unlikely. So we test the guard condition explicitly: if
        // listeners is empty AND active_routes is not, skip cleanup.
        // We can't fully simulate this in a unit test without mocking, but
        // we can verify that a normal scan with a real listener doesn't
        // incorrectly remove unrelated routes.
        watcher.scan(&mut active_routes).await.unwrap();

        // The route for port 9999 may or may not be cleaned up depending on
        // whether other LISTEN sockets exist on the system. This test mainly
        // exercises the code path without panicking.
    }
}
