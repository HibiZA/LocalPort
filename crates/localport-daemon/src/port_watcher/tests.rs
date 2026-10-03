use super::*;
use std::net::TcpListener;

fn entry(name: &str) -> ProjectEntry {
    ProjectEntry::new(name, "test")
}

// -- ProjectRegistry tests ---------------------------------------------------

#[test]
fn test_registry_register_and_find() {
    let mut reg = ProjectRegistry::default();
    reg.register(PathBuf::from("/Users/me/projects/my-app"), entry("my-app"));

    assert_eq!(
        reg.find_project_for_dir(std::path::Path::new("/Users/me/projects/my-app")),
        Some(&entry("my-app"))
    );
}

#[test]
fn test_registry_find_subdirectory() {
    let mut reg = ProjectRegistry::default();
    reg.register(PathBuf::from("/Users/me/projects/my-app"), entry("my-app"));

    assert_eq!(
        reg.find_project_for_dir(std::path::Path::new("/Users/me/projects/my-app/src")),
        Some(&entry("my-app"))
    );
}

#[test]
fn test_registry_no_match() {
    let mut reg = ProjectRegistry::default();
    reg.register(PathBuf::from("/Users/me/projects/my-app"), entry("my-app"));

    assert_eq!(
        reg.find_project_for_dir(std::path::Path::new("/Users/me/projects/other-app")),
        None
    );
}

#[test]
fn test_registry_list() {
    let mut reg = ProjectRegistry::default();
    reg.register(PathBuf::from("/a"), entry("alpha"));
    reg.register(PathBuf::from("/b"), entry("beta"));

    let list = reg.list();
    assert_eq!(list.len(), 2);
}

// -- discover_listeners tests ------------------------------------------------

#[test]
fn test_discover_listeners_finds_bound_port() {
    let listener = TcpListener::bind("127.0.0.1:0").expect("failed to bind");
    let expected_port = listener.local_addr().unwrap().port();
    let our_pid = std::process::id();

    let listeners = discover_listeners_blocking().unwrap();

    let found = listeners.iter().any(|l| {
        l.proc.pid == our_pid && l.port == expected_port && l.ip == IpAddr::V4(Ipv4Addr::LOCALHOST)
    });

    assert!(
        found,
        "expected to find pid={} port={} in listeners, got: {:?}",
        our_pid, expected_port, listeners
    );

    drop(listener);
}

#[test]
fn test_discover_listeners_does_not_find_closed_port() {
    let listener = TcpListener::bind("127.0.0.1:0").expect("failed to bind");
    let closed_port = listener.local_addr().unwrap().port();
    drop(listener);

    let our_pid = std::process::id();
    let listeners = discover_listeners_blocking().unwrap();

    let found = listeners
        .iter()
        .any(|l| l.proc.pid == our_pid && l.port == closed_port);

    assert!(
        !found,
        "should NOT find closed port {} in listeners",
        closed_port
    );
}

// -- get_pid_cwd tests -------------------------------------------------------

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
    assert_eq!(
        cwd, env_cwd,
        "libproc CWD should match std::env::current_dir()"
    );
}

#[test]
fn test_get_pid_cwd_invalid_pid() {
    let cwd = get_pid_cwd_blocking(999_999_999);
    assert!(cwd.is_none(), "invalid PID should return None");
}

// -- FFI struct layout sanity checks -----------------------------------------

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
    assert_eq!(std::mem::size_of::<ffi::VInfoStat>(), 136);
    assert_eq!(std::mem::size_of::<ffi::VnodeInfo>(), 152);
    assert_eq!(std::mem::size_of::<ffi::VnodeInfoPath>(), 1176);
    assert_eq!(std::mem::size_of::<ffi::ProcVnodePathInfo>(), 2352);
}

