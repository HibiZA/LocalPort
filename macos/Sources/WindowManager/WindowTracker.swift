import AppKit
import os.log

private let logger = Logger(subsystem: "com.devspace.app", category: "WindowTracker")

protocol WindowTrackerDelegate: AnyObject {
    func windowTracker(_ tracker: WindowTracker, didUpdateWindows windows: [TrackedWindow])
    func windowTracker(_ tracker: WindowTracker, windowFocused window: TrackedWindow)
}

final class WindowTracker {
    weak var delegate: WindowTrackerDelegate?

    private(set) var trackedWindows: [CGWindowID: TrackedWindow] = [:]
    private var projects: [Project] = []
    private var pollTimer: Timer?
    private var axObservers: [pid_t: AXObserver] = [:]

    // MARK: - Lifecycle

    func start() {
        guard checkAccessibilityPermission() else {
            logger.error("Accessibility permission not granted")
            return
        }

        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.pollWindows()
        }
        RunLoop.current.add(pollTimer!, forMode: .common)

        // Observe app activation for immediate focus tracking
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidTerminate(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )

        // Initial scan
        pollWindows()
        logger.info("WindowTracker started")
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        for (_, observer) in axObservers {
            CFRunLoopRemoveSource(
                CFRunLoopGetCurrent(),
                AXObserverGetRunLoopSource(observer),
                .defaultMode
            )
        }
        axObservers.removeAll()
    }

    func updateProjects(_ projects: [Project]) {
        self.projects = projects
        // Re-evaluate all window assignments
        for (id, window) in trackedWindows {
            trackedWindows[id]?.projectID = matchProject(for: window)
        }
    }

    // MARK: - Accessibility

    func checkAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Window Polling

    private func pollWindows() {
        guard let windowInfoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return }

        var currentIDs = Set<CGWindowID>()

        for info in windowInfoList {
            guard let windowID = info[kCGWindowNumber as String] as? CGWindowID,
                  let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  let ownerName = info[kCGWindowOwnerName as String] as? String,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0 // Normal window layer only
            else { continue }

            // Skip our own overlay windows and tiny windows
            if ownerName == "DevSpace" { continue }

            let bounds = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )

            // Skip very small windows (tooltips, popups)
            if bounds.width < 100 || bounds.height < 100 { continue }

            let title = info[kCGWindowName as String] as? String ?? ""
            currentIDs.insert(windowID)

            if let existing = trackedWindows[windowID] {
                // Update mutable fields
                existing.title = title
                existing.bounds = bounds
                // Re-evaluate project assignment if title changed
                if existing.projectID == nil {
                    existing.projectID = matchProject(for: existing)
                }
            } else {
                // New window
                let window = TrackedWindow(
                    windowID: windowID,
                    ownerPID: ownerPID,
                    appName: ownerName,
                    title: title,
                    bounds: bounds,
                    windowRole: TrackedWindow.classifyApp(ownerName)
                )
                window.projectID = matchProject(for: window)
                trackedWindows[windowID] = window

                // Set up AX observer for move/resize
                setupAXObserver(for: window)
            }
        }

        // Remove windows that no longer exist
        let staleIDs = Set(trackedWindows.keys).subtracting(currentIDs)
        for id in staleIDs {
            if let window = trackedWindows.removeValue(forKey: id) {
                // window removed
            }
        }

        delegate?.windowTracker(self, didUpdateWindows: Array(trackedWindows.values))
    }

    // MARK: - Project Matching

    private func matchProject(for window: TrackedWindow) -> String? {
        for project in projects {
            switch window.windowRole {
            case .editor:
                // Editor titles typically contain the project directory name
                // e.g., "main.rs - project-a - Cursor"
                if window.title.localizedCaseInsensitiveContains(project.directoryName) {
                    return project.id
                }

            case .browser:
                // Browser titles often include the URL
                // e.g., "My App - project-a.localhost"
                if window.title.localizedCaseInsensitiveContains(project.hostname) {
                    return project.id
                }
                // Also try reading URL via accessibility API
                if let url = getBrowserURL(for: window),
                   url.contains(project.hostname) {
                    return project.id
                }

            case .terminal:
                // Check working directory of the shell process
                if let cwd = getProcessCwd(pid: window.ownerPID),
                   cwd.hasPrefix(project.directory) {
                    return project.id
                }
                // Fallback: check title
                if window.title.localizedCaseInsensitiveContains(project.directoryName) {
                    return project.id
                }

            case .agent, .other:
                // Generic title matching
                if window.title.localizedCaseInsensitiveContains(project.directoryName) {
                    return project.id
                }
            }
        }
        return nil
    }

    // MARK: - Process Inspection

    private func getProcessCwd(pid: pid_t) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            // lsof -Fn outputs lines like "n/path/to/cwd"
            for line in output.components(separatedBy: "\n") {
                if line.hasPrefix("n/") {
                    return String(line.dropFirst(1))
                }
            }
        } catch {
            logger.debug("Failed to get cwd for PID \(pid): \(error)")
        }
        return nil
    }

    private func getBrowserURL(for window: TrackedWindow) -> String? {
        let appElement = AXUIElementCreateApplication(window.ownerPID)

        // Try to get the focused window's URL field
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success else {
            return nil
        }

        let windowElement = windowRef as! AXUIElement

        // Search the window's AX tree for a text field containing a URL
        if let url = findURLField(in: windowElement) {
            return url
        }

        return nil
    }

    private func findURLField(in element: AXUIElement, depth: Int = 0) -> String? {
        // Limit recursion depth to avoid performance issues
        guard depth < 8 else { return nil }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return nil
        }

        for child in children {
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef)
            let role = roleRef as? String

            // Chrome/Arc use AXTextField or AXComboBox for the URL bar
            if role == "AXTextField" || role == "AXComboBox" {
                var valueRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(child, kAXValueAttribute as CFString, &valueRef) == .success,
                   let value = valueRef as? String,
                   value.contains(".localhost") || value.contains("://") {
                    return value
                }
            }

            // Recurse into children
            if let url = findURLField(in: child, depth: depth + 1) {
                return url
            }
        }
        return nil
    }

    // MARK: - AXObserver (Window Move/Resize Tracking)

    private func setupAXObserver(for window: TrackedWindow) {
        let pid = window.ownerPID

        // Only create one observer per PID
        guard axObservers[pid] == nil else { return }

        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon = refcon else { return }
            let tracker = Unmanaged<WindowTracker>.fromOpaque(refcon).takeUnretainedValue()
            tracker.handleAXNotification(element: element, notification: notification as String)
        }

        guard AXObserverCreate(pid, callback, &observer) == .success,
              let observer = observer else { return }

        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        AXObserverAddNotification(observer, appElement, kAXMovedNotification as CFString, refcon)
        AXObserverAddNotification(observer, appElement, kAXResizedNotification as CFString, refcon)
        AXObserverAddNotification(observer, appElement, kAXFocusedWindowChangedNotification as CFString, refcon)

        CFRunLoopAddSource(
            CFRunLoopGetCurrent(),
            AXObserverGetRunLoopSource(observer),
            .defaultMode
        )

        axObservers[pid] = observer
    }

    private func handleAXNotification(element: AXUIElement, notification: String) {
        // Find the tracked window by matching the AX element
        // For move/resize, update bounds and reposition border overlay
        DispatchQueue.main.async { [weak self] in
            self?.pollWindows()
        }
    }

    // MARK: - Notification Handlers

    @objc private func appDidActivate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let pid = Optional(app.processIdentifier) else { return }

        // Find the focused window for this app and notify delegate
        for (_, window) in trackedWindows where window.ownerPID == pid {
            window.lastFocusedAt = Date()
            delegate?.windowTracker(self, windowFocused: window)
            break
        }
    }

    @objc private func appDidTerminate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let pid = app.processIdentifier

        // Clean up AX observer
        if let observer = axObservers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(
                CFRunLoopGetCurrent(),
                AXObserverGetRunLoopSource(observer),
                .defaultMode
            )
        }

        // Remove windows for this PID
        let staleIDs = trackedWindows.filter { $0.value.ownerPID == pid }.map(\.key)
        for id in staleIDs {
            if let window = trackedWindows.removeValue(forKey: id) {
                // window removed
            }
        }
    }

    // MARK: - Public Queries

    func windows(for projectID: String) -> [TrackedWindow] {
        trackedWindows.values.filter { $0.projectID == projectID }
    }

    func claimWindow(_ windowID: CGWindowID, forProject projectID: String) {
        trackedWindows[windowID]?.projectID = projectID
    }
}
