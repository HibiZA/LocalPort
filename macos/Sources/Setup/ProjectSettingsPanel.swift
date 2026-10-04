import AppKit
import SwiftUI

struct ProjectSettings {
    var name: String
    var color: String
    /// Full hostname override, or nil to use the default / `.localport.toml`.
    var customHostname: String?
    /// Pinned port, or nil to let LocalPort pick.
    var port: Int?
    /// Route `port` even when the server isn't running in the project folder.
    var claimPort: Bool
    /// Command that starts the dev server, or nil to use the detected one.
    var startCommand: String?
}

/// What the panel shows about the project's live state and the other
/// projects, as of when it opened.
struct ProjectSettingsContext {
    var tld: String
    /// "127.0.0.1:5173" while the project's server runs.
    var upstream: String?
    var owner: RouteOwner?
    /// hostname -> who uses it, excluding this project.
    var taken: [String: String] = [:]
}

// MARK: - SwiftUI View

private struct ProjectSettingsView: View {
    let project: Project
    let context: ProjectSettingsContext

    @State var name: String
    @State var hostname: String
    @State var port: String
    @State var claimPort: Bool
    @State var selectedColor: String
    @State var startCommand: String
    /// What Start runs when `startCommand` is empty.
    let detectedCommand: String?

    var onSave: ((ProjectSettings) -> Void)?
    var onRemove: (() -> Void)?
    var onDismiss: (() -> Void)?

    private let colorPalette = [
        "#3B82F6", "#10B981", "#F59E0B", "#EF4444", "#8B5CF6", "#EC4899",
        "#06B6D4", "#84CC16", "#F97316", "#6366F1",
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                generalSection
                urlSection
                devServerSection
                routingSection
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            footer
        }
        .frame(width: 460, height: 780)
        .background(Steel.background)
        .tint(Steel.ice)
        .environment(\.colorScheme, .dark)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            let color = Color(nsColor: NSColor(hex: selectedColor))
            Text(displayName.first.map { String($0).uppercased() } ?? "?")
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
                .frame(width: 46, height: 46)
                .background(SteelPanel(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 3) {
                Text(displayName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Steel.textPrimary)
                    .lineLimit(1)
                Text(previewHostname)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(hostnameProblem == nil ? Steel.ice : Steel.danger)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 5) {
                    Circle()
                        .fill(running ? Steel.ice : Steel.textTertiary)
                        .frame(width: 6, height: 6)
                    Text(statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(Steel.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 4)
    }

    private var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? project.slug : trimmed
    }

    private var running: Bool { context.upstream != nil }

    private var statusText: String {
        guard let upstream = context.upstream else { return "Not running" }
        var text = "Running on \(upstream)"
        if let process = context.owner?.process { text += " · \(friendlyName(process))" }
        return text
    }

    // MARK: General

    private var generalSection: some View {
        Section("General") {
            TextField("Name", text: $name, prompt: Text(project.slug))
            LabeledContent("Color") {
                HStack(spacing: 4) {
                    ForEach(colorPalette, id: \.self) { hex in
                        swatch(hex)
                    }
                }
            }
            LabeledContent("Folder") {
                HStack(spacing: 6) {
                    Text((project.directory as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Steel.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(project.directory)
                    FolderButton(symbol: "folder", help: "Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.directory)])
                    }
                    if let editor {
                        FolderButton(symbol: "chevron.left.forwardslash.chevron.right", help: "Open in \(editor.name)") {
                            AppSettings.open(directory: project.directory, in: editor)
                        }
                    }
                }
            }
        }
    }

    private var editor: AppSettings.App? { AppSettings.preferredEditor(in: AppSettings.installedEditors()) }

    private func swatch(_ hex: String) -> some View {
        let selected = selectedColor.lowercased() == hex.lowercased()
        let color = Color(nsColor: NSColor(hex: hex))
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { selectedColor = hex }
        } label: {
            Circle()
                .fill(color)
                .frame(width: 16, height: 16)
                .padding(3)
                .overlay(Circle().strokeBorder(selected ? color : .clear, lineWidth: 1.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(hex)
    }

    // MARK: URL

    private var urlSection: some View {
        Section {
            LabeledContent("Hostname") {
                HStack(spacing: 0) {
                    TextField("Hostname", text: $hostname, prompt: Text(project.slug))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .onChange(of: hostname) { value in
                            let clean = HostnameLabel.sanitize(value)
                            if clean != value { hostname = clean }
                        }
                    Text(".\(context.tld)")
                        .foregroundStyle(Steel.textTertiary)
                }
                .font(.system(size: 12.5, design: .monospaced))
            }
        } header: {
            Text("URL")
        } footer: {
            HStack(alignment: .firstTextBaseline) {
                Caption(text: hostnameProblem ?? "Leave empty for the default, \(project.slug).\(context.tld).")
                    .foregroundStyle(hostnameProblem == nil ? Steel.textTertiary : Steel.danger)
                Spacer()
                if !hostname.isEmpty && hostname != project.slug {
                    Button("Use Default") { hostname = "" }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Steel.ice)
                }
            }
        }
    }

    private var previewHostname: String {
        (hostname.isEmpty ? project.slug : hostname) + "." + context.tld
    }

    private var hostnameProblem: String? {
        if let problem = HostnameLabel.problem(hostname) { return problem }
        if previewHostname != project.hostname, let user = context.taken[previewHostname] {
            return "\(previewHostname) is already used by \(user)."
        }
        return nil
    }

    // MARK: Routing

    private var routingSection: some View {
        Section {
            LabeledContent("Port") {
                TextField("Port", text: $port, prompt: Text("Automatic"))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 12.5, design: .monospaced))
                    .onChange(of: port) { value in
                        let digits = String(value.filter(\.isNumber).prefix(5))
                        if digits != value { port = digits }
                    }
            }
            Toggle(isOn: $claimPort) {
                Text("Route this port from any process")
                Text("For servers outside the project folder, such as a Docker container.")
            }
            .disabled(port.isEmpty)
        } header: {
            Text("Routing")
        } footer: {
            Caption(text: portProblem ?? portHint)
                .foregroundStyle(portProblem == nil ? Steel.textTertiary : Steel.danger)
        }
    }

    private var portValue: Int? { Int(port) }

    private var portProblem: String? {
        guard !port.isEmpty else { return nil }
        guard let value = portValue, (1...65535).contains(value) else { return "Enter a port from 1 to 65535." }
        return nil
    }

    private var portHint: String {
        port.isEmpty
            ? "LocalPort routes the dev server it finds in the folder. Set a port if there are several."
            : "LocalPort routes port \(port) to \(previewHostname)."
    }

    // MARK: Dev server

    private var devServerSection: some View {
        Section {
            LabeledContent("Start command") {
                TextField("Start command", text: $startCommand, prompt: Text(detectedCommand ?? "npm run dev"))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 12.5, design: .monospaced))
            }
        } header: {
            Text("Dev server")
        } footer: {
            Caption(text: devServerHint)
                .foregroundStyle(Steel.textTertiary)
        }
    }

