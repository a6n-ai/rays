import Foundation

struct SorterStatus: Decodable, Equatable, Sendable {
    let folders: [SorterFolder]
    let categories: [SorterCategory]
    let recent: [SorterMove]
    let waitSeconds: Int?
}

struct SorterFolder: Decodable, Identifiable, Equatable, Sendable {
    let path: String
    let watching: Bool
    let label: String
    let agentBinary: String?

    var id: String { path }
    var name: String { URL(filePath: path).lastPathComponent }
}

struct SorterCategory: Decodable, Identifiable, Equatable, Sendable {
    let name: String
    let description: String
    var id: String { name }
}

struct SorterMove: Decodable, Equatable, Sendable {
    let time: Double
    let file: String
    let from: String
    let to: String
}

extension Notification.Name {
    static let openSorter = Notification.Name("ai.a6n.rays.openSorter")
}

/// Read-only: custom destinations are shown from sorter.json, which only `sorter config` writes.
private struct SorterConfigFile: Decodable {
    struct Folder: Decodable {
        let path: String
        let destinations: [String: String]?
    }
    let folders: [Folder]
}

@MainActor
@Observable
final class SorterModel {
    static let unavailableMessage = "The sorter isn't available in this build."

    private(set) var status: SorterStatus?
    private(set) var loadFailed = false
    private(set) var busy = false
    private(set) var error: String?
    private(set) var sortResults: [String: String] = [:]
    private(set) var destinations: [String: [String: String]] = [:]
#if DEBUG
    private(set) var isFixture = false
#endif

    func refresh() async {
#if DEBUG
        guard !isFixture else { return }
#endif
        // One retry, and a failed refresh keeps the last good status: a single slow or overlapping run
        // (e.g. right after launch) shouldn't flash "isn't available".
        for attempt in 0..<2 {
            let result = await Sorter.run(Sorter.defaultPath, ["status", "--json"])
            if result.status == 0, let decoded = try? Self.decode(Data(result.stdout.utf8)) {
                // Assigning an equal value still invalidates every view reading it; skip no-op refreshes.
                if decoded != status { status = decoded }
                loadFailed = false
                break
            }
            if attempt == 0 { try? await Task.sleep(for: .seconds(1)) }
            if attempt == 1 { loadFailed = status == nil }
        }
        let loaded = Self.loadDestinations()
        if loaded != destinations { destinations = loaded }
    }

    func destination(for folder: SorterFolder, category: String) -> String? {
        destinations[folder.path]?[category]
    }

    func setWatching(_ folder: SorterFolder, on: Bool) async {
        _ = await perform([on ? "watch" : "unwatch", folder.path])
    }

    /// Re-runs `watch` so the launch agent points at the bundled sorter.
    func update(_ folder: SorterFolder) async {
        _ = await perform(["watch", folder.path])
    }

    func sortNow(_ folder: SorterFolder) async {
        let result = await perform([folder.path])
        if result.status == 0 { sortResults[folder.path] = Sorter.lastLine(result.stdout) }
    }

    static let waitChoices: [(seconds: Int, title: String)] = [
        (10, "10 seconds (Recommended)"), (30, "30 seconds"), (60, "1 minute"),
        (300, "5 minutes"), (900, "15 minutes"), (3600, "1 hour"),
    ]

    func setWait(_ seconds: Int) async {
        _ = await perform(["config", "set-wait", String(seconds)])
    }

    func addFolder(_ path: String) async {
        _ = await perform(["config", "add", path])
    }

    func remove(_ folder: SorterFolder) async {
        if folder.watching {
            guard await perform(["unwatch", folder.path]).status == 0 else { return }
        }
        _ = await perform(["config", "remove", folder.path])
    }

    func setDestination(_ folder: SorterFolder, category: String, path: String) async {
        _ = await perform(["config", "set-dest", folder.path, category, path])
    }

    func resetDestination(_ folder: SorterFolder, category: String) async {
        _ = await perform(["config", "clear-dest", folder.path, category])
    }

    /// Settings calls this after the Downloads folder changes: a watch on the old folder moves to the new one.
    func moveWatch(from old: URL, sorterPath: String) async {
        let new = EngineModel.downloadsURL
        guard old.standardizedFileURL != new.standardizedFileURL,
              FileManager.default.fileExists(atPath: Sorter.plistURL(for: old).path(percentEncoded: false))
        else { return }
        busy = true
        error = nil
        let stop = await Sorter.run(sorterPath, ["unwatch", old.path(percentEncoded: false)])
        let start = await Sorter.run(sorterPath, ["watch", new.path(percentEncoded: false)])
        busy = false
        error = [stop, start].first { $0.status != 0 }?.failure
        await refresh()
    }

    private func perform(_ arguments: [String]) async -> SorterRunResult {
        busy = true
        error = nil
        let result = await Sorter.run(Sorter.defaultPath, arguments)
        busy = false
        if result.status != 0 { error = result.failure }
        await refresh()
        return result
    }

    private static func decode(_ data: Data) throws -> SorterStatus {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SorterStatus.self, from: data)
    }

    private static func loadDestinations() -> [String: [String: String]] {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        guard let data = try? Data(contentsOf: support.appending(path: "Rays/sorter.json")),
              let file = try? JSONDecoder().decode(SorterConfigFile.self, from: data)
        else { return [:] }
        return Dictionary(file.folders.map { ($0.path, $0.destinations ?? [:]) }, uniquingKeysWith: { $1 })
    }
}

#if DEBUG
extension SorterModel {
    /// Previews only: shows `json` as if `status --json` had printed it, and never polls the real sorter.
    static func preview(_ json: String) -> SorterModel {
        let model = SorterModel()
        model.isFixture = true
        model.status = try? decode(Data(json.utf8))
        model.destinations = loadDestinations()
        return model
    }
}
#endif
