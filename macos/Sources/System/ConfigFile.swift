import Foundation

/// Minimal access to the daemon's `~/.config/localport/config.toml`, which is
/// the single source of truth for settings the daemon uses (TLD, ports, log
/// level). Defaults here mirror `localport-core`'s.
enum ConfigFile {
    static var directory: String {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            ?? NSHomeDirectory() + "/.config"
        return base + "/localport"
    }

    static var path: String { directory + "/config.toml" }

    /// The configured TLD (the daemon's default is "test").
    static func tld() -> String {
        value(forKey: "tld", section: nil) ?? "test"
    }

    static func httpPort() -> Int {
        value(forKey: "http_port", section: "caddy").flatMap(Int.init) ?? 47080
    }

    static func httpsPort() -> Int {
        value(forKey: "https_port", section: "caddy").flatMap(Int.init) ?? 47443
    }

    static func dnsPort() -> Int {
        value(forKey: "dns_port", section: "daemon").flatMap(Int.init) ?? 5553
    }

    static func logLevel() -> String {
        value(forKey: "log_level", section: "daemon") ?? "info"
    }

    /// Set the top-level `tld`, preserving everything else in the file.
    static func setTLD(_ tld: String) throws {
        try set("tld", to: "\"\(tld)\"", section: nil)
    }

    static func setPorts(http: Int, https: Int, dns: Int) throws {
        try set("http_port", to: String(http), section: "caddy")
        try set("https_port", to: String(https), section: "caddy")
        try set("dns_port", to: String(dns), section: "daemon")
    }

    static func setLogLevel(_ level: String) throws {
        try set("log_level", to: "\"\(level)\"", section: "daemon")
    }

    /// Set `key = rawValue` (a TOML literal) in `[section]` or the top level,
    /// adding the key or section if missing and keeping everything else.
    private static func set(_ key: String, to rawValue: String, section: String?) throws {
        var lines = (try? String(contentsOfFile: path, encoding: .utf8))?
            .components(separatedBy: "\n") ?? []
        let newLine = "\(key) = \(rawValue)"
        let isHeader = { (line: String) in line.trimmingCharacters(in: .whitespaces).hasPrefix("[") }

        // The section's body: from after its header to the next header.
        var start = 0
        if let section {
            if let header = lines.firstIndex(where: { sectionName(of: $0) == section }) {
                start = header + 1
            } else {
                if let last = lines.last, !last.isEmpty { lines.append("") }
                lines.append("[\(section)]")
                start = lines.count
            }
        }
        let end = lines[start...].firstIndex(where: isHeader) ?? lines.count

        if let idx = lines[start..<end].firstIndex(where: { self.key(of: $0) == key }) {
            lines[idx] = newLine
        } else {
            // After the section's last non-blank line (top level: file start).
            var insertAt = section == nil ? 0 : end
            while section != nil, insertAt > start, lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                insertAt -= 1
            }
            lines.insert(newLine, at: insertAt)
        }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    private static func sectionName(of line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[") else { return nil }
        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
    }

    /// Read `key = value` from `[section]` (or the top level when nil).
    private static func value(forKey wanted: String, section wantedSection: String?) -> String? {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var section: String?
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                section = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                continue
            }
            guard section == wantedSection, key(of: trimmed) == wanted,
                  let eq = trimmed.firstIndex(of: "=") else { continue }
            var value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if let hash = value.firstIndex(of: "#") {
                value = value[..<hash].trimmingCharacters(in: .whitespaces)
            }
            return value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }

    private static func key(of line: String) -> String? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        return line[..<eq].trimmingCharacters(in: .whitespaces)
    }
}
