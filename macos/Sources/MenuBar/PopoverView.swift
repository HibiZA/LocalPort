import SwiftUI

/// What the popover shows, and the actions it can take. Owned by
/// `MenuBarController`, which forwards actions to its delegate.
final class PopoverModel: ObservableObject {
    @Published var state = MenuState()
    @Published var availableUpdate: String?
    /// Resource usage by pid, sampled only while the Ports tab is showing.
    @Published var stats: [Int32: ProcessStats] = [:]
    @Published var portsTabVisible = false
    /// Installed editors; refreshed each time the popover opens.
    @Published var editors: [AppSettings.App] = []
    /// The project whose URL is being renamed in place, if any.
    @Published var renamingProjectID: String?

    var preferredEditor: AppSettings.App? { AppSettings.preferredEditor(in: editors) }

    var openProject: (String) -> Void = { _ in }
    var openRoute: (String) -> Void = { _ in }
    var copyURL: (String) -> Void = { _ in }
    var reveal: (String) -> Void = { _ in }
    var openInEditor: (String, AppSettings.App) -> Void = { _, _ in }
    /// Project ID and the new label ("shop" for shop.test; empty = default).
    var renameProject: (String, String) -> Void = { _, _ in }
    var projectSettings: (String) -> Void = { _ in }
    var startServer: (String) -> Void = { _ in }
    var stopServer: (String) -> Void = { _ in }
    var restartServer: (String) -> Void = { _ in }
    var showOutput: (String) -> Void = { _ in }
    var togglePin: (String) -> Void = { _ in }
    /// Move a project into another's place, while dragging.
    var moveProject: (String, String) -> Void = { _, _ in }
    var openUnclaimed: (Int) -> Void = { _ in }
    var addProjectAt: (String) -> Void = { _ in }
    var assign: (Int, String) -> Void = { _, _ in }
    var addProject: () -> Void = {}
    var preferences: () -> Void = {}
    var openLogs: () -> Void = {}
    /// Opens Sparkle's update dialog.
    var openUpdate: () -> Void = {}
    var startDaemon: () -> Void = {}
    var stopDaemon: () -> Void = {}
    var quit: () -> Void = {}
}

private enum Tab: CaseIterable {
    case projects, ports, system

    var symbol: String {
        switch self {
        case .projects: return "globe"
        case .ports: return "dot.radiowaves.left.and.right"
        case .system: return "server.rack"
        }
    }

    var title: String {
        switch self {
        case .projects: return "Projects"
        case .ports: return "Ports"
        case .system: return "System"
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .projects: return "1"
        case .ports: return "2"
        case .system: return "3"
        }
    }
}

struct PopoverView: View {
    @ObservedObject var model: PopoverModel
    @State private var tab: Tab = .projects
    @State private var drag: RowDrag?
    @State private var rowFrames: [String: CGRect] = [:]

    private static let listSpace = "projectList"

    /// Every tab gets the same height, so the popover doesn't jump when
    /// switching; longer content scrolls.
    private static let contentHeight: CGFloat = 316

    private var state: MenuState { model.state }

