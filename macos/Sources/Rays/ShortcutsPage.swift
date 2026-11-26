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

    private struct Template: Identifiable {
        let file: String, symbol: String, detail: String, steps: [String]
        var id: String { file }
    }

    private let templates = [
        Template(file: "Download from Share Sheet", symbol: "square.and.arrow.up", detail: "Downloads links shared from Safari or any app.",
                 steps: ["Make a new shortcut and turn on Use as Quick Action > Share Sheet.", "Add Repeat with Each, with Shortcut Input.",
                         "Inside it, add Rays > Add download and set Link to Repeat Item."]),
        Template(file: "Speed check", symbol: "speedometer", detail: "Tests your speed and shows the result.",
                 steps: ["Make a new shortcut.", "Add Rays > Run speed test.", "Add Show Result below it."]),
        Template(file: "Download copied link", symbol: "doc.on.clipboard", detail: "Downloads the link you just copied.",
                 steps: ["Make a new shortcut.", "Add Get Clipboard.", "Add Rays > Add download and set Link to Clipboard."]),
        Template(file: "Night downloads", symbol: "moon.stars", detail: "Starts a queue of your choice.",
                 steps: ["Make a new shortcut.", "Add Rays > Start queue.", "Leave Queue empty so it asks each time."]),
    ]

    private func bundled(_ t: Template) -> URL? {
        Bundle.main.url(forResource: t.file, withExtension: "shortcut", subdirectory: "Shortcuts")
    }

    private func template(_ t: Template) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: LayoutMetrics.gap) {
                Image(systemName: t.symbol).font(.title3).foregroundStyle(.tint).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.file)
                    Text(t.detail).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: LayoutMetrics.gap)
                if let url = bundled(t) {
                    Button("Add") { NSWorkspace.shared.open(url) }.controlSize(.small)
                }
            }
            if bundled(t) == nil {
                DisclosureGroup("Build it") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(t.steps.enumerated()), id: \.offset) { step($0.offset + 1, $0.element) }
                    }
                    .font(.callout).padding(.top, 4)
                }
                .font(.callout).padding(.leading, 28 + LayoutMetrics.gap)
            }
        }
        .padding(.vertical, 8)
    }

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
                    section("Ready-made shortcuts")
                    Text("Common automations built from the actions above.").font(.callout).foregroundStyle(.secondary)
                    VStack(spacing: 0) {
                        ForEach(templates) { template($0) }
                    }
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
