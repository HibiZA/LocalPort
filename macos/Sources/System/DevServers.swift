import Darwin
import Foundation
import os.log

private let logger = Logger(subsystem: "com.localport.app", category: "DevServers")

/// Guesses the command that starts a project's dev server from the files in
/// its folder, e.g. `pnpm run dev` for a package.json with a "dev" script
/// and a pnpm lockfile.
enum StartCommand {
    private static var cache: [String: (checked: Date, command: String?)] = [:]

    /// Cached for a few seconds; the app asks on every refresh.
    static func detected(in directory: String) -> String? {
        if let hit = cache[directory], hit.checked.timeIntervalSinceNow > -10 { return hit.command }
        let command = detect(in: directory)
        cache[directory] = (Date(), command)
        return command
    }

    static func detect(in directory: String) -> String? {
        let fm = FileManager.default
        func has(_ file: String) -> Bool { fm.fileExists(atPath: directory + "/" + file) }

        if let data = fm.contents(atPath: directory + "/package.json"),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let scripts = json["scripts"] as? [String: Any],
           let script = ["dev", "start", "serve"].first(where: { scripts[$0] != nil }) {
            return "\(packageManager(json["packageManager"] as? String, has: has)) run \(script)"
        }
        if has("bin/dev") { return "bin/dev" }
        if has("bin/rails") { return "bin/rails server" }
        if has("manage.py") { return "python3 manage.py runserver" }
        if has("mix.exs") { return "mix phx.server" }
        if has("Cargo.toml") { return "cargo run" }
        if has("go.mod") { return "go run ." }
        if ["compose.yaml", "compose.yml", "docker-compose.yml", "docker-compose.yaml"].contains(where: has) {
            return "docker compose up"
        }
        return nil
    }

    /// From package.json's "packageManager" ("pnpm@9.1.0"), else the lockfile.
    private static func packageManager(_ declared: String?, has: (String) -> Bool) -> String {
        if let name = declared?.split(separator: "@").first.map(String.init),
           ["npm", "pnpm", "yarn", "bun"].contains(name) {
            return name
        }
        if has("bun.lock") || has("bun.lockb") { return "bun" }
        if has("pnpm-lock.yaml") { return "pnpm" }
        if has("yarn.lock") { return "yarn" }
        return "npm"
    }
}

/// Runs project dev servers that the user starts from LocalPort.
///
/// Each command runs in the project folder through the user's shell, with
/// the environment of an interactive login shell (so PATH from .zprofile and
/// .zshrc — Homebrew, nvm, asdf — applies), tagged with
/// `LOCALPORT_PROJECT` so the daemon routes its port to the project
/// whatever its working directory. It gets its own process group, so Stop
/// ends the whole tree (npm → node → esbuild). Output goes to
/// `~/Library/Logs/LocalPort/projects/<name>.log`. Main thread only.
final class DevServerManager {
    enum State: Equatable {
        case running
        case stopping
        /// Ended on its own with this exit code (128 + signal if killed).
        case exited(Int32)
    }

    private(set) var states: [String: State] = [:]
    /// Called after any state change.
    var onChange: (() -> Void)?

    private var children: [String: (pid: pid_t, source: DispatchSourceProcess)] = [:]

    /// The user's shell environment, read once in the background.
    private static let shellEnvironment = ShellEnvironment()

    init() {
        Self.shellEnvironment.load()
    }

    static var logDirectory: String { DaemonSupervisor.logDirectory + "/projects" }

    static func logPath(for project: Project) -> String {
        logDirectory + "/\(project.slug).log"
    }

    func isRunning(_ projectID: String) -> Bool { children[projectID] != nil }