    var body: some View {
        VStack(spacing: 14) {
            header
            tabBar
            ScrollView(showsIndicators: false) {
                Group {
                    switch tab {
                    case .projects: projectsTab
                    case .ports: portsTab
                    case .system: systemTab
                    }
                }
                // Room for the panels' shadows inside the scroll view.
                .padding(.horizontal, 4)
                .padding(.bottom, 8)
            }
            .frame(height: Self.contentHeight)
            // Fade the bottom edge so a list that continues reads as scrollable.
            .mask(
                LinearGradient(
                    stops: [.init(color: .black, location: 0.9), .init(color: .clear, location: 1)],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .padding(.horizontal, -4)
            footer
        }
        .padding(16)
        .frame(width: 380)
        .onAppear { model.portsTabVisible = tab == .ports }
        .onChange(of: tab) { model.portsTabVisible = $0 == .ports }
        .foregroundStyle(Steel.textPrimary)
        .background(Steel.background)
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: MenuBarController.appIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("LocalPort")
                    .font(.system(size: 14, weight: .semibold))
                HStack(spacing: 5) {
                    Circle().fill(health.color).frame(width: 6, height: 6)
                    Text(health.label)
                        .font(.system(size: 11))
                        .foregroundStyle(Steel.textSecondary)
                }
            }
            Spacer()
            if let version = model.availableUpdate {
                Button(action: model.openUpdate) {
                    Label("v\(version)", systemImage: "arrow.down.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Steel.ice.opacity(0.12)))
                        .foregroundStyle(Steel.ice)
                }
                .buttonStyle(.plain)
                .help("Update available: LocalPort \(version)")
            }
        }
    }

    private var health: (label: String, color: Color) {
        guard state.daemonConnected else { return ("Daemon stopped", Steel.danger) }
        let tld = state.tld.map { " · .\($0)" } ?? ""
        switch state.proxyState {
        case "running", nil: return ("Running" + tld, Steel.ice)
        case "failed": return ("Proxy failed", Steel.danger)
        default: return (proxyLabel, Steel.amber)
        }
    }

    // MARK: - Tabs

    private var tabBar: some View {
        SteelTabBar(
            items: Tab.allCases.map {
                .init(
                    value: $0, symbol: $0.symbol, title: $0.title,
                    badge: $0 == .ports ? state.unclaimed.count : nil,
                    shortcut: $0.shortcut
                )
            },
            selection: $tab
        )
    }

    // MARK: - Projects

    /// Pinned projects in their own card on top; drag a row to reorder it
    /// within its card.
    private var projectsTab: some View {
        let pinned = state.projects.filter(\.pinned)
        let unpinned = state.projects.filter { !$0.pinned }
        return VStack(alignment: .leading, spacing: 8) {
            if !pinned.isEmpty {
                SectionHeader("Pinned")
                Card { projectRows(pinned) }
                    .padding(.bottom, 8)
                SectionHeader("Projects")
            }
            Card {
                if state.projects.isEmpty {
                    EmptyState(
                        symbol: "shippingbox",
                        title: "No projects yet",
                        message: "Add a project folder and its dev server gets a hostname like myapp.\(state.tld ?? "test")."
                    )
                } else {
                    projectRows(unpinned)
                }
                if !unpinned.isEmpty || state.projects.isEmpty { RowDivider() }
                CardButton(symbol: "plus", title: "Add Project…", action: model.addProject)
                    .keyboardShortcut("n")
            }
        }
        .coordinateSpace(name: Self.listSpace)
        .onPreferenceChange(RowFramesKey.self) { rowFrames = $0 }
    }

    private func projectRows(_ group: [Project]) -> some View {
        ForEach(Array(group.enumerated()), id: \.element.id) { index, project in
            if index > 0 { RowDivider() }
            let dragged = drag?.id == project.id
            ProjectRow(
                project: project,
                upstream: state.upstreams[project.id],
                owner: state.owners[project.hostname],
                model: model,
                renaming: model.renamingProjectID == project.id,
                context: renameContext,
                server: state.devServers[project.id],
                startCommand: state.startCommands[project.id]
            )
            .background(GeometryReader { geo in
                Color.clear.preference(key: RowFramesKey.self, value: [project.id: geo.frame(in: .named(Self.listSpace))])
            })
            .background {
                if dragged {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Steel.surface)
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Steel.edge))
                        .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
                        .padding(.horizontal, -8)
                }
            }
            .offset(y: dragOffset(for: project))
            .zIndex(dragged ? 1 : 0)
            .animation(dragged ? nil : .easeOut(duration: 0.15), value: index)
            .gesture(reorderGesture(for: project), including: model.renamingProjectID == nil ? .all : .subviews)
        }
    }

    // MARK: Reordering

    /// Row midpoints of `project`'s group, top to bottom. While rows move,
    /// the frames keyed by id can lag a layout behind, but the set of
    /// positions stays the same, so slot `i` is where row `i` is drawn.
    private func slots(for project: Project) -> (group: [Project], midYs: [CGFloat])? {
        let group = state.projects.filter { $0.pinned == project.pinned }
        let midYs = group.compactMap { rowFrames[$0.id]?.midY }.sorted()
        return midYs.count == group.count ? (group, midYs) : nil
    }

    private func dragOffset(for project: Project) -> CGFloat {
        guard let drag, drag.id == project.id, let (group, midYs) = slots(for: project),
              let index = group.firstIndex(where: { $0.id == project.id }) else { return 0 }
        return drag.startMidY + drag.translation - midYs[index]
    }

    private func reorderGesture(for project: Project) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.listSpace))
            .onChanged { value in
                if drag == nil {
                    guard let frame = rowFrames[project.id] else { return }
                    drag = RowDrag(id: project.id, startMidY: frame.midY)
                }
                drag?.translation = value.translation.height
                guard let drag, let (group, midYs) = slots(for: project),
                      let index = group.firstIndex(where: { $0.id == project.id }) else { return }
                // The slot nearest the pointer; past the halfway mark, swap.
                let y = drag.startMidY + drag.translation
                let target = midYs.indices.min { abs(midYs[$0] - y) < abs(midYs[$1] - y) } ?? index
                if target != index { model.moveProject(project.id, group[target].id) }
            }
            .onEnded { _ in
                withAnimation(.easeOut(duration: 0.15)) { drag = nil }
            }
    }

    private var renameContext: RenameContext {
        var taken: [String: String] = [:]
        for route in state.otherRoutes { taken[route.hostname] = "a localport run server" }
        for project in state.projects { taken[project.hostname] = project.name }
        return RenameContext(tld: state.tld ?? "test", taken: taken)
    }

    // MARK: - Ports

    private var runningProjects: [Project] {
        state.projects.filter { state.upstreams[$0.id] != nil }
    }

    private func stats(for pid: Int?) -> ProcessStats? {
        pid.flatMap { model.stats[Int32($0)] }
    }

    private var portsTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !runningProjects.isEmpty {
                SectionHeader("Project servers")
                Card {
                    ForEach(Array(runningProjects.enumerated()), id: \.element.id) { index, project in
                        if index > 0 { RowDivider() }
                        let owner = state.owners[project.hostname]
                        ProjectRow(
                            project: project,
                            upstream: state.upstreams[project.id],
                            owner: owner,
                            model: model,
                            renaming: model.renamingProjectID == project.id,
                            context: renameContext,
                            server: state.devServers[project.id],
                            startCommand: state.startCommands[project.id],
                            stats: .some(stats(for: owner?.pid))
                        )
                    }
                }
                .padding(.bottom, 8)
            }

            if !state.otherRoutes.isEmpty {
                SectionHeader("Other routes")
                Card {
                    ForEach(Array(state.otherRoutes.enumerated()), id: \.element.hostname) { index, route in
                        if index > 0 { RowDivider() }
                        let owner = state.owners[route.hostname]
                        RouteRow(
                            hostname: route.hostname,
                            upstream: route.upstream,
                            owner: owner,
                            model: model,
                            stats: .some(stats(for: owner?.pid))
                        )
                    }
                }
                .padding(.bottom, 8)
            }

            SectionHeader("Unclaimed")
            Card {
                if state.unclaimed.isEmpty {
                    EmptyState(
                        symbol: "checkmark.circle",
                        title: "Nothing unclaimed",
                        message: "Every dev server LocalPort can see belongs to a project."
                    )
                } else {
                    ForEach(Array(state.unclaimed.enumerated()), id: \.element.port) { index, port in
                        if index > 0 { RowDivider() }
                        UnclaimedRow(
                            port: port, projects: state.projects, model: model,
                            stats: .some(stats(for: port.pid))
                        )
                    }
                }
            }
        }
    }

    // MARK: - System

    private var systemTab: some View {
        VStack(spacing: 12) {
            Card {
                StatusRow(symbol: "bolt.horizontal.circle", title: "Daemon") {
                    HStack(spacing: 10) {
                        StatusText(
                            text: state.daemonConnected ? "Running" : "Stopped",
                            color: state.daemonConnected ? Steel.ice : Steel.danger
                        )
                        SteelButton(title: state.daemonConnected ? "Stop" : "Start") {
                            state.daemonConnected ? model.stopDaemon() : model.startDaemon()
                        }
                    }
                }
                RowDivider()
                StatusRow(symbol: "lock.shield", title: "HTTPS proxy") {
                    StatusText(text: proxyLabel, color: health.color)
                }
                if state.proxyState == "failed", let error = state.proxyError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(Steel.textSecondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                        .padding(.leading, 34)
                        .padding(.bottom, 8)
                }
                RowDivider()
                StatusRow(symbol: "network", title: "Domain") {
                    Text(state.tld.map { ".\($0)" } ?? "—")
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(Steel.textSecondary)
                }
                RowDivider()
                StatusRow(symbol: "point.3.connected.trianglepath.dotted", title: "Active routes") {
                    Text("\(state.upstreams.count + state.otherRoutes.count)")
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(Steel.textSecondary)
                }
            }
            Card {
                CardButton(symbol: "doc.text.magnifyingglass", title: "Open Logs", action: model.openLogs)
                RowDivider()
                CardButton(symbol: "arrow.down.circle", title: "Check for Updates…", action: model.openUpdate)
            }
        }
    }

    private var proxyLabel: String {
        guard state.daemonConnected else { return "Offline" }
        switch state.proxyState {
        case "running", nil: return "Running"
        case "downloading": return "Downloading Caddy…"
        case "starting": return "Starting…"
        case "failed": return "Failed"
        case let other?: return other.capitalized
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            FooterButton(symbol: "gearshape", title: "Settings", action: model.preferences)
                .keyboardShortcut(",")
            FooterButton(symbol: "power", title: "Quit", action: model.quit)
                .keyboardShortcut("q")
        }
    }
}

