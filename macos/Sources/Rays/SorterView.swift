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

enum SorterTab: String { case files, recent }

struct SorterView: View {
    @State private var model: SorterModel

    @State private var confirmRemoveAll = false
    @AppStorage("sorterTab") private var tab: SorterTab = .recent
    @AppStorage("sortedBrowserLayout") private var layout: SortedLayout = .finderDefault
    @State private var removing: SorterFolder?
    @State private var recentKind = FileKind.all
    @State private var recentSort = ListSort.newest
    @State private var recentPage = 0
    @AppStorage(Paging.key) private var pageSize = Paging.defaultSize
    @State private var recentSelection: Int?
    /// Moves removed from the list, one key per line. Kept in the app so the sorter's log stays untouched.
    @AppStorage("sorterHiddenMoves") private var hiddenMoves = ""
    private var allRecent: [SorterMove] {
        let hidden = Set(hiddenMoves.split(separator: "\n").map(String.init))
        return (model.status?.recent ?? []).filter { !hidden.contains($0.key) }
    }
    /// The sorter's recent moves, filtered by kind and sorted.
    private var recentMoves: [SorterMove] {
        let moves = allRecent.filter { recentKind.matches($0.file) }
        return switch recentSort {
        case .oldest: moves.sorted { $0.time < $1.time }
        case .name: moves.sorted { $0.file.localizedStandardCompare($1.file) == .orderedAscending }
        default: moves.sorted { $0.time > $1.time }
        }
    }

    private var outdated: [SorterFolder] { (model.status?.folders ?? []).filter(\.needsUpdate) }

    @MainActor init(model: SorterModel? = nil) {
        _model = State(initialValue: model ?? SorterModel())
    }

    private static let docs = URL(string: "https://rays.a6n.ai/docs/app/sorter/")!
    private static let cardInsets = EdgeInsets(top: 4, leading: LayoutMetrics.margin - 4, bottom: 4,
                                               trailing: LayoutMetrics.margin - 4)

