import AppKit
import UserNotifications
import os.log

private let logger = Logger(subsystem: "com.devspace.app", category: "AppDelegate")

final class AppDelegate: NSObject, NSApplicationDelegate {

    // Subsystems
    let windowTracker = WindowTracker()
    let layoutManager = LayoutManager()
    let projectSwitcher = ProjectSwitcher()
    let menuBarController = MenuBarController()
    let daemonClient = DaemonClient()
    let projectLauncher = ProjectLauncher()
    let spaceManager = SpaceManager()
    let switchHUD = SwitchHUD()

    // State
    private var projects: [Project] = []
    private var screenBorder: ScreenBorderWindow?
    private var borderUpdateTimer: Timer?

    // Track launched PIDs so we can force-associate windows with projects
    private var launchedPIDs: [String: Set<pid_t>] = [:] // projectID -> PIDs

    // Pre-computed target frames for each window role per project
    private var launchedFrames: [String: [WindowRole: CGRect]] = [:] // projectID -> role -> frame

    // Default color palette
    private let colorPalette = [
        "#3B82F6", "#10B981", "#F59E0B", "#EF4444", "#8B5CF6", "#EC4899",
    ]

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("DevSpace starting up")

        // Hide dock icon — we're a menu bar app
        NSApp.setActivationPolicy(.accessory)

        // Set up menu bar first (always visible)
        menuBarController.delegate = self
        menuBarController.setup()

