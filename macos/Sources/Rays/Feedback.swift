import AppKit

/// Crash reports and feedback go by email: Rays fills in a message to hi@a6n.ai and nothing is sent until the user presses Send.
enum Feedback {
    static let address = "hi@a6n.ai"
    static let crashLogs = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Logs/DiagnosticReports", directoryHint: .isDirectory)
    private static let seenKey = "crashReportsSeenUntil"
    /// macOS names crash logs `<process>-YYYY-MM-DD-HHMMSS.ips`; these are Rays and the tools inside its bundle.
    private static let crashName = #/^(Rays|dl|sorter|extract)-\d{4}-\d{2}-\d{2}-\d{6}.*\.ips$/#

    static var about: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        return "Rays \(version), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
    }

    static func sendFeedback() {
        compose(subject: "Rays feedback", body: "\n\n--\n\(about)")
    }

    /// The newest crash log of Rays or its tools written after `since`.
    static func newestCrash(in dir: URL, names: [String], since: Date) -> (url: URL, date: Date)? {
        names.filter { $0.wholeMatch(of: crashName) != nil }
            .compactMap { name -> (URL, Date)? in
                let url = dir.appending(path: name)
                guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      date > since else { return nil }
                return (url, date)
            }
            .max { $0.1 < $1.1 }
    }

    /// At launch: if Rays crashed since the last check, offer to email the report. The first launch only sets the mark,
    /// so crashes from before this version are not offered.
    @MainActor
    static func offerCrashReportIfNeeded(defaults: UserDefaults = .standard) {
        let now = Date()
        guard let seen = defaults.object(forKey: seenKey) as? Date else {
            defaults.set(now, forKey: seenKey)
            return
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: crashLogs.path(percentEncoded: false))) ?? []
        guard let crash = newestCrash(in: crashLogs, names: names, since: seen) else { return }
        defaults.set(now, forKey: seenKey)

        let alert = NSAlert()
        alert.messageText = "Rays quit unexpectedly"
        alert.informativeText = "Send the crash report to a6n to help fix it? Mail opens with the report attached, and nothing is sent until you press Send. The report can include names of files and folders on your Mac."
        alert.addButton(withTitle: "Send Report…")
        alert.addButton(withTitle: "Don't Send")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        compose(subject: "Rays crash report", body: "What were you doing when Rays quit?\n\n\n--\n\(about)", attachments: [crash.url])
    }

    /// Opens a new message in the user's mail app; falls back to a mailto link (no attachment) if Mail can't compose.
    private static func compose(subject: String, body: String, attachments: [URL] = []) {
        let items: [Any] = [body] + attachments
        if let mail = NSSharingService(named: .composeEmail), mail.canPerform(withItems: items) {
            mail.recipients = [address]
            mail.subject = subject
            mail.perform(withItems: items)
            return
        }
        var link = URLComponents(string: "mailto:\(address)")!
        link.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
        if let url = link.url { NSWorkspace.shared.open(url) }
    }
}
