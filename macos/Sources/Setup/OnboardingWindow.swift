import AppKit
import os.log

private let logger = Logger(subsystem: "com.devspace.app", category: "Onboarding")

// MARK: - App Icon Card

private final class AppCardView: NSView {
    let app: DetectedApp
    var isSelected: Bool = false { didSet { needsDisplay = true } }
    var onClick: ((DetectedApp) -> Void)?

    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")

    init(app: DetectedApp) {
        self.app = app
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12

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
        // Load icon from the app bundle
        let icon = NSWorkspace.shared.icon(forFile: app.path)
        icon.size = NSSize(width: 48, height: 48)

        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        nameLabel.stringValue = app.name
        nameLabel.font = .systemFont(ofSize: 11, weight: .medium)
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 2
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)

        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            iconView.widthAnchor.constraint(equalToConstant: 48),
            iconView.heightAnchor.constraint(equalToConstant: 48),

            nameLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 6),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
        ])
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if isSelected {
            // Selected state: accent color border + tinted background
            let bgColor = NSColor.controlAccentColor.withAlphaComponent(0.1)
            bgColor.setFill()
            let bg = NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12)
            bg.fill()

            NSColor.controlAccentColor.setStroke()
            let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 11, yRadius: 11)
            border.lineWidth = 2.0
            border.stroke()
        } else {
            // Default: subtle background
            let bgColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.15)
            bgColor.setFill()
            let bg = NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12)
            bg.fill()
        }
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

    override func mouseDown(with event: NSEvent) {
        onClick?(app)
    }
}

// MARK: - App Selection Row (horizontal strip of icon cards)

private final class AppSelectionRow: NSView {
    var cards: [AppCardView] = []
    var selectedApp: DetectedApp? { cards.first(where: \.isSelected)?.app }
    var onSelectionChanged: ((DetectedApp) -> Void)?

    private let scrollView = NSScrollView()
    private let stackView = NSStackView()

    init(apps: [DetectedApp]) {
        super.init(frame: .zero)
        setupUI(apps: apps)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupUI(apps: [DetectedApp]) {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        addSubview(scrollView)

        stackView.orientation = .horizontal
        stackView.spacing = 10
        stackView.translatesAutoresizingMaskIntoConstraints = false

        let cardWidth: CGFloat = 88
        let cardHeight: CGFloat = 88

        for app in apps {
            let card = AppCardView(app: app)
            card.translatesAutoresizingMaskIntoConstraints = false
            card.onClick = { [weak self] selected in
                self?.selectApp(selected)
            }

            NSLayoutConstraint.activate([
                card.widthAnchor.constraint(equalToConstant: cardWidth),
                card.heightAnchor.constraint(equalToConstant: cardHeight),
            ])

            stackView.addArrangedSubview(card)
            cards.append(card)
        }

        scrollView.documentView = stackView

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stackView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            stackView.heightAnchor.constraint(equalToConstant: cardHeight),
        ])

        // Auto-select first
        if let first = cards.first {
            first.isSelected = true
        }
    }

    private func selectApp(_ app: DetectedApp) {
        for card in cards {
            card.isSelected = (card.app == app)
        }
        onSelectionChanged?(app)
    }
}

// MARK: - Onboarding Window Controller

final class OnboardingWindowController: NSWindowController {
    private let scanner = AppScanner()
    private let prefs = UserAppPreferences.shared
    var onComplete: (() -> Void)?

