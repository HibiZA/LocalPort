import AppKit

struct ProjectSettings {
    var name: String
    var color: String
    var hostname: String
    var layoutPreset: LayoutPreset
}

/// Panel for editing an existing project's settings.
final class ProjectSettingsPanel: NSPanel {
    var onSave: ((ProjectSettings) -> Void)?
    var onRemove: ((String) -> Void)?

    private let projectID: String
    private let nameField = NSTextField()
    private let hostnameField = NSTextField()
    private var selectedColor: String
    private var selectedLayout: LayoutPreset
    private var colorSwatches: [ColorSwatchView] = []
    private var layoutButtons: [LayoutButton] = []

    private let colorPalette = [
        "#3B82F6", "#10B981", "#F59E0B", "#EF4444", "#8B5CF6", "#EC4899",
        "#06B6D4", "#84CC16", "#F97316", "#6366F1",
    ]

    init(project: Project) {
        self.projectID = project.id
        self.selectedColor = project.color.hex
        self.selectedLayout = project.layoutPreset ?? .codeFocus

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        title = "Project Settings"
        isMovableByWindowBackground = true
        level = .floating
        center()

        setupUI(project: project)
    }

    // MARK: - UI Setup

    private func setupUI(project: Project) {
        let bg = NSVisualEffectView()
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        contentView = bg

        var y: CGFloat = 380

        // Name
        y = addLabeledField("Name:", field: nameField, value: project.name, in: bg, y: y)

        // Hostname
        y = addHostnameRow(value: project.hostname, in: bg, y: y)

        // Color
        y -= 8
        y = addColorRow(selected: project.color.hex, in: bg, y: y)

        // Layout
        y -= 8
        y = addLayoutRow(selected: project.layoutPreset ?? .codeFocus, in: bg, y: y)

        // Save button
        y -= 16
        let saveButton = NSButton(title: "Save", target: self, action: #selector(saveClicked))
        saveButton.bezelStyle = .rounded
        saveButton.controlSize = .large
        saveButton.keyEquivalent = "\r"
        saveButton.frame = NSRect(x: 130, y: y, width: 140, height: 32)
        bg.addSubview(saveButton)

        // Separator
        y -= 28
        let sep = NSBox(frame: NSRect(x: 30, y: y, width: 340, height: 1))
        sep.boxType = .separator
        bg.addSubview(sep)

        // Remove button
        y -= 32
        let removeButton = NSButton(title: "Remove Project", target: self, action: #selector(removeClicked))
        removeButton.bezelStyle = .rounded
        removeButton.contentTintColor = .systemRed
        removeButton.frame = NSRect(x: 130, y: y, width: 140, height: 28)
        bg.addSubview(removeButton)
    }

    private func addLabeledField(_ label: String, field: NSTextField, value: String, in container: NSView, y: CGFloat) -> CGFloat {
        let lbl = NSTextField(labelWithString: label)
        lbl.font = .systemFont(ofSize: 13, weight: .medium)
        lbl.frame = NSRect(x: 30, y: y, width: 80, height: 22)
        container.addSubview(lbl)

        field.stringValue = value
        field.isEditable = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: 13)
        field.frame = NSRect(x: 115, y: y, width: 250, height: 24)
        container.addSubview(field)

        return y - 36
    }

    private func addHostnameRow(value: String, in container: NSView, y: CGFloat) -> CGFloat {
        let lbl = NSTextField(labelWithString: "Hostname:")
        lbl.font = .systemFont(ofSize: 13, weight: .medium)
        lbl.frame = NSRect(x: 30, y: y, width: 80, height: 22)
        container.addSubview(lbl)

        // Strip .localhost suffix for editing
        let editable = value.replacingOccurrences(of: ".localhost", with: "")
        hostnameField.stringValue = editable
        hostnameField.isEditable = true
        hostnameField.isBezeled = true
        hostnameField.bezelStyle = .roundedBezel
        hostnameField.font = .systemFont(ofSize: 13)
        hostnameField.frame = NSRect(x: 115, y: y, width: 180, height: 24)
        container.addSubview(hostnameField)

        let suffix = NSTextField(labelWithString: ".localhost")
        suffix.font = .systemFont(ofSize: 13)
        suffix.textColor = .secondaryLabelColor
        suffix.frame = NSRect(x: 298, y: y, width: 80, height: 22)
        container.addSubview(suffix)

        return y - 36
    }

    private func addColorRow(selected: String, in container: NSView, y: CGFloat) -> CGFloat {
        let lbl = NSTextField(labelWithString: "Color:")
        lbl.font = .systemFont(ofSize: 13, weight: .medium)
        lbl.frame = NSRect(x: 30, y: y, width: 80, height: 22)
        container.addSubview(lbl)

        let swatchSize: CGFloat = 24
        let spacing: CGFloat = 8
        var x: CGFloat = 115

        for hex in colorPalette {
            let swatch = ColorSwatchView(hex: hex, size: swatchSize)
            swatch.frame = NSRect(x: x, y: y - 1, width: swatchSize, height: swatchSize)
            swatch.isSelected = (hex.lowercased() == selected.lowercased())
            swatch.onClick = { [weak self] clickedHex in
                self?.selectColor(clickedHex)
            }
            container.addSubview(swatch)
            colorSwatches.append(swatch)
            x += swatchSize + spacing
        }

        return y - 36
    }

    private func addLayoutRow(selected: LayoutPreset, in container: NSView, y: CGFloat) -> CGFloat {
        let lbl = NSTextField(labelWithString: "Layout:")
        lbl.font = .systemFont(ofSize: 13, weight: .medium)
        lbl.frame = NSRect(x: 30, y: y, width: 80, height: 22)
        container.addSubview(lbl)

        let presets: [(LayoutPreset, String)] = [
            (.codeFocus, "Code"), (.previewFocus, "Preview"), (.equalSplit, "Equal"),
            (.stacked, "Stack"), (.pair, "Pair"), (.fullscreen, "Full"),
        ]

        let buttonW: CGFloat = 52
        let spacing: CGFloat = 4
        var x: CGFloat = 115

        for (i, (preset, label)) in presets.enumerated() {
            if i == 3 {
                x = 115
            }
            let rowY = (i < 3) ? y : y - 30

            let btn = LayoutButton(preset: preset, label: label)
            btn.frame = NSRect(x: x, y: rowY, width: buttonW, height: 24)
            btn.isSelected = (preset == selected)
            btn.onClick = { [weak self] clickedPreset in
                self?.selectLayout(clickedPreset)
            }
            container.addSubview(btn)
            layoutButtons.append(btn)
            x += buttonW + spacing
        }

        return y - 68
    }

    // MARK: - Selection

    private func selectColor(_ hex: String) {
        selectedColor = hex
        for swatch in colorSwatches {
            swatch.isSelected = (swatch.hex.lowercased() == hex.lowercased())
        }
    }

    private func selectLayout(_ preset: LayoutPreset) {
        selectedLayout = preset
        for btn in layoutButtons {
            btn.isSelected = (btn.preset == preset)
        }
    }

    // MARK: - Actions

    @objc private func saveClicked() {
        let hostname = hostnameField.stringValue.isEmpty
            ? nameField.stringValue + ".localhost"
            : hostnameField.stringValue + ".localhost"

        let settings = ProjectSettings(
            name: nameField.stringValue,
            color: selectedColor,
            hostname: hostname,
            layoutPreset: selectedLayout
        )
        onSave?(settings)
        close()
    }

    @objc private func removeClicked() {
        let alert = NSAlert()
        alert.messageText = "Remove Project?"
        alert.informativeText = "This will unregister the project from DevSpace. Your files will not be deleted."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: self) { [weak self] response in
            guard let self = self, response == .alertFirstButtonReturn else { return }
            self.onRemove?(self.projectID)
            self.close()
        }
    }
}

