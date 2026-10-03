# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run Commands

```bash
# Rust (all crates)
cargo build                          # Build everything
cargo test                           # Run all tests
cargo clippy --all-targets -- -D warnings
cargo fmt --check                    # CI enforces both of these
cargo run --bin localportd           # Run the daemon
cargo test -p localport-core         # Test a single crate

# macOS app (Swift)
cd macos && swift build              # Debug build

# Full app bundle (+ DMG); --universal builds arm64 + x86_64
bash scripts/build.sh [--universal] [--dmg]
```

To run the daemon in isolation (without touching an installed LocalPort), point
`HOME` and `XDG_CONFIG_HOME` at a temp dir and give it a `config.toml` with
non-default ports and `daemon.socket_path`.

## Architecture

LocalPort gives each local dev server a hostname (`myapp.test`). A **Rust daemon**
discovers listening ports and drives Caddy; a **Swift/AppKit menu bar app**
supervises the daemon and handles UI and privileged setup.

### Rust workspace (`crates/`)

- **localport-core** — config (`GlobalConfig` from `~/.config/localport/config.toml`,
  `ProjectConfig` from `.localport.toml`), validation/normalization of names and
  hostnames, `PROJECT_ENV_VAR`, and `VERSION` (from `LOCALPORT_VERSION` at build time).
- **localport-proto** — JSON-RPC 2.0 message types and method name constants.
- **localport-daemon** — two binaries:
  - `localportd` (`src/main.rs`):
    - `daemon.rs` — wires subsystems; handles SIGINT/SIGTERM/IPC shutdown
    - `port_watcher/` — libproc-based listener discovery every 2s. `reconcile` is the
      pure core: it computes the desired route per hostname (one per project) and
      diffs it against what the watcher owns. Attribution order: claimed port >
      `LOCALPORT_PROJECT` tag > cwd. Each scan also publishes a `WatchSnapshot`
      (route owners and unclaimed dev-server ports) that `project.status` reports. Process inputs (tag, cwd) are cached per
      (pid, start time). The registry is keyed by canonical paths.
    - `caddy.rs` — supervises Caddy (restart with backoff, status for the app), writes
      the Caddyfile, reloads on route changes, downloads a pinned + SHA-512-verified
      Caddy if none is installed. Caddy uses its own storage under
      `~/Library/Application Support/LocalPort/caddy`.
    - `ipc.rs` — Unix socket JSON-RPC server (`/tmp/localport-{uid}.sock`)
    - `dns.rs` — answers A queries with 127.0.0.1 (empty NOERROR for other types)
    - `router.rs` — hostname → upstream `SocketAddr` map
  - `localport` (`src/bin/localport.rs`) — CLI; `localport run` sets
    `LOCALPORT_PROJECT` and execs the command (std + core only, no tokio).

### macOS app (`macos/Sources/`)

- `AppDelegate` — orchestration: polls `daemon.status` + `project.status` every 3s on a
  serial background queue, re-registers saved projects the daemon doesn't know,
  triggers system setup, and handles add/edit/remove and uninstall.
- `System/DaemonSupervisor` — launches `localportd` (logs to `~/Library/Logs/LocalPort`),
  restarts it on unexpected exit.
- `System/SystemSetup` — runs `scripts/setup.sh` / `uninstall.sh` via the admin prompt.
  CA trust is set in-process (`SecTrustSettings`), since macOS rejects admin trust
  changes from the prompt's root shell. `SystemSetup.currentVersion` forces a re-run
  when setup changes.
- `System/ProcessStats` — CPU/memory (`proc_pid_rusage`), GPU (IOAccelerator clients in
  the IORegistry) and network (`nettop`) per pid; runs only while the Ports tab is open.
- `System/ConfigFile` — reads and writes the daemon's `config.toml`, which is the single
  source of truth for TLD and ports.
- `IPC/DaemonClient` — synchronous, thread-safe socket client. Never call it on the main thread.
- `MenuBar/MenuBarController` — status item + `NSPopover`; `PopoverView` (SwiftUI) renders
  `MenuState` from a `PopoverModel` and forwards actions to the delegate.
- `Models/Project` — `id` is the directory. `slug` is the daemon's project name.

## IPC Protocol

Line-delimited JSON-RPC 2.0 over a Unix socket. Methods: `daemon.status`,
`daemon.shutdown`, `project.init` (`directory`, optional `name`/`hostname`/`port`/`claim`),
`project.remove`, `project.status`, `route.add|remove|list`.

## Key Patterns

- **Async**: Tokio, `tokio::spawn` for subsystems, `watch::channel` for shutdown
- **Shared state**: `Arc<RwLock<T>>`
- **Errors**: `thiserror` in core, `anyhow` elsewhere
- **Logging**: `tracing` to stderr (`RUST_LOG` or `daemon.log_level`); `os.log` in Swift
- **Testing**: routing logic is tested through pure functions (`reconcile`,
  `generate_caddyfile`, `build_response`); keep new logic testable the same way.
