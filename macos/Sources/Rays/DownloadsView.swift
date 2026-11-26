import AppKit
import SwiftUI

struct DownloadsView: View {
    @Environment(EngineModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isDropTargeted: Bool
    /// nil is every download; a queue id shows only that queue, with its header.
    var queue: UInt64? = nil
    @AppStorage("downloadsSection") private var section = DownloadsSection.recent
    @State private var status = "All"
    @State private var kind = FileKind.all
    @State private var sort = ListSort.newest
    @State private var page = 0
    @AppStorage(Paging.key) private var pageSize = Paging.defaultSize
    @State private var selection = Set<UInt64>()
    @State private var removal: [JobView] = []
    /// The sorter moves finished files out of the downloads folder; rows then show where each one went.
    @State private var watcher = DirectoryWatcher()

    @State private var sorter = SorterModel()

    /// The same two pages on every view: recent activity, then the files. A stored "settings" falls back to recent.
    enum DownloadsSection: String { case recent, files }

    private var inQueue: [JobView] { model.jobs.filter { queue == nil || $0.queueId == queue } }
    private var queueView: QueueView? { model.queues.first { $0.id == queue } }
    private var matching: [JobView] { inQueue.listed(status: status, kind: kind, sort: sort) }

    private var visible: [JobView] { Array(ListControls.page(matching, page, pageSize)) }
    private var selectedJobs: [JobView] { model.jobs.filter { selection.contains($0.id) } }

    var body: some View {
        pageView(queue == nil ? section : .recent)
            .safeAreaInset(edge: .top) { ExtensionBanner() }
            .safeAreaInset(edge: .bottom) {
                AddBar(isTargeted: isDropTargeted, defaultQueue: queue ?? 0)
                    .disabled(model.startError != nil)
            }
            .navigationTitle(queueView?.config.name ?? "Rays")
            .navigationSubtitle(subtitle)
            .toolbar { toolbar }
            .onAppear { watcher.watch(EngineModel.downloadsURL) { model.foldersChanged() } }
            .onDisappear { watcher.stop() }
            .confirmationDialog(
                removalTitle, isPresented: Binding(get: { !removal.isEmpty }, set: { if !$0 { removal = [] } }),
                titleVisibility: .visible
            ) {
                if removal.contains(where: \.isDone) {
                    Button("Remove and Move Files to Trash", role: .destructive) {
                        model.removeAndTrash(removal)
                        removal = []
                        selection = []
                    }
                }
                if removal.contains(where: \.hasPartial) {
                    Button("Remove and Delete Partial Files", role: .destructive) { confirmRemoval(deletePartial: true) }
                }
                Button(removal.contains(where: \.hasPartial) ? "Remove and Keep Partial Files" : "Remove from List") {
                    confirmRemoval(deletePartial: false)
                }
                Button("Cancel", role: .cancel) {}
            }
    }

    @ViewBuilder private func pageView(_ section: DownloadsSection) -> some View {
        switch section {
        case .recent:
            content.safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    if !model.jobs.isEmpty && model.startError == nil {
                        ListControls(statuses: JobView.statuses, status: $status, kind: $kind, sort: $sort,
                                     count: matching.count, page: $page, part: .paging)
                    }
                }
            }
        case .files:
            FolderView(root: EngineModel.downloadsURL, folder: EngineModel.downloadsURL, embedded: true) {}
        }
    }

    @ViewBuilder private var content: some View {
        if let error = model.startError {
            ContentUnavailableView {
                Label { Text("Engine didn't start") } icon: { GlassSymbol(systemName: "exclamationmark.triangle") }
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { model.restart() }
            }
        } else if queue != nil && visible.isEmpty {
            if inQueue.isEmpty {
                EmptyState(symbol: "tray", title: "No downloads in this queue",
                           message: "Use Move to Queue on a download, or pick this queue when you add one.")
            } else {
                EmptyState(symbol: "tray", title: "No downloads match")
            }
        } else {
            // Selection is drawn by the rows (CardRowBackground), not List(selection:), whose highlight is always the accent blue.
            List {
                if queue == nil {
                    Section {
                        HeroCard(.downloads, title: "Downloads", subtitle: subtitle.isEmpty ? "Everything you download, in one place." : subtitle,
                                 learnMore: URL(string: "https://rays.a6n.ai/docs/app/downloads/"))
                            .cardRow(.only)
                    }
                    CollapsibleSettingsCard(page: "downloads", summary: "Save folder, notifications, limits") {
                        settingsRow(SaveFolderRow(sorter: sorter), .middle)
                        settingsRow(CopiedLinksRow(), .middle)
                        settingsRow(NotifyRow(), .middle)
                        settingsRow(MaxRunningRow(), .middle)
                        settingsRow(PartsRow(), .middle)
                        settingsRow(SpeedLimitRow(), .middle)
                        settingsRow(UnpackSettingsRows(), .middle)
                        settingsRow(ReplaceExistingRow(), .last)
                    }
                }
                Section {
                    if visible.isEmpty {
                        emptyRow
                    } else {
                        ForEach(Array(visible.enumerated()), id: \.element.id) { index, job in
                            JobRow(job: job, isSelected: selection.contains(job.id),
                                   position: CardRowBackground.position(index, of: visible.count))
                                .contentShape(Rectangle())
                                .onTapGesture { select(job.id) }
                        }
                    }
                } header: {
                    if !model.jobs.isEmpty && model.startError == nil {
                        HStack {
                            Text("Recent downloads")
                            Spacer()
                            ListControls(statuses: JobView.statuses, status: $status, kind: $kind, sort: $sort,
                                         count: matching.count, page: $page, removeMissing: {
                                for job in model.jobs where job.isDone && model.locate(job) == nil {
                                    model.remove(job.id, deletePartial: false)
                                }
                            }, part: .menus)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .tint(.gray)
            .scrollContentBackground(.hidden)
            .scrollEdgeEffectStyle(.soft, for: .all)
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { step(-1) }
            .onKeyPress(.downArrow) { step(1) }
            .onKeyPress(.space) { togglePause() ? .handled : .ignored }
            .onKeyPress(.return) { revealSelected() ? .handled : .ignored }
            .onDeleteCommand(perform: removeSelected)
        }
    }

    private func settingsRow(_ row: some View, _ position: CardRowBackground.Position) -> some View {
        row.padding(.vertical, 6).cardRow(position, separatorInset: TileSize.row + 10)
    }

    /// Plain text, not the glass empty states: this sits in a List row.
    private var emptyRow: some View {
        Text(model.jobs.isEmpty ? "No downloads yet. Paste a link below, or press ⌘L." : "No downloads match")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 120)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if queue == nil {
            ToolbarItem(placement: .principal) {
                ToolbarIconGroup {
                    ForEach([(DownloadsSection.recent, "clock.arrow.circlepath", "Recent downloads"),
                             (DownloadsSection.files, "folder", "Downloads folder")], id: \.0) { item in
                        Button { section = item.0 } label: {
                            ToolbarIcon(symbol: item.1, title: item.2, selected: section == item.0)
                        }
                        .buttonStyle(.plain)
                        .help(item.2)
                        .accessibilityAddTraits(section == item.0 ? .isSelected : [])
                    }
                }
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .primaryAction) {
                ToolbarActions()
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .primaryAction) { SettingsToolbarButton() }
        }
    }

    private var subtitle: String {
        let running = inQueue.filter { $0.state == .running }
        let paused = inQueue.filter { $0.state == .paused }.count
        var text = ""
        if !running.isEmpty {
            let speed = running.reduce(UInt64(0)) { $0 + $1.bytesPerSec }
            text = "\(running.count) downloading, \(byteText(speed))/s"
        } else if paused > 0 {
            text = "\(paused) paused"
        } else if !inQueue.isEmpty && inQueue.allSatisfy(\.isDone) {
            text = "All done"
        }
        return text
    }

    private var removalTitle: String {
        removal.count == 1 ? "Remove \(removal[0].name)?" : "Remove \(removal.count) downloads?"
    }

    /// Click selects one row; ⌘-click adds or removes it, like a native list.
    private func select(_ id: UInt64) {
        if NSEvent.modifierFlags.contains(.command) {
            if selection.remove(id) == nil { selection.insert(id) }
        } else {
            selection = [id]
        }
    }

    private func step(_ delta: Int) -> KeyPress.Result {
        let ids = visible.map(\.id)
        guard !ids.isEmpty else { return .ignored }
        let current = ids.lastIndex(where: selection.contains) ?? (delta > 0 ? -1 : ids.count)
        selection = [ids[min(max(current + delta, 0), ids.count - 1)]]
        return .handled
    }

    /// Returns false when nothing is selected, so the key press falls through to the list.
    private func togglePause() -> Bool {
        // Pausing a non-resumable download discards its progress, so only the row's Stop button does that.
        let targets = selectedJobs.filter { $0.state != .verifying && ($0.resumable || $0.state == .paused) }
        guard !targets.isEmpty else { return false }
        for job in targets {
            if job.state == .paused {
                model.resume(job.id)
            } else {
                model.pause(job.id)
            }
        }
        return true
    }

    private func revealSelected() -> Bool {
        guard let job = selectedJobs.first(where: \.isDone) else { return false }
        model.reveal(job)
        return true
    }

    private func removeSelected() {
        let targets = selectedJobs
        guard !targets.isEmpty else { return }
        // Finished files and partials both have something on disk, so ask what to do with it.
        if targets.contains(where: { $0.hasPartial || $0.isDone }) {
            removal = targets
        } else {
            remove(targets, deletePartial: false)
        }
    }

    private func confirmRemoval(deletePartial: Bool) {
        remove(removal, deletePartial: deletePartial)
        removal = []
    }

    private func remove(_ targets: [JobView], deletePartial: Bool) {
        if deletePartial {
            for job in targets { model.remove(job.id, deletePartial: job.hasPartial) }
        } else {
            model.removeUndoable(targets)
        }
        selection = []
    }
}
