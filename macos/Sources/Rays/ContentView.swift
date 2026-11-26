import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(EngineModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var destination: Destination? = .downloads
    /// The last sidebar folder, restored on launch the way Apple's apps reopen where you left off.
    @AppStorage("lastFolder") private var lastFolder = ""
    @State private var isDropTargeted = false
    @State private var drafts = QueueDrafts()
    /// Links taken from the current drag. A browser drop can carry both a URL and a String for the same link.
    @State private var droppedLinks = Set<String>()
    @State private var query = ""

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        @Bindable var bound = model
        return NavigationSplitView {
            SidebarView(selection: $destination)
                // On the sidebar column (not the split view) so the field doesn't take toolbar space.
                .searchable(text: $query, placement: .sidebar, prompt: "Search")
                .onAppear {
                    let path = lastFolder
                    if path == "sorter" {
                        destination = .sorter
                    } else if path == "cloud" {
                        destination = .cloud
                    } else if path == "schedules" {
                        destination = .schedules
                    } else if path == "queues" {
                        destination = .queues
                    } else if path == "speed" {
                        destination = .speed
                    } else if path == "models" {
                        destination = .models
                    } else if !path.isEmpty, FileManager.default.fileExists(atPath: path) {
                        destination = .folder(URL(filePath: path, directoryHint: .isDirectory))
                    }
                }
                .onChange(of: model.pendingAdd) { _, new in if new != nil { destination = .downloads } }
                .onChange(of: model.requestedDestination) { _, new in
                    guard let new else { return }
                    destination = new
                    model.requestedDestination = nil
                }
                .onChange(of: destination) { _, new in
                    switch new {
                    case .folder(let url)?: lastFolder = url.path(percentEncoded: false)
                    case .sorter?: lastFolder = "sorter"
                    case .cloud?: lastFolder = "cloud"
                    case .models?: lastFolder = "models"
                    case .queues?: lastFolder = "queues"
                    case .schedules?: lastFolder = "schedules"
                    case .speed?: lastFolder = "speed"
                    default: lastFolder = ""
                    }
                }
        } detail: {
            detail
                .overlay(alignment: .top) { UpdatePill() }
                .overlay(alignment: .top) { CountdownBanner() }
                .animation(reduceMotion ? nil : .smooth, value: Updater.shared.showsPill)
                .animation(reduceMotion ? nil : .smooth, value: QueueActions.shared.countdown != nil)
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
        .task(id: model.generation) {
            while !Task.isCancelled {
                model.refreshSpeed()
                try? await Task.sleep(for: .seconds(30 * 60))
            }
        }
        .confirmationDialog(model.confirmTestTitle,
                            isPresented: $bound.confirmHotspot, titleVisibility: .visible) {
            Button("Run Test") { Task { await model.runSpeedTest(force: true) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Let Rays test your speed a few times each night for a week? About 1 GB in total.",
               isPresented: $bound.nightPromptShown) {
            Button("Allow") { model.answerNightPrompt(allow: true) }
            Button("Not Now", role: .cancel) { model.answerNightPrompt(allow: false) }
        }
        .onChange(of: model.queues.map(\.config)) { drafts.reconcile(model.queues) }
        .onReceive(NotificationCenter.default.publisher(for: .openSorter)) { _ in destination = .sorter }
        .onReceive(NotificationCenter.default.publisher(for: .openCloud)) { _ in destination = .cloud }
        .onReceive(NotificationCenter.default.publisher(for: .openDownloads)) { _ in destination = .downloads }
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
                case .cloud?:
                    CloudView()
                case .models?:
                    ModelsView()
                case .speed?:
                    SpeedPage()
                case .schedules?:
                    SchedulesPage(isDropTargeted: isDropTargeted, drafts: drafts)
                case .queues?:
                    QueuesPage(isDropTargeted: isDropTargeted, drafts: drafts)
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

struct GlassSymbol: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 36))
            .frame(width: 88, height: 88)
            .glassEffect(.regular, in: .circle)
    }
}

struct EmptyState: View {
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
    static let openDownloads = Notification.Name("ai.a6n.rays.openDownloads")
    static let openCloud = Notification.Name("ai.a6n.rays.openCloud")
}

/// First-run / empty Downloads: the three ways to start a download, as glass tiles of equal size.
/// Glass sits only on things you can press; the background stays the window's material.
struct WelcomeEmpty: View {
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
