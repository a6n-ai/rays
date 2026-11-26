import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Cloud page: browse providers and buckets like Finder, manage buckets, and cloud downloads.
struct CloudView: View {
    @Environment(EngineModel.self) private var model
    @Environment(NavHistory.self) private var nav
    /// "" is the top level, "p:<provider>" a provider's buckets, "b:<bucket>" inside a bucket.
    @AppStorage("cloudPlace") private var place = ""
    @AppStorage("sortedBrowserLayout") private var layout: SortedLayout = .finderDefault
    @State private var reload = 0

    /// "browse" and "downloads" are drill-ins from the buckets page; with no buckets there is only the page.
    private var shown: String { model.buckets.isEmpty ? "buckets" : (nav.sub ?? "buckets") }

    var body: some View {
        Group {
            switch shown {
            case "browse":
                CloudBrowser(place: $place, layout: layout, reload: reload)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        ViewBar {
                            Button { layout = layout == .table ? .icons : .table } label: {
                                Label(layout == .table ? "Show as icons" : "Show as list",
                                      systemImage: layout == .table ? "square.grid.2x2" : "list.bullet")
                            }
                            Button { reload += 1 } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                                .help("List this folder again")
                        }
                    }
            case "downloads": CloudDownloads()
            default: BucketsForm()
            }
        }
        .navigationTitle(shown == "browse" ? "Browse Cloud" : shown == "downloads" ? "Cloud Downloads" : "Cloud")
        .navigationSubtitle(subtitle)
    }

    private var subtitle: String {
        switch shown {
        case "browse": "Cloud"
        case "downloads": "Cloud downloads"
        default: model.buckets.count == 1 ? "Cloud: 1 bucket" : "Cloud: \(model.buckets.count) buckets"
        }
    }
}

/// A provider name for the path bar and tiles, from the presets.
@MainActor
private func providerName(_ model: EngineModel, _ id: String) -> String {
    model.providers.first { $0.id == id }?.name ?? id
}

/// Top level: the connected providers as folders; then a provider's buckets; then inside a bucket.
private struct CloudBrowser: View {
    @Environment(EngineModel.self) private var model
    @Binding var place: String
    let layout: SortedLayout
    let reload: Int

    private var providers: [String] {
        var seen = Set<String>()
        return model.buckets.map(\.provider).filter { seen.insert($0).inserted }
    }

    var body: some View {
        if place.hasPrefix("b:"), let bucket = model.buckets.first(where: { "b:" + $0.name == place }) {
            BucketBrowser(bucket: bucket.name, provider: bucket.provider, layout: layout, reload: reload) {
                place = "p:" + bucket.provider
            }
            .id(bucket.name)
        } else if place.hasPrefix("p:"), providers.contains(String(place.dropFirst(2))) {
            let provider = String(place.dropFirst(2))
            let buckets = model.buckets.filter { $0.provider == provider }
            CloudItems(
                entries: buckets.map { BucketEntry(id: $0.name, name: $0.name, isFolder: true, size: nil, modified: nil,
                                                   badge: provider, note: $0.region) },
                layout: layout,
                path: ["Cloud", providerName(model, provider)],
                back: { place = "" },
                open: { place = "b:" + $0.id })
        } else {
            CloudItems(
                entries: providers.map { id in
                    let count = model.buckets.filter { $0.provider == id }.count
                    return BucketEntry(id: id, name: providerName(model, id), isFolder: true, size: nil, modified: nil,
                                       badge: id, note: count == 1 ? "1 bucket" : "\(count) buckets")
                },
                layout: layout,
                path: ["Cloud"],
                back: nil,
                open: { place = "p:" + $0.id })
        }
    }
}

/// One row or tile: a provider, a bucket, a folder (a common prefix) or an object.
struct BucketEntry: Identifiable {
    let id: String
    let name: String
    let isFolder: Bool
    let size: UInt64?
    let modified: Date?
    /// A provider id for providers and buckets, which show the brand badge instead of a Finder icon.
    var badge: String? = nil
    var note: String? = nil

    var type: UTType { isFolder ? .folder : UTType(filenameExtension: (name as NSString).pathExtension) ?? .data }
    var kind: String {
        if badge != nil { return note ?? "" }
        return type.localizedDescription ?? (isFolder ? "Folder" : "Document")
    }

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func rows(folders: [String], objects: [BucketObject]) -> [BucketEntry] {
        folders.map { BucketEntry(id: $0, name: leaf($0), isFolder: true, size: nil, modified: nil) }
            + objects.map { o in
                BucketEntry(id: o.key, name: leaf(o.key), isFolder: false, size: o.size,
                            modified: iso.date(from: o.modified) ?? ISO8601DateFormatter().date(from: o.modified))
            }
    }

