import AppKit
import SwiftUI

struct SorterFolderPage: View {
    let model: SorterModel
    let path: String

    @Environment(\.dismiss) private var dismiss
    @State private var confirmingRemoval = false
    @AppStorage("sorterShowDestinations") private var showDestinations = false
    @AppStorage("sorterShowSorted") private var showSorted = true

    private static let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .indigo]

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

            Section(isExpanded: $showSorted) {
                let dirs = categories.map { category in
                    (category.name, URL(filePath: model.destination(for: folder, category: category.name)
                                         ?? URL(filePath: folder.path).appending(path: category.name).path))
                }.filter { FileManager.default.fileExists(atPath: $0.1.path) }
                if dirs.isEmpty {
                    Text("Nothing sorted yet.").foregroundStyle(.secondary)
                }
                ForEach(dirs, id: \.1) { name, url in
                    SortedFolderRow(url: url, title: name)
                }
            } header: {
                Text("Sorted files")
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


/// A sorted folder that opens and closes in place. Its contents are read when it first opens,
/// off the main thread; files open on click, subfolders nest.
private struct SortedFolderRow: View {
    let url: URL
    var title: String? = nil

    @State private var expanded = false
    @State private var entries: [URL]?

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if let entries {
                if entries.isEmpty {
                    Text("Empty").foregroundStyle(.secondary)
                }
                ForEach(entries, id: \.self) { entry in
                    if entry.hasDirectoryPath {
                        SortedFolderRow(url: entry)
                    } else {
                        SortedFileRow(url: entry)
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
        } label: {
            Label(title ?? url.lastPathComponent, systemImage: "folder")
        }
        .task(id: expanded) {
            guard expanded, entries == nil else { return }
            let folder = url
            entries = await Task.detached { Self.list(folder) }.value
        }
    }

    nonisolated private static func list(_ folder: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        // Folders first, then files, each by name.
        return items.sorted {
            ($0.hasDirectoryPath ? 0 : 1, $0.lastPathComponent.localizedLowercase)
                < ($1.hasDirectoryPath ? 0 : 1, $1.lastPathComponent.localizedLowercase)
        }
    }
}

private struct SortedFileRow: View {
    let url: URL

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
            Text(url.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.blue)
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
            .accessibilityLabel("Show \(url.lastPathComponent) in Finder")
        }
        .contentShape(Rectangle())
        .onTapGesture { NSWorkspace.shared.open(url) }
        .help("Click to open")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Open") { NSWorkspace.shared.open(url) }
    }
}
