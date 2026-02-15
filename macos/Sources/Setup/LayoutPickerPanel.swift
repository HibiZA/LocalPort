import AppKit

/// A floating panel that lets the user pick a window layout preset before
/// launching a new project.
final class LayoutPickerPanel: NSPanel {
    var onSelect: ((LayoutPreset) -> Void)?

    private var selectedPreset: LayoutPreset = .codeFocus
    private var cards: [LayoutCardView] = []
    private let addButton = NSButton()

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        title = "Choose Layout"
        isMovableByWindowBackground = true
        level = .floating
        center()

        setupUI()
    }

    private func setupUI() {
        let bg = NSVisualEffectView()
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        contentView = bg

        // Title label
        let titleLabel = NSTextField(labelWithString: "How should your windows be arranged?")
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(titleLabel)

        // Layout cards — 2 rows of 3
        let presets: [(LayoutPreset, String, String)] = [
            (.codeFocus,    "Code Focus",    "┃ Editor  ┃ Term ┃\n┃  60%    ┃ Brws ┃"),
            (.previewFocus, "Preview Focus", "┃ Term ┃ Browser ┃\n┃ Edit ┃  60%    ┃"),
            (.equalSplit,   "Equal Split",   "┃ Edit ┃ Brws ┃ Term ┃\n┃ 33%  ┃ 33%  ┃ 33%  ┃"),
            (.stacked,      "Stacked",       "┃   Editor  50%   ┃\n┃  Browser  25%   ┃\n┃  Terminal  25%  ┃"),
            (.pair,         "Pair",          "┃ Editor ┃ Browser ┃\n┃  50%   ┃  50%    ┃"),
            (.fullscreen,   "Fullscreen",    "┃                  ┃\n┃   Editor 100%    ┃\n┃                  ┃"),
        ]

        let topRow = NSStackView()
        topRow.orientation = .horizontal
        topRow.spacing = 12
        topRow.distribution = .fillEqually
        topRow.translatesAutoresizingMaskIntoConstraints = false

        let bottomRow = NSStackView()
        bottomRow.orientation = .horizontal
        bottomRow.spacing = 12
        bottomRow.distribution = .fillEqually
        bottomRow.translatesAutoresizingMaskIntoConstraints = false

        for (i, (preset, label, diagram)) in presets.enumerated() {
            let card = LayoutCardView(preset: preset, label: label, diagram: diagram)
            card.onClick = { [weak self] selected in
                self?.selectPreset(selected)
            }
            if i < 3 {
                topRow.addArrangedSubview(card)
            } else {
                bottomRow.addArrangedSubview(card)
            }
            cards.append(card)
        }

        bg.addSubview(topRow)
        bg.addSubview(bottomRow)

        // Select default
        cards.first?.isSelected = true

        // Add Project button
        addButton.title = "Add Project"
        addButton.bezelStyle = .rounded
        addButton.controlSize = .large
        addButton.keyEquivalent = "\r"
        addButton.target = self
        addButton.action = #selector(confirmSelection)
        addButton.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(addButton)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: bg.topAnchor, constant: 20),
            titleLabel.centerXAnchor.constraint(equalTo: bg.centerXAnchor),

            topRow.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 20),
            topRow.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 20),
            topRow.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -20),
            topRow.heightAnchor.constraint(equalToConstant: 120),

            bottomRow.topAnchor.constraint(equalTo: topRow.bottomAnchor, constant: 12),
            bottomRow.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 20),
            bottomRow.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -20),
            bottomRow.heightAnchor.constraint(equalToConstant: 120),

            addButton.topAnchor.constraint(equalTo: bottomRow.bottomAnchor, constant: 20),
            addButton.centerXAnchor.constraint(equalTo: bg.centerXAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 140),
        ])
    }

    private func selectPreset(_ preset: LayoutPreset) {
        selectedPreset = preset
        for card in cards {
            card.isSelected = card.preset == preset
        }
    }

    @objc private func confirmSelection() {
        onSelect?(selectedPreset)
        close()
    }
}

// MARK: - Layout Card View

private final class LayoutCardView: NSView {
    let preset: LayoutPreset
    var isSelected: Bool = false { didSet { needsDisplay = true } }
    var onClick: ((LayoutPreset) -> Void)?

    private let label: String
    private let diagram: String

    init(preset: LayoutPreset, label: String, diagram: String) {
        self.preset = preset
        self.label = label
        self.diagram = diagram
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10

        setupUI()

        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        let diagramLabel = NSTextField(labelWithString: diagram)
        diagramLabel.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
        diagramLabel.textColor = .secondaryLabelColor
        diagramLabel.alignment = .center
        diagramLabel.maximumNumberOfLines = 0
        diagramLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(diagramLabel)

        let nameLabel = NSTextField(labelWithString: label)
        nameLabel.font = .systemFont(ofSize: 11, weight: .medium)
        nameLabel.textColor = .labelColor
        nameLabel.alignment = .center
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)

        NSLayoutConstraint.activate([
            diagramLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            diagramLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -10),
            diagramLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 6),
            diagramLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),

            nameLabel.topAnchor.constraint(equalTo: diagramLabel.bottomAnchor, constant: 8),
            nameLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if isSelected {
            let bgColor = NSColor.controlAccentColor.withAlphaComponent(0.1)
            bgColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()

            NSColor.controlAccentColor.setStroke()
            let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9)
            border.lineWidth = 2.0
            border.stroke()
        } else {
            NSColor.quaternaryLabelColor.withAlphaComponent(0.15).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(preset)
    }

    override func mouseEntered(with event: NSEvent) {
        if !isSelected {
            layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.25).cgColor
        }
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
        needsDisplay = true
    }
}