    private var devServerHint: String {
        let base = "Start it from the menu bar. It runs in the project folder with your shell's PATH."
        guard trimmedStartCommand.isEmpty else { return base }
        if let detectedCommand {
            return base + " Leave empty to use \(detectedCommand), from the project's files."
        }
        return base + " Enter the command your project uses."
    }

    private var trimmedStartCommand: String { startCommand.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button(role: .destructive) {
                onRemove?()
            } label: {
                Label("Remove Project…", systemImage: "trash")
                    .foregroundStyle(Steel.danger)
            }
            .buttonStyle(.borderless)

            Spacer()

            Button("Cancel") { onDismiss?() }
                .keyboardShortcut(.cancelAction)

            Button("Save", action: save)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Steel.iceDeep)
                .disabled(hostnameProblem != nil || portProblem != nil)
        }
        .padding(.horizontal, 24)
        .padding(.top, 4)
        .padding(.bottom, 18)
    }

    private func save() {
        onSave?(ProjectSettings(
            name: displayName,
            color: selectedColor,
            customHostname: HostnameLabel.customHostname(for: hostname, project: project, tld: context.tld),
            port: portValue,
            claimPort: claimPort && portValue != nil,
            startCommand: trimmedStartCommand.isEmpty ? nil : trimmedStartCommand
        ))
    }
}

/// Small icon button next to the folder path.
private struct FolderButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovering ? Steel.ice : Steel.textSecondary)
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(hovering ? 0.10 : 0.05))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

private struct Caption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - AppKit Wrapper

final class ProjectSettingsPanel: NSPanel {
    var onSave: ((ProjectSettings) -> Void)?
    var onRemove: ((String) -> Void)?

    private let project: Project

    init(project: Project, context: ProjectSettingsContext) {
        self.project = project
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 780),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        title = "\(project.name) — Project Settings"
        appearance = NSAppearance(named: .darkAqua)
        level = .floating
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        center()

        let settingsView = ProjectSettingsView(
            project: project,
            context: context,
            name: project.name,
            hostname: HostnameLabel.editable(project.hostname, tld: context.tld),
            port: project.port.map(String.init) ?? "",
            claimPort: project.claimPort,
            selectedColor: project.color.hex,
            startCommand: project.startCommand ?? "",
            detectedCommand: StartCommand.detect(in: project.directory),
            onSave: { [weak self] settings in
                self?.onSave?(settings)
                self?.close()
            },
            onRemove: { [weak self] in
                self?.confirmRemove()
            },
            onDismiss: { [weak self] in
                self?.close()
            }
        )

        contentView = ClickThroughHostingView(rootView: settingsView)
    }

    private func confirmRemove() {
        let alert = NSAlert()
        alert.messageText = "Remove \(project.name)?"
        alert.informativeText = "LocalPort stops routing \(project.hostname). Your files are not deleted."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true

        alert.beginSheetModal(for: self) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.onRemove?(self.project.id)
            self.close()
        }
    }
}
