import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class EngineModel {
    private(set) var jobs: [JobView] = []
    private(set) var startError: String?
    private(set) var notice: String?
    /// Bumped when the folders on disk may have changed, so the sidebar re-lists them.
    private(set) var folderRevision = 0
    private(set) var generation = 0
    private(set) var buckets: [BucketConfig] = []
    @ObservationIgnored private var engine: Engine?
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let files = FileTracker(storeURL: FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Rays/bookmarks.plist"))

    static var defaultDownloadsURL: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads")
    }

    /// The folder chosen in Settings, or the user's Downloads folder when none is chosen.
    static var downloadsURL: URL {
        guard let path = UserDefaults.standard.string(forKey: SettingsKey.downloadsDir), !path.isEmpty else {
            return defaultDownloadsURL
        }
        return URL(filePath: path, directoryHint: .isDirectory)
    }

    init() {
        defaults.register(defaults: [
            SettingsKey.speedLimit: 0, SettingsKey.connections: 4, SettingsKey.maxRunning: 3,
        ])
        start()
    }

    private func start() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dataDir = home.appending(path: "Library/Application Support/Rays", directoryHint: .isDirectory)
        let socket = home.appending(path: "Library/Application Support/Rays/dl.sock")
        do {
            try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: socket.deletingLastPathComponent(), withIntermediateDirectories: true)
            let config = EngineConfig(
                downloadsDir: Self.downloadsURL.path(percentEncoded: false),
                dataDir: dataDir.path(percentEncoded: false),
                socketPath: socket.path(percentEncoded: false),
                maxRunning: UInt32(min(10, max(1, defaults.integer(forKey: SettingsKey.maxRunning)))),
                connections: UInt32(min(16, max(1, defaults.integer(forKey: SettingsKey.connections)))),
                speedLimit: UInt64(max(0, defaults.integer(forKey: SettingsKey.speedLimit))))
            let engine = try Engine(config: config)
            self.engine = engine
            jobs = engine.snapshot()
            jobs.forEach(track)
            buckets = engine.buckets()
        } catch {
            startError = error.localizedDescription
        }
    }

    func restart() {
        engine?.shutdown()
        engine = nil
        jobs = []
        startError = nil
        generation += 1
        start()
    }

    func run() async {
        guard let engine else { return }
        while !Task.isCancelled {
            let events = await engine.nextEvents()
            // An empty batch means the engine's runtime is gone; without the pause this loop would spin.
            if events.isEmpty { try? await Task.sleep(for: .seconds(1)) }
            // A restart cancels this loop; its engine's late events must not reach the new job list.
            if Task.isCancelled { break }
            events.forEach(apply)
        }
    }

    func add(_ text: String) {
        let urls = Links.inText(text)
        guard let engine else { return }
        guard !urls.isEmpty else {
            notice = "No link found. Links start with http://, https:// or s3://."
            return
        }
        let rejected = engine.add(urls: urls).filter { $0.id == nil }
        notice = rejected.isEmpty
            ? nil
            : rejected.map { "Not added: \($0.url) (\($0.error ?? "unknown error"))" }.joined(separator: "\n")
    }

    func clearNotice() { notice = nil }

    var providers: [ProviderPreset] { engine?.providers() ?? [] }

    /// The preset's endpoint for this region and extra field, or nil while something it needs is missing.
    func providerEndpoint(_ provider: String, region: String, field: String) -> String? {
        try? engine?.providerEndpoint(provider: provider, region: region, field: field)
    }

    /// The engine lists the bucket once to check the keys before saving anything.
    func addBucket(_ config: BucketConfig, secret: String) async throws {
        guard let engine else { return }
        try await engine.addBucket(config: config, secret: secret)
        buckets = engine.buckets()
    }

    func removeBucket(_ name: String) throws {
        try engine?.removeBucket(name: name)
        buckets = engine?.buckets() ?? []
    }

    func listBucket(_ name: String, prefix: String, token: String?) async throws -> Listing {
        guard let engine else { return Listing(folders: [], objects: [], nextToken: nil) }
        return try await engine.listBucket(bucket: name, prefix: prefix, token: token)
    }

    /// Keys can hold spaces or `%`; the engine percent-decodes the link back to the exact key.
    func download(bucket: String, key: String) {
        add("s3://\(bucket)/\(key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key)")
    }

    func setSpeedLimit(_ bytesPerSec: Int) {
        defaults.set(bytesPerSec, forKey: SettingsKey.speedLimit)
        engine?.setSpeedLimit(bytesPerSec: UInt64(max(0, bytesPerSec)))
    }

    func setConnections(_ count: Int) {
        defaults.set(count, forKey: SettingsKey.connections)
        engine?.setConnections(n: UInt32(count))
    }

    func setMaxRunning(_ count: Int) {
        defaults.set(count, forKey: SettingsKey.maxRunning)
        engine?.setMaxRunning(n: UInt32(count))
    }

    /// nil resets to the user's Downloads folder. The engine is asked first, so a failure saves nothing.
    func setDownloadsDir(_ url: URL?) throws {
        try engine?.setDownloadsDir(path: (url ?? Self.defaultDownloadsURL).path(percentEncoded: false))
        defaults.set(url?.path(percentEncoded: false) ?? "", forKey: SettingsKey.downloadsDir)
        foldersChanged()
    }

    func foldersChanged() {
        files.refresh()
        folderRevision += 1
    }

    /// Standardized paths of finished downloads, so folder views can mark the files Rays fetched.
    func trackedPaths() -> Set<String> {
        Set(jobs.filter(\.isDone).compactMap { locate($0)?.standardizedFileURL.path(percentEncoded: false) })
    }

    /// Where a finished file sits relative to the downloads folder, for the row's status line.
    func location(of file: URL) -> String {
        let root = Self.downloadsURL.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let parent = file.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let parts = parent.pathComponents
        guard parts.count >= root.count, Array(parts.prefix(root.count)) == root else {
            return parent.tildePath
        }
        let inside = parts.dropFirst(root.count)
        return inside.isEmpty ? "In Downloads" : "Sorted into " + inside.joined(separator: " › ")
    }

    private func track(_ job: JobView) {
        guard job.isDone, !files.hasBookmark(for: job.id), let path = job.finishedPath else { return }
        files.record(id: job.id, url: URL(filePath: path))
    }

    /// The engine's own message; `localizedDescription` would show the Swift case name.
    static func message(for error: Error) -> String {
        switch error as? EngineError {
        case .Io(let msg)?, .Db(let msg)?, .InvalidUrl(let msg)?: msg
        default: error.localizedDescription
        }
    }

    func pause(_ id: UInt64) { engine?.pause(id: id) }

    func resume(_ id: UInt64) { engine?.resume(id: id) }

    func remove(_ id: UInt64, deletePartial: Bool) { engine?.remove(id: id, deletePartial: deletePartial) }

    /// A finished download may have been moved by the sorter, so a same-named, same-size file under the downloads folder counts.
    func locate(_ job: JobView) -> URL? {
        if files.hasBookmark(for: job.id) { return files.currentURL(for: job.id) }
        guard let path = job.finishedPath else { return nil }
        if FileManager.default.fileExists(atPath: path) { return URL(filePath: path) }
        guard let walker = FileManager.default.enumerator(
            at: Self.downloadsURL, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) else { return nil }
        let size = Int(clamping: job.total ?? job.done)
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true {
                if walker.level >= 4 { walker.skipDescendants() }
            } else if url.lastPathComponent == job.name, values?.fileSize == size {
                return url
            }
        }
        return nil
    }

    func reveal(_ job: JobView) {
        if let url = locate(job) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(Self.downloadsURL)
            notice = "Couldn't find \(job.name); it may have been moved."
        }
    }

    func open(_ job: JobView) {
        if let url = locate(job) {
            NSWorkspace.shared.open(url)
        } else {
            notice = "Couldn't find \(job.name); it may have been moved."
        }
    }

    /// Jobs that would lose progress on quit because they cannot resume.
    var unresumableActive: [JobView] {
        jobs.filter { !$0.resumable && $0.isActive }
    }

    func shutdown() { engine?.shutdown() }

    private func apply(_ event: JobEvent) {
        switch event {
        case .upsert(let job):
            if let index = jobs.firstIndex(where: { $0.id == job.id }) {
                jobs[index] = job
            } else {
                jobs.append(job)
            }
            track(job)
        case .removed(let id):
            files.forget(id)
            jobs.removeAll { $0.id == id }
        }
    }
}

