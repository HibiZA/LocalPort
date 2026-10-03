import AppKit
import os.log

private let logger = Logger(subsystem: "com.localport.app", category: "MenuBar")

protocol MenuBarControllerDelegate: AnyObject {
    func menuBarDidSelectProject(_ projectID: String)
    func menuBarDidSelectRoute(hostname: String)
    func menuBarDidRequestCopyURL(hostname: String)
    func menuBarDidRequestReveal(_ projectID: String)
    func menuBarDidRequestProjectSettings(_ projectID: String)
    func menuBarDidRequestOpenUnclaimed(port: Int)
    func menuBarDidRequestAddProject(directory: String)
    func menuBarDidRequestAssign(port: Int, to projectID: String)
    func menuBarDidRequestAddProject()
    func menuBarDidRequestPreferences()
    func menuBarDidRequestOpenLogs()
    func menuBarDidRequestUpdate()
    func menuBarDidRequestStartDaemon()
    func menuBarDidRequestStopDaemon()
    func menuBarDidRequestQuit()
}

/// Everything the menu displays.
struct MenuState {
    var daemonConnected = false
    /// Proxy state from the daemon ("running", "starting", "downloading", "failed", …).
    var proxyState: String?
    var proxyError: String?
    var projects: [Project] = []
    /// project.id -> upstream ("127.0.0.1:3000") for running projects.
    var upstreams: [String: String] = [:]
    /// Live routes not belonging to a registered project (e.g. `localport run` tags).
    var otherRoutes: [(hostname: String, upstream: String)] = []
    /// hostname -> process serving it.
    var owners: [String: RouteOwner] = [:]
    /// Listening dev servers no project claims.
    var unclaimed: [UnclaimedPort] = []
}

