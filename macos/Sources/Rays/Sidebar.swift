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
    case home
    case general
    case ai
    case browsers
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
                HomeRow().tag(Destination.home)
            }
            Section {
                SidebarLabel("Downloads", tile: .downloads)
                    .activeDot(model.hasActivity)
                    .tag(Destination.downloads)
                SidebarLabel("Models", tile: .models)
                    .tag(Destination.models)
                SidebarLabel("Sorter", tile: .sorter)
                    .tag(Destination.sorter)
                SidebarLabel("Cloud", tile: .cloud)
                    .tag(Destination.cloud)
            }
            Section {
                SidebarLabel("Queues", tile: .queues)
                    .activeDot(model.queuesRunning)
                    .tag(Destination.queues)
                SidebarLabel("Schedules", tile: .schedules)
                    .tag(Destination.schedules)
            }
            Section {
                SpeedCard().tag(Destination.speed)
                SidebarLabel("Stats", tile: .stats)
                    .tag(Destination.stats)
                SidebarLabel("Shortcuts", tile: .shortcuts)
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

/// A sidebar row label with a System Settings style icon: a white symbol on a small tile of the item's colour.
struct SidebarLabel: View {
    let title: String
    let tile: Tile

    init(_ title: String, tile: Tile) {
        (self.title, self.tile) = (title, tile)
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            IconTile(tile, size: TileSize.sidebar)
        }
    }
}

/// The top sidebar row, like the Apple Account row in System Settings: app icon, name, version.
struct HomeRow: View {
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: TileSize.list, height: TileSize.list)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Rays").font(.body.weight(.semibold))
                Text("Version \(version)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Stands in for the Home page until its task.
struct HomePlaceholder: View {
    var body: some View {
        HeroCard(.downloads, title: "Rays", subtitle: "Home is coming.", style: .home)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Stands in for the General, AI and Browsers pages until Task 7.
struct SettingsPagePlaceholder: View {
    let tile: Tile
    let title: String

    var body: some View {
        HeroCard(tile, title: title, subtitle: "This page is coming.", style: .centered)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
