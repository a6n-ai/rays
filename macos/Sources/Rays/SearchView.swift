import AppKit
import SwiftUI

/// Search results for the sidebar search field: matching downloads, then files under the downloads folder.
struct SearchView: View {
    @Environment(EngineModel.self) private var model
    let query: String
    /// Opens a folder in the folder view and ends the search.
    let onOpenFolder: (URL) -> Void
    @State private var files: [FileSearch.Hit] = []
    @State private var searching = false
    @State private var tracked = Set<String>()

    private var jobHits: [JobView] {
        model.jobs.filter { job in
            if job.name.localizedStandardContains(query) || job.url.localizedStandardContains(query) { return true }
            guard job.isDone, let file = model.locate(job) else { return false }
            return model.location(of: file).localizedStandardContains(query)
        }
    }

    private var rowInsets: EdgeInsets {
        EdgeInsets(
            top: LayoutMetrics.rowSpacing / 2,
            leading: LayoutMetrics.margin - LayoutMetrics.hoverInset,
            bottom: LayoutMetrics.rowSpacing / 2,
            trailing: LayoutMetrics.margin - LayoutMetrics.hoverInset)
    }

    var body: some View {
        let jobs = jobHits
        let total = jobs.count + files.count
        Group {
            if !searching && total == 0 {
                ContentUnavailableView.search(text: query)
            } else {
                List {
                    if !jobs.isEmpty {
                        Section {
                            ForEach(jobs, id: \.id) { job in
                                JobRow(job: job)
                                    .listRowInsets(rowInsets)
                                    .listRowSeparator(.hidden)
                            }
                        } header: {
                            Text("Downloads").accessibilityAddTraits(.isHeader)
                        }
                    }
                    if searching || !files.isEmpty {
                        Section {
                            if searching {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("Searching…").foregroundStyle(.secondary)
                                }
                                .listRowInsets(rowInsets)
                                .listRowSeparator(.hidden)
                            }
                            ForEach(files) { hit in
                                fileRow(hit)
                                    .listRowInsets(rowInsets)
                                    .listRowSeparator(.hidden)
                            }
                        } header: {
                            Text("Files in Downloads").accessibilityAddTraits(.isHeader)
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .scrollEdgeEffectStyle(.soft, for: .all)
            }
        }
        .navigationTitle("Search")
        .toolbar { ToolbarItem(placement: .primaryAction) { SettingsToolbarButton() } }
        .navigationSubtitle(total == 1 ? "1 result" : "\(total) results")
        .task(id: query) { await searchFiles() }
    }

    private func searchFiles() async {
        searching = true
        files = []
        tracked = model.trackedPaths()
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        let term = query
        let root = EngineModel.downloadsURL
        let task = Task.detached(priority: .utility) { FileSearch.run(term, in: root) }
        let hits = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard !Task.isCancelled else { return }
        files = hits
        searching = false
    }

    private func fileRow(_ hit: FileSearch.Hit) -> some View {
        let isTracked = tracked.contains(hit.url.standardizedFileURL.path(percentEncoded: false))
        let size = hit.size.map { Int64($0).formatted(.byteCount(style: .file)) } ?? "—"
        let date = hit.modified?.formatted(.dateTime.day().month(.abbreviated).hour().minute()) ?? ""
        let label = [hit.url.lastPathComponent, hit.folder, size, date, isTracked ? "Downloaded by Rays" : nil]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        return HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: hit.url.path(percentEncoded: false)))
                .resizable()
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.highlighted(hit.url.lastPathComponent, matching: query))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(hit.folder)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isTracked {
                Image(systemName: "arrow.down.circle")
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
            VStack(alignment: .trailing, spacing: 2) {
                Text(size)
                Text(date)
            }
            .font(.callout)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, LayoutMetrics.hoverInset)
        .frame(minHeight: LayoutMetrics.rowHeight)
        .contentShape(.rect)
        .onTapGesture(count: 2) { open(hit) }
        .contextMenu {
            Button("Open") { open(hit) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([hit.url]) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(hit.url.path(percentEncoded: false), forType: .string)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAction { open(hit) }
    }

    private func open(_ hit: FileSearch.Hit) {
        if hit.isFolder {
            onOpenFolder(hit.url)
        } else {
            NSWorkspace.shared.open(hit.url)
        }
    }

    /// Bolds every case- and diacritic-insensitive match of the query in a file name.
    private static func highlighted(_ name: String, matching term: String) -> AttributedString {
        var text = AttributedString(name)
        var from = name.startIndex
        while from < name.endIndex,
              let found = name.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: from..<name.endIndex),
              let lower = AttributedString.Index(found.lowerBound, within: text),
              let upper = AttributedString.Index(found.upperBound, within: text) {
            text[lower..<upper].font = .body.bold()
            from = found.upperBound
        }
        return text
    }
}

/// Recursive name search under the downloads folder. Runs off the main actor.
enum FileSearch {
    struct Hit: Identifiable, Sendable {
        let url: URL
        let isFolder: Bool
        let size: Int?
        let modified: Date?
        /// The containing folders relative to Downloads, joined with " › ".
        let folder: String

        var id: URL { url }
    }

    static let maxDepth = 4
    static let maxHits = 200

    static func run(_ term: String, in root: URL) -> [Hit] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        let rootParts = root.standardizedFileURL.pathComponents
        var hits: [Hit] = []
        for case let url as URL in walker {
            if Task.isCancelled || hits.count >= maxHits { break }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isFolder = values?.isDirectory == true
            if isFolder, walker.level >= maxDepth { walker.skipDescendants() }
            guard url.pathExtension != "part", url.lastPathComponent.localizedStandardContains(term) else { continue }
            let inside = url.deletingLastPathComponent().standardizedFileURL.pathComponents.dropFirst(rootParts.count)
            hits.append(Hit(
                url: url, isFolder: isFolder, size: values?.fileSize, modified: values?.contentModificationDate,
                folder: inside.isEmpty ? "Downloads" : inside.joined(separator: " › ")))
        }
        return hits
    }
}