    private var recentList: some View {
        let moves = recentMoves
        let shown = ListControls.page(moves, recentPage, pageSize)
        let folderRows = folderRows
        return List {
            Section {
                HeroCard(.sorter, title: "Sorter",
                         subtitle: "Rays files new downloads into folders by what is inside them, using on-device AI.",
                         learnMore: Self.docs)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(Self.cardInsets)
            }
            if let error = model.error {
                Section { ErrorLine(text: error).listRowBackground(Color.clear) }
            }
            if model.loadFailed {
                Section { ErrorLine(text: SorterModel.unavailableMessage).listRowBackground(Color.clear) }
            }
            CollapsibleSettingsCard(page: "sorter") {
                AIStatusRow().cardRow(.first)
                SortDelayRow(sorter: model).cardRow(.middle)
                RenameRow(sorter: model).cardRow(.last)
            }
            Section("Watched folders") {
                ForEach(Array(folderRows.enumerated()), id: \.element.id) { index, kind in
                    folderRow(kind)
                        .cardRow(CardRowBackground.position(index, of: folderRows.count))
                }
            }
            Section("Recently sorted") {
                if moves.isEmpty {
                    Text(allRecent.isEmpty ? "Nothing sorted yet" : "No sorted files match")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: LayoutMetrics.cardListRowHeight)
                        .cardRow(.only)
                } else {
                    ForEach(Array(shown.enumerated()), id: \.offset) { index, move in
                        MoveRow(move: move, position: CardRowBackground.position(index, of: shown.count),
                                isSelected: recentSelection == index) { hide([move]) }
                            .contentShape(Rectangle())
                            .onTapGesture { recentSelection = index }
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .scrollEdgeEffectStyle(.soft, for: .all)
        .safeAreaInset(edge: .top, spacing: 0) {
            if !allRecent.isEmpty {
                ListControls(status: .constant(""), kind: $recentKind, sorts: [.newest, .oldest, .name],
                             sort: $recentSort, count: moves.count, page: $recentPage) {
                    hide(allRecent.filter { !FileManager.default.fileExists(atPath: $0.to) })
                }
            }
        }
    }

    private enum FolderRowKind: Identifiable {
        case tempWarning, update, empty, folder(SorterFolder), add, quick(URL), removeAll

        var id: String {
            switch self {
            case .tempWarning: "temp"
            case .update: "update"
            case .empty: "empty"
            case .folder(let folder): "f:" + folder.path
            case .add: "add"
            case .quick(let url): "q:" + url.path(percentEncoded: false)
            case .removeAll: "removeAll"
            }
        }
    }

    private var folderRows: [FolderRowKind] {
        let folders = model.status?.folders ?? []
        var rows: [FolderRowKind] = []
        if Sorter.isTemporary(Bundle.main.bundlePath) {
            rows.append(.tempWarning)
        } else if !outdated.isEmpty {
            rows.append(.update)
        }
        rows += folders.map(FolderRowKind.folder)
        if folders.isEmpty { rows.append(.empty) }
        rows.append(.add)
        rows += quickFolders.map(FolderRowKind.quick)
        if !folders.isEmpty { rows.append(.removeAll) }
        return rows
    }

    @ViewBuilder private func folderRow(_ kind: FolderRowKind) -> some View {
        switch kind {
        case .tempWarning:
            HStack(alignment: .top, spacing: 10) {
                IconTile(.warning, size: TileSize.list)
                Text("Move Rays to Applications, then open it from there. Folders watched from this copy stop sorting when it goes away.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 8)
        case .update:
            UpdateAllRow(count: outdated.count, busy: model.busy) {
                Task { for folder in outdated { await model.update(folder) } }
            }
            .padding(.vertical, 8)
        case .empty:
            Text("No folders yet.").foregroundStyle(.secondary).frame(minHeight: LayoutMetrics.cardListRowHeight)
        case .folder(let folder):
            NavigationLink(value: folder.path) {
                CardRow(title: folder.name,
                        subtitle: folder.needsUpdate ? "Old copy, needs update" : folder.watching ? "Sorting new files" : "Paused",
                        status: folder.needsUpdate ? .warning : folder.watching ? .ok : .off) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: folder.path)).resizable().accessibilityHidden(true)
                } trailing: {
                    rowIcon("wand.and.stars", "Sort \(folder.name) now",
                            tint: AIReadinessStore.shared.value.isReady ? .purple : .secondary) {
                        Task { await model.sortNow(folder) }
                    }
                    .disabled(model.busy || !AIReadinessStore.shared.value.isReady)
                    rowIcon("folder", "Show \(folder.name) in Finder", tint: .blue) {
                        NSWorkspace.shared.open(URL(filePath: folder.path))
                    }
                    rowIcon("trash", "Remove \(folder.name) from the sorter", tint: .red) { removing = folder }
                    CardChevron()
                }
            }
        case .add:
            addRow("Add Folder…", action: chooseFolder).disabled(model.busy || model.loadFailed)
        case .quick(let url):
            addRow("Add \(url.lastPathComponent)") { Task { await model.addFolder(url.path(percentEncoded: false)) } }
                .disabled(model.busy)
        case .removeAll:
            Button(role: .destructive) { confirmRemoveAll = true } label: {
                Text("Remove Sorter…").frame(maxWidth: .infinity, minHeight: LayoutMetrics.cardListRowHeight)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .disabled(model.busy)
        }
    }

    private func addRow(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            CardRow(title: title) {
                Image(systemName: "plus.circle.fill").font(.title2).foregroundStyle(.tint).accessibilityHidden(true)
            }
        }
        .buttonStyle(.plain)
    }

    /// Only keys still in the sorter's recent list are kept, so the stored set can't grow forever.
    private func hide(_ moves: [SorterMove]) {
        let current = Set((model.status?.recent ?? []).map(\.key))
        var hidden = Set(hiddenMoves.split(separator: "\n").map(String.init)).intersection(current)
        hidden.formUnion(moves.map(\.key))
        hiddenMoves = hidden.sorted().joined(separator: "\n")
        recentSelection = nil
    }

    private var watchedCount: Int { model.status?.folders.filter(\.watching).count ?? 0 }

    var body: some View {
        NavigationStack {
            Group {
                if tab == .files { SorterFilesTable(model: model) } else { recentList }
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
            .confirmationDialog("Remove the sorter from all folders?", isPresented: $confirmRemoveAll,
                                titleVisibility: .visible) {
                Button("Remove Sorter", role: .destructive) {
                    Task { for folder in model.status?.folders ?? [] { await model.remove(folder) } }
                }
                Button("Cancel", role: .cancel) {}
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
                        ForEach([(SorterTab.recent, "clock.arrow.circlepath", "Sorter"),
                                 (SorterTab.files, "folder", "Sorted files")], id: \.0) { item in
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

private struct MoveRow: View {
    let move: SorterMove
    var position: CardRowBackground.Position = .middle
    var isSelected = false
    var onRemove: () -> Void = {}
    @State private var isHovered = false
    private static let relative = RelativeDateTimeFormatter()

    var body: some View {
        HStack(alignment: .center, spacing: LayoutMetrics.gap) {
            Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: URL(filePath: move.file).pathExtension) ?? .data))
                .resizable()
                .frame(width: LayoutMetrics.iconSize, height: LayoutMetrics.iconSize)
                .overlay(alignment: .bottomTrailing) {
                    if exists {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .green)
                            .font(.system(size: 14))
                    }
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(move.file)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(move.file)
                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Image(systemName: exists ? "folder" : "questionmark.folder").font(.system(size: 12))
                        Text(exists ? placeText : "Moved or deleted since").truncationMode(.middle)
                    }
                    // A static string: `Text(date, style: .relative)` redraws every second, which keeps the CPU awake.
                    Text(Self.relative.localizedString(for: Date(timeIntervalSince1970: move.time), relativeTo: .now))
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if exists {
            Button(action: revert) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: LayoutMetrics.rowHitArea, height: LayoutMetrics.rowHitArea)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .opacity(isHovered ? 1 : 0)
            .help("Move back to \(URL(filePath: move.from).lastPathComponent)")
            .accessibilityLabel("Move \(move.file) back")
            ShareLink(item: url) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: LayoutMetrics.rowHitArea, height: LayoutMetrics.rowHitArea)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .opacity(isHovered ? 1 : 0)
            .help("Share or AirDrop \(move.file)")
            .accessibilityLabel("Share \(move.file)")
            }
            Menu { menu } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: LayoutMetrics.rowHitArea, height: LayoutMetrics.rowHitArea)
                    .contentShape(Circle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(isHovered ? 1 : 0)
            .help("More actions")
            .accessibilityLabel("More actions for \(move.file)")
            if exists {
                // The recommended action, always visible, as on a finished download.
                Button(action: reveal) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.blue)
                        .frame(width: LayoutMetrics.rowAction, height: LayoutMetrics.rowAction)
                        .glassEffect(.regular, in: .circle)
                        .frame(width: LayoutMetrics.rowHitArea, height: LayoutMetrics.rowHitArea)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Show \(move.file) in Finder")
                .accessibilityLabel("Show \(move.file) in Finder")
            } else {
                // Gone since it was sorted: the only useful action left, as on a missing download.
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: LayoutMetrics.rowAction, height: LayoutMetrics.rowAction)
                        .glassEffect(.regular, in: .circle)
                        .frame(width: LayoutMetrics.rowHitArea, height: LayoutMetrics.rowHitArea)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Remove \(move.file) from the list")
                .accessibilityLabel("Remove \(move.file) from the list")
            }
        }
        .frame(minHeight: LayoutMetrics.cardListRowHeight)
        .cardRow(position, selected: isSelected, hovered: isHovered, separatorInset: LayoutMetrics.iconSize + LayoutMetrics.gap)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        // Simultaneous, so the parent's single-click selection still fires.
        .simultaneousGesture(TapGesture(count: 2).onEnded(open))
        .contextMenu { menu }
        .help("Double-click to open")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Open", open)
        .accessibilityAction(named: "Show in Finder", reveal)
        .accessibilityAction(named: "Move Back", revert)
    }

