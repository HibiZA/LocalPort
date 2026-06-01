//! `localport` — the command-line companion to the LocalPort daemon.
//!
//! Today it provides a single subcommand, `run`, which tags a dev server with
//! its project name so the daemon attributes the server's port by GROUND TRUTH
//! instead of guessing from the process's working directory:
//!
//! ```text
//!   localport run -- npm run dev                      # infer name from cwd / .localport.toml
//!   localport run --project web -- pnpm --filter web dev
//! ```
//!
//! It sets `LOCALPORT_PROJECT=<name>` and execs the child. Because the
//! environment is inherited across fork/exec, every worker the dev server
//! spawns (Vite, Next, esbuild, …) carries the tag automatically, so the
//! daemon attributes whichever of them ends up holding the listening socket.
//!
//! This binary intentionally depends only on `localport-core` (config +
//! validation) and the standard library — no daemon, no IPC, no async runtime.

use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;

fn main() {
    let argv: Vec<String> = std::env::args().collect();
    match argv.get(1).map(String::as_str) {
        Some("run") => run(&argv[2..]),
        Some("-h") | Some("--help") | Some("help") | None => {
            print_help();
            std::process::exit(0);
        }
        Some("-V") | Some("--version") => {
            println!("localport {}", env!("CARGO_PKG_VERSION"));
            std::process::exit(0);
        }
        Some(other) => {
            eprintln!("localport: unknown subcommand '{other}'\n");
            print_help();
            std::process::exit(2);
        }
    }
}

/// `localport run [--project <name>] [--] <command> [args...]`
fn run(args: &[String]) -> ! {
    let mut project: Option<String> = None;
    let mut i = 0;
    let cmd: &[String];

    loop {
        match args.get(i).map(String::as_str) {
            Some("--project") | Some("-p") => {
                project = match args.get(i + 1) {
                    Some(v) => Some(v.clone()),
                    None => fail("--project requires a value"),
                };
                i += 2;
            }
            // Explicit separator: everything after `--` is the command.
            Some("--") => {
                cmd = &args[i + 1..];
                break;
            }
            // Any other dashed token is a mistyped option, not a program name.
            Some(tok) if tok.starts_with('-') => {
                fail(&format!(
                    "unknown option '{tok}'. Put the command after '--', e.g. \
                     'localport run --project web -- {tok}'"
                ));
            }
            // First bare token begins the command (the `--` is optional).
            Some(_) => {
                cmd = &args[i..];
                break;
            }
            None => fail(
                "missing command\n\n\
                 usage: localport run [--project <name>] -- <command> [args...]",
            ),
        }
    }

    if cmd.is_empty() {
        fail(
            "missing command\n\n\
             usage: localport run [--project <name>] -- <command> [args...]",
        );
    }

    // Resolve the project name: explicit flag > nearest .localport.toml > cwd
    // basename — mirroring how the daemon names a registered directory.
    let raw_name = project.unwrap_or_else(infer_project_name);
    let name = localport_core::validation::normalize_project_name(&raw_name);
    if !localport_core::validation::is_valid_dns_label(&name) {
        fail(&format!(
            "invalid project name '{name}' (from '{raw_name}'): must be a valid DNS \
             label — lowercase letters, digits and hyphens, 1–63 chars. \
             Pass --project <name> to set it explicitly."
        ));
    }

    eprintln!("localport: tagging '{}' as project '{name}'", cmd[0]);

    // Hand off to the child via exec(2). exec replaces this process image, so
    // the child keeps our PID, exit status and signals pass straight through,
    // and the LOCALPORT_PROJECT tag is inherited by every descendant.
    let err = Command::new(&cmd[0])
        .args(&cmd[1..])
        .env(localport_core::PROJECT_ENV_VAR, &name)
        .exec();

    // exec() only returns if it failed.
    fail(&format!("failed to run '{}': {err}", cmd[0]));
}

/// Infer a project name when `--project` is not given: prefer the nearest
/// `.localport.toml`'s `[project] name`, falling back to the cwd's basename.
fn infer_project_name() -> String {
    let cwd = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    if let Some(name) = find_localport_name(&cwd) {
        return name;
    }
    cwd.file_name()
        .map(|f| f.to_string_lossy().into_owned())
        .unwrap_or_else(|| "unnamed".to_string())
}

/// Walk up from `start` looking for a `.localport.toml` with a project name.
fn find_localport_name(start: &Path) -> Option<String> {
    let mut dir: Option<&Path> = Some(start);
    while let Some(d) = dir {
        if let Ok(cfg) = localport_core::config::load_project_config(d) {
            if !cfg.project.name.trim().is_empty() {
                return Some(cfg.project.name);
            }
        }
        dir = d.parent();
    }
    None
}

fn fail(msg: &str) -> ! {
    eprintln!("localport: {msg}");
    std::process::exit(2);
}

fn print_help() {
    eprintln!(
        "localport {ver} — local hostnames for your dev servers\n\n\
         USAGE:\n    \
         localport run [--project <name>] -- <command> [args...]\n\n\
         Runs <command> tagged with its project so the LocalPort daemon maps\n\
         the server's port to <name>.<tld> by ground truth instead of guessing\n\
         from the working directory. Essential for monorepos where servers are\n\
         launched from a parent directory.\n\n\
         OPTIONS:\n    \
         -p, --project <name>   Project name (default: nearest .localport.toml,\n                           \
         else the current directory's name)\n    \
         -h, --help             Show this help\n    \
         -V, --version          Show version\n\n\
         EXAMPLES:\n    \
         localport run -- npm run dev\n    \
         localport run --project web -- pnpm --filter web dev\n",
        ver = env!("CARGO_PKG_VERSION"),
    );
}
