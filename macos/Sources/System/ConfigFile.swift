import Foundation

/// Minimal access to the daemon's `~/.config/localport/config.toml`, which is
/// the single source of truth for settings the daemon uses (TLD, ports).
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

    /// Set the top-level `tld`, preserving everything else in the file.
    static func setTLD(_ tld: String) throws {
        var lines = (try? String(contentsOfFile: path, encoding: .utf8))?
            .components(separatedBy: "\n") ?? []
        let newLine = "tld = \"\(tld)\""
        let firstSection = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") } ?? lines.count
        if let idx = lines[..<firstSection].firstIndex(where: { key(of: $0) == "tld" }) {
            lines[idx] = newLine
        } else {
            lines.insert(newLine, at: 0)
        }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
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