// MARK: - Rows

/// A project row being dragged: where it started and how far it moved,
/// in the project list's coordinates.
private struct RowDrag {
    let id: String
    let startMidY: CGFloat
    var translation: CGFloat = 0
}

private struct RowFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// What renaming a project's URL needs to know about the others.
private struct RenameContext {
    let tld: String
    /// hostname -> who uses it.
    let taken: [String: String]
}

private struct ProjectRow: View {
    let project: Project
    let upstream: String?
    let owner: RouteOwner?
    let model: PopoverModel
    let renaming: Bool
    let context: RenameContext
    /// A dev server LocalPort started for this project, if any.
    var server: DevServerManager.State?
    /// What Start runs; nil if LocalPort doesn't know how to start it.
    var startCommand: String?
    /// Outer `nil`: no stats line; inner `nil`: not measured yet.
    var stats: ProcessStats?? = nil

    @State private var hovering = false
    @State private var copied = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    private var running: Bool { upstream != nil }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                Badge(
                    color: Color(nsColor: project.color.nsColor),
                    letter: project.name.first.map(String.init) ?? "?",
                    dimmed: !running
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(running ? Steel.textPrimary : Steel.textSecondary)
                        .lineLimit(1)
                    if renaming {
                        hostnameField
                    } else {
                        HStack(spacing: 5) {
                            Text(project.hostname)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(running ? Steel.textSecondary : Steel.textTertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if hovering {
                                RenameButton(action: startRename)
                            }
                        }
                    }
                }
                Spacer(minLength: 8)
                if renaming {
                    HStack(spacing: 2) {
                        IconButton(symbol: "xmark", help: "Cancel (Esc)", action: cancelRename)
                        IconButton(symbol: "checkmark", help: "Save (Return)", action: commitRename)
                            .disabled(renameProblem != nil)
                    }
                } else if copied {
                    StatusPill(text: "Copied", color: Steel.ice, emphasized: true)
                } else if hovering {
                    HStack(spacing: 2) {
                        if canStop {
                            IconButton(symbol: "stop.fill", help: "Stop dev server") { model.stopServer(project.id) }
                        } else if let startCommand, canStart {
                            IconButton(symbol: "play.fill", help: "Start dev server: \(startCommand)") {
                                model.startServer(project.id)
                            }
                        }
                        IconButton(symbol: "doc.on.doc", help: "Copy URL", action: copy)
                        if let editor = model.preferredEditor {
                            IconButton(symbol: "chevron.left.forwardslash.chevron.right", help: "Open in \(editor.name)") {
                                model.openInEditor(project.id, editor)
                            }
                        }
                        IconButton(symbol: "arrow.up.right", help: "Open in browser") { model.openProject(project.id) }
                    }
                } else {
                    statusPill
                }
                if !renaming {
                    projectMenu
                }
            }
            if renaming {
                Text(renameProblem ?? renameHint)
                    .font(.system(size: 10.5))
                    .foregroundStyle(renameProblem == nil ? Steel.textTertiary : Steel.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 44)
            }
            if let stats { StatsLine(stats: stats).padding(.leading, 44) }
        }
        .padding(.vertical, stats == nil && !renaming ? 0 : 8)
        .rowStyle(hovering: hovering && !renaming)
        .onHover { hovering = $0 }
        .onTapGesture { if !renaming { model.openProject(project.id) } }
        .help(renaming ? "" : rowHelp)
    }

    private var rowHelp: String {
        if case .exited(let code) = server, upstream == nil {
            return "The dev server exited with code \(code). Its output is in the ••• menu."
        }
        return ownerHelp(owner, upstream: upstream) ?? "Open \(project.hostname)"
    }

    // MARK: Dev server

    /// Started by LocalPort, so LocalPort can stop it.
    private var canStop: Bool { server == .running || server == .stopping }
    private var canStart: Bool { startCommand != nil && upstream == nil && !canStop }

    @ViewBuilder
    private var statusPill: some View {
        switch server {
        case .stopping:
            StatusPill(text: "Stopping…", color: Steel.amber, emphasized: true)
        case .running where upstream == nil:
            StatusPill(text: "Starting…", color: Steel.amber, emphasized: true)
        case .exited(let code) where upstream == nil:
            StatusPill(text: "Exited (\(code))", color: Steel.danger, emphasized: true)
        default:
            if let port = upstream.flatMap(portOf) {
                StatusPill(text: ":\(port)", color: Steel.ice, emphasized: true)
            } else {
                StatusPill(text: "Stopped", color: Steel.textTertiary)
            }
        }
    }

    private var hasOutput: Bool {
        server != nil || FileManager.default.fileExists(atPath: DevServerManager.logPath(for: project))
    }

    private var projectMenu: some View {
        MoreMenu {
            if let detail = ownerHelp(owner, upstream: upstream) {
                Text(detail)
                Divider()
            }
            if canStop {
                Button("Stop Dev Server") { model.stopServer(project.id) }
                Button("Restart Dev Server") { model.restartServer(project.id) }
            } else if canStart {
                Button("Start Dev Server") { model.startServer(project.id) }
            } else if upstream == nil {
                Button("Set Start Command…") { model.projectSettings(project.id) }
            }
            if hasOutput {
                Button("Show Output") { model.showOutput(project.id) }
            }
            Divider()
            Button("Open in Browser") { model.openProject(project.id) }
            if let editor = model.preferredEditor {
                Button("Open in \(editor.name)") { model.openInEditor(project.id, editor) }
            }
            if model.editors.count > 1 {
                Menu("Open in Editor") {
                    ForEach(model.editors) { editor in
                        Button {
                            model.openInEditor(project.id, editor)
                        } label: {
                            Label { Text(editor.name) } icon: { Image(nsImage: editor.icon) }
                        }
                    }
                }
            }
            Button("Copy URL", action: copy)
            Button("Rename URL…", action: startRename)
            Button("Reveal in Finder") { model.reveal(project.id) }
            Divider()
            Button(project.pinned ? "Unpin" : "Pin to Top") { model.togglePin(project.id) }
            Button("Settings…") { model.projectSettings(project.id) }
        }
    }

    // MARK: Rename

    /// The label as an inline field with the fixed `.tld` after it. The field
    /// is as wide as its text, so the suffix follows what you type.
    private var hostnameField: some View {
        HStack(spacing: 0) {
            Text(draft.isEmpty ? project.slug : draft)
                .hidden()
                .overlay {
                    TextField(project.slug, text: $draft)
                        .textFieldStyle(.plain)
                        .focused($fieldFocused)
                        .onSubmit(commitRename)
                        .onExitCommand(perform: cancelRename)
                }
            Text(".\(context.tld)")
                .foregroundStyle(Steel.textTertiary)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11.5, design: .monospaced))
        .lineLimit(1)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.black.opacity(0.35)))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(renameProblem == nil ? Steel.ice.opacity(0.6) : Steel.danger.opacity(0.8))
        )
        .onChange(of: draft) { value in
            let clean = HostnameLabel.sanitize(value)
            if clean != value { draft = clean }
        }
        .onAppear {
            draft = HostnameLabel.editable(project.hostname, tld: context.tld)
            fieldFocused = true
        }
    }

    private var renameProblem: String? {
        if let problem = HostnameLabel.problem(draft) { return problem }
        let hostname = (draft.isEmpty ? project.slug : draft) + "." + context.tld
        if hostname != project.hostname, let user = context.taken[hostname] {
            return "\(hostname) is already used by \(user)."
        }
        return nil
    }

    private var renameHint: String {
        draft.isEmpty
            ? "Empty uses the default, \(project.slug).\(context.tld)."
            : "Return to save, Esc to cancel."
    }

    private func startRename() {
        model.renamingProjectID = project.id
    }

    private func cancelRename() {
        model.renamingProjectID = nil
    }

    private func commitRename() {
        guard renameProblem == nil else { return }
        model.renamingProjectID = nil
        if draft != HostnameLabel.editable(project.hostname, tld: context.tld) {
            model.renameProject(project.id, draft)
        }
    }

    private func copy() {
        model.copyURL(project.hostname)
        withAnimation(.easeOut(duration: 0.15)) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(.easeOut(duration: 0.2)) { copied = false }
        }
    }
}

