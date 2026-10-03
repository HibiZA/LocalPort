# DevSpace Implementation Progress

## Architecture Overview
- **Rust Daemon** (`devspaced`): Networking layer — reverse proxy, port watcher, process manager, IPC
- **Swift macOS App** (`DevSpace.app`): Native menu bar app — window grouping, border overlays, project switching
- **CLI** (`devspace`): Command-line interface for project management

---

## Phase 1: Daemon (Rust) — Standalone CLI
- [x] Core types and config (`devspace-core`)
- [x] Protocol definitions (`devspace-proto`)
- [x] Daemon skeleton with IPC server (`devspace-daemon`)
- [x] Reverse proxy with hostname routing
- [x] Port watcher (auto-detect listening ports → project mapping)
- [x] Process manager (spawn/kill project processes)
- [x] CLI commands: init, up, down, status (`devspace-cli`)
- [ ] End-to-end testing: `devspace init` → `devspace up` → proxy routes traffic
- [ ] WebSocket upgrade support in proxy
- [ ] Optional local TLS via mkcert

## Phase 2: Native macOS Window Manager (Swift/AppKit)
- [x] Swift package setup (`macos/Package.swift`)
- [x] Accessibility permission request flow
- [x] Window discovery and tracking (CGWindowList + AXUIElement)
- [x] Project-to-window matching (editor, browser, terminal heuristics)
- [x] Colored border overlays (transparent NSWindow companions)
- [x] Dim overlay for inactive projects
- [x] Project switching (Ctrl+1-9, Ctrl+Tab, Ctrl+`) via CGEvent tap
- [x] Window arrangement — save/restore layouts
- [x] Auto-tiling layouts (code-focus, preview-focus, equal-split)
- [x] Menu bar UI (project list, status, notifications, badge)
- [x] Window claiming (manual override + PID-based auto-claim)
- [x] IPC client — Unix socket JSON-RPC to Rust daemon
- [x] AppDelegate wiring — all subsystems connected
- [x] Preferences window (border width, glow, dim, animation speed)
- [x] Add Project via directory picker
- [x] Compiles successfully (`swift build`)

## Phase 3: Project Launch & Linking
When a user adds a project, DevSpace automatically:
1. Detects the project type (Node/Vite/Next/Rust/Python/Go/etc.)
2. Opens the user's preferred IDE with the project directory
3. Starts the dev server in the preferred terminal
4. Opens the browser to the correct URL once the server is ready
5. Tags all launched windows and associates them with the project
6. Auto-tiles the windows in the user's chosen layout

- [x] AppScanner — detect installed IDEs, browsers, terminals on the system
- [x] OnboardingFlow — first-launch questionnaire to pick preferred apps
- [x] UserPreferences — persist preferred IDE/browser/terminal across sessions
- [x] ProjectDetector — detect project type from directory contents (package.json, Cargo.toml, etc.)
- [x] ProjectLauncher — orchestrate IDE/terminal/browser launch sequence
- [x] PID-based window association — track launched PIDs and auto-claim their windows
- [x] Auto-tile after launch — arrange claimed windows in chosen layout
- [x] Wired into AppDelegate — full flow from "Add Project" → launch → window management
- [x] Package manager detection (npm vs yarn vs pnpm vs bun) from lockfiles
- [x] Custom dev command override in .devspace.toml
- [x] Server ready detection (TCP port polling before opening browser)
- [x] Layout selection dialog when adding a project (6 presets)
- [x] Project settings panel (edit name, color, hostname, layout; remove project)

## Phase 4: Polish & Reliability
- [x] UI overhaul: redesign Preferences window and Project Settings panel
- [ ] Persist project list across restarts
- [x] Window rule engine (match by title/URL patterns from .devspace.toml)
- [x] macOS notification permission request on first launch
- [x] Graceful handling when apps are already open
- [x] Re-scan for new windows when apps spawn child processes

## Phase 5: Linux/Windows Support
- [ ] Linux: X11/Wayland window management
- [ ] Windows: Win32 APIs

## Phase 6: Team Features
- [ ] Shared project configs
- [ ] Secure tunneling

---

## File Structure

```
macos/
  Package.swift
  Sources/
    main.swift                          # Entry point
    AppDelegate.swift                   # Orchestrates all subsystems
    PreferencesWindow.swift             # Preferences UI + AppPreferences model
    Models/
      Project.swift                     # Project model + color wrapper
      TrackedWindow.swift               # Window model + app classification
    WindowManager/
      WindowTracker.swift               # CGWindowList polling, AX observers, project matching
      BorderOverlay.swift               # Transparent NSWindow borders + dim overlays
      ProjectSwitcher.swift             # Global hotkeys via CGEvent tap
      LayoutManager.swift               # Save/restore/auto-tile window layouts
    MenuBar/
      MenuBarController.swift           # NSStatusItem menu bar UI
    Setup/
      AppScanner.swift                  # Scan /Applications for known IDEs/browsers/terminals
      OnboardingWindow.swift            # First-launch app selection questionnaire
      UserPreferences.swift             # Persist preferred apps (UserDefaults)
    Launch/
      ProjectDetector.swift             # Detect project type from directory contents
      ProjectLauncher.swift             # Orchestrate IDE/terminal/browser launch
    IPC/
      DaemonClient.swift                # Unix socket JSON-RPC client
```

## Current Focus
Phase 4: polish, persistence, reliability.
