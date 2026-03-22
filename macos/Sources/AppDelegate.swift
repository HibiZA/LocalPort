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

        // Run first-time setup if needed
        if !UserDefaults.standard.bool(forKey: "setupComplete") {
            runFirstTimeSetup()
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

        logger.info("Running first-time setup")

        // Build the privileged script that creates DNS resolver + pfctl rules
        let script = """
        do shell script "
            mkdir -p /etc/resolver
            echo 'nameserver 127.0.0.1\\nport 5553' > /etc/resolver/\(tld)
            cat > /etc/pf.anchors/localport << 'PF'
            rdr pass on lo0 inet proto tcp from any to 127.0.0.1 port 80 -> 127.0.0.1 port 8080
            rdr pass on lo0 inet proto tcp from any to 127.0.0.1 port 443 -> 127.0.0.1 port 8443
        PF
            pfctl -a localport -f /etc/pf.anchors/localport 2>/dev/null
            pfctl -e 2>/dev/null
        " with administrator privileges
        """

        let appleScript = NSAppleScript(source: script)
        var error: NSDictionary?
        appleScript?.executeAndReturnError(&error)

        if let error = error {
            logger.error("Setup script failed: \(error)")
            // Don't mark complete — will retry next launch
            return
        }

        // Install Caddy root CA (runs as current user, may prompt for keychain password)
        // Caddy trust needs the caddy binary — check bundled location
        let caddyBinPaths = [
            "\(NSHomeDirectory())/.config/localport/bin/caddy",
            "/opt/homebrew/bin/caddy",
            "/usr/local/bin/caddy",
        ]
        for path in caddyBinPaths {
            if FileManager.default.fileExists(atPath: path) {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: path)
                task.arguments = ["trust"]
                task.standardOutput = FileHandle.nullDevice
                task.standardError = FileHandle.nullDevice
                try? task.run()
                task.waitUntilExit()
                if task.terminationStatus == 0 {
                    logger.info("Caddy root CA installed")
                }
                break
            }
        }

        UserDefaults.standard.set(true, forKey: "setupComplete")
        logger.info("First-time setup complete")
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
        let helperPath = bundlePath + "/Contents/Helpers/localportd"

        guard FileManager.default.fileExists(atPath: helperPath) else {
            logger.info("No bundled daemon found at \(helperPath), expecting external daemon")
            return
        }

        let uid = getuid()
        let socketPath = "/tmp/localport-\(uid).sock"
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

        // Read .localport.toml if it exists
        let projectConfig = Self.readProjectConfig(directory: directory)
        let projectName = projectConfig?["name"] ?? dirName
        let tld = UserDefaults.standard.string(forKey: PrefKey.tld) ?? "test"
        let hostname = projectConfig?["hostname"] ?? "\(projectName).\(tld)"

        var project = Project(
            id: projectName,
            name: projectName,
            directory: directory,
            hostname: hostname,
            color: NSColorWrapper(hex: colorPalette[colorIndex])
        )

        if daemonClient.isConnected {
            do {
                let result = try daemonClient.registerProject(directory: directory)
                if let name = result["name"] as? String {
                    project.id = name
                    project.name = name
                }
                if let h = result["hostname"] as? String {
                    project.hostname = h
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

    func menuBarDidRequestUpdate() {
        if let url = updateChecker.releaseURL {
            NSWorkspace.shared.open(url)
        }
    }

    func menuBarDidRequestQuit() {
        NSApp.terminate(nil)
    }
}
