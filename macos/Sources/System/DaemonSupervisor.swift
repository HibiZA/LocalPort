import Foundation
import os.log

private let logger = Logger(subsystem: "com.localport.app", category: "DaemonSupervisor")

/// Launches `localportd`, logs its output to ~/Library/Logs/LocalPort, and
/// restarts it with backoff if it exits unexpectedly. Main-thread only.
final class DaemonSupervisor {
    private let client: DaemonClient
    private var process: Process?
    private var launchedAt = Date()
    private var restartDelay: TimeInterval = 1
    private var restartScheduled = false
    /// Set by `stop()`; suppresses the automatic restart.
    private var stopRequested = false

    static var logDirectory: String { NSHomeDirectory() + "/Library/Logs/LocalPort" }
    private static let maxLogBytes = 10 * 1024 * 1024

    init(client: DaemonClient) {
        self.client = client
    }

    /// Whether this app launched the daemon that is currently running.
    var ownsDaemon: Bool { process?.isRunning == true }

    /// Start the daemon unless one is already running (ours or external).
    func start() {
        stopRequested = false
        guard process?.isRunning != true else { return }
        if DaemonClient.isReachable(path: client.socketPath) {
            logger.info("Daemon already running, not launching another")
            return
        }

        guard let daemonPath = Self.findDaemonBinary() else {
            logger.error("No localportd binary found")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: daemonPath)
        // Not inside any project directory, so nothing we spawn is misattributed.
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        if let log = Self.openLog(name: "localportd.log") {
            process.standardOutput = log
            process.standardError = log
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }
        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.handleExit(proc) }
        }

        do {
            try process.run()
            self.process = process
            launchedAt = Date()
            logger.info("Started daemon from \(daemonPath) (PID \(process.processIdentifier))")
        } catch {
            logger.error("Failed to start daemon: \(error)")
            scheduleRestart()
        }
    }

    /// Stop the daemon (ours or external) and don't restart it. The blocking
    /// part (IPC shutdown, waiting for exit) runs off the main thread;
    /// `completion` runs on main once the daemon is gone.
    func stop(completion: (() -> Void)? = nil) {
        stopRequested = true
        let process = self.process
        let client = self.client
        DispatchQueue.global(qos: .userInitiated).async {
            if !client.isConnected { try? client.connect() }
            try? client.shutdown()
            client.disconnect()

            let deadline = Date().addingTimeInterval(5)
            if let process {
                while process.isRunning && Date() < deadline { usleep(50_000) }
                if process.isRunning { process.terminate() }
            }
            while DaemonClient.isReachable(path: client.socketPath) && Date() < deadline {
                usleep(100_000)
            }
            DispatchQueue.main.async { completion?() }
        }
    }

    /// Stop, then start again once the old daemon has released its socket.
    func restart(completion: @escaping () -> Void) {
        stop { [weak self] in
            self?.start()
            completion()
        }
    }

    /// Ask our own daemon to exit (used on app quit; doesn't wait).
    func interruptOwnedDaemon() {
        stopRequested = true
        guard let process, process.isRunning else { return }
        process.interrupt() // SIGINT → daemon stops Caddy and exits
    }

    private func handleExit(_ proc: Process) {
        guard proc === process else { return }
        process = nil
        if stopRequested {
            logger.info("Daemon stopped")
            return
        }
        logger.error("Daemon exited unexpectedly (status \(proc.terminationStatus)); see \(Self.logDirectory)/localportd.log")
        // A daemon that ran for a while before dying gets a fast restart.
        if Date().timeIntervalSince(launchedAt) > 60 {
            restartDelay = 1
        }
        scheduleRestart()
    }

    private func scheduleRestart() {
        guard !restartScheduled else { return }
        restartScheduled = true
        let delay = restartDelay
        restartDelay = min(restartDelay * 2, 30)
        logger.info("Restarting daemon in \(delay)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.restartScheduled = false
            if !self.stopRequested {
                self.start()
            }
        }
    }

    private static func findDaemonBinary() -> String? {
        let searchPaths = [
            Bundle.main.bundlePath + "/Contents/Helpers/localportd",
            "\(NSHomeDirectory())/.cargo/bin/localportd",
            "/usr/local/bin/localportd",
            "/opt/homebrew/bin/localportd",
        ]
        return searchPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Open a log file for appending, rotating it to `.1` once it's too big.
    private static func openLog(name: String) -> FileHandle? {
        let fm = FileManager.default
        let path = logDirectory + "/" + name
        try? fm.createDirectory(atPath: logDirectory, withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int, size > maxLogBytes {
            try? fm.removeItem(atPath: path + ".1")
            try? fm.moveItem(atPath: path, toPath: path + ".1")
        }
        if !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return nil }
        handle.seekToEndOfFile()
        return handle
    }
}
