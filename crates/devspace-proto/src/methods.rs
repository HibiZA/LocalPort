/// Register a project directory with the daemon
pub const PROJECT_INIT: &str = "project.init";

/// Start services for a project
pub const PROJECT_UP: &str = "project.up";

/// Get status of all projects
pub const PROJECT_STATUS: &str = "project.status";

/// Stop services for a project
pub const PROJECT_DOWN: &str = "project.down";

/// Get daemon health/version info
pub const DAEMON_STATUS: &str = "daemon.status";

/// Gracefully shut down the daemon
pub const DAEMON_SHUTDOWN: &str = "daemon.shutdown";

/// Add a proxy route (used internally and for testing)
pub const ROUTE_ADD: &str = "route.add";

/// Remove a proxy route
pub const ROUTE_REMOVE: &str = "route.remove";

/// List all proxy routes
pub const ROUTE_LIST: &str = "route.list";