    func start(_ project: Project, command: String) throws {
        guard children[project.id] == nil else { return }
        let logPath = Self.logPath(for: project)
        try FileManager.default.createDirectory(atPath: Self.logDirectory, withIntermediateDirectories: true)
        let header = "\n=== \(Date().formatted(date: .abbreviated, time: .standard)) — \(command) ===\n\n"
        if FileManager.default.fileExists(atPath: logPath), let handle = FileHandle(forWritingAtPath: logPath) {
            handle.truncateFile(atOffset: 0)  // one run per file keeps it short
            handle.write(Data(header.utf8))
            try? handle.close()
        } else {
            try Data(header.utf8).write(to: URL(fileURLWithPath: logPath))
        }

        let pid = try Self.spawn(
            shell: Self.loginShell,
            command: command,
            directory: project.directory,
            logPath: logPath,
            environment: Self.shellEnvironment.value.merging(["LOCALPORT_PROJECT": project.slug]) { _, new in new }
        )
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in self?.reap(project.id, pid: pid) }
        children[project.id] = (pid, source)
        states[project.id] = .running
        source.resume()
        logger.info("Started \(project.slug) (pid \(pid)): \(command)")
        // It may have exited before the source was watching.
        reap(project.id, pid: pid)
        onChange?()
    }

    /// SIGTERM to the process group, SIGKILL after five seconds.
    func stop(_ projectID: String) {
        guard let child = children[projectID] else { return }
        states[projectID] = .stopping
        kill(-child.pid, SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            if self?.children[projectID]?.pid == child.pid { kill(-child.pid, SIGKILL) }
        }
        onChange?()
    }

    /// Forget a crash once the user has seen it (or restarts).
    func clearExit(_ projectID: String) {
        guard case .exited = states[projectID] else { return }
        states[projectID] = nil
        onChange?()
    }

    /// At quit: give every server up to three seconds to stop, then kill it.
    func stopAll() {
        let pids = children.values.map(\.pid)
        guard !pids.isEmpty else { return }
        for pid in pids { kill(-pid, SIGTERM) }
        let deadline = Date().addingTimeInterval(3)
        var remaining = Set(pids)
        while !remaining.isEmpty && Date() < deadline {
            remaining = remaining.filter { waitpid($0, nil, WNOHANG) == 0 }
            if !remaining.isEmpty { usleep(50_000) }
        }
        for pid in remaining { kill(-pid, SIGKILL) }
        children.removeAll()
    }

    private func reap(_ projectID: String, pid: pid_t) {
        var status: Int32 = 0
        guard waitpid(pid, &status, WNOHANG) == pid, children[projectID]?.pid == pid else { return }
        children[projectID]?.source.cancel()
        children[projectID] = nil
        // Whatever the shell left behind would keep holding the port.
        kill(-pid, SIGTERM)

        let signal = status & 0x7F
        let code = signal == 0 ? (status >> 8) & 0xFF : 128 + signal
        if states[projectID] == .stopping || code == 0 {
            states[projectID] = nil
        } else {
            states[projectID] = .exited(code)
        }
        logger.info("Dev server for \(projectID) ended (status \(code))")
        onChange?()
    }

    static var loginShell: String {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell {
            let path = String(cString: shell)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return "/bin/zsh"
    }

    /// `shell -c command` in `directory`, stdout and stderr to
    /// `logPath`, in a new process group led by the child.
    private static func spawn(
        shell: String, command: String, directory: String, logPath: String, environment: [String: String]
    ) throws -> pid_t {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // New process group; close every descriptor not set up below.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attr, 0)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, logPath, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        posix_spawn_file_actions_addchdir_np(&actions, directory)

        // Not interactive: an interactive shell puts jobs in process groups
        // of their own, which Stop wouldn't reach.
        let args = [shell, "-c", command]
        let env = environment
        let argv = args.map { strdup($0) } + [nil]
        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, shell, &actions, &attr, argv, envp)
        guard rc == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(rc), userInfo: [
                NSLocalizedDescriptionKey: "Couldn't start \(shell): \(String(cString: strerror(rc)))",
            ])
        }
        return pid
    }
}

/// The environment of the user's interactive login shell, as a terminal
/// would have it. A GUI app gets a bare PATH; dev tools need the real one.
private final class ShellEnvironment {
    private let lock = NSLock()
    private var resolved: [String: String]?
    private let ready = DispatchSemaphore(value: 0)
    private var started = false

    func load() {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        started = true
        DispatchQueue.global(qos: .utility).async {
            let env = Self.read() ?? ProcessInfo.processInfo.environment
            self.lock.lock()
            self.resolved = env
            self.lock.unlock()
            self.ready.signal()
        }
    }

    /// Waits for `load` (a few seconds at most) on first use.
    var value: [String: String] {
        lock.lock()
        if let resolved { lock.unlock(); return resolved }
        lock.unlock()
        load()
        _ = ready.wait(timeout: .now() + 6)
        ready.signal()  // let later callers through too
        lock.lock()
        defer { lock.unlock() }
        return resolved ?? ProcessInfo.processInfo.environment
    }

    private static let marker = "__LOCALPORT_ENV__"

    /// `$SHELL -l -i -c env`, after a marker so anything .zshrc prints is skipped.
    private static func read() -> [String: String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: DevServerManager.loginShell)
        process.arguments = ["-l", "-i", "-c", "printf '\\n\(marker)\\n'; /usr/bin/env -0"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        do { try process.run() } catch { return nil }
        let timeout = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()

        guard let text = String(data: data, encoding: .utf8),
              let range = text.range(of: "\n\(marker)\n") else {
            logger.error("Couldn't read the shell environment; using the app's")
            return nil
        }
        var env: [String: String] = [:]
        for entry in text[range.upperBound...].split(separator: "\0") {
            guard let eq = entry.firstIndex(of: "=") else { continue }
            env[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
        }
        for key in ["SHLVL", "_", "PWD", "OLDPWD"] { env[key] = nil }
        return env["PATH"] == nil ? nil : env
    }
}
