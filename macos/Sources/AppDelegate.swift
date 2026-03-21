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
    let spaceManager = SpaceManager()
    let switchHUD = SwitchHUD()

    // State
    private var projects: [Project] = []
    private var screenBorder: ScreenBorderWindow?
    private var borderUpdateTimer: Timer?
    private var daemonProcess: Process?

    // Default color palette
    private let colorPalette = [
        "#3B82F6", "#10B981", "#F59E0B", "#EF4444", "#8B5CF6", "#EC4899",
    ]

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("DevSpace starting up")

        // Hide dock icon — we're a menu bar app
        NSApp.setActivationPolicy(.accessory)

        // Request notification permissions (requires a valid app bundle)
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error = error {
                    logger.error("Notification auth error: \(error)")
                }
                logger.info("Notification permission granted: \(granted)")
            }
        }

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
        stopBundledDaemon()
        removeAllBorders()
    }

    // MARK: - Daemon Connection

    private func connectToDaemon() {
        // Start bundled daemon if not already running
        startBundledDaemon()

        // Give daemon a moment to start, then connect
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            do {
                try self?.daemonClient.connect()
                self?.refreshProjectsFromDaemon()
            } catch {
                logger.warning("Could not connect to daemon: \(error). Running in standalone mode.")
            }
        }
    }

    private func startBundledDaemon() {
        // Look for devspaced in the app bundle's Helpers directory
        let bundlePath = Bundle.main.bundlePath
        let helperPath = bundlePath + "/Contents/Helpers/devspaced"

        guard FileManager.default.fileExists(atPath: helperPath) else {
            logger.info("No bundled daemon found at \(helperPath), expecting external daemon")
            return
        }

        // Check if daemon is already running (socket exists)
        let uid = getuid()
        let socketPath = "/tmp/devspace-\(uid).sock"
        if FileManager.default.fileExists(atPath: socketPath) {
            logger.info("Daemon socket already exists, skipping launch")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: helperPath)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            daemonProcess = process
            logger.info("Started bundled daemon (PID \(process.processIdentifier))")
        } catch {
            logger.error("Failed to start bundled daemon: \(error)")
        }
    }

    private func stopBundledDaemon() {
        guard let process = daemonProcess, process.isRunning else { return }
        process.interrupt() // SIGINT
        logger.info("Sent interrupt to bundled daemon (PID \(process.processIdentifier))")
        daemonProcess = nil
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
            let projectName = hostname.components(separatedBy: ".").first ?? hostname

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
        case "port.detected":
            refreshProjectsFromDaemon()

        default:
            logger.debug("Unhandled daemon event: \(method)")
        }
    }

    // MARK: - Project Management

    func addProject(directory: String, layoutPreset: LayoutPreset = .codeFocus) {
        // If this project directory is already registered, just switch to it
        if let existing = projects.first(where: { $0.directory == directory }) {
            logger.info("Project \(existing.name) already exists, switching")
            projectSwitcher.switchTo(projectID: existing.id)
            return
        }

        let dirName = (directory as NSString).lastPathComponent
        let colorIndex = projects.count % colorPalette.count

        var project = Project(
            id: dirName,
            name: dirName,
            directory: directory,
            hostname: "\(dirName).test",
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
            existing.refreshFromPreferences()
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