    @ViewBuilder private var menu: some View {
        if exists { fileActions }
        Button(role: .destructive, action: onRemove) { Label("Remove from List", systemImage: "minus.circle") }
    }

    @ViewBuilder private var fileActions: some View {
        Button(action: open) { Label("Open", systemImage: "arrow.up.forward.app") }
        Button(action: reveal) { Label("Show in Finder", systemImage: "folder") }
        Button {
            NSSharingService(named: .sendViaAirDrop)?.perform(withItems: [url])
        } label: {
            Label("AirDrop", systemImage: "dot.radiowaves.up.forward")
        }
        ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") }
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.path(percentEncoded: false), forType: .string)
        } label: {
            Label("Copy Path", systemImage: "doc.on.doc")
        }
        Divider()
        Button(action: revert) { Label("Move Back", systemImage: "arrow.uturn.backward") }
        Divider()
    }

    /// "Work › Invoices" when the file went inside the folder it came from, otherwise the full path.
    private var placeText: String {
        let base = move.from.hasSuffix("/") ? move.from : move.from + "/"
        guard move.to.hasPrefix(base) else { return URL(filePath: move.to).tildePath }
        return move.to.dropFirst(base.count).split(separator: "/").joined(separator: " › ")
    }

    /// `to` is the full new path; the sorter may have renamed the file, so never append `file` to it.
    private var url: URL { URL(filePath: move.to) }

    private var exists: Bool { FileManager.default.fileExists(atPath: move.to) }

    private func open() { NSWorkspace.shared.open(url) }

    private func reveal() { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    /// Back under its original name. The sorter won't take it again: it skips files born before its last run.
    private func revert() {
        let back = URL(filePath: move.from).appending(path: move.file)
        do {
            try FileManager.default.moveItem(at: url, to: back)
            NSWorkspace.shared.activateFileViewerSelecting([back])
        } catch {
            NSAlert(error: error).runModal()
        }
    }
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
            IconTile(.warning)
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

private extension SorterMove {
    /// Stable across status reloads: a move is one file landing at one path at one time.
    var key: String { "\(Int(time))|\(to)" }
}