    static func leaf(_ key: String) -> String {
        let trimmed = key.hasSuffix("/") ? String(key.dropLast()) : key
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }
}

/// A path bar, then the entries as the Sorter shows files: a Finder table or an icon grid.
private struct CloudItems: View {
    let entries: [BucketEntry]
    let layout: SortedLayout
    let path: [String]
    let back: (() -> Void)?
    let open: (BucketEntry) -> Void
    var added: Set<String> = []
    var loading = false
    var error: String?
    var download: ((String) -> Void)?
    var copyLinks: ((Set<String>) -> Void)?
    @State private var selection = Set<String>()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { back?() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                    .disabled(back == nil)
                    .help("Back")
                Text(path.joined(separator: " › "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, LayoutMetrics.margin)
            .padding(.vertical, 8)
            if let error {
                ContentUnavailableView("Couldn't list this bucket", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if !loading && entries.isEmpty {
                ContentUnavailableView("Empty", systemImage: "folder", description: Text("Nothing is in this folder yet."))
            } else if layout == .icons {
                grid
            } else {
                table
            }
        }
    }

    @ViewBuilder private func icon(_ entry: BucketEntry, side: CGFloat) -> some View {
        if let badge = entry.badge {
            let (symbol, color) = ProviderIcon.style(badge)
            Image(systemName: entry.id == badge ? symbol : "cloud.fill")
                .font(.system(size: side * 0.5, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: side, height: side)
                .background(color, in: RoundedRectangle(cornerRadius: side * 0.24, style: .continuous))
                .accessibilityHidden(true)
        } else {
            Image(nsImage: NSWorkspace.shared.icon(for: entry.type))
                .resizable()
                .frame(width: side, height: side)
                .accessibilityHidden(true)
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92, maximum: 112), spacing: 12)], spacing: 14) {
                ForEach(entries) { entry in
                    Button { open(entry) } label: {
                        VStack(spacing: 6) {
                            icon(entry, side: entry.badge == nil ? 48 : 44).frame(width: 60, height: 54)
                            Text(entry.name)
                                .font(.caption)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .truncationMode(.middle)
                            Text(entry.badge != nil ? (entry.note ?? "") : entry.isFolder ? "Folder" : entry.size.map(byteText) ?? "")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .monospacedDigit()
                        }
                        .frame(maxWidth: .infinity)
                        .padding(8)
                        .overlay(alignment: .topTrailing) {
                            if added.contains(entry.id) {
                                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint).padding(6)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .help(entry.isFolder ? "Open \(entry.name)" : "Download \(entry.name)")
                    .contextMenu { menu([entry.id]) }
                }
            }
            .padding(20)
        }
    }

    private var table: some View {
        Table(entries, selection: $selection) {
            TableColumn("Name") { entry in
                HStack(spacing: 6) {
                    icon(entry, side: 16)
                    Text(entry.name).lineLimit(1).truncationMode(.middle)
                    if added.contains(entry.id) {
                        Image(systemName: "arrow.down.circle")
                            .foregroundStyle(.tint)
                            .help("Added to Downloads")
                            .accessibilityLabel("Added to Downloads")
                    }
                }
            }
            .width(min: 160, ideal: 260)
            TableColumn("Size") { entry in
                Text(entry.size.map(byteText) ?? "—").foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 60, ideal: 70)
            TableColumn("Date Modified") { entry in
                Text(entry.modified?.formatted(.dateTime.day().month(.abbreviated).hour().minute()) ?? "")
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 150)
            TableColumn("Kind") { entry in
                Text(entry.kind).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 80, ideal: 110)
        }
        .scrollContentBackground(.hidden)
        .alternatingRowBackgrounds(.disabled)
        .contextMenu(forSelectionType: String.self) { ids in
            menu(ids)
        } primaryAction: { ids in
            let picked = entries.filter { ids.contains($0.id) }
            if picked.count == 1, let one = picked.first, one.isFolder {
                open(one)
            } else {
                picked.filter { !$0.isFolder }.forEach(open)
            }
        }
    }

    @ViewBuilder private func menu(_ ids: Set<String>) -> some View {
        let picked = entries.filter { ids.contains($0.id) }
        if picked.count == 1, let one = picked.first, one.isFolder {
            Button("Open") { open(one) }
        }
        if let download {
            let files = picked.filter { !$0.isFolder }
            Button(files.count > 1 ? "Download \(files.count) Files" : "Download") { files.forEach { download($0.id) } }
                .disabled(files.isEmpty)
        }
        if let copyLinks {
            Button("Copy Link") { copyLinks(ids) }.disabled(ids.isEmpty)
        }
    }
}

/// One level of a bucket: folders open in place, files download with the normal engine.
private struct BucketBrowser: View {
    @Environment(EngineModel.self) private var model
    let bucket: String
    let provider: String
    let layout: SortedLayout
    let reload: Int
    let up: () -> Void
    @State private var prefix = ""
    @State private var folders: [String] = []
    @State private var objects: [BucketObject] = []
    @State private var nextToken: String?
    @State private var loading = false
    @State private var error: String?
    @State private var added = Set<String>()