private struct RouteRow: View {
    let hostname: String
    let upstream: String
    let owner: RouteOwner?
    let model: PopoverModel
    var stats: ProcessStats?? = nil

    @State private var hovering = false

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                Badge(color: Steel.ice, symbol: "arrow.triangle.branch")
                VStack(alignment: .leading, spacing: 2) {
                    Text(hostname)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(ownerDetail(owner, upstream: upstream) ?? upstream)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Steel.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if hovering {
                    HStack(spacing: 2) {
                        IconButton(symbol: "doc.on.doc", help: "Copy URL") { model.copyURL(hostname) }
                        IconButton(symbol: "arrow.up.right", help: "Open in browser") { model.openRoute(hostname) }
                    }
                } else if let port = portOf(upstream) {
                    StatusPill(text: ":\(port)", color: Steel.ice, emphasized: true)
                }
                MoreMenu {
                    Button("Open in Browser") { model.openRoute(hostname) }
                    Button("Copy URL") { model.copyURL(hostname) }
                }
            }
            if let stats { StatsLine(stats: stats).padding(.leading, 44) }
        }
        .padding(.vertical, stats == nil ? 0 : 8)
        .rowStyle(hovering: hovering)
        .onHover { hovering = $0 }
        .onTapGesture { model.openRoute(hostname) }
        .help(ownerHelp(owner, upstream: upstream) ?? "Open \(hostname)")
    }
}

