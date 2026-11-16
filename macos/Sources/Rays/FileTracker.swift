import Foundation

/// Follows finished downloads by bookmark, so a file the sorter moved is still found where it went.
@MainActor
final class FileTracker {
    private let storeURL: URL
    private var bookmarks: [String: Data]
    private var cache: [UInt64: (url: URL?, at: Date)] = [:]

    init(storeURL: URL) {
        self.storeURL = storeURL
        bookmarks = (try? PropertyListDecoder().decode([String: Data].self, from: Data(contentsOf: storeURL))) ?? [:]
    }

    func hasBookmark(for id: UInt64) -> Bool { bookmarks[String(id)] != nil }

    func record(id: UInt64, url: URL) {
        guard let data = try? url.bookmarkData() else { return }
        bookmarks[String(id)] = data
        save()
    }

    func forget(_ id: UInt64) {
        cache[id] = nil
        guard bookmarks.removeValue(forKey: String(id)) != nil else { return }
        save()
    }

    /// The file's current location, or nil when it is gone or in the Trash. Cached for 2 s so redraws skip the disk.
    func currentURL(for id: UInt64) -> URL? {
        if let hit = cache[id], Date.now.timeIntervalSince(hit.at) < 2 { return hit.url }
        let url = resolve(id)
        cache[id] = (url, .now)
        return url
    }

    private func resolve(_ id: UInt64) -> URL? {
        guard let data = bookmarks[String(id)] else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
            relativeTo: nil, bookmarkDataIsStale: &stale),
            FileManager.default.fileExists(atPath: url.path(percentEncoded: false)),
            !url.path(percentEncoded: false).hasPrefix(Self.trashPath + "/")
        else { return nil }
        if stale, let fresh = try? url.bookmarkData() {
            bookmarks[String(id)] = fresh
            save()
        }
        return url
    }

    private static var trashPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".Trash").path(percentEncoded: false)
    }

    private func save() {
        try? PropertyListEncoder().encode(bookmarks).write(to: storeURL, options: .atomic)
    }
}
