import AppKit
import UserNotifications

/// Offers to download a link copied anywhere on the Mac, with a notification and a Download button.
/// It checks the clipboard's change count every second, then asks macOS only whether the new item looks like a web
/// link (which never prompts); it reads the item only then, so macOS's paste alert appears only for links.
@MainActor
final class ClipboardWatcher: NSObject, UNUserNotificationCenterDelegate {
    nonisolated static let category = "ai.a6n.rays.clipboard"
    nonisolated static let download = "download"

    private let model: EngineModel
    private var lastChange = NSPasteboard.general.changeCount
    private var offered = Set<String>()
    private var timer: Timer?

    init(model: EngineModel) {
        self.model = model
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let action = UNNotificationAction(identifier: Self.download, title: "Download", options: [])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [action], intentIdentifiers: [])])
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private var enabled: Bool { UserDefaults.standard.object(forKey: SettingsKey.clipboard) as? Bool ?? true }

    private func tick() {
        let board = NSPasteboard.general
        guard board.changeCount != lastChange else { return }
        lastChange = board.changeCount
        // Our own copies (a row's link, for example) are not offers.
        guard enabled, NSApp.isActive == false else { return }
        Task { await check(board) }
    }

    private func check(_ board: NSPasteboard) async {
        guard let found = try? await board.detectedPatterns(for: [\.probableWebURL]), found.contains(\.probableWebURL),
              let value = try? await board.detectedValues(for: [\.probableWebURL]).probableWebURL
        else { return }
        let links = Links.inText(value).filter { Self.looksLikeDownload($0) && !offered.contains($0) }
        guard !links.isEmpty else { return }
        offered.formUnion(links)
        await offer(links)
    }

    private func offer(_ links: [String]) async {
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }
        let content = UNMutableNotificationContent()
        let first = URL(string: links[0])
        content.title = links.count == 1 ? "Download \(first?.lastPathComponent ?? "this file")?" : "Download \(links.count) copied links?"
        content.body = links.count == 1 ? (first?.host() ?? links[0]) : "From the clipboard"
        content.categoryIdentifier = Self.category
        content.userInfo = ["links": links]
        try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// A link to a file: its path ends in a type people download, or it is an `s3://` object.
    nonisolated static func looksLikeDownload(_ link: String) -> Bool {
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "s3" { return !url.path().isEmpty && url.path() != "/" }
        guard scheme == "http" || scheme == "https" else { return false }
        let name = url.lastPathComponent.lowercased()
        return downloadTypes.contains(where: { name.hasSuffix(".\($0)") })
    }

    nonisolated static let downloadTypes = [
        "zip", "dmg", "pkg", "iso", "img", "7z", "rar", "tar", "gz", "tgz", "xz", "bz2", "zst",
        "exe", "msi", "apk", "deb", "rpm", "appimage", "jar",
        "pdf", "epub", "docx", "xlsx", "pptx", "csv",
        "mp4", "mkv", "mov", "avi", "webm", "mp3", "m4a", "flac", "wav", "ogg",
        "bin", "torrent",
    ]

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content
        guard info.categoryIdentifier == Self.category,
              response.actionIdentifier == Self.download || response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let links = info.userInfo["links"] as? [String]
        else { return }
        await MainActor.run { model.add(links.joined(separator: "\n")) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner]
    }
}
