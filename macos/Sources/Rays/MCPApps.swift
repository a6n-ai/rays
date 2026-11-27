import AppKit
import SwiftUI

/// One AI app Rays can connect to over MCP, with how it adds a server.
struct MCPApp: Identifiable {
    enum Add {
        /// Rays writes the server into the app's JSON config, under `key`.
        case config(path: String, key: String)
        /// The app's own link asks the person to confirm, then adds the server.
        case link((_ dl: String) -> URL?)
        case copyCommand((_ dl: String) -> String)
        /// The app cannot reach a server on this Mac; the hint says why.
        case none
    }

    let id: String
    let name: String
    let bundleID: String?
    let fallback: Tile
    let hint: String
    let add: Add
    /// The JSON config that lists servers, to show Added once Rays is in it.
    var installedIn: (path: String, key: String)?

    var appURL: URL? { bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) } }

    var isAdded: Bool {
        guard let (path, key) = installedIn else { return false }
        let servers = MCPConfigFile.read(path)?[key] as? [String: Any]
        return servers?["rays"] != nil
    }

    static func all() -> [MCPApp] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        let claude = "\(home)/Library/Application Support/Claude/claude_desktop_config.json"
        let cursor = "\(home)/.cursor/mcp.json"
        let vscode = "\(home)/Library/Application Support/Code/User/mcp.json"
        return [
            MCPApp(id: "claude", name: "Claude", bundleID: "com.anthropic.claudefordesktop",
                   fallback: Tile(symbol: "sparkle", color: TilePalette.orange, system: .mark("app-claude")),
                   hint: "Adds Rays to Claude's config. Quit and reopen Claude to load it.",
                   add: .config(path: claude, key: "mcpServers"), installedIn: (claude, "mcpServers")),
            MCPApp(id: "claude-code", name: "Claude Code", bundleID: nil, fallback: .commandLine,
                   hint: "Paste the command in Terminal.",
                   add: .copyCommand { "claude mcp add rays -- \(shellQuoted($0)) mcp" }),
            MCPApp(id: "cursor", name: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92",
                   fallback: Tile(symbol: "cursorarrow", color: TilePalette.gray, system: .mark("app-cursor")),
                   hint: "Opens Cursor to confirm adding Rays.",
                   add: .link { dl in
                       let config = try? JSONSerialization.data(withJSONObject: ["command": dl, "args": ["mcp"]], options: .withoutEscapingSlashes)
                       guard let base64 = config?.base64EncodedString() else { return nil }
                       var url = URLComponents(string: "cursor://anysphere.cursor-deeplink/mcp/install")
                       url?.queryItems = [URLQueryItem(name: "name", value: "rays"), URLQueryItem(name: "config", value: base64)]
                       return url?.url
                   }, installedIn: (cursor, "mcpServers")),
            MCPApp(id: "vscode", name: "Visual Studio Code", bundleID: "com.microsoft.VSCode",
                   fallback: Tile(symbol: "chevron.left.forwardslash.chevron.right", color: TilePalette.blue, system: .mark("app-vscode")),
                   hint: "Opens VS Code to confirm adding Rays.",
                   add: .link { dl in
                       let server = try? JSONSerialization.data(withJSONObject: ["name": "rays", "command": dl, "args": ["mcp"]], options: .withoutEscapingSlashes)
                       guard let json = server.map({ String(decoding: $0, as: UTF8.self) }),
                             let query = json.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+#")))
                       else { return nil }
                       return URL(string: "vscode:mcp/install?\(query)")
                   }, installedIn: (vscode, "servers")),
            MCPApp(id: "chatgpt", name: "ChatGPT", bundleID: "com.openai.chat",
                   fallback: Tile(symbol: "bubble.left.fill", color: TilePalette.green, system: .mark("app-chatgpt")),
                   hint: "ChatGPT connects only to MCP servers on the internet, so it can't reach Rays on this Mac.",
                   add: .none),
        ]
    }

    private static func shellQuoted(_ s: String) -> String { s.contains(" ") ? "'\(s)'" : s }
}

/// Reads and writes another app's MCP config, changing only the `rays` entry.
enum MCPConfigFile {
    static func read(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Leaves a file it can't read as JSON untouched, so a hand-edited config is never lost.
    static func addRays(path: String, key: String, dl: String) throws {
        var root: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: path) {
            guard let existing = read(path) else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "\(path) isn't valid JSON, so Rays left it as it is."])
            }
            root = existing
        }
        var servers = root[key] as? [String: Any] ?? [:]
        servers["rays"] = ["command": dl, "args": ["mcp"]]
        root[key] = servers
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let url = URL(filePath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

struct MCPAppsSection: View {
    @State private var apps = MCPApp.all()
    @State private var added: Set<String> = []
    @State private var copied: String?
    @State private var error: String?

    private var dl: String { CommandLineTool.bundled.path(percentEncoded: false) }

    var body: some View {
        CardSection("Connect an AI app") {
            ForEach(apps) { app in
                CardRow(title: app.name, subtitle: subtitle(app), status: status(app)) {
                    icon(app)
                } trailing: {
                    button(app)
                }
            }
            CardRow(title: "Other apps", subtitle: "Most AI apps take this JSON in their MCP settings.") {
                IconTile(Tile(symbol: "curlybraces", color: TilePalette.gray), size: TileSize.list)
            } trailing: {
                Button(copied == "json" ? "Copied" : "Copy JSON") {
                    copy(#"{ "mcpServers": { "rays": { "command": "\#(dl)", "args": ["mcp"] } } }"#, id: "json")
                }
            }
            if let error { ErrorLine(text: error) }
        }
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func refresh() {
        apps = MCPApp.all()
        added = Set(apps.filter(\.isAdded).map(\.id))
    }

    private func subtitle(_ app: MCPApp) -> String {
        if added.contains(app.id) { return "Added" }
        if case .none = app.add { return app.hint }
        return app.bundleID != nil && app.appURL == nil ? "Not installed" : app.hint
    }

    private func status(_ app: MCPApp) -> StatusDot.Kind? {
        if added.contains(app.id) { return .ok }
        if case .none = app.add { return .off }
        return nil
    }

    @ViewBuilder private func icon(_ app: MCPApp) -> some View {
        if let url = app.appURL {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false)))
                .resizable()
                .accessibilityHidden(true)
        } else {
            IconTile(app.fallback, size: TileSize.list)
        }
    }

    @ViewBuilder private func button(_ app: MCPApp) -> some View {
        switch app.add {
        case .config(let path, let key):
            Button(added.contains(app.id) ? "Add again" : "Add") {
                do {
                    try MCPConfigFile.addRays(path: path, key: key, dl: dl)
                    error = nil
                    refresh()
                } catch {
                    self.error = error.localizedDescription
                }
            }
            .disabled(app.appURL == nil && !added.contains(app.id))
        case .link(let make):
            Button("Add") { make(dl).map { NSWorkspace.shared.open($0) } }
                .disabled(app.appURL == nil)
        case .copyCommand(let make):
            Button(copied == app.id ? "Copied" : "Copy command") { copy(make(dl), id: app.id) }
        case .none:
            EmptyView()
        }
    }

    private func copy(_ text: String, id: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = id
    }
}
