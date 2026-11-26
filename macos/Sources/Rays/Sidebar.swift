import SwiftUI

enum Destination: Hashable {
    case downloads
    case sorter
    case models
    case folder(URL)
    case cloud
    case queues
    case schedules
    case speed
    case stats
    case shortcuts
}

struct SidebarFolder: Identifiable {
    let url: URL
    let count: Int
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

/// Lists the downloads folder and its immediate subfolders, skipping hidden items and sorter's `.part` files.
enum FolderListing {
    static func visibleItems(in folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .localizedTypeDescriptionKey]
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return items.filter { $0.pathExtension != "part" }
    }

    /// False when macOS hasn't granted (or has denied) access to the folder, e.g. the Downloads privacy prompt.
    static func canRead(_ folder: URL) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) != nil
    }

    static func sidebarFolders(root: URL) -> [SidebarFolder] {
        let subfolders = visibleItems(in: root)
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return ([root] + subfolders).map { SidebarFolder(url: $0, count: visibleItems(in: $0).count) }
    }
}

struct SidebarView: View {
    @Environment(EngineModel.self) private var model
    @Binding var selection: Destination?
    @State private var folders: [SidebarFolder] = []
    @AppStorage("sidebarFoldersExpanded") private var foldersExpanded = false
    @State private var denied = false
    @State private var activations = 0
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
        List(selection: $selection) {
            Section {
                SidebarLabel("Downloads", symbol: "arrow.down.circle", color: .blue)
                    .activeDot(model.hasActivity)
                    .tag(Destination.downloads)
                // Always shown, not a DisclosureGroup: a sidebar List ignores its saved expansion and can hide a selected child.
                SidebarLabel("Models", symbol: "cube", color: .purple)
                    .padding(.leading, 18)
                    .tag(Destination.models)
                SidebarLabel("Sorter", symbol: "sparkles", color: .yellow)
                    .tag(Destination.sorter)
                SidebarLabel("Cloud", symbol: "cloud", color: .cyan)
                    .tag(Destination.cloud)
            } header: {
                Text("Rays")
            }
            Section("Queues") {
                SidebarLabel("Queues", symbol: "list.bullet.rectangle", color: .orange)
                    .activeDot(model.queuesRunning)
                    .tag(Destination.queues)
                SidebarLabel("Schedules", symbol: "calendar.badge.clock", color: .red)
                    .tag(Destination.schedules)
            }
            Section("Tools") {
                SpeedCard().tag(Destination.speed)
                SidebarLabel("Stats", symbol: "chart.bar.xaxis", color: .green)
                    .tag(Destination.stats)
                SidebarLabel("Shortcuts", symbol: "square.2.layers.3d", color: .indigo)
                    .tag(Destination.shortcuts)
            }
            Section("Folders", isExpanded: $foldersExpanded) {
                if denied {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Rays needs access to Downloads", systemImage: "lock")
                            .font(.callout)
                        Button("Open Privacy Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                }
                ForEach(folders) { folder in
                    // The downloads root's subfolders are already listed here, so it doesn't expand.
                    FolderNode(url: folder.url, count: folder.count, expandable: folder.url != EngineModel.downloadsURL)
                }
            }
        }
        .listStyle(.sidebar)
        // Pinned under the list, so it stays put while the sidebar scrolls.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Animated here, not on the List: an animated List diff crashed in AppKit (0.1.24).
            VStack { if model.hasActivity {
                ActivityCard { selection = .downloads }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    .transition(.opacity)
            } }
            .animation(.easeInOut(duration: 0.2), value: model.hasActivity)
        }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        .task(id: "\(EngineModel.downloadsURL.path(percentEncoded: false))|\(model.jobs.filter(\.isDone).count)|\(model.folderRevision)|\(activations)") {
            let root = EngineModel.downloadsURL
            // Counting every folder's items is disk work; keep it off the main thread.
            let listed = await Task.detached(priority: .userInitiated) { () -> [SidebarFolder]? in
                FolderListing.canRead(root) ? FolderListing.sidebarFolders(root: root) : nil
            }.value
            denied = listed == nil
            folders = listed ?? []
        }
        // Coming back from System Settings after granting access should refresh without a relaunch.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            activations += 1
        }
    }
}


/// A sidebar folder that can expand to show its own subfolders, read only when first opened.
private struct FolderNode: View {
    let url: URL
    let count: Int
    var expandable = true
    @State private var expanded = false
    @State private var children: [SidebarFolder]?
    @State private var hasSubfolders = false

    var body: some View {
        Group {
            if expandable && hasSubfolders {
            DisclosureGroup(isExpanded: $expanded) {
                ForEach(children ?? []) { child in
                    FolderNode(url: child.url, count: child.count)
                }
            } label: {
                label
            }
            .onChange(of: expanded) { _, open in
                if open && children == nil { children = Self.subfolders(of: url) }
            }
            } else {
                label
            }
        }
        // Checked once per row, not on every redraw.
        .task(id: url) { if expandable { hasSubfolders = Self.containsSubfolder(url) } }
    }

    private var label: some View {
        Label(url.lastPathComponent, systemImage: "folder")
            .badge(count)
            .tag(Destination.folder(url))
    }

    // Cheap check (stops at the first subfolder) so the arrow only shows where there's something inside.
    private static func containsSubfolder(_ url: URL) -> Bool {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return false }
        return items.contains { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
    }

    private static func subfolders(of url: URL) -> [SidebarFolder] {
        FolderListing.visibleItems(in: url)
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { SidebarFolder(url: $0, count: FolderListing.visibleItems(in: $0).count) }
    }
}

/// A sidebar row label whose symbol keeps its own colour, and turns white on the selected row.
struct SidebarLabel: View {
    let title: String
    let symbol: String
    let color: Color
    @Environment(\.backgroundProminence) private var prominence

    init(_ title: String, symbol: String, color: Color) {
        (self.title, self.symbol, self.color) = (title, symbol, color)
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol).foregroundStyle(prominence == .increased ? AnyShapeStyle(.white) : AnyShapeStyle(color.mix(with: .gray, by: 0.45)))
        }
    }
}
