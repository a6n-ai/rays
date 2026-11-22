import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(EngineModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var destination: Destination? = .downloads
    /// The last sidebar folder, restored on launch the way Apple's apps reopen where you left off.
    @AppStorage("lastFolder") private var lastFolder = ""
    @State private var isDropTargeted = false
    /// Links taken from the current drag. A browser drop can carry both a URL and a String for the same link.
    @State private var droppedLinks = Set<String>()
    @State private var query = ""

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $destination)
                // On the sidebar column (not the split view) so the field doesn't take toolbar space.
                .searchable(text: $query, placement: .sidebar, prompt: "Search")
                .onAppear {
                    let path = lastFolder
                    if path == "sorter" {
                        destination = .sorter
                    } else if !path.isEmpty, FileManager.default.fileExists(atPath: path) {
                        destination = .folder(URL(filePath: path, directoryHint: .isDirectory))
                    }
                }
                .onChange(of: destination) { _, new in
                    switch new {
                    case .folder(let url)?: lastFolder = url.path(percentEncoded: false)
                    case .sorter?: lastFolder = "sorter"
                    default: lastFolder = ""
                    }
                }
        } detail: {
            detail
                .overlay(alignment: .top) { UpdatePill() }
                .animation(reduceMotion ? nil : .smooth, value: Updater.shared.showsPill)
        }
        .containerBackground(.thinMaterial, for: .window)
        .frame(minWidth: 640, idealWidth: 760, minHeight: 440, idealHeight: 520)
        .overlay {
            if isDropTargeted {
                DropPanel()
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(reduceMotion ? nil : .smooth, value: isDropTargeted)
        .dropDestination(for: URL.self) { urls, _ in
            accept(urls.compactMap(Links.fromFile))
        } isTargeted: { setTargeted($0) }
        .dropDestination(for: String.self) { texts, _ in
            accept(texts.flatMap(Links.inText))
        } isTargeted: { setTargeted($0) }
        .task(id: model.generation) { await model.run() }
        .onReceive(NotificationCenter.default.publisher(for: .openSorter)) { _ in destination = .sorter }
    }

    @ViewBuilder private var detail: some View {
        if !trimmedQuery.isEmpty {
            SearchView(query: trimmedQuery) { folder in
                destination = .folder(folder)
                query = ""
            }
        } else {
            Group {
                switch destination {
                case .folder(let folder)?:
                    FolderView(root: EngineModel.downloadsURL, folder: folder) { destination = .downloads }
                case .sorter?:
                    SorterView()
                case .bucket(let name)?:
                    BucketView(bucket: name)
                default:
                    DownloadsView(isDropTargeted: isDropTargeted)
                }
            }
            .id(destination)
            .transition(.opacity)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: destination)
        }
    }

    private func setTargeted(_ targeted: Bool) {
        if targeted { droppedLinks = [] }
        isDropTargeted = targeted
    }

    private func accept(_ links: [String]) -> Bool {
        guard !links.isEmpty else { return false }
        let fresh = links.filter { droppedLinks.insert($0).inserted }
        if !fresh.isEmpty { model.add(fresh.joined(separator: "\n")) }
        return true
    }
}

