import AppKit
import os.log

private let logger = Logger(subsystem: "com.devspace.app", category: "ProjectLauncher")

/// Result of launching a project — tracks the PIDs so we can associate windows
struct LaunchedProject {
    let directory: String
    let info: ProjectInfo
    var idePID: pid_t?
    var terminalPID: pid_t?
    var browserPID: pid_t?
    var devServerProcess: Process?
}

/// Orchestrates opening IDE, starting dev server in terminal, and opening browser
/// for a project directory.
final class ProjectLauncher {
    private let detector = ProjectDetector()
    private let userPrefs = UserAppPreferences.shared

    /// Full project launch sequence:
    /// 1. Detect project type
    /// 2. Open terminal FIRST (needs focus for keystroke-based terminals)
    /// 3. Open IDE with the project directory
    /// 4. Wait for the server to be ready, then open browser
    func launch(directory: String, completion: @escaping (LaunchedProject) -> Void) {
        let info = detector.detect(directory: directory)
        logger.info("Launching \(info.name) (\(info.type.rawValue)) from \(directory)")

        var launched = LaunchedProject(directory: directory, info: info)

        // 1. Open terminal FIRST — must happen before IDE because some terminals
        //    use keystroke-based input that requires the terminal to have focus
        let terminalCommand = info.devCommand ?? ""
        launched.terminalPID = openTerminalWithCommand(terminalCommand, directory: directory)

        // 2. Open IDE (after terminal has received its command)
        launched.idePID = openIDE(directory: directory)

        // 3. Open browser once server is ready (if this project has a web UI)
        if info.needsBrowser {
            let hostname = (directory as NSString).lastPathComponent + ".localhost"

            if let port = info.defaultPort {
                // Poll for the port to become available, then open browser
                waitForPort(port, timeout: 30) { [weak self] in
                    DispatchQueue.main.async {
                        launched.browserPID = self?.openBrowser(url: "http://\(hostname)")
                        completion(launched)
                    }
                }
            } else {
                // No known port — fall back to a short delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    launched.browserPID = self?.openBrowser(url: "http://\(hostname)")
                    completion(launched)
                }
            }
            return
        }

