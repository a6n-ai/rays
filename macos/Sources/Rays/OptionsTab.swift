import SwiftUI

/// Concurrency, speed, retry, wake, and what happens when the queue finishes.
struct OptionsTab: View {
    @Binding var draft: QueueConfig
    let queueId: UInt64
    let onDelete: () -> Void
    @Environment(EngineModel.self) private var model
    @AppStorage(SettingsKey.maxRunning) private var cap = 3
    @State private var wakeInstalled = false
    @State private var wakeMissing = false
    @State private var confirmDelete = false

    private var shownRunning: Int { Int(min(draft.maxRunning, UInt32(max(cap, 0)))) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: LayoutMetrics.gap) {
                if let queue = model.queues.first(where: { $0.id == queueId }) {
                    formRow("Icon & color") { QueueIconPicker(queue: queue) }
                }
                formRow("Simultaneous") {
                    Stepper(value: Binding(get: { shownRunning }, set: { draft.maxRunning = UInt32($0) }), in: 0...max(cap, 1)) {
                        Text(shownRunning == 0 ? "Same as Rays" : "\(shownRunning) download\(shownRunning == 1 ? "" : "s") at a time")
                            .monospacedDigit()
                    }
                }
                formRow("Speed limit") {
                    HStack(spacing: 8) {
                        Picker("Speed limit", selection: Binding(get: { Int(draft.speedLimit) }, set: { draft.speedLimit = UInt64($0) })) {
                            ForEach(SpeedPreset.all) { Text($0.title).tag($0.bytes) }
                            if !SpeedPreset.all.contains(where: { $0.bytes == Int(draft.speedLimit) }) {
                                Text(SpeedPreset.text(Int(draft.speedLimit))).tag(Int(draft.speedLimit))
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Text("for the whole queue").font(.callout).foregroundStyle(.secondary)
                    }
                }
                formRow("Options") {
                    Toggle("Retry failed downloads", isOn: $draft.retryFailed)
                    if draft.schedule != nil { wake }
                }
                formRow("When finished", top: true) { FinishActionGrid(action: $draft.whenFinished) }
            }
            .toggleStyle(.checkbox)
            if queueId != 1 {
                Button("Delete queue") { confirmDelete = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .frame(minHeight: 28)
                    .padding(.leading, 122)
            }
        }
        .formColumn()
        .task { await refreshWake() }
        .confirmationDialog("Delete queue \(draft.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete queue", role: .destructive, action: onDelete)
        } message: {
            Text("Its downloads move to Main.")
        }
    }

    @ViewBuilder private var wake: some View {
        HStack(spacing: 12) {
            Toggle("Wake the Mac to start", isOn: Binding(get: { draft.wake }, set: setWake))
            if wakeInstalled {
                Button("Remove wake permission") { Task { await removeWake() } }
                    .buttonStyle(.link)
                    .font(.callout)
            }
        }
        if draft.wake && wakeMissing {
            HStack(spacing: 8) {
                Label("Permission missing", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                Button("Set Up Again") { Task { _ = await WakePermission.ensure(); await refreshWake() } }
                    .controlSize(.small)
            }
        }
    }

    private func setWake(_ on: Bool) {
        guard on else { draft.wake = false; return }
        Task {
            draft.wake = await WakePermission.ensure()
            await refreshWake()
        }
    }

    private func removeWake() async {
        if !(await WakePermission.remove()) {
            model.showNotice("Couldn't remove the wake permission. Try Remove wake permission again.")
        }
        await refreshWake()
    }

    private func refreshWake() async {
        (wakeInstalled, wakeMissing) = await WakePermission.status()
    }
}
