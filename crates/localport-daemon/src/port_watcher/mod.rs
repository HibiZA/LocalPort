mod ffi;
mod proc_env;

#[cfg(test)]
mod tests;

use crate::router::Router;
use serde::Serialize;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use tokio::sync::{Notify, RwLock};
use tokio::time::{interval, Duration};

use libproc::libproc::file_info::{pidfdinfo, ListFDs, ProcFDType};
use libproc::libproc::net_info::SocketFDInfo;
use libproc::libproc::proc_pid::{listpidinfo, pidinfo, pidpath};
use libproc::libproc::task_info::TaskAllInfo;
use libproc::processes::{pids_by_type, ProcFilter};

use ffi::ProcVnodePathInfo;

// ---------------------------------------------------------------------------
// Project registry
// ---------------------------------------------------------------------------

/// A registered project, with its hostname already resolved against the TLD.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProjectEntry {
    pub name: String,
    pub hostname: String,
    /// Route only this port (from `.localport.toml` or the app's settings).
    pub port: Option<u16>,
    /// Claim `port` for this project whatever process listens on it — for
    /// servers running outside the project directory (Docker, a shared dev
    /// server). Takes precedence over tags and the cwd heuristic.
    pub claim: bool,
}

impl ProjectEntry {
    /// An entry with the default hostname `<name>.<tld>` and no pinned port.
    pub fn new(name: &str, tld: &str) -> Self {
        Self {
            name: name.to_string(),
            hostname: format!("{name}.{tld}"),
            port: None,
            claim: false,
        }
    }
}

/// Registry of known project directories.
///
/// Keyed by the *canonical* directory, because process working directories
/// come back from the kernel with symlinks resolved (`/tmp` → `/private/tmp`,
/// a symlinked `~/code`, …). The path as registered is kept for display and
/// for matching removal requests.
#[derive(Debug, Default)]
pub struct ProjectRegistry {
    projects: HashMap<PathBuf, (PathBuf, ProjectEntry)>,
}

/// Resolve symlinks; fall back to the path as given if it doesn't exist.
fn canonical(dir: &Path) -> PathBuf {
    std::fs::canonicalize(dir).unwrap_or_else(|_| dir.to_path_buf())
}

impl ProjectRegistry {
    pub fn register(&mut self, directory: PathBuf, entry: ProjectEntry) {
        tracing::info!(
            "registered project '{}' ({}) at {}",
            entry.name,
            entry.hostname,
            directory.display()
        );
        self.projects
            .insert(canonical(&directory), (directory, entry));
    }

    pub fn unregister(&mut self, directory: &Path) -> Option<ProjectEntry> {
        let key = canonical(directory);
        let key = if self.projects.contains_key(&key) {
            key
        } else {
            // The directory may have been deleted or re-linked since it was
            // registered; match on the path as registered instead.
            self.projects
                .iter()
                .find(|(_, (registered, _))| registered == directory)
                .map(|(k, _)| k.clone())?
        };
        self.projects.remove(&key).map(|(_, entry)| entry)
    }

    /// Find which project owns the given directory.
    ///
    /// When multiple registered directories match (e.g. `/a/b` and `/a/b/c`
    /// both match a CWD of `/a/b/c/src`), the **most specific** (longest path)
    /// wins. This lets monorepo sub-apps override the parent project.
    pub fn find_project_for_dir(&self, dir: &Path) -> Option<&ProjectEntry> {
        self.projects
            .iter()
            .filter(|(project_dir, _)| dir.starts_with(project_dir))
            .max_by_key(|(project_dir, _)| project_dir.as_os_str().len())
            .map(|(_, (_, entry))| entry)
    }

    /// Find a registered project by name (used to apply a registered
    /// project's hostname/port overrides to a `localport run` tag).
    pub fn find_by_name(&self, name: &str) -> Option<&ProjectEntry> {
        self.projects
            .values()
            .map(|(_, e)| e)
            .find(|e| e.name == name)
    }

