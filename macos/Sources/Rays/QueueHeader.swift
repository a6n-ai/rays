import SwiftUI

/// The top of a queue's page: its name, totals, the state when not open, and the controls that stop, start and schedule it.
struct QueueHeader: View {
    let queue: QueueView
    let items: Int
    let onSchedule: () -> Void
    @Environment(EngineModel.self) private var model

    private var pill: (symbol: String, text: String, tint: Color)? {
        switch queue.state {
        case .open:
            nil
        case .waitingForTime(let next):
            ("clock", "Starts " + Date(timeIntervalSince1970: TimeInterval(next)).formatted(Date.FormatStyle().hour().minute()), .orange)
        case .waitingForCondition(let missing):
            (Self.conditionSymbol(missing), "Waiting for " + missing.joined(separator: ", "), .yellow)
        case .stopped:
            ("pause.circle", "Stopped", .secondary)
        case .off:
            ("minus.circle", "Off", Color(nsColor: .tertiaryLabelColor))
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: LayoutMetrics.gap) {
            VStack(alignment: .leading, spacing: 6) {
                Text(queue.config.name)
                    .font(.title2.weight(.semibold))
                Text("\(items) items · \(queue.running) downloading · \(byteText(queue.totalBytes)) total")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if let pill {
                    Label(pill.text, systemImage: pill.symbol)
                        .font(.callout)
                        .foregroundStyle(pill.tint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(pill.tint.opacity(0.15), in: Capsule())
                }
            }
            Spacer()
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    if queue.isStopped {
                        Button { model.startQueue(queue.id) } label: {
                            Label("Start queue", systemImage: "play.circle")
                        }
                    } else {
                        Button { model.stopQueue(queue.id) } label: {
                            Label("Stop queue", systemImage: "stop.circle")
                        }
                    }
                    Button(action: onSchedule) {
                        Label("Schedule…", systemImage: "calendar.badge.clock")
                    }
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, LayoutMetrics.margin)
        .padding(.vertical, 10)
    }

    private static func conditionSymbol(_ missing: [String]) -> String {
        switch missing.first {
        case "charger"?: "bolt"
        case "idle"?: "moon"
        default: "wifi"
        }
    }
}