#[test]
fn test_discover_listeners_reports_ipv6_loopback() {
    // Node binds `localhost` to ::1 only; the watcher must report ::1 so the
    // proxy dials an address the server actually listens on.
    let Ok(listener) = TcpListener::bind("[::1]:0") else {
        return; // no IPv6 loopback on this machine
    };
    let port = listener.local_addr().unwrap().port();
    let listeners = discover_listeners_blocking().unwrap();
    assert!(
        listeners.iter().any(|l| l.proc.pid == std::process::id()
            && l.port == port
            && l.ip == IpAddr::V6(Ipv6Addr::LOCALHOST)),
        "expected [::1]:{port} in {listeners:?}"
    );
}

#[test]
fn test_dial_addr() {
    let v4 = |s: &str| s.parse::<IpAddr>().unwrap();
    assert_eq!(dial_addr(v4("0.0.0.0")), v4("127.0.0.1"));
    assert_eq!(dial_addr(v4("127.0.0.1")), v4("127.0.0.1"));
    assert_eq!(dial_addr(v4("::")), v4("::1"));
    assert_eq!(dial_addr(v4("::1")), v4("::1"));
    assert_eq!(dial_addr(v4("::ffff:127.0.0.1")), v4("127.0.0.1"));
    assert_eq!(dial_addr(v4("192.168.1.5")), v4("192.168.1.5"));
}

// -- reconcile: pure routing decisions (deterministic, no real ports) --------

fn info(port: u16, tag: Option<&str>, cwd: Option<&str>) -> ListenerInfo {
    ListenerInfo {
        port,
        pid: port as u32,
        ip: IpAddr::V4(Ipv4Addr::LOCALHOST),
        tag: tag.map(String::from),
        cwd: cwd.map(PathBuf::from),
        exe: Some(PathBuf::from("/opt/homebrew/bin/node")),
    }
}

fn info_v6(port: u16, cwd: &str) -> ListenerInfo {
    ListenerInfo {
        ip: IpAddr::V6(Ipv6Addr::LOCALHOST),
        ..info(port, None, Some(cwd))
    }
}

fn reg_with(projects: &[(&str, &str)]) -> ProjectRegistry {
    let mut reg = ProjectRegistry::default();
    for (dir, name) in projects {
        reg.register(PathBuf::from(dir), entry(name));
    }
    reg
}

fn owned(routes: &[(&str, &str)]) -> HashMap<String, SocketAddr> {
    routes
        .iter()
        .map(|(h, a)| (h.to_string(), a.parse().unwrap()))
        .collect()
}

#[test]
fn test_reconcile_routes_listener_in_project_dir() {
    let reg = reg_with(&[("/Users/me/api", "api")]);
    let listeners = vec![info(3000, None, Some("/Users/me/api/src"))];
    let plan = reconcile(&listeners, &HashMap::new(), &reg, "test");

    assert_eq!(plan.add.len(), 1);
    assert_eq!(plan.add[0].hostname, "api.test");
    assert_eq!(plan.add[0].addr, "127.0.0.1:3000".parse().unwrap());
    assert!(plan.add[0].source.starts_with("cwd="));
    assert!(plan.remove.is_empty());
}

#[test]
fn test_reconcile_routes_ipv6_only_listener_to_ipv6() {
    let reg = reg_with(&[("/Users/me/web", "web")]);
    let plan = reconcile(
        &[info_v6(5173, "/Users/me/web")],
        &HashMap::new(),
        &reg,
        "test",
    );
    assert_eq!(plan.add[0].addr, "[::1]:5173".parse().unwrap());
}

#[test]
fn test_reconcile_prefers_ipv4_when_both_families_listen() {
    let reg = reg_with(&[("/Users/me/web", "web")]);
    let listeners = vec![
        info_v6(5173, "/Users/me/web"),
        info(5173, None, Some("/Users/me/web")),
    ];
    let plan = reconcile(&listeners, &HashMap::new(), &reg, "test");
    assert_eq!(plan.add.len(), 1);
    assert_eq!(plan.add[0].addr, "127.0.0.1:5173".parse().unwrap());
}

