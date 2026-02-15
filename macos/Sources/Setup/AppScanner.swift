import AppKit
import os.log

private let logger = Logger(subsystem: "com.devspace.app", category: "AppScanner")

/// Categories of apps DevSpace cares about
enum AppCategory: String, CaseIterable, Codable {
    case ide = "IDE / Editor"
    case browser = "Browser"
    case terminal = "Terminal"
}

/// A detected application on the system
struct DetectedApp: Identifiable, Codable, Hashable {
    let id: String           // bundle identifier
    let name: String         // display name
    let path: String         // path to .app bundle
    let category: AppCategory

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: DetectedApp, rhs: DetectedApp) -> Bool { lhs.id == rhs.id }
}

/// Known app signatures — bundle ID to category mapping
private let knownApps: [(bundleID: String, name: String, category: AppCategory)] = [
    // IDEs / Editors
    ("com.todesktop.230313mzl4w4u92", "Cursor", .ide),
    ("com.microsoft.VSCode", "Visual Studio Code", .ide),
    ("com.google.antigravity", "Antigravity", .ide),
    ("dev.zed.Zed", "Zed", .ide),
    ("com.sublimetext.4", "Sublime Text", .ide),
    ("com.jetbrains.intellij", "IntelliJ IDEA", .ide),
    ("com.jetbrains.WebStorm", "WebStorm", .ide),
    ("com.jetbrains.pycharm", "PyCharm", .ide),
    ("com.apple.dt.Xcode", "Xcode", .ide),
    ("co.noteplan.NotePlan3", "Nova", .ide),

    // Browsers
    ("com.google.Chrome", "Google Chrome", .browser),
    ("company.thebrowser.Browser", "Arc", .browser),
    ("app.zen-browser.zen", "Zen", .browser),
    ("net.imput.helium", "Helium", .browser),
    ("com.apple.Safari", "Safari", .browser),
    ("org.mozilla.firefox", "Firefox", .browser),
    ("com.brave.Browser", "Brave", .browser),
    ("com.operasoftware.Opera", "Opera", .browser),
    ("com.vivaldi.Vivaldi", "Vivaldi", .browser),
    ("com.microsoft.edgemac", "Microsoft Edge", .browser),

    // Terminals
    ("com.apple.Terminal", "Terminal", .terminal),
    ("com.googlecode.iterm2", "iTerm2", .terminal),
    ("dev.warp.Warp-Stable", "Warp", .terminal),
    ("io.alacritty", "Alacritty", .terminal),
    ("net.kovidgoyal.kitty", "kitty", .terminal),
    ("com.github.wez.wezterm", "WezTerm", .terminal),
    ("com.mitchellh.ghostty", "Ghostty", .terminal),
]

/// Scans the system for installed applications that DevSpace can work with
final class AppScanner {

    /// Scan /Applications and ~/Applications for known apps
    func scan() -> [DetectedApp] {
        var found: [DetectedApp] = []
        let searchDirs = [
            "/Applications",
            NSHomeDirectory() + "/Applications",
            "/System/Applications",
        ]

        // Method 1: Check known bundle IDs via Launch Services
        for known in knownApps {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: known.bundleID) {
                found.append(DetectedApp(
                    id: known.bundleID,
                    name: known.name,
                    path: url.path,
                    category: known.category
                ))
            }
        }

        // Method 2: Also scan directories for any .app bundles we might have missed
        for dir in searchDirs {
            scanDirectory(dir, into: &found)
        }

        // Deduplicate
        var seen = Set<String>()
        found = found.filter { seen.insert($0.id).inserted }

        let counts = Dictionary(grouping: found, by: \.category).mapValues(\.count)
        logger.info("Scan complete: \(counts.map { "\($0.key.rawValue): \($0.value)" }.joined(separator: ", "))")

        return found
    }

    /// Get apps filtered by category
    func scan(category: AppCategory) -> [DetectedApp] {
        scan().filter { $0.category == category }
    }

    // MARK: - Private

    private func scanDirectory(_ path: String, into results: inout [DetectedApp]) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: path) else { return }

        for item in contents where item.hasSuffix(".app") {
            let appPath = (path as NSString).appendingPathComponent(item)
            let plistPath = (appPath as NSString).appendingPathComponent("Contents/Info.plist")

            guard let plist = NSDictionary(contentsOfFile: plistPath),
                  let bundleID = plist["CFBundleIdentifier"] as? String else { continue }

            // Check if this matches any known app we haven't already found
            if let known = knownApps.first(where: { $0.bundleID == bundleID }),
               !results.contains(where: { $0.id == bundleID }) {
                let displayName = plist["CFBundleDisplayName"] as? String
                    ?? plist["CFBundleName"] as? String
                    ?? known.name

                results.append(DetectedApp(
                    id: bundleID,
                    name: displayName,
                    path: appPath,
                    category: known.category
                ))
            }
        }
    }
}
