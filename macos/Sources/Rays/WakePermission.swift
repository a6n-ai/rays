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

    /// One administrator prompt cancels every wake Rays recorded, as root, then removes the rule file.
    /// The records are cleared only when that succeeds.
    @MainActor
    static func remove() async -> Bool {
        // The snapshot waits for syncs already queued, and no new wake is scheduled until the rule file is gone.
        let (keys, cancels) = await withCheckedContinuation { (done: CheckedContinuation<([String], String), Never>) in
            serial.async {
                lock.lock(); defer { lock.unlock() }
                removing = true
                let keys = UserDefaults.standard.dictionaryRepresentation().keys.filter { $0.hasPrefix(keyPrefix) }
                let cancels = keys.flatMap { key in
                    (UserDefaults.standard.array(forKey: key) as? [Double] ?? []).map { format(Date(timeIntervalSince1970: $0)) }
                }
                .filter { $0.range(of: #"^\d\d/\d\d/\d\d \d\d:\d\d:\d\d$"#, options: .regularExpression) != nil }
                .map { "/usr/bin/pmset schedule cancel wake '\($0)'; " }
                .joined()
                done.resume(returning: (keys, cancels))
            }
        }
        defer { endRemoval() }
        guard await runAsAdmin(cancels + "/bin/rm -f '\(file)'"), !FileManager.default.fileExists(atPath: file) else { return false }
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        return true
    }

    private static var wanting = Set<UInt64>()
    private static let wantLock = NSLock()
    private static var removing = false

    private static func endRemoval() {
        lock.lock(); defer { lock.unlock() }
        removing = false
    }
    private static let serial = DispatchQueue(label: "app.rays.wake")

    /// Some queue has Wake on but the rule file is gone, so the toggle should offer "Set Up Again".
    static var isMissingForWakeQueues: Bool {
        wantLock.lock(); defer { wantLock.unlock() }
        return !wanting.isEmpty && !FileManager.default.fileExists(atPath: file)
    }

    /// Brings the Mac's wake time in step with a queue. Calls run one at a time, in the order they were made.
    static func sync(queue: UInt64, wake: Bool, nextRun: Date?) {
        wantLock.lock()
        if wake { wanting.insert(queue) } else { wanting.remove(queue) }
        wantLock.unlock()
        serial.async {
            if wake, let nextRun { _ = schedule(queue: queue, at: nextRun) } else { cancel(queue: queue) }
        }
    }

    /// Wakes the Mac a minute before `at`. A wake already recorded for that time is left alone.
    static func schedule(queue: UInt64, at: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !removing, FileManager.default.fileExists(atPath: file) else { return false }
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

    /// The only dates sudo will accept, in the sudoers line below.
    private static let datePattern = #"[0-9][0-9]/[0-9][0-9]/[0-9][0-9] [0-9][0-9]\:[0-9][0-9]\:[0-9][0-9]"#
    static let sudoersRule = "/usr/bin/pmset schedule wake \(datePattern), /usr/bin/pmset schedule cancel wake \(datePattern)"

    /// The temp file is made inside the root-owned target directory, so nobody else can swap it, and its dot name
    /// keeps sudo from reading it before the move. It is validated, then chowned, chmodded and renamed into place;
    /// any failure removes it and leaves `target` untouched. `user` must come from `validatedUser`.
    static func installScript(user: String, target: String, visudo: String) -> String {
        let dir = (target as NSString).deletingLastPathComponent
        return #"""
        USER_NAME='\#(user)'; f='\#(target)'; t=$(/usr/bin/mktemp '\#(dir)/.rays-wake.XXXXXX') || exit 1; 
        /usr/bin/printf '%s ALL=(root) NOPASSWD: %s\n' "$USER_NAME" '\#(sudoersRule)' > "$t"         && '\#(visudo)' -cf "$t" && /usr/sbin/chown root:wheel "$t" && /bin/chmod 0440 "$t" && /bin/mv "$t" "$f"         || { /bin/rm -f "$t"; exit 1; }
        """#
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