#[test]
fn test_reconcile_routes_tagged_listener_without_registration() {
    // Ground truth: a tag routes even with an empty registry and a cwd that
    // matches nothing.
    let reg = ProjectRegistry::default();
    let listeners = vec![info(5173, Some("web"), Some("/tmp/anywhere"))];
    let plan = reconcile(&listeners, &HashMap::new(), &reg, "test");

    assert_eq!(plan.add.len(), 1);
    assert_eq!(plan.add[0].hostname, "web.test");
    assert_eq!(plan.add[0].source, "tag");
}

#[test]
fn test_reconcile_tag_overrides_cwd() {
    // cwd would map to "monorepo", but the explicit tag wins.
    let reg = reg_with(&[("/Users/me/monorepo", "monorepo")]);
    let listeners = vec![info(4000, Some("web"), Some("/Users/me/monorepo"))];
    let plan = reconcile(&listeners, &HashMap::new(), &reg, "test");

    assert_eq!(plan.add.len(), 1);
    assert_eq!(plan.add[0].hostname, "web.test");
    assert_eq!(plan.add[0].source, "tag");
}

#[test]
fn test_reconcile_ignores_unmatched_listener() {
    let reg = reg_with(&[("/Users/me/api", "api")]);
    let listeners = vec![info(6000, None, Some("/Users/me/elsewhere"))];
    let plan = reconcile(&listeners, &HashMap::new(), &reg, "test");
    assert_eq!(plan, RoutePlan::default());
}

#[test]
fn test_reconcile_leaves_unchanged_route_alone() {
    let reg = reg_with(&[("/Users/me/api", "api")]);
    let listeners = vec![info(3000, None, Some("/Users/me/api"))];
    let current = owned(&[("api.test", "127.0.0.1:3000")]);
    let plan = reconcile(&listeners, &current, &reg, "test");
    assert_eq!(plan, RoutePlan::default());
}

#[test]
fn test_reconcile_removes_stale_route() {
    // api.test is routed but nothing for it is listening, while another port
    // IS listening (so this is a real scan, not the transient-empty case).
    let reg = ProjectRegistry::default();
    let listeners = vec![info(8080, None, Some("/tmp/x"))];
    let current = owned(&[("api.test", "127.0.0.1:3000")]);

    let plan = reconcile(&listeners, &current, &reg, "test");
    assert_eq!(plan.remove, vec!["api.test".to_string()]);
    assert!(plan.add.is_empty());
}

#[test]
fn test_reconcile_empty_listeners_keeps_active_routes() {
    // Transient-failure guard: a 0-listener scan must NOT remove live routes.
    let reg = ProjectRegistry::default();
    let current = owned(&[("api.test", "127.0.0.1:3000")]);
    let plan = reconcile(&[], &current, &reg, "test");
    assert_eq!(plan, RoutePlan::default(), "empty scan must be a no-op");
}

#[test]
fn test_reconcile_no_routes_when_empty_registry_and_no_tags() {
    let reg = ProjectRegistry::default();
    let listeners = vec![info(3000, None, Some("/tmp/a")), info(3001, None, None)];
    let plan = reconcile(&listeners, &HashMap::new(), &reg, "test");
    assert_eq!(plan, RoutePlan::default());
}

#[test]
fn test_reconcile_project_registered_after_listener() {
    // "User adds a project while the server is already running": the same
    // listener yields no route before registration and a route after.
    let listeners = vec![info(3000, None, Some("/Users/me/late/src"))];

    let before = reconcile(
        &listeners,
        &HashMap::new(),
        &ProjectRegistry::default(),
        "test",
    );
    assert!(before.add.is_empty());

    let reg = reg_with(&[("/Users/me/late", "late")]);
    let after = reconcile(&listeners, &HashMap::new(), &reg, "test");
    assert_eq!(after.add.len(), 1);
    assert_eq!(after.add[0].hostname, "late.test");
}