enum SettingsKey {
    static let speedLimit = "speedLimitBytes"
    static let connections = "connectionsPerFile"
    static let maxRunning = "maxRunning"
    static let downloadsDir = "downloadsDir"
    static let sorterPath = "sorterPath"
}

struct SpeedPreset: Identifiable {
    let title: String
    let bytes: Int
    var id: Int { bytes }

    static func text(_ bytes: Int) -> String {
        Int64(bytes).formatted(.byteCount(style: .file)) + "/s"
    }

    static let all = [
        SpeedPreset(title: "Unlimited", bytes: 0),
        SpeedPreset(title: "1 MB/s", bytes: 1_000_000),
        SpeedPreset(title: "5 MB/s", bytes: 5_000_000),
        SpeedPreset(title: "10 MB/s", bytes: 10_000_000),
        SpeedPreset(title: "25 MB/s", bytes: 25_000_000),
    ]
}

/// Pulls web links out of dropped text and files. A .webloc file stores its link in a plist.
enum Links {
    static func fromFile(_ url: URL) -> String? {
        guard url.isFileURL else { return url.absoluteString }
        guard url.pathExtension == "webloc" else { return nil }
        return NSDictionary(contentsOf: url)?["URL"] as? String
    }

    /// Every http(s) or s3 link in pasted text, in order, without repeats. Handles the usual ways links get
    /// copied: one per line, separated by spaces, commas, semicolons or tabs (CSV and spreadsheet cells),
    /// quoted, inside Markdown `[name](url)` or HTML `href="url"`, and links pasted back to back.
    static func inText(_ text: String) -> [String] {
        // A link runs until whitespace, a quote, or a bracket; a new "http" also starts a new link.
        let pattern = #"(?:https?|s3)://[^\s"'<>\[\]{}|\\^`]+?(?=(?:https?|s3)://|[\s"'<>\[\]{}|\\^`]|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        var seen = Set<String>()
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            var link = String(text[range])
            // CSV / prose punctuation stuck to the end is not part of the link.
            while let last = link.last, ",;.:!?".contains(last) { link.removeLast() }
            // A closing ")" belongs to the link only if it has a matching "(" (Wikipedia-style URLs).
            while link.hasSuffix(")"), link.filter({ $0 == ")" }).count > link.filter({ $0 == "(" }).count { link.removeLast() }
            guard let url = URL(string: link), let host = url.host(), !host.isEmpty else { return nil }
            return seen.insert(url.absoluteString).inserted ? url.absoluteString : nil
        }
    }
}

extension JobView {
    var isActive: Bool {
        switch state {
        case .running, .retrying: true
        default: false
        }
    }

    var isDone: Bool {
        if case .done = state { true } else { false }
    }

    var isFinished: Bool {
        switch state {
        case .done, .failed: true
        default: false
        }
    }

    var finishedPath: String? {
        if case .done(let path) = state { path } else { nil }
    }

    /// A partial file exists on disk once bytes have arrived and the job has not finished.
    var hasPartial: Bool { done > 0 && !isDone }

    var sizeText: String {
        guard let total else { return byteText(done) }
        return "\(byteText(done)) of \(byteText(total))"
    }
}

func byteText(_ bytes: UInt64) -> String {
    Int64(clamping: bytes).formatted(.byteCount(style: .file))
}