    private var detectedApps: [DetectedApp] = []
    private var ideRow: AppSelectionRow!
    private var browserRow: AppSelectionRow!
    private var terminalRow: AppSelectionRow!

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 560),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to DevSpace"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.center()
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor.windowBackgroundColor

        super.init(window: window)

        detectedApps = scanner.scan()
        window.contentView = buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - UI

    private func buildUI() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 580, height: 560))

        // Title
        let title = NSTextField(labelWithString: "Set up your workspace")
        title.font = .systemFont(ofSize: 26, weight: .bold)
        title.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(title)

        // Subtitle
        let subtitle = NSTextField(wrappingLabelWithString: "DevSpace will open these apps when you launch a project.\nYou can change these later in Preferences.")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(subtitle)

        // IDE section
        let ideLabel = sectionLabel("Editor / IDE")
        ideLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(ideLabel)

        let ideApps = detectedApps.filter { $0.category == .ide }
        ideRow = AppSelectionRow(apps: ideApps)
        ideRow.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(ideRow)

        // Browser section
        let browserLabel = sectionLabel("Browser")
        browserLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(browserLabel)

        let browserApps = detectedApps.filter { $0.category == .browser }
        browserRow = AppSelectionRow(apps: browserApps)
        browserRow.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(browserRow)

        // Terminal section
        let termLabel = sectionLabel("Terminal")
        termLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(termLabel)

        let termApps = detectedApps.filter { $0.category == .terminal }
        terminalRow = AppSelectionRow(apps: termApps)
        terminalRow.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminalRow)

        // Buttons
        let continueButton = NSButton(title: "Get Started", target: self, action: #selector(onContinue))
        continueButton.bezelStyle = .rounded
        continueButton.controlSize = .large
        continueButton.keyEquivalent = "\r"
        continueButton.contentTintColor = .white
        continueButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(continueButton)

        let skipButton = NSButton(title: "Skip for now", target: self, action: #selector(onSkip))
        skipButton.bezelStyle = .rounded
        skipButton.controlSize = .large
        skipButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(skipButton)

        let rowHeight: CGFloat = 92

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 40),
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 40),
            title.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -40),

            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),

            ideLabel.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 24),
            ideLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),

            ideRow.topAnchor.constraint(equalTo: ideLabel.bottomAnchor, constant: 8),
            ideRow.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            ideRow.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            ideRow.heightAnchor.constraint(equalToConstant: rowHeight),

            browserLabel.topAnchor.constraint(equalTo: ideRow.bottomAnchor, constant: 16),
            browserLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),

            browserRow.topAnchor.constraint(equalTo: browserLabel.bottomAnchor, constant: 8),
            browserRow.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            browserRow.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            browserRow.heightAnchor.constraint(equalToConstant: rowHeight),

            termLabel.topAnchor.constraint(equalTo: browserRow.bottomAnchor, constant: 16),
            termLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),

            terminalRow.topAnchor.constraint(equalTo: termLabel.bottomAnchor, constant: 8),
            terminalRow.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            terminalRow.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            terminalRow.heightAnchor.constraint(equalToConstant: rowHeight),

            continueButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -28),
            continueButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -40),
            continueButton.widthAnchor.constraint(equalToConstant: 120),
            continueButton.heightAnchor.constraint(equalToConstant: 36),

            skipButton.centerYAnchor.constraint(equalTo: continueButton.centerYAnchor),
            skipButton.trailingAnchor.constraint(equalTo: continueButton.leadingAnchor, constant: -12),
            skipButton.widthAnchor.constraint(equalToConstant: 120),
            skipButton.heightAnchor.constraint(equalToConstant: 36),
        ])

        return container
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    // MARK: - Actions

    @objc private func onContinue() {
        if let app = ideRow.selectedApp { prefs.preferredIDE = app }
        if let app = browserRow.selectedApp { prefs.preferredBrowser = app }
        if let app = terminalRow.selectedApp { prefs.preferredTerminal = app }

        prefs.isOnboardingComplete = true

        logger.info("Onboarding complete — IDE: \(self.prefs.preferredIDE?.name ?? "none"), Browser: \(self.prefs.preferredBrowser?.name ?? "none"), Terminal: \(self.prefs.preferredTerminal?.name ?? "none")")

        window?.close()
        NSApp.setActivationPolicy(.accessory)
        onComplete?()
    }

    @objc private func onSkip() {
        prefs.isOnboardingComplete = true
        window?.close()
        NSApp.setActivationPolicy(.accessory)
        onComplete?()
    }
}
