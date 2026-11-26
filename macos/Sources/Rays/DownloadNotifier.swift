import UserNotifications

/// Posts a notification when a download finishes or fails. Events within a short window are collected so a
/// big queue produces a few notifications (one each for up to three jobs) or a single summary.
@MainActor
final class DownloadNotifier {
    nonisolated static let doneCategory = "ai.a6n.rays.done"
    nonisolated static let failedCategory = "ai.a6n.rays.failed"
    nonisolated static let open = "open"
    nonisolated static let reveal = "reveal"
    nonisolated static let retry = "retry"
    private static let window = Duration.seconds(2)

    private var pending: [JobView] = []
    private var flushing = false

    private var enabled: Bool { UserDefaults.standard.object(forKey: SettingsKey.notifyDone) as? Bool ?? true }

    func note(_ job: JobView) {
        guard enabled else { return }
        pending.append(job)
        guard !flushing else { return }
        flushing = true
        Task {
            try? await Task.sleep(for: Self.window)
            flushing = false
            let batch = pending
            pending = []
            await post(batch)
        }
    }

    private func post(_ batch: [JobView]) async {
        let center = UNUserNotificationCenter.current()
        guard !batch.isEmpty, (try? await center.requestAuthorization(options: [.alert])) == true else { return }
        let done = UNNotificationCategory(identifier: Self.doneCategory, actions: [
            UNNotificationAction(identifier: Self.open, title: "Open", options: [.foreground]),
            UNNotificationAction(identifier: Self.reveal, title: "Show in Finder", options: []),
        ], intentIdentifiers: [])
        let failed = UNNotificationCategory(identifier: Self.failedCategory, actions: [
            UNNotificationAction(identifier: Self.retry, title: "Retry", options: []),
        ], intentIdentifiers: [])
        // Replacing the categories would drop the clipboard watcher's and the queue countdown's, so keep what is registered.
        let ours: Set = [Self.doneCategory, Self.failedCategory]
        let others = await center.notificationCategories().filter { !ours.contains($0.identifier) }
        center.setNotificationCategories(others.union([done, failed]))

        if batch.count <= 3 {
            for job in batch { try? await center.add(request(for: job)) }
            return
        }
        let failures = batch.filter { !$0.isDone }.count
        let content = UNMutableNotificationContent()
        content.title = failures == 0 ? "\(batch.count) downloads finished" : "\(batch.count - failures) downloads finished, \(failures) failed"
        try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private func request(for job: JobView) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.userInfo = ["id": NSNumber(value: job.id)]
        if case .failed(let message) = job.state {
            content.title = "Download failed"
            content.body = "\(job.name): \(message)"
            content.categoryIdentifier = Self.failedCategory
        } else {
            content.title = "Download finished"
            content.body = job.name
            content.categoryIdentifier = Self.doneCategory
        }
        return UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
    }
}
