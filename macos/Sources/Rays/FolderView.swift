import AppKit
import SwiftUI

struct FileEntry: Identifiable {
    let url: URL
    let isFolder: Bool
    let size: Int?
    let modified: Date?
    let kind: String

    var id: URL { url }
    var name: String { url.lastPathComponent }

    /// Folders first, then newest first.
    static func load(_ folder: URL) -> [FileEntry] {
        FolderListing.visibleItems(in: folder).map { url in
            let values = try? url.resourceValues(forKeys: [
                .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .localizedTypeDescriptionKey,
            ])
            return FileEntry(
                url: url, isFolder: values?.isDirectory ?? false, size: values?.fileSize,
                modified: values?.contentModificationDate, kind: values?.localizedTypeDescription ?? "")
        }
        .sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            return (a.modified ?? .distantPast) > (b.modified ?? .distantPast)
        }
    }
}

/// Watches one folder for changes and calls back once per burst, 300 ms after the last change.
@MainActor
final class DirectoryWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var debounce: Task<Void, Never>?

    func watch(_ folder: URL, onChange: @escaping @MainActor () -> Void) {
        stop()
        let fd = open(folder.path(percentEncoded: false), O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.schedule(onChange) }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    func stop() {
        debounce?.cancel()
        debounce = nil
        source?.cancel()
        source = nil
    }

    private func schedule(_ onChange: @escaping @MainActor () -> Void) {
        debounce?.cancel()
        debounce = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            onChange()
        }
    }
}

struct FolderView: View {
    @Environment(EngineModel.self) private var model
    let root: URL
    @State private var current: URL
    @State private var entries: [FileEntry] = []
    @State private var selection = Set<URL>()
    @State private var tracked = Set<String>()
    @State private var watcher = DirectoryWatcher()
    let onClose: () -> Void
    /// Inside the Downloads page, under its own toolbar: the back button and path move into a bar above the files.
    var embedded = false

    init(root: URL, folder: URL, embedded: Bool = false, onClose: @escaping () -> Void) {
        self.root = root
        self.onClose = onClose
        self.embedded = embedded
        _current = State(initialValue: folder)
    }

    private var atRoot: Bool { current.standardizedFileURL == root.standardizedFileURL }

    /// Up one folder; from the downloads folder itself, back to the downloads list.
    private func goBack() {
        if atRoot { onClose() } else { current = current.deletingLastPathComponent() }
    }

    var body: some View {
        Group {
            if entries.isEmpty {
                ContentUnavailableView("Empty folder", systemImage: "folder")
            } else {
                table
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .top) {
            if embedded {
                HStack(spacing: 8) {
                    navButton("chevron.backward") { current = current.deletingLastPathComponent() }
                        .disabled(atRoot)
                        .help(atRoot ? "" : "Back to \(current.deletingLastPathComponent().lastPathComponent)")
                        .accessibilityLabel("Back")
                    pathBar
                    Spacer()
                }
                .padding(.horizontal, LayoutMetrics.margin)
                .padding(.vertical, 6)
            }
        }
        .navigationTitle(embedded ? "Rays" : current.lastPathComponent)
        .toolbar {
            if !embedded {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 2) {
                    navButton("chevron.backward", action: goBack)
                        .help(atRoot ? "Back to Downloads list" : "Back to \(current.deletingLastPathComponent().lastPathComponent)")
                        .accessibilityLabel(atRoot ? "Back to Downloads list" : "Back")
                        .keyboardShortcut("[", modifiers: .command)
                    navButton("house", action: onClose)
                        .help("Home: the Downloads list")
                        .accessibilityLabel("Home")
                        .keyboardShortcut("h", modifiers: [.command, .shift])
                }
                .padding(3)
                .glassEffect(.regular, in: .capsule)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .principal) {
                pathBar
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .primaryAction) { SettingsToolbarButton() }
            }
        }
        .onExitCommand(perform: goBack)
        .onChange(of: current, initial: true) { _, folder in
            selection = []
            reload(folder)
            watcher.watch(folder) {
                reload(folder)
                model.foldersChanged()
            }
        }
        .onDisappear { watcher.stop() }
    }

    private var table: some View {
        Table(entries, selection: $selection) {
            TableColumn("Name") { entry in
                HStack(spacing: 6) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: entry.url.path(percentEncoded: false)))
                        .resizable()
                        .frame(width: 16, height: 16)
                        .accessibilityHidden(true)
                    Text(entry.name).lineLimit(1)
                    if tracked.contains(entry.url.standardizedFileURL.path(percentEncoded: false)) {
                        Image(systemName: "arrow.down.circle")
                            .foregroundStyle(.tint)
                            .help("Downloaded by Rays")
                            .accessibilityLabel("Downloaded by Rays")
                    }
                }
            }
            .width(min: 160, ideal: 240)
            TableColumn("Size") { entry in
                Text(entry.size.map { Int64($0).formatted(.byteCount(style: .file)) } ?? "—")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 60, ideal: 70)
            TableColumn("Date Modified") { entry in
                Text(entry.modified?.formatted(.dateTime.day().month(.abbreviated).hour().minute()) ?? "")
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 150)
        }
        .scrollContentBackground(.hidden)
        .alternatingRowBackgrounds(.disabled)
        .contextMenu(forSelectionType: URL.self) { urls in
            Button("Open") { selected(urls).forEach(open) }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(Array(urls))
            }
            .disabled(urls.isEmpty)
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(urls.map { $0.path(percentEncoded: false) }.joined(separator: "\n"), forType: .string)
            }
            .disabled(urls.isEmpty)
        } primaryAction: { urls in
            selected(urls).forEach(open)
        }
    }

    private func navButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 34, height: 28)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var pathBar: some View {
        HStack(spacing: 6) {
            ForEach(Array(breadcrumbs.enumerated()), id: \.offset) { index, crumb in
                if index > 0 {
                    Text("›").foregroundStyle(.secondary)
                }
                Button(crumb.name) { current = crumb.url }
                    .buttonStyle(.plain)
                    .fontWeight(crumb.url == current ? .semibold : .regular)
                    .foregroundStyle(crumb.url == current ? .primary : .secondary)
                    .disabled(crumb.url == current)
                    .lineLimit(1)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 14)
        .frame(height: 34)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Path")
    }

    /// The downloads folder down to the shown folder, each one clickable.
    private var breadcrumbs: [(name: String, url: URL)] {
        let rootParts = root.standardizedFileURL.pathComponents
        let parts = current.standardizedFileURL.pathComponents
        guard parts.starts(with: rootParts) else { return [] }
        var crumbs = [(name: root.lastPathComponent, url: root)]
        var url = root
        for name in parts.dropFirst(rootParts.count) {
            url = url.appending(path: name, directoryHint: .isDirectory)
            crumbs.append((name, url))
        }
        return crumbs
    }

    private func selected(_ urls: Set<URL>) -> [FileEntry] {
        entries.filter { urls.contains($0.url) }
    }

    private func open(_ entry: FileEntry) {
        if entry.isFolder {
            current = entry.url
        } else {
            NSWorkspace.shared.open(entry.url)
        }
    }

    private func reload(_ folder: URL) {
        entries = FileEntry.load(folder)
        tracked = model.trackedPaths()
    }
}
