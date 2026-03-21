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

private let kToolbarGeneral = NSToolbarItem.Identifier("general")
private let kToolbarShortcuts = NSToolbarItem.Identifier("shortcuts")
private let kToolbarAbout = NSToolbarItem.Identifier("about")

final class PreferencesWindowController: NSWindowController {
    static let shared = PreferencesWindowController()

    private let prefs = AppPreferences.shared
    var onPreferencesChanged: (() -> Void)?

    private var tabViews: [String: NSView] = [:]
    private var currentTab = "general"
    private var shortcutButtons: [HotkeyAction: NSButton] = [:]

    private let winW: CGFloat = 480
    private let winH: CGFloat = 420
    private let contentH: CGFloat = 348  // winH minus toolbar+titlebar (~72px)
    private let inset: CGFloat = 28

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "General"
        window.center()
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden

        super.init(window: window)

        let toolbar = NSToolbar(identifier: "PreferencesToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.selectedItemIdentifier = kToolbarGeneral
        window.toolbar = toolbar

        let bg = NSVisualEffectView(frame: window.contentView!.bounds)
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.autoresizingMask = [.width, .height]
        window.contentView = bg

        tabViews["general"] = buildGeneralTab()
        tabViews["shortcuts"] = buildShortcutsTab()
        tabViews["about"] = buildAboutTab()

        switchToTab("general", animate: false)
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

    private func switchToTab(_ tab: String, animate: Bool = true) {
        guard let window = window, let contentView = window.contentView else { return }

        for (_, view) in tabViews {
            view.removeFromSuperview()
        }

        guard let newView = tabViews[tab] else { return }
        newView.frame = contentView.bounds
        newView.autoresizingMask = [.width, .height]
        contentView.addSubview(newView)
        currentTab = tab

        let titles = ["general": "General", "shortcuts": "Shortcuts", "about": "About"]
        window.title = titles[tab] ?? ""
    }

    // MARK: - General Tab

    private func buildGeneralTab() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: winW, height: contentH))
        let contentW = winW - inset * 2

        var y: CGFloat = contentH - 16

        // --- Border Glow ---
        y = addToggleRow(
            label: "Border Glow", description: "Colored glow around active project's screen edge",
            on: prefs.borderGlow, in: container, x: inset, y: y, width: contentW
        ) { [weak self] val in
            self?.prefs.borderGlow = val
            self?.onPreferencesChanged?()
        }

        y = addSliderRow(
            label: "Border Width", value: Double(prefs.borderWidth),
            range: 1...10, format: "%.0fpx",
            in: container, x: inset, y: y, width: contentW
        ) { [weak self] val in
            self?.prefs.borderWidth = CGFloat(val)
            self?.onPreferencesChanged?()
        }

        y -= 8
        addThinSeparator(in: container, x: inset, y: y, width: contentW)
        y -= 12

        // --- Dim ---
        y = addToggleRow(
            label: "Dim Inactive Windows", description: "Reduce opacity of windows not in the active project",
            on: prefs.dimInactive, in: container, x: inset, y: y, width: contentW
        ) { [weak self] val in
            self?.prefs.dimInactive = val
            self?.onPreferencesChanged?()
        }

        y = addSliderRow(
            label: "Dim Amount", value: Double(prefs.dimOpacity),
            range: 0.1...0.8, format: "%.0f%%", multiplier: 100,
            in: container, x: inset, y: y, width: contentW
        ) { [weak self] val in
            self?.prefs.dimOpacity = CGFloat(val)
            self?.onPreferencesChanged?()
        }

        y -= 8
        addThinSeparator(in: container, x: inset, y: y, width: contentW)
        y -= 12

        // --- Animation ---
        y = addSliderRow(
            label: "Transition Speed", value: prefs.animationDuration,
            range: 0.05...0.5, format: "%.2fs",
            in: container, x: inset, y: y, width: contentW
        ) { [weak self] val in
            self?.prefs.animationDuration = val
            self?.onPreferencesChanged?()
        }

        y -= 8
        addThinSeparator(in: container, x: inset, y: y, width: contentW)
        y -= 12

        // --- Behavior ---
        y = addToggleRow(
            label: "Close Windows on Quit", description: nil,
            on: UserAppPreferences.shared.closeWindowsOnQuit, in: container, x: inset, y: y, width: contentW
        ) { val in
            UserAppPreferences.shared.closeWindowsOnQuit = val
        }

        return container
    }

    // MARK: - Shortcuts Tab

    private func buildShortcutsTab() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: winW, height: contentH))
        let contentW = winW - inset * 2

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: winW, height: contentH))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = true

        let docView = FlippedView(frame: NSRect(x: 0, y: 0, width: winW, height: 600))
        scrollView.documentView = docView

        var y: CGFloat = 12

        // Section: Navigation
        y = addSectionLabelFlipped("NAVIGATION", in: docView, x: inset, y: y)

        let navActions: [HotkeyAction] = [.cycleNext, .toggleLast]
        for (i, action) in navActions.enumerated() {
            y = addShortcutRow(action: action, in: docView, x: inset, y: y, width: contentW)
            if i < navActions.count - 1 {
                addThinSeparatorFlipped(in: docView, x: inset, y: y, width: contentW)
                y += 4
            }
        }

        y += 12
        addThinSeparatorFlipped(in: docView, x: inset, y: y, width: contentW)
        y += 12

        // Section: Direct Switch
        y = addSectionLabelFlipped("DIRECT SWITCH", in: docView, x: inset, y: y)

        let numActions: [HotkeyAction] = [
            .switchProject1, .switchProject2, .switchProject3,
            .switchProject4, .switchProject5, .switchProject6,
            .switchProject7, .switchProject8, .switchProject9,
        ]
        for (i, action) in numActions.enumerated() {
            y = addShortcutRow(action: action, in: docView, x: inset, y: y, width: contentW)
            if i < numActions.count - 1 {
                addThinSeparatorFlipped(in: docView, x: inset, y: y, width: contentW)
                y += 4
            }
        }

        y += 20

        // Reset button
        let resetButton = NSButton(title: "Reset All to Defaults", target: nil, action: nil)
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .regular
        resetButton.frame = NSRect(x: (winW - 180) / 2, y: y, width: 180, height: 28)
        let handler = ButtonHandler { [weak self] in
            HotkeyPreferences.shared.resetToDefaults()
            self?.refreshShortcutButtons()
        }
        resetButton.target = handler
        resetButton.action = #selector(ButtonHandler.clicked)
        objc_setAssociatedObject(resetButton, "handler", handler, .OBJC_ASSOCIATION_RETAIN)
        docView.addSubview(resetButton)
        y += 48

        docView.frame = NSRect(x: 0, y: 0, width: winW, height: max(y, contentH))

        container.addSubview(scrollView)
        return container
    }

    private func addShortcutRow(action: HotkeyAction, in container: NSView, x: CGFloat, y: CGFloat, width: CGFloat) -> CGFloat {
        let label = NSTextField(labelWithString: action.label)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.frame = NSRect(x: x, y: y, width: 200, height: 20)
        container.addSubview(label)

        let binding = HotkeyPreferences.shared.binding(for: action)
        let button = ShortcutKeyView(binding: binding)
        button.frame = NSRect(x: x + width - 164, y: y - 2, width: 164, height: 24)

        let handler = ShortcutButtonHandler(action: action, keyView: button)
        button.onClick = { [weak handler] in handler?.startRecording() }
        objc_setAssociatedObject(button, "handler", handler, .OBJC_ASSOCIATION_RETAIN)

        container.addSubview(button)
        shortcutButtons[action] = button

        return y + 32
    }

    private func refreshShortcutButtons() {
        for (action, button) in shortcutButtons {
            let binding = HotkeyPreferences.shared.binding(for: action)
            if let keyView = button as? ShortcutKeyView {
                keyView.update(binding: binding)
            } else {
                button.title = binding.displayString
            }
        }
    }

    // MARK: - About Tab

    private func buildAboutTab() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: winW, height: contentH))

        let iconSize: CGFloat = 72
        let iconView = AppIconView()
        iconView.frame = NSRect(x: (winW - iconSize) / 2, y: contentH - 100, width: iconSize, height: iconSize)
        container.addSubview(iconView)

        let titleLabel = NSTextField(labelWithString: "DevSpace")
        titleLabel.font = .systemFont(ofSize: 24, weight: .bold)
        titleLabel.alignment = .center
        titleLabel.frame = NSRect(x: 0, y: contentH - 136, width: winW, height: 28)
        container.addSubview(titleLabel)

        let versionLabel = NSTextField(labelWithString: "Version 0.1.0")
        versionLabel.font = .systemFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.alignment = .center
        versionLabel.frame = NSRect(x: 0, y: contentH - 156, width: winW, height: 16)
        container.addSubview(versionLabel)

        let descLabel = NSTextField(labelWithString: "Project-first workspace manager for macOS")
        descLabel.font = .systemFont(ofSize: 12)
        descLabel.textColor = .tertiaryLabelColor
        descLabel.alignment = .center
        descLabel.frame = NSRect(x: 0, y: contentH - 180, width: winW, height: 16)
        container.addSubview(descLabel)

        let techLabel = NSTextField(labelWithString: "Swift \u{00B7} AppKit \u{00B7} AXUIElement \u{00B7} Rust \u{00B7} JSON-RPC")
        techLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        techLabel.textColor = .quaternaryLabelColor
        techLabel.alignment = .center
        techLabel.frame = NSRect(x: 0, y: contentH - 204, width: winW, height: 14)
        container.addSubview(techLabel)

        return container
    }

    // MARK: - Row Helpers

    private func addToggleRow(label: String, description: String?, on: Bool,
                               in container: NSView, x: CGFloat, y: CGFloat, width: CGFloat,
                               onChange: @escaping (Bool) -> Void) -> CGFloat {
        let lbl = NSTextField(labelWithString: label)
        lbl.font = .systemFont(ofSize: 13)
        lbl.textColor = .labelColor
        lbl.frame = NSRect(x: x, y: y - 18, width: width - 60, height: 18)
        container.addSubview(lbl)

        var rowH: CGFloat = 28

        if let desc = description {
            let descLabel = NSTextField(labelWithString: desc)
            descLabel.font = .systemFont(ofSize: 11)
            descLabel.textColor = .tertiaryLabelColor
            descLabel.frame = NSRect(x: x, y: y - 34, width: width - 60, height: 14)
            container.addSubview(descLabel)
            rowH = 42
        }

        let toggle = NSSwitch()
        toggle.state = on ? .on : .off
        toggle.controlSize = .small
        let toggleW: CGFloat = 38
        toggle.frame = NSRect(x: x + width - toggleW, y: y - 20, width: toggleW, height: 20)
        let handler = SwitchHandler(onChange: onChange)
        toggle.target = handler
        toggle.action = #selector(SwitchHandler.toggled(_:))
        objc_setAssociatedObject(toggle, "handler", handler, .OBJC_ASSOCIATION_RETAIN)
        container.addSubview(toggle)

        return y - rowH
    }

    private func addSliderRow(label: String, value: Double, range: ClosedRange<Double>,
                               format: String, multiplier: Double = 1,
                               in container: NSView, x: CGFloat, y: CGFloat, width: CGFloat,
                               onChange: @escaping (Double) -> Void) -> CGFloat {
        let lbl = NSTextField(labelWithString: label)
        lbl.font = .systemFont(ofSize: 13)
        lbl.textColor = .labelColor
        lbl.frame = NSRect(x: x, y: y - 18, width: 130, height: 18)
        container.addSubview(lbl)

        let sliderX: CGFloat = x + 136
        let sliderW: CGFloat = width - 200
        let slider = NSSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound,
                              target: nil, action: nil)
        slider.frame = NSRect(x: sliderX, y: y - 18, width: sliderW, height: 18)
        slider.controlSize = .small

        let displayVal = String(format: format, value * multiplier)
        let valLabel = NSTextField(labelWithString: displayVal)
        valLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        valLabel.textColor = .secondaryLabelColor
        valLabel.alignment = .right
        valLabel.frame = NSRect(x: x + width - 56, y: y - 18, width: 56, height: 18)
        container.addSubview(valLabel)

        let handler = SliderHandler(valueLabel: valLabel, format: format, multiplier: multiplier, onChange: onChange)
        slider.target = handler
        slider.action = #selector(SliderHandler.slid(_:))
        objc_setAssociatedObject(slider, "handler", handler, .OBJC_ASSOCIATION_RETAIN)
        container.addSubview(slider)

        return y - 28
    }

    private func addThinSeparator(in container: NSView, x: CGFloat, y: CGFloat, width: CGFloat) {
        let sep = NSView(frame: NSRect(x: x, y: y, width: width, height: 1))
        sep.wantsLayer = true
        sep.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        container.addSubview(sep)
    }

    private func addThinSeparatorFlipped(in container: NSView, x: CGFloat, y: CGFloat, width: CGFloat) {
        let sep = NSView(frame: NSRect(x: x, y: y, width: width, height: 1))
        sep.wantsLayer = true
        sep.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        container.addSubview(sep)
    }

    private func addSectionLabelFlipped(_ title: String, in container: NSView, x: CGFloat, y: CGFloat) -> CGFloat {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        label.frame = NSRect(x: x, y: y, width: 200, height: 12)
        container.addSubview(label)
        return y + 20
    }
}

