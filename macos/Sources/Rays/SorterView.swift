import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension SorterFolder {
    /// The agent runs a sorter that isn't inside an installed Rays: an older standalone copy, a deleted
    /// app, or a DMG or temporary copy. Another installed Rays (the same app at a different path) is fine.
    var needsUpdate: Bool {
        guard let agent = agentBinary else { return false }
        let url = URL(filePath: agent).resolvingSymlinksInPath()
        if url == URL(filePath: Sorter.defaultPath).resolvingSymlinksInPath() { return false }
        if Sorter.isTemporary(url.path(percentEncoded: false)) { return true }
        let app = url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let installed = app.pathExtension == "app"
            && Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier
            && FileManager.default.isExecutableFile(atPath: url.path(percentEncoded: false))
        return !installed
    }
}

enum SorterTab: String { case setup, files, recent }

struct SorterView: View {
    @State private var model: SorterModel

    @State private var confirmRemoveAll = false
    @AppStorage("sorterTab") private var tab: SorterTab = .setup
    @AppStorage("sortedBrowserLayout") private var layout: SortedLayout = .finderDefault
    @AppStorage("sorterShowFolders") private var showFolders = true
    @State private var removing: SorterFolder?
    private var outdated: [SorterFolder] { (model.status?.folders ?? []).filter(\.needsUpdate) }

    @MainActor init(model: SorterModel? = nil) {
        _model = State(initialValue: model ?? SorterModel())
    }

    private var watchedCount: Int { model.status?.folders.filter(\.watching).count ?? 0 }

