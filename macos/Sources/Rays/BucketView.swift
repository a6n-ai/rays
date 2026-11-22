import AppKit
import SwiftUI

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
                    Button { reload += 1 } label: { ToolbarIcon(symbol: "arrow.clockwise", title: "Refresh") }
                        .buttonStyle(.plain)
                        .disabled(shown != .browse)
                        .help("List this folder again")
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

/// One level of a bucket: folders open in place, objects download with the normal engine.
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

    var body: some View {
        List {
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
            }
            if let error {
                ErrorLine(text: error)
            } else if !loading && folders.isEmpty && objects.isEmpty {
                Text(prefix.isEmpty ? "This bucket is empty." : "This folder is empty.")
                    .foregroundStyle(.secondary)
            }
            ForEach(folders, id: \.self) { folder in
                Button { prefix = folder } label: {
                    Label(Self.leaf(folder), systemImage: "folder")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            ForEach(objects, id: \.key) { object in
                HStack {
                    Label(Self.leaf(object.key), systemImage: "doc")
                    Spacer()
                    Text(byteText(object.size)).foregroundStyle(.secondary).monospacedDigit()
                    Button { download(object.key) } label: {
                        Image(systemName: added.contains(object.key) ? "checkmark.circle.fill" : "arrow.down.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(added.contains(object.key) ? "Added to Downloads" : "Download")
                    .accessibilityLabel("Download \(Self.leaf(object.key))")
                }
                .contextMenu {
                    Button { download(object.key) } label: { Label("Download", systemImage: "arrow.down.circle") }
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("s3://\(bucket)/\(object.key)", forType: .string)
                    } label: { Label("Copy Link", systemImage: "link") }
                }
            }
            if let nextToken, !loading {
                Button("Load More") { Task { await load(token: nextToken) } }
            }
            if loading { ProgressView().frame(maxWidth: .infinity) }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
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