// MARK: - Toolbar Delegate

extension PreferencesWindowController: NSToolbarDelegate {
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [kToolbarGeneral, kToolbarShortcuts, kToolbarAbout]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [kToolbarGeneral, kToolbarShortcuts, kToolbarAbout]
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [kToolbarGeneral, kToolbarShortcuts, kToolbarAbout]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.target = self

        switch itemIdentifier {
        case kToolbarGeneral:
            item.label = "General"
            item.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "General")
            item.action = #selector(selectGeneralTab)
        case kToolbarShortcuts:
            item.label = "Shortcuts"
            item.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Shortcuts")
            item.action = #selector(selectShortcutsTab)
        case kToolbarAbout:
            item.label = "About"
            item.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "About")
            item.action = #selector(selectAboutTab)
        default:
            return nil
        }
        return item
    }

    @objc private func selectGeneralTab() { switchToTab("general") }
    @objc private func selectShortcutsTab() { switchToTab("shortcuts") }
    @objc private func selectAboutTab() { switchToTab("about") }
}

// MARK: - Shortcut Key View

private final class ShortcutKeyView: NSButton {
    var onClick: (() -> Void)?
    private var isRecording = false

    init(binding: HotkeyBinding) {
        super.init(frame: .zero)
        title = binding.displayString
        bezelStyle = .recessed
        font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        isBordered = true
        wantsLayer = true
        layer?.cornerRadius = 6
        target = self
        action = #selector(handleClick)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(binding: HotkeyBinding) {
        title = binding.displayString
        isRecording = false
        contentTintColor = nil
    }

