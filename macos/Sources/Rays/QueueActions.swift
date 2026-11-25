import AppKit
import Observation
import os
import SwiftUI
import UserNotifications

/// Runs a queue's "when finished" action. Sleep, Shut down and Quit wait 30 seconds first, so a person who comes
/// back to the Mac can cancel from the banner or the notification.
@MainActor
@Observable
final class QueueActions {
    static let shared = QueueActions()
    nonisolated static let category = "ai.a6n.rays.queue-finished"
    nonisolated static let cancelAction = "cancel"
    private static let notificationID = "queue-finished-countdown"
    private nonisolated static let log = Logger(subsystem: "app.rays", category: "queue-actions")
    private static let countdownSeconds = 30

    struct Countdown: Equatable {
        let action: FinishAction
        var remaining: Int

        var message: String {
            switch action {
            case .sleep: "Your Mac will sleep in \(remaining) seconds"
            case .shutDown: "Your Mac will shut down in \(remaining) seconds"
            default: "Rays will quit in \(remaining) seconds"
            }
        }
    }

    private(set) var countdown: Countdown?
    @ObservationIgnored private var task: Task<Void, Never>?

    func perform(_ action: FinishAction) {
        switch action {
        case .nothing: break
        case .sound: NSSound(named: "Glass")?.play()
        case .lock: Self.lockScreen()
        case .command(let command): Self.run(command)
        case .sleep, .quit, .shutDown: startCountdown(action)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        countdown = nil
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.notificationID])
    }

    private func startCountdown(_ action: FinishAction) {
        cancel()
        countdown = Countdown(action: action, remaining: Self.countdownSeconds)
        task = Task { @MainActor in
            await Self.postNotification(for: countdown)
            while let current = countdown, current.remaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                countdown?.remaining -= 1
            }
            guard !Task.isCancelled else { return }
            cancel()
            Self.finish(action)
        }
    }

    private static func finish(_ action: FinishAction) {
        switch action {
        case .sleep: launch("/usr/bin/pmset", ["sleepnow"])
        case .quit: NSApp.terminate(nil)
        case .shutDown: shutDown()
        default: break
        }
    }

    /// Authorization is asked the first time a countdown is needed. If it is denied, the in-app banner still shows.
    private static func postNotification(for countdown: Countdown?) async {
        guard let countdown else { return }
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }
        let cancel = UNNotificationAction(identifier: cancelAction, title: "Cancel", options: [])
        let mine = UNNotificationCategory(identifier: category, actions: [cancel], intentIdentifiers: [])
        // Replacing the categories would drop the clipboard watcher's, so keep what is registered.
        let others = await center.notificationCategories().filter { $0.identifier != category }
        center.setNotificationCategories(others.union([mine]))
        let content = UNMutableNotificationContent()
        content.title = countdown.message
        content.body = "A queue has finished downloading."
        content.categoryIdentifier = category
        try? await center.add(UNNotificationRequest(identifier: notificationID, content: content, trigger: nil))
    }

    private static func launch(_ path: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(filePath: path)
        process.arguments = arguments
        do { try process.run() } catch { log.error("Couldn't run \(path, privacy: .public): \(error.localizedDescription, privacy: .public)") }
    }

    /// The only place text from the user runs, as the user. Output stays at debug level and private.
    private static func run(_ command: String) {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/zsh")
        process.arguments = ["-lc", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            log.debug("\(String(decoding: data, as: UTF8.self), privacy: .private)")
        }
        do { try process.run() } catch { log.error("Couldn't run the finish command: \(error.localizedDescription, privacy: .public)") }
    }

    /// `CGSession -suspend` is gone on current macOS, so this uses the login framework's own lock call.
    private static func lockScreen() {
        let session = "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession"
        if FileManager.default.isExecutableFile(atPath: session) { return launch(session, ["-suspend"]) }
        typealias Lock = @convention(c) () -> Int32
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_NOW),
              let symbol = dlsym(handle, "SACLockScreenImmediate")
        else { return log.error("Couldn't find a way to lock the screen") }
        _ = unsafeBitCast(symbol, to: Lock.self)()
    }

    private static func shutDown() {
        let key = "shutDownExplained"
        if !UserDefaults.standard.bool(forKey: key) {
            let alert = NSAlert()
            alert.messageText = "Allow Rays to shut down your Mac"
            alert.informativeText = "macOS will ask whether Rays can control System Events. Click OK to let Rays shut down your Mac when a queue finishes. You can change this in System Settings > Privacy & Security > Automation."
            alert.runModal()
            UserDefaults.standard.set(true, forKey: key)
        }
        var error: NSDictionary?
        NSAppleScript(source: "tell application \"System Events\" to shut down")?.executeAndReturnError(&error)
        if let error { log.error("Shut down failed: \(String(describing: error[NSAppleScript.errorMessage]), privacy: .public)") }
    }
}

/// The in-app countdown, shown over the detail column while an action waits.
struct CountdownBanner: View {
    private var actions: QueueActions { .shared }

    var body: some View {
        if let countdown = actions.countdown {
            HStack(spacing: 10) {
                Image(systemName: "timer").foregroundStyle(.orange)
                Text(countdown.message).font(.callout.weight(.medium)).monospacedDigit()
                Button("Cancel") { actions.cancel() }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
            .padding(.top, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
