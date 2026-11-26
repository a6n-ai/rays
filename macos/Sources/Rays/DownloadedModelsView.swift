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

/// Verify state for one model folder. Held by the view only, never written to disk.
enum VerifyState: Equatable {
    case running
    case noRecord
    case failed(String)
    case checked(Checked)
    case queued(Int, issues: [String])

    struct Checked: Equatable {
        let repo: String
        let sha: String
        let files: [HfFile]
        let results: [VerifyResult]
        /// Checked against the latest Hugging Face revision, not the recorded download.
        let latest: Bool
        /// Red lines that are not a file's own status: skipped paths, trash failures.
        var issues: [String] = []

        var problems: [VerifyResult] { results.filter { $0.status.problem != nil } }
    }
}

private extension VerifyStatus {
    var problem: String? {
        switch self {
        case .ok, .sizeChecked: nil
        case .missing: "Missing"
        case .wrongSize: "Wrong size"
        case .wrongChecksum: "Checksum didn't match"
        }
    }

    var isWrongContent: Bool {
        switch self {
        case .wrongSize, .wrongChecksum: true
        default: false
        }
    }
}

/// The model folders inside the AI Models folder, with size and file count.
struct DownloadedModelsView: View {
    let folder: URL
    @Environment(EngineModel.self) private var model
    @AppStorage(SettingsKey.replaceExisting) private var replaceExisting = false
    @State private var models: [DownloadedModel] = []
    @State private var loaded = false
    @State private var selection: URL?
    @State private var watcher = DirectoryWatcher()
    @State private var revision = 0
    @State private var checks: [URL: VerifyState] = [:]
    @State private var page = 0
    @AppStorage(Paging.key) private var pageSize = Paging.defaultSize

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
                    ForEach(ListControls.page(models, page, pageSize)) { item in
                        DownloadedModelRow(
                            item: item,
                            isSelected: selection == item.id,
                            state: checks[item.id],
                            trash: { remove(item) },
                            verify: { verifyFiles(item) },
                            lookUp: { lookUp(item) },
                            redownload: { redownload(item, $0) })
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
                .scrollContentBackground(.hidden)
                .scrollEdgeEffectStyle(.soft, for: .all)
                .safeAreaInset(edge: .bottom, spacing: 0) { PageBar(count: models.count, page: $page, padded: true) }
            }
        }
        .task(id: "\(folder.path)|\(revision)") {
            let base = folder
            models = await Task.detached(priority: .userInitiated) { DownloadedModel.scan(base) }.value
            let listed = Set(models.map(\.id))
            checks = checks.filter { listed.contains($0.key) }
            loaded = true
        }
        .onAppear { watch() }
        .onChange(of: folder) { _, _ in
            checks = [:]
            watch()
        }
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

    private func verifyFiles(_ item: DownloadedModel) {
        run(item) {
            guard let manifest = try await model.readModelManifest(item.url) else { return .noRecord }
            let results = try await model.verifyFiles(item.url, files: manifest.files)
            return .checked(.init(repo: manifest.repo, sha: manifest.sha, files: manifest.files, results: results, latest: false))
        }
    }

    private func lookUp(_ item: DownloadedModel) {
        run(item) {
            let repo = try await model.hfModel("\(item.org)/\(item.name)")
            let results = try await model.verifyFiles(item.url, files: repo.files)
            return .checked(.init(repo: repo.id, sha: repo.sha, files: repo.files, results: results, latest: true))
        }
    }

    private func redownload(_ item: DownloadedModel, _ checked: VerifyState.Checked) {
        let bad = Set(checked.problems.map(\.path))
        var base = checked
        var files: [HfFile] = []
        for file in checked.files where bad.contains(file.path) {
            if isInside(file.path, of: item.url) {
                files.append(file)
            } else {
                base.issues.append("\(file.path) — unsafe path")
            }
        }
        guard !files.isEmpty else {
            checks[item.id] = .checked(base)
            return
        }
        run(item) {
            var kept = base
            // With replace off the engine keeps both copies, so the bad ones go first to keep the names exact.
            // Only a wrong size or checksum is trashed: the engine confirmed those are regular files inside the folder,
            // while a missing file has nothing to trash and a symlinked path must never be followed.
            if !replaceExisting {
                let fm = FileManager.default
                let root = item.url.resolvingSymlinksInPath().path(percentEncoded: false) + "/"
                var trashed = false
                defer { if trashed { revision += 1 } }
                for result in checked.results where result.status.isWrongContent {
                    guard let file = files.first(where: { $0.path == result.path }) else { continue }
                    let url = item.url.appending(path: file.path)
                    let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().path(percentEncoded: false) + "/"
                    guard parent.hasPrefix(root) else {
                        kept.issues.append("\(file.path) — unsafe path")
                        continue
                    }
                    do {
                        try fm.trashItem(at: url, resultingItemURL: nil)
                        trashed = true
                    } catch {
                        kept.issues.append("Couldn't move \(file.path) to the Trash: \(EngineModel.message(for: error))")
                        return .checked(kept)
                    }
                }
            }
            let added = try await model.addModel(repo: kept.repo, sha: kept.sha, files: files, to: item.url)
            var queued = 0
            for result in added {
                switch result.status {
                case .added: queued += 1
                case .rejected(let error): kept.issues.append("\(result.path) — \(error)")
                default: break
                }
            }
            return .queued(queued, issues: kept.issues)
        }
    }

    /// Manifest paths come from the network or a file on disk, so only a relative path that stays inside the folder is used.
    private func isInside(_ path: String, of folder: URL) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.hasPrefix("/"), !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return false }
        return folder.appending(path: path).standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/")
    }

    /// One check per folder at a time, so a second Verify cannot start while one runs.
    private func run(_ item: DownloadedModel, _ work: @escaping () async throws -> VerifyState) {
        guard checks[item.id] != .running else { return }
        checks[item.id] = .running
        Task {
            do { checks[item.id] = try await work() }
            catch { checks[item.id] = .failed(EngineModel.message(for: error)) }
        }
    }
}