private struct DownloadsView: View {
    @Environment(EngineModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isDropTargeted: Bool
    @State private var filter = Filter.all
    @State private var selection = Set<UInt64>()
    @State private var removal: [JobView] = []
    /// The sorter moves finished files out of the downloads folder; rows then show where each one went.
    @State private var watcher = DirectoryWatcher()

    private enum Filter: String, CaseIterable, Identifiable {
        case all = "All", active = "Active", finished = "Finished"
        var id: Self { self }
        var symbol: String {
            switch self {
            case .all: "tray.full"
            case .active: "arrow.down.to.line"
            case .finished: "checkmark"
            }
        }
        func matches(_ job: JobView) -> Bool {
            switch self {
            case .all: true
            case .active: !job.isFinished
            case .finished: job.isFinished
            }
        }
    }

    private var visible: [JobView] { model.jobs.filter(filter.matches) }
    private var selectedJobs: [JobView] { model.jobs.filter { selection.contains($0.id) } }

    var body: some View {
        content
            .safeAreaInset(edge: .top) { ExtensionBanner() }
            .safeAreaInset(edge: .bottom) {
                AddBar(isTargeted: isDropTargeted)
                    .disabled(model.startError != nil)
            }
            .navigationTitle("Rays")
            .navigationSubtitle(subtitle)
            .toolbar { toolbar }
            .onAppear { watcher.watch(EngineModel.downloadsURL) { model.foldersChanged() } }
            .onDisappear { watcher.stop() }
            .confirmationDialog(
                removalTitle, isPresented: Binding(get: { !removal.isEmpty }, set: { if !$0 { removal = [] } }),
                titleVisibility: .visible
            ) {
                Button("Remove and Delete Partial Files", role: .destructive) { confirmRemoval(deletePartial: true) }
                Button("Remove and Keep Partial Files") { confirmRemoval(deletePartial: false) }
                Button("Cancel", role: .cancel) {}
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
        } else if model.jobs.isEmpty {
            WelcomeEmpty()
        } else if visible.isEmpty {
            EmptyState(symbol: "tray", title: filter == .active ? "Nothing active" : "Nothing finished")
        } else {
            List(selection: $selection) {
                ForEach(visible, id: \.id) { job in
                    JobRow(job: job)
                        .tag(job.id)
                        .listRowInsets(EdgeInsets(
                            top: LayoutMetrics.rowSpacing / 2,
                            leading: LayoutMetrics.margin - LayoutMetrics.hoverInset,
                            bottom: LayoutMetrics.rowSpacing / 2,
                            trailing: LayoutMetrics.margin - LayoutMetrics.hoverInset))
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .scrollEdgeEffectStyle(.soft, for: .all)
            .animation(reduceMotion ? nil : .smooth, value: visible.map(\.id))
            .onKeyPress(.space) { togglePause() ? .handled : .ignored }
            .onKeyPress(.return) { revealSelected() ? .handled : .ignored }
            .onDeleteCommand(perform: removeSelected)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            ToolbarIconGroup {
                ForEach(Filter.allCases) { item in
                    Button { filter = item } label: {
                        ToolbarIcon(symbol: item.symbol, title: "\(item.rawValue) downloads", selected: filter == item)
                    }
                    .buttonStyle(.plain)
                    .help("\(item.rawValue) downloads")
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

    private var subtitle: String {
        let running = model.jobs.filter { $0.state == .running }
        let paused = model.jobs.filter { $0.state == .paused }.count
        var text = ""
        if !running.isEmpty {
            let speed = running.reduce(UInt64(0)) { $0 + $1.bytesPerSec }
            text = "\(running.count) downloading, \(byteText(speed))/s"
        } else if paused > 0 {
            text = "\(paused) paused"
        } else if !model.jobs.isEmpty && model.jobs.allSatisfy(\.isDone) {
            text = "All done"
        }
        return text
    }

    private var removalTitle: String {
        removal.count == 1 ? "Remove \(removal[0].name)?" : "Remove \(removal.count) downloads?"
    }

    /// Returns false when nothing is selected, so the key press falls through to the list.
    private func togglePause() -> Bool {
        // Pausing a non-resumable download discards its progress, so only the row's Stop button does that.
        let targets = selectedJobs.filter { $0.resumable || $0.state == .paused }
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
        if targets.contains(where: \.hasPartial) {
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
        for job in targets { model.remove(job.id, deletePartial: deletePartial && job.hasPartial) }
        selection = []
    }
}

/// The speed limit, clear and open buttons. Shared by the Downloads list and the folder views.
struct ToolbarActions: View {
    @Environment(EngineModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @AppStorage(SettingsKey.speedLimit) private var speedLimit = 0

    private var hasFinished: Bool { model.jobs.contains(where: \.isDone) }

    var body: some View {
        ToolbarIconGroup {
            Menu {
                speedMenuItems
            } label: {
                ToolbarIcon(
                    symbol: speedLimit > 0 ? "tortoise" : "hare", title: speedLimit > 0 ? "Speed limited" : "No speed limit",
                    tint: speedLimit > 0 ? .orange : .teal)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help(speedLimit > 0 ? "Speed limited to \(SpeedPreset.text(speedLimit))" : "Limit download speed")
            Button(action: clearFinished) {
                ToolbarIcon(symbol: "eraser", title: "Clear finished", tint: hasFinished ? .pink : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(!hasFinished)
            .help("Remove finished downloads from the list. Files stay on disk.")
            Button {
                NSWorkspace.shared.open(EngineModel.downloadsURL)
            } label: {
                ToolbarIcon(symbol: "folder", title: "Open Downloads folder", tint: .blue)
            }
            .buttonStyle(.plain)
            .help("Open the Downloads folder in Finder")
        }
    }

    @ViewBuilder private var speedMenuItems: some View {
        ForEach(SpeedPreset.all) { preset in
            Button {
                model.setSpeedLimit(preset.bytes)
            } label: {
                if preset.bytes == speedLimit {
                    Label(preset.title, systemImage: "checkmark")
                } else {
                    Text(preset.title)
                }
            }
        }
        Divider()
        Button("Settings…") { openSettings() }
    }

    private func clearFinished() {
        for job in model.jobs where job.isDone { model.remove(job.id, deletePartial: false) }
    }
}

/// One glass capsule holding equal-width icon buttons; both toolbar groups use it so they match.
struct ToolbarIconGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 2) { content }
            .padding(3)
            .glassEffect(.regular, in: .capsule)
    }
}

/// Every toolbar glyph: same point size, weight, frame and hover effect, so the two groups line up.
struct ToolbarIcon: View {
    let symbol: String
    let title: String
    var tint: Color = .primary
    var selected = false
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(selected ? Color.accentColor : tint)
            .frame(width: 34, height: 28)
            .background {
                Capsule()
                    .fill(selected ? AnyShapeStyle(.tint.opacity(0.2)) : AnyShapeStyle(.primary.opacity(hovering && isEnabled ? 0.08 : 0)))
            }
            .contentShape(Capsule())
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .smooth(duration: 0.15), value: hovering)
            .accessibilityLabel(title)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct GlassSymbol: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 36))
            .frame(width: 88, height: 88)
            .glassEffect(.regular, in: .circle)
    }
}

private struct EmptyState: View {
    let symbol: String
    let title: String
    var message: String?

    var body: some View {
        VStack(spacing: LayoutMetrics.gap) {
            GlassSymbol(systemName: symbol)
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
            if let message {
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Sits a little above the true centre of the area above the bar, which reads as centred.
        .padding(.bottom, LayoutMetrics.margin)
    }
}

/// Non-blocking: no scrim, and it never takes hits from the drag.
private struct DropPanel: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 48))
            Text("Drop to download")
                .font(.headline)
        }
        .frame(width: 280, height: 160)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .allowsHitTesting(false)
    }
}


/// Round glass gear, the last item of every page's toolbar, mirroring the sidebar toggle on the left.
/// It lives in the content toolbar: in the sidebar's toolbar it fought the sidebar search field for
/// space and rebuilt the toolbar in a loop (100% CPU).
struct SettingsToolbarButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button { openSettings() } label: {
            Label("Settings", systemImage: "gearshape")
        }
        .help("Settings (⌘,)")
    }
}

