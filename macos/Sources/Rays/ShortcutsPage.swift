import AppKit
import SwiftUI

/// Explains the app's Shortcuts actions and the other ways to send links to Rays.
struct ShortcutsPage: View {
    @Environment(\.openSettings) private var openSettings

    private struct Action: Identifiable {
        let symbol: String, title: String, detail: String, phrase: String
        var id: String { title }
    }

    // Keep in step with the intents and phrases in Intents.swift.
    private let actions = [
        Action(symbol: "arrow.down.circle", title: "Add download", detail: "Adds a link and starts it, or queues it.",
               phrase: "Add a download in Rays"),
        Action(symbol: "play.circle", title: "Start queue", detail: "Starts one of your queues.", phrase: "Start a queue in Rays"),
        Action(symbol: "stop.circle", title: "Stop queue", detail: "Stops one of your queues.", phrase: "Stop a queue in Rays"),
        Action(symbol: "speedometer", title: "Run speed test", detail: "Measures your speed and returns it, for example 212 Mbps.",
               phrase: "Run a speed test in Rays"),
        Action(symbol: "pause.circle", title: "Pause all downloads", detail: "Pauses every download that can resume.",
               phrase: "Pause all downloads in Rays"),
        Action(symbol: "play.circle", title: "Resume all downloads", detail: "Resumes every paused download.",
               phrase: "Resume all downloads in Rays"),
        Action(symbol: "doc.on.clipboard", title: "Download copied link", detail: "Downloads the link on the clipboard.",
               phrase: "Download copied link in Rays"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LayoutMetrics.gap) {
                    header
                    section("Ready to use")
                    Text("These appear in the Shortcuts app and in Spotlight without any setup. Run one from there, or say its phrase to Siri.")
                        .font(.callout).foregroundStyle(.secondary)
                    VStack(spacing: 0) {
                        ForEach(actions) { row($0) }
                    }
                    // ShortcutsLink is not available on macOS, so this opens the app itself.
                    Button("Open Shortcuts") { NSWorkspace.shared.open(URL(string: "shortcuts://")!) }
                        .buttonStyle(.glassProminent)
                    section("How to add one")
                    VStack(alignment: .leading, spacing: 6) {
                        step(1, "Open Shortcuts and make a new shortcut.")
                        step(2, "Search for Rays in the actions list.")
                        step(3, "Drag an action into your shortcut.")
                    }
                    Text("Siri phrases work without any setup. Say one, or find it in Spotlight.")
                        .font(.callout).foregroundStyle(.secondary)
                    section("Other ways to send links to Rays")
                    VStack(alignment: .leading, spacing: LayoutMetrics.gap) {
                        way("square.and.arrow.up", "Share menu",
                            "Choose Rays in the Share menu of Safari or any app. Turn it on in System Settings > General > Login Items & Extensions > Sharing.") {
                            Button("Open Sharing Settings") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences")!)
                            }
                        }
                        way("contextualmenu.and.cursorarrow", "Services menu",
                            "Select a link, then choose Download with Rays from the app's Services menu.")
                        way("globe", "Browser extension", "Right-click any link in your browser and choose Download with Rays.") {
                            Button("Browser settings") {
                                UserDefaults.standard.set("browsers", forKey: "settingsTab")
                                openSettings()
                            }
                        }
                        way("terminal", "Command line", "Run dl add followed by a link. Install dl in Settings > General.")
                    }
                }
                .buttonStyle(.glass)
                .frame(maxWidth: 640, alignment: .leading)
                .padding(.horizontal, LayoutMetrics.margin)
                .padding(.bottom, LayoutMetrics.margin)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Shortcuts")
            .toolbar { ToolbarItem(placement: .primaryAction) { SettingsToolbarButton() } }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: LayoutMetrics.gap) {
            ModelTile(symbol: "square.2.layers.3d", color: .indigo, size: 44)
            VStack(alignment: .leading, spacing: 6) {
                Text("Shortcuts").font(.title2.weight(.semibold))
                Text("Rays adds actions to the Shortcuts app and to Siri, so you can start downloads and queues from your own automations.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 10)
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.headline).padding(.top, 4)
    }

    private func row(_ action: Action) -> some View {
        HStack(spacing: LayoutMetrics.gap) {
            Image(systemName: action.symbol).font(.title3).foregroundStyle(.tint).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                Text(action.detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: LayoutMetrics.gap)
            Text("\u{201C}\(action.phrase)\u{201D}").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n).").monospacedDigit().foregroundStyle(.secondary)
            Text(text)
        }
    }

    private func way(_ symbol: String, _ title: String, _ detail: String, @ViewBuilder button: () -> some View = { EmptyView() }) -> some View {
        HStack(alignment: .top, spacing: LayoutMetrics.gap) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.tint).frame(width: 28)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                button().controlSize(.small)
            }
        }
    }
}
