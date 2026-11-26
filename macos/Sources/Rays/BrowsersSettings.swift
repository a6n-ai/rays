import AppKit
import SwiftUI

struct BrowsersPage: View {
    @Environment(NavHistory.self) private var nav
    @State private var model = BrowserCheckModel()

    private var allInstalled: Bool { !model.states.contains { $0.browser.engine != .safari && $0.helper != .ok } }

    var body: some View {
        Group {
            if nav.sub == "helper" {
                CardForm { CardSection { HelperExplainer() } }
            } else {
                overview
            }
        }
        .formStyle(.grouped)
        .navigationTitle(nav.sub == "helper" ? "How the helper works" : "Browsers")
        .controlSize(.small)
        .toggleStyle(SettingSwitchStyle())
        .onAppear { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
    }

    private var overview: some View {
        CardForm {
            CardSection {
                HeroCard(.browsers, title: "Browsers", subtitle: "Add the Rays extension to send links from your browser.") {
                    HeroActions {
                        Button("Install all helpers") { model.installAllHelpers(model.states) }
                            .disabled(allInstalled)
                            .help(allInstalled ? "All helpers are installed" : "Install the helper in every browser")
                        Button("Check again") { model.refresh() }
                    }
                }
                DrillInRow(tile: Tile(symbol: "questionmark.circle.fill", color: TilePalette.gray), title: "How the helper works",
                           subtitle: "What it does and how to remove it") { nav.open("helper") }
            }
            if model.loaded && model.states.isEmpty {
                CardSection {
                    Text("No supported browsers found.")
                        .foregroundStyle(.secondary)
                }
            }
            if !model.states.isEmpty || !model.others.isEmpty {
                CardSection {
                    ForEach(model.states) { state in
                        BrowserRow(state: state, failure: model.failures[state.browser.bundleID],
                                   install: { model.installHelper(state) },
                                   remove: { model.removeHelper(state) })
                    }
                    ForEach(model.others) { OtherBrowserRow(browser: $0) }
                }
            }
            if model.states.contains(where: { $0.helper != .missing }) {
                RemoveAllHelpersRow(model: model)
            }
        }
    }
}

private func appIcon(_ url: URL) -> some View {
    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false)))
        .resizable()
        .frame(width: TileSize.row, height: TileSize.row)
        .accessibilityHidden(true)
}

/// A browser Rays found but has no setup for, with what that means.
private struct OtherBrowserRow: View {
    let browser: BrowserCheck.OtherBrowser

    var body: some View {
        CardRow(title: browser.name,
                subtitle: browser.chromium
                    ? "Built on Chromium, but Rays couldn't find its data folder. Open it once, then click Check again."
                    : "Rays can't add itself to this browser: its extension needs Chrome, Firefox or a browser built on them.",
                status: .off) { appIcon(browser.appURL) }
    }
}

/// One browser: app icon, name, status line, and only the buttons that apply.
private struct BrowserRow: View {
    let state: BrowserCheck.State
    let failure: String?
    let install: () -> Void
    let remove: () -> Void
    @State private var confirmRemove = false

    private var status: (StatusDot.Kind, String) {
        if state.browser.engine == .safari { return (.off, "Coming later, Safari needs a signed build") }
        switch (state.helper, state.addon) {
        case (.broken(let reason), _): return (.error, "Helper needs repair: \(reason)")
        case (.missing, _): return (.off, "Helper not installed")
        case (.ok, .added): return (.ok, "Connected, extension added")
        case (.ok, .notAdded): return (.warning, "Connected, extension not found")
        case (.ok, .unknown): return (.warning, "Connected, extension not found")
        }
    }

    var body: some View {
        CardRow(title: state.browser.name, subtitle: failure ?? status.1, status: failure == nil ? status.0 : .error) {
            appIcon(state.appURL)
        } trailing: {
            if state.browser.engine != .safari { buttons }
        }
        .confirmationDialog("Remove the Rays helper from \(state.browser.name)?",
                            isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove helper", role: .destructive, action: remove)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(state.browser.helperNote.map { "\($0) Removing it affects both. You can install it again anytime." }
                 ?? "Download with Rays stops working in this browser. You can install it again anytime.")
        }
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 8) {
            if state.helper != .ok {
                Button(state.helper == .missing ? "Install helper" : "Repair helper", action: install)
                    .buttonStyle(.bordered)
            }
            if state.addon != .added, BrowserCheck.storeURL(for: state.browser.engine) != nil {
                Button("Get extension") { BrowserCheck.openStore(in: state.browser) }
                    .buttonStyle(.bordered)
                    .help(state.browser.engine == .firefox ? "Opens Rays on Firefox Add-ons." : "Opens Rays in the Chrome Web Store.")
            }
            if state.helper != .missing {
                HeroMenu {
                    Button("Remove helper", role: .destructive) { confirmRemove = true }
                        .help(state.browser.helperNote ?? "Removes the helper from this browser.")
                }
            }
        }
    }
}

private struct RemoveAllHelpersRow: View {
    let model: BrowserCheckModel
    @State private var confirm = false

    var body: some View {
        DestructiveButton(title: "Remove all helpers…") { confirm = true }
            .help("Disconnects Rays from every browser.")
            .confirmationDialog("Remove the Rays helper from all browsers?", isPresented: $confirm,
                                titleVisibility: .visible) {
                Button("Remove all helpers", role: .destructive) { model.removeAllHelpers() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Download with Rays stops working in your browsers until you install the helpers again.")
            }
    }
}
