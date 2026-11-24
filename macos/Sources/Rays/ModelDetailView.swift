import AppKit
import SwiftUI

/// An opened Hugging Face model: pick a version or files, choose where they go, and download them.
struct ModelDetailView: View {
    let repo: HfRepo
    let destinations: [String: [String: String]]
    @Environment(EngineModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @AppStorage(SettingsKey.replaceExisting) private var replaceExisting = false
    @State private var selected: Set<String>
    /// nil means the default folder under AI Models.
    @State private var chosen: URL?
    @State private var added: [HfAdd]?
    @State private var freeBytes: UInt64?

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
        switch (new, queued) {
        case (0, 0): return nil
        case (_, 0): return "Added \(plural(new)). Follow them in Downloads"
        case (0, _): return "\(plural(queued)) already in Downloads. Follow them in Downloads"
        default: return "Added \(plural(new)), \(queued) already in Downloads. Follow them in Downloads"
        }
    }

    private var dir: URL {
        chosen ?? AIModelsFolder.base(downloadsDir: EngineModel.downloadsURL, destinations: destinations)
            .appending(path: repo.id, directoryHint: .isDirectory)
    }

    private var lmStudioDir: URL? {
        AIModelsFolder.lmStudioModels?.appending(path: repo.id, directoryHint: .isDirectory)
    }

    private var hubURL: URL? { URL(string: "https://huggingface.co/\(repo.id)") }

    var body: some View {
        List {
            Section {
                header
            }
            if !versions.isEmpty {
                Section {
                    versionChips
                } header: {
                    Text("Version")
                }
            }
            Section {
                ForEach(repo.files, id: \.path) { fileRow($0) }
            } header: {
                filesHeader
            }
            Section {
                saveTo
            }
            Section {
                footer
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .task(id: dir) { freeBytes = Self.freeSpace(near: dir) }
        .onChange(of: selected) { _, _ in added = nil }
        .onChange(of: dir) { _, _ in added = nil }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(repo.id).font(.title3.weight(.semibold)).textSelection(.enabled).lineLimit(1)
                Spacer()
                Text(byteText(total)).font(.title3).foregroundStyle(.secondary).monospacedDigit()
            }
            HStack(spacing: 10) {
                if isGGUF {
                    Text("GGUF")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: .capsule)
                }
                Label(repo.downloads.formatted(.number.notation(.compactName)), systemImage: "arrow.down.circle")
                if let hubURL { Link("Open on Hugging Face", destination: hubURL) }
                Spacer()
                if let freeBytes {
                    Text("\(byteText(freeBytes)) free").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            if needsToken {
                HStack {
                    Text("This model is gated. Add your Hugging Face token in Settings")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Settings") { openSettings() }
                }
                .font(.callout)
            }
        }
    }

    private var versionChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(versions, id: \.label) { version in
                    let on = Set(version.files) == selected
                    Button {
                        selected = Set(version.files)
                    } label: {
                        Text("\(version.label)\(version.recommended ? " ★" : "")  \(byteText(version.size))")
                            .font(.callout)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(on ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06), in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
    }

    private var filesHeader: some View {
        HStack {
            Text("Files")
            Text("\(selected.count) of \(repo.files.count) selected").foregroundStyle(.secondary)
            Spacer()
            Button("Recommended") { selected = Set(hfRecommended(files: repo.files)) }
            Button("Select all") { selected = Set(repo.files.map(\.path)) }
            Button("None") { selected = [] }
        }
        .buttonStyle(.link)
        .textCase(nil)
    }

    private func fileRow(_ file: HfFile) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Toggle(isOn: Binding(
                    get: { selected.contains(file.path) },
                    set: { on in if on { selected.insert(file.path) } else { selected.remove(file.path) } }
                )) {
                    Text(file.path).lineLimit(1).truncationMode(.middle)
                }
                .toggleStyle(.checkbox)
                Spacer()
                Text(byteText(file.size)).foregroundStyle(.secondary).monospacedDigit()
            }
            if let note = note(for: file) {
                Text(note.text)
                    .font(.caption)
                    .foregroundStyle(note.isError ? Color.red : Color.secondary)
                    .padding(.leading, 22)
            }
        }
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
        guard selected.contains(file.path) else { return nil }
        let target = dir.appending(path: file.path)
        guard FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) else { return nil }
        let size = try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize
        if size == Int(file.size) { return ("Already downloaded", false) }
        if replaceExisting { return ("Replaces the file there", false) }
        return ("Saves as \(Self.freeName(for: target)). Some apps need exact file names", false)
    }

    private var saveTo: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Save to")
                Text((dir.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Choose…") { chooseFolder() }
            }
            if let lmStudioDir {
                Toggle("Save into LM Studio's models folder", isOn: Binding(
                    get: { chosen == lmStudioDir },
                    set: { chosen = $0 ? lmStudioDir : nil }
                ))
                .toggleStyle(.checkbox)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .trailing, spacing: 6) {
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
            HStack {
                Spacer()
                Button("Download \(byteText(total))") {
                    added = model.addModel(repo: repo.id, sha: repo.sha, files: files, to: dir)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(files.isEmpty || notEnoughSpace || needsToken)
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