private struct DownloadedModelRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let item: DownloadedModel
    let isSelected: Bool
    let state: VerifyState?
    let trash: () -> Void
    let verify: () -> Void
    let lookUp: () -> Void
    let redownload: (VerifyState.Checked) -> Void
    @State private var isHovered = false

    private var status: String {
        "\(item.org) · \(item.files == 1 ? "1 file" : "\(item.files) files") · \(byteText(item.bytes))"
    }

    private var isRunning: Bool { state == .running }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: LayoutMetrics.gap) {
                IconTile(.localModel, size: TileSize.list)
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
                    if isRunning {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: LayoutMetrics.rowHitArea, height: LayoutMetrics.rowHitArea)
                            .accessibilityLabel("Verifying \(item.name)")
                    } else {
                        Button(action: verify) {
                            Image(systemName: "checkmark.shield")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.secondary)
                                .frame(width: LayoutMetrics.rowHitArea, height: LayoutMetrics.rowHitArea)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Verify files")
                        .accessibilityLabel("Verify \(item.name)")
                    }
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
                        Button("Verify files", action: verify).disabled(isRunning)
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
                .opacity(isHovered || isRunning ? 1 : 0)
            }
            .frame(height: LayoutMetrics.rowHeight)
            details
                .padding(.leading, LayoutMetrics.iconSize + LayoutMetrics.gap)
                .padding(.bottom, LayoutMetrics.rowSpacing / 2)
        }
        .padding(.horizontal, LayoutMetrics.hoverInset)
        .listRowBackground(RowHighlight(selected: isSelected, hovered: isHovered))
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .smooth(duration: 0.15), value: isHovered)
    }

    @ViewBuilder private var details: some View {
        switch state {
        case .noRecord:
            VStack(alignment: .leading, spacing: 6) {
                Text("Can't verify: no record of this download")
                    .foregroundStyle(.secondary)
                Button("Look up on Hugging Face", action: lookUp)
            }
            .font(.callout)
        case .failed(let message):
            Text(message)
                .font(.callout)
                .foregroundStyle(.red)
        case .checked(let checked):
            let total = checked.results.count
            let sizeOnly = checked.results.filter { $0.status == .sizeChecked }.count
            let problems = checked.problems.count
            let matching = checked.results.filter { $0.status == .ok }.count
            VStack(alignment: .leading, spacing: 6) {
                if problems == 0 && sizeOnly == 0 {
                    Label(total == 1 ? "All 1 file matches" : "All \(total) files match", systemImage: "checkmark")
                        .foregroundStyle(.green)
                } else if matching > 0 {
                    Label(matching == 1 ? "1 file matches" : "\(matching) files match", systemImage: "checkmark")
                        .foregroundStyle(.green)
                }
                if sizeOnly > 0 {
                    Text(sizeOnly == 1 ? "1 file checked by size only" : "\(sizeOnly) files checked by size only")
                        .foregroundStyle(.secondary)
                }
                ForEach(checked.problems, id: \.path) { result in
                    Text("\(result.path) — \(result.status.problem ?? "")")
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                ForEach(checked.issues, id: \.self) { issue in
                    Text(issue)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if problems > 0 {
                    Button(problems == 1 ? "Re-download 1 file" : "Re-download \(problems) files") { redownload(checked) }
                }
                if checked.latest {
                    Text("Checked against the latest revision")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
        case .queued(let count, let issues):
            VStack(alignment: .leading, spacing: 6) {
                Label(count == 1 ? "Queued 1 file in Downloads" : "Queued \(count) files in Downloads", systemImage: "arrow.down.circle")
                    .foregroundStyle(.secondary)
                ForEach(issues, id: \.self) { issue in
                    Text(issue)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .font(.callout)
        case .running, nil:
            EmptyView()
        }
    }
}