    func startRecordingMode() {
        title = "Press shortcut\u{2026}"
        isRecording = true
        contentTintColor = .controlAccentColor
    }

    func stopRecordingMode() {
        isRecording = false
        contentTintColor = nil
    }

    @objc private func handleClick() {
        onClick?()
    }
}

// MARK: - Shortcut Recorder

private final class ShortcutButtonHandler: NSObject {
    let action: HotkeyAction
    weak var keyView: ShortcutKeyView?
    private var monitor: Any?

    init(action: HotkeyAction, keyView: ShortcutKeyView) {
        self.action = action
        self.keyView = keyView
    }

    func startRecording() {
        keyView?.startRecordingMode()

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }

            let keyCode = event.keyCode
            let flags = event.modifierFlags

            if keyCode == 53 {
                self.cancelRecording()
                return nil
            }

            let hasModifier = flags.contains(.control) || flags.contains(.option)
                || flags.contains(.command) || flags.contains(.shift)
            guard hasModifier else { return nil }

            var cgMods: UInt = 0
            if flags.contains(.control) { cgMods |= UInt(CGEventFlags.maskControl.rawValue) }
            if flags.contains(.option) { cgMods |= UInt(CGEventFlags.maskAlternate.rawValue) }
            if flags.contains(.shift) { cgMods |= UInt(CGEventFlags.maskShift.rawValue) }
            if flags.contains(.command) { cgMods |= UInt(CGEventFlags.maskCommand.rawValue) }