        // Check if onboarding is needed
        if !UserAppPreferences.shared.isOnboardingComplete {
            showOnboarding()
        } else {
            startSubsystems()
        }
    }

    private func showOnboarding() {
        let onboarding = OnboardingWindowController()
        // Store reference to prevent dealloc
        objc_setAssociatedObject(self, "onboarding", onboarding, .OBJC_ASSOCIATION_RETAIN)

        onboarding.onComplete = { [weak self] in
            objc_setAssociatedObject(self, "onboarding", nil, .OBJC_ASSOCIATION_RETAIN)
            self?.startSubsystems()
        }
        onboarding.show()
    }

    private func startSubsystems() {
        // Load saved projects
        loadProjects()

        // Set up window tracker
        windowTracker.delegate = self

        // Set up project switcher
        projectSwitcher.delegate = self

        // Sync loaded projects into subsystems (but don't activate or show borders yet)
        if !projects.isEmpty {
            // Clear any persisted isActive flags — user must explicitly switch
            for i in projects.indices {
                projects[i].isActive = false
            }
            projectSwitcher.updateProjects(projects)
            windowTracker.updateProjects(projects)
            updateMenuBar()
        }

        // Connect to daemon
        connectToDaemon()

        // Listen for daemon events
        daemonClient.onEvent = { [weak self] method, params in
            self?.handleDaemonEvent(method: method, params: params)
        }

        // Start window tracking and hotkeys
        windowTracker.start()
        projectSwitcher.start()

        // Periodic border position updates (in case AX observers miss something)
        borderUpdateTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.updateBorderPositions()
        }
        RunLoop.current.add(borderUpdateTimer!, forMode: .common)

        logger.info("DevSpace ready")
    }

    func applicationWillTerminate(_ notification: Notification) {
        saveProjects()
        spaceManager.shutdown()
        windowTracker.stop()
        projectSwitcher.stop()
        borderUpdateTimer?.invalidate()
        daemonClient.disconnect()
        removeAllBorders()
    }

    // MARK: - Daemon Connection

    private func connectToDaemon() {
        do {
            try daemonClient.connect()
            refreshProjectsFromDaemon()
        } catch {
            logger.warning("Could not connect to daemon: \(error). Running in standalone mode.")
        }
    }

    private func refreshProjectsFromDaemon() {
        guard daemonClient.isConnected else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let routes = try self.daemonClient.getProxyStatus()
                DispatchQueue.main.async {
                    self.syncProjectsFromRoutes(routes)
                }
            } catch {
                logger.error("Failed to get proxy status: \(error)")
            }
        }
    }

    private func syncProjectsFromRoutes(_ routes: [[String: Any]]) {
        for route in routes {
            guard let hostname = route["hostname"] as? String else { continue }
            let projectName = hostname.replacingOccurrences(of: ".localhost", with: "")

            if !projects.contains(where: { $0.id == projectName }) {
                let colorIndex = projects.count % colorPalette.count
                let project = Project(
                    id: projectName,
                    name: projectName,
                    directory: "",
                    hostname: hostname,
                    color: NSColorWrapper(hex: colorPalette[colorIndex])
                )
                projects.append(project)
            }
        }

        if !projects.isEmpty && !projects.contains(where: { $0.isActive }) {
            projects[0].isActive = true
        }

        projectSwitcher.updateProjects(projects)
        windowTracker.updateProjects(projects)
        updateMenuBar()
    }

    // MARK: - Daemon Events

    private func handleDaemonEvent(method: String, params: [String: Any]) {
        switch method {
        case "process.exited":
            guard let projectID = params["project_id"] as? String,
                  let code = params["code"] as? Int else { return }

            if projectSwitcher.activeProject?.id != projectID {
                menuBarController.addNotification(for: projectID)
                sendSystemNotification(
                    title: "[\(projectID)] Process exited",
                    body: "Process exited with code \(code)"
                )
            }

        case "port.detected":
            refreshProjectsFromDaemon()

        default:
            logger.debug("Unhandled daemon event: \(method)")
        }
    }

    // MARK: - Project Management

    func addProject(directory: String, layoutPreset: LayoutPreset = .codeFocus) {
        // If this project directory is already registered, just launch/switch to it
        if let existing = projects.first(where: { $0.directory == directory }) {
            logger.info("Project \(existing.name) already exists, launching")
            launchProject(existing)
            projectSwitcher.switchTo(projectID: existing.id)
            return
        }

        let detector = ProjectDetector()
        let info = detector.detect(directory: directory)

        let name = info.name
        let colorIndex = projects.count % colorPalette.count

        var project = Project(
            id: name,
            name: name,
            directory: directory,
            hostname: "\(name).localhost",
            color: NSColorWrapper(hex: colorPalette[colorIndex]),
            layoutPreset: layoutPreset
        )

        // Register with daemon if connected
        if daemonClient.isConnected {
            do {
                let result = try daemonClient.registerProject(directory: directory)
                if let hostname = result["hostname"] as? String {
                    project.hostname = hostname
                }
            } catch {
                logger.error("Failed to register project: \(error)")
            }
        }

        projects.append(project)

        if projects.count == 1 {
            projects[0].isActive = true
        }

        projectSwitcher.updateProjects(projects)
        windowTracker.updateProjects(projects)
        updateMenuBar()
        saveProjects()

        // Launch the project: open IDE, start dev server, open browser
        launchProject(project)
    }

    func updateProject(_ projectID: String, settings: ProjectSettings) {
        guard let idx = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[idx].name = settings.name
        projects[idx].color = NSColorWrapper(hex: settings.color)
        projects[idx].hostname = settings.hostname
        projects[idx].layoutPreset = settings.layoutPreset

        saveProjects()
        updateMenuBar()
        updateBorders()

        // Re-tile if layout changed
        let windows = windowTracker.windows(for: projectID)
        if !windows.isEmpty {
            layoutManager.autoTile(windows: windows, preset: settings.layoutPreset)
        }

        logger.info("Updated project settings for \(projectID)")
    }

    func removeProject(_ projectID: String) {
        projects.removeAll { $0.id == projectID }
        launchedPIDs.removeValue(forKey: projectID)
        launchedFrames.removeValue(forKey: projectID)

        projectSwitcher.updateProjects(projects)
        windowTracker.updateProjects(projects)
        saveProjects()
        updateMenuBar()
        updateBorders()

        logger.info("Removed project \(projectID)")
    }

    // MARK: - Project Persistence

    private static let projectsKey = "savedProjects"

    private func saveProjects() {
        do {
            let data = try JSONEncoder().encode(projects)
            UserDefaults.standard.set(data, forKey: Self.projectsKey)
            logger.info("Saved \(self.projects.count) project(s)")
        } catch {
            logger.error("Failed to save projects: \(error)")
        }
    }

    private func loadProjects() {
        guard let data = UserDefaults.standard.data(forKey: Self.projectsKey) else { return }
        do {
            projects = try JSONDecoder().decode([Project].self, from: data)
            logger.info("Loaded \(self.projects.count) project(s)")
        } catch {
            logger.error("Failed to load projects: \(error)")
        }
    }

    private func launchProject(_ project: Project) {
        // Pre-compute target frames BEFORE launching apps
        let preset = project.layoutPreset ?? .codeFocus
        let frames = layoutManager.computeFrames(preset: preset)
        launchedFrames[project.id] = frames
        logger.info("Pre-computed \(frames.count) frame(s) for \(project.id, privacy: .public) preset: \(preset.rawValue, privacy: .public)")

        // Create a new desktop Space for this project
        let spaceID = spaceManager.createSpaceForProject(project.id)
        spaceManager.switchToSpace(spaceID)

        // Minimize all non-DevSpace windows to clear the desktop for the new project
        spaceManager.minimizeNonProjectWindows()

        projectLauncher.launch(directory: project.directory) { [weak self] launched in
            guard let self = self else { return }

            // Track all PIDs from the launch so WindowTracker can associate them
            var pids = Set<pid_t>()
            if let pid = launched.idePID { pids.insert(pid) }
            if let pid = launched.terminalPID { pids.insert(pid) }
            if let pid = launched.browserPID { pids.insert(pid) }

            // Also add ALL PIDs for each app's bundle ID — some apps (e.g. Ghostty)
            // have multiple processes, and CGWindowList may report a different PID
            // than NSWorkspace.runningApplications.first
            let prefs = UserAppPreferences.shared
            for bundleID in [prefs.preferredIDE?.id, prefs.preferredTerminal?.id, prefs.preferredBrowser?.id].compactMap({ $0 }) {
                for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == bundleID {
                    pids.insert(app.processIdentifier)
                }
            }

            self.launchedPIDs[project.id] = pids

            // Force-claim windows and tile them — two passes to catch late-arriving windows
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.claimWindowsForLaunchedPIDs(projectID: project.id)
            }
            // Second pass for apps that take longer to create windows
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                self.claimWindowsForLaunchedPIDs(projectID: project.id)
            }

            logger.info("Project \(project.name, privacy: .public) launched — PIDs: \(pids.map { Int($0) }, privacy: .public)")
        }
    }

    /// After launching apps for a project, claim their windows and position them immediately
    private func claimWindowsForLaunchedPIDs(projectID: String) {
        guard let pids = launchedPIDs[projectID] else { return }
        let frames = launchedFrames[projectID] ?? [:]

        logger.info("Claiming windows for \(projectID, privacy: .public) — PIDs: \(pids.map { Int($0) }, privacy: .public), frames: \(frames.count)")
        logger.info("WindowTracker has \(self.windowTracker.trackedWindows.count) tracked window(s)")

        var claimedWindowIDs: [CGWindowID] = []

        for (windowID, window) in windowTracker.trackedWindows {
            let pidMatch = pids.contains(window.ownerPID)
            let projNil = window.projectID == nil
            logger.info("  Window \(windowID): \(window.appName, privacy: .public) (PID \(window.ownerPID), role: \(window.windowRole.rawValue, privacy: .public), project: \(window.projectID ?? "none", privacy: .public), pidMatch: \(pidMatch), projNil: \(projNil))")
            if pidMatch && projNil {
                windowTracker.claimWindow(windowID, forProject: projectID)
                claimedWindowIDs.append(windowID)

                // Position immediately using pre-computed frame for this role
                if let frame = frames[window.windowRole] {
                    layoutManager.moveWindow(window, to: frame)
                    logger.info("  → Claimed + positioned \(window.appName, privacy: .public) as \(window.windowRole.rawValue, privacy: .public)")
                } else {
                    logger.info("  → Claimed \(window.appName, privacy: .public) (no frame for role \(window.windowRole.rawValue, privacy: .public))")
                }
            }
        }

        // Move claimed windows to the project's Space
        if !claimedWindowIDs.isEmpty {
            spaceManager.moveWindowsToProjectSpace(windowIDs: claimedWindowIDs, projectID: projectID)
            projectSwitcher.switchTo(projectID: projectID)
        }

        updateBorders()
        updateMenuBar()
    }

    // MARK: - Border Management

    private func updateBorders() {
        guard let activeProject = projectSwitcher.activeProject else {
            removeAllBorders()
            return
        }

        let color = activeProject.color.nsColor

        if let existing = screenBorder {
            existing.updateColor(color)
            existing.updateFrame()
        } else {
            let border = ScreenBorderWindow(color: color)
            border.animateIn()
            screenBorder = border
        }
    }

    private func updateBorderPositions() {
        screenBorder?.updateFrame()
    }

    private func removeAllBorders() {
        screenBorder?.animateOut { [weak self] in
            self?.screenBorder?.close()
            self?.screenBorder = nil
        }
    }

    // MARK: - Menu Bar

    private func updateMenuBar() {
        var windowCounts: [String: Int] = [:]
        for project in projects {
            windowCounts[project.id] = windowTracker.windows(for: project.id).count
        }
        menuBarController.update(
            projects: projects,
            activeProjectID: projectSwitcher.activeProject?.id,
            windowCounts: windowCounts
        )
    }

    // MARK: - Notifications

    private func sendSystemNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - WindowTrackerDelegate

