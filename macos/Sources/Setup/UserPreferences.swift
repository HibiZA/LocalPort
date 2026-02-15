import Foundation

/// Persisted user choices for which apps to use
final class UserAppPreferences {
    static let shared = UserAppPreferences()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let ide = "preferredIDE"
        static let browser = "preferredBrowser"
        static let terminal = "preferredTerminal"
        static let onboardingComplete = "onboardingComplete"
        static let closeWindowsOnQuit = "closeWindowsOnQuit"
    }

    var isOnboardingComplete: Bool {
        get { defaults.bool(forKey: Key.onboardingComplete) }
        set { defaults.set(newValue, forKey: Key.onboardingComplete) }
    }

    /// Whether to close project windows when DevSpace quits (default: false)
    var closeWindowsOnQuit: Bool {
        get { defaults.bool(forKey: Key.closeWindowsOnQuit) }
        set { defaults.set(newValue, forKey: Key.closeWindowsOnQuit) }
    }

    var preferredIDE: DetectedApp? {
        get { load(key: Key.ide) }
        set { save(newValue, key: Key.ide) }
    }

    var preferredBrowser: DetectedApp? {
        get { load(key: Key.browser) }
        set { save(newValue, key: Key.browser) }
    }

    var preferredTerminal: DetectedApp? {
        get { load(key: Key.terminal) }
        set { save(newValue, key: Key.terminal) }
    }

    private func save(_ app: DetectedApp?, key: String) {
        guard let app = app,
              let data = try? JSONEncoder().encode(app) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }

    private func load(key: String) -> DetectedApp? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(DetectedApp.self, from: data)
    }
}