private struct UnclaimedRow: View {
    let port: UnclaimedPort
    let projects: [Project]
    let model: PopoverModel
    var stats: ProcessStats?? = nil

    @State private var hovering = false

    private var candidateDir: String? {
        guard let cwd = port.cwd, isProjectCandidate(cwd) else { return nil }
        return cwd
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                Badge(color: Steel.amber, symbol: "dot.radiowaves.left.and.right")
                VStack(alignment: .leading, spacing: 2) {
                    Text(port.process.map(friendlyName) ?? "pid \(port.pid)")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(candidateDir.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? port.upstream)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Steel.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 8)
                if hovering {
                    IconButton(symbol: "arrow.up.right", help: "Open localhost:\(port.port)") { model.openUnclaimed(port.port) }
                } else {
                    StatusPill(text: ":\(port.port)", color: Steel.amber)
                }
                MoreMenu {
                    Button("Open localhost:\(port.port)") { model.openUnclaimed(port.port) }
                    if let dir = candidateDir, !projects.contains(where: { $0.directory == dir }) {
                        Button("Add \u{201C}\((dir as NSString).lastPathComponent)\u{201D} as Project") {
                            model.addProjectAt(dir)
                        }
                    }
                    if !projects.isEmpty {
                        Menu("Assign to Project") {
                            ForEach(projects) { project in
                                Button(project.name) { model.assign(port.port, project.id) }
                            }
                        }
                    }
                }
            }
            if let stats { StatsLine(stats: stats).padding(.leading, 44) }
        }
        .padding(.vertical, stats == nil ? 0 : 8)
        .rowStyle(hovering: hovering)
        .onHover { hovering = $0 }
        .onTapGesture { model.openUnclaimed(port.port) }
        .help("pid \(port.pid) on \(port.upstream)")
    }
}

private struct StatusRow<Trailing: View>: View {
    let symbol: String
    let title: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(Steel.textSecondary)
                .frame(width: 22)
            Text(title)
                .font(.system(size: 13, weight: .medium))
            Spacer()
            trailing
        }
        .frame(minHeight: 40)
    }
}

/// CPU · GPU · MEM · NET for the process behind a port.
private struct StatsLine: View {
    let stats: ProcessStats?

    var body: some View {
        HStack(spacing: 0) {
            column("CPU", stats?.cpuPercent.map(percent), color: load(stats?.cpuPercent))
                .frame(width: 54, alignment: .leading)
            column("GPU", stats?.gpuPercent.map(percent), color: load(stats?.gpuPercent))
                .frame(width: 54, alignment: .leading)
            column("MEM", stats?.memoryBytes.map(bytes))
                .frame(width: 64, alignment: .leading)
            column("NET", network)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .help("Resource use of the listening process; network is bytes per second in ↓ and out ↑.")
    }

    private func column(_ label: String, _ value: String?, color: Color = Steel.textPrimary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 8.5, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(Steel.textTertiary)
            Text(value ?? "—")
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(value == nil ? Steel.textTertiary : color)
                .lineLimit(1)
        }
    }

    private var network: String? {
        guard let down = stats?.netInPerSecond, let up = stats?.netOutPerSecond else { return nil }
        return "↓\(rate(down)) ↑\(rate(up))"
    }

    /// Ice by default; amber above one busy core, red above two.
    private func load(_ value: Double?) -> Color {
        guard let value else { return Steel.textPrimary }
        return value >= 200 ? Steel.danger : value >= 80 ? Steel.amber : Steel.ice
    }

    private func percent(_ value: Double) -> String {
        value < 10 ? String(format: "%.1f%%", value) : String(format: "%.0f%%", value)
    }

    private func bytes(_ value: UInt64) -> String {
        let mb = Double(value) / 1_048_576
        return mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }

    private func rate(_ bytesPerSecond: Double) -> String {
        switch bytesPerSecond {
        case ..<1: return "0"
        case ..<1024: return String(format: "%.0fB", bytesPerSecond)
        case ..<(1024 * 1024): return String(format: "%.0fK", bytesPerSecond / 1024)
        default: return String(format: "%.1fM", bytesPerSecond / 1_048_576)
        }
    }
}

// MARK: - Building blocks

private struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.horizontal, 12)
            .padding(.vertical, 2)
            .background(SteelPanel())
    }
}

private struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .medium))
            .kerning(0.6)
            .foregroundStyle(Steel.textTertiary)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RowDivider: View {
    var body: some View {
        Rectangle()
            .fill(LinearGradient(
                colors: [.white.opacity(0.02), .white.opacity(0.08), .white.opacity(0.02)],
                startPoint: .leading, endPoint: .trailing
            ))
            .frame(height: 1)
    }
}

private struct Badge: View {
    let color: Color
    var letter: String?
    var symbol: String?
    var dimmed = false

    var body: some View {
        // A steel tile; the colour lives in the glyph.
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        shape
            .fill(LinearGradient(
                colors: [Color(hex: 0x262A31), Color(hex: 0x15171B)],
                startPoint: .top, endPoint: .bottom
            ))
            .overlay(shape.strokeBorder(Steel.edge, lineWidth: 1))
            .frame(width: 32, height: 32)
            .overlay {
                Group {
                    if let letter {
                        Text(letter.uppercased())
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                    } else if let symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 13, weight: .medium))
                    }
                }
                .foregroundStyle(color.opacity(dimmed ? 0.45 : 1))
            }
    }
}

/// A coloured dot and a label: ":5173", "Starting…", "Stopped".
private struct StatusPill: View {
    let text: String
    let color: Color
    /// Colour the label too, for states that need attention.
    var emphasized = false

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundStyle(emphasized ? color : Steel.textSecondary)
        }
        .fixedSize()
    }
}

/// "● Running" in the status colour, for the System tab.
private struct StatusText: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(color)
        }
    }
}

/// Pencil after a project's URL, shown on hover.
private struct RenameButton: View {
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "pencil")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(hovering ? Steel.ice : Steel.textTertiary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Rename URL")
    }
}

/// Small square icon button.
private struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(hovering ? Steel.ice : Steel.textSecondary)
                .frame(width: 26, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(hovering ? 0.08 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Compact bordered button.
private struct SteelButton: View {
    let title: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(hovering ? Steel.ice : Steel.textPrimary)
                .padding(.horizontal, 11)
                .padding(.vertical, 4)
                .background(SteelPanel(cornerRadius: 7, highlighted: hovering))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct MoreMenu<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Menu {
            content
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Steel.textSecondary)
                .frame(width: 22, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

private struct CardButton: View {
    let symbol: String
    let title: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 32)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
            }
            .foregroundStyle(hovering ? Steel.ice : Steel.textSecondary)
            .frame(minHeight: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct FooterButton: View {
    let symbol: String
    let title: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12.5, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 30)
                .foregroundStyle(hovering ? Steel.ice : Steel.textPrimary)
                .background(SteelPanel(cornerRadius: 8, highlighted: hovering))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(Steel.textSecondary)
                .padding(.bottom, 2)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(Steel.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }
}

private extension View {
    func rowStyle(hovering: Bool) -> some View {
        frame(minHeight: 52)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(hovering ? 0.05 : 0))
            )
            .padding(.horizontal, -6)
            .contentShape(Rectangle())
    }
}

// MARK: - Helpers

/// "node · localport run": who serves the route and how it was matched.
private func ownerDetail(_ owner: RouteOwner?, upstream: String?) -> String? {
    guard let owner else { return nil }
    var parts = [owner.process.map(friendlyName) ?? "pid \(owner.pid)"]
    switch owner.source {
    case "claim": parts.append("assigned port")
    case "tag": parts.append("localport run")
    default: break
    }
    return parts.joined(separator: " · ")
}

/// Tooltip with the full detail, e.g. "node (pid 123) on [::1]:5173".
private func ownerHelp(_ owner: RouteOwner?, upstream: String?) -> String? {
    guard let owner, let upstream else { return nil }
    return "\(owner.process ?? "process") (pid \(owner.pid)) on \(upstream)"
}

/// Readable names for helper processes that serve other apps' ports.
func friendlyName(_ process: String) -> String {
    process.hasPrefix("com.docker.") ? "Docker" : process
}

private func portOf(_ upstream: String) -> String? {
    upstream.components(separatedBy: ":").last
}

/// A working directory worth offering as a project: not `/`, the home
/// folder itself, or an app's sandbox container under ~/Library.
private func isProjectCandidate(_ dir: String) -> Bool {
    let home = NSHomeDirectory()
    return dir != "/" && dir != home && !dir.hasPrefix(home + "/Library/")
}