        completion(launched)
    }

    // MARK: - IDE

    private func openIDE(directory: String) -> pid_t? {
        guard let ide = userPrefs.preferredIDE else {
            logger.warning("No IDE configured")
            return nil
        }

        let url = URL(fileURLWithPath: ide.path)
        let dirURL = URL(fileURLWithPath: directory)

        let config = NSWorkspace.OpenConfiguration()
        config.arguments = [directory]

        // VS Code and Cursor accept the directory as an argument
        // For other IDEs, we open the directory as a "file"
        let isVSCodeBased = ide.id.contains("VSCode") || ide.id.contains("Cursor")
            || ide.id.contains("todesktop") || ide.id.contains("antigravity")

        var launchedPID: pid_t?
        let semaphore = DispatchSemaphore(value: 0)

        if isVSCodeBased {
            // Use 'open -a' which passes the directory correctly to VS Code-based editors
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = ["-a", ide.path, directory]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            do {
                try task.run()
                task.waitUntilExit()
                // Find the PID of the launched app
                launchedPID = findPID(forBundleID: ide.id)
            } catch {
                logger.error("Failed to open IDE: \(error)")
            }
        } else {
            NSWorkspace.shared.open(
                [dirURL],
                withApplicationAt: url,
                configuration: config
            ) { app, error in
                if let error = error {
                    logger.error("Failed to open IDE: \(error)")
                } else {
                    launchedPID = app?.processIdentifier
                }
                semaphore.signal()
            }
            semaphore.wait()
        }

        if let pid = launchedPID {
            logger.info("IDE launched: \(ide.name) (PID \(pid))")
        }
        return launchedPID
    }

    // MARK: - Terminal + Dev Server

    private func openTerminalWithCommand(_ command: String, directory: String) -> pid_t? {
        guard let terminal = userPrefs.preferredTerminal else {
            // Fall back to Apple Terminal — always available on macOS
            logger.info("No terminal configured, falling back to Terminal.app")
            return openAppleTerminal(command: command, directory: directory)
        }

        switch terminal.id {
        case "com.apple.Terminal":
            return openAppleTerminal(command: command, directory: directory)
        case "com.googlecode.iterm2":
            return openITerm(command: command, directory: directory)
        case "dev.warp.Warp-Stable":
            return openWarp(command: command, directory: directory)
        case "com.mitchellh.ghostty":
            return openGhostty(command: command, directory: directory)
        default:
            return openGenericTerminal(app: terminal, command: command, directory: directory)
        }
    }

    private func openAppleTerminal(command: String, directory: String) -> pid_t? {
        let shellCmd = command.isEmpty
            ? "cd \(escapeForAppleScript(directory))"
            : "cd \(escapeForAppleScript(directory)) && \(escapeForAppleScript(command))"
        let script = """
        tell application "Terminal"
            activate
            do script "\(shellCmd)"
        end tell
        """
        return runAppleScript(script, appName: "Terminal")
    }

    private func openITerm(command: String, directory: String) -> pid_t? {
        let shellCmd = command.isEmpty
            ? "cd \(escapeForAppleScript(directory))"
            : "cd \(escapeForAppleScript(directory)) && \(escapeForAppleScript(command))"
        let script = """
        tell application "iTerm"
            activate
            set newWindow to (create window with default profile)
            tell current session of newWindow
                write text "\(shellCmd)"
            end tell
        end tell
        """
        return runAppleScript(script, appName: "iTerm2")
    }

    private func openGhostty(command: String, directory: String) -> pid_t? {
        // Ghostty doesn't handle .command files. Since terminal opens BEFORE the IDE,
        // we can safely use System Events keystrokes — Ghostty will be frontmost.
        let shellCmd: String
        if command.isEmpty {
            shellCmd = "cd \(escapeForAppleScript(directory))"
        } else {
            shellCmd = "cd \(escapeForAppleScript(directory)) && \(escapeForAppleScript(command))"
        }

        // Grab PID BEFORE AppleScript — if Ghostty is already running, its PID is stable.
        // After AppleScript, transient helper processes can confuse the lookup.
        let existingPID = findPID(forBundleID: "com.mitchellh.ghostty")
        let alreadyRunning = existingPID != nil

        let script: String
        if alreadyRunning {
            // Already running — activate and open a new window with Cmd+N
            script = """
            tell application "Ghostty" to activate
            delay 0.3
            tell application "System Events"
                keystroke "n" using command down
                delay 0.5
                keystroke "\(shellCmd)"
                keystroke return
            end tell
            """
        } else {
            // Not running — launch it (creates a default window), then type into it
            script = """
            tell application "Ghostty" to activate
            delay 1.0
            tell application "System Events"
                keystroke "\(shellCmd)"
                keystroke return
            end tell
            """
        }

        let appleScript = NSAppleScript(source: script)
        var error: NSDictionary?
        appleScript?.executeAndReturnError(&error)
        if let error = error {
            logger.error("AppleScript error for Ghostty: \(error)")
        }

        // If was already running, use the PID we captured before AppleScript.
        // Otherwise look it up now (it just launched).
        return existingPID ?? findPID(forBundleID: "com.mitchellh.ghostty")
    }

    /// Escape a string for safe use in a shell command
    private func shellEscape(_ str: String) -> String {
        "'" + str.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func openWarp(command: String, directory: String) -> pid_t? {
        return openTerminalViaScript(bundleID: "dev.warp.Warp-Stable", appName: "Warp",
                                     command: command, directory: directory)
    }

    private func openGenericTerminal(app: DetectedApp, command: String, directory: String) -> pid_t? {
        return openTerminalViaScript(bundleID: app.id, appName: app.name,
                                     command: command, directory: directory)
    }

    /// Open a terminal by writing a temp .command script and opening it with the app.
    /// This avoids keystroke-based input entirely — immune to focus races.
    private func openTerminalViaScript(bundleID: String, appName: String,
                                       command: String, directory: String) -> pid_t? {
        let shellCmd: String
        if command.isEmpty {
            shellCmd = "cd \(shellEscape(directory))"
        } else {
            shellCmd = "cd \(shellEscape(directory)) && \(command)"
        }

        // Write a .command script — macOS opens these in the associated terminal
        let scriptContent = "#!/bin/zsh\n\(shellCmd)\nexec $SHELL\n"
        let tmpPath = NSTemporaryDirectory() + "devspace-launch-\(UUID().uuidString).command"
        do {
            try scriptContent.write(toFile: tmpPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmpPath)
        } catch {
            logger.error("Failed to write temp script: \(error)")
            return nil
        }

        // Open the script with the specified terminal app
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", appName, tmpPath]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()
            logger.info("\(appName) opened with project script")

            // Clean up temp script after a delay
            DispatchQueue.global().asyncAfter(deadline: .now() + 5.0) {
                try? FileManager.default.removeItem(atPath: tmpPath)
            }

            return findPID(forBundleID: bundleID)
        } catch {
            logger.error("Failed to open \(appName): \(error)")
            try? FileManager.default.removeItem(atPath: tmpPath)
            return nil
        }
    }

    /// Fallback: run the dev server as a child process (no terminal UI)
    private func startDevServerDirect(_ command: String, directory: String) -> pid_t? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-c", command]
        task.currentDirectoryURL = URL(fileURLWithPath: directory)
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            logger.info("Dev server started directly (PID \(task.processIdentifier))")
            return task.processIdentifier
        } catch {
            logger.error("Failed to start dev server: \(error)")
            return nil
        }
    }

    // MARK: - Port Polling

    /// Poll localhost for a port to accept TCP connections, then call the handler.
    /// Falls back to calling the handler after `timeout` seconds if the port never opens.
    private func waitForPort(_ port: Int, timeout: TimeInterval = 30,
                             then handler: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        let queue = DispatchQueue.global(qos: .userInitiated)

        func poll() {
            if Date() >= deadline {
                logger.info("Port \(port) poll timed out after \(timeout)s — opening browser anyway")
                handler()
                return
            }

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(port).bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")

            let sock = socket(AF_INET, SOCK_STREAM, 0)
            guard sock >= 0 else {
                queue.asyncAfter(deadline: .now() + 0.5) { poll() }
                return
            }
            defer { close(sock) }

            let result = withUnsafePointer(to: &addr, {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            })

            if result == 0 {
                logger.info("Port \(port) is ready")
                handler()
            } else {
                queue.asyncAfter(deadline: .now() + 0.5) { poll() }
            }
        }

        // Start polling after a brief initial delay to let the process start
        queue.asyncAfter(deadline: .now() + 1.0) { poll() }
    }

    // MARK: - Browser

    private func openBrowser(url urlString: String) -> pid_t? {
        guard let browser = userPrefs.preferredBrowser,
              let url = URL(string: urlString) else {
            // Fallback: use default browser
            if let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
            return nil
        }

        let config = NSWorkspace.OpenConfiguration()
        var launchedPID: pid_t?
        let semaphore = DispatchSemaphore(value: 0)

        NSWorkspace.shared.open(
            [url],
            withApplicationAt: URL(fileURLWithPath: browser.path),
            configuration: config
        ) { app, error in
            if let error = error {
                logger.error("Failed to open browser: \(error)")
            } else {
                launchedPID = app?.processIdentifier
            }
            semaphore.signal()
        }
        semaphore.wait()

        if let pid = launchedPID {
            logger.info("Browser opened: \(browser.name) (PID \(pid)) -> \(urlString)")
        }
        return launchedPID
    }

    // MARK: - Helpers

    @discardableResult
    private func runAppleScript(_ source: String, appName: String) -> pid_t? {
        let script = NSAppleScript(source: source)
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        if let error = error {
            logger.error("AppleScript error for \(appName): \(error)")
        }
        return findPID(forApp: appName)
    }

    private func findPID(forBundleID bundleID: String) -> pid_t? {
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == bundleID }?
            .processIdentifier
    }

    private func findPID(forApp name: String) -> pid_t? {
        NSWorkspace.shared.runningApplications
            .first { $0.localizedName == name }?
            .processIdentifier
    }

    private func escapeForAppleScript(_ str: String) -> String {
        str.replacingOccurrences(of: "\\", with: "\\\\")
           .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