extension AppDelegate: WindowTrackerDelegate {
    func windowTracker(_ tracker: WindowTracker, didUpdateWindows windows: [TrackedWindow]) {
        // Claim and immediately position any new windows matching launched PIDs
        var newlyClaimed: [String: [CGWindowID]] = [:] // projectID -> windowIDs
        for (projectID, pids) in launchedPIDs {
            let frames = launchedFrames[projectID] ?? [:]
            for window in windows {
                if pids.contains(window.ownerPID) && window.projectID == nil {
                    tracker.claimWindow(window.windowID, forProject: projectID)
                    newlyClaimed[projectID, default: []].append(window.windowID)
                    // Position immediately using pre-computed frame
                    if let frame = frames[window.windowRole] {
                        layoutManager.moveWindow(window, to: frame)
                    }
                }
            }
        }

        // Register newly claimed windows with SpaceManager
        for (projectID, windowIDs) in newlyClaimed {
            spaceManager.moveWindowsToProjectSpace(windowIDs: windowIDs, projectID: projectID)
        }

        updateBorders()
        updateMenuBar()
    }

    func windowTracker(_ tracker: WindowTracker, windowFocused window: TrackedWindow) {
        if let projectID = window.projectID,
           projectID != projectSwitcher.activeProject?.id {
            projectSwitcher.switchTo(projectID: projectID)
        }
    }
}

