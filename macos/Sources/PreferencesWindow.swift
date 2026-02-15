import AppKit
import os.log

private let logger = Logger(subsystem: "com.devspace.app", category: "Preferences")

/// Keys for UserDefaults persistence
enum PrefKey {
    static let borderWidth = "borderWidth"
    static let borderGlow = "borderGlow"
    static let dimInactive = "dimInactive"
    static let dimOpacity = "dimOpacity"
    static let animationDuration = "animationDuration"
    static let hotkeys = "hotkeyBindings"
}

/// Observable preferences that other components can read
final class AppPreferences {
    static let shared = AppPreferences()

    var borderWidth: CGFloat {
        get { CGFloat(UserDefaults.standard.double(forKey: PrefKey.borderWidth).clamped(1...10, fallback: 3)) }
        set { UserDefaults.standard.set(Double(newValue), forKey: PrefKey.borderWidth) }
    }

    var borderGlow: Bool {
        get { UserDefaults.standard.object(forKey: PrefKey.borderGlow) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: PrefKey.borderGlow) }
    }

    var dimInactive: Bool {
        get { UserDefaults.standard.object(forKey: PrefKey.dimInactive) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: PrefKey.dimInactive) }
    }

    var dimOpacity: CGFloat {
        get { CGFloat(UserDefaults.standard.double(forKey: PrefKey.dimOpacity).clamped(0.1...0.8, fallback: 0.4)) }
        set { UserDefaults.standard.set(Double(newValue), forKey: PrefKey.dimOpacity) }
    }

    var animationDuration: TimeInterval {
        get { UserDefaults.standard.double(forKey: PrefKey.animationDuration).clamped(0.05...0.5, fallback: 0.15) }
        set { UserDefaults.standard.set(newValue, forKey: PrefKey.animationDuration) }
    }
}

private extension Double {
    func clamped(_ range: ClosedRange<Double>, fallback: Double) -> Double {
        if self == 0 { return fallback }
        return min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Hotkey Model

/// A single hotkey binding: modifier flags + key code
struct HotkeyBinding: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt  // CGEventFlags rawValue (masked)

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
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
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

/// Identifiers for each configurable action
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

/// Stores and retrieves hotkey bindings from UserDefaults
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

    /// Build a lookup table: combined key -> HotkeyAction for fast matching in event tap
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

// MARK: - Preferences Window Controller

final class PreferencesWindowController: NSWindowController {
    static let shared = PreferencesWindowController()

    private let prefs = AppPreferences.shared
    var onPreferencesChanged: (() -> Void)?

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "DevSpace Preferences"
        window.center()
        window.isReleasedWhenClosed = false

        super.init(window: window)

        window.contentView = buildTabbedUI()
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

    // MARK: - Tabbed UI

    private func buildTabbedUI() -> NSView {
        let tabView = NSTabView(frame: NSRect(x: 0, y: 0, width: 520, height: 440))
        tabView.autoresizingMask = [.width, .height]

        let generalTab = NSTabViewItem(identifier: "general")
        generalTab.label = "General"
        generalTab.view = buildGeneralTab()
        tabView.addTabViewItem(generalTab)

        let shortcutsTab = NSTabViewItem(identifier: "shortcuts")
        shortcutsTab.label = "Shortcuts"
        shortcutsTab.view = buildShortcutsTab()
        tabView.addTabViewItem(shortcutsTab)

        let aboutTab = NSTabViewItem(identifier: "about")
        aboutTab.label = "About"
        aboutTab.view = buildAboutTab()
        tabView.addTabViewItem(aboutTab)

        return tabView
    }

    // MARK: - General Tab

    private func buildGeneralTab() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 380))

        var y: CGFloat = 350

        // Section: Appearance
        y = addSectionHeader("Appearance", in: container, y: y)

        y = addSliderRow(
            label: "Border Width:",
            value: Double(prefs.borderWidth),
            range: 1...10,
            in: container, y: y
        ) { [weak self] val in
            self?.prefs.borderWidth = CGFloat(val)
            self?.onPreferencesChanged?()
        }

        y = addCheckboxRow(
            label: "Border Glow Effect",
            checked: prefs.borderGlow,
            in: container, y: y
        ) { [weak self] val in
            self?.prefs.borderGlow = val
            self?.onPreferencesChanged?()
        }

        y = addCheckboxRow(
            label: "Dim Inactive Project Windows",
            checked: prefs.dimInactive,
            in: container, y: y
        ) { [weak self] val in
            self?.prefs.dimInactive = val
            self?.onPreferencesChanged?()
        }

        y = addSliderRow(
            label: "Dim Opacity:",
            value: Double(prefs.dimOpacity),
            range: 0.1...0.8,
            in: container, y: y
        ) { [weak self] val in
            self?.prefs.dimOpacity = CGFloat(val)
            self?.onPreferencesChanged?()
        }

