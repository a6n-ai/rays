import SwiftUI

/// The top of a queue's page, above every tab: an editable name, totals, the state when not open, and the enabled switch.
struct QueueHeader: View {
    let queue: QueueView
    let items: Int
    @Binding var draft: QueueConfig
    let showsRunNow: Bool
    let isDirty: Bool
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
                TextField("Queue name", text: $draft.name)
                    .textFieldStyle(.plain)
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
            if showsRunNow {
                Button { model.runQueueNow(queue.id) } label: { Label("Run now", systemImage: "play.fill") }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .disabled(isDirty)
                    .help(isDirty ? "Save your changes first" : "Run this queue now")
            }
            Toggle("Enabled", isOn: Binding(get: { queue.config.enabled }, set: setEnabled))
                .toggleStyle(.switch)
                .labelsHidden()
                .help("Enabled")
        }
        .padding(.horizontal, LayoutMetrics.margin)
        .padding(.vertical, 10)
    }

    /// Saves at once against the saved config, so name edits still waiting in the draft are not saved with it. A failure leaves the switch where it was.
    private func setEnabled(_ on: Bool) {
        var config = queue.config
        config.enabled = on
        do { _ = try model.saveQueue(config) } catch { model.queueFailed("change the queue", error) }
    }

    private static func conditionSymbol(_ missing: [String]) -> String {
        switch missing.first {
        case "charger"?: "bolt"
        case "idle"?: "moon"
        default: "wifi"
        }
    }
}