    var body: some View {
        NavigationStack {
            Group {
            if tab == .files {
                SorterFilesTable(model: model)
            } else {
            Form {
                if tab == .setup {
                    if let error = model.error {
                        Section { ErrorLine(text: error) }
                    }
                    if model.loadFailed {
                        Section { ErrorLine(text: SorterModel.unavailableMessage) }
                    }

                    Section("On-device AI") {
                        AIStatusRow()
                    }

                    Section {
                        Picker(selection: Binding(get: { model.status?.waitSeconds ?? 10 },
                                                  set: { secs in Task { await model.setWait(secs) } })) {
                            ForEach(SorterModel.waitChoices, id: \.seconds) { Text($0.title).tag($0.seconds) }
                        } label: {
                            Label("Sort new files after", systemImage: "timer")
                        }
                        .pickerStyle(.menu)
                        .disabled(model.busy || model.loadFailed)
                    } footer: {
                        Text("Rays waits this long after a file arrives, so you can open or move it first.")
                    }

                    Section {
                        Toggle(isOn: Binding(get: { model.status?.renameFiles ?? true },
                                             set: { on in Task { await model.setRename(on) } })) {
                            Label("Rename files from their content", systemImage: "character.cursor.ibeam")
                        }
                        .toggleStyle(.switch)
                        .disabled(model.busy || model.loadFailed)
                    } footer: {
                        Text("Off keeps every file's original name. Files are still sorted into folders.")
                    }

                    if Sorter.isTemporary(Bundle.main.bundlePath) {
                        Section {
                            Label("Move Rays to Applications, then open it from there. Folders watched from this copy stop sorting when it goes away.",
                                  systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    } else if !outdated.isEmpty {
                        Section {
                            UpdateAllRow(count: outdated.count, busy: model.busy) {
                                Task { for folder in outdated { await model.update(folder) } }
                            }
                        }
                    }
                    Section(isExpanded: $showFolders) {
                        ForEach(model.status?.folders ?? []) { folder in
                            NavigationLink(value: folder.path) {
                                HStack {
                                    FolderRow(folder: folder)
                                    Spacer(minLength: 8)
                                    rowIcon("wand.and.stars", "Sort \(folderName(folder)) now",
                                            tint: AIReadinessStore.shared.value.isReady ? .purple : .secondary) {
                                        Task { await model.sortNow(folder) }
                                    }
                                    .disabled(model.busy || !AIReadinessStore.shared.value.isReady)
                                    rowIcon("folder", "Show \(folderName(folder)) in Finder", tint: .blue) {
                                        NSWorkspace.shared.open(URL(filePath: folder.path))
                                    }
                                    rowIcon("trash", "Remove \(folderName(folder)) from the sorter", tint: .red) {
                                        removing = folder
                                    }
                                }
                            }
                        }
                        if model.status?.folders.isEmpty == true {
                            Text("No folders yet.").foregroundStyle(.secondary)
                        }
                        Button(action: chooseFolder) {
                            Label("Add Folder…", systemImage: "plus.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                        .disabled(model.busy || model.loadFailed)
                        ForEach(quickFolders, id: \.self) { url in
                            Button { Task { await model.addFolder(url.path(percentEncoded: false)) } } label: {
                                Label("Add \(url.lastPathComponent)", systemImage: "plus.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tint)
                            .disabled(model.busy)
                        }
                    } header: {
                        Text("Folders")
                    }

                    if !(model.status?.folders ?? []).isEmpty {
                        Section {
                            Button(role: .destructive) { confirmRemoveAll = true } label: {
                                Text("Remove Sorter…").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                            .disabled(model.busy)
                            .confirmationDialog("Remove the sorter from all folders?", isPresented: $confirmRemoveAll,
                                                titleVisibility: .visible) {
                                Button("Remove Sorter", role: .destructive) {
                                    Task { for folder in model.status?.folders ?? [] { await model.remove(folder) } }
                                }
                                Button("Cancel", role: .cancel) {}
                            } message: {
                                Text("Files already sorted stay where they are.")
                            }
                        }
                    }
                } else if tab == .recent {
                Section("Recent activity") {
                    let moves = model.status?.recent ?? []
                    if moves.isEmpty {
                        Text("Nothing sorted yet.").foregroundStyle(.secondary)
                    }
                    ForEach(Array(moves.prefix(10).enumerated()), id: \.offset) { _, move in
                        MoveRow(move: move)
                    }
                }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            }
            }
            .confirmationDialog("Remove \(removing.map { URL(filePath: $0.path).lastPathComponent } ?? "this folder") from the sorter?",
                                isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                                titleVisibility: .visible) {
                Button("Remove Folder", role: .destructive) {
                    if let folder = removing { Task { await model.remove(folder) } }
                    removing = nil
                }
                Button("Cancel", role: .cancel) { removing = nil }
            } message: {
                Text("Files already sorted stay where they are.")
            }
            .scrollContentBackground(.hidden)
            // Same title and toolbar skeleton as Downloads, so switching pages doesn't jump.
            .navigationTitle("Rays")
            .navigationSubtitle(watchedCount == 1 ? "Sorter: 1 folder watched" : "Sorter: \(watchedCount) folders watched")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    ToolbarIconGroup {
                        ForEach([(SorterTab.setup, "slider.horizontal.3", "Setup"),
                                 (SorterTab.files, "folder", "Sorted files"),
                                 (SorterTab.recent, "clock.arrow.circlepath", "Recently sorted")], id: \.0) { item in
                            Button { tab = item.0 } label: {
                                ToolbarIcon(symbol: item.1, title: item.2, selected: tab == item.0)
                            }
                            .buttonStyle(.plain)
                            .help(item.2)
                            .accessibilityAddTraits(tab == item.0 ? .isSelected : [])
                        }
                    }
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .primaryAction) {
                    ToolbarIconGroup {
                        Button(action: chooseFolder) {
                            ToolbarIcon(symbol: "folder.badge.plus", title: "Add folder")
                        }
                        .buttonStyle(.plain)
                        .help("Add a folder to sort")
                        Button { Task { await sortAll() } } label: {
                            ToolbarIcon(symbol: "wand.and.stars", title: "Sort all now",
                                        tint: AIReadinessStore.shared.value.isReady ? .purple : .secondary)
                        }
                        .buttonStyle(.plain)
                        .disabled(model.busy || !AIReadinessStore.shared.value.isReady)
                        .help(AIReadinessStore.shared.value.isReady ? "Sort new files in every watched folder now" : AIReadinessStore.shared.value.title)
                        if tab == .files {
                            Button { layout = layout == .table ? .icons : .table } label: {
                                ToolbarIcon(symbol: layout == .table ? "square.grid.2x2" : "list.bullet",
                                            title: layout == .table ? "Show as icons" : "Show as list")
                            }
                            .buttonStyle(.plain)
                            .help(layout == .table ? "Show as icons" : "Show as list")
                        }
                        Button { Task { await model.refresh() } } label: {
                            ToolbarIcon(symbol: "arrow.clockwise", title: "Refresh")
                        }
                        .buttonStyle(.plain)
                        .help("Check folders and recent activity again")
                    }
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .primaryAction) { SettingsToolbarButton() }
            }
            .navigationDestination(for: URL.self) { url in SortedBrowserPage(folder: url) }
            .navigationDestination(for: String.self) { path in
                SorterFolderPage(model: model, path: path)
            }
            .task {
                while !Task.isCancelled {
                    await model.refresh()
                    try? await Task.sleep(for: .seconds(30))
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await model.refresh() }
            }
        }
    }

    /// Desktop, Documents and Downloads, minus any already in the list.
    private var quickFolders: [URL] {
        guard let folders = model.status?.folders else { return [] }
        let home = FileManager.default.homeDirectoryForCurrentUser
        // Compare plain paths: a directory URL's trailing slash would otherwise make equal folders differ.
        func key(_ url: URL) -> String {
            let path = url.standardizedFileURL.path(percentEncoded: false)
            return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        }
        let watched = Set(folders.map { key(URL(filePath: $0.path)) })
        return [home.appending(path: "Desktop"), home.appending(path: "Documents"), EngineModel.downloadsURL]
            .filter { !watched.contains(key($0)) }
    }

    private func folderName(_ folder: SorterFolder) -> String { URL(filePath: folder.path).lastPathComponent }

    /// Small borderless icon button inside a list row; borderless so the click doesn't open the row.
    private func rowIcon(_ symbol: String, _ label: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }

    private func sortAll() async {
        for folder in model.status?.folders ?? [] where folder.watching {
            await model.sortNow(folder)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Add Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.addFolder(url.path(percentEncoded: false)) }
    }
}

private struct FolderRow: View {
    let folder: SorterFolder

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: folder.path))
                .resizable()
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name)
                if folder.needsUpdate {
                    Label("Old copy — needs update", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                } else {
                    Text(folder.watching ? "Sorting new files" : "Paused")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct MoveRow: View {
    let move: SorterMove
    private static let relative = RelativeDateTimeFormatter()

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: URL(filePath: move.file).pathExtension) ?? .data))
                .resizable()
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(move.file)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("→ \(placeText)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            // A static string: `Text(date, style: .relative)` redraws every second, which keeps the CPU awake.
            Text(Self.relative.localizedString(for: Date(timeIntervalSince1970: move.time), relativeTo: .now))
                .font(.callout)
                .foregroundStyle(.secondary)
            Button(action: reveal) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.blue)
                    .frame(width: 26, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
            .accessibilityLabel("Show \(move.file) in Finder")
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .help("Click to open")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Open", open)
        .accessibilityAction(named: "Show in Finder", reveal)
    }

    /// "Work › Invoices" when the file went inside the folder it came from, otherwise the full path.
    private var placeText: String {
        let base = move.from.hasSuffix("/") ? move.from : move.from + "/"
        guard move.to.hasPrefix(base) else { return URL(filePath: move.to).tildePath }
        return move.to.dropFirst(base.count).split(separator: "/").joined(separator: " › ")
    }

    private var url: URL { URL(filePath: move.to).appending(path: move.file) }

    private func open() { NSWorkspace.shared.open(url) }

    private func reveal() { NSWorkspace.shared.activateFileViewerSelecting([url]) }
}

#if DEBUG
private let sorterFixture = """
{
  "folders": [
    { "path": "/Users/me/Downloads", "watching": true, "label": "local.sorter",
      "agent_binary": "/Applications/Rays.app/Contents/MacOS/sorter" },
    { "path": "/Users/me/Desktop", "watching": false, "label": "local.sorter.desktop", "agent_binary": null }
  ],
  "categories": [
    { "name": "Work", "description": "Invoices, reports and contracts." },
    { "name": "Personal", "description": "Photos, receipts and travel." }
  ],
  "recent": [
    { "time": 1763300000, "file": "report.pdf", "from": "/Users/me/Downloads", "to": "/Users/me/Downloads/Work/Invoices" }
  ]
}
"""

#Preview {
    SorterView(model: .preview(sorterFixture))
        .frame(width: 640, height: 480)
}
#endif


/// Explains what "old copy" means and switches every outdated folder to the bundled sorter at once.
private struct UpdateAllRow: View {
    let count: Int
    let busy: Bool
    let updateAll: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SettingIcon(symbol: "exclamationmark.triangle.fill", color: .orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(count == 1 ? "1 folder needs an update" : "\(count) folders need an update")
                    .font(.callout.weight(.semibold))
                Text("Switch to the sorter built into Rays. Nothing is moved.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Update All", action: updateAll)
                .buttonStyle(.glassProminent)
                .disabled(busy)
        }
        .accessibilityElement(children: .combine)
    }
}
