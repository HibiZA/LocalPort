import AppKit
import os.log

private let logger = Logger(subsystem: "com.localport.app", category: "AppDelegate")

final class AppDelegate: NSObject, NSApplicationDelegate {

    // Subsystems
    let menuBarController = MenuBarController()
    let daemonClient = DaemonClient()
    let updateChecker = UpdateChecker()
    private lazy var supervisor = DaemonSupervisor(client: daemonClient)

    /// All daemon IPC happens here, serially, never on the main thread.
    private let daemonQueue = DispatchQueue(label: "com.localport.daemon-ipc")

    // State (main thread only)
    private var projects: [Project] = []
    private var upstreams: [String: String] = [:]  // project.id (directory) -> upstream
    private var otherRoutes: [(hostname: String, upstream: String)] = []
    private var owners: [String: RouteOwner] = [:]
    private var unclaimed: [UnclaimedPort] = []
    private var daemonInfo: DaemonInfo?
    private var daemonPollTimer: Timer?
    private var refreshInFlight = false

    // System setup (main thread only)
    private var setupInFlight = false
    /// Prompt for the admin password at most once per launch / TLD change.
    private var setupAttempted = false
    private var setupWaitingSince: Date?
    private var uninstalling = false
    /// Restart a mismatched daemon at most once per launch.
    private var restartedForVersion = false

    // Default color palette
    private let colorPalette = [
        "#3B82F6", "#10B981", "#F59E0B", "#EF4444", "#8B5CF6", "#EC4899",
    ]

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("LocalPort starting up")

        // Hide dock icon — we're a menu bar app
        NSApp.setActivationPolicy(.accessory)

        menuBarController.delegate = self
        menuBarController.setup()

        NotificationCenter.default.addObserver(
            forName: .localportUninstallRequested, object: nil, queue: .main
        ) { [weak self] _ in
            self?.performUninstall()
        }
        NotificationCenter.default.addObserver(
            forName: .localportTLDChangeRequested, object: nil, queue: .main
        ) { [weak self] note in
            if let tld = note.object as? String { self?.changeTLD(to: tld) }
        }

        loadProjects()
        updateMenuBar()

        updateChecker.onUpdateAvailable = { [weak self] version in
            self?.menuBarController.showUpdateAvailable(version: version)
        }
        updateChecker.startChecking()

        supervisor.start()