    /// The project that has claimed `port`, if any.
    pub fn find_claim(&self, port: u16) -> Option<&ProjectEntry> {
        self.projects
            .values()
            .map(|(_, e)| e)
            .find(|e| e.claim && e.port == Some(port))
    }

    /// `(directory as registered, entry)` for every project.
    pub fn list(&self) -> Vec<(PathBuf, ProjectEntry)> {
        self.projects.values().cloned().collect()
    }
}

// ---------------------------------------------------------------------------
// Snapshot published for IPC
// ---------------------------------------------------------------------------

/// What the watcher saw on its last scan, for `project.status`.
#[derive(Debug, Clone, Default)]
pub struct WatchSnapshot {
    /// hostname -> the process serving it.
    pub owners: HashMap<String, RouteOwner>,
    /// Likely dev servers that no project claims.
    pub unclaimed: Vec<UnclaimedPort>,
}

/// The process behind a route.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct RouteOwner {
    pub pid: u32,
    /// Executable name, e.g. `node`.
    pub process: Option<String>,
    /// How the listener was attributed: `"claim"`, `"tag"` or `"cwd"`.
    pub source: &'static str,
}

/// A listener no project claims, offered in the app as "Add as Project" /
/// "Assign to Project".
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct UnclaimedPort {
    pub port: u16,
    pub upstream: String,
    pub pid: u32,
    pub process: Option<String>,
    pub cwd: Option<String>,
}

// ---------------------------------------------------------------------------
// Port watcher
// ---------------------------------------------------------------------------

/// Watches for TCP listeners on the system and maps them to registered projects.
pub struct PortWatcher {
    router: Arc<RwLock<Router>>,
    projects: Arc<RwLock<ProjectRegistry>>,
    tld: String,
    interval: Duration,
    /// Notified when the registry changes so we scan immediately instead of
    /// waiting for the next tick.
    scan_notify: Arc<Notify>,
    /// Ports that belong to LocalPort itself (Caddy) and must never be routed.
    excluded_ports: HashSet<u16>,
    snapshot: Arc<RwLock<WatchSnapshot>>,
}

/// Mutable state carried between scans.
#[derive(Default)]
struct ScanState {
    /// Routes this watcher has installed in the router: hostname -> upstream.
    owned: HashMap<String, SocketAddr>,
    /// Attribution inputs per process. A process's environment is frozen at
    /// exec, so the tag never changes for a given process; caching it (and the
    /// cwd) avoids re-reading every unattributed listener every tick.
    procs: HashMap<ProcKey, ProcInputs>,
}

/// Identifies a process instance: pid plus start time, so a recycled pid is
/// never mistaken for the process that used to hold it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
struct ProcKey {
    pid: u32,
    started_us: u64,
}

#[derive(Debug, Clone, Default)]
struct ProcInputs {
    tag: Option<String>,
    cwd: Option<PathBuf>,
    exe: Option<PathBuf>,
}

/// A listening TCP socket as discovered from the OS.
#[derive(Debug, Clone)]
struct ListeningSocket {
    proc: ProcKey,
    port: u16,
    /// The address a proxy should dial to reach this socket.
    ip: IpAddr,
}

impl PortWatcher {
    pub fn new(
        router: Arc<RwLock<Router>>,
        projects: Arc<RwLock<ProjectRegistry>>,
        tld: String,
        scan_notify: Arc<Notify>,
        excluded_ports: HashSet<u16>,
        snapshot: Arc<RwLock<WatchSnapshot>>,
    ) -> Self {
        Self {
            router,
            projects,
            tld,
            interval: Duration::from_secs(2),
            scan_notify,
            excluded_ports,
            snapshot,
        }
    }

