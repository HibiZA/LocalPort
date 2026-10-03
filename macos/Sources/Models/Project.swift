import AppKit

struct Project: Identifiable, Codable {
    /// Stable identity: the project directory.
    var id: String { directory }
    /// The daemon's project name (normalized, DNS-safe).
    var slug: String
    /// Display name, editable in Project Settings.
    var name: String
    var directory: String
    /// Hostname as resolved by the daemon (custom, `.localport.toml`, or default).
    var hostname: String
    var color: NSColorWrapper
    /// Hostname override set in Project Settings; sent on every registration.
    var customHostname: String?
    /// Port pinned in Project Settings; sent on every registration.
    var port: Int?
    /// Route `port` to this project even when the server runs elsewhere
    /// (e.g. a Docker-published port). Set via "Assign to Project".
    var claimPort = false

    var directoryName: String {
        (directory as NSString).lastPathComponent
    }

    init(slug: String, name: String, directory: String, hostname: String, color: NSColorWrapper) {
        self.slug = slug
        self.name = name
        self.directory = directory
        self.hostname = hostname
        self.color = color
    }

    private enum CodingKeys: String, CodingKey {
        case slug, name, directory, hostname, color, customHostname, port, claimPort
        case legacyID = "id" // pre-1.0 saves stored the daemon name as `id`
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        slug = try c.decodeIfPresent(String.self, forKey: .slug)
            ?? c.decodeIfPresent(String.self, forKey: .legacyID)
            ?? name
        directory = try c.decode(String.self, forKey: .directory)
        hostname = try c.decode(String.self, forKey: .hostname)
        color = try c.decode(NSColorWrapper.self, forKey: .color)
        customHostname = try c.decodeIfPresent(String.self, forKey: .customHostname)
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        claimPort = try c.decodeIfPresent(Bool.self, forKey: .claimPort) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(slug, forKey: .slug)
        try c.encode(name, forKey: .name)
        try c.encode(directory, forKey: .directory)
        try c.encode(hostname, forKey: .hostname)
        try c.encode(color, forKey: .color)
        try c.encodeIfPresent(customHostname, forKey: .customHostname)
        try c.encodeIfPresent(port, forKey: .port)
        try c.encode(claimPort, forKey: .claimPort)
    }
}

/// Wrapper so we can store color as hex
struct NSColorWrapper: Codable {
    let hex: String

    var nsColor: NSColor {
        NSColor(hex: hex)
    }
}

extension NSColor {
    convenience init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var rgbValue: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&rgbValue)
        self.init(
            red: CGFloat((rgbValue & 0xFF0000) >> 16) / 255.0,
            green: CGFloat((rgbValue & 0x00FF00) >> 8) / 255.0,
            blue: CGFloat(rgbValue & 0x0000FF) / 255.0,
            alpha: 1.0
        )
    }
}
