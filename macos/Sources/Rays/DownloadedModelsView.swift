import SwiftUI

struct DownloadedModel: Identifiable, Equatable {
    let url: URL
    let org: String
    let name: String
    let files: Int
    let bytes: UInt64
    var id: URL { url }

    /// Folders two levels deep, `<org>/<model>`. Reads file sizes, so call it off the main thread.
    static func scan(_ base: URL) -> [DownloadedModel] {
        let fm = FileManager.default
        func dirs(_ url: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        }
        var found: [DownloadedModel] = []
        for org in dirs(base) {
            for model in dirs(org) {
                var files = 0
                var bytes: UInt64 = 0
                let walk = fm.enumerator(at: model, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles])
                while let item = walk?.nextObject() as? URL {
                    let values = try? item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                    guard values?.isRegularFile == true else { continue }
                    files += 1
                    bytes += UInt64(values?.fileSize ?? 0)
                }
                found.append(DownloadedModel(url: model, org: org.lastPathComponent, name: model.lastPathComponent, files: files, bytes: bytes))
            }
        }
        return found.sorted { ($0.org, $0.name) < ($1.org, $1.name) }
    }
}

/// The model folders inside the AI Models folder, with size and file count.
struct DownloadedModelsView: View {
    let folder: URL
    @State private var models: [DownloadedModel] = []
    @State private var loaded = false
    @State private var selection: URL?
    @State private var watcher = DirectoryWatcher()
    @State private var revision = 0

    var body: some View {
        Group {
            if models.isEmpty {
                if loaded {
                    EmptyState(symbol: "shippingbox", title: "No models yet", message: "Models you download appear here.")
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                List {
                    ForEach(models) { item in
                        DownloadedModelRow(item: item, isSelected: selection == item.id) { remove(item) }
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { reveal(item) }
                            .onTapGesture { selection = item.id }
                            .listRowInsets(EdgeInsets(
                                top: LayoutMetrics.rowSpacing / 2,
                                leading: LayoutMetrics.margin - LayoutMetrics.hoverInset,
                                bottom: LayoutMetrics.rowSpacing / 2,
                                trailing: LayoutMetrics.margin - LayoutMetrics.hoverInset))
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.inset)
                .tint(.gray)
                .scrollContentBackground(.hidden)
                .scrollEdgeEffectStyle(.soft, for: .all)
            }
        }
        .task(id: "\(folder.path)|\(revision)") {
            let base = folder
            models = await Task.detached(priority: .userInitiated) { DownloadedModel.scan(base) }.value
            loaded = true
        }
        .onAppear { watch() }
        .onChange(of: folder) { _, _ in watch() }
        .onDisappear { watcher.stop() }
    }

    // Only the first level is watched; downloads landing deeper show up on the next visit.
    private func watch() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        watcher.watch(folder) { revision += 1 }
    }

    private func reveal(_ item: DownloadedModel) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    private func remove(_ item: DownloadedModel) {
        NSWorkspace.shared.recycle([item.url]) { _, _ in
            Task { @MainActor in revision += 1 }
        }
    }
}

private struct DownloadedModelRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let item: DownloadedModel
    let isSelected: Bool
    let trash: () -> Void
    @State private var isHovered = false

    private var status: String {
        "\(item.org) · \(item.files == 1 ? "1 file" : "\(item.files) files") · \(byteText(item.bytes))"
    }

    var body: some View {
        HStack(spacing: LayoutMetrics.gap) {
            ModelTile(symbol: "shippingbox.fill", color: .gray)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 0) {
                Button(action: trash) {
                    Image(systemName: "trash")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: LayoutMetrics.rowHitArea, height: LayoutMetrics.rowHitArea)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Move to Trash")
                .accessibilityLabel("Move \(item.name) to Trash")
                Menu {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                    Button("Move to Trash", action: trash)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: LayoutMetrics.rowHitArea, height: LayoutMetrics.rowHitArea)
                        .contentShape(Circle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .help("More")
                .accessibilityLabel("More actions for \(item.name)")
            }
            .opacity(isHovered ? 1 : 0)
        }
        .frame(height: LayoutMetrics.rowHeight)
        .padding(.horizontal, LayoutMetrics.hoverInset)
        .listRowBackground(RowHighlight(selected: isSelected, hovered: isHovered))
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .smooth(duration: 0.15), value: isHovered)
    }
}
