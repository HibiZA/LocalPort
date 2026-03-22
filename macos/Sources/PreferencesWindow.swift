import AppKit
import ServiceManagement
import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.devspace.app", category: "Preferences")

/// Keys for UserDefaults persistence
enum PrefKey {
    static let tld = "tld"
    static let hotkeys = "hotkeyBindings"
}

// MARK: - Hotkey Model

struct HotkeyBinding: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt

    var displayString: String {
        var parts: [String] = []
        let flags = CGEventFlags(rawValue: UInt64(modifiers))
        if flags.contains(.maskControl) { parts.append("Ctrl") }
        if flags.contains(.maskAlternate) { parts.append("Opt") }
        if flags.contains(.maskShift) { parts.append("Shift") }
        if flags.contains(.maskCommand) { parts.append("Cmd") }
        parts.append(Self.keyName(for: keyCode))
        return parts.joined(separator: " + ")
    }

    static func keyName(for keyCode: UInt16) -> String {
        switch keyCode {
        case 48: return "Tab"
        case 50: return "`"
        case 49: return "Space"
        case 36: return "Return"
        case 51: return "Delete"
        case 53: return "Esc"
        case 123: return "\u{2190}"
        case 124: return "\u{2192}"
        case 125: return "\u{2193}"
        case 126: return "\u{2191}"
        case 18: return "1"; case 19: return "2"; case 20: return "3"
        case 21: return "4"; case 23: return "5"; case 22: return "6"
        case 26: return "7"; case 28: return "8"; case 25: return "9"
        case 29: return "0"
        case 0: return "A"; case 11: return "B"; case 8: return "C"
        case 2: return "D"; case 14: return "E"; case 3: return "F"
        case 5: return "G"; case 4: return "H"; case 34: return "I"
        case 38: return "J"; case 40: return "K"; case 37: return "L"
        case 46: return "M"; case 45: return "N"; case 31: return "O"
        case 35: return "P"; case 12: return "Q"; case 15: return "R"
        case 1: return "S"; case 17: return "T"; case 32: return "U"
        case 9: return "V"; case 13: return "W"; case 7: return "X"
        case 16: return "Y"; case 6: return "Z"
        case 27: return "-"; case 24: return "="; case 33: return "["
        case 30: return "]"; case 42: return "\\"; case 41: return ";"
        case 39: return "'"; case 43: return ","; case 47: return "."
        case 44: return "/"
        default: return "Key\(keyCode)"
        }
    }
}

enum HotkeyAction: String, CaseIterable, Codable {
    case cycleNext = "cycleNext"
    case toggleLast = "toggleLast"
    case switchProject1 = "switchProject1"
    case switchProject2 = "switchProject2"
    case switchProject3 = "switchProject3"
    case switchProject4 = "switchProject4"
    case switchProject5 = "switchProject5"
    case switchProject6 = "switchProject6"
    case switchProject7 = "switchProject7"
    case switchProject8 = "switchProject8"
    case switchProject9 = "switchProject9"

    var label: String {
        switch self {
        case .cycleNext: return "Cycle Projects"
        case .toggleLast: return "Toggle Last Project"
        case .switchProject1: return "Switch to Project 1"
        case .switchProject2: return "Switch to Project 2"
        case .switchProject3: return "Switch to Project 3"
        case .switchProject4: return "Switch to Project 4"
        case .switchProject5: return "Switch to Project 5"
        case .switchProject6: return "Switch to Project 6"
        case .switchProject7: return "Switch to Project 7"
        case .switchProject8: return "Switch to Project 8"
        case .switchProject9: return "Switch to Project 9"
        }
    }
}

final class HotkeyPreferences {
    static let shared = HotkeyPreferences()

    static let didChangeNotification = Notification.Name("HotkeyPreferencesDidChange")

    private var bindings: [HotkeyAction: HotkeyBinding] = [:]

    init() { load() }

    func binding(for action: HotkeyAction) -> HotkeyBinding {
        bindings[action] ?? Self.defaultBinding(for: action)
    }