final class MenuBarController: NSObject {
    weak var delegate: MenuBarControllerDelegate?

    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var state = MenuState()
    private var availableUpdate: String?

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = makeIcon()
            button.imagePosition = .imageLeading
            button.title = ""
        }

        menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        logger.info("MenuBarController ready")
    }

    /// Store the latest state; the menu is rebuilt when it's next opened, so
    /// periodic refreshes never rebuild a menu the user is looking at.
    func update(_ state: MenuState) {
        self.state = state
    }

    func showUpdateAvailable(version: String) {
        availableUpdate = version
    }

    // MARK: - Menu Construction

    private func rebuildMenu() {
        menu.removeAllItems()

        menu.addItem(headerItem())
        if let detail = proxyDetail() {
            let item = NSMenuItem()
            item.attributedTitle = NSAttributedString(
                string: detail,
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
            )
            item.toolTip = state.proxyError
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())

        for project in state.projects {
            let upstream = state.upstreams[project.id]
            let item = statusLine(
                bulletColor: project.color.nsColor,
                running: upstream != nil,
                title: project.name,
                hostname: project.hostname,
                upstream: upstream
            )
            item.target = self
            item.action = #selector(projectSelected(_:))
            item.representedObject = project.id

            let sub = NSMenu()
            if let upstream {
                sub.addItem(ownerItem(state.owners[project.hostname], upstream: upstream))
                sub.addItem(.separator())
            }
            sub.addItem(action("Open in Browser", #selector(projectSelected(_:)), project.id))
            sub.addItem(action("Copy URL", #selector(copyURL(_:)), project.hostname))
            sub.addItem(action("Reveal in Finder", #selector(revealProject(_:)), project.id))
            sub.addItem(.separator())
            sub.addItem(action("Settings...", #selector(projectSettingsClicked(_:)), project.id))
            item.submenu = sub

            menu.addItem(item)
        }

        if state.projects.isEmpty {
            let emptyItem = NSMenuItem()
            emptyItem.title = "No projects"
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        }

        if !state.otherRoutes.isEmpty {
            menu.addItem(.separator())
            let heading = NSMenuItem(title: "Other Routes", action: nil, keyEquivalent: "")
            heading.isEnabled = false
            menu.addItem(heading)
            for route in state.otherRoutes {
                let name = route.hostname.components(separatedBy: ".").first ?? route.hostname
                let item = statusLine(
                    bulletColor: .secondaryLabelColor,
                    running: true,
                    title: name,
                    hostname: route.hostname,
                    upstream: route.upstream
                )
                item.target = self
                item.action = #selector(routeSelected(_:))
                item.representedObject = route.hostname

                let sub = NSMenu()
                sub.addItem(ownerItem(state.owners[route.hostname], upstream: route.upstream))
                sub.addItem(.separator())
                sub.addItem(action("Open in Browser", #selector(routeSelected(_:)), route.hostname))
                sub.addItem(action("Copy URL", #selector(copyURL(_:)), route.hostname))
                item.submenu = sub
                menu.addItem(item)
            }
        }

        if !state.unclaimed.isEmpty {
            menu.addItem(.separator())
            menu.addItem(unclaimedItem())
        }

        // Actions
        menu.addItem(.separator())

        let addItem = NSMenuItem(title: "Add Project...", action: #selector(addProject), keyEquivalent: "n")
        addItem.keyEquivalentModifierMask = .command
        addItem.target = self
        menu.addItem(addItem)

        let prefsItem = NSMenuItem(title: "Preferences...", action: #selector(openPreferences), keyEquivalent: ",")
        prefsItem.keyEquivalentModifierMask = .command
        prefsItem.target = self
        menu.addItem(prefsItem)

        let logsItem = NSMenuItem(title: "Open Logs", action: #selector(openLogs), keyEquivalent: "")
        logsItem.target = self
        menu.addItem(logsItem)

        if let version = availableUpdate {
            menu.addItem(.separator())
            let updateItem = NSMenuItem()
            updateItem.attributedTitle = NSAttributedString(
                string: "Update Available: v\(version)",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                    .foregroundColor: NSColor.systemBlue,
                ]
            )
            updateItem.target = self
            updateItem.action = #selector(openUpdate)
            menu.addItem(updateItem)
        }

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit LocalPort", action: #selector(quit), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = .command
        quitItem.target = self
        menu.addItem(quitItem)
    }

    /// "LocalPort ●" — green when routing works, orange when the daemon is up
    /// but the proxy isn't, red when the daemon is unreachable.
    private func headerItem() -> NSMenuItem {
        let header = NSMenuItem()
        let dot = "●"
        let dotColor: NSColor
        if !state.daemonConnected {
            dotColor = NSColor.systemRed.withAlphaComponent(0.7)
        } else if state.proxyState == "running" {
            dotColor = .systemGreen
        } else {
            dotColor = .systemOrange
        }
        let headerStr = NSMutableAttributedString(
            string: "LocalPort  \(dot)",
            attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]
        )
        let dotRange = (headerStr.string as NSString).range(of: dot)
        headerStr.addAttribute(.foregroundColor, value: dotColor, range: dotRange)
        headerStr.addAttribute(.font, value: NSFont.systemFont(ofSize: 8), range: dotRange)
        header.attributedTitle = headerStr
        header.target = self
        header.action = state.daemonConnected ? #selector(stopDaemon) : #selector(startDaemon)
        header.toolTip = state.daemonConnected ? "Click to stop daemon" : "Click to start daemon"
        return header
    }

    private func proxyDetail() -> String? {
        guard state.daemonConnected else { return "Daemon not running" }
        switch state.proxyState {
        case "running", nil: return nil
        case "downloading": return "Downloading Caddy…"
        case "starting": return "Starting proxy…"
        case "failed":
            let error = state.proxyError ?? "unknown error"
            return "Proxy failed: " + (error.count > 60 ? String(error.prefix(57)) + "…" : error)
        default: return "Proxy \(state.proxyState ?? "")"
        }
    }

    private func action(_ title: String, _ selector: Selector, _ object: Any) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.representedObject = object
        return item
    }

    /// Disabled info line: "node (pid 123) · [::1]:5173 · via localport run".
    private func ownerItem(_ owner: RouteOwner?, upstream: String) -> NSMenuItem {
        var parts: [String] = []
        if let owner {
            parts.append("\(owner.process ?? "process") (pid \(owner.pid))")
        }
        parts.append(upstream)
        switch owner?.source {
        case "claim": parts.append("assigned port")
        case "tag": parts.append("via localport run")
        default: break
        }
        let item = NSMenuItem(title: parts.joined(separator: " · "), action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// "Unclaimed Ports" submenu: one entry per dev server no project claims,
    /// each offering to open it, add its folder as a project, or assign the
    /// port to an existing project.
    private func unclaimedItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Unclaimed Ports (\(state.unclaimed.count))", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for port in state.unclaimed {
            var title = "\(port.process ?? "pid \(port.pid)") · :\(port.port)"
            if let cwd = port.cwd, Self.isProjectCandidate(cwd) {
                title += "  " + Self.abbreviate(cwd)
            }
            let row = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let actions = NSMenu()
            actions.addItem(action("Open http://localhost:\(port.port)", #selector(openUnclaimed(_:)), port.port))
            if let cwd = port.cwd, Self.isProjectCandidate(cwd),
               !state.projects.contains(where: { $0.directory == cwd }) {
                let name = (cwd as NSString).lastPathComponent
                actions.addItem(action("Add \u{201C}\(name)\u{201D} as Project", #selector(addUnclaimedProject(_:)), cwd))
            }
            if !state.projects.isEmpty {
                let assign = NSMenuItem(title: "Assign to Project", action: nil, keyEquivalent: "")
                let targets = NSMenu()
                for project in state.projects {
                    targets.addItem(action(project.name, #selector(assignPort(_:)), [port.port, project.id] as [Any]))
                }
                assign.submenu = targets
                actions.addItem(assign)
            }
            row.submenu = actions
            sub.addItem(row)
        }
        item.submenu = sub
        return item
    }

    /// A working directory worth offering as a project: not `/`, the home
    /// folder itself, or an app's sandbox container under ~/Library.
    private static func isProjectCandidate(_ dir: String) -> Bool {
        let home = NSHomeDirectory()
        return dir != "/" && dir != home && !dir.hasPrefix(home + "/Library/")
    }

    private static func abbreviate(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    /// "● name  hostname · :port" (running) or "○ name  hostname · stopped".
    private func statusLine(bulletColor: NSColor, running: Bool, title: String, hostname: String, upstream: String?) -> NSMenuItem {
        let item = NSMenuItem()
        let bullet = running ? "●" : "○"
        let portStatus: String
        if let upstream, let port = upstream.components(separatedBy: ":").last {
            portStatus = ":\(port)"
        } else {
            portStatus = "stopped"
        }
        let title = "\(bullet) \(title)  \(hostname) · \(portStatus)"
        let attrTitle = NSMutableAttributedString(string: title)
        let ns = title as NSString

        attrTitle.addAttribute(.foregroundColor, value: bulletColor, range: NSRange(location: 0, length: 1))

        let detailStart = ns.range(of: "  \(hostname)").location
        if detailStart != NSNotFound {
            let detailRange = NSRange(location: detailStart, length: ns.length - detailStart)
            attrTitle.addAttribute(.font, value: NSFont.systemFont(ofSize: 12), range: detailRange)
            attrTitle.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: detailRange)
        }

        let portRange = ns.range(of: portStatus, options: .backwards)
        attrTitle.addAttribute(
            .foregroundColor,
            value: running ? NSColor.systemGreen : NSColor.systemRed.withAlphaComponent(0.7),
            range: portRange
        )

        item.attributedTitle = attrTitle
        return item
    }

    private func makeIcon() -> NSImage {
        let size = NSSize(width: 22, height: 22)

        // Bundle resources first (@2x preferred), then the source tree during development.
        let bundle = Bundle.main
        let candidates = [
            bundle.path(forResource: "MenuBarIcon@2x", ofType: "png"),
            bundle.path(forResource: "MenuBarIcon", ofType: "png"),
            "macos/Resources/MenuBarIcon@2x.png",
            "Resources/MenuBarIcon@2x.png",
            "../macos/Resources/MenuBarIcon@2x.png",
        ].compactMap { $0 }
        for path in candidates {
            if let img = NSImage(contentsOfFile: path) {
                img.size = size
                img.isTemplate = true
                return img
            }
        }

        // Final fallback: simple dot
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 4, dy: 4)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - Actions

    @objc private func projectSelected(_ sender: NSMenuItem) {
        guard let projectID = sender.representedObject as? String else { return }
        delegate?.menuBarDidSelectProject(projectID)
    }

    @objc private func routeSelected(_ sender: NSMenuItem) {
        guard let hostname = sender.representedObject as? String else { return }
        delegate?.menuBarDidSelectRoute(hostname: hostname)
    }

    @objc private func copyURL(_ sender: NSMenuItem) {
        guard let hostname = sender.representedObject as? String else { return }
        delegate?.menuBarDidRequestCopyURL(hostname: hostname)
    }

    @objc private func revealProject(_ sender: NSMenuItem) {
        guard let projectID = sender.representedObject as? String else { return }
        delegate?.menuBarDidRequestReveal(projectID)
    }

    @objc private func openUnclaimed(_ sender: NSMenuItem) {
        guard let port = sender.representedObject as? Int else { return }
        delegate?.menuBarDidRequestOpenUnclaimed(port: port)
    }

    @objc private func addUnclaimedProject(_ sender: NSMenuItem) {
        guard let directory = sender.representedObject as? String else { return }
        delegate?.menuBarDidRequestAddProject(directory: directory)
    }

    @objc private func assignPort(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [Any],
              let port = pair.first as? Int, let projectID = pair.last as? String else { return }
        delegate?.menuBarDidRequestAssign(port: port, to: projectID)
    }

    @objc private func projectSettingsClicked(_ sender: NSMenuItem) {
        guard let projectID = sender.representedObject as? String else { return }
        delegate?.menuBarDidRequestProjectSettings(projectID)
    }

    @objc private func addProject() {
        delegate?.menuBarDidRequestAddProject()
    }

    @objc private func openPreferences() {
        delegate?.menuBarDidRequestPreferences()
    }

    @objc private func openLogs() {
        delegate?.menuBarDidRequestOpenLogs()
    }

    @objc private func startDaemon() {
        delegate?.menuBarDidRequestStartDaemon()
    }

    @objc private func stopDaemon() {
        delegate?.menuBarDidRequestStopDaemon()
    }

    @objc private func openUpdate() {
        delegate?.menuBarDidRequestUpdate()
    }

    @objc private func quit() {
        delegate?.menuBarDidRequestQuit()
    }
}

// MARK: - NSMenuDelegate

extension MenuBarController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }
}
