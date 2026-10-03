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
}

// MARK: - SwiftUI View

private struct ProjectSettingsView: View {
    let projectID: String
    let projectTLD: String
    let directory: String

    /// The hostname label the project would get without an override.
    let defaultLabel: String
    /// The hostname label currently in effect (shown initially).
    let currentLabel: String
    /// The project's existing override, kept as-is if the field isn't edited.
    let existingCustomHostname: String?

    @State var name: String
    @State var hostname: String
    @State var port: String
    @State var claimPort: Bool
    @State var selectedColor: String

    var onSave: ((ProjectSettings) -> Void)?
    var onRemove: ((String) -> Void)?
    var onDismiss: (() -> Void)?

    private let colorPalette = [
        "#3B82F6", "#10B981", "#F59E0B", "#EF4444", "#8B5CF6", "#EC4899",
        "#06B6D4", "#84CC16", "#F97316", "#6366F1",
    ]

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    HStack {
                        Text("Name")
                        Spacer()
                        TextField("Project name", text: $name)
                            .multilineTextAlignment(.trailing)
                            .textFieldStyle(.plain)
                    }

                    HStack {
                        Text("Hostname")
                        Spacer()
                        HStack(spacing: 0) {
                            TextField(defaultLabel, text: $hostname)
                                .multilineTextAlignment(.trailing)
                                .textFieldStyle(.plain)
                            Text(".\(projectTLD)")
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack {
                        Text("Port")
                        Spacer()
                        TextField("Auto", text: $port)
                            .multilineTextAlignment(.trailing)
                            .textFieldStyle(.plain)
                    }
                    .help("Route this port when the project listens on several. Leave empty to pick automatically.")

                    if !port.trimmingCharacters(in: .whitespaces).isEmpty {
                        Toggle("Claim this port", isOn: $claimPort)
                            .help("Route this port to the project even when the server runs outside the project folder, e.g. a Docker container.")
                    }

                    if !directory.isEmpty {
                        HStack {
                            Text("Path")
                            Spacer()
                            Text(directory)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }

                Section("Color") {
                    HStack(spacing: 6) {
                        ForEach(colorPalette, id: \.self) { hex in
                            Circle()
                                .fill(Color(nsColor: NSColor(hex: hex)))
                                .frame(width: 22, height: 22)
                                .overlay(
                                    Circle()
                                        .strokeBorder(
                                            Color(nsColor: NSColor(hex: hex)).opacity(0.5),
                                            lineWidth: selectedColor.lowercased() == hex.lowercased() ? 2 : 0
                                        )
                                        .frame(width: 28, height: 28)
                                )
                                .scaleEffect(selectedColor.lowercased() == hex.lowercased() ? 1.1 : 1.0)
                                .onTapGesture {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        selectedColor = hex
                                    }
                                }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            // Bottom bar
            HStack {
                Button("Remove Project", role: .destructive) {
                    onRemove?(projectID)
                }

                Spacer()

                Button("Cancel") {
                    onDismiss?()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    onSave?(ProjectSettings(
                        name: name.isEmpty ? defaultLabel : name,
                        color: selectedColor,
                        customHostname: resolvedCustomHostname(),
                        port: Int(port.trimmingCharacters(in: .whitespaces)).flatMap { (1...65535).contains($0) ? $0 : nil },
                        claimPort: claimPort
                    ))
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .frame(width: 420, height: 410)
        .background(Steel.background)
        .tint(Steel.ice)
        .environment(\.colorScheme, .dark)
    }

    /// Only an *edited* hostname becomes an override, so a hostname that came
    /// from `.localport.toml` keeps following that file.
    private func resolvedCustomHostname() -> String? {
        let label = hostname.trimmingCharacters(in: .whitespaces).lowercased()
        if label.isEmpty || label == defaultLabel { return nil }
        if label == currentLabel { return existingCustomHostname }
        let suffix = "." + projectTLD
        return label.hasSuffix(suffix) ? label : label + suffix
    }
}

// MARK: - AppKit Wrapper (preserves existing API)

final class ProjectSettingsPanel: NSPanel {
    var onSave: ((ProjectSettings) -> Void)?
    var onRemove: ((String) -> Void)?

    init(project: Project, tld: String) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 410),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        title = "Project Settings"
        appearance = NSAppearance(named: .darkAqua)
        level = .floating
        center()

        let suffix = "." + tld
        let editable = project.hostname.hasSuffix(suffix)
            ? String(project.hostname.dropLast(suffix.count))
            : project.hostname

        let settingsView = ProjectSettingsView(
            projectID: project.id,
            projectTLD: tld,
            directory: project.directory,
            defaultLabel: project.slug,
            currentLabel: editable,
            existingCustomHostname: project.customHostname,
            name: project.name,
            hostname: editable,
            port: project.port.map(String.init) ?? "",
            claimPort: project.claimPort,
            selectedColor: project.color.hex,
            onSave: { [weak self] settings in
                self?.onSave?(settings)
                self?.close()
            },
            onRemove: { [weak self] projectID in
                self?.confirmRemove(projectID: projectID)
            },
            onDismiss: { [weak self] in
                self?.close()
            }
        )

        contentView = ClickThroughHostingView(rootView: settingsView)
    }

    private func confirmRemove(projectID: String) {
        let alert = NSAlert()
        alert.messageText = "Remove Project?"
        alert.informativeText = "This will unregister the project from LocalPort. Your files will not be deleted."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: self) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.onRemove?(projectID)
            self?.close()
        }
    }
}