        y = addSliderRow(
            label: "Animation Speed:",
            value: prefs.animationDuration,
            range: 0.05...0.5,
            in: container, y: y
        ) { [weak self] val in
            self?.prefs.animationDuration = val
            self?.onPreferencesChanged?()
        }

        // Section: Behavior
        y -= 10
        y = addSectionHeader("Behavior", in: container, y: y)

        y = addCheckboxRow(
            label: "Close project windows when DevSpace quits",
            checked: UserAppPreferences.shared.closeWindowsOnQuit,
            in: container, y: y
        ) { val in
            UserAppPreferences.shared.closeWindowsOnQuit = val
        }

        return container
    }

    // MARK: - Shortcuts Tab

    private var shortcutButtons: [HotkeyAction: NSButton] = [:]

    private func buildShortcutsTab() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 380))

        var y: CGFloat = 350

        y = addSectionHeader("Project Switching", in: container, y: y)

        // Main actions first
        let mainActions: [HotkeyAction] = [.cycleNext, .toggleLast]
        for action in mainActions {
            y = addShortcutRow(action: action, in: container, y: y)
        }

        y -= 10
        y = addSectionHeader("Direct Switch", in: container, y: y)

        // Project number shortcuts
        let numberActions: [HotkeyAction] = [
            .switchProject1, .switchProject2, .switchProject3,
            .switchProject4, .switchProject5, .switchProject6,
            .switchProject7, .switchProject8, .switchProject9,
        ]
        for action in numberActions {
            y = addShortcutRow(action: action, in: container, y: y)
        }

        // Reset button
        let resetButton = NSButton(title: "Reset to Defaults", target: nil, action: nil)
        resetButton.frame = NSRect(x: 340, y: 10, width: 140, height: 28)
        resetButton.bezelStyle = .rounded
        let resetHandler = ButtonHandler { [weak self] in
            HotkeyPreferences.shared.resetToDefaults()
            self?.refreshShortcutButtons()
        }
        resetButton.target = resetHandler
        resetButton.action = #selector(ButtonHandler.clicked)
        objc_setAssociatedObject(resetButton, "handler", resetHandler, .OBJC_ASSOCIATION_RETAIN)
        container.addSubview(resetButton)

        return container
    }

    private func addShortcutRow(action: HotkeyAction, in container: NSView, y: CGFloat) -> CGFloat {
        let label = NSTextField(labelWithString: action.label)
        label.frame = NSRect(x: 40, y: y, width: 180, height: 22)
        label.textColor = .labelColor
        container.addSubview(label)

        let binding = HotkeyPreferences.shared.binding(for: action)
        let button = NSButton(title: binding.displayString, target: nil, action: nil)
        button.frame = NSRect(x: 230, y: y - 1, width: 200, height: 24)
        button.bezelStyle = .roundRect
        button.font = .monospacedSystemFont(ofSize: 12, weight: .regular)

        let handler = ShortcutButtonHandler(action: action, button: button)
        button.target = handler
        button.action = #selector(ShortcutButtonHandler.clicked(_:))
        objc_setAssociatedObject(button, "handler", handler, .OBJC_ASSOCIATION_RETAIN)

        container.addSubview(button)
        shortcutButtons[action] = button

        return y - 28
    }

    private func refreshShortcutButtons() {
        for (action, button) in shortcutButtons {
            let binding = HotkeyPreferences.shared.binding(for: action)
            button.title = binding.displayString
        }
    }

    // MARK: - About Tab

    private func buildAboutTab() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 380))

        var y: CGFloat = 320

        let titleLabel = NSTextField(labelWithString: "DevSpace")
        titleLabel.font = .systemFont(ofSize: 24, weight: .bold)
        titleLabel.frame = NSRect(x: 0, y: y, width: 500, height: 30)
        titleLabel.alignment = .center
        container.addSubview(titleLabel)

        y -= 30
        let versionLabel = NSTextField(labelWithString: "Version 0.1.0")
        versionLabel.font = .systemFont(ofSize: 13)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.frame = NSRect(x: 0, y: y, width: 500, height: 20)
        versionLabel.alignment = .center
        container.addSubview(versionLabel)

        y -= 30
        let descLabel = NSTextField(labelWithString: "Project-first workspace manager for macOS")
        descLabel.font = .systemFont(ofSize: 12)
        descLabel.textColor = .tertiaryLabelColor
        descLabel.frame = NSRect(x: 0, y: y, width: 500, height: 18)
        descLabel.alignment = .center
        container.addSubview(descLabel)

        return container
    }

    // MARK: - UI Helpers

    private func addSectionHeader(_ title: String, in container: NSView, y: CGFloat) -> CGFloat {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.frame = NSRect(x: 20, y: y, width: 440, height: 20)
        container.addSubview(label)

        let sep = NSBox(frame: NSRect(x: 20, y: y - 4, width: 440, height: 1))
        sep.boxType = .separator
        container.addSubview(sep)

        return y - 30
    }

    private func addCheckboxRow(label: String, checked: Bool, in container: NSView, y: CGFloat, onChange: @escaping (Bool) -> Void) -> CGFloat {
        let checkbox = NSButton(checkboxWithTitle: label, target: nil, action: nil)
        checkbox.state = checked ? .on : .off
        checkbox.frame = NSRect(x: 40, y: y, width: 400, height: 22)

        let handler = CheckboxHandler(onChange: onChange)
        checkbox.target = handler
        checkbox.action = #selector(CheckboxHandler.toggled(_:))
        objc_setAssociatedObject(checkbox, "handler", handler, .OBJC_ASSOCIATION_RETAIN)

        container.addSubview(checkbox)
        return y - 30
    }

    private func addSliderRow(label: String, value: Double, range: ClosedRange<Double>, in container: NSView, y: CGFloat, onChange: @escaping (Double) -> Void) -> CGFloat {
        let lbl = NSTextField(labelWithString: label)
        lbl.frame = NSRect(x: 40, y: y, width: 130, height: 22)
        container.addSubview(lbl)

        let slider = NSSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound, target: nil, action: nil)
        slider.frame = NSRect(x: 175, y: y, width: 200, height: 22)

        let valueLabel = NSTextField(labelWithString: String(format: "%.1f", value))
        valueLabel.frame = NSRect(x: 385, y: y, width: 60, height: 22)
        valueLabel.alignment = .left
        container.addSubview(valueLabel)

        let handler = SliderHandler(valueLabel: valueLabel, onChange: onChange)
        slider.target = handler
        slider.action = #selector(SliderHandler.slid(_:))
        objc_setAssociatedObject(slider, "handler", handler, .OBJC_ASSOCIATION_RETAIN)

        container.addSubview(slider)
        return y - 30
    }
}

