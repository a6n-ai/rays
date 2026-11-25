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
    private(set) var hasHFToken = false
    private(set) var queues: [QueueView] = []
    /// Queue runs, newest first, at most `runLimit`.
    private(set) var runs: [QueueRun] = []
    static let runLimit = 200
    private(set) var bestTime: BestTime?
    private(set) var lastTest: SpeedTestResult?
    private(set) var testing = false
    private(set) var speedError: String?
    private(set) var hourly: [UInt64?] = Array(repeating: nil, count: 24)
    private(set) var speedSettings = SpeedSettings(autoTests: false, nightUntil: nil, nightPromptAnswered: true)
    private(set) var network = NetworkKind.unknown
    private(set) var speedProgress: SpeedProgress?
    /// The running (or last) test's rate over time, for the live chart.
    private(set) var liveSamples: [LivePoint] = []
    private(set) var speedHistory: [SpeedSample] = []
    @ObservationIgnored private var ignoreProgressUntil = Date.distantPast
    var confirmHotspot = false
    var nightPromptShown = false
    /// Slow-hint dismissals live only for this session.
    private(set) var dismissedHints = Set<UInt64>()
    private(set) var bestQueueId: UInt64?
    @ObservationIgnored private var hintShown = Set<UInt64>()
    @ObservationIgnored private var hintGone = Set<UInt64>()
    @ObservationIgnored private var runningSince: [UInt64: Date] = [:]
    @ObservationIgnored private var afterNightPrompt: (() -> Void)?
    var onQueueFinished: ((UInt64) -> Void)?
    @ObservationIgnored private var engine: Engine?
    @ObservationIgnored private var conditions: ConditionsMonitor?
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
        QueueActions.shared.onNotice = { [weak self] in self?.notice = $0 }
        onQueueFinished = { [weak self] id in
            guard let action = self?.queues.first(where: { $0.config.id == id })?.config.whenFinished else { return }
            QueueActions.shared.perform(action, running: self?.activeJobs.count ?? 0)
        }
    }

    /// Keeps the Mac's wake time in step with the queue's next run, one minute early. Needs the wake permission.
    private func syncWake(_ queue: QueueView) {
        guard let id = queue.config.id else { return }
        WakePermission.sync(queue: id, wake: queue.config.wake,
                            nextRun: queue.nextRun.map { Date(timeIntervalSince1970: TimeInterval($0)) })
    }

    func showNotice(_ text: String) { notice = text }

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
            engine.setReplaceExisting(on: defaults.bool(forKey: SettingsKey.replaceExisting))
            self.engine = engine
            hasHFToken = engine.hasHfToken()
            jobs = engine.snapshot()
            jobs.forEach(track)
            buckets = engine.buckets()
            queues = engine.queues()
            runs = engine.queueRuns(limit: UInt32(Self.runLimit))
            queues.forEach(syncWake)
            defaults.removeObject(forKey: "bestTimeQueueID")
            refreshSpeed(engine)
            conditions = ConditionsMonitor { [weak self] wifi, onPower, idle, network in
                self?.network = network
                engine.setConditions(wifi: wifi, onPower: onPower, idle: idle, network: network)
            }
            conditions?.start()
        } catch {
            startError = error.localizedDescription
        }
    }

    func restart() {
        conditions?.stop()
        conditions = nil
        engine?.shutdown()
        engine = nil
        jobs = []
        queues = []
        runs = []
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

    func add(_ text: String, queue: UInt64? = nil) {
        let urls = Links.inText(text)
        guard let engine else { return }
        guard !urls.isEmpty else {
            notice = "No link found. Links start with http://, https:// or s3://."
            return
        }
        let results = engine.addTo(urls: urls, dir: nil, names: Array(repeating: nil, count: urls.count), queue: queue)
        let rejected = results.filter { $0.id == nil }
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

    // Each lookup runs the aws or cf command, which takes seconds, so results stay for the app's
    // session and the Cloud page opens instantly; Refresh asks again.
    private(set) var awsProfiles: [String] = []
    private(set) var awsFound: [String: [AwsBucket]] = [:]
    private(set) var cloudflare: Result<CfAccount, Error>?
    @ObservationIgnored private var cloudLoaded = false

    func loadCloudLogins(force: Bool = false) async {
        guard let engine, force || !cloudLoaded else { return }
        cloudLoaded = true
        if force { awsFound = [:] }
        async let profiles = Task.detached { engine.awsProfiles() }.value
        do {
            cloudflare = .success(try await engine.cloudflareAccount())
        } catch {
            cloudflare = .failure(error)
        }
        awsProfiles = await profiles
    }

    func awsBuckets(_ profile: String) async throws -> [AwsBucket] {
        if let cached = awsFound[profile] { return cached }
        guard let engine else { return [] }
        let found = try await engine.awsBuckets(profile: profile)
        awsFound[profile] = found
        return found
    }

    /// Linked to an AWS CLI profile: the CLI supplies fresh keys each time and Rays stores none.
    func addAWSBucket(_ bucket: AwsBucket, profile: String) async throws {
        let config = BucketConfig(name: bucket.name, provider: "aws", endpoint: "https://s3.\(bucket.region).amazonaws.com",
                                  region: bucket.region, accessKeyId: "", pathStyle: false, profile: profile)
        try await addBucket(config, secret: "")
    }

    func addCloudflareBucket(_ name: String, account: String) async throws {
        guard let engine else { return }
        try await engine.addCloudflareBucket(accountId: account, name: name)
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

    func setReplaceExisting(_ on: Bool) {
        defaults.set(on, forKey: SettingsKey.replaceExisting)
        engine?.setReplaceExisting(on: on)
    }

    /// Thrown by the Hugging Face calls when the engine did not start, so the UI can say so.
    private var runningEngine: Engine {
        get throws {
            guard let engine else { throw EngineError.Io(msg: "The Rays engine is not running.") }
            return engine
        }
    }

    func hfSearch(_ query: String) async throws -> [HfModel] {
        try await runningEngine.hfSearch(query: query)
    }

    func hfModel(_ repo: String) async throws -> HfRepo {
        try await runningEngine.hfModel(repo: repo)
    }

    /// The engine call can block on disk, so it runs off the main actor.
    func addModel(repo: String, sha: String, files: [HfFile], to dir: URL, queue: UInt64? = nil) async throws -> [HfAdd] {
        let engine = try runningEngine
        let destDir = dir.path(percentEncoded: false)
        return await Task.detached { engine.addHf(repo: repo, sha: sha, files: files, destDir: destDir, queue: queue) }.value
    }

    /// Reads a file from disk, so it runs off the main actor.
    func readModelManifest(_ dir: URL) async throws -> HfManifest? {
        let engine = try runningEngine
        let path = dir.path(percentEncoded: false)
        return await Task.detached { engine.readModelManifest(dir: path) }.value
    }

    func verifyFiles(_ dir: URL, files: [HfFile]) async throws -> [VerifyResult] {
        try await runningEngine.verifyFiles(dir: dir.path(percentEncoded: false), files: files)
    }

    func setHFToken(_ token: String?) throws {
        try runningEngine.setHfToken(token: token)
        hasHFToken = engine?.hasHfToken() ?? false
    }

    func saveQueue(_ config: QueueConfig) throws -> UInt64 {
        let engine = try runningEngine
        let id = try engine.saveQueue(config: config)
        queues = engine.queues()
        if let saved = queues.first(where: { $0.config.id == id }) { syncWake(saved) }
        return id
    }

    func deleteQueue(_ id: UInt64) throws {
        let engine = try runningEngine
        try engine.deleteQueue(id: id)
        queues = engine.queues()
        WakePermission.sync(queue: id, wake: false, nextRun: nil)
        QueueAppearances.shared.clear(id)
    }

    /// Shows a queue action's failure in the notice line; `notice` is only settable in this file.
    func queueFailed(_ action: String, _ error: Error) {
        notice = "Couldn't \(action): \(Self.message(for: error))"
    }

    func moveToQueue(job: UInt64, queue: UInt64) { engine?.moveToQueue(job: job, queue: queue) }

    func startQueue(_ id: UInt64) { engine?.startQueue(id: id) }

    func stopQueue(_ id: UInt64) { engine?.stopQueue(id: id) }

    func runQueueNow(_ id: UInt64) { engine?.runQueueNow(id: id) }

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
    /// A file still in the folder its job was saved to says "Saved in", so it reads the same after a restart.
    func location(of file: URL, job: JobView? = nil) -> String {
        let root = Self.downloadsURL.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let parent = file.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let parts = parent.pathComponents
        let savedHere = job?.dir.map { dir in
            let saved = URL(filePath: dir).resolvingSymlinksInPath().standardizedFileURL.pathComponents
            return parts.starts(with: saved)
        } ?? false
        guard parts.count >= root.count, Array(parts.prefix(root.count)) == root else {
            return savedHere ? "Saved in " + parent.tildePath : parent.tildePath
        }
        let inside = parts.dropFirst(root.count)
        let verb = savedHere ? "Saved in " : "Sorted into "
        return inside.isEmpty ? "In Downloads" : verb + inside.joined(separator: " › ")
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

    /// Finished files go to the Trash (so the user can put them back); unfinished ones lose their partial file.
    func removeAndTrash(_ jobs: [JobView]) {
        let urls = jobs.filter(\.isDone).compactMap(locate)
        if !urls.isEmpty {
            NSWorkspace.shared.recycle(urls) { _, error in
                guard error != nil else { return }
                Task { @MainActor in self.notice = "Couldn't move some files to the Trash." }
            }
        }
        for job in jobs { remove(job.id, deletePartial: job.hasPartial) }
    }

    /// A finished download may have been moved by the sorter, so a same-named, same-size file under the downloads folder counts.
    func locate(_ job: JobView) -> URL? {
        if files.hasBookmark(for: job.id), let url = files.currentURL(for: job.id) { return url }
        guard let path = job.finishedPath else { return nil }
        if FileManager.default.fileExists(atPath: path) { return URL(filePath: path) }
        // The sorter's log says where it put the file, even after an AI rename; follow it from then on.
        if let sorted = SorterJournal.target(for: URL(filePath: path).lastPathComponent) {
            files.record(id: job.id, url: sorted)
            return sorted
        }
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

    /// A missing file that sits in the Trash, so the row can say so instead of "deleted".
    func isInTrash(_ job: JobView) -> Bool {
        let trash = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".Trash")
        return FileManager.default.fileExists(atPath: trash.appending(path: job.name).path(percentEncoded: false))
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

    func shutdown() {
        conditions?.stop()
        engine?.shutdown()
    }

    private func apply(_ event: JobEvent) {
        switch event {
        case .upsert(let job):
            if job.isActive { runningSince[job.id] = runningSince[job.id] ?? Date() } else { runningSince[job.id] = nil }
            if let index = jobs.firstIndex(where: { $0.id == job.id }) {
                jobs[index] = job
            } else {
                jobs.append(job)
            }
            track(job)
        case .removed(let id):
            runningSince[id] = nil
            files.forget(id)
            jobs.removeAll { $0.id == id }
        case .queueChanged(let queue):
            if let index = queues.firstIndex(where: { $0.config.id == queue.config.id }) {
                queues[index] = queue
            } else {
                queues.append(queue)
            }
            syncWake(queue)
            bestQueueId = engine?.bestTimeQueueId()
        case .queueFinished(let id):
            onQueueFinished?(id)
        case .runChanged(let run):
            if let index = runs.firstIndex(where: { $0.id == run.id }) {
                runs[index] = run
            } else {
                runs.insert(run, at: 0)
                if runs.count > Self.runLimit { runs.removeLast() }
            }
        case .speedTestProgress(let phase, let bps, let elapsed, let total):
            // A late event from a test that already ended must not bring the indicator back.
            if !testing, phase == .download, Date() < ignoreProgressUntil { break }
            if phase == .latency { liveSamples = [] } else { liveSamples.append(LivePoint(ms: elapsed, bps: bps)) }
            speedProgress = SpeedProgress(phase: phase, bps: bps, elapsedMs: elapsed, totalMs: total)
            // A test the app did not start (an automatic one) ends here; there is no result call to clear it.
            if !testing, elapsed >= total {
                speedProgress = nil
                refreshSpeed()
                loadSpeedHistory()
            }
        }
    }
}

enum SettingsKey {
    static let speedLimit = "speedLimitBytes"
    static let connections = "connectionsPerFile"
    static let maxRunning = "maxRunning"
    static let replaceExisting = "replaceExisting"
    static let downloadsDir = "downloadsDir"
    static let sorterPath = "sorterPath"
    static let menuBar = "showsMenuBar"
    static let clipboard = "offersCopiedLinks"
    static let queueDefaultMaxRunning = "queueDefaultMaxRunning"
    static let queueDefaultSpeed = "queueDefaultSpeed"
    static let queueDefaultFinish = "queueDefaultFinish"
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
    /// The text with each web address in it clickable, for messages that quote one.
    static func clickable(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        for match in detector?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? [] {
            guard let url = match.url, url.scheme == "https", let range = Range(match.range, in: out) else { continue }
            out[range].link = url
        }
        return out
    }

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
        case .running, .retrying, .verifying: true
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

/// Where the sorter moved each file, from its log: `time name -> target (why)`. The last move wins.
@MainActor
enum SorterJournal {
    private static var cache: (stamp: Date, targets: [String: String])?

    static let log = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Rays/Sorter/sorter.log")

    /// The file's current place if the sorter moved it there and it is still there.
    static func target(for name: String) -> URL? {
        let stamp = (try? log.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        if cache?.stamp != stamp {
            cache = (stamp, parse((try? String(contentsOf: log, encoding: .utf8)) ?? ""))
        }
        guard let path = cache?.targets[name], FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(filePath: path)
    }

    /// Mirrors `parse_move` in sorter/src/status.rs.
    nonisolated static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let space = line.firstIndex(of: " "), Double(line[..<space]) != nil else { continue }
            let rest = line[line.index(after: space)...]
            guard let arrow = rest.range(of: " -> "), rest.hasSuffix(")") else { continue }
            let name = String(rest[..<arrow.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let body = rest[arrow.upperBound...].dropLast()
            guard let cut = body.range(of: " (duplicate of ") ?? body.range(of: " (", options: .backwards) else { continue }
            out[name] = String(body[..<cut.lowerBound])
        }
        return out
    }
}

extension EngineModel {
    /// Reads the engine's speed state. A test that was not saved stays shown until a newer one replaces it.
    func refreshSpeed() { if let engine { refreshSpeed(engine) } }

    fileprivate func refreshSpeed(_ engine: Engine) {
        bestTime = engine.bestTime()
        hourly = engine.hourlyTypical()
        speedSettings = engine.speedSettings()
        bestQueueId = engine.bestTimeQueueId()
        if let saved = engine.lastSpeedTest(), saved.at >= (lastTest?.at ?? 0) { lastTest = saved }
    }

    /// Asks first on a hotspot or metered connection. Ignored while a test is already running.
    func requestSpeedTest() {
        guard !testing, speedProgress == nil else { return }
        if network == .expensive { confirmHotspot = true } else { Task { await runSpeedTest(force: false) } }
    }

    func runSpeedTest(force: Bool) async {
        guard let engine, !testing else { return }
        testing = true
        speedError = nil
        liveSamples = []
        defer {
            testing = false
            speedProgress = nil
            ignoreProgressUntil = Date().addingTimeInterval(1)
        }
        do {
            lastTest = try await engine.runSpeedTest(force: force)
        } catch {
            let message = Self.message(for: error)
            // Stopping is the user's own action, not a failure.
            if message != "Speed test stopped" {
                speedError = message
                Task {
                    try? await Task.sleep(for: .seconds(10))
                    if speedError == message { speedError = nil }
                }
            }
        }
        refreshSpeed(engine)
        loadSpeedHistory()
    }

    func cancelSpeedTest() { if testing { engine?.cancelSpeedTest() } }

    func loadSpeedHistory() { speedHistory = engine?.speedHistory(limit: 500) ?? [] }

    /// A test is running that the app did not start; it can't be stopped.
    var automaticTestRunning: Bool { speedProgress != nil && !testing }

    func setAutoTests(_ on: Bool) {
        guard let engine else { return }
        var settings = engine.speedSettings()
        settings.autoTests = on
        engine.setSpeedSettings(s: settings)
        speedSettings = engine.speedSettings()
    }

    func clearSpeedHistory() {
        engine?.clearSpeedHistory()
        lastTest = nil
        refreshSpeed()
    }

    /// Whether the Best time queue's night week is running now.
    var nightWeekActive: Bool { (speedSettings.nightUntil ?? 0) > Int64(Date().timeIntervalSince1970) }

    func startNightWeek() {
        guard let engine else { return }
        engine.startNightWeek()
        markNightPromptAnswered(engine)
    }

    private func markNightPromptAnswered(_ engine: Engine) {
        var settings = engine.speedSettings()
        settings.nightPromptAnswered = true
        engine.setSpeedSettings(s: settings)
        speedSettings = engine.speedSettings()
    }

    /// Runs `go` once the one-time night-test question has been answered, asking it first if needed.
    func withNightPrompt(_ go: @escaping () -> Void) {
        guard let engine else { return }
        if engine.speedSettings().nightPromptAnswered { go(); return }
        afterNightPrompt = go
        nightPromptShown = true
    }

    func answerNightPrompt(allow: Bool) {
        guard let engine else { return }
        if allow { engine.startNightWeek() }
        markNightPromptAnswered(engine)
        afterNightPrompt?()
        afterNightPrompt = nil
    }

    /// The Best time queue, made by the engine on first use; it gets the moon look unless the user picked one.
    func bestTimeQueueID() throws -> UInt64 {
        let engine = try runningEngine
        let id = try engine.bestTimeQueue()
        queues = engine.queues()
        bestQueueId = id
        QueueAppearances.shared.setIfMissing(QueueAppearance(symbol: "moon.stars", color: "indigo"), for: id)
        return id
    }

    func isBestTimeQueue(_ queue: QueueView) -> Bool {
        queue.config.followBestTime || bestQueueId == queue.id
    }

    func addAtBestTime(_ text: String) {
        withNightPrompt { [self] in
            do { add(text, queue: try bestTimeQueueID()) } catch { queueFailed("add to the Best time queue", error) }
        }
    }

    func moveToBestTime(_ job: UInt64) {
        dismissedHints.insert(job)
        withNightPrompt { [self] in
            do { moveToQueue(job: job, queue: try bestTimeQueueID()) } catch { queueFailed("move the download", error) }
        }
    }

    func dismissHint(_ job: UInt64) { dismissedHints.insert(job) }

    /// "Usually 3x faster at 01:00" when a big, slow download would do much better in the best window.
    func slowHint(for job: JobView) -> String? {
        guard job.state == .running, !dismissedHints.contains(job.id), !hintGone.contains(job.id) else { return nil }
        let parts = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let now = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        guard (job.total ?? 0) >= 1_000_000_000,
              job.bytesPerSec > 0, let since = runningSince[job.id], Date().timeIntervalSince(since) >= 60,
              case .window(let start, let end, let typical, _, let confidence)? = bestTime, confidence != .low,
              typical >= 2 * job.bytesPerSec, !minuteInWindow(now, start: Int(start), end: Int(end)) else {
            // Once shown, a hint that stops holding does not come back.
            if hintShown.contains(job.id) { hintGone.insert(job.id) }
            return nil
        }
        hintShown.insert(job.id)
        return "Usually \(typical / job.bytesPerSec)× faster at \(SchedulerTime.hhmm(start))"
    }
}

extension BestTime {
    /// "01:00–05:00", or the default window while there is not enough data.
    var windowText: String {
        if case .window(let start, let end, _, _, _) = self { return "\(SchedulerTime.hhmm(start))–\(SchedulerTime.hhmm(end))" }
        return "01:00–06:00"
    }

    var hasWindow: Bool { if case .window = self { true } else { false } }
}

enum SpeedFormat {
    /// 100 or more shows no decimals; below that, one.
    static func mbps(_ bps: UInt64) -> String {
        let value = Double(bps) * 8 / 1_000_000
        return (value >= 100 ? String(Int(value.rounded())) : String(format: "%.1f", value)) + " Mb/s"
    }

    static func ago(_ at: Int64) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: Date(timeIntervalSince1970: TimeInterval(at)), relativeTo: Date())
    }
}

/// Whether a minute of the day falls in [start, end), where a window like 23:00 to 03:00 wraps past midnight.
func minuteInWindow(_ minute: Int, start: Int, end: Int) -> Bool {
    start <= end ? (start..<end).contains(minute) : (minute >= start || minute < end)
}

func hourInWindow(_ h: Int, start: Int, end: Int) -> Bool { minuteInWindow(h * 60, start: start, end: end) }

struct SpeedProgress: Equatable {
    var phase: SpeedTestPhase
    var bps: UInt64
    var elapsedMs: UInt32
    var totalMs: UInt32

    var fraction: Double { totalMs == 0 ? 0 : min(1, Double(elapsedMs) / Double(totalMs)) }
}

struct LivePoint: Equatable {
    var ms: UInt32
    var bps: UInt64
}

extension NetworkKind {
    var title: String {
        switch self {
        case .wifi: "Wi-Fi"
        case .wired: "Wired"
        case .expensive: "Hotspot"
        case .other, .unknown: "Other"
        }
    }

    var symbol: String {
        switch self {
        case .wifi: "wifi"
        case .wired: "cable.connector"
        case .expensive: "antenna.radiowaves.left.and.right"
        case .other, .unknown: "network"
        }
    }
}
