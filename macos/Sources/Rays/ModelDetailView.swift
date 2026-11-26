import AppKit
import SwiftUI

/// An opened Hugging Face model: pick a version or files, choose where they go, and download them.
struct ModelDetailView: View {
    let repo: HfRepo
    let destinations: [String: [String: String]]
    @Environment(EngineModel.self) private var model
    @Environment(NavHistory.self) private var nav
    @AppStorage(SettingsKey.replaceExisting) private var replaceExisting = false
    @State private var selected: Set<String>
    /// nil means the default folder under AI Models.
    @State private var chosen: URL?
    @State private var added: [HfAdd]?
    @State private var freeBytes: UInt64?
    /// Notes from the disk for the selected files, read when the choice changes rather than on every redraw.
    @State private var fileNotes: [String: String] = [:]
    @State private var downloading = false
    @State private var errorText: String?
    /// nil until the user picks; then Main, or the queue named "Hugging Face" if there is one.
    @State private var chosenQueue: UInt64?

    private struct NoteInputs: Equatable {
        let selected: Set<String>
        let dir: URL
        let replace: Bool
    }

    init(repo: HfRepo, destinations: [String: [String: String]]) {
        self.repo = repo
        self.destinations = destinations
        _selected = State(initialValue: Set(hfRecommended(files: repo.files)))
    }

    private var files: [HfFile] { repo.files.filter { selected.contains($0.path) } }
    private var total: UInt64 { files.reduce(0) { $0 + $1.size } }
    private var versions: [HfVersion] { hfVersions(files: repo.files) }
    private var isGGUF: Bool { repo.files.contains { $0.path.hasSuffix(".gguf") } }
    private var needsToken: Bool { repo.gated && !model.hasHFToken }
    private var notEnoughSpace: Bool { freeBytes.map { total > $0 } ?? false }
    private func count(_ match: (HfAddStatus) -> Bool) -> Int {
        (added ?? []).filter { match($0.status) }.count
    }

    private func plural(_ n: Int) -> String { n == 1 ? "1 file" : "\(n) files" }

    private var bannerText: String? {
        let new = count { status in
            if case .added = status { return true }
            return false
        }
        let queued = count { status in
            if case .alreadyQueued = status { return true }
            return false
        }
        func follow(_ n: Int) -> String { n == 1 ? "it" : "them" }
        switch (new, queued) {
        case (0, 0): return nil
        case (_, 0): return "Added \(plural(new)). Follow \(follow(new)) in Downloads"
        case (0, _): return "\(plural(queued)) already in Downloads. Follow \(follow(queued)) in Downloads"
        default: return "Added \(plural(new)), \(plural(queued)) already in Downloads. Follow them in Downloads"
        }
    }

    private var dir: URL {
        chosen ?? AIModelsFolder.base(downloadsDir: EngineModel.downloadsURL, destinations: destinations)
            .appending(path: repo.id, directoryHint: .isDirectory)
    }

    private var lmStudioDir: URL? {
        AIModelsFolder.lmStudioModels?.appending(path: repo.id, directoryHint: .isDirectory)
    }

