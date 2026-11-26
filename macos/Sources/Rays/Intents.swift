import AppIntents
import AppKit

struct IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    let text: String
    var localizedStringResource: LocalizedStringResource { "\(text)" }
}

/// The running app's model; intents run in the app process, which the system launches when needed.
@MainActor private func appModel() throws -> EngineModel {
    guard let model = AppDelegate.shared?.model else { throw IntentFailure(text: "Rays is not ready yet. Open Rays and try again.") }
    return model
}

/// A queue for Shortcuts. AddDownload leaves it empty for a direct download.
struct QueueEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Queue"
    static let defaultQuery = QueueEntityQuery()

    var id: Int
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct QueueEntityQuery: EntityQuery {
    @MainActor private func all() -> [QueueEntity] {
        (AppDelegate.shared?.model.sortedQueues ?? []).map { QueueEntity(id: Int($0.id), name: $0.config.name) }
    }

    @MainActor func entities(for identifiers: [Int]) async throws -> [QueueEntity] { all().filter { identifiers.contains($0.id) } }
    @MainActor func suggestedEntities() async throws -> [QueueEntity] { all() }
}

struct AddDownloadIntent: AppIntent {
    static let title: LocalizedStringResource = "Add download"
    static let description = IntentDescription("Adds a link to Rays and starts it, or queues it.")
    static let openAppWhenRun = false

    @Parameter(title: "Link") var url: String
    @Parameter(title: "Queue") var queue: QueueEntity?

    static var parameterSummary: some ParameterSummary { Summary("Download \(\.$url) in \(\.$queue)") }

    @MainActor func perform() async throws -> some IntentResult {
        let model = try appModel()
        guard !Links.split(url).urls.isEmpty else { throw IntentFailure(text: "No web link found. Links start with http://, https:// or s3://.") }
        model.add(url, queue: queue.map { UInt64($0.id) })
        return .result()
    }
}

struct StartQueueIntent: AppIntent {
    static let title: LocalizedStringResource = "Start queue"
    static let openAppWhenRun = false

    @Parameter(title: "Queue") var queue: QueueEntity

    static var parameterSummary: some ParameterSummary { Summary("Start \(\.$queue)") }

    @MainActor func perform() async throws -> some IntentResult {
        (try appModel()).startQueue(UInt64(queue.id))
        return .result()
    }
}

struct StopQueueIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop queue"
    static let openAppWhenRun = false

    @Parameter(title: "Queue") var queue: QueueEntity

    static var parameterSummary: some ParameterSummary { Summary("Stop \(\.$queue)") }

    @MainActor func perform() async throws -> some IntentResult {
        (try appModel()).stopQueue(UInt64(queue.id))
        return .result()
    }
}

struct RunSpeedTestIntent: AppIntent {
    static let title: LocalizedStringResource = "Run speed test"
    static let description = IntentDescription("Measures your download speed and returns it, for example 212 Mbps.")
    static let openAppWhenRun = false

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let model = try appModel()
        // A hotspot or a network Rays cannot identify needs the user's confirmation in the app; a shortcut does not force it.
        guard model.network != .expensive, model.network != .unknown else {
            throw IntentFailure(text: "Rays can't run a speed test on a metered or unidentified network without asking. Open Rays and run it there.")
        }
        guard !model.testing else { throw IntentFailure(text: "A speed test is already running.") }
        let before = model.lastTest?.at
        await model.runSpeedTest(force: false)
        if let message = model.speedError { throw IntentFailure(text: message) }
        guard let result = model.lastTest, result.at != before else { throw IntentFailure(text: "The speed test did not finish.") }
        return .result(value: "\(Int((Double(result.bps) * 8 / 1_000_000).rounded())) Mbps")
    }
}

struct PauseAllIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause all downloads"
    static let openAppWhenRun = false

    @MainActor func perform() async throws -> some IntentResult {
        (try appModel()).pauseAll()
        return .result()
    }
}

struct ResumeAllIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume all downloads"
    static let openAppWhenRun = false

    @MainActor func perform() async throws -> some IntentResult {
        (try appModel()).resumeAll()
        return .result()
    }
}

struct DownloadClipboardIntent: AppIntent {
    static let title: LocalizedStringResource = "Download copied link"
    static let description = IntentDescription("Downloads the link or links on the clipboard.")
    static let openAppWhenRun = false

    @MainActor func perform() async throws -> some IntentResult {
        let model = try appModel()
        guard let text = NSPasteboard.general.string(forType: .string), !Links.split(text).urls.isEmpty else {
            throw IntentFailure(text: "No link on the clipboard")
        }
        model.add(text)
        return .result()
    }
}

struct RaysShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AddDownloadIntent(), phrases: ["Add a download in \(.applicationName)", "Download with \(.applicationName)"],
                    shortTitle: "Add download", systemImageName: "arrow.down.circle")
        AppShortcut(intent: StartQueueIntent(), phrases: ["Start a queue in \(.applicationName)"],
                    shortTitle: "Start queue", systemImageName: "play.circle")
        AppShortcut(intent: StopQueueIntent(), phrases: ["Stop a queue in \(.applicationName)"],
                    shortTitle: "Stop queue", systemImageName: "stop.circle")
        AppShortcut(intent: RunSpeedTestIntent(), phrases: ["Run a speed test in \(.applicationName)"],
                    shortTitle: "Run speed test", systemImageName: "speedometer")
        AppShortcut(intent: PauseAllIntent(), phrases: ["Pause all downloads in \(.applicationName)"],
                    shortTitle: "Pause all downloads", systemImageName: "pause.circle")
        AppShortcut(intent: ResumeAllIntent(), phrases: ["Resume all downloads in \(.applicationName)"],
                    shortTitle: "Resume all downloads", systemImageName: "play.circle")
        AppShortcut(intent: DownloadClipboardIntent(), phrases: ["Download copied link in \(.applicationName)"],
                    shortTitle: "Download copied link", systemImageName: "doc.on.clipboard")
    }
}
