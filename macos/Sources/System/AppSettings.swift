import AppKit

/// App-side preferences (UserDefaults). Daemon settings — TLD, ports, log
/// level — live in `config.toml` instead; see `ConfigFile`.
enum AppSettings {
    enum Key {
        static let browser = "browserBundleID"
        static let editor = "editorBundleID"
        static let notifyOnStatusChange = "notifyOnStatusChange"
        static let showUnclaimedPorts = "showUnclaimedPorts"
        static let checkForUpdates = "checkForUpdates"
        static let installUpdatesAutomatically = "installUpdatesAutomatically"
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.browser: "",
            Key.editor: "",
            Key.notifyOnStatusChange: false,
            Key.showUnclaimedPorts: true,
            Key.checkForUpdates: true,
            Key.installUpdatesAutomatically: false,
        ])
    }

    /// Bundle ID of the browser that opens projects; empty = system default.
    static var browserBundleID: String { UserDefaults.standard.string(forKey: Key.browser) ?? "" }
    /// Bundle ID of the editor that opens project folders; empty = the first installed one.
    static var editorBundleID: String { UserDefaults.standard.string(forKey: Key.editor) ?? "" }
    static var notifyOnStatusChange: Bool { UserDefaults.standard.bool(forKey: Key.notifyOnStatusChange) }
    static var showUnclaimedPorts: Bool { UserDefaults.standard.bool(forKey: Key.showUnclaimedPorts) }
    static var checkForUpdates: Bool { UserDefaults.standard.bool(forKey: Key.checkForUpdates) }
    static var installUpdatesAutomatically: Bool { UserDefaults.standard.bool(forKey: Key.installUpdatesAutomatically) }

    /// Open a project URL in the chosen browser (or the default one).
    static func openInBrowser(_ url: URL) {
        guard !browserBundleID.isEmpty,
              let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browserBundleID) else {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    struct App: Identifiable {
        let id: String  // bundle ID
        let name: String
        let url: URL
        let icon: NSImage

        init?(url appURL: URL) {
            guard let id = Bundle(url: appURL)?.bundleIdentifier else { return nil }
            self.id = id
            name = FileManager.default.displayName(atPath: appURL.path)
                .replacingOccurrences(of: ".app", with: "")
            url = appURL
            icon = NSWorkspace.shared.icon(forFile: appURL.path)
            icon.size = NSSize(width: 16, height: 16)
        }
    }

    /// Apps registered to open https URLs.
    static func installedBrowsers() -> [App] {
        let probe = URL(string: "https://example.test")!
        var seen = Set<String>()
        return NSWorkspace.shared.urlsForApplications(toOpen: probe).compactMap { appURL in
            guard let app = App(url: appURL), seen.insert(app.id).inserted else { return nil }
            return app
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Editors that open a folder handed to them by `NSWorkspace`, in the
    /// order the automatic choice prefers. (Apps that only bring their window
    /// forward, such as T3 Code, can't be listed.)
    private static let editorBundleIDs = [
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92",  // Cursor
        "com.exafunction.windsurf",
        "dev.zed.Zed",
        "com.microsoft.VSCodeInsiders",
        "dev.zed.Zed-Preview",
        "com.sublimetext.4",
        "com.panic.Nova",
        "com.jetbrains.WebStorm",
        "com.jetbrains.intellij",
        "com.jetbrains.intellij.ce",
        "com.jetbrains.pycharm",
        "com.jetbrains.pycharm.ce",
        "com.jetbrains.rustrover",
        "com.jetbrains.goland",
        "com.jetbrains.PhpStorm",
        "com.jetbrains.rubymine",
        "com.apple.dt.Xcode",
    ]

    static func installedEditors() -> [App] {
        editorBundleIDs.compactMap { id in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).flatMap(App.init(url:))
        }
    }

    /// The chosen editor if it's still installed, else the first one found.
    static func preferredEditor(in editors: [App]) -> App? {
        editors.first { $0.id == editorBundleID } ?? editors.first
    }

    static func open(directory: String, in editor: App) {
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: directory, isDirectory: true)],
            withApplicationAt: editor.url,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }
}