        // Poll the daemon for routes and health. The first refreshes come
        // quickly so the menu fills in as soon as the daemon is up.
        for delay in [0.3, 1.0, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refreshFromDaemon()
            }
        }
        daemonPollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refreshFromDaemon()
        }

        logger.info("LocalPort ready")
    }

    func applicationWillTerminate(_ notification: Notification) {
        if !uninstalling { saveProjects() }
        daemonPollTimer?.invalidate()
        updateChecker.stop()
        daemonClient.disconnect()
        supervisor.interruptOwnedDaemon()
    }

    // MARK: - Daemon Sync

    /// Fetch daemon health + project status, re-registering any saved
    /// project the daemon doesn't know about (e.g. after a daemon restart).
    private func refreshFromDaemon() {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        let saved = projects
        let checkVersion = !restartedForVersion

        daemonQueue.async { [weak self] in
            guard let self else { return }
            let result = Result { () -> (DaemonInfo, DaemonProjectStatus?) in
                if !self.daemonClient.isConnected {
                    try self.daemonClient.connect()
                }
                let info = try self.daemonClient.daemonStatus()
                if checkVersion && Self.isStale(info) {
                    return (info, nil)
                }
                var status = try self.daemonClient.projectStatus()

                let known = Set(status.projects.map(\.directory))
                let missing = saved.filter { !$0.directory.isEmpty && !known.contains($0.directory) }
                for project in missing {
                    do {
                        _ = try self.daemonClient.registerProject(
                            directory: project.directory,
                            hostname: project.customHostname,
                            port: project.port,
                            claim: project.claimPort
                        )
                        logger.info("Registered project '\(project.name)' with daemon")
                    } catch {
                        logger.error("Failed to register \(project.name) with daemon: \(error.localizedDescription)")
                    }
                }
                if !missing.isEmpty {
                    status = try self.daemonClient.projectStatus()
                }
                return (info, status)
            }

            DispatchQueue.main.async {
                self.refreshInFlight = false
                switch result {
                case .success(let (info, status?)):
                    self.apply(info: info, status: status)
                    self.runSystemSetupIfNeeded(info)
                case .success(let (info, nil)):
                    self.restartStaleDaemon(info)
                case .failure(let error):
                    if self.daemonInfo != nil {
                        logger.warning("Lost daemon connection: \(error.localizedDescription)")
                    }
                    self.daemonInfo = nil
                    self.clearLiveState()
                    self.updateMenuBar()
                }
            }
        }
    }

    /// A daemon left running by a different app version (e.g. after an
    /// upgrade, or a crash of the old app) speaks an older protocol.
    private static func isStale(_ info: DaemonInfo) -> Bool {
        appVersion != "dev" && info.version != appVersion
    }

    /// Restart once; if the mismatch persists (e.g. an external daemon of
    /// another version), later refreshes use it as best they can.
    private func restartStaleDaemon(_ info: DaemonInfo) {
        guard !restartedForVersion else { return }
        restartedForVersion = true
        logger.info("Restarting daemon v\(info.version) to match app v\(appVersion)")
        supervisor.restart { [weak self] in
            for delay in [0.5, 1.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    self?.refreshFromDaemon()
                }
            }
        }
    }

    private func apply(info: DaemonInfo, status: DaemonProjectStatus) {
        daemonInfo = info

        var newUpstreams: [String: String] = [:]
        var changed = false
        for remote in status.projects {
            guard let idx = projects.firstIndex(where: { $0.directory == remote.directory }) else { continue }
            if projects[idx].slug != remote.name || projects[idx].hostname != remote.hostname {
                // Keep a user-chosen display name; follow the daemon's otherwise.
                if projects[idx].name == projects[idx].slug {
                    projects[idx].name = remote.name
                }
                projects[idx].slug = remote.name
                projects[idx].hostname = remote.hostname
                changed = true
            }
            if let upstream = remote.upstream {
                newUpstreams[projects[idx].id] = upstream
            }
        }
        if changed { saveProjects() }

        let projectHostnames = Set(projects.map(\.hostname))
        upstreams = newUpstreams
        otherRoutes = status.routes
            .filter { !projectHostnames.contains($0.hostname) }
            .map { (hostname: $0.hostname, upstream: $0.upstream) }
        owners = Dictionary(
            status.routes.compactMap { r in r.owner.map { (r.hostname, $0) } },
            uniquingKeysWith: { a, _ in a }
        )
        unclaimed = status.unclaimed ?? []
        updateMenuBar()
    }

    /// Register one project (after adding it or editing its settings) and
    /// refresh. Reports conflicts and errors to the user.
    private func register(_ project: Project) {
        let directory = project.directory
        daemonQueue.async { [weak self] in
            guard let self else { return }
            let result = Result {
                if !self.daemonClient.isConnected { try self.daemonClient.connect() }
                return try self.daemonClient.registerProject(
                    directory: directory,
                    hostname: project.customHostname,
                    port: project.port,
                    claim: project.claimPort
                )
            }
            DispatchQueue.main.async {
                switch result {
                case .success(let info):
                    if let other = self.projects.first(where: { $0.hostname == info.hostname && $0.directory != directory }) {
                        self.showAlert(
                            "Hostname already in use",
                            "\(info.hostname) is also used by \(other.name). Set a custom hostname in this project's Settings."
                        )
                    }
                case .failure(let error as DaemonError):
                    if case .rpcError(let message) = error {
                        self.showAlert("Couldn't register project", message)
                    }
                    // Not connected: the next refresh registers it.
                case .failure(let error):
                    logger.error("Failed to register project: \(error.localizedDescription)")
                }
                self.refreshFromDaemon()
            }
        }
    }

    // MARK: - System Setup

    /// Fix whatever is missing: DNS resolver + pf port forwarding (setup.sh,
    /// one admin prompt) and trusting the local CA (one system dialog).
    private func runSystemSetupIfNeeded(_ info: DaemonInfo) {
        guard !setupInFlight, !setupAttempted, info.tld != "localhost" else { return }

        let caExists = FileManager.default.fileExists(atPath: info.caRoot)
        let proxyPending = info.proxy.state == "starting" || info.proxy.state == "downloading"
        if !caExists && proxyPending {
            // Caddy creates its CA at startup; wait (up to 60s) so the CA
            // can be trusted in the same pass.
            let since = setupWaitingSince ?? Date()
            setupWaitingSince = since
            if Date().timeIntervalSince(since) < 60 { return }
        }

        setupInFlight = true
        DispatchQueue.global(qos: .userInitiated).async {
            let needsSetup = SystemSetup.needsSetup(for: info)
            let needsTrust = caExists && !SystemSetup.isCATrusted(info.caRoot)

            if needsSetup {
                SystemSetup.install(info: info)
            }
            if needsTrust {
                SystemSetup.trustCA(info.caRoot)
            }

            DispatchQueue.main.async {
                self.setupInFlight = false
                // Don't re-prompt this session if the user cancelled; but if
                // the CA didn't exist yet, try trusting it on a later refresh.
                self.setupAttempted = caExists
            }
        }
    }

    private func changeTLD(to tld: String) {
        guard tld != daemonInfo?.tld else { return }
        do {
            try ConfigFile.setTLD(tld)
        } catch {
            showAlert("Couldn't change TLD", error.localizedDescription)
            return
        }
        logger.info("TLD changed to .\(tld); restarting daemon")
        setupAttempted = false
        setupWaitingSince = nil
        daemonInfo = nil
        updateMenuBar()
        supervisor.restart { [weak self] in
            for delay in [0.5, 1.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    self?.refreshFromDaemon()
                }
            }
        }
    }

    // MARK: - Project Management

    func addProject(directory: String) {
        if let existing = projects.first(where: { $0.directory == directory }) {
            showAlert("Project already added", "\(directory) is already registered as \(existing.name).")
            return
        }

        // Placeholder until the daemon resolves the name/hostname (from
        // .localport.toml or the directory name) — see `apply`.
        let dirName = (directory as NSString).lastPathComponent
        let name = dirName.lowercased().replacingOccurrences(of: "_", with: "-")
        let tld = daemonInfo?.tld ?? ConfigFile.tld()
        let project = Project(
            slug: name,
            name: name,
            directory: directory,
            hostname: "\(name).\(tld)",
            color: NSColorWrapper(hex: colorPalette[projects.count % colorPalette.count])
        )

        projects.append(project)
        saveProjects()
        updateMenuBar()
        register(project)
    }

    func updateProject(_ projectID: String, settings: ProjectSettings) {
        guard let idx = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[idx].name = settings.name
        projects[idx].color = NSColorWrapper(hex: settings.color)
        let claim = settings.port != nil && settings.claimPort
        let routingChanged = projects[idx].customHostname != settings.customHostname
            || projects[idx].port != settings.port
            || projects[idx].claimPort != claim
        projects[idx].customHostname = settings.customHostname
        projects[idx].port = settings.port
        projects[idx].claimPort = claim
        if claim, let port = settings.port {
            releaseClaims(on: port, except: projectID)
        }

        saveProjects()
        updateMenuBar()
        if routingChanged {
            register(projects[idx])
        }
        logger.info("Updated project settings for \(projectID)")
    }

    /// Route `port` to a project whichever process listens on it (e.g. a
    /// Docker container), from the "Unclaimed Ports" menu.
    func assign(port: Int, to projectID: String) {
        guard let idx = projects.firstIndex(where: { $0.id == projectID }) else { return }
        releaseClaims(on: port, except: projectID)
        projects[idx].port = port
        projects[idx].claimPort = true
        saveProjects()
        updateMenuBar()
        register(projects[idx])
        logger.info("Assigned port \(port) to \(self.projects[idx].name)")
    }

    /// A port can be claimed by one project only.
    private func releaseClaims(on port: Int, except projectID: String) {
        for i in projects.indices where projects[i].id != projectID && projects[i].claimPort && projects[i].port == port {
            projects[i].claimPort = false
            projects[i].port = nil
            register(projects[i])
        }
    }

    func removeProject(_ projectID: String) {
        let directory = projects.first(where: { $0.id == projectID })?.directory

        projects.removeAll { $0.id == projectID }
        saveProjects()
        updateMenuBar()
        logger.info("Removed project \(projectID)")

        if let directory, !directory.isEmpty {
            daemonQueue.async { [weak self] in
                do {
                    try self?.daemonClient.removeProject(directory: directory)
                } catch {
                    logger.error("Failed to unregister project from daemon: \(error.localizedDescription)")
                }
                DispatchQueue.main.async { self?.refreshFromDaemon() }
            }
        }
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
            // Projects without a directory were auto-created from routes by
            // older versions; those now show under "Other Routes" instead.
            projects = try JSONDecoder().decode([Project].self, from: data)
                .filter { !$0.directory.isEmpty }
            logger.info("Loaded \(self.projects.count) project(s)")
        } catch {
            logger.error("Failed to load projects: \(error)")
        }
    }

    // MARK: - UI Helpers

    private func updateMenuBar() {
        menuBarController.update(MenuState(
            daemonConnected: daemonInfo != nil,
            proxyState: daemonInfo?.proxy.state,
            proxyError: daemonInfo?.proxy.error,
            tld: daemonInfo?.tld,
            projects: projects,
            upstreams: upstreams,
            otherRoutes: otherRoutes,
            owners: owners,
            unclaimed: unclaimed
        ))
    }

    /// The browser URL for a hostname: HTTPS via pf (443) for custom TLDs;
    /// plain HTTP on Caddy's port for `.localhost`, which has no pf rule.
    private func url(for hostname: String) -> URL? {
        if hostname.hasSuffix(".localhost") {
            let port = daemonInfo?.httpPort ?? ConfigFile.httpPort()
            return URL(string: "http://\(hostname):\(port)")
        }
        return URL(string: "https://\(hostname)")
    }

    private func clearLiveState() {
        upstreams = [:]
        otherRoutes = []
        owners = [:]
        unclaimed = []
    }

    private func showAlert(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

// MARK: - MenuBarControllerDelegate

extension AppDelegate: MenuBarControllerDelegate {
    func menuBarDidSelectProject(_ projectID: String) {
        if let project = projects.first(where: { $0.id == projectID }), let url = url(for: project.hostname) {
            NSWorkspace.shared.open(url)
        }
    }

    func menuBarDidSelectRoute(hostname: String) {
        if let url = url(for: hostname) {
            NSWorkspace.shared.open(url)
        }
    }

    func menuBarDidRequestCopyURL(hostname: String) {
        guard let url = url(for: hostname) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    func menuBarDidRequestReveal(_ projectID: String) {
        guard let project = projects.first(where: { $0.id == projectID }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.directory)])
    }

    func menuBarDidRequestOpenUnclaimed(port: Int) {
        if let url = URL(string: "http://localhost:\(port)") {
            NSWorkspace.shared.open(url)
        }
    }

    func menuBarDidRequestAddProject(directory: String) {
        addProject(directory: directory)
    }

    func menuBarDidRequestAssign(port: Int, to projectID: String) {
        assign(port: port, to: projectID)
    }

    func menuBarDidRequestProjectSettings(_ projectID: String) {
        guard let project = projects.first(where: { $0.id == projectID }) else { return }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let tld = daemonInfo?.tld ?? ConfigFile.tld()
        let panel = ProjectSettingsPanel(project: project, tld: tld)
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
        PreferencesWindowController.shared.showWindow()
    }

    func menuBarDidRequestOpenLogs() {
        let dir = daemonInfo?.logDir ?? DaemonSupervisor.logDirectory
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: dir))
    }

    func menuBarDidRequestStartDaemon() {
        supervisor.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refreshFromDaemon()
        }
    }

    func menuBarDidRequestStopDaemon() {
        supervisor.stop { [weak self] in
            self?.daemonInfo = nil
            self?.clearLiveState()
            self?.updateMenuBar()
        }
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
        alert.informativeText = "This will remove LocalPort, its system configuration (DNS, port forwarding, trusted certificate), and stop the daemon. Your projects will not be affected."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            NSApp.setActivationPolicy(.accessory)
            return
        }

        let home = NSHomeDirectory()
        let tld = daemonInfo?.tld ?? ConfigFile.tld()
        let dnsPort = daemonInfo?.dnsPort ?? 5553
        let caRoot = daemonInfo?.caRoot
            ?? home + "/Library/Application Support/LocalPort/caddy/pki/authorities/local/root.crt"

        uninstalling = true
        daemonPollTimer?.invalidate()
        supervisor.stop {
            DispatchQueue.global(qos: .userInitiated).async {
                SystemSetup.uninstall(tld: tld, dnsPort: dnsPort, caPath: caRoot)

                DispatchQueue.main.async {
                    let fm = FileManager.default
                    for path in [
                        ConfigFile.directory,
                        home + "/Library/Application Support/LocalPort",
                        DaemonSupervisor.logDirectory,
                    ] {
                        try? fm.removeItem(atPath: path)
                    }
                    if let bundleID = Bundle.main.bundleIdentifier {
                        UserDefaults.standard.removePersistentDomain(forName: bundleID)
                    }

                    // Remove the app itself if running from /Applications
                    let appPath = Bundle.main.bundlePath
                    if appPath.hasPrefix("/Applications") {
                        try? fm.removeItem(atPath: appPath)
                    }

                    NSApp.terminate(nil)
                }
            }
        }
    }

    func menuBarDidRequestQuit() {
        NSApp.terminate(nil)
    }
}
