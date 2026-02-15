import AppKit
import os.log

private let logger = Logger(subsystem: "com.devspace.app", category: "SpaceManager")

/// The off-screen X coordinate used to "hide" windows
private let offScreenX: CGFloat = -30000

/// Key used to persist off-screen window state for crash recovery
private let savedStateKey = "SpaceManagerSavedState"

/// Key used to persist minimized window IDs for crash recovery
private let minimizedStateKey = "SpaceManagerMinimizedState"

/// Virtual workspace manager that isolates project windows by moving inactive
/// windows off-screen and restoring them when switching back.
///
/// This is the same technique used by AeroSpace — no SIP or private APIs needed.
/// When switching projects:
///   1. Save current positions of the active project's windows
///   2. Move them off-screen (x: -30000)
///   3. Restore the target project's windows to their saved positions
///   4. Raise them to the front
///
/// Edge cases handled:
///   - Crash recovery: persists off-screen state to disk, restores on next launch
///   - Stale windows: periodically pruned when windows no longer exist
///   - Signal handling: SIGTERM/SIGINT restore windows before exit
final class SpaceManager {
    /// Tracks which window IDs belong to each project
    private var projectWindows: [String: Set<CGWindowID>] = [:]

    /// Saved on-screen positions per project, keyed by window ID
    private var savedPositions: [String: [CGWindowID: CGPoint]] = [:]

    /// The currently visible project (nil = no project active, all windows visible)
    private(set) var activeProjectID: String?

    /// Window IDs that we minimized (non-project windows) so we can restore them on quit
    private var minimizedByUs: Set<CGWindowID> = []

    /// Previous signal handlers so we can chain them
    private var previousSIGTERM: sig_t?
    private var previousSIGINT: sig_t?

    init() {
        recoverFromCrash()
        installSignalHandlers()
    }

    // MARK: - Public API

    /// Register a project workspace
    func createSpaceForProject(_ projectID: String) -> UInt64 {
        if projectWindows[projectID] == nil {
            projectWindows[projectID] = []
            savedPositions[projectID] = [:]
        }
        logger.info("Registered virtual workspace for project \(projectID)")
        return 0
    }

    /// Track window IDs for a project
    func moveWindowsToProjectSpace(windowIDs: [CGWindowID], projectID: String) {
        var windowSet = projectWindows[projectID] ?? []
        for id in windowIDs {
            windowSet.insert(id)
        }
        projectWindows[projectID] = windowSet
        logger.info("Tracked \(windowIDs.count) window(s) for project \(projectID)")
    }

    /// Switch to a project's virtual workspace
    func switchToProjectSpace(_ projectID: String) {
        guard projectID != activeProjectID else { return }

        let previousProjectID = activeProjectID
        activeProjectID = projectID

        // 1. Save positions & move current project's windows off-screen
        if let prevID = previousProjectID, let windowIDs = projectWindows[prevID] {
            var positions: [CGWindowID: CGPoint] = [:]
            for windowID in windowIDs {
                if let (axWindow, pos) = findAXWindow(windowID) {
                    // Only save if the window is actually on-screen
                    if pos.x > offScreenX + 1000 {
                        positions[windowID] = pos
                    }
                    moveAXWindow(axWindow, to: CGPoint(x: offScreenX, y: pos.y))
                }
            }
            if !positions.isEmpty {
                savedPositions[prevID] = positions
            }
        }

        // 2. Restore target project's windows to saved positions & raise
        if let windowIDs = projectWindows[projectID] {
            let positions = savedPositions[projectID] ?? [:]
            for windowID in windowIDs {
                if let (axWindow, _) = findAXWindow(windowID) {
                    if let savedPos = positions[windowID] {
                        moveAXWindow(axWindow, to: savedPos)
                    } else {
                        // No saved position — cascade from top-left
                        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
                        moveAXWindow(axWindow, to: CGPoint(x: screen.origin.x + 50, y: screen.origin.y + 50))
                    }
                    AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
                }
            }

            // Activate the frontmost app of the target project
            activateFrontApp(for: windowIDs)
        }

        // Persist state in case of crash
        persistOffScreenState()

        // Clean up stale window IDs while we're at it
        pruneStaleWindows()

        let prev = previousProjectID ?? "none"
        logger.info("Switched workspace: \(prev) → \(projectID)")
    }