#[test]
fn test_reconcile_moves_route_when_more_specific_project_registered() {
    // The parent owned the port; once the sub-app is registered the parent's
    // route goes away and the sub-app's appears — in a single plan, without
    // tearing down unrelated routes.
    let reg = reg_with(&[
        ("/Users/me/monorepo", "monorepo"),
        ("/Users/me/monorepo/apps/web", "web"),
        ("/Users/me/other", "other"),
    ]);
    let listeners = vec![
        info(3000, None, Some("/Users/me/monorepo/apps/web")),
        info(4000, None, Some("/Users/me/other")),
    ];
    let current = owned(&[
        ("monorepo.test", "127.0.0.1:3000"),
        ("other.test", "127.0.0.1:4000"),
    ]);
    let plan = reconcile(&listeners, &current, &reg, "test");
    assert_eq!(plan.add.len(), 1);
    assert_eq!(plan.add[0].hostname, "web.test");
    assert_eq!(plan.remove, vec!["monorepo.test".to_string()]);
}

#[test]
fn test_reconcile_one_route_per_project_lowest_port_wins() {
    let reg = reg_with(&[("/Users/me/app", "app")]);
    let listeners = vec![
        info(6006, None, Some("/Users/me/app")),
        info(3000, None, Some("/Users/me/app")),
        info(5555, None, Some("/Users/me/app")),
    ];
    let plan = reconcile(&listeners, &HashMap::new(), &reg, "test");
    assert_eq!(plan.add.len(), 1);
    assert_eq!(plan.add[0].addr, "127.0.0.1:3000".parse().unwrap());
}

#[test]
fn test_reconcile_deprioritizes_inspector_and_ephemeral_ports() {
    let reg = reg_with(&[("/Users/me/app", "app")]);
    let listeners = vec![
        info(9229, None, Some("/Users/me/app")),
        info(61234, None, Some("/Users/me/app")),
        info(31337, None, Some("/Users/me/app")),
    ];
    let plan = reconcile(&listeners, &HashMap::new(), &reg, "test");
    assert_eq!(plan.add[0].addr, "127.0.0.1:31337".parse().unwrap());

    // But a project with only an ephemeral listener still gets routed.
    let plan = reconcile(&listeners[1..2], &HashMap::new(), &reg, "test");
    assert_eq!(plan.add[0].addr, "127.0.0.1:61234".parse().unwrap());
}

#[test]
fn test_reconcile_secondary_listener_exit_keeps_route() {
    // Regression: with two listeners in one project, the secondary one exiting
    // must not delete the project's route.
    let reg = reg_with(&[("/Users/me/app", "app")]);
    let current = owned(&[("app.test", "127.0.0.1:3000")]);
    let listeners = vec![info(3000, None, Some("/Users/me/app"))];
    let plan = reconcile(&listeners, &current, &reg, "test");
    assert_eq!(plan, RoutePlan::default());
}

#[test]
fn test_reconcile_falls_back_when_primary_listener_exits() {
    let reg = reg_with(&[("/Users/me/app", "app")]);
    let current = owned(&[("app.test", "127.0.0.1:3000")]);
    let listeners = vec![info(6006, None, Some("/Users/me/app"))];
    let plan = reconcile(&listeners, &current, &reg, "test");
    assert_eq!(plan.add.len(), 1);
    assert_eq!(plan.add[0].addr, "127.0.0.1:6006".parse().unwrap());
    assert!(plan.remove.is_empty());
}

#[test]
fn test_reconcile_pinned_port() {
    let mut reg = ProjectRegistry::default();
    reg.register(
        PathBuf::from("/Users/me/app"),
        ProjectEntry {
            port: Some(5173),
            ..entry("app")
        },
    );
    let listeners = vec![
        info(3000, None, Some("/Users/me/app")),
        info(5173, None, Some("/Users/me/app")),
    ];
    let plan = reconcile(&listeners, &HashMap::new(), &reg, "test");
    assert_eq!(plan.add.len(), 1);
    assert_eq!(plan.add[0].addr, "127.0.0.1:5173".parse().unwrap());

    // Pinned port not listening: no route, even though 3000 is up.
    let plan = reconcile(&listeners[..1], &HashMap::new(), &reg, "test");
    assert!(plan.add.is_empty());
}

