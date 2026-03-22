<p align="center">
  <img src="https://github.com/HibiZA/DevSpace/releases/download/v0.1.2/DevSpace.dmg" width="0" height="0" />
  <h1 align="center">DevSpace</h1>
  <p align="center">Local hostnames for every project. No more port numbers.</p>
</p>

<p align="center">
  <a href="https://github.com/HibiZA/DevSpace/releases/latest"><strong>Download</strong></a> &nbsp;&middot;&nbsp;
  <a href="#install">Install</a> &nbsp;&middot;&nbsp;
  <a href="#how-it-works">How It Works</a> &nbsp;&middot;&nbsp;
  <a href="#configuration">Configuration</a>
</p>

---

## The Problem

AI coding agents have changed how developers work. Tools like Claude Code, Cursor, and Copilot Workspace make it easy to spin up and iterate on multiple projects at once — you might have an agent building a frontend in one terminal, another scaffolding an API, and a third prototyping a microservice, all running simultaneously.

But your local environment wasn't built for this. You end up with:

- `localhost:3000` — is that the frontend or the API?
- `localhost:3001` — which project was this again?
- `localhost:8080` — did I already kill the old server?

Cookies and localStorage bleed across projects because they all share the `localhost` origin. OAuth redirect URIs become a mess — you can't tell Google "send auth callbacks to `localhost:3000`" when three different apps are fighting over that port. The more projects you run in parallel, the worse it gets.

## The Solution

DevSpace gives each project its own hostname:

```
https://myapp.test     → localhost:3000
https://api.test       → localhost:8080
https://dashboard.test → localhost:5173
```

- **Unique browser origins** — cookies, localStorage, and sessions are isolated per project
- **Clean OAuth redirects** — configure `https://myapp.test/callback` in Google Console
- **No port memorization** — just use the project name
- **Auto-HTTPS** — Caddy handles TLS with an internal CA
- **Zero config** — start your dev server, DevSpace detects it automatically

## How It Works

1. Register a project: `devspace init` in any project directory
2. Start your dev server however you normally do
3. DevSpace auto-detects the listening port and maps it to `yourproject.test`
4. Open `https://yourproject.test` in your browser

The menu bar app shows which projects are running and on which ports:

```
DevSpace
────────────────────────────────
● my-app
    my-app.test · :3000 · running
● api-server
    api-server.test · :8080 · running
○ dashboard
    dashboard.test · stopped
────────────────────────────────
Add Project...
Preferences...
Quit DevSpace
```

## Install

### Download

Grab the latest `.dmg` from [**Releases**](https://github.com/HibiZA/DevSpace/releases/latest), open it, and drag DevSpace to Applications.

On first launch, macOS will show an "unidentified developer" warning. Go to **System Settings → Privacy & Security** and click **Open Anyway**.

### Build from Source

```bash
git clone https://github.com/HibiZA/DevSpace.git
cd DevSpace
bash scripts/build.sh
cp -r build/DevSpace.app /Applications/
```

### CLI Setup

The CLI is bundled inside the app. To add it to your PATH:

```bash
ln -sf /Applications/DevSpace.app/Contents/Helpers/devspace /usr/local/bin/devspace
```

### First-Time Setup

```bash
devspace setup
```

This runs one-time system configuration (requires sudo):
- Creates `/etc/resolver/test` for `*.test` DNS resolution
- Installs Caddy's root CA for trusted local HTTPS
- Sets up port forwarding so you don't need `:8443` in URLs

Caddy is auto-downloaded on first run if not already installed.

## Usage

```bash
# Initialize a project
cd ~/projects/my-app
devspace init

# Start your dev server as usual
npm run dev

# DevSpace auto-detects it — visit https://my-app.test

# Check what's running
devspace status
```

### CLI Commands

| Command | Description |
|---------|-------------|
| `devspace init` | Register the current directory as a project |
| `devspace status` | Show all projects and active routes |
| `devspace setup` | One-time system setup (DNS, HTTPS, port forwarding) |
| `devspace daemon start` | Start the daemon manually |
| `devspace daemon stop` | Stop the daemon |
| `devspace daemon status` | Show daemon info |

## Configuration

### Global Config

`~/.config/devspace/config.toml`:

```toml
# TLD for project hostnames (default: "test")
# Set to "localhost" to skip DNS setup (access via myapp.localhost:8080)
tld = "test"

[caddy]
http_port = 8080
https_port = 8443

[daemon]
log_level = "info"
dns_port = 5553
```

### Per-Project Config

`.devspace.toml` in your project root:

```toml
[project]
name = "my-app"
hostname = "my-app"
```

## Architecture

```
Browser → https://myapp.test
         ↓
    DNS resolver (/etc/resolver/test → 127.0.0.1:5553)
         ↓
    pfctl port forwarding (443 → 8443)
         ↓
    Caddy reverse proxy (HTTPS with internal CA)
         ↓
    Your dev server (localhost:3000)
         ↑
    Auto-discovered by port watcher
```

### Components

| Component | Language | Purpose |
|-----------|----------|---------|
| `devspaced` | Rust | Daemon — Caddy management, DNS responder, port watcher, IPC |
| `devspace` | Rust | CLI — project init, status, setup |
| `DevSpace.app` | Swift | macOS menu bar app — status display, preferences |
| Caddy | Go | Reverse proxy with automatic HTTPS (auto-downloaded) |

### How Port Detection Works

The daemon runs `lsof` every 2 seconds to discover listening TCP ports. For each new port, it checks the process's working directory. If that directory is inside a registered project, a route is created automatically and Caddy is reloaded.

When a port stops listening, the route is removed.

## Requirements

- macOS 13 (Ventura) or later
- For building: Rust toolchain + Swift 5.9+

## Contributing

Contributions are welcome. Please open an issue first to discuss what you'd like to change.

## License

[MIT](LICENSE)