    func setBinding(_ binding: HotkeyBinding, for action: HotkeyAction) {
        bindings[action] = binding
        save()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    func resetToDefaults() {
        bindings.removeAll()
        save()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    func buildLookupTable() -> [UInt64: HotkeyAction] {
        var table: [UInt64: HotkeyAction] = [:]
        for action in HotkeyAction.allCases {
            let b = binding(for: action)
            let key = Self.lookupKey(keyCode: b.keyCode, modifiers: b.modifiers)
            table[key] = action
        }
        return table
    }

    static func lookupKey(keyCode: UInt16, modifiers: UInt) -> UInt64 {
        let mask: UInt64 = CGEventFlags.maskControl.rawValue
            | CGEventFlags.maskAlternate.rawValue
            | CGEventFlags.maskShift.rawValue
            | CGEventFlags.maskCommand.rawValue
        let cleanMods = UInt64(modifiers) & mask
        return (cleanMods << 16) | UInt64(keyCode)
    }

    static func defaultBinding(for action: HotkeyAction) -> HotkeyBinding {
        let ctrl = UInt(CGEventFlags.maskControl.rawValue)
        switch action {
        case .cycleNext:      return HotkeyBinding(keyCode: 48, modifiers: ctrl)
        case .toggleLast:     return HotkeyBinding(keyCode: 50, modifiers: ctrl)
        case .switchProject1: return HotkeyBinding(keyCode: 18, modifiers: ctrl)
        case .switchProject2: return HotkeyBinding(keyCode: 19, modifiers: ctrl)
        case .switchProject3: return HotkeyBinding(keyCode: 20, modifiers: ctrl)
        case .switchProject4: return HotkeyBinding(keyCode: 21, modifiers: ctrl)
        case .switchProject5: return HotkeyBinding(keyCode: 23, modifiers: ctrl)
        case .switchProject6: return HotkeyBinding(keyCode: 22, modifiers: ctrl)
        case .switchProject7: return HotkeyBinding(keyCode: 26, modifiers: ctrl)
        case .switchProject8: return HotkeyBinding(keyCode: 28, modifiers: ctrl)
        case .switchProject9: return HotkeyBinding(keyCode: 25, modifiers: ctrl)
        }
    }

    private func save() {
        let encoded = bindings.reduce(into: [String: HotkeyBinding]()) { $0[$1.key.rawValue] = $1.value }
        if let data = try? JSONEncoder().encode(encoded) {
            UserDefaults.standard.set(data, forKey: PrefKey.hotkeys)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: PrefKey.hotkeys),
              let decoded = try? JSONDecoder().decode([String: HotkeyBinding].self, from: data) else { return }
        for (key, value) in decoded {
            if let action = HotkeyAction(rawValue: key) {
                bindings[action] = value
            }
        }
    }
}

// MARK: - SwiftUI Preferences View

private struct PreferencesView: View {
    @State private var tld: String
    @State private var launchAtLogin: Bool

    init() {
        _tld = State(initialValue: UserDefaults.standard.string(forKey: PrefKey.tld) ?? "test")
        _launchAtLogin = State(initialValue: SMAppService.mainApp.status == .enabled)
    }

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }

            shortcutsTab
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }

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
                    UserDefaults.standard.set(val, forKey: PrefKey.tld)
                }

                if tld == "test" {
                    Text("Projects accessible at https://myproject.test")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Projects accessible at http://myproject.localhost:8080")
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
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Shortcuts

    private var shortcutsTab: some View {
        Form {
            Section("Navigation") {
                ShortcutRow(action: .cycleNext)
                ShortcutRow(action: .toggleLast)
            }

            Section("Direct Switch") {
                ForEach([
                    HotkeyAction.switchProject1, .switchProject2, .switchProject3,
                    .switchProject4, .switchProject5, .switchProject6,
                    .switchProject7, .switchProject8, .switchProject9,
                ], id: \.rawValue) { action in
                    ShortcutRow(action: action)
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button("Reset All to Defaults") {
                        HotkeyPreferences.shared.resetToDefaults()
                    }
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: About

    private var aboutTab: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)

            Text("DevSpace")
                .font(.title.bold())

            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.2")")
                .foregroundStyle(.secondary)

            Text("Run multiple projects with unique local hostnames.\nNo more remembering port numbers.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.tertiary)
                .padding(.horizontal)

            Link("GitHub", destination: URL(string: "https://github.com/HibiZA/DevSpace")!)
                .foregroundStyle(.blue)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Shortcut Row

private struct ShortcutRow: View {
    let action: HotkeyAction
    @State private var displayString: String

    init(action: HotkeyAction) {
        self.action = action
        _displayString = State(initialValue: HotkeyPreferences.shared.binding(for: action).displayString)
    }

    var body: some View {
        HStack {
            Text(action.label)
            Spacer()
            Text(displayString)
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
        }
        .onReceive(NotificationCenter.default.publisher(for: HotkeyPreferences.didChangeNotification)) { _ in
            displayString = HotkeyPreferences.shared.binding(for: action).displayString
        }
    }
}

// MARK: - AppKit Window Controller (preserves existing API)

final class PreferencesWindowController: NSWindowController {
    static let shared = PreferencesWindowController()

    var onPreferencesChanged: (() -> Void)?

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
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
