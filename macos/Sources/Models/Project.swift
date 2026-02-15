import AppKit

enum LayoutPreset: String, Codable {
    case codeFocus = "code-focus"
    case previewFocus = "preview-focus"
    case equalSplit = "equal-split"
    case stacked = "stacked"
    case pair = "pair"
    case fullscreen = "fullscreen"
}

struct SavedLayout: Codable {
    var frames: [UInt32: CGRect] = [:]
}

struct Project: Identifiable, Codable {
    let id: String
    var name: String
    var directory: String
    var hostname: String
    var color: NSColorWrapper
    var layoutPreset: LayoutPreset?
    var savedLayout: SavedLayout?
    var isActive: Bool = false
    var lastSwitchedAt: Date = Date()

    var directoryName: String {
        (directory as NSString).lastPathComponent
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
