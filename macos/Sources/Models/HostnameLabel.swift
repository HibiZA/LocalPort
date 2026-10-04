import Foundation

/// The editable part of a project's URL ("shop" in "shop.test") and the
/// rules the daemon applies to it (`localport_core::validation`).
enum HostnameLabel {
    /// Lowercase, with spaces and underscores as hyphens and anything a DNS
    /// name can't hold dropped, so typing "My Shop" gives "my-shop".
    static func sanitize(_ raw: String) -> String {
        String(raw.lowercased().compactMap { c -> Character? in
            if c == " " || c == "_" { return "-" }
            let allowed = (c.isASCII && (c.isLetter || c.isNumber)) || c == "-" || c == "."
            return allowed ? c : nil
        })
    }

    /// Why `label` can't be used, or nil if it can. Empty is fine: it means
    /// the default hostname.
    static func problem(_ label: String) -> String? {
        guard !label.isEmpty else { return nil }
        for part in label.split(separator: ".", omittingEmptySubsequences: false) {
            if part.isEmpty { return "Remove the extra dot." }
            if part.count > 63 { return "Each part can be 63 characters at most." }
            if part.hasPrefix("-") || part.hasSuffix("-") { return "A part can't start or end with a hyphen." }
        }
        return nil
    }

    /// `hostname` without its `.tld` suffix.
    static func editable(_ hostname: String, tld: String) -> String {
        let suffix = "." + tld
        return hostname.hasSuffix(suffix) ? String(hostname.dropLast(suffix.count)) : hostname
    }

    /// The override to save for a newly entered label: nil to use the
    /// default. An unchanged label keeps the existing override (or none), so
    /// a hostname from `.localport.toml` keeps following that file.
    static func customHostname(for label: String, project: Project, tld: String) -> String? {
        let label = editable(label, tld: tld)  // "shop.test" typed in full
        if label.isEmpty || label == project.slug { return nil }
        if label == editable(project.hostname, tld: tld) { return project.customHostname }
        return label + "." + tld
    }
}
