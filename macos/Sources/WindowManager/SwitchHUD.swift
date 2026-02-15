import AppKit

/// A brief floating HUD that shows the project name + color when switching.
/// Mimics the macOS volume/brightness indicator style.
final class SwitchHUD {
    private var hudWindow: NSWindow?
    private var hideTimer: Timer?

    /// Show the HUD centered on screen with the project name and color dot
    func show(projectName: String, color: NSColor) {
        hideTimer?.invalidate()

        let window = hudWindow ?? createWindow()
        hudWindow = window

        // Update content
        guard let contentView = window.contentView else { return }
        updateContent(in: contentView, name: projectName, color: color)

        // Position center of main screen, slightly above center
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - window.frame.width / 2
            let y = screenFrame.midY - window.frame.height / 2 + screenFrame.height * 0.15
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        // Animate in
        window.alphaValue = 0
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1.0
        }

        // Auto-hide after 1.2 seconds
        hideTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            self?.hide()
        }
    }

    private func hide() {
        guard let window = hudWindow else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.hudWindow?.orderOut(nil)
        })
    }

    private func createWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 72),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.hasShadow = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let content = NSView(frame: window.contentRect(forFrameRect: window.frame))
        content.wantsLayer = true
        content.layer?.cornerRadius = 18
        content.layer?.masksToBounds = true

        // Vibrancy background (like macOS system HUDs)
        let visualEffect = NSVisualEffectView(frame: content.bounds)
        visualEffect.autoresizingMask = [.width, .height]
        visualEffect.material = .hudWindow
        visualEffect.state = .active
        visualEffect.blendingMode = .behindWindow
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 18
        content.addSubview(visualEffect)

        window.contentView = content
        return window
    }

    private func updateContent(in contentView: NSView, name: String, color: NSColor) {
        // Remove old labels/dots (keep the visual effect view)
        for subview in contentView.subviews where !(subview is NSVisualEffectView) {
            subview.removeFromSuperview()
        }

        // Color dot
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 7
        dot.layer?.backgroundColor = color.cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(dot)

        // Project name
        let label = NSTextField(labelWithString: name)
        label.font = .systemFont(ofSize: 20, weight: .semibold)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)

        NSLayoutConstraint.activate([
            dot.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            dot.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            dot.widthAnchor.constraint(equalToConstant: 14),
            dot.heightAnchor.constraint(equalToConstant: 14),

            label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 12),
            label.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -24),
        ])
    }
}
