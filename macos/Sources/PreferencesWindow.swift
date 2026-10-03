import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications
import os.log

private let logger = Logger(subsystem: "com.localport.app", category: "Preferences")

extension Notification.Name {
    static let localportUninstallRequested = Notification.Name("localportUninstallRequested")
    /// Posted with the new TLD as `object` when the user changes it.
    static let localportTLDChangeRequested = Notification.Name("localportTLDChangeRequested")
    /// config.toml changed (ports, log level): restart the daemon.
    static let localportConfigChanged = Notification.Name("localportConfigChanged")
    static let localportRestartDaemonRequested = Notification.Name("localportRestartDaemonRequested")
    /// Re-run setup.sh even if the configuration looks current.
    static let localportSetupRequested = Notification.Name("localportSetupRequested")
    static let localportOpenLogsRequested = Notification.Name("localportOpenLogsRequested")
}

// MARK: - SwiftUI Preferences View

private enum SettingsTab: CaseIterable {
    case general, network, certificate, advanced, about

    var title: String {
        switch self {
        case .general: return "General"
        case .network: return "Network"
        case .certificate: return "Certificate"
        case .advanced: return "Advanced"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .network: return "network"
        case .certificate: return "lock.shield"
        case .advanced: return "wrench.and.screwdriver"
        case .about: return "info.circle"
        }
    }
}

private struct PreferencesView: View {
    @State private var tab: SettingsTab = .general

    var body: some View {
        VStack(spacing: 0) {
            SteelTabBar(
                items: SettingsTab.allCases.enumerated().map { index, item in
                    .init(
                        value: item, symbol: item.symbol, title: item.title,
                        shortcut: KeyEquivalent(Character(String(index + 1)))
                    )
                },
                selection: $tab,
                vertical: true
            )
            .padding(.horizontal, 16)
            .padding(.top, 12)

            Group {
                switch tab {
                case .general: GeneralSettings()
                case .network: NetworkSettings()
                case .certificate: CertificateSettings()
                case .advanced: AdvancedSettings()
                case .about: AboutView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 520, height: 600)
        .background(Steel.background)
        .tint(Steel.ice)
        .environment(\.colorScheme, .dark)
    }
}

private func post(_ name: Notification.Name, _ object: Any? = nil) {
    NotificationCenter.default.post(name: name, object: object)
}

private struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: General

private struct GeneralSettings: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage(AppSettings.Key.browser) private var browser = ""
    @AppStorage(AppSettings.Key.notifyOnStatusChange) private var notify = false
    @AppStorage(AppSettings.Key.checkForUpdates) private var checkForUpdates = true
    @State private var browsers: [AppSettings.Browser] = []
    @State private var notificationsDenied = false

    private var inApplications: Bool { Bundle.main.bundlePath.hasPrefix("/Applications") }

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            logger.error("Failed to update login item: \(error)")
                            launchAtLogin = !enabled
                        }
                    }
                    .disabled(!inApplications)
                if !inApplications {
                    Caption("Move LocalPort to /Applications to enable this.")
                }
            }

            Section("Browser") {
                Picker("Open projects in", selection: $browser) {
                    Text("Default browser").tag("")
                    if !browsers.isEmpty { Divider() }
                    ForEach(browsers) { app in
                        Label { Text(app.name) } icon: { Image(nsImage: app.icon) }
                            .tag(app.id)
                    }
                }
            }

            Section("Notifications") {
                Toggle("Notify when a project starts or stops", isOn: $notify)
                    .onChange(of: notify) { enabled in
                        guard enabled else { return }
                        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                            DispatchQueue.main.async {
                                notificationsDenied = !granted
                                if !granted { notify = false }
                            }
                        }
                    }
                if notificationsDenied {
                    Caption("Notifications are turned off for LocalPort in System Settings → Notifications.")
                }
            }

            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $checkForUpdates)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear { browsers = AppSettings.installedBrowsers() }
    }
}

// MARK: Network

private struct NetworkSettings: View {
    @State private var tld = ConfigFile.tld()
    @AppStorage(AppSettings.Key.showUnclaimedPorts) private var showUnclaimed = true
    @State private var httpPort = String(ConfigFile.httpPort())
    @State private var httpsPort = String(ConfigFile.httpsPort())
    @State private var dnsPort = String(ConfigFile.dnsPort())
    @State private var portError: String?
    @State private var applied = false

