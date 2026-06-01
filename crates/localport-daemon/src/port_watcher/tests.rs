use super::*;
use std::net::TcpListener;

// -- ProjectRegistry tests ---------------------------------------------------

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

// -- discover_listeners tests ------------------------------------------------

#[test]
fn test_discover_listeners_finds_bound_port() {
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

// -- reconcile: pure routing decisions (deterministic, no real ports) --------
//
// These replace the old `scan`-level integration tests, which bound real
// `127.0.0.1:0` listeners and enumerated the whole system. That made them flaky
// under parallel execution and port reuse (e.g. a freed port being re-bound by
// another test before the "route removed" assertion). `reconcile` is the pure
// routing core, so the same scenarios are now exercised deterministically.
// One intentional real-system integration test is kept below
// (`test_scan_re_evaluates_routes_when_more_specific_project_added`) to prove
// the discover → reconcile → router wiring against the live OS.

fn info(port: u16, tag: Option<&str>, cwd: Option<&str>) -> ListenerInfo {
    ListenerInfo {
        port,
        pid: port as u32,
        tag: tag.map(String::from),
        cwd: cwd.map(PathBuf::from),
    }
}

#[test]
fn test_reconcile_routes_listener_in_project_dir() {
    let mut reg = ProjectRegistry::default();
    reg.register(PathBuf::from("/Users/me/api"), "api".into());

    let listeners = vec![info(3000, None, Some("/Users/me/api/src"))];
    let plan = reconcile(&listeners, &HashMap::new(), &reg, "test");

    assert_eq!(plan.add.len(), 1);
    assert_eq!(plan.add[0].port, 3000);
    assert_eq!(plan.add[0].hostname, "api.test");
    assert_eq!(plan.add[0].addr, "127.0.0.1:3000".parse().unwrap());
    assert!(plan.add[0].source.starts_with("cwd="));
    assert!(plan.remove.is_empty());
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
    let mut reg = ProjectRegistry::default();
    reg.register(PathBuf::from("/Users/me/monorepo"), "monorepo".into());

    let listeners = vec![info(4000, Some("web"), Some("/Users/me/monorepo"))];
    let plan = reconcile(&listeners, &HashMap::new(), &reg, "test");

    assert_eq!(plan.add.len(), 1);
    assert_eq!(plan.add[0].hostname, "web.test");
    assert_eq!(plan.add[0].source, "tag");
}

#[test]
fn test_reconcile_ignores_unmatched_listener() {
    let mut reg = ProjectRegistry::default();
    reg.register(PathBuf::from("/Users/me/api"), "api".into());

    // No tag, cwd not under any registered dir.
    let listeners = vec![info(6000, None, Some("/Users/me/elsewhere"))];
    let plan = reconcile(&listeners, &HashMap::new(), &reg, "test");

    assert!(plan.add.is_empty());
    assert!(plan.remove.is_empty());
}

#[test]
fn test_reconcile_skips_already_routed_port() {
    let mut reg = ProjectRegistry::default();
    reg.register(PathBuf::from("/Users/me/api"), "api".into());

    let listeners = vec![info(3000, None, Some("/Users/me/api"))];
    let mut active = HashMap::new();
    active.insert(3000u16, "api.test".to_string());

    let plan = reconcile(&listeners, &active, &reg, "test");
    assert!(
        plan.add.is_empty(),
        "an already-routed port should not be re-added"
    );
    assert!(plan.remove.is_empty());
}

#[test]
fn test_reconcile_removes_stale_route() {
    // Port 3000 is routed but no longer listening, while another port IS
    // listening (so this is a real scan, not the transient-empty case).
    let reg = ProjectRegistry::default();
    let listeners = vec![info(8080, None, Some("/tmp/x"))];
    let mut active = HashMap::new();
    active.insert(3000u16, "api.test".to_string());

    let plan = reconcile(&listeners, &active, &reg, "test");
    assert_eq!(plan.remove, vec![(3000u16, "api.test".to_string())]);
    assert!(plan.add.is_empty());
}

#[test]
fn test_reconcile_empty_listeners_keeps_active_routes() {
    // Transient-failure guard: a 0-listener scan must NOT remove live routes
    // (an empty enumeration is far more likely a permission/timing failure
    // than every server stopping at once).
    let reg = ProjectRegistry::default();
    let mut active = HashMap::new();
    active.insert(3000u16, "api.test".to_string());

    let plan = reconcile(&[], &active, &reg, "test");
    assert_eq!(plan, RoutePlan::default(), "empty scan must be a no-op");
}

#[test]
fn test_reconcile_no_routes_when_empty_registry_and_no_tags() {
    let reg = ProjectRegistry::default();
    let listeners = vec![
        info(3000, None, Some("/tmp/a")),
        info(3001, None, None),
    ];
    let plan = reconcile(&listeners, &HashMap::new(), &reg, "test");
    assert!(plan.add.is_empty());
    assert!(plan.remove.is_empty());
}

#[test]
fn test_reconcile_project_registered_after_listener() {
    // Models "user adds a project while the server is already running": the
    // same listener yields no route before registration and a route after.
    let listeners = vec![info(3000, None, Some("/Users/me/late/src"))];

    let empty_reg = ProjectRegistry::default();
    let before = reconcile(&listeners, &HashMap::new(), &empty_reg, "test");
    assert!(before.add.is_empty());

    let mut reg = ProjectRegistry::default();
    reg.register(PathBuf::from("/Users/me/late"), "late".into());
    let after = reconcile(&listeners, &HashMap::new(), &reg, "test");
    assert_eq!(after.add.len(), 1);
    assert_eq!(after.add[0].hostname, "late.test");
}

#[test]
fn test_reconcile_prefers_most_specific_after_reeval() {
    // After a registry change, `scan` drains active_routes; reconcile then
    // re-matches against the updated registry, where the most specific dir
    // wins (the monorepo sub-app overrides the parent).
    let mut reg = ProjectRegistry::default();
    reg.register(PathBuf::from("/Users/me/monorepo"), "monorepo".into());
    reg.register(PathBuf::from("/Users/me/monorepo/apps/web"), "web".into());

    let listeners = vec![info(3000, None, Some("/Users/me/monorepo/apps/web"))];
    let plan = reconcile(&listeners, &HashMap::new(), &reg, "test");
    assert_eq!(plan.add[0].hostname, "web.test");
}

#[test]
fn test_reconcile_uses_configured_tld() {
    let mut reg = ProjectRegistry::default();
    reg.register(PathBuf::from("/Users/me/api"), "api".into());
    let listeners = vec![info(3000, None, Some("/Users/me/api"))];
    let plan = reconcile(&listeners, &HashMap::new(), &reg, "localhost");
    assert_eq!(plan.add[0].hostname, "api.localhost");
}

// -- Most-specific project matching ------------------------------------------

#[test]
fn test_find_project_prefers_most_specific_dir() {
    let mut reg = ProjectRegistry::default();
    reg.register(PathBuf::from("/Users/me/monorepo"), "monorepo".into());
    reg.register(
        PathBuf::from("/Users/me/monorepo/apps/admin"),
        "admin".into(),
    );
    reg.register(
        PathBuf::from("/Users/me/monorepo/apps/client"),
        "client".into(),
    );

    assert_eq!(
        reg.find_project_for_dir(std::path::Path::new(
            "/Users/me/monorepo/apps/admin/src"
        )),
        Some("admin")
    );
    assert_eq!(
        reg.find_project_for_dir(std::path::Path::new(
            "/Users/me/monorepo/apps/client"
        )),
        Some("client")
    );

    // Something NOT under a sub-app should fall back to the parent
    assert_eq!(
        reg.find_project_for_dir(std::path::Path::new(
            "/Users/me/monorepo/packages/shared"
        )),
        Some("monorepo")
    );
}

// -- Project attribution: tag (ground truth) vs cwd (heuristic) --------------

#[test]
fn test_attribution_tagged_wins_without_registration() {
    // A tagged process is attributed to its project DIRECTLY — no registered
    // directory and no cwd match required.
    let reg = ProjectRegistry::default();
    let cwd = PathBuf::from("/Users/me/anywhere");

    assert_eq!(
        attribute_project(Some("web"), Some(&cwd), &reg),
        Some("web".to_string())
    );
}

#[test]
fn test_attribution_untagged_falls_back_to_cwd() {
    // No tag → use the existing cwd heuristic against the registry.
    let mut reg = ProjectRegistry::default();
    reg.register(PathBuf::from("/Users/me/projects/api"), "api".into());
    let cwd = PathBuf::from("/Users/me/projects/api/src");

    assert_eq!(
        attribute_project(None, Some(&cwd), &reg),
        Some("api".to_string())
    );
}

#[test]
fn test_attribution_tag_overrides_cwd_when_they_disagree() {
    // The monorepo case: cwd is the repo root (registered as "monorepo"), but
    // the server was launched with `localport run --project web`. The tag must
    // win over the cwd-derived project.
    let mut reg = ProjectRegistry::default();
    reg.register(PathBuf::from("/Users/me/monorepo"), "monorepo".into());
    let cwd = PathBuf::from("/Users/me/monorepo");

    assert_eq!(
        attribute_project(Some("web"), Some(&cwd), &reg),
        Some("web".to_string()),
        "explicit tag must override the cwd-derived project"
    );
}

#[test]
fn test_attribution_tag_is_normalized() {
    // Tags go through the same normalization as registration: lowercase and
    // underscores → hyphens, so the hostname matches.
    let reg = ProjectRegistry::default();
    let cwd = PathBuf::from("/Users/me/whatever");

    assert_eq!(
        attribute_project(Some("My_App"), Some(&cwd), &reg),
        Some("my-app".to_string())
    );
}

#[test]
fn test_attribution_invalid_tag_falls_back_to_cwd() {
    // A tag that cannot be a valid DNS label (even after normalization) is
    // ignored, and attribution falls back to the cwd heuristic.
    let mut reg = ProjectRegistry::default();
    reg.register(PathBuf::from("/Users/me/projects/api"), "api".into());
    let cwd = PathBuf::from("/Users/me/projects/api");

    assert_eq!(
        attribute_project(Some("has space"), Some(&cwd), &reg),
        Some("api".to_string())
    );
}

#[test]
fn test_attribution_none_when_no_tag_and_no_cwd_match() {
    let reg = ProjectRegistry::default();
    let cwd = PathBuf::from("/Users/me/unregistered");

    assert_eq!(attribute_project(None, Some(&cwd), &reg), None);
    assert_eq!(attribute_project(None, None, &reg), None);
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
fn test_registry_generation_increments() {
    let mut reg = ProjectRegistry::default();
    assert_eq!(reg.generation(), 0);

    reg.register(PathBuf::from("/a"), "a".into());
    assert_eq!(reg.generation(), 1);

    reg.register(PathBuf::from("/b"), "b".into());
    assert_eq!(reg.generation(), 2);

    reg.unregister(std::path::Path::new("/a"));
    assert_eq!(reg.generation(), 3);

    // Unregistering something that doesn't exist doesn't bump generation
    reg.unregister(std::path::Path::new("/nonexistent"));
    assert_eq!(reg.generation(), 3);
}

/// The one intentional **real-system** integration test: it binds an actual
/// listener and drives the full `scan` path (live `discover_listeners` →
/// `reconcile` → `Router`) plus the generation-change re-evaluation that lives
/// in `scan` itself. It is robust under parallel execution because it never
/// drops a port mid-test and asserts route *values* (parent → child), not the
/// absence of a route — so it can't be fooled by another test reusing a port.
#[tokio::test]
async fn test_scan_re_evaluates_routes_when_more_specific_project_added() {
    let notify = Arc::new(tokio::sync::Notify::new());
    let router = Arc::new(RwLock::new(Router::new(notify)));
    let projects = Arc::new(RwLock::new(ProjectRegistry::default()));
    let cwd = std::env::current_dir().unwrap();

    projects
        .write()
        .await
        .register(cwd.clone(), "parent".into());

    let scan_notify = Arc::new(tokio::sync::Notify::new());
    let watcher = PortWatcher::new(router.clone(), projects.clone(), "test".into(), scan_notify);

    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();

    let mut active_routes = HashMap::new();
    let mut gen = 0u64;
    watcher.scan(&mut active_routes, &mut gen).await.unwrap();

    assert_eq!(active_routes.get(&port).unwrap(), "parent.test");

    // Now register a more specific project that covers our exact CWD.
    projects.write().await.register(cwd.clone(), "child".into());

    // Next scan should detect the generation change and re-evaluate.
    watcher.scan(&mut active_routes, &mut gen).await.unwrap();

    assert_eq!(
        active_routes.get(&port).unwrap(),
        "child.test",
        "route should update to the more specific project after registry change"
    );

    drop(listener);
}
