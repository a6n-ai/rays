import AppKit
import SwiftUI

struct SorterFolderPage: View {
    let model: SorterModel
    let path: String

    @Environment(\.dismiss) private var dismiss
    @State private var confirmingRemoval = false
    @AppStorage("sorterShowDestinations") private var showDestinations = false

    static let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .indigo]

    var body: some View {
        if let folder = model.status?.folders.first(where: { $0.path == path }) {
            page(folder)
        }
    }

    private func page(_ folder: SorterFolder) -> some View {
        let readiness = AIReadinessStore.shared.value
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

            if model.sortResults[folder.path] != nil || !readiness.isReady {
                Section {
                    if let result = model.sortResults[folder.path] {
                        Label(result, systemImage: "wand.and.stars").foregroundStyle(.secondary)
                    }
                    if !readiness.isReady {
                        Label(readiness.title, systemImage: readiness.symbol).foregroundStyle(.secondary)
                    }
                }
            }

            Section(isExpanded: $showDestinations) {
                ForEach(Array(categories.enumerated()), id: \.element.id) { index, category in
                    CategoryRow(model: model, folder: folder, category: category,
                                color: Self.colors[index % Self.colors.count])
                }
                Text("Files stay inside \(folder.name) unless you choose another folder.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Where files go")
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
        .toolbar {
            ToolbarItem(placement: .principal) {
                ToolbarIconGroup {
                    Button { Task { await model.sortNow(folder) } } label: {
                        ToolbarIcon(symbol: "wand.and.stars", title: "Sort now",
                                    tint: readiness.isReady ? .purple : .secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.busy || model.loadFailed || !readiness.isReady)
                    .help(readiness.isReady ? "Sort new files in \(folder.name) now" : readiness.title)
                    Button { NSWorkspace.shared.open(URL(filePath: folder.path)) } label: {
                        ToolbarIcon(symbol: "folder", title: "Show in Finder", tint: .blue)
                    }
                    .buttonStyle(.plain)
                    .help("Show \(folder.name) in Finder")
                    Button { Task { await model.refresh() } } label: {
                        ToolbarIcon(symbol: "arrow.clockwise", title: "Refresh")
                    }
                    .buttonStyle(.plain)
                    .help("Check this folder again")
                }
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .primaryAction) { SettingsToolbarButton() }
        }
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
        let target = URL(filePath: custom ?? URL(filePath: folder.path).appending(path: category.name).path)
        Menu {
            Button("Choose Folder…", systemImage: "folder.badge.plus", action: chooseDestination)
            if custom != nil {
                Button("Use Inside \(folder.name)", systemImage: "arrow.uturn.backward") {
                    Task { await model.resetDestination(folder, category: category.name) }
                }
            }
            Divider()
            Button("Show in Finder", systemImage: "magnifyingglass") {
                NSWorkspace.shared.activateFileViewerSelecting([target])
            }
            .disabled(!FileManager.default.fileExists(atPath: target.path))
        } label: {
            HStack(spacing: 10) {
                SettingIcon(symbol: "folder.fill", color: color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(category.name)
                        .foregroundStyle(.primary)
                    Text(custom.map { URL(filePath: $0).tildePath } ?? "Inside \(folder.name)")
                        .font(.callout)
                        .foregroundStyle(custom == nil ? .secondary : Color.accentColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(model.busy)
        .help(category.description)
        .accessibilityLabel("\(category.name), \(custom.map { URL(filePath: $0).tildePath } ?? "inside \(folder.name)")")
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


/// The Sorter's Files tab: each sorter folder with its category folders. A row opens the folder as
/// its own page (Files-app style).
struct SorterFilesSections: View {
    let model: SorterModel

    var body: some View {
        let folders = model.status?.folders ?? []
        let categories = model.status?.categories ?? []
        if folders.isEmpty {
            Section { Text("Add a folder in Setup to see sorted files here.").foregroundStyle(.secondary) }
        }
        ForEach(folders) { folder in
            Section(folder.name) {
                let dirs = categories.compactMap { category -> (String, URL)? in
                    let url = URL(filePath: model.destination(for: folder, category: category.name)
                                  ?? URL(filePath: folder.path).appending(path: category.name).path)
                    return FileManager.default.fileExists(atPath: url.path) ? (category.name, url) : nil
                }
                if dirs.isEmpty {
                    Text("Nothing sorted yet.").foregroundStyle(.secondary)
                }
                ForEach(Array(dirs.enumerated()), id: \.element.1) { index, item in
                    NavigationLink(value: item.1) {
                        CategoryFolderRow(url: item.1, title: item.0,
                                          color: SorterFolderPage.colors[index % SorterFolderPage.colors.count])
                    }
                }
            }
        }
    }
}

private struct CategoryFolderRow: View {
    let url: URL
    let title: String
    let color: Color
    @State private var count: Int?

    var body: some View {
        HStack(spacing: 10) {
            SettingIcon(symbol: "folder.fill", color: color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(url.tildePath)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let count {
                Text(count == 1 ? "1 item" : "\(count) items")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .task {
            let folder = url
            count = await Task.detached { SortedItem.list(folder).count }.value
        }
    }
}
