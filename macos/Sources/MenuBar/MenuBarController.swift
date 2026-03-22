import AppKit
import os.log

private let logger = Logger(subsystem: "com.devspace.app", category: "MenuBar")

protocol MenuBarControllerDelegate: AnyObject {
    func menuBarDidSelectProject(_ projectID: String)
    func menuBarDidRequestProjectSettings(_ projectID: String)
    func menuBarDidRequestAddProject()
    func menuBarDidRequestPreferences()
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

    func update(projects: [Project], activeProjectID: String?, windowCounts: [String: Int], routes: [String: String] = [:]) {
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

    // MARK: - Menu Construction

    private func rebuildMenu(projects: [Project], activeProjectID: String?, windowCounts: [String: Int] = [:], routes: [String: String] = [:]) {
        menu.removeAllItems()
        projectMenuItems.removeAll()

        // Header
        let header = NSMenuItem()
        header.attributedTitle = NSAttributedString(
            string: "DevSpace",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            ]
        )
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        // Project list
        for (i, project) in projects.enumerated() {
            let isActive = project.id == activeProjectID
            let item = NSMenuItem()

            // Build title with status indicator and notification count
            let bullet = isActive ? "●" : "○"
            var title = "\(bullet) \(project.name)"

            if let notifCount = pendingNotifications[project.id], notifCount > 0 {
                title += "  (\(notifCount) notification\(notifCount == 1 ? "" : "s"))"
            }

            item.title = title
            item.tag = i
            item.target = self
            item.action = #selector(projectSelected(_:))
            item.representedObject = project.id

            // Keyboard shortcut hint
            if i < 9 {
                item.keyEquivalent = "\(i + 1)"
                item.keyEquivalentModifierMask = .control
            }

            // Color indicator via attributed string
            let attrTitle = NSMutableAttributedString(string: title)
            let bulletRange = (title as NSString).range(of: bullet)
            attrTitle.addAttribute(
                .foregroundColor,
                value: project.color.nsColor,
                range: bulletRange
            )
            if isActive {
                attrTitle.addAttribute(
                    .font,
                    value: NSFont.systemFont(ofSize: 14, weight: .medium),
                    range: NSRange(location: 0, length: title.count)
                )
            }
            item.attributedTitle = attrTitle

            menu.addItem(item)

            // Submenu details: hostname, port status, windows
            let windowCount = windowCounts[project.id] ?? 0
            let upstream = routes[project.id]
            let statusText: String
            if let upstream = upstream, let port = upstream.components(separatedBy: ":").last {
                statusText = ":\(port)"
            } else {
                statusText = "stopped"
            }
            let detailString = "    \(project.hostname) · \(statusText) · \(windowCount) window\(windowCount == 1 ? "" : "s")"
            let detailItem = NSMenuItem()
            let detailAttrs = NSMutableAttributedString(
                string: detailString,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            )
            // Color the status: green for running, red for stopped
            let statusRange = (detailString as NSString).range(of: statusText)
            if upstream != nil {
                detailAttrs.addAttribute(.foregroundColor, value: NSColor.systemGreen, range: statusRange)
            } else {
                detailAttrs.addAttribute(.foregroundColor, value: NSColor.systemRed.withAlphaComponent(0.7), range: statusRange)
            }
            detailItem.attributedTitle = detailAttrs
            detailItem.isEnabled = false
            menu.addItem(detailItem)

            // Settings item
            let settingsItem = NSMenuItem()
            settingsItem.attributedTitle = NSAttributedString(
                string: "    Settings...",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.tertiaryLabelColor,
                ]
            )
            settingsItem.target = self
            settingsItem.action = #selector(projectSettingsClicked(_:))
            settingsItem.representedObject = project.id
            menu.addItem(settingsItem)

            projectMenuItems[project.id] = item
        }

        if projects.isEmpty {
            let emptyItem = NSMenuItem()
            emptyItem.title = "  No projects registered"
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

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit DevSpace", action: #selector(quit), keyEquivalent: "q")
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
        let size = NSSize(width: 18, height: 18)

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
