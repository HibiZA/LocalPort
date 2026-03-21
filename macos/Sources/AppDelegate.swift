import AppKit
import os.log

private let logger = Logger(subsystem: "com.devspace.app", category: "AppDelegate")

final class AppDelegate: NSObject, NSApplicationDelegate {

    // Subsystems
    let menuBarController = MenuBarController()
    let daemonClient = DaemonClient()

    // State
    private var projects: [Project] = []
    private var projectRoutes: [String: String] = [:]  // projectID -> upstream
    private var daemonProcess: Process?
    private var daemonPollTimer: Timer?

    // Default color palette
    private let colorPalette = [
        "#3B82F6", "#10B981", "#F59E0B", "#EF4444", "#8B5CF6", "#EC4899",
    ]

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("DevSpace starting up")

        // Hide dock icon — we're a menu bar app
        NSApp.setActivationPolicy(.accessory)

        // Set up menu bar
        menuBarController.delegate = self
        menuBarController.setup()

        // Start
        // Load saved projects
        loadProjects()

        if !projects.isEmpty {
            updateMenuBar()
        }

        // Connect to daemon
        connectToDaemon()

        // Poll daemon for route status every 3 seconds
        daemonPollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refreshProjectsFromDaemon()
        }

        logger.info("DevSpace ready")
    }

    func applicationWillTerminate(_ notification: Notification) {
        saveProjects()
        daemonPollTimer?.invalidate()
        daemonClient.disconnect()
        stopBundledDaemon()
    }

    // MARK: - Daemon Connection

    private func connectToDaemon() {
        startBundledDaemon()

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
        let bundlePath = Bundle.main.bundlePath
        let helperPath = bundlePath + "/Contents/Helpers/devspaced"

        guard FileManager.default.fileExists(atPath: helperPath) else {
            logger.info("No bundled daemon found at \(helperPath), expecting external daemon")
            return
        }

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
        process.interrupt()
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
        var newRoutes: [String: String] = [:]

        for route in routes {
            guard let hostname = route["hostname"] as? String else { continue }
            let projectName = hostname.components(separatedBy: ".").first ?? hostname
            let upstream = route["upstream"] as? String ?? ""

            newRoutes[projectName] = upstream

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

        projectRoutes = newRoutes
        updateMenuBar()
    }

    // MARK: - Project Management

    func addProject(directory: String) {
        if let existing = projects.first(where: { $0.directory == directory }) {
            logger.info("Project \(existing.name) already exists")
            return
        }

        let dirName = (directory as NSString).lastPathComponent
        let colorIndex = projects.count % colorPalette.count

        var project = Project(
            id: dirName,
            name: dirName,
            directory: directory,
            hostname: "\(dirName).test",
            color: NSColorWrapper(hex: colorPalette[colorIndex])
        )

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
        updateMenuBar()
        saveProjects()
    }

    func updateProject(_ projectID: String, settings: ProjectSettings) {
        guard let idx = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[idx].name = settings.name
        projects[idx].color = NSColorWrapper(hex: settings.color)
        projects[idx].hostname = settings.hostname

        saveProjects()
        updateMenuBar()
        logger.info("Updated project settings for \(projectID)")
    }

    func removeProject(_ projectID: String) {
        projects.removeAll { $0.id == projectID }
        saveProjects()
        updateMenuBar()
        logger.info("Removed project \(projectID)")
    }

    // MARK: - Project Persistence

    private static let projectsKey = "savedProjects"

    private func saveProjects() {
        do {
            let data = try JSONEncoder().encode(projects)
            UserDefaults.standard.set(data, forKey: Self.projectsKey)
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

    // MARK: - Menu Bar

    private func updateMenuBar() {
        menuBarController.update(
            projects: projects,
            activeProjectID: nil,
            windowCounts: [:],
            routes: projectRoutes
        )
    }
}

// MARK: - MenuBarControllerDelegate

extension AppDelegate: MenuBarControllerDelegate {
    func menuBarDidSelectProject(_ projectID: String) {
        // Open the project's URL in the default browser
        if let project = projects.first(where: { $0.id == projectID }) {
            let scheme = project.hostname.hasSuffix(".localhost") ? "http" : "https"
            if let url = URL(string: "\(scheme)://\(project.hostname)") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func menuBarDidRequestProjectSettings(_ projectID: String) {
        guard let project = projects.first(where: { $0.id == projectID }) else { return }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let panel = ProjectSettingsPanel(project: project)
        objc_setAssociatedObject(self, "projectSettings", panel, .OBJC_ASSOCIATION_RETAIN)

        panel.onSave = { [weak self] settings in
            objc_setAssociatedObject(self as Any, "projectSettings", nil, .OBJC_ASSOCIATION_RETAIN)
            NSApp.setActivationPolicy(.accessory)
            self?.updateProject(projectID, settings: settings)
        }

        panel.onRemove = { [weak self] removedID in
            objc_setAssociatedObject(self as Any, "projectSettings", nil, .OBJC_ASSOCIATION_RETAIN)
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
            NSApp.setActivationPolicy(.accessory)
            guard response == .OK, let url = panel.url else { return }
            self?.addProject(directory: url.path)
        }
    }

    func menuBarDidRequestPreferences() {
        let prefsController = PreferencesWindowController.shared
        prefsController.showWindow()
    }

    func menuBarDidRequestQuit() {
        NSApp.terminate(nil)
    }
}
