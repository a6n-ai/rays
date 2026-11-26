import AppKit
import SwiftUI

struct BrowsersTab: View {
    @State private var model = BrowserCheckModel()

    var body: some View {
        Form {
            Section {
                SettingRow(.browsers, title: "Rays browser extension", hint: "Right-click any link and choose Download with Rays.") {
                    Button("Install All Helpers") { model.installAllHelpers(model.states) }
                        .buttonStyle(.glassProminent)
                        .disabled(!model.states.contains { $0.browser.engine != .safari && $0.helper != .ok })
                    Button("Check again") { model.refresh() }
                        .buttonStyle(.glass)
                }
                if model.states.contains(where: { $0.helper != .missing }) {
                    RemoveAllHelpersRow(model: model)
                }
                HelperExplainer()
            }
            if model.loaded && model.states.isEmpty {
                Section {
                    Text("No supported browsers found.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(model.states) { state in
                Section {
                    BrowserStatus(state: state, failure: model.failures[state.browser.bundleID],
                                  install: { model.installHelper(state) },
                                  remove: { model.removeHelper(state) })
                } header: {
                    BrowserTitle(state: state)
                }
            }
            ForEach(model.others) { other in
                Section { OtherBrowserRow(browser: other) }
            }
            SavedNote()
        }
        .scrollContentBackground(.hidden)
        .formStyle(.grouped)
        .controlSize(.small)
        .toggleStyle(SettingSwitchStyle())
        .onAppear { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
    }
}

/// A browser Rays found but has no setup for, with what that means.
private struct OtherBrowserRow: View {
    let browser: BrowserCheck.OtherBrowser

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: browser.appURL.path(percentEncoded: false)))
                .resizable()
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(browser.name)
                Text(browser.chromium
                     ? "Built on Chromium, but Rays couldn't find its data folder. Open it once, then click Check again."
                     : "Rays can't add itself to this browser: its extension needs Chrome, Firefox or a browser built on them.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct BrowserTitle: View {
    let state: BrowserCheck.State

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: state.appURL.path(percentEncoded: false)))
                .resizable()
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityHidden(true)
            Text(state.browser.name)
        }
    }
}

private struct BrowserStatus: View {
    let state: BrowserCheck.State
    let failure: String?
    let install: () -> Void
    let remove: () -> Void
    @State private var confirmRemove = false

    var body: some View {
        if state.browser.engine == .safari {
            Label("Coming later — Safari needs a signed build.", systemImage: "clock")
                .foregroundStyle(.secondary)
        } else {
            helperLine
            if let note = state.browser.helperNote {
                Text(note).font(.callout).foregroundStyle(.secondary)
            }
            addonLine
            HStack(spacing: 8) {
                if state.helper != .ok {
                    Button(state.helper == .missing ? "Install Helper" : "Repair Helper", action: install)
                        .buttonStyle(.glass)
                }
                if state.addon != .added, BrowserCheck.storeURL(for: state.browser.engine) != nil {
                    Button("Get Extension") { BrowserCheck.openStore(in: state.browser) }
                        .buttonStyle(.glassProminent)
                        .help(state.browser.engine == .firefox ? "Opens Rays on Firefox Add-ons." : "Opens Rays in the Chrome Web Store.")
                }
                if state.helper != .missing {
                    Button("Remove Helper", role: .destructive) { confirmRemove = true }
                        .buttonStyle(.glass)
                        .confirmationDialog("Remove the Rays helper from \(state.browser.name)?",
                                            isPresented: $confirmRemove, titleVisibility: .visible) {
                            Button("Remove Helper", role: .destructive, action: remove)
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text(state.browser.engine == .firefox
                                 ? "Download with Rays stops working in this browser. Firefox and Zen share this helper, so both are affected. You can install it again anytime."
                                 : "Download with Rays stops working in this browser. You can install it again anytime.")
                        }
                }
            }
            if let failure {
                ErrorLine(text: failure)
            }
        }
    }

    @ViewBuilder
    private var helperLine: some View {
        switch state.helper {
        case .ok:
            StatusLine(symbol: "checkmark.circle.fill", color: .green, text: "Connected to Rays")
        case .broken(let reason):
            StatusLine(symbol: "exclamationmark.triangle.fill", color: .orange, text: "Helper needs repair: \(reason)")
        case .missing:
            StatusLine(symbol: "xmark.circle", color: .secondary, text: "Helper not installed")
        }
    }

    @ViewBuilder
    private var addonLine: some View {
        switch state.addon {
        case .added:
            StatusLine(symbol: "checkmark.circle.fill", color: .green, text: "Extension added")
        case .notAdded:
            StatusLine(symbol: "xmark.circle", color: .secondary, text: "Extension not added")
        case .unknown(let reason):
            StatusLine(symbol: "questionmark.circle", color: .secondary, text: "Extension status unknown", detail: reason)
        }
    }
}

private struct StatusLine: View {
    let symbol: String
    let color: Color
    let text: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label {
                Text(text)
            } icon: {
                Image(systemName: symbol).foregroundStyle(color)
            }
            if let detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct RemoveAllHelpersRow: View {
    let model: BrowserCheckModel
    @State private var confirm = false

    var body: some View {
        SettingRow(.trash, title: "Remove all helpers",
                   hint: "Disconnects Rays from every browser. Nothing else in your browsers changes.") {
            Button("Remove All Helpers", role: .destructive) { confirm = true }
                .buttonStyle(.glass)
                .confirmationDialog("Remove the Rays helper from all browsers?", isPresented: $confirm,
                                    titleVisibility: .visible) {
                    Button("Remove All Helpers", role: .destructive) { model.removeAllHelpers() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Download with Rays stops working in your browsers until you install the helpers again.")
                }
        }
    }
}
