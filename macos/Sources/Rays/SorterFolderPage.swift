import AppKit
import SwiftUI

struct SorterFolderPage: View {
    let model: SorterModel
    let path: String

    @Environment(\.dismiss) private var dismiss
    @State private var confirmingRemoval = false

    private static let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .indigo]

    var body: some View {
        if let folder = model.status?.folders.first(where: { $0.path == path }) {
            page(folder)
        }
    }

    private func page(_ folder: SorterFolder) -> some View {
        let readiness = AIReadiness.current()
        let categories = model.status?.categories ?? []
        return Form {
            if let error = model.error {
                Section { ErrorLine(text: error) }
            }

            Section {
                Toggle("Watching", isOn: Binding(
                    get: { folder.watching },
                    set: { on in Task { await model.setWatching(folder, on: on) } }))
                    .toggleStyle(.switch)
                    .disabled(model.busy || model.loadFailed)
                if folder.needsUpdate {
                    HStack {
                        Label("Old copy — needs update", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Update") { Task { await model.update(folder) } }
                            .disabled(model.busy)
                    }
                }
            }

            Section {
                Button("Sort Now") { Task { await model.sortNow(folder) } }
                    .disabled(model.busy || model.loadFailed || !readiness.isReady)
                    .help(readiness.isReady ? "Sort new files in this folder now" : readiness.title)
                if let result = model.sortResults[folder.path] {
                    Text(result)
                        .foregroundStyle(.secondary)
                }
                Button("Show in Finder") { NSWorkspace.shared.open(URL(filePath: folder.path)) }
            } footer: {
                if !readiness.isReady {
                    Text(readiness.title)
                }
            }

            Section {
                ForEach(Array(categories.enumerated()), id: \.element.id) { index, category in
                    CategoryRow(model: model, folder: folder, category: category,
                                color: Self.colors[index % Self.colors.count])
                }
            } header: {
                Text("Where files go")
            } footer: {
                Text("Files stay inside \(folder.name) unless you choose another folder.")
            }

            Section {
                Button(role: .destructive) {
                    confirmingRemoval = true
                } label: {
                    Text("Remove Folder…")
                        .frame(maxWidth: .infinity)
                }
                .disabled(model.busy)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .navigationTitle(folder.name)
        .toolbar { ToolbarItem(placement: .primaryAction) { SettingsToolbarButton() } }
        .confirmationDialog(
            "Stop sorting \(folder.name)?",
            isPresented: $confirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove Folder", role: .destructive) {
                Task {
                    await model.remove(folder)
                    if model.error == nil { dismiss() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Rays stops sorting this folder. Files already sorted stay where they are.")
        }
    }
}

private struct CategoryRow: View {
    let model: SorterModel
    let folder: SorterFolder
    let category: SorterCategory
    let color: Color

    var body: some View {
        let custom = model.destination(for: folder, category: category.name)
        HStack(spacing: 10) {
            SettingIcon(symbol: "folder.fill", color: color)
            VStack(alignment: .leading, spacing: 2) {
                Text(category.name)
                Text(category.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(custom.map { URL(filePath: $0).tildePath } ?? "Inside \(folder.name)")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(custom ?? folder.path)
            Button("Change…", action: chooseDestination)
                .disabled(model.busy)
            if custom != nil {
                Button("Reset") { Task { await model.resetDestination(folder, category: category.name) } }
                    .disabled(model.busy)
            }
        }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.setDestination(folder, category: category.name, path: url.path(percentEncoded: false)) }
    }
}
