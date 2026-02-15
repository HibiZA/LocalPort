import AppKit
import Carbon.HIToolbox
import os.log

private let logger = Logger(subsystem: "com.devspace.app", category: "ProjectSwitcher")

protocol ProjectSwitcherDelegate: AnyObject {
    func projectSwitcher(_ switcher: ProjectSwitcher, didSwitchTo project: Project)
}

final class ProjectSwitcher {
    weak var delegate: ProjectSwitcherDelegate?

    private(set) var projects: [Project] = []
    private(set) var activeProjectIndex: Int = 0
    private var previousProjectIndex: Int = 0
    private var hasActiveProject: Bool = false
    private var eventTap: CFMachPort?

    /// Lookup table rebuilt whenever hotkey preferences change
    private var hotkeyLookup: [UInt64: HotkeyAction] = [:]

    var activeProject: Project? {
        guard hasActiveProject, !projects.isEmpty, activeProjectIndex < projects.count else { return nil }
        return projects[activeProjectIndex]
    }

    // MARK: - Lifecycle

    func start() {
        rebuildHotkeyLookup()
        installEventTap()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hotkeyPreferencesChanged),
            name: HotkeyPreferences.didChangeNotification,
            object: nil
        )

        logger.info("ProjectSwitcher started")
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        eventTap = nil
    }

    func updateProjects(_ projects: [Project]) {
        self.projects = projects
    }

    @objc private func hotkeyPreferencesChanged() {
        rebuildHotkeyLookup()
        logger.info("Hotkey bindings reloaded")
    }

    private func rebuildHotkeyLookup() {
        hotkeyLookup = HotkeyPreferences.shared.buildLookupTable()
    }

    // MARK: - Switching

    func switchTo(index: Int) {
        guard index >= 0, index < projects.count else { return }
        // Allow switching to the same index if no project is active yet (first activation)
        guard index != activeProjectIndex || !hasActiveProject else { return }

        previousProjectIndex = activeProjectIndex
        if hasActiveProject {
            projects[activeProjectIndex].isActive = false
        }

        activeProjectIndex = index
        hasActiveProject = true
        projects[activeProjectIndex].isActive = true
        projects[activeProjectIndex].lastSwitchedAt = Date()

        logger.info("Switched to project: \(self.projects[index].name)")
        delegate?.projectSwitcher(self, didSwitchTo: projects[index])
    }

    func switchTo(projectID: String) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        switchTo(index: index)
    }

    func cycleNext() {
        guard projects.count > 1 else { return }
        let next = (activeProjectIndex + 1) % projects.count
        switchTo(index: next)
    }

    func toggleLast() {
        guard projects.count > 1 else { return }
        switchTo(index: previousProjectIndex)
    }

    // MARK: - Global Hotkeys via CGEvent Tap

    private func installEventTap() {
        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let switcher = Unmanaged<ProjectSwitcher>.fromOpaque(refcon).takeUnretainedValue()
                return switcher.handleKeyEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: refcon
        ) else {
            logger.error("Failed to create event tap. Accessibility permission may be missing.")
            return
        }

        self.eventTap = tap
        let runLoopSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handleKeyEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable tap if it gets disabled (system safety)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let rawFlags = UInt(event.flags.rawValue)
        let lookupKey = HotkeyPreferences.lookupKey(keyCode: keyCode, modifiers: rawFlags)

        guard let action = hotkeyLookup[lookupKey] else {
            return Unmanaged.passUnretained(event)
        }

        switch action {
        case .cycleNext:
            DispatchQueue.main.async { self.cycleNext() }
        case .toggleLast:
            DispatchQueue.main.async { self.toggleLast() }
        case .switchProject1:
            DispatchQueue.main.async { self.switchTo(index: 0) }
        case .switchProject2:
            DispatchQueue.main.async { self.switchTo(index: 1) }
        case .switchProject3:
            DispatchQueue.main.async { self.switchTo(index: 2) }
        case .switchProject4:
            DispatchQueue.main.async { self.switchTo(index: 3) }
        case .switchProject5:
            DispatchQueue.main.async { self.switchTo(index: 4) }
        case .switchProject6:
            DispatchQueue.main.async { self.switchTo(index: 5) }
        case .switchProject7:
            DispatchQueue.main.async { self.switchTo(index: 6) }
        case .switchProject8:
            DispatchQueue.main.async { self.switchTo(index: 7) }
        case .switchProject9:
            DispatchQueue.main.async { self.switchTo(index: 8) }
        }

        return nil // Consume the event
    }
}
