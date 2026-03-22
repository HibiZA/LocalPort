import AppKit
import os.log

private let logger = Logger(subsystem: "com.localport.app", category: "MenuBar")

protocol MenuBarControllerDelegate: AnyObject {
    func menuBarDidSelectProject(_ projectID: String)
    func menuBarDidRequestProjectSettings(_ projectID: String)
    func menuBarDidRequestAddProject()
    func menuBarDidRequestPreferences()
    func menuBarDidRequestUpdate()
    func menuBarDidRequestStartDaemon()
    func menuBarDidRequestStopDaemon()
    func menuBarDidRequestUninstall()
    func menuBarDidRequestQuit()
}

final class MenuBarController: NSObject {
    weak var delegate: MenuBarControllerDelegate?

    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var badgeCount: Int = 0
    private var projectMenuItems: [String: NSMenuItem] = [:]

    // Notification tracking per project
    private var pendingNotifications: [String: Int] = [:]
    private var availableUpdate: String?
    private var daemonConnected: Bool = false

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

        rebuildMenu(projects: [], activeProjectID: nil)
        logger.info("MenuBarController ready")
    }

    func update(projects: [Project], activeProjectID: String?, windowCounts: [String: Int], routes: [String: String] = [:], daemonConnected: Bool = false) {
        self.daemonConnected = daemonConnected
        rebuildMenu(projects: projects, activeProjectID: activeProjectID, windowCounts: windowCounts, routes: routes)
        updateBadge()
    }

    func addNotification(for projectID: String) {
        pendingNotifications[projectID, default: 0] += 1
        updateBadge()
    }

    func clearNotifications(for projectID: String) {
        pendingNotifications.removeValue(forKey: projectID)
        updateBadge()
    }

    func showUpdateAvailable(version: String) {
        availableUpdate = version
        // Trigger a menu rebuild on next open
    }

    // MARK: - Menu Construction

    private func rebuildMenu(projects: [Project], activeProjectID: String?, windowCounts: [String: Int] = [:], routes: [String: String] = [:]) {
        menu.removeAllItems()
        projectMenuItems.removeAll()

        // Header with daemon status inline
        let header = NSMenuItem()
        let dot = "●"
        let dotColor = daemonConnected ? NSColor.systemGreen : NSColor.systemRed.withAlphaComponent(0.7)
        let headerStr = NSMutableAttributedString(
            string: "LocalPort  \(dot)",
            attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]
        )
        let dotRange = (headerStr.string as NSString).range(of: dot)
        headerStr.addAttribute(.foregroundColor, value: dotColor, range: dotRange)
        headerStr.addAttribute(.font, value: NSFont.systemFont(ofSize: 8), range: dotRange)
        header.attributedTitle = headerStr
        header.target = self
        header.action = daemonConnected ? #selector(stopDaemon) : #selector(startDaemon)
        header.toolTip = daemonConnected ? "Click to stop daemon" : "Click to start daemon"
        menu.addItem(header)

        menu.addItem(.separator())

        // Project list — one line per project
        for (i, project) in projects.enumerated() {
            let item = NSMenuItem()
            item.tag = i
            item.target = self
            item.action = #selector(projectSelected(_:))
            item.representedObject = project.id

            // Keyboard shortcut
            if i < 9 {
                item.keyEquivalent = "\(i + 1)"
                item.keyEquivalentModifierMask = .control
            }

            // Build: "● name  hostname · :port" or "○ name  hostname · stopped"
            let isActive = project.id == activeProjectID
            let bullet = isActive ? "●" : "○"
            let upstream = routes[project.id]
            let portStatus: String
            if let upstream = upstream, let port = upstream.components(separatedBy: ":").last {
                portStatus = ":\(port)"
            } else {
                portStatus = "stopped"
            }
            let title = "\(bullet) \(project.name)  \(project.hostname) · \(portStatus)"

            let attrTitle = NSMutableAttributedString(string: title)

            // Color the bullet with project color
            let bulletRange = NSRange(location: 0, length: 1)
            attrTitle.addAttribute(.foregroundColor, value: project.color.nsColor, range: bulletRange)

            // Dim the hostname + status portion
            let detailStart = (title as NSString).range(of: "  \(project.hostname)").location
            if detailStart != NSNotFound {
                let detailRange = NSRange(location: detailStart, length: title.count - detailStart)
                attrTitle.addAttribute(.font, value: NSFont.systemFont(ofSize: 12), range: detailRange)
                attrTitle.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: detailRange)
            }

            // Color the port status
            let portRange = (title as NSString).range(of: portStatus)
            if upstream != nil {
                attrTitle.addAttribute(.foregroundColor, value: NSColor.systemGreen, range: portRange)
            } else {
                attrTitle.addAttribute(.foregroundColor, value: NSColor.systemRed.withAlphaComponent(0.7), range: portRange)
            }

            if isActive {
                attrTitle.addAttribute(.font, value: NSFont.systemFont(ofSize: 14, weight: .medium), range: NSRange(location: 0, length: detailStart != NSNotFound ? detailStart : title.count))
            }

            item.attributedTitle = attrTitle

            // Settings in submenu
            let sub = NSMenu()
            let settingsItem = NSMenuItem(title: "Settings...", action: #selector(projectSettingsClicked(_:)), keyEquivalent: "")
            settingsItem.target = self
            settingsItem.representedObject = project.id
            sub.addItem(settingsItem)
            item.submenu = sub

            menu.addItem(item)
            projectMenuItems[project.id] = item
        }

        if projects.isEmpty {
            let emptyItem = NSMenuItem()
            emptyItem.title = "No projects"
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
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

        let uninstallItem = NSMenuItem(title: "Uninstall LocalPort...", action: #selector(uninstall), keyEquivalent: "")
        uninstallItem.target = self
        menu.addItem(uninstallItem)

        let quitItem = NSMenuItem(title: "Quit LocalPort", action: #selector(quit), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = .command
        quitItem.target = self
        menu.addItem(quitItem)
    }

    // MARK: - Badge

    private func updateBadge() {
        let total = pendingNotifications.values.reduce(0, +)
        if let button = statusItem.button {
            button.title = total > 0 ? " \(total)" : ""
            button.image = makeIcon(badge: total > 0)
        }
    }

    private func makeIcon(badge: Bool = false) -> NSImage {
        // Load the icon image from the app bundle's Resources
        let bundle = Bundle.main
        let size = NSSize(width: 22, height: 22)

        // Try @2x first, fall back to 1x
        if let path = bundle.path(forResource: "MenuBarIcon@2x", ofType: "png"),
           let img = NSImage(contentsOfFile: path) {
            img.size = size
            img.isTemplate = true
            return img
        }
        if let path = bundle.path(forResource: "MenuBarIcon", ofType: "png"),
           let img = NSImage(contentsOfFile: path) {
            img.size = size
            img.isTemplate = true
            return img
        }

        // During development (no bundle), load from source tree
        let devPaths = [
            "macos/Resources/MenuBarIcon@2x.png",
            "Resources/MenuBarIcon@2x.png",
            "../macos/Resources/MenuBarIcon@2x.png",
        ]
        for devPath in devPaths {
            if let img = NSImage(contentsOfFile: devPath) {
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

    @objc private func startDaemon() {
        delegate?.menuBarDidRequestStartDaemon()
    }

    @objc private func stopDaemon() {
        delegate?.menuBarDidRequestStopDaemon()
    }

    @objc private func uninstall() {
        delegate?.menuBarDidRequestUninstall()
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
    func menuWillOpen(_ menu: NSMenu) {
        // Could refresh state here if needed
    }
}
