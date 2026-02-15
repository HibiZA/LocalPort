import AppKit
import os.log

private let logger = Logger(subsystem: "com.devspace.app", category: "LayoutManager")

final class LayoutManager {

    // MARK: - Save / Restore

    func saveLayout(for project: inout Project, windows: [TrackedWindow]) {
        var layout = SavedLayout()
        for window in windows {
            layout.frames[window.windowID] = window.bounds
        }
        project.savedLayout = layout
        let name = project.name
        logger.info("Saved layout for \(name) (\(windows.count) windows)")
    }

    func restoreLayout(for project: Project, windows: [TrackedWindow]) {
        guard let layout = project.savedLayout else {
            // No saved layout — auto-tile instead
            autoTile(windows: windows, preset: project.layoutPreset ?? .codeFocus)
            return
        }

        for window in windows {
            if let savedFrame = layout.frames[window.windowID] {
                moveWindow(window, to: savedFrame)
            }
        }
        logger.info("Restored layout for \(project.name)")
    }

    // MARK: - Frame Computation

    /// Pre-compute target frames for each window role based on the layout preset.
    /// Call this BEFORE launching apps so you can position windows immediately as they appear.
    func computeFrames(preset: LayoutPreset = .codeFocus, screen: NSScreen? = nil) -> [WindowRole: CGRect] {
        let screen = screen ?? NSScreen.main!
        let visibleFrame = screen.visibleFrame
        var frames: [WindowRole: CGRect] = [:]

        switch preset {
        case .codeFocus:
            let splitX = visibleFrame.minX + visibleFrame.width * 0.6
            let rightWidth = visibleFrame.width * 0.4
            let halfHeight = visibleFrame.height / 2

            frames[.editor] = CGRect(
                x: visibleFrame.minX, y: visibleFrame.minY,
                width: visibleFrame.width * 0.6, height: visibleFrame.height
            )
            frames[.browser] = CGRect(
                x: splitX, y: visibleFrame.minY + halfHeight,
                width: rightWidth, height: halfHeight
            )
            frames[.terminal] = CGRect(
                x: splitX, y: visibleFrame.minY,
                width: rightWidth, height: halfHeight
            )

        case .previewFocus:
            let leftWidth = visibleFrame.width * 0.4
            let halfHeight = visibleFrame.height / 2

            frames[.editor] = CGRect(
                x: visibleFrame.minX, y: visibleFrame.minY + halfHeight,
                width: leftWidth, height: halfHeight
            )
            frames[.terminal] = CGRect(
                x: visibleFrame.minX, y: visibleFrame.minY,
                width: leftWidth, height: halfHeight
            )
            frames[.browser] = CGRect(
                x: visibleFrame.minX + leftWidth, y: visibleFrame.minY,
                width: visibleFrame.width * 0.6, height: visibleFrame.height
            )

        case .equalSplit:
            let colWidth = visibleFrame.width / 3
            frames[.editor] = CGRect(
                x: visibleFrame.minX, y: visibleFrame.minY,
                width: colWidth, height: visibleFrame.height
            )
            frames[.browser] = CGRect(
                x: visibleFrame.minX + colWidth, y: visibleFrame.minY,
                width: colWidth, height: visibleFrame.height
            )
            frames[.terminal] = CGRect(
                x: visibleFrame.minX + colWidth * 2, y: visibleFrame.minY,
                width: colWidth, height: visibleFrame.height
            )

        case .stacked:
            // Three horizontal rows: editor on top (50%), browser middle (25%), terminal bottom (25%)
            let editorH = visibleFrame.height * 0.5
            let lowerH = visibleFrame.height * 0.25

            frames[.editor] = CGRect(
                x: visibleFrame.minX, y: visibleFrame.minY + visibleFrame.height - editorH,
                width: visibleFrame.width, height: editorH
            )
            frames[.browser] = CGRect(
                x: visibleFrame.minX, y: visibleFrame.minY + lowerH,
                width: visibleFrame.width, height: lowerH
            )
            frames[.terminal] = CGRect(
                x: visibleFrame.minX, y: visibleFrame.minY,
                width: visibleFrame.width, height: lowerH
            )

        case .pair:
            // Editor + browser side-by-side (50/50), terminal hidden below browser
            let halfW = visibleFrame.width / 2

            frames[.editor] = CGRect(
                x: visibleFrame.minX, y: visibleFrame.minY,
                width: halfW, height: visibleFrame.height
            )
            frames[.browser] = CGRect(
                x: visibleFrame.minX + halfW, y: visibleFrame.minY,
                width: halfW, height: visibleFrame.height
            )
            // Terminal gets a small strip at the bottom-right
            frames[.terminal] = CGRect(
                x: visibleFrame.minX + halfW, y: visibleFrame.minY,
                width: halfW, height: visibleFrame.height * 0.3
            )

        case .fullscreen:
            // Editor takes the full screen, others get minimal space
            frames[.editor] = visibleFrame
            frames[.browser] = CGRect(
                x: visibleFrame.minX, y: visibleFrame.minY,
                width: visibleFrame.width, height: visibleFrame.height
            )
            frames[.terminal] = CGRect(
                x: visibleFrame.minX, y: visibleFrame.minY,
                width: visibleFrame.width, height: visibleFrame.height
            )
        }

        return frames
    }

    // MARK: - Auto-Tile

    func autoTile(windows: [TrackedWindow], preset: LayoutPreset = .codeFocus, screen: NSScreen? = nil) {
        let frames = computeFrames(preset: preset, screen: screen)

        logger.info("autoTile: \(windows.count) window(s), preset: \(preset.rawValue, privacy: .public)")

        for window in windows {
            if let frame = frames[window.windowRole] {
                moveWindow(window, to: frame)
            }
        }
    }

    // MARK: - Window Manipulation

    func moveWindow(_ window: TrackedWindow, to frame: CGRect) {
        logger.info("moveWindow: \(window.appName, privacy: .public) (ID \(window.windowID), PID \(window.ownerPID)) → \(NSStringFromRect(frame), privacy: .public)")
        guard let axWindow = findAXWindow(windowID: window.windowID, pid: window.ownerPID) else {
            logger.warning("Could not find AX window for \(window.appName) (ID \(window.windowID))")
            return
        }

        // Set position
        var newPos = frame.origin
        if let posValue = AXValueCreate(.cgPoint, &newPos) {
            AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, posValue)
        }

        // Set size
        var newSize = frame.size
        if let sizeValue = AXValueCreate(.cgSize, &newSize) {
            AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeValue)
        }
    }

    /// Find an AXUIElement by matching its CGWindowID
    private func findAXWindow(windowID: CGWindowID, pid: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else { return nil }

        for axWindow in axWindows {
            var axWindowID: CGWindowID = 0
            _AXUIElementGetWindow(axWindow, &axWindowID)
            if axWindowID == windowID {
                return axWindow
            }
        }
        return nil
    }

    func bringToFront(_ window: TrackedWindow) {
        guard let axWindow = findAXWindow(windowID: window.windowID, pid: window.ownerPID) else { return }

        AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)

        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == window.ownerPID }) {
            app.activate()
        }
    }

    func focusWindow(_ window: TrackedWindow) {
        bringToFront(window)
    }
}

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError
