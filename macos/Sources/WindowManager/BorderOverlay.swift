import AppKit

/// A single full-screen border overlay that draws a colored line around the
/// edges of the desktop, indicating the active project.
final class ScreenBorderWindow: NSWindow {
    private let borderView: ScreenBorderView

    init(color: NSColor) {
        borderView = ScreenBorderView(color: color)

        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)

        super.init(
            contentRect: screenFrame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .screenSaver
        self.ignoresMouseEvents = true
        self.hasShadow = false
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        self.animationBehavior = .none

        self.contentView = borderView
    }

    func updateColor(_ color: NSColor) {
        borderView.updateColor(color)
    }

    func updateFrame() {
        guard let screen = NSScreen.main else { return }
        setFrame(screen.frame, display: true)
    }

    /// Re-read preferences and redraw
    func refreshFromPreferences() {
        borderView.refreshFromPreferences()
    }

    func animateIn(duration: TimeInterval? = nil) {
        let dur = duration ?? AppPreferences.shared.animationDuration
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = dur
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1.0
        }
    }

    func animateOut(duration: TimeInterval? = nil, completion: (() -> Void)? = nil) {
        let dur = duration ?? AppPreferences.shared.animationDuration
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = dur
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 0.0
        }, completionHandler: {
            self.orderOut(nil)
            completion?()
        })
    }
}

// MARK: - Screen Border View

private final class ScreenBorderView: NSView {
    private var color: NSColor
    private let cornerRadius: CGFloat = 12.0

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        layerUsesCoreImageFilters = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func updateColor(_ newColor: NSColor) {
        color = newColor
        layer?.setNeedsDisplay()
    }

    func refreshFromPreferences() {
        layer?.setNeedsDisplay()
    }

    override func updateLayer() {
        guard let layer = self.layer else { return }

        layer.sublayers?.forEach { $0.removeFromSuperlayer() }

        let prefs = AppPreferences.shared

        // If glow is disabled, don't draw anything
        guard prefs.borderGlow else { return }

        let borderWidth = prefs.borderWidth
        let glowSpread = borderWidth * 6  // scale glow relative to border width

        let inset = glowSpread / 2
        let glowRect = bounds.insetBy(dx: inset, dy: inset)
        let path = CGPath(roundedRect: glowRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

        // Soft diffused hue
        let glowLayer = CAShapeLayer()
        glowLayer.path = path
        glowLayer.fillColor = nil
        glowLayer.strokeColor = color.withAlphaComponent(0.35).cgColor
        glowLayer.lineWidth = glowSpread

        if let blur = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: glowSpread * 0.8]) {
            glowLayer.filters = [blur]
        }

        layer.addSublayer(glowLayer)

        // Tighter core for definition
        let coreLayer = CAShapeLayer()
        coreLayer.path = path
        coreLayer.fillColor = nil
        coreLayer.strokeColor = color.withAlphaComponent(0.18).cgColor
        coreLayer.lineWidth = borderWidth * 2

        if let blur = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: borderWidth * 2]) {
            coreLayer.filters = [blur]
        }

        layer.addSublayer(coreLayer)
    }

    override var wantsUpdateLayer: Bool { true }
}

// MARK: - Dim Overlay

/// A full-screen dark overlay used to dim windows not in the active project.
final class DimOverlayWindow: NSWindow {

    init() {
        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)

        super.init(
            contentRect: screenFrame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        self.isOpaque = false
        self.backgroundColor = NSColor.black.withAlphaComponent(AppPreferences.shared.dimOpacity)
        self.level = .normal
        self.ignoresMouseEvents = true
        self.hasShadow = false
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        self.animationBehavior = .none
    }

    func updateOpacity() {
        backgroundColor = NSColor.black.withAlphaComponent(AppPreferences.shared.dimOpacity)
    }

    func updateFrame() {
        guard let screen = NSScreen.main else { return }
        setFrame(screen.frame, display: true)
    }

    func fadeIn(duration: TimeInterval? = nil) {
        let dur = duration ?? AppPreferences.shared.animationDuration
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = dur
            self.animator().alphaValue = 1.0
        }
    }

    func fadeOut(duration: TimeInterval? = nil, completion: (() -> Void)? = nil) {
        let dur = duration ?? AppPreferences.shared.animationDuration
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = dur
            self.animator().alphaValue = 0.0
        }, completionHandler: {
            self.orderOut(nil)
            completion?()
        })
    }
}
