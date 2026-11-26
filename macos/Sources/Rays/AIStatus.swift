import AppKit
import FoundationModels
import SwiftUI

/// Whether Apple's on-device model, which the sorter uses through `/usr/bin/fm`, can run right now.
enum AIReadiness: Equatable {
    case ready
    case notEnabled          // Apple Intelligence is off or its terms haven't been accepted
    case downloading         // turned on, model assets still downloading
    case notEligible         // this Mac can't run Apple Intelligence
    case toolMissing         // macOS doesn't have the `fm` command
    case unknown(String)

    static func current() -> AIReadiness {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/fm") else { return .toolMissing }
        switch SystemLanguageModel.default.availability {
        case .available: return .ready
        case .unavailable(.appleIntelligenceNotEnabled): return .notEnabled
        case .unavailable(.modelNotReady): return .downloading
        case .unavailable(.deviceNotEligible): return .notEligible
        case .unavailable(let other): return .unknown(String(describing: other))
        }
    }

    var isReady: Bool { self == .ready }

    var title: String {
        switch self {
        case .ready: "On-device AI is ready"
        case .notEnabled: "Turn on Apple Intelligence"
        case .downloading: "The model is still downloading"
        case .notEligible: "This Mac can't run Apple Intelligence"
        case .toolMissing: "Apple's model tool isn't installed"
        case .unknown: "On-device AI isn't available"
        }
    }

    var hint: String {
        switch self {
        case .ready: "Sorting runs on your Mac with Apple's model. Nothing is uploaded."
        case .notEnabled: "Sorting uses Apple's on-device model. Turn on Apple Intelligence and accept its terms in System Settings."
        case .downloading: "Sorting starts working when the download finishes. Keep your Mac on power and Wi-Fi."
        case .notEligible: "Sorting needs a Mac with Apple silicon that supports Apple Intelligence."
        case .toolMissing: "Update macOS to get the fm command that sorting uses."
        case .unknown(let reason): "macOS reports: \(reason)."
        }
    }

    var symbol: String {
        switch self {
        case .ready: "checkmark.circle.fill"
        case .downloading: "arrow.down.circle.fill"
        case .notEligible: "xmark.octagon.fill"
        default: "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .ready: TilePalette.green
        case .downloading: TilePalette.blue
        case .notEligible: TilePalette.red
        default: TilePalette.orange
        }
    }
}

/// Holds the last readiness check. Views read `value`; the check itself (which touches the observable
/// SystemLanguageModel) runs outside view bodies, so drawing never subscribes to the model's changes.
@MainActor
@Observable
final class AIReadinessStore {
    static let shared = AIReadinessStore()
    private(set) var value: AIReadiness = .ready

    private init() {
        refresh()
        // Re-check when the app comes back to the front (e.g. after turning Apple Intelligence on).
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { AIReadinessStore.shared.refresh() } }
    }

    func refresh() {
        let current = AIReadiness.current()
        if current != value { value = current }
    }
}

struct AIStatusRow: View {
    private var readiness: AIReadiness { AIReadinessStore.shared.value }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            IconTile(Tile(symbol: readiness.symbol, color: readiness.color))
            VStack(alignment: .leading, spacing: 2) {
                Text(readiness.title).font(.callout.weight(.semibold))
                Text(readiness.hint).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if readiness == .notEnabled {
                Button("Open Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.glass)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
