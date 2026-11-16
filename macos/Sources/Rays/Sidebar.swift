import SwiftUI

enum Destination: Hashable {
    case downloads
    case folder(URL)
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
    @State private var denied = false
    @State private var activations = 0
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
        List(selection: $selection) {
            Section("Rays") {
                Label("Downloads", systemImage: "arrow.down.circle")
                    .tag(Destination.downloads)
            }
            Section("Folders") {
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
                    Label(folder.name, systemImage: "folder")
                        .badge(folder.count)
                        .tag(Destination.folder(folder.url))
                }
            }
        }
        .listStyle(.sidebar)
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        .toolbar {
            // Sits in the sidebar's title bar beside the system sidebar toggle.
            ToolbarItem(placement: .automatic) {
                Button { openSettings() } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Settings (⌘,)")
            }
        }
        .task(id: "\(EngineModel.downloadsURL.path(percentEncoded: false))|\(model.jobs.filter(\.isDone).count)|\(model.folderRevision)|\(activations)") {
            let root = EngineModel.downloadsURL
            denied = !FolderListing.canRead(root)
            folders = denied ? [] : FolderListing.sidebarFolders(root: root)
        }
        // Coming back from System Settings after granting access should refresh without a relaunch.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            activations += 1
        }
    }
}
