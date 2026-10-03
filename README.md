<p align="center">
  <img src="https://github.com/HibiZA/LocalPort/releases/download/v0.1.2/LocalPort.dmg" width="0" height="0" />
  <h1 align="center">LocalPort</h1>
  <p align="center">Local hostnames for every project. No more port numbers.</p>
</p>

<p align="center">
  <a href="https://github.com/HibiZA/LocalPort/releases/latest"><img src="https://img.shields.io/github/v/release/HibiZA/LocalPort?style=flat-square&label=release&color=blue" alt="Latest Release"></a>
  <a href="https://github.com/HibiZA/LocalPort/blob/main/LICENSE"><img src="https://img.shields.io/github/license/HibiZA/LocalPort?style=flat-square&color=green" alt="License"></a>
  <img src="https://img.shields.io/badge/platform-macOS-lightgrey?style=flat-square" alt="Platform">
  <img src="https://img.shields.io/badge/rust-%E2%9C%93-orange?style=flat-square&logo=rust" alt="Rust">
  <img src="https://img.shields.io/badge/swift-%E2%9C%93-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift">
  <a href="https://github.com/HibiZA/LocalPort/stargazers"><img src="https://img.shields.io/github/stars/HibiZA/LocalPort?style=flat-square" alt="Stars"></a>
  <a href="https://github.com/HibiZA/LocalPort/issues"><img src="https://img.shields.io/github/issues/HibiZA/LocalPort?style=flat-square" alt="Issues"></a>
</p>

<p align="center">
  <a href="https://github.com/HibiZA/LocalPort/releases/latest"><strong>Download</strong></a> &nbsp;&middot;&nbsp;
  <a href="#install">Install</a> &nbsp;&middot;&nbsp;
  <a href="#how-it-works">How It Works</a> &nbsp;&middot;&nbsp;
  <a href="#configuration">Configuration</a>
</p>

---

## The Problem

AI coding agents have changed how developers work. Tools like Claude Code, Cursor, and Codex make it easy to spin up and iterate on multiple projects at once — you might have an agent building a frontend in one terminal, another scaffolding an API, and a third prototyping a microservice, all running simultaneously.

But your local environment wasn't built for this. You end up with:

- `localhost:3000` — is that the frontend or the API?
- `localhost:3001` — which project was this again?
- `localhost:8080` — did I already kill the old server?

Cookies and localStorage bleed across projects because they all share the `localhost` origin. OAuth redirect URIs become a mess — you can't tell Google "send auth callbacks to `localhost:3000`" when three different apps are fighting over that port. The more projects you run in parallel, the worse it gets.

## The Solution

LocalPort gives each project its own hostname:

```
https://myapp.test     → localhost:3000
https://api.test       → localhost:8080
https://dashboard.test → localhost:5173
```

- **Unique browser origins** — cookies, localStorage, and sessions are isolated per project
- **Clean OAuth redirects** — configure `https://myapp.test/callback` in Google Console
- **No port memorization** — just use the project name
- **Auto-HTTPS** — Caddy handles TLS with an internal CA
- **Zero config** — start your dev server, LocalPort detects it automatically

## How It Works

1. Add a project from the menu bar (click the LocalPort icon → **Add Project...**)
2. Start your dev server however you normally do
3. LocalPort auto-detects the listening port and maps it to `yourproject.test`
4. Open `https://yourproject.test` in your browser

The menu bar app shows which projects are running and on which ports:

<p align="center"><img src="docs/popover.png" width="360" alt="LocalPort popover"></p>

## Install

### Download

