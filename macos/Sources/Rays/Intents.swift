import AppIntents
import AppKit

struct IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    let text: String
    var localizedStringResource: LocalizedStringResource { "\(text)" }
}

/// The running app's model; intents run in the app process, which the system launches when needed.
@MainActor private func appModel() throws -> EngineModel {
    guard let model = (NSApp.delegate as? AppDelegate)?.model else { throw IntentFailure(text: "Rays is not ready yet. Open Rays and try again.") }
    return model
}

/// A queue for Shortcuts. Id 0 is "No queue": a direct download.
struct QueueEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Queue"
    static let defaultQuery = QueueEntityQuery()
    static let none = QueueEntity(id: 0, name: "No queue")

    var id: Int
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct QueueEntityQuery: EntityQuery {
    @MainActor private func all() -> [QueueEntity] {
        let queues = ((NSApp.delegate as? AppDelegate)?.model.sortedQueues ?? []).map { QueueEntity(id: Int($0.id), name: $0.config.name) }
        return [.none] + queues
    }

    @MainActor func entities(for identifiers: [Int]) async throws -> [QueueEntity] { all().filter { identifiers.contains($0.id) } }
    @MainActor func suggestedEntities() async throws -> [QueueEntity] { all() }
    func defaultResult() async -> QueueEntity? { .none }
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
        let id = queue?.id ?? 0
        model.add(url, queue: id == 0 ? nil : UInt64(id))
        return .result()
    }
}

struct StartQueueIntent: AppIntent {
    static let title: LocalizedStringResource = "Start queue"
    static let openAppWhenRun = false

    @Parameter(title: "Queue") var queue: QueueEntity

    static var parameterSummary: some ParameterSummary { Summary("Start \(\.$queue)") }

    @MainActor func perform() async throws -> some IntentResult {
        guard queue.id != 0 else { throw IntentFailure(text: "Pick a queue.") }
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
        guard queue.id != 0 else { throw IntentFailure(text: "Pick a queue.") }
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
    }
}
