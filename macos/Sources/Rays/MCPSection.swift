import AppKit
import SwiftUI

/// Runs `dl mcp --http` from inside Rays.app while the setting is on. The child quits with the app.
@MainActor @Observable
final class MCPHTTPServer {
    static let shared = MCPHTTPServer()
    static let port = 7467
    static var url: String { "http://127.0.0.1:\(port)/mcp" }

    private(set) var running = false
    private(set) var error: String?
    private var process: Process?

    /// Starts the server when the setting was left on.
    func restore() {
        if UserDefaults.standard.bool(forKey: SettingsKey.mcpHTTP) { start() }
    }

    func start() {
        guard process == nil else { return }
        let p = Process()
        p.executableURL = CommandLineTool.bundled
        p.arguments = ["mcp", "--http", "--port", String(Self.port)]
        p.environment = ProcessInfo.processInfo.environment.merging(["RAYS_MCP_PARENT": String(getpid())]) { $1 }
        let stderr = Pipe()
        p.standardError = stderr
        p.standardOutput = FileHandle.nullDevice
        p.terminationHandler = { proc in
            let text = String(decoding: stderr.fileHandleForReading.availableData, as: UTF8.self)
            Task { @MainActor in
                guard self.process === proc else { return }
                self.process = nil
                self.running = false
                if proc.terminationStatus != 0 {
                    self.error = text.split(separator: "\n").last.map { String($0).replacingOccurrences(of: "dl: ", with: "") }
                        ?? "The MCP server stopped."
                }
            }
        }
        do {
            try p.run()
            process = p
            running = true
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stop() {
        let p = process
        process = nil
        running = false
        p?.terminate()
    }

    /// Created by the server on its first start; nil until then.
    var token: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let file = home.appending(path: "Library/Application Support/Rays/mcp-token")
        return (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct MCPSection: View {
    @AppStorage(SettingsKey.mcpHTTP) private var httpOn = false
    private var server = MCPHTTPServer.shared

    private var dl: String { CommandLineTool.bundled.path(percentEncoded: false) }

    var body: some View {
        CardSection("MCP server") {
            SettingRow(title: "Apps on this Mac",
                       hint: "Claude, Cursor and other AI apps start Rays's MCP server themselves to download files, run queues, get models and sort folders.") {
                Menu("Copy") {
                    Button("Claude Code command") { copy("claude mcp add rays -- \(quoted(dl)) mcp") }
                    Button("JSON config") { copy(#"{ "mcpServers": { "rays": { "command": "\#(dl)", "args": ["mcp"] } } }"#) }
                }
                .fixedSize()
            }
            SettingRow(title: "HTTP server", hint: httpHint, status: server.running ? .ok : nil) {
                Toggle("HTTP server", isOn: $httpOn).labelsHidden()
            }
            if server.running {
                SettingRow(title: "Connect over HTTP", hint: "Clients send the token as a bearer token. Keep it private.") {
                    Menu("Copy") {
                        Button("Address") { copy(MCPHTTPServer.url) }
                        Button("Token") { server.token.map(copy) }
                        Button("Claude Code command") {
                            server.token.map { copy("claude mcp add --transport http rays \(MCPHTTPServer.url) --header \"Authorization: Bearer \($0)\"") }
                        }
                        Button("JSON config") {
                            server.token.map {
                                copy(#"{ "mcpServers": { "rays": { "type": "http", "url": "\#(MCPHTTPServer.url)", "headers": { "Authorization": "Bearer \#($0)" } } } }"#)
                            }
                        }
                    }
                    .fixedSize()
                }
            }
            if let error = server.error { ErrorLine(text: error) }
        }
        .onChange(of: httpOn) { _, on in on ? server.start() : server.stop() }
    }

    private var httpHint: String {
        server.running ? "Listening at \(MCPHTTPServer.url), on this Mac only."
                       : "For AI apps that connect to an address instead. Listens on this Mac only and needs a token."
    }

    private func quoted(_ s: String) -> String { s.contains(" ") ? "'\(s)'" : s }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
