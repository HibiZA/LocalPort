import AppKit
import os.log

private let logger = Logger(subsystem: "com.localport.app", category: "AppDelegate")

final class AppDelegate: NSObject, NSApplicationDelegate {

    // Subsystems
    let menuBarController = MenuBarController()
    let daemonClient = DaemonClient()
    let updateChecker = UpdateChecker()

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
        logger.info("LocalPort starting up")

        // Hide dock icon — we're a menu bar app
        NSApp.setActivationPolicy(.accessory)

        // Set up menu bar
        menuBarController.delegate = self
        menuBarController.setup()

        // Listen for uninstall request from Preferences
        NotificationCenter.default.addObserver(
            forName: .localportUninstallRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.performUninstall()
        }

        // Load saved projects
        loadProjects()

        if !projects.isEmpty {
            updateMenuBar()
        }

        // Check for updates
        updateChecker.onUpdateAvailable = { [weak self] version in
            self?.menuBarController.showUpdateAvailable(version: version)
        }
        updateChecker.startChecking()

        // Connect to daemon
        connectToDaemon()

        // Poll daemon for route status every 3 seconds
        daemonPollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refreshProjectsFromDaemon()
        }

        // Run first-time setup in the background so the menu bar stays responsive
        if !UserDefaults.standard.bool(forKey: "setupComplete") {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.runFirstTimeSetup()
            }
        }

        logger.info("LocalPort ready")
    }

    func applicationWillTerminate(_ notification: Notification) {
        saveProjects()
        daemonPollTimer?.invalidate()
        updateChecker.stop()
        daemonClient.disconnect()
        stopBundledDaemon()
    }

    // MARK: - First-Time Setup

    private func runFirstTimeSetup() {
        let tld = UserDefaults.standard.string(forKey: PrefKey.tld) ?? "test"
        guard tld != "localhost" else {
            UserDefaults.standard.set(true, forKey: "setupComplete")
            return
        }

        // Sanitize TLD to prevent command injection (runs as root)
        let sanitizedTLD = tld.filter { $0.isLetter || $0.isNumber }
        guard !sanitizedTLD.isEmpty else {
            logger.error("Invalid TLD: \(tld)")
            return
        }

        // Check if setup was already done (e.g. by a previous install)
        if FileManager.default.fileExists(atPath: "/etc/resolver/\(sanitizedTLD)") {
            UserDefaults.standard.set(true, forKey: "setupComplete")
            logger.info("Setup already done, skipping")
            return
        }

        logger.info("Running first-time setup")

        // Find setup script — bundled or in source tree
        let setupPaths = [
            Bundle.main.bundlePath + "/Contents/Resources/setup.sh",
            "scripts/setup.sh",
            "../scripts/setup.sh",
        ]
        guard let setupScript = setupPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            logger.error("Setup script not found")
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = [
            "-e",
            "do shell script \"bash '\(setupScript)' '\(sanitizedTLD)'\" with administrator privileges",
        ]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            logger.error("Setup failed to launch: \(error)")
            return
        }

        guard task.terminationStatus == 0 else {
            logger.error("Setup script failed (exit \(task.terminationStatus))")
            // Don't mark complete — will retry next launch
            return
        }

        UserDefaults.standard.set(true, forKey: "setupComplete")
        logger.info("First-time setup complete")
    }

    // MARK: - Daemon Connection

    private func trustCaddyCA() {
        let caPath = NSHomeDirectory() + "/Library/Application Support/Caddy/pki/authorities/local/root.crt"
        guard FileManager.default.fileExists(atPath: caPath) else {
            return
        }

        // Check if already trusted in keychain
        let checkTask = Process()
        checkTask.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        checkTask.arguments = ["find-certificate", "-c", "Caddy Local Authority"]
        checkTask.standardOutput = FileHandle.nullDevice
        checkTask.standardError = FileHandle.nullDevice
        try? checkTask.run()
        checkTask.waitUntilExit()
        if checkTask.terminationStatus == 0 {
            return // Already trusted
        }

        // Add to system keychain and mark as trusted (requires admin)
        let script = "do shell script \"security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain '\(caPath)'\" with administrator privileges"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        if task.terminationStatus == 0 {
            logger.info("Caddy root CA trusted in system keychain")
        }
    }

    private func connectToDaemon() {
        startDaemon()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            do {
                try self.daemonClient.connect()
                self.updateMenuBar()
                self.registerSavedProjectsWithDaemon()
                self.refreshProjectsFromDaemon()
            } catch {
                logger.warning("Could not connect to daemon: \(error). Running in standalone mode.")
            }

            // Trust Caddy CA in background (after daemon has had time to download Caddy)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5.0) { [weak self] in
                self?.trustCaddyCA()
            }
        }
    }

    private func startDaemon() {
        let uid = getuid()
        let socketPath = "/tmp/localport-\(uid).sock"
        if FileManager.default.fileExists(atPath: socketPath) {
            // Check if socket is actually connectable (not stale)
            do {
                try daemonClient.connect()
                logger.info("Daemon already running, skipping launch")
                return
            } catch {
                // Stale socket — remove it and proceed
                logger.info("Removing stale daemon socket")
                try? FileManager.default.removeItem(atPath: socketPath)
            }
        }

        // Try bundled binary first, then system paths
        let bundledPath = Bundle.main.bundlePath + "/Contents/Helpers/localportd"
        let searchPaths = [
            bundledPath,
            "\(NSHomeDirectory())/.cargo/bin/localportd",
            "/usr/local/bin/localportd",
            "/opt/homebrew/bin/localportd",
        ]

        guard let daemonPath = searchPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            logger.warning("No localportd binary found")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: daemonPath)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            daemonProcess = process
            logger.info("Started daemon from \(daemonPath) (PID \(process.processIdentifier))")
        } catch {
            logger.error("Failed to start daemon: \(error)")
        }
    }

    private func stopBundledDaemon() {
        guard let process = daemonProcess, process.isRunning else { return }
        process.interrupt()
        logger.info("Sent interrupt to bundled daemon (PID \(process.processIdentifier))")
        daemonProcess = nil
    }

    private func registerSavedProjectsWithDaemon() {
        guard daemonClient.isConnected else { return }
        let projectsToRegister = projects.filter { !$0.directory.isEmpty }
        guard !projectsToRegister.isEmpty else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            for project in projectsToRegister {
                do {
                    _ = try self.daemonClient.registerProject(directory: project.directory)
                    logger.info("Re-registered project '\(project.name)' with daemon")
                } catch {
                    logger.error("Failed to register \(project.name) with daemon: \(error)")
                }
            }
        }
    }

    private func refreshProjectsFromDaemon() {
        // Try to reconnect if not connected
        if !daemonClient.isConnected {
            do {
                try daemonClient.connect()
                updateMenuBar()
                registerSavedProjectsWithDaemon()
            } catch {
                updateMenuBar()
                return
            }
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let status = try self.daemonClient.getProxyStatus()
                DispatchQueue.main.async {
                    self.syncProjectsFromRoutes(status.routes, daemonProjects: status.projects)
                }
            } catch {
                logger.error("Failed to get proxy status: \(error)")
                DispatchQueue.main.async {
                    self.updateMenuBar()
                }
            }
        }
    }

    private func syncProjectsFromRoutes(_ routes: [[String: Any]], daemonProjects: [[String: Any]]) {
        var newRoutes: [String: String] = [:]

        // Build a lookup from project name -> directory using daemon's project registry.
        var projectDirectories: [String: String] = [:]
        for proj in daemonProjects {
            if let name = proj["name"] as? String,
               let dir = proj["directory"] as? String {
                projectDirectories[name.lowercased()] = dir
            }
        }

        for route in routes {
            guard let hostname = route["hostname"] as? String else { continue }
            let projectName = hostname.components(separatedBy: ".").first ?? hostname
            let upstream = route["upstream"] as? String ?? ""

            newRoutes[projectName] = upstream

            // Match existing projects case-insensitively to avoid duplicates
            // when the daemon normalizes names (e.g. "MyApp" -> "myapp").
            let alreadyExists = projects.contains(where: {
                $0.id.lowercased() == projectName.lowercased()
                    || $0.name.lowercased() == projectName.lowercased()
            })
            if !alreadyExists {
                let colorIndex = projects.count % colorPalette.count
                let directory = projectDirectories[projectName.lowercased()] ?? ""
                let project = Project(
                    id: projectName,
                    name: projectName,
                    directory: directory,
                    hostname: hostname,
                    color: NSColorWrapper(hex: colorPalette[colorIndex])
                )
                projects.append(project)
            } else if let idx = projects.firstIndex(where: {
                $0.id.lowercased() == projectName.lowercased()
            }), projects[idx].directory.isEmpty,
                let dir = projectDirectories[projectName.lowercased()], !dir.isEmpty {
                // Backfill directory for existing projects that were missing it.
                projects[idx].directory = dir
            }
        }

        projectRoutes = newRoutes
        updateMenuBar()
    }

    // MARK: - Project Management

    func addProject(directory: String) {
        // Check for duplicate by directory path
        if let existing = projects.first(where: { $0.directory == directory }) {
            logger.info("Project \(existing.name) already exists (same directory)")
            return
        }

        let dirName = (directory as NSString).lastPathComponent
        let colorIndex = projects.count % colorPalette.count

        // Read .localport.toml if it exists
        let projectConfig = Self.readProjectConfig(directory: directory)
        let rawName = projectConfig?["name"] ?? dirName

        // Normalize: lowercase + replace underscores (matches daemon behavior)
        let projectName = rawName.lowercased().replacingOccurrences(of: "_", with: "-")

        // Check for duplicate by normalized name
        if let existing = projects.first(where: { $0.id == projectName }) {
            logger.info("Project '\(projectName)' already exists (registered as \(existing.directory))")
            return
        }

        let tld = UserDefaults.standard.string(forKey: PrefKey.tld) ?? "test"
        let hostname = projectConfig?["hostname"] ?? "\(projectName).\(tld)"

        let project = Project(
            id: projectName,
            name: projectName,
            directory: directory,
            hostname: hostname,
            color: NSColorWrapper(hex: colorPalette[colorIndex])
        )

        projects.append(project)
        updateMenuBar()
        saveProjects()

        // Register with daemon in the background
        if daemonClient.isConnected {
            let dir = directory
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                do {
                    let result = try self.daemonClient.registerProject(directory: dir)
                    DispatchQueue.main.async {
                        guard let idx = self.projects.firstIndex(where: { $0.directory == dir }) else { return }
                        if let name = result["name"] as? String {
                            self.projects[idx].id = name
                            self.projects[idx].name = name
                        }
                        if let h = result["hostname"] as? String {
                            self.projects[idx].hostname = h
                        }
                        self.updateMenuBar()
                        self.saveProjects()
                    }
                } catch {
                    logger.error("Failed to register project: \(error)")
                }
            }
        }
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
        // Find the project's directory before removing it from the list.
        let directory = projects.first(where: { $0.id == projectID })?.directory

        projects.removeAll { $0.id == projectID }
        saveProjects()
        updateMenuBar()
        logger.info("Removed project \(projectID)")

        // Tell the daemon to unregister the project and remove its routes.
        if let directory = directory, !directory.isEmpty {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    _ = try self?.daemonClient.removeProject(directory: directory)
                } catch {
                    logger.error("Failed to unregister project from daemon: \(error)")
                }
            }
        }
    }

    // MARK: - Project Config File

    /// Reads .localport.toml from a project directory, returns name/hostname if present.
    private static func readProjectConfig(directory: String) -> [String: String]? {
        let configPath = (directory as NSString).appendingPathComponent(".localport.toml")
        guard let content = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            return nil
        }

        var result: [String: String] = [:]
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") || trimmed.hasPrefix("#") || trimmed.isEmpty { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            result[key] = value
        }

        return result.isEmpty ? nil : result
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
            routes: projectRoutes,
            daemonConnected: daemonClient.isConnected
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

    func menuBarDidRequestStartDaemon() {
        startDaemon()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refreshProjectsFromDaemon()
        }
    }

    func menuBarDidRequestStopDaemon() {
        // Try graceful shutdown via IPC, then fall back to process signal
        if daemonClient.isConnected {
            _ = try? daemonClient.callSync(method: "daemon.shutdown")
            daemonClient.disconnect()
        }
        stopBundledDaemon()

        // Also remove the socket so the status updates
        let uid = getuid()
        let socketPath = "/tmp/localport-\(uid).sock"
        try? FileManager.default.removeItem(atPath: socketPath)

        updateMenuBar()
    }

    func menuBarDidRequestUpdate() {
        if let url = updateChecker.releaseURL {
            NSWorkspace.shared.open(url)
        }
    }

    private func performUninstall() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Uninstall LocalPort?"
        alert.informativeText = "This will remove LocalPort, its system configuration (DNS, port forwarding), and stop the daemon. Your projects will not be affected."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            NSApp.setActivationPolicy(.accessory)
            return
        }

        // Stop daemon
        menuBarDidRequestStopDaemon()

        // Find uninstall script
        let uninstallPaths = [
            Bundle.main.bundlePath + "/Contents/Resources/uninstall.sh",
            "scripts/uninstall.sh",
            "../scripts/uninstall.sh",
        ]

        if let script = uninstallPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            let appleScript = NSAppleScript(source: """
            do shell script "bash '\(script)'" with administrator privileges
            """)
            var error: NSDictionary?
            appleScript?.executeAndReturnError(&error)

            if let error = error {
                logger.error("Uninstall failed: \(error)")
            }
        }

        // Remove app config
        let configDir = NSHomeDirectory() + "/.config/localport"
        try? FileManager.default.removeItem(atPath: configDir)

        // Remove the app itself if running from /Applications
        let appPath = Bundle.main.bundlePath
        if appPath.hasPrefix("/Applications") {
            try? FileManager.default.removeItem(atPath: appPath)
        }

        NSApp.terminate(nil)
    }

    func menuBarDidRequestQuit() {
        NSApp.terminate(nil)
    }
}