// MARK: - Shortcut Recorder

/// Handles click-to-record for a shortcut button. When clicked, the button enters
/// "recording" mode and captures the next key combination.
private final class ShortcutButtonHandler: NSObject {
    let action: HotkeyAction
    weak var button: NSButton?
    private var monitor: Any?

    init(action: HotkeyAction, button: NSButton) {
        self.action = action
        self.button = button
    }

    @objc func clicked(_ sender: NSButton) {
        // Enter recording mode
        sender.title = "Press shortcut..."
        sender.isHighlighted = true

        // Listen for the next key event
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }

            let keyCode = event.keyCode
            let flags = event.modifierFlags

            // Escape cancels
            if keyCode == 53 {
                self.cancelRecording()
                return nil
            }

            // Require at least one modifier (Ctrl, Opt, Cmd, Shift)
            let hasModifier = flags.contains(.control) || flags.contains(.option)
                || flags.contains(.command) || flags.contains(.shift)
            guard hasModifier else { return nil }

            // Convert NSEvent modifierFlags to CGEventFlags mask
            var cgMods: UInt = 0
            if flags.contains(.control) { cgMods |= UInt(CGEventFlags.maskControl.rawValue) }
            if flags.contains(.option) { cgMods |= UInt(CGEventFlags.maskAlternate.rawValue) }
            if flags.contains(.shift) { cgMods |= UInt(CGEventFlags.maskShift.rawValue) }
            if flags.contains(.command) { cgMods |= UInt(CGEventFlags.maskCommand.rawValue) }

            let binding = HotkeyBinding(keyCode: keyCode, modifiers: cgMods)
            HotkeyPreferences.shared.setBinding(binding, for: self.action)

            self.button?.title = binding.displayString
            self.stopRecording()
            return nil // Consume the event
        }
    }

    private func cancelRecording() {
        let binding = HotkeyPreferences.shared.binding(for: action)
        button?.title = binding.displayString
        stopRecording()
    }

    private func stopRecording() {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        button?.isHighlighted = false
    }

    deinit {
        stopRecording()
    }
}

// MARK: - Action Handlers

private final class CheckboxHandler: NSObject {
    let onChange: (Bool) -> Void
    init(onChange: @escaping (Bool) -> Void) { self.onChange = onChange }

    @objc func toggled(_ sender: NSButton) {
        onChange(sender.state == .on)
    }
}

private final class SliderHandler: NSObject {
    let valueLabel: NSTextField
    let onChange: (Double) -> Void

    init(valueLabel: NSTextField, onChange: @escaping (Double) -> Void) {
        self.valueLabel = valueLabel
        self.onChange = onChange
    }

    @objc func slid(_ sender: NSSlider) {
        let val = sender.doubleValue
        valueLabel.stringValue = String(format: "%.2f", val)
        onChange(val)
    }
}

private final class ButtonHandler: NSObject {
    let action: () -> Void
    init(action: @escaping () -> Void) { self.action = action }

    @objc func clicked() {
        action()
    }
}