    var body: some View {
        List {
            ModelHeaderCard(repo: repo, isGGUF: isGGUF, total: total, freeBytes: freeBytes)
                .plainRow()
            if !versions.isEmpty {
                ModelVersionPills(versions: versions, tint: ModelKind(pipelineTag: repo.pipelineTag).color, selected: $selected)
                    .plainRow()
            }
            filesHeader
                .plainRow()
            ForEach(repo.files, id: \.path) { file in
                ModelFileRow(
                    file: file,
                    isOn: Binding(
                        get: { selected.contains(file.path) },
                        set: { on in if on { selected.insert(file.path) } else { selected.remove(file.path) } }),
                    note: note(for: file))
                .plainRow(horizontal: LayoutMetrics.margin - LayoutMetrics.hoverInset)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .scrollEdgeEffectStyle(.soft, for: .all)
        .navigationTitle(hfNameParts(repo.id).name)
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .task(id: dir) { freeBytes = Self.freeSpace(near: dir) }
        .task(id: NoteInputs(selected: selected, dir: dir, replace: replaceExisting)) { fileNotes = diskNotes() }
        .onChange(of: selected) { _, _ in added = nil }
        .onChange(of: dir) { _, _ in added = nil }
    }

    private var filesHeader: some View {
        HStack {
            Text("Files").font(.headline)
            Text("\(selected.count) of \(repo.files.count) selected").foregroundStyle(.secondary)
            Spacer()
            Button("Recommended") { selected = Set(hfRecommended(files: repo.files)) }
            Button("All") { selected = Set(repo.files.map(\.path)) }
            Button("None") { selected = [] }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.top, 8)
    }

    /// Per-file status after a download, or a warning about a same-name file already in the folder.
    private func note(for file: HfFile) -> (text: String, isError: Bool)? {
        if let status = added?.first(where: { $0.path == file.path })?.status {
            switch status {
            case .alreadyThere: return ("Already downloaded", false)
            case .alreadyQueued: return ("Already in Downloads", false)
            case .rejected(let error): return (error, true)
            default: return nil
            }
        }
        return fileNotes[file.path].map { ($0, false) }
    }

    /// The notes that need the disk: a same-name file already in the folder for each selected file.
    private func diskNotes() -> [String: String] {
        var notes: [String: String] = [:]
        for file in repo.files where selected.contains(file.path) {
            let target = dir.appending(path: file.path)
            guard FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) else { continue }
            let size = try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize
            if size == Int(file.size) {
                notes[file.path] = "Already downloaded"
            } else if replaceExisting {
                notes[file.path] = "Replaces the file there"
            } else {
                notes[file.path] = "Saves as \(Self.freeName(for: target)). Some apps need exact file names"
            }
        }
        return notes
    }

    private var saveTo: some View {
        Menu {
            Button("AI Models folder") { chosen = nil }
            if let lmStudioDir {
                Button("LM Studio models folder") { chosen = lmStudioDir }
            }
            Button("Choose…") { chooseFolder() }
        } label: {
            Label {
                Text((dir.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } icon: {
                Image(systemName: "folder")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .glassEffect(.regular.interactive(), in: .capsule)
        .help("Save to")
        .accessibilityLabel("Save to")
        .frame(maxWidth: 360, alignment: .leading)
    }

    private var bottomBar: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if needsToken {
                HStack {
                    Text("This model is gated. Add your Hugging Face token in the Models settings")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Models") { UserDefaults.standard.set(true, forKey: "settingsCard.models"); nav.replaceSub(nil) }
                }
            }
            if let bannerText {
                HStack {
                    Text(bannerText).foregroundStyle(.secondary)
                    Spacer()
                    Button("Show Downloads") {
                        NotificationCenter.default.post(name: .openDownloads, object: nil)
                    }
                }
            }
            if notEnoughSpace, let freeBytes {
                Text("Not enough space: needs \(byteText(total)), \(byteText(freeBytes)) free")
                    .foregroundStyle(.red)
            }
            if let errorText {
                Text(errorText).foregroundStyle(.red)
            }
            GlassEffectContainer(spacing: 12) {
                HStack {
                    saveTo
                    Spacer()
                    queuePicker
                    Button(total == 0 ? "Download" : "Download \(byteText(total))", action: download)
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(files.isEmpty || notEnoughSpace || needsToken || downloading)
                }
            }
        }
        .font(.callout)
        .padding(.horizontal, LayoutMetrics.margin)
        .padding(.vertical, 12)
    }

    /// Resolved at each use, so a deleted choice falls back instead of sending a stale id.
    private var queueId: UInt64 {
        if let chosenQueue, chosenQueue == 0 || model.queues.contains(where: { $0.id == chosenQueue }) { return chosenQueue }
        return model.queues.first { $0.config.name == "Hugging Face" }?.id ?? 0
    }

    private var queuePicker: some View {
        Menu {
            Picker("Queue", selection: Binding(get: { queueId }, set: { chosenQueue = $0 })) {
                Label("Download now", systemImage: "arrow.down.circle").tag(UInt64(0))
                ForEach(model.sortedQueues) { option in
                    Label(option.config.name, systemImage: QueueAppearances.shared.appearance(for: option).symbol).tag(option.id)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(model.queues.first { $0.id == queueId }?.config.name ?? "Download now",
                  systemImage: model.queues.first { $0.id == queueId }.map { QueueAppearances.shared.appearance(for: $0).symbol } ?? "arrow.down.circle")
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .glassEffect(.regular.interactive(), in: .capsule)
        .help("Queue")
        .accessibilityLabel("Queue")
        .accessibilityValue(model.queues.first { $0.id == queueId }?.config.name ?? "Download now")
        .fixedSize()
    }

    private func download() {
        let picked = (selected, dir)
        downloading = true
        Task {
            defer { downloading = false }
            do {
                let result = try await model.addModel(repo: repo.id, sha: repo.sha, files: files, to: dir, queue: queueId)
                // A choice changed during the call has already cleared `added`; this result is for the old choice.
                guard selected == picked.0, dir == picked.1 else { return }
                added = result
                errorText = nil
            } catch {
                errorText = EngineModel.message(for: error)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        chosen = url
    }

    /// Walks up to the nearest existing folder, since the save folder may not exist yet.
    private static func freeSpace(near url: URL) -> UInt64? {
        var folder = url
        while !FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)), folder.pathComponents.count > 1 {
            folder = folder.deletingLastPathComponent()
        }
        let bytes = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        return bytes.map { UInt64(max($0, 0)) }
    }

    /// "name (1).ext", the first free name, as the download would be saved under Keep both.
    private static func freeName(for url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var n = 1
        while true {
            let name = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            if !FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appending(path: name).path(percentEncoded: false)) {
                return name
            }
            n += 1
        }
    }
}

private extension View {
    func plainRow(horizontal: CGFloat = LayoutMetrics.margin) -> some View {
        listRowInsets(EdgeInsets(top: LayoutMetrics.rowSpacing / 2, leading: horizontal, bottom: LayoutMetrics.rowSpacing / 2, trailing: horizontal))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}