// MARK: - Color Swatch

private final class ColorSwatchView: NSView {
    let hex: String
    var isSelected: Bool = false { didSet { needsDisplay = true } }
    var onClick: ((String) -> Void)?

    private let swatchColor: NSColor

    init(hex: String, size: CGFloat) {
        self.hex = hex
        self.swatchColor = NSColor(hex: hex)
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true

        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let radius: CGFloat = bounds.width / 2
        let path = NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2))
        swatchColor.setFill()
        path.fill()

        if isSelected {
            NSColor.white.setStroke()
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 2.0
            ring.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(hex)
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.opacity = 0.8
    }

    override func mouseExited(with event: NSEvent) {
        layer?.opacity = 1.0
    }
}

// MARK: - Layout Button

private final class LayoutButton: NSView {
    let preset: LayoutPreset
    var isSelected: Bool = false { didSet { needsDisplay = true } }
    var onClick: ((LayoutPreset) -> Void)?

    private let label: String

    init(preset: LayoutPreset, label: String) {
        self.preset = preset
        self.label = label
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6

        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
            NSColor.controlAccentColor.setStroke()
            let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5.5, yRadius: 5.5)
            border.lineWidth = 1.5
            border.stroke()
        } else {
            NSColor.quaternaryLabelColor.withAlphaComponent(0.2).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: isSelected ? .semibold : .regular),
            .foregroundColor: isSelected ? NSColor.controlAccentColor : NSColor.labelColor,
        ]
        let size = (label as NSString).size(withAttributes: attrs)
        let point = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        (label as NSString).draw(at: point, withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(preset)
    }

    override func mouseEntered(with event: NSEvent) {
        if !isSelected {
            layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.3).cgColor
        }
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
        needsDisplay = true
    }
}