#[test]
fn test_reconcile_uses_hostname_override() {
    let mut reg = ProjectRegistry::default();
    reg.register(
        PathBuf::from("/Users/me/app"),
        ProjectEntry {
            hostname: "custom.test".into(),
            ..entry("app")
        },
    );
    let plan = reconcile(
        &[info(3000, None, Some("/Users/me/app"))],
        &HashMap::new(),
        &reg,
        "test",
    );
    assert_eq!(plan.add[0].hostname, "custom.test");

    // A tag naming the registered project picks up its override too.
    let plan = reconcile(
        &[info(4000, Some("app"), None)],
        &HashMap::new(),
        &reg,
        "test",
    );
    assert_eq!(plan.add[0].hostname, "custom.test");
}

#[test]
fn test_reconcile_uses_configured_tld() {
    let mut reg = ProjectRegistry::default();
    reg.register(
        PathBuf::from("/Users/me/api"),
        ProjectEntry::new("api", "localhost"),
    );
    let listeners = vec![
        info(3000, Some("web"), None),
        info(3001, None, Some("/Users/me/api")),
    ];
    let plan = reconcile(&listeners, &HashMap::new(), &reg, "localhost");
    let hosts: Vec<_> = plan.add.iter().map(|a| a.hostname.as_str()).collect();
    assert_eq!(hosts, vec!["api.localhost", "web.localhost"]);
}

// -- Most-specific project matching ------------------------------------------

#[test]
fn test_find_project_prefers_most_specific_dir() {
    let reg = reg_with(&[
        ("/Users/me/monorepo", "monorepo"),
        ("/Users/me/monorepo/apps/admin", "admin"),
        ("/Users/me/monorepo/apps/client", "client"),
    ]);
    let find = |d: &str| {
        reg.find_project_for_dir(Path::new(d))
            .map(|e| e.name.as_str())
    };

    assert_eq!(find("/Users/me/monorepo/apps/admin/src"), Some("admin"));
    assert_eq!(find("/Users/me/monorepo/apps/client"), Some("client"));
    // Something NOT under a sub-app should fall back to the parent
    assert_eq!(find("/Users/me/monorepo/packages/shared"), Some("monorepo"));
}

// -- Project attribution: tag (ground truth) vs cwd (heuristic) --------------

fn attributed(tag: Option<&str>, cwd: Option<&str>, reg: &ProjectRegistry) -> Option<String> {
    let cwd = cwd.map(PathBuf::from);
    attribute_project(3000, tag, cwd.as_deref(), reg, "test").map(|(e, _)| e.name)
}

#[test]
fn test_attribution_tagged_wins_without_registration() {
    let reg = ProjectRegistry::default();
    assert_eq!(
        attributed(Some("web"), Some("/Users/me/anywhere"), &reg),
        Some("web".into())
    );
}

#[test]
fn test_attribution_untagged_falls_back_to_cwd() {
    let reg = reg_with(&[("/Users/me/projects/api", "api")]);
    assert_eq!(
        attributed(None, Some("/Users/me/projects/api/src"), &reg),
        Some("api".into())
    );
}

#[test]
fn test_attribution_tag_overrides_cwd_when_they_disagree() {
    // The monorepo case: cwd is the repo root (registered as "monorepo"), but
    // the server was launched with `localport run --project web`.
    let reg = reg_with(&[("/Users/me/monorepo", "monorepo")]);
    assert_eq!(
        attributed(Some("web"), Some("/Users/me/monorepo"), &reg),
        Some("web".into()),
        "explicit tag must override the cwd-derived project"
    );
}

#[test]
fn test_attribution_tag_is_normalized() {
    let reg = ProjectRegistry::default();
    assert_eq!(
        attributed(Some("My_App"), None, &reg),
        Some("my-app".into())
    );
}

#[test]
fn test_attribution_invalid_tag_falls_back_to_cwd() {
    let reg = reg_with(&[("/Users/me/projects/api", "api")]);
    assert_eq!(
        attributed(Some("has space"), Some("/Users/me/projects/api"), &reg),
        Some("api".into())
    );
}

