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
    @State private var copied: String?

    var body: some View {
        MCPAppsSection()
        CardSection("HTTP server") {
            SettingRow(title: "HTTP server", hint: httpHint, status: server.running ? .ok : nil) {
                Toggle("HTTP server", isOn: $httpOn).labelsHidden()
            }
            // Always shown, so turning the server on or off doesn't move the page.
            copyRow("Address", hint: MCPHTTPServer.url, id: "address") { MCPHTTPServer.url }
            copyRow("Token", hint: "Clients send it as a bearer token. Keep it private.", id: "token") { server.token }
            copyRow("Claude Code command", hint: "Paste it in Terminal.", id: "claude") {
                server.token.map { "claude mcp add --transport http rays \(MCPHTTPServer.url) --header \"Authorization: Bearer \($0)\"" }
            }
            copyRow("JSON config", hint: "For other apps that connect to an address.", id: "json") {
                server.token.map { #"{ "mcpServers": { "rays": { "type": "http", "url": "\#(MCPHTTPServer.url)", "headers": { "Authorization": "Bearer \#($0)" } } } }"# }
            }
            if let error = server.error { ErrorLine(text: error) }
        }
        .onChange(of: httpOn) { _, on in on ? server.start() : server.stop() }
    }

    private var httpHint: String {
        server.running ? "On, listening on this Mac only."
                       : "For apps that connect to an address. This Mac only, with a token."
    }

    private func copyRow(_ title: String, hint: String, id: String, text: @escaping () -> String?) -> some View {
        SettingRow(title: title, hint: hint) {
            Button(copied == id ? "Copied" : "Copy") {
                guard let value = text() else { return }
                copy(value)
                copied = id
            }
            .disabled(!server.running)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
