import AppKit
import Sparkle
import os.log

private let logger = Logger(subsystem: "com.localport.app", category: "Updater")

let appVersion: String = {
    if let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, v != "0.0.0" {
        return v
    }
    return "dev"
}()

/// Self-updates with Sparkle. The feed (`SUFeedURL`) and the public key that
/// updates must be signed with (`SUPublicEDKey`) are in Info.plist.
///
/// LocalPort lives in the menu bar, so a scheduled check that finds an
/// update doesn't put a window over whatever the user is doing: the popover
/// shows a badge instead, and clicking it opens Sparkle's update dialog.
final class Updater: NSObject {
    /// Main queue: the version found by a scheduled check, nil once handled.
    var onUpdateAvailable: ((String?) -> Void)?

    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self
    )

    /// Sparkle needs a bundled, versioned build; `swift run` isn't one.
    var isAvailable: Bool { appVersion != "dev" && Bundle.main.bundleIdentifier != nil }

    func start() {
        guard isAvailable else { return }
        do {
            try controller.updater.start()
        } catch {
            logger.error("Couldn't start the updater: \(error.localizedDescription)")
        }
        applySettings()
    }

    /// Mirror the Settings toggles into Sparkle. Only on change: Sparkle
    /// stores them in UserDefaults, and the app re-applies settings whenever
    /// UserDefaults changes.
    func applySettings() {
        guard isAvailable else { return }
        let updater = controller.updater
        if updater.automaticallyChecksForUpdates != AppSettings.checkForUpdates {
            updater.automaticallyChecksForUpdates = AppSettings.checkForUpdates
        }
        if updater.automaticallyDownloadsUpdates != AppSettings.installUpdatesAutomatically {
            updater.automaticallyDownloadsUpdates = AppSettings.installUpdatesAutomatically
        }
    }

    /// Show Sparkle's dialog: checking, then the update if there is one.
    func checkForUpdates() {
        guard isAvailable else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    var lastCheck: Date? { isAvailable ? controller.updater.lastUpdateCheckDate : nil }
}

extension Updater: SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Show Sparkle's window only when it would have focus anyway (e.g.
    /// right after launch); otherwise the popover's badge is the reminder.
    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        if !handleShowingUpdate { onUpdateAvailable?(update.displayVersionString) }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        onUpdateAvailable?(nil)
    }

    func standardUserDriverWillFinishUpdateSession() {
        onUpdateAvailable?(nil)
    }
}