Grab the latest `.dmg` from [**Releases**](https://github.com/HibiZA/LocalPort/releases/latest), open it, and drag LocalPort to Applications.

On first launch, macOS will show an "unidentified developer" warning. Go to **System Settings → Privacy & Security** and click **Open Anyway**.

### Build from Source

```bash
git clone https://github.com/HibiZA/LocalPort.git
cd LocalPort
bash scripts/build.sh
cp -r build/LocalPort.app /Applications/
```

### First Launch

On first launch, LocalPort asks for your password once to:
- Set up DNS resolution for `*.test` domains
- Trust LocalPort's local certificate authority for HTTPS
- Configure port forwarding (80 → 47080, 443 → 47443), re-applied automatically at boot and after macOS updates

If Caddy isn't installed, a pinned, checksum-verified release is downloaded automatically. LocalPort checks this configuration on every launch and asks again only if something is missing (for example after you change the TLD).

## Usage

1. Click the LocalPort icon in the menu bar → **Add Project...**
2. Select your project directory
3. Start your dev server as usual:

```bash
cd ~/projects/my-app
npm run dev
# LocalPort auto-detects it — visit https://my-app.test
```

That's it. LocalPort handles the rest.

### The menu bar popover

Click the LocalPort icon to open the popover. It has three tabs:

- **Projects** — each project with its hostname and port. A running project also shows which process serves it (for example `node · localport run`; hover for the pid and address). Click a project to open it, or use its **•••** menu for **Open in Browser**, **Copy URL**, **Reveal in Finder** and **Settings...**.
- **Ports** — unclaimed ports and other live routes (see below).
- **System** — daemon and proxy status, with the proxy error if it failed, the TLD, and **Open Logs**.

**Unclaimed Ports** lists dev servers LocalPort can see but can't attribute to a project. For each one you can:
- **Add "folder" as Project** — register the folder the server is running in
- **Assign to Project** — route that port to an existing project whatever process listens on it. Use this for servers that don't run from the project folder, such as a Docker-published port. You can also set it in Settings with a port and **Claim this port**.

macOS system services, debugger and ephemeral ports, and sockets bound to VPN/LAN addresses are left out of this list.

### Monorepos and explicit tagging

The zero-config path attributes a server to a project by its working directory. That's a heuristic, and it breaks down when a server is launched from a *parent* directory — common in monorepos:

```bash
# cwd is the repo root, but this server is the "web" app
pnpm --filter web dev
```

Here the working directory is the monorepo root, so the heuristic would attribute the port to the root project (or miss it). Wrap the command in `localport run` to tag it with the right project explicitly:

```bash
localport run --project web -- pnpm --filter web dev
# → https://web.test, regardless of the directory it was launched from
```

`localport run` sets the `LOCALPORT_PROJECT` environment variable and then execs your command. Because the environment is inherited across `fork`/`exec`, every worker the server spawns (Vite, Next, esbuild, …) keeps the tag, so whichever one ends up holding the listening socket is still attributed correctly. **An explicit tag always wins over the working-directory heuristic.**

If you omit `--project`, the name is taken from the nearest `.localport.toml` (its `[project] name`), falling back to the current directory's name:

```bash
localport run -- npm run dev
```

The `localport` CLI is bundled inside `LocalPort.app`. To put it on your `PATH`:

```bash
sudo ln -sf /Applications/LocalPort.app/Contents/Helpers/localport /usr/local/bin/localport
```

## Configuration

### Global Config

`~/.config/localport/config.toml`:

```toml
# TLD for project hostnames (default: "test")
# Set to "localhost" to skip DNS setup (access via http://myapp.localhost:47080)
tld = "test"

[caddy]
http_port = 47080    # Caddy's ports; deliberately uncommon so they don't
https_port = 47443   # collide with your own dev servers
admin_port = 47019   # Caddy admin API (localhost only)

[daemon]
log_level = "info"
dns_port = 5553
```

The TLD can also be changed in **Preferences**, which updates this file and restarts the daemon.

### Per-Project Config (Optional)

You can add a `.localport.toml` to your project root to override the defaults. Without this file, LocalPort uses the directory name. Every field is optional.

```toml
[project]
name = "my-app"         # project name (default: directory name)
hostname = "my-app"     # a bare label gets the TLD appended; "api.my-app.test" is used as-is
port = 5173             # route only this port (see below)
```

Hostname and port can also be set per project in the app's **Settings...** panel, and these take precedence over the file.

When a project has several listening ports (dev server, debugger, Storybook, internal workers), LocalPort routes the most likely dev server: the lowest port, skipping Node's inspector (9229) and ephemeral ports. Set `port` to choose explicitly.

### Logs

The daemon and Caddy log to `~/Library/Logs/LocalPort/` (**System → Open Logs** in the popover). If the proxy fails, the popover shows the error and LocalPort restarts it automatically.

## Architecture

```
Browser → https://myapp.test
         ↓
    DNS resolver (/etc/resolver/test → 127.0.0.1:5553)
         ↓
    pfctl port forwarding (443 → 47443)
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
| `LocalPort.app` | Swift | macOS menu bar app — manages everything |
| `localportd` | Rust | Daemon — Caddy management, DNS responder, port watcher, IPC |
| `localport` | Rust | CLI — `localport run` tags a server with its project for ground-truth attribution |
| Caddy | Go | Reverse proxy with automatic HTTPS (auto-downloaded) |

### How Port Detection Works

The daemon polls every 2 seconds using macOS `libproc` APIs (in-process syscalls, no subprocesses) to discover listening TCP ports. For each port it attributes the listener to a project in one of three ways, in this order:

1. **Assigned port.** A port assigned to a project (Unclaimed Ports → Assign to Project, or **Claim this port** in Settings) always routes to that project, whichever process listens on it.
2. **Explicit tag (ground truth).** If the server was started with [`localport run`](#monorepos-and-explicit-tagging), it carries a `LOCALPORT_PROJECT` environment variable. The daemon reads that variable back from the process and maps the port to that project directly.
3. **Working-directory heuristic (zero-config default).** Otherwise the daemon reads the process's working directory; if it sits inside a registered project directory, the port is mapped to that project. When project directories nest (monorepos), the most specific match wins.

A tag always overrides the directory heuristic. Each project gets one route. If the project has several listeners, the choice follows the rules in [Per-Project Config](#per-project-config-optional). The route points at the exact address the server listens on, so servers bound only to IPv6 `::1` work too (Node binds `localhost` that way). Once a port is attributed, the route is created and Caddy is reloaded. When the port stops listening, the route is removed.

## Requirements

- macOS 13 (Ventura) or later, Apple Silicon or Intel
- For building: Rust toolchain + Swift 5.9+ (`scripts/build.sh --universal` needs Xcode and both Rust targets)

## Uninstall

**Preferences → Uninstall LocalPort...** removes the DNS resolver, port forwarding, the trusted local CA, LocalPort's data and logs, and the app itself.

## Contributing

Contributions are welcome. Please open an issue first to discuss what you'd like to change.

## License

[MIT](LICENSE)