    pub async fn run(&self, mut shutdown: tokio::sync::watch::Receiver<bool>) {
        let mut ticker = interval(self.interval);
        let mut state = ScanState::default();

        loop {
            tokio::select! {
                _ = ticker.tick() => {}
                _ = self.scan_notify.notified() => {
                    tracing::debug!("immediate scan triggered (registry changed)");
                }
                _ = shutdown.changed() => {
                    tracing::info!("port watcher shutting down");
                    break;
                }
            }
            if let Err(e) = self.scan(&mut state).await {
                tracing::debug!("port scan error: {}", e);
            }
        }
    }

    async fn scan(&self, state: &mut ScanState) -> anyhow::Result<()> {
        // Discovery and the per-process reads are blocking syscalls; do them
        // all in one blocking task, reading inputs only for processes we have
        // not seen before.
        let excluded = self.excluded_ports.clone();
        let known: HashSet<ProcKey> = state.procs.keys().copied().collect();
        let (sockets, fresh) = tokio::task::spawn_blocking(move || {
            let sockets: Vec<ListeningSocket> = discover_listeners_blocking()?
                .into_iter()
                .filter(|s| !excluded.contains(&s.port))
                .collect();
            let mut fresh = HashMap::new();
            for s in &sockets {
                if !known.contains(&s.proc) && !fresh.contains_key(&s.proc) {
                    fresh.insert(s.proc, read_proc_inputs(s.proc.pid));
                }
            }
            anyhow::Ok((sockets, fresh))
        })
        .await??;

        state.procs.extend(fresh);
        let live: HashSet<ProcKey> = sockets.iter().map(|s| s.proc).collect();
        state.procs.retain(|k, _| live.contains(k));

        let listeners: Vec<ListenerInfo> = sockets
            .iter()
            .map(|s| {
                let inputs = state.procs.get(&s.proc).cloned().unwrap_or_default();
                ListenerInfo {
                    port: s.port,
                    pid: s.proc.pid,
                    ip: s.ip,
                    tag: inputs.tag,
                    cwd: inputs.cwd,
                    exe: inputs.exe,
                }
            })
            .collect();

        let (plan, snapshot) = {
            let registry = self.projects.read().await;
            let plan = reconcile(&listeners, &state.owned, &registry, &self.tld);
            let snapshot = (!is_transient_empty(&listeners, &state.owned))
                .then(|| snapshot(&listeners, &registry, &self.tld));
            (plan, snapshot)
        };
        if let Some(snapshot) = snapshot {
            *self.snapshot.write().await = snapshot;
        }

        if plan.add.is_empty() && plan.remove.is_empty() {
            return Ok(());
        }

        let mut router = self.router.write().await;
        for hostname in plan.remove {
            tracing::info!("removing route {hostname} (no longer listening)");
            router.remove_route(&hostname);
            state.owned.remove(&hostname);
        }
        for add in plan.add {
            tracing::info!(
                "routing {} -> {} (pid={}, {})",
                add.hostname,
                add.addr,
                add.pid,
                add.source
            );
            router.add_route(add.hostname.clone(), add.addr);
            state.owned.insert(add.hostname, add.addr);
        }

        Ok(())
    }
}

// ---------------------------------------------------------------------------
// libproc-based listener discovery
// ---------------------------------------------------------------------------

// `insi_vflag` bits from Darwin's bsd/sys/proc_info.h.
const INI_IPV4: u8 = 0x1;
const INI_IPV6: u8 = 0x2;

