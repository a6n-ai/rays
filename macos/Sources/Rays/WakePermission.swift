import AppKit
import Foundation

/// The one-time administrator step that lets Rays schedule wakes: a sudoers drop-in that allows `pmset schedule wake`
/// and `pmset schedule cancel wake` and nothing else. Rays never sees a password; macOS shows the prompt itself.
enum WakePermission {
    static let file = "/etc/sudoers.d/rays-wake"
    private static let pmset = "/usr/bin/pmset"
    private static let lock = NSLock()

    /// The rule file exists and sudo accepts the wake command without a password. `-l` only checks; it runs nothing.
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: file) && sudo(["-l", pmset, "schedule", "wake", "01/01/30 00:00:00"]) == 0
    }

    @MainActor
    static func ensure() async -> Bool {
        if await Task.detached(operation: { isInstalled }).value { return true }
        let alert = NSAlert()
        alert.messageText = "Let Rays wake your Mac for scheduled queues?"
        alert.informativeText = "Rays needs your administrator password once. It adds a rule that lets Rays set and cancel wake times, and nothing else. You can remove it in Settings > Downloads."
        alert.addButton(withTitle: "Continue…")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        guard let user = validatedUser(NSUserName()) else { return false }
        let script = installScript(user: user, target: file, visudo: "/usr/sbin/visudo")
        guard await runAsAdmin(script) else { return false }
        return await Task.detached(operation: { isInstalled }).value
    }

    @MainActor
    static func remove() async -> Bool {
        await Task.detached {
            let keys = UserDefaults.standard.dictionaryRepresentation().keys.filter { $0.hasPrefix(keyPrefix) }
            for key in keys { if let id = UInt64(key.dropFirst(keyPrefix.count)) { cancel(queue: id) } }
        }.value
        guard await runAsAdmin("/bin/rm -f \(file)") else { return false }
        return !FileManager.default.fileExists(atPath: file)
    }

    /// Wakes the Mac a minute before `at`. A wake already recorded for that time is left alone.
    static func schedule(queue: UInt64, at: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let target = at.addingTimeInterval(-60)
        guard target > .now else { return false }
        if recorded(queue) == [target.timeIntervalSince1970] { return true }
        cancelLocked(queue)
        guard sudo([pmset, "schedule", "wake", format(target)]) == 0 else { return false }
        UserDefaults.standard.set([target.timeIntervalSince1970], forKey: key(queue))
        return true
    }

    /// Cancels only the wakes Rays recorded for this queue.
    static func cancel(queue: UInt64) {
        lock.lock(); defer { lock.unlock() }
        cancelLocked(queue)
    }

    private static func cancelLocked(_ queue: UInt64) {
        for time in recorded(queue) where Date(timeIntervalSince1970: time) > .now {
            _ = sudo([pmset, "schedule", "cancel", "wake", format(Date(timeIntervalSince1970: time))])
        }
        UserDefaults.standard.removeObject(forKey: key(queue))
    }

    private static let keyPrefix = "wakeTimes."
    private static func key(_ queue: UInt64) -> String { keyPrefix + String(queue) }
    private static func recorded(_ queue: UInt64) -> [Double] {
        UserDefaults.standard.array(forKey: key(queue)) as? [Double] ?? []
    }

    private static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM/dd/yy HH:mm:ss"
        return formatter.string(from: date)
    }

    /// Runs `sudo -n` with an argument array, so no value goes through a shell. Nil when it can't start.
    private static func sudo(_ arguments: [String]) -> Int32? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/sudo")
        process.arguments = ["-n"] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// The name goes into a shell command, so only plain account-name characters pass.
    static func validatedUser(_ name: String) -> String? {
        name.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil ? name : nil
    }

    /// The temp file is validated before it is chowned, chmodded and moved; any failure removes it and leaves
    /// `target` untouched. `user` must come from `validatedUser`; `target` and `visudo` are fixed paths.
    static func installScript(user: String, target: String, visudo: String) -> String {
        """
        USER_NAME='\(user)'; f='\(target)'; t=$(/usr/bin/mktemp) || exit 1; \
        /usr/bin/printf '%s ALL=(root) NOPASSWD: /usr/bin/pmset schedule wake *, /usr/bin/pmset schedule cancel wake *\\n' "$USER_NAME" > "$t" \
        && '\(visudo)' -cf "$t" && /usr/sbin/chown root:wheel "$t" && /bin/chmod 0440 "$t" && /bin/mv "$t" "$f" \
        || { /bin/rm -f "$t"; exit 1; }
        """
    }

    /// `osascript` shows the system administrator prompt. The script text is fixed apart from the validated user name.
    private static func runAsAdmin(_ shell: String) async -> Bool {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus == 0) }
            do { try process.run() } catch { continuation.resume(returning: false) }
        }
    }
}
