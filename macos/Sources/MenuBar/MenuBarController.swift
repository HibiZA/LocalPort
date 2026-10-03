import AppKit
import SwiftUI
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

/// Everything the popover displays.
struct MenuState {
    var daemonConnected = false
    /// Proxy state from the daemon ("running", "starting", "downloading", "failed", …).
    var proxyState: String?
    var proxyError: String?
    var tld: String?
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

/// The status item and its SwiftUI popover.
final class MenuBarController: NSObject {
    weak var delegate: MenuBarControllerDelegate?

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let model = PopoverModel()

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = Self.icon(size: 18)
            button.target = self
            button.action = #selector(togglePopover)
        }

        bindActions()
        let host = NSHostingController(rootView: PopoverView(model: model))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true

        logger.info("MenuBarController ready")
    }

    func update(_ state: MenuState) {
        model.state = state
    }

    func showUpdateAvailable(version: String) {
        model.availableUpdate = version
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // An accessory app must be active for the popover to take key
            // events and close when the user clicks elsewhere.
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// Close the popover, then run `action`; used for anything that opens a
    /// window or another app, so the popover doesn't sit on top of it.
    private func closing(_ action: @escaping () -> Void) -> () -> Void {
        { [weak self] in
            self?.popover.performClose(nil)
            action()
        }
    }

    private func bindActions() {
        model.openProject = { [weak self] id in self?.closing { self?.delegate?.menuBarDidSelectProject(id) }() }
        model.openRoute = { [weak self] host in self?.closing { self?.delegate?.menuBarDidSelectRoute(hostname: host) }() }
        model.copyURL = { [weak self] host in self?.delegate?.menuBarDidRequestCopyURL(hostname: host) }
        model.reveal = { [weak self] id in self?.closing { self?.delegate?.menuBarDidRequestReveal(id) }() }
        model.projectSettings = { [weak self] id in
            self?.closing { self?.delegate?.menuBarDidRequestProjectSettings(id) }()
        }
        model.openUnclaimed = { [weak self] port in
            self?.closing { self?.delegate?.menuBarDidRequestOpenUnclaimed(port: port) }()
        }
        model.addProjectAt = { [weak self] dir in self?.delegate?.menuBarDidRequestAddProject(directory: dir) }
        model.assign = { [weak self] port, id in self?.delegate?.menuBarDidRequestAssign(port: port, to: id) }
        model.addProject = closing { [weak self] in self?.delegate?.menuBarDidRequestAddProject() }
        model.preferences = closing { [weak self] in self?.delegate?.menuBarDidRequestPreferences() }
        model.openLogs = closing { [weak self] in self?.delegate?.menuBarDidRequestOpenLogs() }
        model.openUpdate = closing { [weak self] in self?.delegate?.menuBarDidRequestUpdate() }
        model.startDaemon = { [weak self] in self?.delegate?.menuBarDidRequestStartDaemon() }
        model.stopDaemon = { [weak self] in self?.delegate?.menuBarDidRequestStopDaemon() }
        model.quit = { [weak self] in self?.delegate?.menuBarDidRequestQuit() }
    }

    /// The full-colour app icon, for the popover header.
    static let appIcon: NSImage = {
        if let path = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
           let image = NSImage(contentsOfFile: path) {
            return image
        }
        // Running outside the bundle (swift run): use the source tree's copy.
        for path in ["macos/Resources/AppIcon.icns", "Resources/AppIcon.icns"] {
            if let image = NSImage(contentsOfFile: path) { return image }
        }
        return NSApp.applicationIconImage
    }()

    /// The LocalPort mark as a template image (adapts to light/dark),
    /// `height` points tall.
    static func icon(size height: CGFloat) -> NSImage {

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
            if let img = NSImage(contentsOfFile: path), img.size.height > 0 {
                // Keep the artwork's aspect ratio (it isn't square).
                img.size = NSSize(width: height * img.size.width / img.size.height, height: height)
                img.isTemplate = true
                return img
            }
        }

        // Final fallback: simple dot
        let image = NSImage(size: NSSize(width: height, height: height), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: rect.width / 5, dy: rect.height / 5)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
