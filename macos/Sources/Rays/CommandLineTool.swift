import AppKit
import SwiftUI

/// Puts the `dl` inside Rays.app on the PATH, like "Install 'code' command" in VS Code.
/// Homebrew installs already link it; DMG installs use this.
enum CommandLineTool {
    static let bundled = Bundle.main.bundleURL.appending(path: "Contents/MacOS/dl")
    /// Homebrew's bin is user-writable on Apple silicon; /usr/local/bin needs an administrator.
    static let homebrewBin = URL(filePath: "/opt/homebrew/bin")
    static let systemBin = URL(filePath: "/usr/local/bin")

    enum State: Equatable {
        case installed(URL)
        case otherDL(URL)
        case missing
    }

    static func state() -> State {
        for dir in [homebrewBin, systemBin] {
            let link = dir.appending(path: "dl")
            guard FileManager.default.fileExists(atPath: link.path) else { continue }
            return isRays(link) ? .installed(link) : .otherDL(link)
        }
        return .missing
    }

    /// Any Rays.app's dl counts, so a Homebrew-linked /Applications copy is "installed" too.
    static func isRays(_ link: URL) -> Bool {
        let target = link.resolvingSymlinksInPath().path
        return target == bundled.resolvingSymlinksInPath().path || target.hasSuffix("Rays.app/Contents/MacOS/dl")
    }

    static func install() throws {
        if FileManager.default.isWritableFile(atPath: homebrewBin.path) {
            let link = homebrewBin.appending(path: "dl")
            if (try? link.checkResourceIsReachable()) == true || isSymlink(link) {
                guard isSymlink(link), isRays(link) else { throw Failure.occupied(link.path) }
                try FileManager.default.removeItem(at: link)
            }
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: bundled)
            return
        }
        let link = systemBin.appending(path: "dl")
        if FileManager.default.fileExists(atPath: link.path), !isRays(link) { throw Failure.occupied(link.path) }
        try runAsAdmin("mkdir -p \(shellQuote(systemBin.path)) && ln -sfn \(shellQuote(bundled.path)) \(shellQuote(link.path))")
    }

    static func uninstall(_ link: URL) throws {
        guard isSymlink(link), isRays(link) else { throw Failure.occupied(link.path) }
        if FileManager.default.isWritableFile(atPath: link.deletingLastPathComponent().path) {
            try FileManager.default.removeItem(at: link)
        } else {
            try runAsAdmin("rm \(shellQuote(link.path))")
        }
    }

    enum Failure: LocalizedError {
        case occupied(String)
        case admin(String)
        var errorDescription: String? {
            switch self {
            case .occupied(let path): "\(path) is another program named dl, so Rays left it alone."
            case .admin(let message): message
            }
        }
    }

    private static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
    }

    private static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// macOS shows its own password prompt; nothing is stored.
    private static func runAsAdmin(_ command: String) throws {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var error: NSDictionary?
        NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?.executeAndReturnError(&error)
        if let error {
            // -128: the user cancelled the password prompt.
            let code = error[NSAppleScript.errorNumber] as? Int
            throw Failure.admin(code == -128 ? "Cancelled." : (error[NSAppleScript.errorMessage] as? String ?? "Could not install."))
        }
    }
}

struct CommandLineSection: View {
    @State private var state = CommandLineTool.state()
    @State private var error: String?

    var body: some View {
        Section {
            SettingRow(.commandLine, title: "Command line tool", hint: hint) {
                switch state {
                case .installed(let link):
                    Button("Remove") { run { try CommandLineTool.uninstall(link) } }
                        .buttonStyle(.glass)
                case .otherDL:
                    EmptyView()
                case .missing:
                    Button("Install") { run { try CommandLineTool.install() } }
                        .buttonStyle(.glass)
                }
            }
            if let error { ErrorLine(text: error) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            state = CommandLineTool.state()
        }
    }

    private var hint: String {
        switch state {
        case .installed(let link): "dl is ready in Terminal (\(link.path))."
        case .otherDL(let link): "\(link.path) is another program named dl."
        case .missing: "Optional. Lets Terminal and AI agents (MCP) download and sort with Rays."
        }
    }

    private func run(_ action: () throws -> Void) {
        do {
            try action()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        state = CommandLineTool.state()
    }
}