    private var portsChanged: Bool {
        httpPort != String(ConfigFile.httpPort())
            || httpsPort != String(ConfigFile.httpsPort())
            || dnsPort != String(ConfigFile.dnsPort())
    }

    var body: some View {
        Form {
            Section("Domain") {
                Picker("Top-level domain", selection: $tld) {
                    Text(".test (HTTPS)").tag("test")
                    Text(".localhost (HTTP)").tag("localhost")
                }
                .onChange(of: tld) { value in
                    // Writes config.toml and restarts the daemon; switching to
                    // .test may prompt for the admin password to set up DNS.
                    post(.localportTLDChangeRequested, value)
                }
                if tld == "localhost" {
                    Caption("Projects open at http://myproject.localhost:\(httpPort). No DNS or certificate setup needed.")
                } else {
                    Caption("Projects open at https://myproject.\(tld).")
                }
            }

            Section("Discovery") {
                Toggle("Show unclaimed ports", isOn: $showUnclaimed)
                Caption("Lists dev servers LocalPort can see but can't match to a project, so you can add or assign them.")
            }

            Section {
                portField("HTTP", text: $httpPort)
                portField("HTTPS", text: $httpsPort)
                portField("DNS", text: $dnsPort)
                HStack {
                    if let portError {
                        Label(portError, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Steel.amber)
                    } else if applied {
                        Label("Saved. The daemon restarted.", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(Steel.ice)
                    }
                    Spacer()
                    Button("Defaults") {
                        httpPort = "47080"
                        httpsPort = "47443"
                        dnsPort = "5553"
                    }
                    Button("Apply", action: applyPorts)
                        .disabled(!portsChanged)
                        .keyboardShortcut(.defaultAction)
                }
            } header: {
                Text("Ports")
            } footer: {
                Caption("Ports Caddy and the DNS responder listen on. Ports 80 and 443 forward to the HTTP and HTTPS ports. Changing them asks for your password once to update the forwarding.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private func portField(_ label: String, text: Binding<String>) -> some View {
        TextField(label, text: text)
            .multilineTextAlignment(.trailing)
            .font(.body.monospacedDigit())
            .onChange(of: text.wrappedValue) { _ in
                portError = nil
                applied = false
            }
    }

    private func applyPorts() {
        let values = [httpPort, httpsPort, dnsPort].map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard let http = values[0], let https = values[1], let dns = values[2] else {
            portError = "Ports must be numbers."
            return
        }
        guard [http, https, dns].allSatisfy({ (1024...65535).contains($0) }) else {
            portError = "Use ports from 1024 to 65535."
            return
        }
        guard Set([http, https, dns]).count == 3 else {
            portError = "Each port must be different."
            return
        }
        do {
            try ConfigFile.setPorts(http: http, https: https, dns: dns)
        } catch {
            portError = error.localizedDescription
            return
        }
        applied = true
        post(.localportConfigChanged)
    }
}

// MARK: Certificate

private struct CertificateSettings: View {
    @State private var trusted: Bool?
    @State private var working = false
    private let caPath = SystemSetup.defaultCARoot

    private var caExists: Bool { FileManager.default.fileExists(atPath: caPath) }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: statusSymbol)
                        .font(.system(size: 28))
                        .foregroundStyle(statusColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(statusTitle).font(.headline)
                        Text("LocalPort Local Authority")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if working {
                        ProgressView().controlSize(.small)
                    } else if trusted == false && caExists {
                        Button("Trust Certificate…", action: trust)
                    }
                }
                .padding(.vertical, 4)
            } footer: {
                Caption("LocalPort's proxy signs a certificate for each project with this local authority. Your Mac must trust it for browsers to accept https://myproject.test without a warning. The key never leaves this Mac.")
            }

            Section {
                Button("Show Certificate in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: caPath)])
                }
                .disabled(!caExists)
                Button("Open Keychain Access") {
                    if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.keychainaccess") {
                        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear(perform: refresh)
    }

    private var statusTitle: String {
        guard caExists else { return "Not created yet" }
        switch trusted {
        case true?: return "Trusted"
        case false?: return "Not trusted"
        case nil: return "Checking…"
        }
    }

    private var statusSymbol: String {
        trusted == true ? "checkmark.shield.fill" : caExists ? "exclamationmark.shield.fill" : "shield"
    }

    private var statusColor: Color {
        trusted == true ? Steel.ice : caExists && trusted == false ? Steel.amber : Steel.textSecondary
    }

    private func refresh() {
        guard caExists else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = SystemSetup.isCATrusted(caPath)
            DispatchQueue.main.async { trusted = result }
        }
    }

    private func trust() {
        working = true
        DispatchQueue.global(qos: .userInitiated).async {
            SystemSetup.trustCA(caPath)
            let result = SystemSetup.isCATrusted(caPath)
            DispatchQueue.main.async {
                trusted = result
                working = false
            }
        }
    }
}

// MARK: Advanced

private struct AdvancedSettings: View {
    @State private var logLevel = ConfigFile.logLevel()

    var body: some View {
        Form {
            Section {
                Picker("Daemon log level", selection: $logLevel) {
                    Text("Error").tag("error")
                    Text("Warning").tag("warn")
                    Text("Info").tag("info")
                    Text("Debug").tag("debug")
                    Text("Trace").tag("trace")
                }
                .onChange(of: logLevel) { level in
                    do {
                        try ConfigFile.setLogLevel(level)
                        post(.localportConfigChanged)
                    } catch {
                        logger.error("Couldn't save log level: \(error)")
                    }
                }
            } header: {
                Text("Logging")
            } footer: {
                Caption("Logs are written to ~/Library/Logs/LocalPort. Use Debug when you report a problem.")
            }

            Section("Maintenance") {
                LabeledContent("Daemon") {
                    Button("Restart") { post(.localportRestartDaemonRequested) }
                }
                LabeledContent("DNS and port forwarding") {
                    Button("Run Setup Again…") { post(.localportSetupRequested) }
                }
                LabeledContent("Files") {
                    HStack {
                        Button("Open Logs") { post(.localportOpenLogsRequested) }
                        Button("Open config.toml") { openConfig() }
                    }
                }
            }

            Section {
                Button("Uninstall LocalPort…", role: .destructive) {
                    post(.localportUninstallRequested)
                }
                .foregroundStyle(.red)
            } footer: {
                Caption("Removes the DNS resolver, port forwarding, the trusted certificate, LocalPort's data and logs, and the app. Your projects aren't touched.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private func openConfig() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: ConfigFile.path) {
            try? fm.createDirectory(atPath: ConfigFile.directory, withIntermediateDirectories: true)
            fm.createFile(atPath: ConfigFile.path, contents: Data("# LocalPort daemon settings\n".utf8))
        }
        let url = URL(fileURLWithPath: ConfigFile.path)
        // .toml often has no default app; fall back to TextEdit.
        if NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
        } else if let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            NSWorkspace.shared.open([url], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

// MARK: About

private struct AboutView: View {
    var body: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(nsImage: MenuBarController.appIcon)
                .resizable()
                .frame(width: 112, height: 112)

            Text("LocalPort")
                .font(.title.bold())

            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? appVersion)")
                .foregroundStyle(.secondary)

            Text("Run multiple projects with unique local hostnames.\nNo more remembering port numbers.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.tertiary)
                .padding(.horizontal)

            Link("GitHub", destination: URL(string: "https://github.com/HibiZA/LocalPort")!)
                .foregroundStyle(Steel.ice)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - AppKit Window Controller (preserves existing API)

final class PreferencesWindowController: NSWindowController {
    static let shared = PreferencesWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "LocalPort Settings"
        window.appearance = NSAppearance(named: .darkAqua)
        window.center()
        window.isReleasedWhenClosed = false

        super.init(window: window)

        window.contentView = ClickThroughHostingView(rootView: PreferencesView())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func showWindow() {
        NSApp.setActivationPolicy(.regular)
        // Activate before showing, so the window opens key and takes clicks.
        NSApp.activate(ignoringOtherApps: true)
        // Fresh view each time so it reflects the current config.
        window?.contentView = ClickThroughHostingView(rootView: PreferencesView())
        window?.makeKeyAndOrderFront(nil)

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
