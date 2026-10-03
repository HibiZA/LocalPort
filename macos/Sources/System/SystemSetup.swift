import Foundation
import Security
import os.log

private let logger = Logger(subsystem: "com.localport.app", category: "SystemSetup")

/// Privileged one-time setup (DNS resolver, pf port forwarding, CA trust) and
/// its reverse. Every function here blocks — call from a background queue.
enum SystemSetup {
    /// Bump when setup.sh changes in a way existing installs need re-applied.
    static let currentVersion = 2
    private static let versionKey = "setupVersion"

    /// Where the daemon's Caddy keeps its root CA (the daemon reports the
    /// same path as `caRoot`).
    static var defaultCARoot: String {
        NSHomeDirectory() + "/Library/Application Support/LocalPort/caddy/pki/authorities/local/root.crt"
    }

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

    /// Run setup.sh as root (one password prompt).
    @discardableResult
    static func install(info: DaemonInfo) -> Bool {
        guard let script = bundledScript("setup.sh") else {
            logger.error("setup.sh not found")
            return false
        }
        let args = [script, info.tld, "\(info.httpPort)", "\(info.httpsPort)", "\(info.dnsPort)"]
        guard runAsAdmin(["/bin/bash"] + args) else {
            logger.error("Setup failed or was cancelled")
            return false
        }
        UserDefaults.standard.set(currentVersion, forKey: versionKey)
        logger.info("System setup complete (tld .\(info.tld))")
        return true
    }

    /// Trust the CA for TLS for all users. This runs in the app, not via the
    /// admin prompt: macOS only lets a process with UI access change admin
    /// trust settings, so it asks with its own dialog.
    @discardableResult
    static func trustCA(_ caPath: String) -> Bool {
        guard let cert = loadCertificate(caPath) else {
            logger.error("Can't read CA certificate at \(caPath)")
            return false
        }
        // Chain building only finds roots that are in a keychain.
        let added = SecItemAdd([kSecClass: kSecClassCertificate, kSecValueRef: cert] as CFDictionary, nil)
        guard added == errSecSuccess || added == errSecDuplicateItem else {
            logger.error("Couldn't add CA to the keychain: \(added)")
            return false
        }
        let status = SecTrustSettingsSetTrustSettings(cert, .admin, nil)
        guard status == errSecSuccess else {
            logger.error("Couldn't trust CA: \(status)")
            return false
        }
        logger.info("LocalPort root CA trusted")
        return true
    }

    /// Remove the CA's trust setting and its keychain item (one dialog).
    static func untrustCA(_ caPath: String) {
        guard let cert = loadCertificate(caPath) else { return }
        let status = SecTrustSettingsRemoveTrustSettings(cert, .admin)
        if status != errSecSuccess && status != errSecItemNotFound {
            logger.error("Couldn't remove CA trust: \(status)")
        }
        SecItemDelete([kSecClass: kSecClassCertificate, kSecValueRef: cert] as CFDictionary)
    }

    /// Remove everything setup.sh installed, plus the CA and its trust.
    @discardableResult
    static func uninstall(tld: String, dnsPort: Int, caPath: String) -> Bool {
        guard let script = bundledScript("uninstall.sh") else {
            logger.error("uninstall.sh not found")
            return false
        }
        untrustCA(caPath)
        let ok = runAsAdmin(["/bin/bash", script, tld, "\(dnsPort)", caPath])
        UserDefaults.standard.removeObject(forKey: versionKey)
        return ok
    }

    // MARK: - Helpers

    private static func loadCertificate(_ path: String) -> SecCertificate? {
        guard let pem = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let base64 = pem.split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let der = Data(base64Encoded: base64) else { return nil }
        return SecCertificateCreateWithData(nil, der as CFData)
    }

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
