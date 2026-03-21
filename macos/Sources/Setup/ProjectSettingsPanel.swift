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
    private let projectTLD: String
    private let nameField = NSTextField()
    private let hostnameField = NSTextField()
    private var selectedColor: String
    private var selectedLayout: LayoutPreset
    private var colorSwatches: [ColorSwatchView] = []
    private var layoutCards: [LayoutCardView] = []
    private var accentLine: NSView!

    private let colorPalette = [
        "#3B82F6", "#10B981", "#F59E0B", "#EF4444", "#8B5CF6", "#EC4899",
        "#06B6D4", "#84CC16", "#F97316", "#6366F1",
    ]

    private let panelW: CGFloat = 420
    private let panelH: CGFloat = 440
    private let inset: CGFloat = 24

    init(project: Project) {
        self.projectID = project.id
        let lastComponent = project.hostname.components(separatedBy: ".").last ?? "test"
        self.projectTLD = lastComponent.isEmpty ? "test" : lastComponent
        self.selectedColor = project.color.hex
        self.selectedLayout = project.layoutPreset ?? .codeFocus

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 440),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        title = ""
        isMovableByWindowBackground = true
        level = .floating
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
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

        let contentW = panelW - inset * 2

        // Thin accent line at top edge
        accentLine = NSView(frame: NSRect(x: 0, y: panelH - 2, width: panelW, height: 2))
        accentLine.wantsLayer = true
        accentLine.layer?.backgroundColor = NSColor(hex: selectedColor).cgColor
        bg.addSubview(accentLine)

        // --- Top section: name + hostname ---
        // Leave room for titlebar drag area (~28px)
        var y: CGFloat = panelH - 58

        // Color dot + project name on same line
        let dotSize: CGFloat = 10
        let dot = NSView(frame: NSRect(x: inset, y: y + 9, width: dotSize, height: dotSize))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = dotSize / 2
        dot.layer?.backgroundColor = NSColor(hex: selectedColor).cgColor
        bg.addSubview(dot)

        let nameX = inset + dotSize + 8
        let nameW = contentW - dotSize - 8
        nameField.stringValue = project.name
        nameField.isEditable = true
        nameField.isBezeled = false
        nameField.drawsBackground = false
        nameField.font = .systemFont(ofSize: 20, weight: .semibold)
        nameField.textColor = .labelColor
        nameField.focusRingType = .none
        nameField.frame = NSRect(x: nameX, y: y, width: nameW, height: 28)
        bg.addSubview(nameField)

        // Underline for name field
        let nameUnderline = NSView(frame: NSRect(x: nameX, y: y - 1, width: nameW, height: 1))
        nameUnderline.wantsLayer = true
        nameUnderline.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
        bg.addSubview(nameUnderline)

        y -= 28

        // Hostname row
        let hostPrefix = NSTextField(labelWithString: "http://")
        hostPrefix.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        hostPrefix.textColor = .tertiaryLabelColor
        hostPrefix.sizeToFit()
        hostPrefix.frame.origin = NSPoint(x: inset, y: y)
        bg.addSubview(hostPrefix)

        let editable = project.hostname.components(separatedBy: ".").first ?? project.hostname
        hostnameField.stringValue = editable
        hostnameField.isEditable = true
        hostnameField.isBezeled = false
        hostnameField.drawsBackground = false
        hostnameField.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        hostnameField.textColor = .secondaryLabelColor
        hostnameField.focusRingType = .none
        hostnameField.frame = NSRect(x: hostPrefix.frame.maxX, y: y, width: 140, height: 16)
        bg.addSubview(hostnameField)

        // Underline for hostname field
        let hostUnderline = NSView(frame: NSRect(x: hostPrefix.frame.maxX, y: y - 2, width: 140, height: 1))
        hostUnderline.wantsLayer = true
        hostUnderline.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
        bg.addSubview(hostUnderline)

        let hostSuffix = NSTextField(labelWithString: ".\(projectTLD)")
        hostSuffix.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        hostSuffix.textColor = .tertiaryLabelColor
        hostSuffix.sizeToFit()
        hostSuffix.frame.origin = NSPoint(x: hostnameField.frame.maxX, y: y)
        bg.addSubview(hostSuffix)

        y -= 20
        addSeparator(in: bg, y: y, width: contentW)

        // --- Color section ---
        y -= 28

        let colorLabel = NSTextField(labelWithString: "COLOR")
        colorLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        colorLabel.textColor = .tertiaryLabelColor
        colorLabel.frame = NSRect(x: inset, y: y + 30, width: 60, height: 12)
        bg.addSubview(colorLabel)

        let swatchSize: CGFloat = 24
        let swatchSpacing: CGFloat = 6
        let totalSwatchW = CGFloat(colorPalette.count) * swatchSize + CGFloat(colorPalette.count - 1) * swatchSpacing
        var sx: CGFloat = inset + (contentW - totalSwatchW) / 2

        for hex in colorPalette {
            let swatch = ColorSwatchView(hex: hex, size: swatchSize)
            swatch.frame = NSRect(x: sx, y: y, width: swatchSize, height: swatchSize)
            swatch.isSelected = (hex.lowercased() == selectedColor.lowercased())
            swatch.onClick = { [weak self] clickedHex in
                self?.selectColor(clickedHex)
            }
            bg.addSubview(swatch)
            colorSwatches.append(swatch)
            sx += swatchSize + swatchSpacing
        }

        y -= 20
        addSeparator(in: bg, y: y, width: contentW)

        // --- Layout section ---
        y -= 12

        let layoutLabel = NSTextField(labelWithString: "LAYOUT")
        layoutLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        layoutLabel.textColor = .tertiaryLabelColor
        layoutLabel.frame = NSRect(x: inset, y: y, width: 60, height: 12)
        bg.addSubview(layoutLabel)

        y -= 8

        let presets: [(LayoutPreset, String)] = [
            (.codeFocus, "Code"), (.previewFocus, "Preview"), (.equalSplit, "Equal"),
            (.stacked, "Stack"), (.pair, "Pair"), (.fullscreen, "Full"),
        ]

        let cols = 3
        let cardSpacing: CGFloat = 8
        let cardW = (contentW - CGFloat(cols - 1) * cardSpacing) / CGFloat(cols)
        let cardH: CGFloat = 72

        for (i, (preset, label)) in presets.enumerated() {
            let col = i % cols
            let row = i / cols
            let cx = inset + CGFloat(col) * (cardW + cardSpacing)
            let cy = y - cardH - CGFloat(row) * (cardH + cardSpacing)

            let card = LayoutCardView(preset: preset, label: label, projectColor: selectedColor)
            card.frame = NSRect(x: cx, y: cy, width: cardW, height: cardH)
            card.isSelected = (preset == selectedLayout)
            card.onClick = { [weak self] clickedPreset in
                self?.selectLayout(clickedPreset)
            }
            bg.addSubview(card)
            layoutCards.append(card)
        }

        // --- Bottom actions ---
        let bottomY: CGFloat = 20

        let removeButton = NSButton(title: "Remove", target: self, action: #selector(removeClicked))
        removeButton.bezelStyle = .rounded
        removeButton.contentTintColor = NSColor.systemRed.withAlphaComponent(0.7)
        removeButton.frame = NSRect(x: inset, y: bottomY, width: 80, height: 28)
        bg.addSubview(removeButton)

        let saveButton = NSButton(title: "Save", target: self, action: #selector(saveClicked))
        saveButton.bezelStyle = .rounded
        saveButton.controlSize = .large
        saveButton.keyEquivalent = "\r"
        let saveW: CGFloat = 100
        saveButton.frame = NSRect(x: panelW - inset - saveW, y: bottomY, width: saveW, height: 32)
        bg.addSubview(saveButton)
    }

    private func addSeparator(in container: NSView, y: CGFloat, width: CGFloat) {
        let sep = NSView(frame: NSRect(x: inset, y: y, width: width, height: 1))
        sep.wantsLayer = true
        sep.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        container.addSubview(sep)
    }

    // MARK: - Selection

    private func selectColor(_ hex: String) {
        selectedColor = hex
        for swatch in colorSwatches {
            swatch.isSelected = (swatch.hex.lowercased() == hex.lowercased())
        }
        for card in layoutCards {
            card.projectColor = hex
            card.needsDisplay = true
        }
        // Update dot
        if let dot = contentView?.subviews.first(where: {
            $0.layer?.cornerRadius == 5 && $0.frame.size.width == 10
        }) {
            dot.layer?.backgroundColor = NSColor(hex: hex).cgColor
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            accentLine.animator().layer?.backgroundColor = NSColor(hex: hex).cgColor
        }
    }

    private func selectLayout(_ preset: LayoutPreset) {
        selectedLayout = preset
        for card in layoutCards {
            card.isSelected = (card.preset == preset)
        }
    }

    // MARK: - Actions

    @objc private func saveClicked() {
        let hostname = hostnameField.stringValue.isEmpty
            ? nameField.stringValue + "." + projectTLD
            : hostnameField.stringValue + "." + projectTLD

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
        if isSelected {
            let path = NSBezierPath(ovalIn: bounds.insetBy(dx: 3, dy: 3))
            swatchColor.setFill()
            path.fill()

            swatchColor.withAlphaComponent(0.4).setStroke()
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
            ring.lineWidth = 1.5
            ring.stroke()
        } else {
            let path = NSBezierPath(ovalIn: bounds.insetBy(dx: 4, dy: 4))
            swatchColor.setFill()
            path.fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(hex)
    }

    override func mouseEntered(with event: NSEvent) {
        if !isSelected { animator().alphaValue = 0.7 }
    }

    override func mouseExited(with event: NSEvent) {
        animator().alphaValue = 1.0
    }
}

// MARK: - Layout Card View

private final class LayoutCardView: NSView {
    let preset: LayoutPreset
    var isSelected: Bool = false { didSet { needsDisplay = true } }
    var onClick: ((LayoutPreset) -> Void)?
    var projectColor: String = "#3B82F6"

    private let label: String

    init(preset: LayoutPreset, label: String, projectColor: String) {
        self.preset = preset
        self.label = label
        self.projectColor = projectColor
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous

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
        let accentColor = NSColor(hex: projectColor)

        if isSelected {
            accentColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
            accentColor.withAlphaComponent(0.5).setStroke()
            let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7.5, yRadius: 7.5)
            border.lineWidth = 1
            border.stroke()
        } else {
            NSColor.white.withAlphaComponent(0.04).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        }

        // Wireframe thumbnail
        let thumbW: CGFloat = bounds.width - 16
        let thumbH: CGFloat = 36
        let thumbX: CGFloat = 8
        let thumbY: CGFloat = bounds.height - thumbH - 10
        drawMiniLayout(in: NSRect(x: thumbX, y: thumbY, width: thumbW, height: thumbH),
                       selected: isSelected, accent: accentColor)

        // Label
        let textColor = isSelected ? accentColor : NSColor.secondaryLabelColor
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: isSelected ? .semibold : .regular),
            .foregroundColor: textColor,
        ]
        let textSize = (label as NSString).size(withAttributes: attrs)
        let textX = (bounds.width - textSize.width) / 2
        (label as NSString).draw(at: NSPoint(x: textX, y: 6), withAttributes: attrs)
    }

    private func drawMiniLayout(in rect: NSRect, selected: Bool, accent: NSColor) {
        let wireColor = selected ? accent.withAlphaComponent(0.6) : NSColor.white.withAlphaComponent(0.2)
        let fillColor = selected ? accent.withAlphaComponent(0.08) : NSColor.white.withAlphaComponent(0.04)
        let highlightFill = selected ? accent.withAlphaComponent(0.15) : NSColor.white.withAlphaComponent(0.06)
        let gap: CGFloat = 2

        // Outer frame
        fillColor.setFill()
        wireColor.setStroke()
        let box = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
        box.lineWidth = 0.75
        box.fill()
        box.stroke()

        switch preset {
        case .codeFocus:
            let splitX = rect.minX + rect.width * 0.65
            drawVLine(x: splitX, rect: rect, gap: gap, color: wireColor)
            highlightFill.setFill()
            NSBezierPath(rect: NSRect(x: rect.minX + 1, y: rect.minY + 1,
                                      width: splitX - rect.minX - 1.5, height: rect.height - 2)).fill()

        case .previewFocus:
            let splitX = rect.minX + rect.width * 0.35
            drawVLine(x: splitX, rect: rect, gap: gap, color: wireColor)
            highlightFill.setFill()
            NSBezierPath(rect: NSRect(x: splitX + 0.5, y: rect.minY + 1,
                                      width: rect.maxX - splitX - 1, height: rect.height - 2)).fill()

        case .equalSplit:
            for i in 1...2 {
                let x = rect.minX + rect.width * CGFloat(i) / 3
                drawVLine(x: x, rect: rect, gap: gap, color: wireColor)
            }

        case .stacked:
            let splitY1 = rect.minY + rect.height * 0.33
            let splitY2 = rect.minY + rect.height * 0.66
            drawHLine(y: splitY1, rect: rect, gap: gap, color: wireColor)
            drawHLine(y: splitY2, rect: rect, gap: gap, color: wireColor)
            highlightFill.setFill()
            NSBezierPath(rect: NSRect(x: rect.minX + 1, y: splitY2 + 0.5,
                                      width: rect.width - 2, height: rect.maxY - splitY2 - 1)).fill()

        case .pair:
            drawVLine(x: rect.midX, rect: rect, gap: gap, color: wireColor)

        case .fullscreen:
            highlightFill.setFill()
            NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1)).fill()
        }
    }

    private func drawVLine(x: CGFloat, rect: NSRect, gap: CGFloat, color: NSColor) {
        color.setStroke()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: x, y: rect.minY + gap))
        line.line(to: NSPoint(x: x, y: rect.maxY - gap))
        line.lineWidth = 0.75
        line.stroke()
    }

    private func drawHLine(y: CGFloat, rect: NSRect, gap: CGFloat, color: NSColor) {
        color.setStroke()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: rect.minX + gap, y: y))
        line.line(to: NSPoint(x: rect.maxX - gap, y: y))
        line.lineWidth = 0.75
        line.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(preset)
    }

    override func mouseEntered(with event: NSEvent) {
        if !isSelected {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        }
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
        needsDisplay = true
    }
}