extension Notification.Name {
    static let focusAddBar = Notification.Name("ai.a6n.rays.focusAddBar")
}

/// First-run / empty Downloads: the three ways to start a download, as glass tiles of equal size.
/// Glass sits only on things you can press; the background stays the window's material.
private struct WelcomeEmpty: View {
    @Environment(\.openSettings) private var openSettings
    @AppStorage("settingsTab") private var settingsTab = "general"
    @Namespace private var glass

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: LayoutMetrics.gap) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
                    .accessibilityHidden(true)
                Text("Ready when you are")
                    .font(.title2.weight(.semibold))
                Text("Add a link and Rays downloads it in parts, resumes if it stops, and files it when it's done.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }

            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    tile("link", .blue, "Paste links", "Any format, ⌘L") {
                        NotificationCenter.default.post(name: .focusAddBar, object: nil)
                    }
                    tile("tray.and.arrow.down", .green, "Drop files", "Links or .webloc", action: nil)
                    tile("puzzlepiece.extension", .purple, "From your browser", "Right-click a link") {
                        settingsTab = "browsers"
                        openSettings()
                    }
                }
            }
        }
        .padding(.horizontal, LayoutMetrics.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, LayoutMetrics.margin)
    }

    @ViewBuilder
    private func tile(_ symbol: String, _ color: Color, _ title: String, _ hint: String,
                      action: (() -> Void)?) -> some View {
        let label = VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(color)
                .frame(height: 26)
            Text(title)
                .font(.callout.weight(.semibold))
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: 140, height: 104)
        .contentShape(RoundedRectangle(cornerRadius: 20))

        if let action {
            Button(action: action) { label }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
                .glassEffectID(title, in: glass)
                .accessibilityLabel("\(title), \(hint)")
        } else {
            // Not a button: dropping works anywhere on the window, this only says so.
            label
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
                .glassEffectID(title, in: glass)
                .accessibilityElement(children: .combine)
        }
    }
}
