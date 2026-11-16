import Foundation

struct SorterRunResult: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool

    var failure: String {
        if timedOut { return "sorter didn't finish within 15 seconds." }
        let line = Sorter.lastLine(stderr)
        return line.isEmpty ? "sorter exited with status \(status)." : line
    }
}

/// Drives the `sorter` CLI. The label rule must match sorter's `watch` (sorter/src/main.rs), because
/// moving the watch after a Downloads change reads the launchd plist on disk to find the old one.
enum Sorter {
    /// The copy bundled into Rays.app; the app never runs a sorter from elsewhere.
    static let defaultPath = Bundle.main.bundleURL
        .appending(path: "Contents/MacOS/sorter").path(percentEncoded: false)

    static func label(for folder: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let homePath = canonicalPath(home)
        let dir = canonicalPath(folder)
        if dir == homePath + "/Downloads" { return "local.sorter" }
        let relative = dir.hasPrefix(homePath + "/") ? String(dir.dropFirst(homePath.count + 1)) : dir
        let slug = relative.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? Character($0.lowercased()) : "-" }
        return "local.sorter." + String(slug).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    static func plistURL(for folder: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: "Library/LaunchAgents/\(label(for: folder, home: home)).plist")
    }

    /// realpath, as sorter's own canonicalize: /tmp becomes /private/tmp. Falls back when the folder is missing.
    static func canonicalPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func lastLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
    }

    /// Runs off the main thread and kills the process after 15 seconds.
    static func run(_ path: String, _ arguments: [String]) async -> SorterRunResult {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(filePath: path)
            process.arguments = arguments
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            do {
                try process.run()
            } catch {
                return SorterRunResult(status: -1, stdout: "", stderr: error.localizedDescription, timedOut: false)
            }
            let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: watchdog)
            let out = stdout.fileHandleForReading.readDataToEndOfFile()
            let err = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            watchdog.cancel()
            return SorterRunResult(
                status: process.terminationStatus,
                stdout: String(decoding: out, as: UTF8.self),
                stderr: String(decoding: err, as: UTF8.self),
                timedOut: process.terminationReason == .uncaughtSignal)
        }.value
    }
}