/// Discover all listening TCP sockets using macOS `libproc` APIs:
///   1. Enumerate all PIDs
///   2. For each PID, list its file descriptors
///   3. For socket FDs, query TCP socket info
///   4. Collect those in LISTEN state with their local address and port
fn discover_listeners_blocking() -> anyhow::Result<Vec<ListeningSocket>> {
    let pids =
        pids_by_type(ProcFilter::All).map_err(|e| anyhow::anyhow!("pids_by_type failed: {e}"))?;

    let mut listeners = Vec::new();

    for pid in pids {
        let pid_i32 = pid as i32;

        // Task info gives the FD count and the start time (for ProcKey).
        let (nfiles, started_us) = match pidinfo::<TaskAllInfo>(pid_i32, 0) {
            Ok(info) => (
                info.pbsd.pbi_nfiles as usize,
                info.pbsd.pbi_start_tvsec * 1_000_000 + info.pbsd.pbi_start_tvusec,
            ),
            Err(_) => continue, // no permission or process already exited
        };

        if nfiles == 0 {
            continue;
        }

        let fds = match listpidinfo::<ListFDs>(pid_i32, nfiles) {
            Ok(fds) => fds,
            Err(_) => continue,
        };

        for fd in &fds {
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

            let ini = tcp_info.tcpsi_ini;
            // Local port is stored in network byte order in the lower 16 bits.
            let port = u16::from_be(ini.insi_lport as u16);
            if port == 0 {
                continue;
            }

            // Safety: insi_vflag says which union variant holds the address.
            let ip = if ini.insi_vflag & INI_IPV4 != 0 {
                let raw = unsafe { ini.insi_laddr.ina_46.i46a_addr4.s_addr };
                Some(IpAddr::V4(Ipv4Addr::from(u32::from_be(raw))))
            } else if ini.insi_vflag & INI_IPV6 != 0 {
                let raw = unsafe { ini.insi_laddr.ina_6.s6_addr };
                Some(IpAddr::V6(Ipv6Addr::from(raw)))
            } else {
                None
            };

            if let Some(ip) = ip {
                listeners.push(ListeningSocket {
                    proc: ProcKey { pid, started_us },
                    port,
                    ip: dial_addr(ip),
                });
            }
        }
    }

    tracing::trace!("discovered {} listening sockets", listeners.len());
    Ok(listeners)
}

/// The address to dial for a socket bound to `bound`. Wildcard binds are
/// reachable on loopback of the same family; specific binds (`::1`,
/// `127.0.0.1`, a LAN IP) must be dialled at exactly that address — Node binds
/// `localhost` to `::1` only, so assuming `127.0.0.1` would be unreachable.
fn dial_addr(bound: IpAddr) -> IpAddr {
    match bound {
        IpAddr::V4(v4) if v4.is_unspecified() => IpAddr::V4(Ipv4Addr::LOCALHOST),
        IpAddr::V6(v6) if v6.is_unspecified() => IpAddr::V6(Ipv6Addr::LOCALHOST),
        IpAddr::V6(v6) => match v6.to_ipv4_mapped() {
            Some(v4) => dial_addr(IpAddr::V4(v4)),
            None => IpAddr::V6(v6),
        },
        other => other,
    }
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

/// How a listener was attributed to its project.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Source {
    /// The user assigned this port to the project.
    Claim,
    /// `LOCALPORT_PROJECT` tag from `localport run`.
    Tag,
    /// The process's working directory is inside the project.
    Cwd(PathBuf),
}

impl Source {
    fn kind(&self) -> &'static str {
        match self {
            Source::Claim => "claim",
            Source::Tag => "tag",
            Source::Cwd(_) => "cwd",
        }
    }
}

impl std::fmt::Display for Source {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Source::Cwd(c) => write!(f, "cwd={}", c.display()),
            other => f.write_str(other.kind()),
        }
    }
}

/// Decide which project a listening process belongs to.
///
/// 1. **Claim:** a project that claimed this port gets it, whoever listens.
/// 2. **Tag (ground truth):** a valid `LOCALPORT_PROJECT` tag names the project
///    directly — no registration and no cwd match required. If a project with
///    that name *is* registered, its hostname and port overrides apply.
/// 3. **Cwd heuristic:** the most specific registered directory containing
///    the process's working directory.
fn attribute_project(
    port: u16,
    tag: Option<&str>,
    cwd: Option<&Path>,
    registry: &ProjectRegistry,
    tld: &str,
) -> Option<(ProjectEntry, Source)> {
    if let Some(entry) = registry.find_claim(port) {
        return Some((entry.clone(), Source::Claim));
    }
    if let Some(name) = resolve_tag(tag) {
        let entry = registry
            .find_by_name(&name)
            .cloned()
            .unwrap_or_else(|| ProjectEntry::new(&name, tld));
        return Some((entry, Source::Tag));
    }
    let cwd = cwd?;
    let entry = registry.find_project_for_dir(cwd)?.clone();
    Some((entry, Source::Cwd(cwd.to_path_buf())))
}

