import AppKit

enum WindowRole: String {
    case editor
    case browser
    case terminal
    case agent
    case other
}

final class TrackedWindow {
    let windowID: CGWindowID
    let ownerPID: pid_t
    let appName: String
    var title: String
    var bounds: CGRect
    var projectID: String?
    var windowRole: WindowRole
    var lastFocusedAt: Date
    var axElement: AXUIElement?

    init(
        windowID: CGWindowID,
        ownerPID: pid_t,
        appName: String,
        title: String,
        bounds: CGRect,
        windowRole: WindowRole = .other,
        lastFocusedAt: Date = Date()
    ) {
        self.windowID = windowID
        self.ownerPID = ownerPID
        self.appName = appName
        self.title = title
        self.bounds = bounds
        self.windowRole = windowRole
        self.lastFocusedAt = lastFocusedAt
    }

    static func classifyApp(_ appName: String) -> WindowRole {
        let name = appName.lowercased()

        // Editors / IDEs
        if name.contains("cursor") || name.contains("visual studio code") || name == "code"
            || name.contains("antigravity") || name.contains("xcode") || name.contains("zed")
            || name.contains("sublime") || name.contains("intellij") || name.contains("neovide")
            || name.contains("nova") || name.contains("fleet") {
            return .editor
        }

        // Browsers
        if name.contains("chrome") || name.contains("arc") || name.contains("zen")
            || name.contains("helium") || name.contains("safari") || name.contains("firefox")
            || name.contains("brave") || name.contains("edge") || name.contains("opera")
            || name.contains("orion") || name.contains("vivaldi") {
            return .browser
        }

        // Terminals
        if name == "terminal" || name.contains("iterm") || name.contains("warp")
            || name.contains("alacritty") || name.contains("kitty") || name.contains("wezterm")
            || name.contains("ghostty") || name.contains("hyper") || name.contains("tabby") {
            return .terminal
        }

        return .other
    }
}
