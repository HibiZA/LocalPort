pub mod config;
pub mod error;
pub mod types;
pub mod validation;

/// Environment variable the `localport run` wrapper sets to tag a dev server
/// with its project name. The daemon's port watcher reads it back from a
/// listening PID as the ground-truth project attribution, overriding the
/// working-directory heuristic. Inherited across fork/exec, so child workers
/// (Vite, Next, …) keep the tag automatically.
pub const PROJECT_ENV_VAR: &str = "LOCALPORT_PROJECT";

/// Release version: `LOCALPORT_VERSION` at build time (set by
/// `scripts/build.sh` from the git tag), else the crate version.
pub const VERSION: &str = match option_env!("LOCALPORT_VERSION") {
    Some(v) => v,
    None => env!("CARGO_PKG_VERSION"),
};
