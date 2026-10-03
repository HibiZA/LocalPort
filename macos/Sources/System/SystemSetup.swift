import Foundation
import os.log

private let logger = Logger(subsystem: "com.localport.app", category: "SystemSetup")

/// Privileged one-time setup (DNS resolver, pf port forwarding, CA trust) and
/// its reverse. Every function here blocks — call from a background queue.
enum SystemSetup {
    /// Bump when setup.sh changes in a way existing installs need re-applied.
    static let currentVersion = 2
    private static let versionKey = "setupVersion"

    static var installedVersion: Int {
        UserDefaults.standard.integer(forKey: versionKey)
    }

    /// Whether the resolver / pf configuration is missing or stale for the
    /// daemon's current TLD and ports (e.g. after a TLD change, a port change,
    /// or a macOS update rewriting /etc/pf.conf).
    static func needsSetup(for info: DaemonInfo) -> Bool {
        guard info.tld != "localhost" else { return false }
        if installedVersion < currentVersion { return true }
        let resolver = (try? String(contentsOfFile: "/etc/resolver/\(info.tld)", encoding: .utf8)) ?? ""
        let anchor = (try? String(contentsOfFile: "/etc/pf.anchors/localport", encoding: .utf8)) ?? ""
        let pfConf = (try? String(contentsOfFile: "/etc/pf.conf", encoding: .utf8)) ?? ""
        return !resolver.contains("port \(info.dnsPort)")
            || !anchor.contains("port \(info.httpPort)")
            || !anchor.contains("port \(info.httpsPort)")
            || !pfConf.contains("localport")
    }

    /// Whether `caPath` is trusted for TLS by the system.
    static func isCATrusted(_ caPath: String) -> Bool {
        run("/usr/bin/security", ["verify-cert", "-c", caPath]) == 0
    }

    /// Run setup.sh as root (one password prompt). Also trusts `caPath` if given.
    @discardableResult
    static func install(info: DaemonInfo, trustCA caPath: String?) -> Bool {
        guard let script = bundledScript("setup.sh") else {
            logger.error("setup.sh not found")
            return false
        }
        var args = [script, info.tld, "\(info.httpPort)", "\(info.httpsPort)", "\(info.dnsPort)"]
        if let caPath { args.append(caPath) }
        guard runAsAdmin(["/bin/bash"] + args) else {
            logger.error("Setup failed or was cancelled")
            return false
        }
        UserDefaults.standard.set(currentVersion, forKey: versionKey)
        logger.info("System setup complete (tld .\(info.tld))")
        return true
    }

    /// Trust the CA in the System keychain (one password prompt).
    @discardableResult
    static func trustCA(_ caPath: String) -> Bool {
        let ok = runAsAdmin([
            "/usr/bin/security", "add-trusted-cert", "-d", "-r", "trustRoot",
            "-k", "/Library/Keychains/System.keychain", caPath,
        ])
        if ok { logger.info("LocalPort root CA trusted") }
        return ok
    }

    /// Remove everything setup.sh installed, plus trust for `caPath`.
    @discardableResult
    static func uninstall(tld: String, dnsPort: Int, caPath: String) -> Bool {
        guard let script = bundledScript("uninstall.sh") else {
            logger.error("uninstall.sh not found")
            return false
        }
        let ok = runAsAdmin(["/bin/bash", script, tld, "\(dnsPort)", caPath])
        UserDefaults.standard.removeObject(forKey: versionKey)
        return ok
    }

    // MARK: - Helpers

    private static func bundledScript(_ name: String) -> String? {
        [
            Bundle.main.bundlePath + "/Contents/Resources/\(name)",
            "scripts/\(name)",
            "../scripts/\(name)",
        ].first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Run a command as root via the standard macOS admin password prompt.
    private static func runAsAdmin(_ argv: [String]) -> Bool {
        let command = argv.map(shellQuote).joined(separator: " ")
        let script = "do shell script \(appleScriptString(command)) with administrator privileges"
        return run("/usr/bin/osascript", ["-e", script]) == 0
    }

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String]) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            logger.error("Failed to run \(executable): \(error)")
            return -1
        }
        task.waitUntilExit()
        return task.terminationStatus
    }

    /// Single-quote for /bin/sh, so paths with spaces or quotes are safe.
    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
