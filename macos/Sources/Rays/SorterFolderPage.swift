import AppKit
import SwiftUI

struct SorterFolderPage: View {
    let model: SorterModel
    let path: String

    @Environment(NavHistory.self) private var nav
    @State private var confirmingRemoval = false
    @AppStorage("sorterShowDestinations") private var showDestinations = false

    static let colors: [Color] = [TilePalette.blue, TilePalette.green, TilePalette.orange, TilePalette.purple, TilePalette.pink, TilePalette.teal, TilePalette.indigo]

    var body: some View {
        if let folder = model.status?.folders.first(where: { $0.path == path }) {
            page(folder)
        }
    }

    private func page(_ folder: SorterFolder) -> some View {
        let readiness = AIReadinessStore.shared.value
        let categories = model.status?.categories ?? []
        return Form {
            Section {
                HeroCard(.folder, title: folder.name, subtitle: URL(filePath: folder.path).tildePath) {
                    HeroActions {
                        Button("Sort Now") { Task { await model.sortNow(folder) } }
                            .disabled(model.busy || model.loadFailed || !readiness.isReady)
                            .help(readiness.isReady ? "Sort new files in \(folder.name) now" : readiness.title)
                        Button("Show in Finder") { NSWorkspace.shared.open(URL(filePath: folder.path)) }
                            .help("Show \(folder.name) in Finder")
                        HeroMenu {
                            Button("Refresh") { Task { await model.refresh() } }
                        }
                    }
                }
            }
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
        .confirmationDialog(
            "Stop sorting \(folder.name)?",
            isPresented: $confirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove Folder", role: .destructive) {
                Task {
                    await model.remove(folder)
                    if model.error == nil { nav.replaceSub(nil) }
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
                IconTile(Tile(symbol: "folder.fill", color: color))
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


/// The Sorter's Files tab: the sorter's folders (Documents, Downloads…) in a Finder-style list.
/// Opening one shows its contents in the same browser.
struct SorterFilesTable: View {
    let model: SorterModel

    @Environment(NavHistory.self) private var nav
    @AppStorage("sortedBrowserLayout") private var layout: SortedLayout = .finderDefault
    @State private var items: [SortedItem] = []

    var body: some View {
        SortedItemsView(items: items, layout: layout) { nav.open("sorted:" + $0.path(percentEncoded: false)) }
            .overlay {
                if items.isEmpty {
                    ContentUnavailableView("No folders yet", systemImage: "folder",
                                           description: Text("Add a folder in Setup to see its sorted files here."))
                }
            }
            .task(id: model.status?.folders.map(\.path)) {
                let paths = (model.status?.folders ?? []).map { URL(filePath: $0.path) }
                items = await Task.detached {
                    paths.filter { FileManager.default.fileExists(atPath: $0.path) }.map(SortedItem.item)
                }.value
            }
    }
}
