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


/// The Sorter's Files tab as a Finder-style table: every category folder of every sorter folder.
/// Double-click opens the folder as its own page.
struct SorterFilesTable: View {
    let model: SorterModel

    struct Row: Identifiable {
        let url: URL
        let name: String
        let parent: String
        let count: Int
        let modified: Date
        var id: URL { url }
    }

    @State private var rows: [Row] = []
    @State private var order = [KeyPathComparator(\Row.parent, comparator: .localizedStandard)]
    @State private var selection = Set<URL>()
    @State private var pushed: URL?

    var body: some View {
        Table(rows.sorted(using: order), selection: $selection, sortOrder: $order) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { row in
                HStack(spacing: 6) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: row.url.path))
                        .resizable().frame(width: 16, height: 16).accessibilityHidden(true)
                    Text(row.name)
                }
            }
            .width(min: 140, ideal: 200)
            TableColumn("In", value: \.parent, comparator: .localizedStandard) { row in
                Text(row.parent).foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 120)
            TableColumn("Items", value: \.count) { row in
                Text("\(row.count)").foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 50, ideal: 60)
            TableColumn("Date Modified", value: \.modified) { row in
                Text(row.modified.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 120, ideal: 160)
        }
        .contextMenu(forSelectionType: URL.self) { _ in } primaryAction: { ids in pushed = ids.first }
        .scrollContentBackground(.hidden)
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView("Nothing sorted yet", systemImage: "folder",
                                       description: Text("Sorted folders show up here once files are filed."))
            }
        }
        .navigationDestination(item: $pushed) { SortedBrowserPage(folder: $0) }
        .task(id: model.status) { await load() }
    }

    private func load() async {
        let folders = model.status?.folders ?? []
        let categories = model.status?.categories ?? []
        let targets: [(URL, String, String)] = folders.flatMap { folder in
            categories.map { category in
                (URL(filePath: model.destination(for: folder, category: category.name)
                     ?? URL(filePath: folder.path).appending(path: category.name).path), category.name, folder.name)
            }
        }
        rows = await Task.detached {
            targets.compactMap { url, name, parent -> Row? in
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return Row(url: url, name: name, parent: parent, count: SortedItem.list(url).count, modified: modified)
            }
        }.value
    }
}
