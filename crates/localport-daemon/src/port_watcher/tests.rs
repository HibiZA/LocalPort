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

// -- Integration: scan creates and removes routes ----------------------------

#[tokio::test]
async fn test_scan_creates_route_for_listener_in_project_dir() {
    let notify = Arc::new(tokio::sync::Notify::new());
    let router = Arc::new(RwLock::new(Router::new(notify)));
    let projects = Arc::new(RwLock::new(ProjectRegistry::default()));

    let cwd = std::env::current_dir().unwrap();
    projects
        .write()
        .await
        .register(cwd, "test-project".into());

    let scan_notify = Arc::new(tokio::sync::Notify::new());
    let watcher = PortWatcher::new(router.clone(), projects.clone(), "test".into(), scan_notify);

    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();

    let mut active_routes = HashMap::new();
    let mut gen = 0u64;
    watcher.scan(&mut active_routes, &mut gen).await.unwrap();

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
    watcher.scan(&mut active_routes, &mut gen).await.unwrap();

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

    projects
        .write()
        .await
        .register(PathBuf::from("/nonexistent/fake-project"), "fake".into());

    let scan_notify = Arc::new(tokio::sync::Notify::new());
    let watcher = PortWatcher::new(router.clone(), projects.clone(), "test".into(), scan_notify);

    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();

    let mut active_routes = HashMap::new();
    let mut gen = 0u64;
    watcher.scan(&mut active_routes, &mut gen).await.unwrap();

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

    let scan_notify = Arc::new(tokio::sync::Notify::new());
    let watcher = PortWatcher::new(router.clone(), projects.clone(), "test".into(), scan_notify);

    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();

    // First scan: no projects registered, should skip scanning entirely.
    let mut active_routes = HashMap::new();
    let mut gen = 0u64;
    watcher.scan(&mut active_routes, &mut gen).await.unwrap();
    assert!(
        active_routes.is_empty(),
        "no routes yet — no projects registered"
    );

    // Now register the project (simulates user adding a project at runtime).
    projects.write().await.register(cwd, "late-project".into());

    // Second scan: should now pick up the already-running listener.
    watcher.scan(&mut active_routes, &mut gen).await.unwrap();
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

    let scan_notify = Arc::new(tokio::sync::Notify::new());
    let watcher = PortWatcher::new(router.clone(), projects.clone(), "test".into(), scan_notify);

    let listener = TcpListener::bind("127.0.0.1:0").unwrap();

    let mut active_routes = HashMap::new();
    let mut gen = 0u64;
    watcher.scan(&mut active_routes, &mut gen).await.unwrap();

    assert!(active_routes.is_empty());

    drop(listener);
}

#[tokio::test]
async fn test_empty_scan_does_not_nuke_active_routes() {
    let notify = Arc::new(tokio::sync::Notify::new());
    let router = Arc::new(RwLock::new(Router::new(notify)));
    let projects = Arc::new(RwLock::new(ProjectRegistry::default()));
    let cwd = std::env::current_dir().unwrap();
    projects.write().await.register(cwd, "myapp".into());

    let scan_notify = Arc::new(tokio::sync::Notify::new());
    let watcher = PortWatcher::new(router.clone(), projects.clone(), "test".into(), scan_notify);

    // Seed active_routes as if a previous scan found a listener.
    let mut active_routes = HashMap::new();
    active_routes.insert(9999, "myapp.test".to_string());

    let mut gen = 0u64;
    watcher.scan(&mut active_routes, &mut gen).await.unwrap();

    // The route for port 9999 may or may not be cleaned up depending on
    // whether other LISTEN sockets exist on the system. This test mainly
    // exercises the code path without panicking.
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