    var body: some View {
        VStack(spacing: 0) {
            CloudItems(
                entries: BucketEntry.rows(folders: folders, objects: objects),
                layout: layout,
                path: ["Cloud", providerName(model, provider), bucket] + prefix.split(separator: "/").map(String.init),
                back: { if prefix.isEmpty { up() } else { prefix = Self.parent(prefix) } },
                open: { entry in if entry.isFolder { prefix = entry.id } else { download(entry.id) } },
                added: added,
                loading: loading,
                error: error,
                download: download,
                copyLinks: { ids in
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ids.sorted().map { "s3://\(bucket)/\($0)" }.joined(separator: "\n"), forType: .string)
                })
            if let nextToken, !loading {
                Button("Load More") { Task { await load(token: nextToken) } }.padding(8)
            }
        }
        .task(id: "\(prefix)|\(reload)") { await load(token: nil) }
    }

    private func download(_ key: String) {
        model.download(bucket: bucket, key: key)
        if model.notice == nil { added.insert(key) }
    }

    /// nil starts the level over; a token appends the next page.
    private func load(token: String?) async {
        loading = true
        defer { loading = false }
        do {
            let page = try await model.listBucket(bucket, prefix: prefix, token: token)
            if token == nil {
                folders = page.folders
                objects = page.objects
            } else {
                folders += page.folders
                objects += page.objects
            }
            nextToken = page.nextToken
            error = nil
        } catch {
            self.error = EngineModel.message(for: error)
        }
    }

    /// "a/b/" goes up to "a/"; a top-level folder goes back to the bucket root.
    static func parent(_ prefix: String) -> String {
        var parts = prefix.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty else { return "" }
        parts.removeLast()
        return parts.isEmpty ? "" : parts.joined(separator: "/") + "/"
    }
}

/// Downloads whose link is an s3:// object, with the same rows as the Downloads list.
private struct CloudDownloads: View {
    @Environment(EngineModel.self) private var model
    @State private var status = "All"
    @State private var kind = FileKind.all
    @State private var sort = ListSort.newest
    @State private var page = 0
    @AppStorage(Paging.key) private var pageSize = Paging.defaultSize

    var body: some View {
        let all = model.jobs.filter { $0.url.hasPrefix("s3://") }
        let jobs = all.listed(status: status, kind: kind, sort: sort)
        if all.isEmpty {
            ContentUnavailableView("No cloud downloads yet", systemImage: "cloud",
                                   description: Text("Download a file from Browse and it shows up here."))
        } else {
            List(Array(ListControls.page(jobs, page, pageSize)), id: \.id) { job in
                JobRow(job: job)
                    .listRowInsets(EdgeInsets(
                        top: LayoutMetrics.rowSpacing / 2,
                        leading: LayoutMetrics.margin - LayoutMetrics.hoverInset,
                        bottom: LayoutMetrics.rowSpacing / 2,
                        trailing: LayoutMetrics.margin - LayoutMetrics.hoverInset))
                    .listRowSeparator(.hidden)
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .overlay { if jobs.isEmpty { EmptyState(symbol: "tray", title: "No downloads match") } }
            .safeAreaInset(edge: .top, spacing: 0) {
                ListControls(statuses: JobView.statuses, status: $status, kind: $kind, sort: $sort, count: jobs.count, page: $page)
            }
        }
    }
}
