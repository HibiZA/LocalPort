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

    /// Find which project owns the given directory (checks if dir starts with any project dir).
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
        let listeners = discover_listeners().await?;

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
                // Hold the projects lock only briefly to check membership
                let project_name = self
                    .projects
                    .read()
                    .await
                    .find_project_for_dir(&cwd)
                    .map(|s| s.to_string());

                if let Some(project_name) = project_name {
                    let hostname = format!("{}.{}", project_name, self.tld);
                    let addr: std::net::SocketAddr = format!("127.0.0.1:{}", listener.port)
                        .parse()
                        .expect("hardcoded 127.0.0.1 with valid port always parses");

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
        Err(_) => return Vec::new(),
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
