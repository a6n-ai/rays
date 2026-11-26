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
        return urls.map(item)
    }

    nonisolated static func item(_ url: URL) -> SortedItem {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey, .localizedTypeDescriptionKey]
        let v = try? url.resourceValues(forKeys: keys)
        return SortedItem(url: url, isFolder: (v?.isDirectory ?? false) && !(v?.isPackage ?? false),
                          size: v?.fileSize, modified: v?.contentModificationDate,
                          kind: v?.localizedTypeDescription ?? "")
    }
}

enum SortedLayout: String, CaseIterable, Identifiable {
    case table, icons
    var id: Self { self }

    /// Until the user picks one, match the view Finder opens new windows in ("icnv" is icon view).
    static var finderDefault: SortedLayout {
        let style = CFPreferencesCopyAppValue("FXPreferredViewStyle" as CFString, "com.apple.finder" as CFString) as? String
        return style == "icnv" ? .icons : .table
    }
    var symbol: String { switch self { case .icons: "square.grid.2x2"; case .table: "list.bullet" } }
    var title: String { switch self { case .icons: "Icons"; case .table: "List" } }
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

    @AppStorage("sortedBrowserLayout") private var layout: SortedLayout = .finderDefault
    @AppStorage("sortedBrowserOrder") private var order: SortedOrder = .name
    @State private var items: [SortedItem]?
    @Environment(NavHistory.self) private var nav

    var body: some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) { viewBar }
            .navigationTitle(folder.lastPathComponent)
            .task(id: folder) {
                let url = folder
                items = await Task.detached { SortedItem.list(url) }.value
            }
    }

    private var viewBar: some View {
        ViewBar {
            Picker("Layout", selection: $layout) {
                ForEach(SortedLayout.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Menu {
                Picker("Sort by", selection: $order) {
                    ForEach(SortedOrder.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Sort by \(order.rawValue)", systemImage: "arrow.up.arrow.down")
            }
            .menuStyle(.button)
            .fixedSize()
            .disabled(layout == .table)
            Button { NSWorkspace.shared.open(folder) } label: { Label("Show in Finder", systemImage: "folder") }
                .help("Show \(folder.lastPathComponent) in Finder")
        }
    }

    @ViewBuilder private var content: some View {
        if let items {
            if items.isEmpty {
                ContentUnavailableView("Empty", systemImage: "folder")
            } else {
                SortedItemsView(items: items, layout: layout, order: order) { nav.open("sorted:" + $0.path(percentEncoded: false)) }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Items as a Finder-style list or an icon grid. Folders call `openFolder`; files open in their app.
struct SortedItemsView: View {
    let items: [SortedItem]
    let layout: SortedLayout
    var order: SortedOrder = .name
    let openFolder: (URL) -> Void
    @State private var columnOrder = [KeyPathComparator(\SortedItem.name, comparator: .localizedStandard)]
    @State private var page = 0
    @AppStorage(Paging.key) private var pageSize = Paging.defaultSize

    var body: some View {
        if layout == .table {
            FinderTable(items: items, order: $columnOrder, openFolder: openFolder)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92, maximum: 112), spacing: 12)], spacing: 14) {
                    ForEach(ListControls.page(order.sorted(items), page, pageSize)) { item in
                        Button { open(item.url) } label: { GridTile(item: item) }
                        .buttonStyle(.plain)
                        .help("Open \(item.name)")
                        .contextMenu { ItemMenu(urls: [item.url], open: open) }
                        .accessibilityAction(named: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                    }
                }
                .padding(20)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { PageBar(count: items.count, page: $page, padded: true) }
            .onChange(of: order) { _, _ in page = 0 }
        }
    }

    private func open(_ url: URL) {
        if items.first(where: { $0.url == url })?.isFolder == true { openFolder(url) } else { NSWorkspace.shared.open(url) }
    }
}

/// Right-click actions for sorted items, the same ones the Downloads list offers.
private struct ItemMenu: View {
    let urls: Set<URL>
    let open: (URL) -> Void

    var body: some View {
        Button("Open") { urls.forEach(open) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(Array(urls)) }
        Button("Copy path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(urls.map { $0.path(percentEncoded: false) }.joined(separator: "\n"), forType: .string)
        }
    }
}

private struct GridTile: View {
    let item: SortedItem

    var body: some View {
        VStack(spacing: 6) {
            Thumbnail(url: item.url, side: 48)
                .frame(width: 60, height: 54)
            Text(item.name)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.middle)
            Text(item.isFolder ? "Folder" : item.details)
                .font(.subheadline)
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

/// Finder's list view: native columns, click a header to sort, double-click to open.
struct FinderTable: View {
    let items: [SortedItem]
    @Binding var order: [KeyPathComparator<SortedItem>]
    let openFolder: (URL) -> Void
    @State private var selection = Set<SortedItem.ID>()
    @State private var page = 0
    @AppStorage(Paging.key) private var pageSize = Paging.defaultSize

    var body: some View {
        // Folders stay on top, as in Finder's default list view.
        let sorted = items.sorted { a, b in
            a.isFolder != b.isFolder ? a.isFolder : order.compare(a, b) == .orderedAscending
        }
        let rows = Array(ListControls.page(sorted, page, pageSize))
        Table(rows, selection: $selection, sortOrder: $order) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { item in
                HStack(spacing: 6) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                        .resizable().frame(width: 16, height: 16).accessibilityHidden(true)
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                }
            }
            .width(min: 180, ideal: 300)
            TableColumn("Date Modified", value: \.sortDate) { item in
                Text(item.modified?.formatted(date: .abbreviated, time: .shortened) ?? "--")
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 120, ideal: 160)
            TableColumn("Size", value: \.sortSize) { item in
                Text(item.isFolder ? "--" : item.size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "--")
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 60, ideal: 80)
            TableColumn("Kind", value: \.kind, comparator: .localizedStandard) { item in
                Text(item.kind).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 80, ideal: 140)
        }
        .contextMenu(forSelectionType: SortedItem.ID.self) { ids in
            if !ids.isEmpty { ItemMenu(urls: ids, open: open) }
        } primaryAction: { ids in
            ids.forEach(open)
        }
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) { PageBar(count: items.count, page: $page, padded: true) }
        .onChange(of: order) { _, _ in page = 0 }
    }

    private func open(_ url: URL) {
        if items.first(where: { $0.url == url })?.isFolder == true { openFolder(url) } else { NSWorkspace.shared.open(url) }
    }
}

private extension SortedItem {
    var sortDate: Date { modified ?? .distantPast }
    var sortSize: Int { size ?? 0 }
}