/// Read a process's attribution inputs: its `LOCALPORT_PROJECT` tag (via the
/// portable [`proc_env`] seam) and its working directory.
fn read_proc_inputs(pid: u32) -> ProcInputs {
    ProcInputs {
        tag: proc_env::get_pid_env_var(pid, localport_core::PROJECT_ENV_VAR),
        cwd: get_pid_cwd_blocking(pid),
        exe: pidpath(pid as i32).ok().map(PathBuf::from),
    }
}

/// A single listener with the inputs `reconcile` needs to attribute it.
/// `scan` fills `tag`/`cwd` from the system; tests construct these directly so
/// routing decisions are tested without binding real ports.
#[derive(Debug, Clone)]
struct ListenerInfo {
    port: u16,
    pid: u32,
    ip: IpAddr,
    tag: Option<String>,
    cwd: Option<PathBuf>,
    exe: Option<PathBuf>,
}

impl ListenerInfo {
    fn process_name(&self) -> Option<String> {
        self.exe
            .as_deref()
            .and_then(|e| e.file_name())
            .map(|n| n.to_string_lossy().into_owned())
    }
}

/// A route to add, carrying enough context to log how it was attributed.
#[derive(Debug, PartialEq, Eq)]
struct RouteAdd {
    hostname: String,
    addr: SocketAddr,
    pid: u32,
    /// `"tag"` or `"cwd=<path>"` — for logging only.
    source: String,
}

/// The route changes a single scan should apply.
#[derive(Debug, Default, PartialEq, Eq)]
struct RoutePlan {
    /// Routes to add or re-point at a different upstream.
    add: Vec<RouteAdd>,
    /// Hostnames whose route should be removed.
    remove: Vec<String>,
}

/// Ranking for choosing which of a project's listeners gets its hostname.
/// Lower is better: ordinary ports first, then debugger and ephemeral ports
/// (Node's `--inspect`, Next.js/Vite internal workers), lowest port first
/// within each group, IPv4 before IPv6 for the same port.
fn port_rank(l: &ListenerInfo) -> (bool, u16, bool) {
    (is_secondary_port(l.port), l.port, l.ip.is_ipv6())
}

/// Node inspector and ephemeral-range ports: rarely the server you browse to.
fn is_secondary_port(port: u16) -> bool {
    (9229..=9230).contains(&port) || port >= 49152
}

/// An empty listener list while routes are active is almost always a
/// failed/permission-denied enumeration, not "everything stopped at once".
fn is_transient_empty(listeners: &[ListenerInfo], owned: &HashMap<String, SocketAddr>) -> bool {
    listeners.is_empty() && !owned.is_empty()
}

/// The best listener per hostname, with how it was attributed.
fn desired_routes<'a>(
    listeners: &'a [ListenerInfo],
    registry: &ProjectRegistry,
    tld: &str,
) -> BTreeMap<String, (&'a ListenerInfo, Source)> {
    let mut desired: BTreeMap<String, (&ListenerInfo, Source)> = BTreeMap::new();
    for info in listeners {
        let Some((entry, source)) = attribute_project(
            info.port,
            info.tag.as_deref(),
            info.cwd.as_deref(),
            registry,
            tld,
        ) else {
            continue;
        };
        if entry.port.is_some_and(|p| p != info.port) {
            continue; // project pins a different port
        }
        match desired.get(&entry.hostname) {
            Some((best, _)) if port_rank(best) <= port_rank(info) => {}
            _ => {
                desired.insert(entry.hostname, (info, source));
            }
        }
    }
    desired
}