    /// Minimize all visible windows that don't belong to any DevSpace-tracked project.
    /// Called once when launching a new project to clear the desktop.
    func minimizeNonProjectWindows() {
        guard let allWindowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return
        }

        // Collect all window IDs tracked by DevSpace
        let trackedIDs = projectWindows.values.reduce(into: Set<CGWindowID>()) { $0.formUnion($1) }

        // PIDs to skip: DevSpace itself and any system UI processes
        let myPID = ProcessInfo.processInfo.processIdentifier

        var minimizedCount = 0
        for info in allWindowInfo {
            guard let windowID = info[kCGWindowNumber as String] as? CGWindowID,
                  let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = info[kCGWindowLayer as String] as? Int else {
                continue
            }

            // Only minimize normal windows (layer 0), skip menu bar, overlays, etc.
            guard layer == 0 else { continue }
            // Skip our own process
            guard ownerPID != myPID else { continue }
            // Skip windows already tracked by DevSpace
            guard !trackedIDs.contains(windowID) else { continue }

            // Find the AX element and minimize it
            let app = AXUIElementCreateApplication(ownerPID)
            var windowList: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowList) == .success,
                  let windows = windowList as? [AXUIElement] else {
                continue
            }

            for axWindow in windows {
                var axWindowID: CGWindowID = 0
                _ = _AXUIElementGetWindow(axWindow, &axWindowID)
                if axWindowID == windowID {
                    AXUIElementSetAttributeValue(axWindow, kAXMinimizedAttribute as CFString, true as CFTypeRef)
                    minimizedByUs.insert(windowID)
                    minimizedCount += 1
                    break
                }
            }
        }

        persistMinimizedState()
        logger.info("Minimized \(minimizedCount) non-project window(s)")
    }

    /// No-op compatibility shim
    func switchToSpace(_ spaceID: UInt64) {}

    /// Remove a project's virtual workspace, restoring its windows on-screen
    func removeProjectSpace(_ projectID: String) {
        if let windowIDs = projectWindows.removeValue(forKey: projectID) {
            let positions = savedPositions.removeValue(forKey: projectID) ?? [:]
            for windowID in windowIDs {
                if let (axWindow, _) = findAXWindow(windowID) {
                    if let pos = positions[windowID] {
                        moveAXWindow(axWindow, to: pos)
                    } else {
                        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
                        moveAXWindow(axWindow, to: CGPoint(x: screen.origin.x + 50, y: screen.origin.y + 50))
                    }
                }
            }
        }
        if activeProjectID == projectID {
            activeProjectID = nil
        }
        persistOffScreenState()
        logger.info("Removed virtual workspace for project \(projectID)")
    }

    /// Clean shutdown: optionally close project windows and restore minimized non-project windows
    func shutdown() {
        let closeWindows = UserAppPreferences.shared.closeWindowsOnQuit

        if closeWindows {
            // Close all project windows by pressing each window's close button
            var closedCount = 0
            for (_, windowIDs) in projectWindows {
                for windowID in windowIDs {
                    if let (axWindow, _) = findAXWindow(windowID) {
                        var closeButtonRef: CFTypeRef?
                        if AXUIElementCopyAttributeValue(axWindow, kAXCloseButtonAttribute as CFString, &closeButtonRef) == .success,
                           let closeButton = closeButtonRef {
                            AXUIElementPerformAction(closeButton as! AXUIElement, kAXPressAction as CFString)
                            closedCount += 1
                        }
                    }
                }
            }
            logger.info("Closed \(closedCount) project window(s)")
        } else {
            // Restore any off-screen project windows back to their saved positions
            showAllProjectWindows()
            logger.info("Restored project windows on-screen")
        }

        // Always restore windows we minimized back to normal
        restoreMinimizedWindows()

        activeProjectID = nil
        clearPersistedState()
        clearMinimizedState()
        logger.info("Shutdown complete")
    }

    /// Restore all project windows that are off-screen to their saved positions
    private func showAllProjectWindows() {
        for (projectID, windowIDs) in projectWindows {
            let positions = savedPositions[projectID] ?? [:]
            for windowID in windowIDs {
                if let (axWindow, currentPos) = findAXWindow(windowID) {
                    if currentPos.x < offScreenX + 1000 {
                        // Window is off-screen — restore it
                        let savedPos = positions[windowID] ?? CGPoint(x: 100, y: 100)
                        moveAXWindow(axWindow, to: savedPos)
                    }
                }
            }
        }
    }

    /// Restore all windows we previously minimized
    private func restoreMinimizedWindows() {
        var restoredCount = 0
        for windowID in minimizedByUs {
            if let (axWindow, _) = findAXWindow(windowID) {
                AXUIElementSetAttributeValue(axWindow, kAXMinimizedAttribute as CFString, false as CFTypeRef)
                restoredCount += 1
            }
        }
        minimizedByUs.removeAll()
        logger.info("Restored \(restoredCount) previously minimized window(s)")
    }

    // MARK: - Crash Recovery

    /// Persisted state structure for crash recovery
    private struct PersistedState: Codable {
        var offScreenWindows: [UInt32: PersistedPosition]  // windowID -> saved position
    }

    private struct PersistedPosition: Codable {
        let x: CGFloat
        let y: CGFloat
    }

    /// Save current off-screen state to UserDefaults so we can recover after a crash
    private func persistOffScreenState() {
        var offScreen: [UInt32: PersistedPosition] = [:]

        for (projectID, windowIDs) in projectWindows where projectID != activeProjectID {
            let positions = savedPositions[projectID] ?? [:]
            for windowID in windowIDs {
                if let pos = positions[windowID] {
                    offScreen[windowID] = PersistedPosition(x: pos.x, y: pos.y)
                }
            }
        }

        if offScreen.isEmpty {
            clearPersistedState()
            return
        }

        let state = PersistedState(offScreenWindows: offScreen)
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: savedStateKey)
        }
    }

    private func clearPersistedState() {
        UserDefaults.standard.removeObject(forKey: savedStateKey)
    }

    /// Save minimized window IDs to UserDefaults for crash recovery
    private func persistMinimizedState() {
        if minimizedByUs.isEmpty {
            clearMinimizedState()
            return
        }
        let ids = minimizedByUs.map { UInt32($0) }
        if let data = try? JSONEncoder().encode(ids) {
            UserDefaults.standard.set(data, forKey: minimizedStateKey)
        }
    }

    private func clearMinimizedState() {
        UserDefaults.standard.removeObject(forKey: minimizedStateKey)
    }

    /// On launch, check if there are windows stuck off-screen or minimized from a previous crash
    private func recoverFromCrash() {
        // Recover off-screen windows
        if let data = UserDefaults.standard.data(forKey: savedStateKey),
           let state = try? JSONDecoder().decode(PersistedState.self, from: data) {
            logger.warning("Found \(state.offScreenWindows.count) off-screen window(s) from previous session — recovering")

            for (windowID, savedPos) in state.offScreenWindows {
                if let (axWindow, currentPos) = findAXWindow(CGWindowID(windowID)) {
                    if currentPos.x < offScreenX + 1000 {
                        moveAXWindow(axWindow, to: CGPoint(x: savedPos.x, y: savedPos.y))
                        logger.info("Recovered window \(windowID) to (\(savedPos.x), \(savedPos.y))")
                    }
                }
            }
            clearPersistedState()
        }

        // Recover minimized windows
        if let data = UserDefaults.standard.data(forKey: minimizedStateKey),
           let ids = try? JSONDecoder().decode([UInt32].self, from: data) {
            logger.warning("Found \(ids.count) minimized window(s) from previous session — restoring")

            for id in ids {
                if let (axWindow, _) = findAXWindow(CGWindowID(id)) {
                    AXUIElementSetAttributeValue(axWindow, kAXMinimizedAttribute as CFString, false as CFTypeRef)
                    logger.info("Unminimized window \(id)")
                }
            }
            clearMinimizedState()
        }
    }

    // MARK: - Signal Handling

    /// Install signal handlers so we restore windows even on SIGTERM/SIGINT
    private func installSignalHandlers() {
        // Store reference to self for signal handler access
        SpaceManager.sharedInstance = self

        previousSIGTERM = signal(SIGTERM) { _ in
            SpaceManager.sharedInstance?.shutdown()
            signal(SIGTERM, SIG_DFL)
            raise(SIGTERM)
        }

        previousSIGINT = signal(SIGINT) { _ in
            SpaceManager.sharedInstance?.shutdown()
            signal(SIGINT, SIG_DFL)
            raise(SIGINT)
        }
    }

    /// Static reference for signal handler access (C callbacks can't capture context)
    private static var sharedInstance: SpaceManager?

    // MARK: - Stale Window Cleanup

    /// Remove window IDs that no longer exist (window was closed)
    private func pruneStaleWindows() {
        guard let allWindows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return }
        let liveIDs = Set(allWindows.compactMap { $0[kCGWindowNumber as String] as? CGWindowID })

        for (projectID, windowIDs) in projectWindows {
            let pruned = windowIDs.filter { liveIDs.contains($0) }
            if pruned.count != windowIDs.count {
                let removed = windowIDs.count - pruned.count
                projectWindows[projectID] = pruned
                // Also clean up saved positions for removed windows
                savedPositions[projectID] = savedPositions[projectID]?.filter { pruned.contains($0.key) }
                logger.debug("Pruned \(removed) stale window(s) from project \(projectID)")
            }
        }
    }

    // MARK: - AX Helpers

    /// Find the AXUIElement for a CGWindowID and return it with its current position
    private func findAXWindow(_ windowID: CGWindowID) -> (AXUIElement, CGPoint)? {
        guard let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return nil }

        guard let windowInfo = info.first(where: { ($0[kCGWindowNumber as String] as? CGWindowID) == windowID }),
              let pid = windowInfo[kCGWindowOwnerPID as String] as? pid_t else {
            return nil
        }

        let app = AXUIElementCreateApplication(pid)
        var windowList: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowList) == .success,
              let windows = windowList as? [AXUIElement] else {
            return nil
        }

        for axWindow in windows {
            var axWindowID: CGWindowID = 0
            _ = _AXUIElementGetWindow(axWindow, &axWindowID)
            if axWindowID == windowID {
                let pos = getWindowPosition(axWindow)
                return (axWindow, pos)
            }
        }
        return nil
    }

    /// Get the current position of an AX window
    private func getWindowPosition(_ axWindow: AXUIElement) -> CGPoint {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &value) == .success else {
            return .zero
        }
        var point = CGPoint.zero
        AXValueGetValue(value as! AXValue, .cgPoint, &point)
        return point
    }

    /// Move an AX window to a specific position
    private func moveAXWindow(_ axWindow: AXUIElement, to point: CGPoint) {
        var mutablePoint = point
        guard let value = AXValueCreate(.cgPoint, &mutablePoint) else { return }
        AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, value)
    }

    /// Activate the app that owns the first tracked window in a set
    private func activateFrontApp(for windowIDs: Set<CGWindowID>) {
        guard let firstID = windowIDs.first,
              let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]],
              let windowInfo = info.first(where: { ($0[kCGWindowNumber as String] as? CGWindowID) == firstID }),
              let pid = windowInfo[kCGWindowOwnerPID as String] as? pid_t else {
            return
        }

        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid }) {
            app.activate()
        }
    }
}

// Private C function to get CGWindowID from AXUIElement
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError
