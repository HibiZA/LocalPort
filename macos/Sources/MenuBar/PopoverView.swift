import SwiftUI

/// What the popover shows, and the actions it can take. Owned by
/// `MenuBarController`, which forwards actions to its delegate.
final class PopoverModel: ObservableObject {
    @Published var state = MenuState()
    @Published var availableUpdate: String?

    var openProject: (String) -> Void = { _ in }
    var openRoute: (String) -> Void = { _ in }
    var copyURL: (String) -> Void = { _ in }
    var reveal: (String) -> Void = { _ in }
    var projectSettings: (String) -> Void = { _ in }
    var openUnclaimed: (Int) -> Void = { _ in }
    var addProjectAt: (String) -> Void = { _ in }
    var assign: (Int, String) -> Void = { _, _ in }
    var addProject: () -> Void = {}
    var preferences: () -> Void = {}
    var openLogs: () -> Void = {}
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
        case .ports: return "antenna.radiowaves.left.and.right"
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
}

struct PopoverView: View {
    @ObservedObject var model: PopoverModel
    @State private var tab: Tab = .projects

    private var state: MenuState { model.state }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            tabBar
            Group {
                switch tab {
                case .projects: projectsTab
                case .ports: portsTab
                case .system: systemTab
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            footer
        }
        .padding(16)
        .frame(width: 360)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            Image(nsImage: MenuBarController.appIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: 56, height: 56)
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
            HStack(spacing: 6) {
                Circle().fill(health.color).frame(width: 7, height: 7)
                Text(health.label)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            if let version = model.availableUpdate {
                Button(action: model.openUpdate) {
                    Label("Update available: v\(version)", systemImage: "arrow.down.circle.fill")
                        .font(.system(size: 11.5, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var health: (label: String, color: Color) {
        guard state.daemonConnected else { return ("Daemon stopped", .red) }
        let tld = state.tld.map { " · .\($0)" } ?? ""
        switch state.proxyState {
        case "running", nil: return ("Running" + tld, .green)
        case "failed": return ("Proxy failed", .red)
        default: return (proxyLabel, .orange)
        }
    }

    // MARK: - Tabs

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(Tab.allCases, id: \.self) { item in
                Button {
                    tab = item
                } label: {
                    Image(systemName: item.symbol)
                        .font(.system(size: 16, weight: .medium))
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .foregroundStyle(tab == item ? Color.accentColor : .secondary)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(tab == item ? Color.accentColor.opacity(0.2) : .clear)
                        )
                        .overlay(alignment: .topTrailing) {
                            if item == .ports && !state.unclaimed.isEmpty {
                                Text("\(state.unclaimed.count)")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 4)
                                    .frame(minWidth: 15, minHeight: 15)
                                    .background(Capsule().fill(Color.accentColor))
                                    .offset(x: -18, y: 3)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(item.title)
            }
        }
        .padding(6)
        .background(CardBackground())
    }

    // MARK: - Projects

    private var projectsTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Projects", detail: state.projects.isEmpty ? nil : "\(state.upstreams.count) of \(state.projects.count) running")
            Card {
                if state.projects.isEmpty {
                    EmptyState(
                        symbol: "shippingbox",
                        title: "No projects yet",
                        message: "Add a project folder and its dev server gets a hostname like myapp.\(state.tld ?? "test")."
                    )
                } else {
                    Scrolling(count: state.projects.count) {
                        ForEach(Array(state.projects.enumerated()), id: \.element.id) { index, project in
                            if index > 0 { RowDivider() }
                            ProjectRow(
                                project: project,
                                upstream: state.upstreams[project.id],
                                owner: state.owners[project.hostname],
                                model: model
                            )
                        }
                    }
                }
                RowDivider()
                CardButton(symbol: "plus", title: "Add Project…", action: model.addProject)
                    .keyboardShortcut("n")
            }
        }
    }

    // MARK: - Ports

    private var portsTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Unclaimed Ports")
            Card {
                if state.unclaimed.isEmpty {
                    EmptyState(
                        symbol: "checkmark.circle",
                        title: "Nothing unclaimed",
                        message: "Every dev server LocalPort can see belongs to a project."
                    )
                } else {
                    Scrolling(count: state.unclaimed.count) {
                        ForEach(Array(state.unclaimed.enumerated()), id: \.element.port) { index, port in
                            if index > 0 { RowDivider() }
                            UnclaimedRow(port: port, projects: state.projects, model: model)
                        }
                    }
                }
            }

            if !state.otherRoutes.isEmpty {
                SectionHeader("Other Routes").padding(.top, 8)
                Card {
                    ForEach(Array(state.otherRoutes.enumerated()), id: \.element.hostname) { index, route in
                        if index > 0 { RowDivider() }
                        RouteRow(
                            hostname: route.hostname,
                            upstream: route.upstream,
                            owner: state.owners[route.hostname],
                            model: model
                        )
                    }
                }
            }
        }
    }

    // MARK: - System

    private var systemTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Status")
            Card {
                StatusRow(symbol: "bolt.horizontal.circle", title: "Daemon") {
                    HStack(spacing: 8) {
                        StatusPill(
                            text: state.daemonConnected ? "Running" : "Stopped",
                            color: state.daemonConnected ? .green : .red
                        )
                        Button(state.daemonConnected ? "Stop" : "Start") {
                            state.daemonConnected ? model.stopDaemon() : model.startDaemon()
                        }
                        .controlSize(.small)
                    }
                }
                RowDivider()
                StatusRow(symbol: "lock.shield", title: "Proxy") {
                    StatusPill(text: proxyLabel, color: health.color)
                }
                if state.proxyState == "failed", let error = state.proxyError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                        .padding(.leading, 34)
                        .padding(.bottom, 6)
                }
                RowDivider()
                StatusRow(symbol: "network", title: "Domain") {
                    Text(state.tld.map { ".\($0)" } ?? "—")
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                RowDivider()
                StatusRow(symbol: "point.3.connected.trianglepath.dotted", title: "Routes") {
                    Text("\(state.upstreams.count + state.otherRoutes.count) active")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
                RowDivider()
                CardButton(symbol: "doc.text.magnifyingglass", title: "Open Logs", action: model.openLogs)
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
        HStack(spacing: 12) {
            FooterButton(symbol: "gearshape", title: "Settings", action: model.preferences)
                .keyboardShortcut(",")
            FooterButton(symbol: "power", title: "Quit", action: model.quit)
                .keyboardShortcut("q")
        }
    }
}

// MARK: - Rows

private struct ProjectRow: View {
    let project: Project
    let upstream: String?
    let owner: RouteOwner?
    let model: PopoverModel

    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(spacing: 12) {
            Badge(color: Color(nsColor: project.color.nsColor), letter: project.name.first.map(String.init) ?? "?")
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(project.hostname)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail = ownerDetail(owner, upstream: upstream) {
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if copied {
                StatusPill(text: "Copied", color: .accentColor)
            } else if let port = upstream.flatMap(portOf) {
                StatusPill(text: ":\(port)", color: .green)
            } else {
                StatusPill(text: "Stopped", color: .secondary)
            }
            MoreMenu {
                Button("Open in Browser") { model.openProject(project.id) }
                Button("Copy URL") { copy() }
                Button("Reveal in Finder") { model.reveal(project.id) }
                Divider()
                Button("Settings…") { model.projectSettings(project.id) }
            }
        }
        .rowStyle(hovering: hovering)
        .onHover { hovering = $0 }
        .onTapGesture { model.openProject(project.id) }
        .help(ownerHelp(owner, upstream: upstream) ?? "Open \(project.hostname)")
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

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Badge(color: .gray, symbol: "arrow.triangle.branch")
            VStack(alignment: .leading, spacing: 2) {
                Text(hostname)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if let detail = ownerDetail(owner, upstream: upstream) {
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let port = portOf(upstream) {
                StatusPill(text: ":\(port)", color: .green)
            }
            MoreMenu {
                Button("Open in Browser") { model.openRoute(hostname) }
                Button("Copy URL") { model.copyURL(hostname) }
            }
        }
        .rowStyle(hovering: hovering)
        .onHover { hovering = $0 }
        .onTapGesture { model.openRoute(hostname) }
    }
}

private struct UnclaimedRow: View {
    let port: UnclaimedPort
    let projects: [Project]
    let model: PopoverModel

    @State private var hovering = false

    private var candidateDir: String? {
        guard let cwd = port.cwd, isProjectCandidate(cwd) else { return nil }
        return cwd
    }

    var body: some View {
        HStack(spacing: 12) {
            Badge(color: .orange, symbol: "dot.radiowaves.left.and.right")
            VStack(alignment: .leading, spacing: 2) {
                Text(port.process.map(friendlyName) ?? "pid \(port.pid)")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(candidateDir.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? port.upstream)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 4)
            StatusPill(text: ":\(port.port)", color: .orange)
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
                .foregroundStyle(.secondary)
                .frame(width: 22)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            trailing
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Building blocks

private struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(CardBackground())
    }
}

private struct CardBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.primary.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            )
    }
}

/// Lists longer than this scroll instead of growing the popover.
private struct Scrolling<Content: View>: View {
    let count: Int
    @ViewBuilder let content: Content

    private static var visibleRows: Int { 6 }

    var body: some View {
        if count > Self.visibleRows {
            ScrollView {
                VStack(spacing: 0) { content }
            }
            .frame(height: CGFloat(Self.visibleRows) * 58)
        } else {
            VStack(spacing: 0) { content }
        }
    }
}

private struct SectionHeader: View {
    let title: String
    var detail: String?
    init(_ title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.6)
            Spacer()
            if let detail {
                Text(detail).font(.system(size: 11))
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }
}

private struct RowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
    }
}

private struct Badge: View {
    let color: Color
    var letter: String?
    var symbol: String?

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(LinearGradient(
                colors: [color.opacity(0.95), color.opacity(0.7)],
                startPoint: .top, endPoint: .bottom
            ))
            .frame(width: 32, height: 32)
            .overlay {
                if let letter {
                    Text(letter.uppercased())
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                } else if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .shadow(color: color.opacity(0.3), radius: 3, y: 1)
    }
}

private struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(color == .secondary ? Color.secondary : color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.15)))
        .fixedSize()
    }
}

private struct MoreMenu<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Menu {
            content
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
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
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 22)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
            }
            .foregroundStyle(hovering ? Color.primary : Color.secondary)
            .padding(.vertical, 10)
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
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.1 : 0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1))
                )
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
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}

private extension View {
    func rowStyle(hovering: Bool) -> some View {
        padding(.vertical, 9)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.06 : 0))
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
private func friendlyName(_ process: String) -> String {
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
