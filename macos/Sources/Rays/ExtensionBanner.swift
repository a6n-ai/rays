import AppKit
import SwiftUI

/// Inline prompt above the downloads list when an installed browser still needs the Rays helper or
/// extension. Dismissing it remembers those browsers; it returns only for a browser not yet dismissed.
struct ExtensionBanner: View {
    @State private var check = BrowserCheckModel()
    @AppStorage("extensionBannerDismissed") private var dismissed = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var needing: [BrowserCheck.State] {
        check.states.filter { state in
            state.browser.engine != .safari && (state.helper != .ok || state.addon == .notAdded)
        }
    }

    private var helpersReady: Bool { needing.allSatisfy { $0.helper == .ok } }
    private var names: String { needing.map(\.browser.name).formatted(.list(type: .and)) }

    private var dismissedIDs: Set<String> { Set(dismissed.split(separator: ",").map(String.init)) }

    private var visible: Bool {
        check.loaded && needing.contains { !dismissedIDs.contains($0.id) }
    }

    var body: some View {
        Group {
            if visible {
                banner
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: visible)
        .task { check.refresh() }
        // Coming back from the browser after adding the extension should clear the banner on its own.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            check.refresh()
        }
    }

    private var banner: some View {
        HStack(spacing: LayoutMetrics.gap) {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(.indigo, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(helpersReady ? "Almost done: add the extension in \(names)" : "Add Rays to \(names)")
                    .font(.callout.weight(.semibold))
                Text(helpersReady
                     ? "Get it from your browser's extension store in one click."
                     : "Right-click any link to download it with Rays.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Not now") {
                dismissed = (dismissedIDs.union(needing.map(\.id))).sorted().joined(separator: ",")
            }
            .buttonStyle(.glass)
            if helpersReady {
                Button("Get extension") { needing.forEach { BrowserCheck.openStore(in: $0.browser) } }
                    .buttonStyle(.glassProminent)
                    .help("Opens the Rays extension in each browser's store")
            } else {
                Button("Install") { check.installAllHelpers(needing) }
                    .buttonStyle(.glassProminent)
                    .help("Connects Rays to \(names). Only writes Rays' own helper file for each browser.")
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .padding(.horizontal, LayoutMetrics.margin)
        .padding(.top, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Browser extension setup")
    }
}