            let binding = HotkeyBinding(keyCode: keyCode, modifiers: cgMods)
            HotkeyPreferences.shared.setBinding(binding, for: self.action)

            self.keyView?.update(binding: binding)
            self.stopRecording()
            return nil
        }
    }

    private func cancelRecording() {
        let binding = HotkeyPreferences.shared.binding(for: action)
        keyView?.update(binding: binding)
        stopRecording()
    }

    private func stopRecording() {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        keyView?.stopRecordingMode()
    }

    deinit {
        stopRecording()
    }
}

// MARK: - App Icon View

private final class AppIconView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 2, dy: 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: 18, yRadius: 18)

        let gradient = NSGradient(colors: [
            NSColor(hex: "#6366F1"),
            NSColor(hex: "#8B5CF6"),
            NSColor(hex: "#EC4899"),
        ])
        gradient?.draw(in: path, angle: -45)

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 28, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let text = "DS" as NSString
        let textSize = text.size(withAttributes: attrs)
        let textPoint = NSPoint(
            x: rect.midX - textSize.width / 2,
            y: rect.midY - textSize.height / 2
        )
        text.draw(at: textPoint, withAttributes: attrs)
    }
}

// MARK: - Flipped View (for scroll content)

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Action Handlers

private final class SwitchHandler: NSObject {
    let onChange: (Bool) -> Void
    init(onChange: @escaping (Bool) -> Void) { self.onChange = onChange }

    @objc func toggled(_ sender: NSSwitch) {
        onChange(sender.state == .on)
    }
}

private final class CheckboxHandler: NSObject {
    let onChange: (Bool) -> Void
    init(onChange: @escaping (Bool) -> Void) { self.onChange = onChange }

    @objc func toggled(_ sender: NSButton) {
        onChange(sender.state == .on)
    }
}

private final class SliderHandler: NSObject {
    let valueLabel: NSTextField
    let format: String
    let multiplier: Double
    let onChange: (Double) -> Void

    init(valueLabel: NSTextField, format: String = "%.2f", multiplier: Double = 1,
         onChange: @escaping (Double) -> Void) {
        self.valueLabel = valueLabel
        self.format = format
        self.multiplier = multiplier
        self.onChange = onChange
    }

    @objc func slid(_ sender: NSSlider) {
        let val = sender.doubleValue
        valueLabel.stringValue = String(format: format, val * multiplier)
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
