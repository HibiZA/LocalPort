import AppKit
import ServiceManagement
import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.localport.app", category: "Preferences")

extension Notification.Name {
    static let localportUninstallRequested = Notification.Name("localportUninstallRequested")
    /// Posted with the new TLD as `object` when the user changes it.
    static let localportTLDChangeRequested = Notification.Name("localportTLDChangeRequested")
}

// MARK: - SwiftUI Preferences View

private struct PreferencesView: View {
    @State private var tld: String
    @State private var launchAtLogin: Bool

    init() {
        _tld = State(initialValue: ConfigFile.tld())
        _launchAtLogin = State(initialValue: SMAppService.mainApp.status == .enabled)
    }

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }

            aboutTab
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480, height: 360)
    }

    // MARK: General

    private var generalTab: some View {
        Form {
            Section("Networking") {
                Picker("TLD", selection: $tld) {
                    Text(".test (HTTPS)").tag("test")
                    Text(".localhost (HTTP)").tag("localhost")
                }
                .onChange(of: tld) { val in
                    // Writes config.toml and restarts the daemon; switching to
                    // .test may prompt for the admin password to set up DNS.
                    NotificationCenter.default.post(name: .localportTLDChangeRequested, object: val)
                }

                if tld == "localhost" {
                    Text("Projects accessible at http://myproject.localhost:\(String(ConfigFile.httpPort()))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Projects accessible at https://myproject.\(tld)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Startup") {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { val in
                        do {
                            if val {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            logger.error("Failed to update login item: \(error)")
                            launchAtLogin = !val
                        }
                    }
                    .disabled(!Bundle.main.bundlePath.hasPrefix("/Applications"))

                if !Bundle.main.bundlePath.hasPrefix("/Applications") {
                    Text("Move LocalPort to /Applications to enable this")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button("Uninstall LocalPort...", role: .destructive) {
                    NotificationCenter.default.post(name: .localportUninstallRequested, object: nil)
                }
                .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: About

    private var aboutTab: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(nsImage: Self.loadAppIcon())
                .resizable()
                .frame(width: 96, height: 96)

            Text("LocalPort")
                .font(.title.bold())

            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? appVersion)")
                .foregroundStyle(.secondary)

            Text("Run multiple projects with unique local hostnames.\nNo more remembering port numbers.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.tertiary)
                .padding(.horizontal)

            Link("GitHub", destination: URL(string: "https://github.com/HibiZA/LocalPort")!)
                .foregroundStyle(.blue)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private static func loadAppIcon() -> NSImage {
        // Try bundle resource first (works in .app bundle)
        if let path = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
           let img = NSImage(contentsOfFile: path) {
            return img
        }
        // Development fallback: look relative to working directory
        for devPath in ["macos/Resources/AppIcon.icns", "Resources/AppIcon.icns", "../macos/Resources/AppIcon.icns"] {
            if let img = NSImage(contentsOfFile: devPath) {
                return img
            }
        }
        return NSApp.applicationIconImage
    }
}

// MARK: - AppKit Window Controller (preserves existing API)

final class PreferencesWindowController: NSWindowController {
    static let shared = PreferencesWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Preferences"
        window.center()
        window.isReleasedWhenClosed = false

        super.init(window: window)

        window.contentView = NSHostingView(rootView: PreferencesView())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func showWindow() {
        NSApp.setActivationPolicy(.regular)
        // Fresh view each time so it reflects the current config.
        window?.contentView = NSHostingView(rootView: PreferencesView())
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if closeObserver == nil {
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { _ in
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    private var closeObserver: NSObjectProtocol?
}
