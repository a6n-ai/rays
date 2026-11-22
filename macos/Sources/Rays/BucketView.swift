import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum CloudTab: String { case browse, buckets, downloads }

/// The Cloud page: browse a bucket, manage buckets, and the downloads that came from buckets.
struct CloudView: View {
    @Environment(EngineModel.self) private var model
    @AppStorage("cloudTab") private var tab: CloudTab = .browse
    @AppStorage("cloudBucket") private var bucket = ""
    @State private var reload = 0

    private var current: String? {
        model.buckets.first { $0.name == bucket }?.name ?? model.buckets.first?.name
    }
    private var shown: CloudTab { model.buckets.isEmpty ? .buckets : tab }

    var body: some View {
        Group {
            switch shown {
            case .browse:
                if let current { BucketBrowser(bucket: current, reload: reload).id(current) }
            case .buckets:
                BucketsForm()
            case .downloads:
                CloudDownloads()
            }
        }
        .navigationTitle("Rays")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .principal) {
                ToolbarIconGroup {
                    ForEach([(CloudTab.browse, "folder", "Browse"),
                             (CloudTab.buckets, "externaldrive.badge.plus", "Buckets"),
                             (CloudTab.downloads, "arrow.down.circle", "Cloud downloads")], id: \.0) { item in
                        Button { tab = item.0 } label: {
                            ToolbarIcon(symbol: item.1, title: item.2, selected: shown == item.0)
                        }
                        .buttonStyle(.plain)
                        .disabled(model.buckets.isEmpty && item.0 != .buckets)
                        .help(item.2)
                        .accessibilityAddTraits(shown == item.0 ? .isSelected : [])
                    }
                }
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .primaryAction) {
                ToolbarIconGroup {
                    if shown == .browse, model.buckets.count > 1 {
                        Menu {
                            Picker("Bucket", selection: Binding(get: { current ?? "" }, set: { bucket = $0 })) {
                                ForEach(model.buckets, id: \.name) { Text($0.name).tag($0.name) }
                            }
                            .pickerStyle(.inline)
                        } label: {
                            ToolbarIcon(symbol: "cloud", title: "Choose bucket")
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .help("Choose bucket")
                    }
                    Button {
                        if shown == .buckets { Task { await model.loadCloudLogins(force: true) } } else { reload += 1 }
                    } label: { ToolbarIcon(symbol: "arrow.clockwise", title: "Refresh") }
                        .buttonStyle(.plain)
                        .disabled(shown == .downloads)
                        .help(shown == .buckets ? "Ask the aws and cf commands again" : "List this folder again")
                }
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .primaryAction) { SettingsToolbarButton() }
        }
    }

    private var subtitle: String {
        switch shown {
        case .browse: "Cloud: \(current ?? "")"
        case .buckets: model.buckets.count == 1 ? "Cloud: 1 bucket" : "Cloud: \(model.buckets.count) buckets"
        case .downloads: "Cloud downloads"
        }
    }
}

/// One row in a bucket listing: a folder (a common prefix) or an object.
private struct BucketEntry: Identifiable {
    let id: String
    let name: String
    let isFolder: Bool
    let size: UInt64?
    let modified: Date?

    var type: UTType { isFolder ? .folder : UTType(filenameExtension: (name as NSString).pathExtension) ?? .data }
    var kind: String { type.localizedDescription ?? (isFolder ? "Folder" : "Document") }

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func rows(folders: [String], objects: [BucketObject]) -> [BucketEntry] {
        folders.map { BucketEntry(id: $0, name: BucketBrowser.leaf($0), isFolder: true, size: nil, modified: nil) }
            + objects.map { o in
                BucketEntry(id: o.key, name: BucketBrowser.leaf(o.key), isFolder: false, size: o.size,
                            modified: iso.date(from: o.modified) ?? ISO8601DateFormatter().date(from: o.modified))
            }
    }
}

/// One level of a bucket in the same table as the folder views: folders open in place, files download.
private struct BucketBrowser: View {
    @Environment(EngineModel.self) private var model
    let bucket: String
    let reload: Int
    @State private var prefix = ""
    @State private var folders: [String] = []
    @State private var objects: [BucketObject] = []
    @State private var nextToken: String?
    @State private var loading = false
    @State private var error: String?
    @State private var added = Set<String>()
    @State private var selection = Set<String>()

    private var entries: [BucketEntry] { BucketEntry.rows(folders: folders, objects: objects) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { prefix = Self.parent(prefix) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                    .disabled(prefix.isEmpty)
                    .help("Up one folder")
                Text(prefix.isEmpty ? bucket : bucket + "/" + prefix)
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
                ContentUnavailableView(prefix.isEmpty ? "This bucket is empty" : "This folder is empty", systemImage: "folder")
            } else {
                table
            }
            if let nextToken, !loading {
                Button("Load More") { Task { await load(token: nextToken) } }
                    .padding(8)
            }
        }
        .task(id: "\(prefix)|\(reload)") { await load(token: nil) }
    }

    private var table: some View {
        Table(entries, selection: $selection) {
            TableColumn("Name") { entry in
                HStack(spacing: 6) {
                    Image(nsImage: NSWorkspace.shared.icon(for: entry.type))
                        .resizable()
                        .frame(width: 16, height: 16)
                        .accessibilityHidden(true)
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
            let files = ids.filter { !$0.hasSuffix("/") }
            if ids.count == 1, let folder = ids.first, folder.hasSuffix("/") {
                Button("Open") { prefix = folder }
            }
            Button(files.count > 1 ? "Download \(files.count) Files" : "Download") { files.forEach(download) }
                .disabled(files.isEmpty)
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(ids.sorted().map { "s3://\(bucket)/\($0)" }.joined(separator: "\n"), forType: .string)
            }
            .disabled(ids.isEmpty)
        } primaryAction: { ids in
            if ids.count == 1, let folder = ids.first, folder.hasSuffix("/") {
                prefix = folder
            } else {
                ids.filter { !$0.hasSuffix("/") }.forEach(download)
            }
        }
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
                selection = []
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

    static func leaf(_ key: String) -> String {
        let trimmed = key.hasSuffix("/") ? String(key.dropLast()) : key
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
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

    var body: some View {
        let jobs = model.jobs.filter { $0.url.hasPrefix("s3://") }
        if jobs.isEmpty {
            ContentUnavailableView("No cloud downloads yet", systemImage: "cloud",
                                   description: Text("Download a file from Browse and it shows up here."))
        } else {
            List(jobs, id: \.id) { job in
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
        }
    }
}
