import AppKit

/// App-side preferences (UserDefaults). Daemon settings — TLD, ports, log
/// level — live in `config.toml` instead; see `ConfigFile`.
enum AppSettings {
    enum Key {
        static let browser = "browserBundleID"
        static let notifyOnStatusChange = "notifyOnStatusChange"
        static let showUnclaimedPorts = "showUnclaimedPorts"
        static let checkForUpdates = "checkForUpdates"
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.browser: "",
            Key.notifyOnStatusChange: false,
            Key.showUnclaimedPorts: true,
            Key.checkForUpdates: true,
        ])
    }

    /// Bundle ID of the browser that opens projects; empty = system default.
    static var browserBundleID: String { UserDefaults.standard.string(forKey: Key.browser) ?? "" }
    static var notifyOnStatusChange: Bool { UserDefaults.standard.bool(forKey: Key.notifyOnStatusChange) }
    static var showUnclaimedPorts: Bool { UserDefaults.standard.bool(forKey: Key.showUnclaimedPorts) }
    static var checkForUpdates: Bool { UserDefaults.standard.bool(forKey: Key.checkForUpdates) }

    /// Open a project URL in the chosen browser (or the default one).
    static func openInBrowser(_ url: URL) {
        guard !browserBundleID.isEmpty,
              let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browserBundleID) else {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    struct Browser: Identifiable {
        let id: String  // bundle ID
        let name: String
        let icon: NSImage
    }

    /// Apps registered to open https URLs.
    static func installedBrowsers() -> [Browser] {
        let probe = URL(string: "https://example.test")!
        var seen = Set<String>()
        return NSWorkspace.shared.urlsForApplications(toOpen: probe).compactMap { appURL in
            guard let bundle = Bundle(url: appURL), let id = bundle.bundleIdentifier,
                  seen.insert(id).inserted else { return nil }
            let name = FileManager.default.displayName(atPath: appURL.path)
                .replacingOccurrences(of: ".app", with: "")
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            icon.size = NSSize(width: 16, height: 16)
            return Browser(id: id, name: name, icon: icon)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
