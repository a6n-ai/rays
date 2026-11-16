import AppKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// One file or folder in a sorted folder, read once off the main thread.
struct SortedItem: Identifiable, Hashable, Sendable {
    let url: URL
    let isFolder: Bool
    let size: Int?
    let modified: Date?
    let kind: String

    var id: URL { url }
    var name: String { url.lastPathComponent }

    var details: String {
        let size = isFolder ? nil : size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
        let date = modified?.formatted(date: .abbreviated, time: .omitted)
        return [size, date].compactMap { $0 }.joined(separator: ", ")
    }

    nonisolated static func list(_ folder: URL) -> [SortedItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey, .localizedTypeDescriptionKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return urls.map { url in
            let v = try? url.resourceValues(forKeys: Set(keys))
            return SortedItem(url: url, isFolder: (v?.isDirectory ?? false) && !(v?.isPackage ?? false),
                              size: v?.fileSize, modified: v?.contentModificationDate,
                              kind: v?.localizedTypeDescription ?? "")
        }
    }
}

enum SortedOrder: String, CaseIterable, Identifiable {
    case name = "Name", date = "Date", size = "Size", kind = "Kind"
    var id: Self { self }

    /// Folders first (as in Files), then by the chosen key; newest and largest first.
    func sorted(_ items: [SortedItem]) -> [SortedItem] {
        items.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            switch self {
            case .name: break
            case .date: if a.modified != b.modified { return (a.modified ?? .distantPast) > (b.modified ?? .distantPast) }
            case .size: if a.size != b.size { return (a.size ?? 0) > (b.size ?? 0) }
            case .kind: if a.kind != b.kind { return a.kind.localizedStandardCompare(b.kind) == .orderedAscending }
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}

/// A sorted folder as its own page, like the Files app: icons or list, a sort menu, folders drill in.
struct SortedBrowserPage: View {
    let folder: URL

    @AppStorage("sortedBrowserGrid") private var grid = true
    @AppStorage("sortedBrowserOrder") private var order: SortedOrder = .name
    @State private var items: [SortedItem]?

    var body: some View {
        content
            .navigationTitle(folder.lastPathComponent)
            .navigationSubtitle(items.map { $0.count == 1 ? "1 item" : "\($0.count) items" } ?? "")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    ToolbarIconGroup {
                        Button { grid = true } label: { ToolbarIcon(symbol: "square.grid.2x2", title: "Icons", selected: grid) }
                            .buttonStyle(.plain).help("Show as icons")
                        Button { grid = false } label: { ToolbarIcon(symbol: "list.bullet", title: "List", selected: !grid) }
                            .buttonStyle(.plain).help("Show as list")
                        Menu {
                            Picker("Sort by", selection: $order) {
                                ForEach(SortedOrder.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.inline)
                        } label: {
                            ToolbarIcon(symbol: "arrow.up.arrow.down", title: "Sort by \(order.rawValue)")
                        }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                        .help("Sort by \(order.rawValue)")
                    }
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .primaryAction) {
                    ToolbarIconGroup {
                        Button { NSWorkspace.shared.open(folder) } label: {
                            ToolbarIcon(symbol: "folder", title: "Show in Finder", tint: .blue)
                        }
                        .buttonStyle(.plain).help("Show \(folder.lastPathComponent) in Finder")
                    }
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .primaryAction) { SettingsToolbarButton() }
            }
            .task(id: folder) {
                let url = folder
                items = await Task.detached { SortedItem.list(url) }.value
            }
    }

    @ViewBuilder private var content: some View {
        if let items {
            let shown = order.sorted(items)
            if shown.isEmpty {
                ContentUnavailableView("Empty", systemImage: "folder", description: Text("Nothing is in this folder yet."))
            } else if grid {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 150), spacing: 16)], spacing: 20) {
                        ForEach(shown) { item in
                            itemLink(item) { GridTile(item: item) }
                        }
                    }
                    .padding(20)
                }
            } else {
                List(shown) { item in
                    itemLink(item) { ListRow(item: item) }
                }
                .scrollContentBackground(.hidden)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Folders open as the next page; files open in their app.
    @ViewBuilder private func itemLink<Label: View>(_ item: SortedItem, @ViewBuilder label: () -> Label) -> some View {
        if item.isFolder {
            NavigationLink(value: item.url) { label() }.buttonStyle(.plain)
        } else {
            Button { NSWorkspace.shared.open(item.url) } label: { label() }
                .buttonStyle(.plain)
                .help("Open \(item.name)")
                .accessibilityAction(named: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        }
    }
}

private struct GridTile: View {
    let item: SortedItem

    var body: some View {
        VStack(spacing: 6) {
            Thumbnail(url: item.url, side: 72)
                .frame(width: 88, height: 80)
            Text(item.name)
                .font(.callout)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.middle)
            Text(item.isFolder ? "Folder" : item.details)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

private struct ListRow: View {
    let item: SortedItem

    var body: some View {
        HStack(spacing: 12) {
            Thumbnail(url: item.url, side: 32)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                Text(item.details.isEmpty ? item.kind : item.details)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 8)
            if item.isFolder {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Quick Look thumbnail (a real preview for images, PDFs, video), falling back to the Finder icon.
private struct Thumbnail: View {
    let url: URL
    let side: CGFloat
    @Environment(\.displayScale) private var scale
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
        .task(id: url) {
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side),
                                                       scale: scale, representationTypes: .thumbnail)
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                image = rep.nsImage
            }
        }
    }
}
