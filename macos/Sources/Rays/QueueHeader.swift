import SwiftUI

/// The top of a queue's page, above its sections: an editable name, totals, the state when not open, and the enabled switch.
struct QueueHeader: View {
    let queue: QueueView
    let items: Int
    @Binding var draft: QueueConfig
    let showsRunNow: Bool
    let isDirty: Bool
    @Environment(EngineModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: LayoutMetrics.gap) {
            QueueTile(queue: queue, size: 44)
            VStack(alignment: .leading, spacing: 6) {
                TextField("Queue name", text: $draft.name)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                Text("\(items) items · \(queue.running) downloading · \(byteText(queue.totalBytes)) total")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if queue.state != .open, let badge = queue.badge { QueueBadgePill(badge: badge) }
            }
            Spacer()
            if showsRunNow {
                Button { model.runQueueNow(queue.id) } label: { Label("Run now", systemImage: "play.fill") }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .disabled(isDirty)
                    .help(isDirty ? "Save your changes first" : "Run this queue now")
            }
            Button {
                if queue.isStopped { model.startQueue(queue.id) } else { model.stopQueue(queue.id) }
            } label: {
                Label(queue.isStopped ? "Start queue" : "Stop queue", systemImage: queue.isStopped ? "play.circle" : "stop.circle")
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            Toggle("Enabled", isOn: Binding(get: { queue.config.enabled }, set: { model.setQueueEnabled(queue, $0) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .tint(.accentColor)
                .help("Enabled")
        }
        .padding(.horizontal, LayoutMetrics.margin)
        .padding(.vertical, 10)
    }
}

/// A queue's state as a capsule tinted with its semantic colour.
struct QueueBadgePill: View {
    let badge: QueueBadge

    var body: some View {
        Label(badge.text, systemImage: badge.symbol)
            .font(.callout)
            .foregroundStyle(badge.tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(badge.tint.opacity(0.15), in: Capsule())
    }
}
