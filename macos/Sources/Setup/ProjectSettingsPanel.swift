import AppKit
import SwiftUI

struct ProjectSettings {
    var name: String
    var color: String
    var hostname: String
}

// MARK: - SwiftUI View

private struct ProjectSettingsView: View {
    let projectID: String
    let projectTLD: String
    let directory: String

    @State var name: String
    @State var hostname: String
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
                            TextField("hostname", text: $hostname)
                                .multilineTextAlignment(.trailing)
                                .textFieldStyle(.plain)
                            Text(".\(projectTLD)")
                                .foregroundStyle(.secondary)
                        }
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
                    let fullHostname = hostname.isEmpty
                        ? name + "." + projectTLD
                        : hostname + "." + projectTLD
                    onSave?(ProjectSettings(
                        name: name,
                        color: selectedColor,
                        hostname: fullHostname
                    ))
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .frame(width: 420, height: 340)
    }
}

// MARK: - AppKit Wrapper (preserves existing API)

final class ProjectSettingsPanel: NSPanel {
    var onSave: ((ProjectSettings) -> Void)?
    var onRemove: ((String) -> Void)?

    init(project: Project) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        title = "Project Settings"
        level = .floating
        center()

        let lastComponent = project.hostname.components(separatedBy: ".").last ?? "test"
        let tld = lastComponent.isEmpty ? "test" : lastComponent
        let editable = project.hostname.components(separatedBy: ".").first ?? project.hostname

        let settingsView = ProjectSettingsView(
            projectID: project.id,
            projectTLD: tld,
            directory: project.directory,
            name: project.name,
            hostname: editable,
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

        contentView = NSHostingView(rootView: settingsView)
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