/// Decide which routes to add and remove, given the currently listening
/// sockets, the routes this watcher already owns, and the project registry.
///
/// This is the heart of the watcher, and it is **pure** — no syscalls, no
/// locks, no I/O. It computes the full desired state (one upstream per
/// hostname) and diffs it against what is installed, so registry changes,
/// multiple listeners per project and listeners going away are all handled
/// the same way.
fn reconcile(
    listeners: &[ListenerInfo],
    owned: &HashMap<String, SocketAddr>,
    registry: &ProjectRegistry,
    tld: &str,
) -> RoutePlan {
    let mut plan = RoutePlan::default();

    // Transient-failure guard: don't tear down routes based on an empty scan.
    if is_transient_empty(listeners, owned) {
        return plan;
    }

    let desired = desired_routes(listeners, registry, tld);

    for (hostname, (info, source)) in &desired {
        let addr = SocketAddr::new(info.ip, info.port);
        if owned.get(hostname) != Some(&addr) {
            plan.add.push(RouteAdd {
                hostname: hostname.clone(),
                addr,
                pid: info.pid,
                source: source.to_string(),
            });
        }
    }

    let mut stale: Vec<String> = owned
        .keys()
        .filter(|h| !desired.contains_key(*h))
        .cloned()
        .collect();
    stale.sort();
    plan.remove = stale;

    plan
}

/// Executables that are part of macOS, whose listeners (AirPlay, sharing,
/// …) are never dev servers.
fn is_system_executable(exe: &Path) -> bool {
    [
        "/System/",
        "/usr/libexec/",
        "/usr/sbin/",
        "/usr/bin/",
        "/sbin/",
        "/bin/",
        "/Library/Apple/",
    ]
    .iter()
    .any(|prefix| exe.starts_with(prefix))
}

/// Who serves each route, plus the listeners no project claims that look like
/// dev servers. Skipped: macOS system processes, privileged ports (system
/// services and VPN extensions), debugger/ephemeral ports, and sockets bound
/// to one specific non-loopback address (VPN/LAN interfaces — dev servers
/// bind loopback or all interfaces). Pure, like [`reconcile`].
fn snapshot(listeners: &[ListenerInfo], registry: &ProjectRegistry, tld: &str) -> WatchSnapshot {
    let owners = desired_routes(listeners, registry, tld)
        .into_iter()
        .map(|(hostname, (info, source))| {
            let owner = RouteOwner {
                pid: info.pid,
                process: info.process_name(),
                source: source.kind(),
            };
            (hostname, owner)
        })
        .collect();

    let mut best: BTreeMap<u16, &ListenerInfo> = BTreeMap::new();
    for info in listeners {
        let attributed = attribute_project(
            info.port,
            info.tag.as_deref(),
            info.cwd.as_deref(),
            registry,
            tld,
        )
        .is_some();
        if attributed
            || info.port < 1024
            || !info.ip.is_loopback()
            || is_secondary_port(info.port)
            || info.exe.as_deref().is_some_and(is_system_executable)
        {
            continue;
        }
        match best.get(&info.port) {
            Some(b) if port_rank(b) <= port_rank(info) => {}
            _ => {
                best.insert(info.port, info);
            }
        }
    }
    let unclaimed = best
        .into_values()
        .map(|info| UnclaimedPort {
            port: info.port,
            upstream: SocketAddr::new(info.ip, info.port).to_string(),
            pid: info.pid,
            process: info.process_name(),
            cwd: info
                .cwd
                .as_deref()
                .map(|c| c.to_string_lossy().into_owned()),
        })
        .collect();

    WatchSnapshot { owners, unclaimed }
}

// ---------------------------------------------------------------------------
// libproc-based CWD lookup
// ---------------------------------------------------------------------------

/// Get the working directory of a process by PID using `proc_pidinfo`
/// with `PROC_PIDVNODEPATHINFO`.
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