// MARK: - ProjectSwitcherDelegate

extension AppDelegate: ProjectSwitcherDelegate {
    func projectSwitcher(_ switcher: ProjectSwitcher, didSwitchTo project: Project) {
        logger.info("Switching to project: \(project.name)")

        for i in projects.indices {
            projects[i].isActive = (projects[i].id == project.id)
        }

        menuBarController.clearNotifications(for: project.id)

        // Show HUD with project name
        switchHUD.show(projectName: project.name, color: project.color.nsColor)

        // Switch to the project's desktop Space (if it has one)
        spaceManager.switchToProjectSpace(project.id)

        let windows = windowTracker.windows(for: project.id)

        layoutManager.restoreLayout(for: project, windows: windows)

        for window in windows.sorted(by: { $0.lastFocusedAt < $1.lastFocusedAt }) {
            layoutManager.bringToFront(window)
        }

        if let lastActive = windows.max(by: { $0.lastFocusedAt < $1.lastFocusedAt }) {
            layoutManager.focusWindow(lastActive)
        }

        updateBorders()
        updateMenuBar()
    }
}

// MARK: - MenuBarControllerDelegate

extension AppDelegate: MenuBarControllerDelegate {
    func menuBarDidSelectProject(_ projectID: String) {
        // If the project has no tracked windows, re-launch it
        let windows = windowTracker.windows(for: projectID)
        if windows.isEmpty, let project = projects.first(where: { $0.id == projectID }) {
            launchProject(project)
        }
        projectSwitcher.switchTo(projectID: projectID)
    }

    func menuBarDidRequestProjectSettings(_ projectID: String) {
        guard let project = projects.first(where: { $0.id == projectID }) else { return }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let panel = ProjectSettingsPanel(project: project)
        objc_setAssociatedObject(self, "projectSettings", panel, .OBJC_ASSOCIATION_RETAIN)

        panel.onSave = { [weak self] settings in
            objc_setAssociatedObject(self, "projectSettings", nil, .OBJC_ASSOCIATION_RETAIN)
            NSApp.setActivationPolicy(.accessory)
            self?.updateProject(projectID, settings: settings)
        }

        panel.onRemove = { [weak self] removedID in
            objc_setAssociatedObject(self, "projectSettings", nil, .OBJC_ASSOCIATION_RETAIN)
            NSApp.setActivationPolicy(.accessory)
            self?.removeProject(removedID)
        }

        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    func menuBarDidRequestAddProject() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a project directory"
        panel.prompt = "Add Project"

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else {
                NSApp.setActivationPolicy(.accessory)
                return
            }

            let directory = url.path

            // Show layout picker before adding the project
            let picker = LayoutPickerPanel()
            // Keep a strong ref so the panel isn't deallocated
            objc_setAssociatedObject(self, "layoutPicker", picker, .OBJC_ASSOCIATION_RETAIN)

            picker.onSelect = { [weak self] preset in
                objc_setAssociatedObject(self, "layoutPicker", nil, .OBJC_ASSOCIATION_RETAIN)
                NSApp.setActivationPolicy(.accessory)
                self?.addProject(directory: directory, layoutPreset: preset)
            }

            picker.center()
            picker.makeKeyAndOrderFront(nil)
        }
    }

    func menuBarDidRequestPreferences() {
        let prefsController = PreferencesWindowController.shared
        prefsController.onPreferencesChanged = { [weak self] in
            self?.updateBorders()
        }
        prefsController.showWindow()
    }

    func menuBarDidRequestQuit() {
        NSApp.terminate(nil)
    }
}