#[test]
fn test_attribution_none_when_no_tag_and_no_cwd_match() {
    let reg = ProjectRegistry::default();
    assert_eq!(attributed(None, Some("/Users/me/unregistered"), &reg), None);
    assert_eq!(attributed(None, None, &reg), None);
}

#[test]
fn test_resolve_tag_rejects_invalid_labels() {
    assert_eq!(resolve_tag(Some("web")), Some("web".to_string()));
    assert_eq!(resolve_tag(Some("My_App")), Some("my-app".to_string()));
    assert_eq!(resolve_tag(None), None);
    assert_eq!(resolve_tag(Some("")), None);
    assert_eq!(resolve_tag(Some("has space")), None);
    assert_eq!(resolve_tag(Some("UPPER")), Some("upper".to_string()));
}

#[test]
fn test_registry_matches_through_symlinks() {
    // Kernel-reported cwds have symlinks resolved (/tmp -> /private/tmp), so a
    // project registered via a symlinked path must still match.
    let base = std::env::temp_dir().join(format!("lp_symlink_{}", std::process::id()));
    let real = base.join("real");
    let link = base.join("link");
    std::fs::create_dir_all(&real).unwrap();
    let _ = std::os::unix::fs::symlink(&real, &link);

    let mut reg = ProjectRegistry::default();
    reg.register(link.clone(), entry("linked"));
    let cwd = std::fs::canonicalize(&real).unwrap().join("src");
    assert_eq!(
        reg.find_project_for_dir(&cwd).map(|e| e.name.as_str()),
        Some("linked")
    );
    assert_eq!(reg.list()[0].0, link, "list reports the path as registered");
    assert!(reg.unregister(&link).is_some());

    let _ = std::fs::remove_dir_all(&base);
}

// -- Port claims ---------------------------------------------------------------

fn claiming(name: &str, port: u16) -> ProjectEntry {
    ProjectEntry {
        port: Some(port),
        claim: true,
        ..entry(name)
    }
}

#[test]
fn test_claim_routes_listener_outside_project_dir() {
    // e.g. a Docker-published port: the listener's cwd is nowhere near the
    // project, but the user assigned the port to it.
    let mut reg = ProjectRegistry::default();
    reg.register(PathBuf::from("/Users/me/api"), claiming("api", 8000));
    let listeners = vec![info(8000, None, Some("/"))];
    let plan = reconcile(&listeners, &HashMap::new(), &reg, "test");
    assert_eq!(plan.add.len(), 1);
    assert_eq!(plan.add[0].hostname, "api.test");
    assert_eq!(plan.add[0].source, "claim");
}

#[test]
fn test_claim_beats_tag_and_cwd() {
    let mut reg = reg_with(&[("/Users/me/other", "other")]);
    reg.register(PathBuf::from("/Users/me/api"), claiming("api", 8000));
    let listeners = vec![info(8000, Some("web"), Some("/Users/me/other"))];
    let plan = reconcile(&listeners, &HashMap::new(), &reg, "test");
    let hosts: Vec<_> = plan.add.iter().map(|a| a.hostname.as_str()).collect();
    assert_eq!(hosts, vec!["api.test"]);
}

#[test]
fn test_pin_without_claim_does_not_capture_foreign_listener() {
    let mut reg = ProjectRegistry::default();
    reg.register(
        PathBuf::from("/Users/me/api"),
        ProjectEntry {
            port: Some(8000),
            ..entry("api")
        },
    );
    let plan = reconcile(
        &[info(8000, None, Some("/"))],
        &HashMap::new(),
        &reg,
        "test",
    );
    assert!(plan.add.is_empty());
}

// -- Snapshot: route owners and unclaimed ports --------------------------------

#[test]
fn test_snapshot_reports_route_owner() {
    let reg = reg_with(&[("/Users/me/api", "api")]);
    let snap = snapshot(&[info(3000, None, Some("/Users/me/api"))], &reg, "test");
    assert_eq!(
        snap.owners.get("api.test"),
        Some(&RouteOwner {
            pid: 3000,
            process: Some("node".into()),
            source: "cwd",
        })
    );
    assert!(
        snap.unclaimed.is_empty(),
        "attributed listeners aren't unclaimed"
    );
}

