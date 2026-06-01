mod ffi;
mod proc_env;

#[cfg(test)]
mod tests;

use crate::router::Router;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
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
        //
        // Note: we deliberately do NOT short-circuit when the registry is
        // empty. A process launched via `localport run` carries an explicit
        // `LOCALPORT_PROJECT` tag and must be routed by ground truth even when
        // no project directory has been registered.
        //
        // Trade-off: previously an empty registry skipped the whole scan. Now
        // an unconfigured daemon still enumerates listeners and reads each new
        // listener's env+cwd every tick. *Attribution* of untagged listeners is
        // unchanged (they still resolve to no route — see `attribute_project`),
        // but the idle scan now does work it used to skip. This is bounded by
        // the number of listening sockets (typically a few dozen) and is the
        // price of supporting tags without prior registration.
        let current_generation = self.projects.read().await.generation();

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

        // Gather attribution inputs (tag + cwd) for every listener we haven't
        // already routed. These reads are the only system I/O here; the routing
        // decision itself is made by the pure `reconcile` below — which is what
        // the deterministic tests exercise, without binding real ports.
        let mut infos = Vec::with_capacity(listeners.len());
        for l in &listeners {
            let (tag, cwd) = if active_routes.contains_key(&l.port) {
                (None, None) // already routed; inputs unused
            } else {
                (read_project_tag(l.pid).await, get_pid_cwd(l.pid).await)
            };
            infos.push(ListenerInfo {
                port: l.port,
                pid: l.pid,
                tag,
                cwd,
            });
        }

        let plan = {
            let registry = self.projects.read().await;
            reconcile(&infos, active_routes, &registry, &self.tld)
        };

        // Apply the plan: mutate the router and our active-route bookkeeping.
        for add in plan.add {
            tracing::info!(
                "auto-routing {} -> {} (pid={}, {})",
                add.hostname,
                add.addr,
                add.pid,
                add.source
            );
            self.router
                .write()
                .await
                .add_route(add.hostname.clone(), add.addr);
            active_routes.insert(add.port, add.hostname);
        }
        for (port, hostname) in plan.remove {
            tracing::info!("removing stale route {hostname} (port {port} no longer listening)");
            self.router.write().await.remove_route(&hostname);
            active_routes.remove(&port);
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
// Project attribution: ground-truth tag wins, cwd heuristic as fallback
// ---------------------------------------------------------------------------

/// Resolve an explicit `LOCALPORT_PROJECT` tag into a hostname label.
///
/// Returns `None` if the tag is absent or cannot be normalized into a valid
/// DNS label, in which case the caller falls back to cwd inference. The
/// normalization matches daemon registration exactly (see
/// [`localport_core::validation::normalize_project_name`]), so a tagged
/// process and a registered directory resolve to the same hostname.
fn resolve_tag(tag: Option<&str>) -> Option<String> {
    let raw = tag?;
    let name = localport_core::validation::normalize_project_name(raw);
    localport_core::validation::is_valid_dns_label(&name).then_some(name)
}

/// Decide which project a listening process belongs to.
///
/// **Ground truth wins:** if the process carries a valid `LOCALPORT_PROJECT`
/// tag, that project is used directly — no registration and no cwd match
/// required. This is what makes monorepos work: `localport run --project web`
/// from the repo root attributes the port to `web` regardless of cwd.
///
/// Otherwise fall back to the working-directory heuristic against the registry
/// (most-specific registered directory wins). This keeps the zero-config path
/// (start a dev server in a registered directory) working exactly as before.
fn attribute_project(
    tag: Option<&str>,
    cwd: Option<&Path>,
    registry: &ProjectRegistry,
) -> Option<String> {
    if let Some(name) = resolve_tag(tag) {
        return Some(name);
    }
    cwd.and_then(|c| registry.find_project_for_dir(c).map(|s| s.to_string()))
}

/// Read the `LOCALPORT_PROJECT` tag from a process's environment, if present.
///
/// Delegates to the portable [`proc_env`] seam (macOS: `KERN_PROCARGS2`).
async fn read_project_tag(pid: u32) -> Option<String> {
    tokio::task::spawn_blocking(move || {
        proc_env::get_pid_env_var(pid, localport_core::PROJECT_ENV_VAR)
    })
    .await
    .ok()
    .flatten()
}

/// A single listener with the inputs `reconcile` needs to attribute it.
/// `scan` fills `tag`/`cwd` from the system; tests construct these directly so
/// routing decisions are tested without binding real ports.
#[derive(Debug)]
struct ListenerInfo {
    port: u16,
    pid: u32,
    tag: Option<String>,
    cwd: Option<PathBuf>,
}

/// A route to add, carrying enough context to log how it was attributed.
#[derive(Debug, PartialEq, Eq)]
struct RouteAdd {
    port: u16,
    pid: u32,
    hostname: String,
    addr: std::net::SocketAddr,
    /// `"tag"` or `"cwd=<path>"` — for logging only.
    source: String,
}

/// The route changes a single scan should apply.
#[derive(Debug, Default, PartialEq, Eq)]
struct RoutePlan {
    add: Vec<RouteAdd>,
    /// `(port, hostname)` routes whose listener has gone away.
    remove: Vec<(u16, String)>,
}

/// Decide which routes to add and remove, given the currently listening
/// sockets, the routes we already have, and the project registry.
///
/// This is the heart of the watcher, and it is **pure** — no syscalls, no
/// locks, no I/O. Every routing rule lives here (tag-wins-over-cwd, cwd
/// fallback, "leave already-routed ports alone", stale cleanup, and the
/// transient-empty-scan guard), so the tests can drive it deterministically
/// with synthetic [`ListenerInfo`]s instead of binding real ports (which made
/// the old `scan`-level tests flaky under parallel execution and port reuse).
fn reconcile(
    listeners: &[ListenerInfo],
    active_routes: &HashMap<u16, String>,
    registry: &ProjectRegistry,
    tld: &str,
) -> RoutePlan {
    let mut plan = RoutePlan::default();

    // Transient-failure guard: an empty listener list while routes are active
    // is almost always a failed/permission-denied enumeration, not "everything
    // stopped at once". Don't tear down routes based on it.
    if listeners.is_empty() && !active_routes.is_empty() {
        return plan;
    }

    let mut seen_ports = std::collections::HashSet::new();
    for info in listeners {
        seen_ports.insert(info.port);

        // Already routed — leave it alone.
        if active_routes.contains_key(&info.port) {
            continue;
        }

        let Some(name) = attribute_project(info.tag.as_deref(), info.cwd.as_deref(), registry)
        else {
            continue;
        };

        let hostname = format!("{}.{}", name, tld);
        let addr: std::net::SocketAddr = format!("127.0.0.1:{}", info.port)
            .parse()
            .expect("hardcoded 127.0.0.1 with valid port always parses");
        let source = if resolve_tag(info.tag.as_deref()).is_some() {
            "tag".to_string()
        } else {
            info.cwd
                .as_deref()
                .map(|c| format!("cwd={}", c.display()))
                .unwrap_or_default()
        };
        plan.add.push(RouteAdd {
            port: info.port,
            pid: info.pid,
            hostname,
            addr,
            source,
        });
    }

    // Any active route whose port is no longer listening is stale.
    for (port, hostname) in active_routes {
        if !seen_ports.contains(port) {
            plan.remove.push((*port, hostname.clone()));
        }
    }

    plan
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
