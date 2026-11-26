import AppKit
import SwiftUI

/// Explains the app's Shortcuts actions and the other ways to send links to Rays.
struct ShortcutsPage: View {
    @Environment(EngineModel.self) private var model

    private struct Action: Identifiable {
        let tile: Tile, title: String, detail: String, phrase: String
        var id: String { title }
    }

    // Keep in step with the intents and phrases in Intents.swift.
    private let actions = [
        Action(tile: .downloads, title: "Add download", detail: "Adds a link and starts it, or queues it.",
               phrase: "Add a download in Rays"),
        Action(tile: .queues, title: "Start queue", detail: "Starts one of your queues.", phrase: "Start a queue in Rays"),
        Action(tile: .queues, title: "Stop queue", detail: "Stops one of your queues.", phrase: "Stop a queue in Rays"),
        Action(tile: .speed, title: "Run speed test", detail: "Measures your speed and returns it, for example 212 Mbps.",
               phrase: "Run a speed test in Rays"),
        Action(tile: .downloads, title: "Pause all downloads", detail: "Pauses every download that can resume.",
               phrase: "Pause all downloads in Rays"),
        Action(tile: .downloads, title: "Resume all downloads", detail: "Resumes every paused download.",
               phrase: "Resume all downloads in Rays"),
        Action(tile: .clipboard, title: "Download copied link", detail: "Downloads the link on the clipboard.",
               phrase: "Download copied link in Rays"),
    ]

    var body: some View {
        NavigationStack {
            CardForm {
                CardSection {
                    HeroCard(.shortcuts, title: "Shortcuts", subtitle: "Start downloads and queues from Shortcuts and Siri.",
                             learnMore: URL(string: "https://rays.a6n.ai/docs/app/shortcuts/")) {
                        HeroActions {
                            // ShortcutsLink is not available on macOS, so this opens the app itself.
                            Button("Open Shortcuts") { NSWorkspace.shared.open(URL(string: "shortcuts://")!) }
                        }
                    }
                }
                CardSection {
                    ForEach(actions) { action in
                        CardRow(title: action.title, subtitle: action.detail) {
                            IconTile(action.tile, size: TileSize.row)
                        } trailing: {
                            Text("\u{201C}\(action.phrase)\u{201D}").font(.subheadline).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                } header: {
                    Text("Actions")
                } footer: {
                    Text("These appear in Shortcuts and Spotlight without setup. Run one there, or say its phrase to Siri.")
                }
                CardSection {
                    step(1, "Open Shortcuts and make a new shortcut.")
                    step(2, "Search for Rays in the actions list.")
                    step(3, "Drag an action into your shortcut.")
                } header: {
                    Text("How to add one")
                }
                CardSection("Other ways to send links to Rays") {
                    way(.shortcuts, "Share menu", "Choose Rays in the Share menu of any app.") {
                        Button("Open sharing settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences")!)
                        }
                    }
                    way(.downloads, "Services menu", "Select a link, then choose Download with Rays from Services.")
                    way(.browsers, "Browser extension", "Right-click any link in your browser.") {
                        Button("Browser settings") {
                            model.requestedDestination = .browsers
                        }
                    }
                    way(.commandLine, "Command line", "Run dl add followed by a link. Install dl on the General page.")
                }
            }
            .formStyle(.grouped)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .navigationTitle("Shortcuts")
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n).").monospacedDigit().foregroundStyle(.secondary)
            Text(text)
        }
        .padding(.vertical, 2)
    }

    private func way(_ tile: Tile, _ title: String, _ detail: String, @ViewBuilder button: () -> some View = { EmptyView() }) -> some View {
        CardRow(title: title, subtitle: detail) { IconTile(tile, size: TileSize.row) } trailing: { button() }
    }
}