#[test]
fn test_snapshot_lists_unclaimed_dev_servers() {
    let reg = reg_with(&[("/Users/me/api", "api")]);
    let listeners = vec![
        info(3000, None, Some("/Users/me/api")), // attributed
        info_v6(5173, "/Users/me/new-app"),      // unclaimed
        info(5173, None, Some("/Users/me/new-app")),
        info(9229, None, Some("/Users/me/new-app")), // inspector: skipped
        info(61000, None, Some("/Users/me/new-app")), // ephemeral: skipped
        ListenerInfo {
            exe: Some(PathBuf::from(
                "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter",
            )),
            ..info(7000, None, Some("/"))
        }, // macOS AirPlay receiver: skipped
        info(443, None, Some("/Users/me")),          // privileged: skipped
        ListenerInfo {
            ip: "100.78.1.2".parse().unwrap(),
            ..info(8443, None, Some("/Users/me"))
        }, // bound to a VPN interface: skipped
    ];
    let snap = snapshot(&listeners, &reg, "test");
    assert_eq!(
        snap.unclaimed,
        vec![UnclaimedPort {
            port: 5173,
            upstream: "127.0.0.1:5173".into(),
            pid: 5173,
            process: Some("node".into()),
            cwd: Some("/Users/me/new-app".into()),
        }]
    );
}

#[test]
fn test_is_system_executable() {
    assert!(is_system_executable(Path::new("/usr/libexec/rapportd")));
    assert!(is_system_executable(Path::new("/System/Library/x")));
    assert!(!is_system_executable(Path::new("/usr/local/bin/node")));
    assert!(!is_system_executable(Path::new("/opt/homebrew/bin/node")));
    assert!(!is_system_executable(Path::new(
        "/Applications/Docker.app/Contents/MacOS/com.docker.backend"
    )));
}

#[test]
fn test_registry_unregister() {
    let mut reg = reg_with(&[("/a", "a")]);
    assert_eq!(reg.unregister(Path::new("/a")), Some(entry("a")));
    assert_eq!(reg.unregister(Path::new("/a")), None);
}

/// The one intentional **real-system** integration test: it binds an actual
/// listener and drives the full `scan` path (live discovery → reconcile →
/// Router), including re-attribution after a registry change. It asserts route
/// *presence by hostname* rather than specific ports, because other tests in
/// this process bind listeners in the same cwd concurrently.
#[tokio::test]
async fn test_scan_re_evaluates_routes_when_more_specific_project_added() {
    let notify = Arc::new(tokio::sync::Notify::new());
    let router = Arc::new(RwLock::new(Router::new(notify)));
    let projects = Arc::new(RwLock::new(ProjectRegistry::default()));
    let cwd = std::env::current_dir().unwrap();

    projects
        .write()
        .await
        .register(cwd.clone(), entry("parent"));

    let watcher = PortWatcher::new(
        router.clone(),
        projects.clone(),
        "test".into(),
        Arc::new(tokio::sync::Notify::new()),
        HashSet::new(),
        Arc::new(RwLock::new(WatchSnapshot::default())),
    );

    let listener = TcpListener::bind("127.0.0.1:0").unwrap();

    let mut state = ScanState::default();
    watcher.scan(&mut state).await.unwrap();
    assert!(state.owned.contains_key("parent.test"));

    // Re-register the same directory under a new name.
    projects.write().await.register(cwd.clone(), entry("child"));
    watcher.scan(&mut state).await.unwrap();

    let hosts: Vec<String> = router
        .read()
        .await
        .list_routes()
        .into_iter()
        .map(|(h, _)| h)
        .collect();
    assert!(hosts.contains(&"child.test".to_string()), "{hosts:?}");
    assert!(!hosts.contains(&"parent.test".to_string()), "{hosts:?}");

    drop(listener);
}
