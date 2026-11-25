import SwiftUI

/// App-wide queue settings: the wake permission, and the defaults given to queues created from now on.
struct QueueSettingsTab: View {
    @Environment(EngineModel.self) private var model
    @AppStorage(SettingsKey.maxRunning) private var cap = 3
    @AppStorage(SettingsKey.queueDefaultMaxRunning) private var defaultRunning = 0
    @AppStorage(SettingsKey.queueDefaultSpeed) private var defaultSpeed = 0
    @AppStorage(SettingsKey.queueDefaultFinish) private var defaultFinish = FinishKind.nothing.rawValue
    @State private var installed = false
    @State private var missing = false
    @State private var busy = false

    private var shownRunning: Int { min(max(defaultRunning, 0), max(cap, 1)) }
    private static let finishChoices: [FinishKind] = [.nothing, .sound, .quit, .sleep, .lock]

    var body: some View {
        Form {
            Section {
                LabeledContent("Wake permission") {
                    HStack(spacing: 8) {
                        Label(installed ? "Set up" : "Not set up", systemImage: installed ? "checkmark.circle" : "minus.circle")
                            .foregroundStyle(installed ? Color.green : Color.secondary)
                        Button("Set Up…") { Task { await run { _ = await WakePermission.ensure() } } }
                            .disabled(installed || busy)
                        Button("Remove") {
                            Task {
                                await run {
                                    if !(await WakePermission.remove()) {
                                        model.showNotice("Couldn't remove the wake permission. Try Remove again.")
                                    }
                                }
                            }
                        }
                        .disabled(!installed || busy)
                    }
                }
                if missing {
                    Label("A queue wakes the Mac but the permission is missing.", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Wake")
            } footer: {
                Text("Rays can wake your Mac to start a scheduled queue. It asks for your administrator password once, to allow setting wake times and nothing else. Without it, keep your Mac awake and Rays running at the start time.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            Section {
                LabeledContent("Simultaneous") {
                    Stepper(value: Binding(get: { shownRunning }, set: { defaultRunning = $0 }), in: 0...max(cap, 1)) {
                        Text(shownRunning == 0 ? "Same as Rays" : "\(shownRunning) download\(shownRunning == 1 ? "" : "s") at a time")
                            .monospacedDigit()
                    }
                }
                Picker("Speed limit", selection: $defaultSpeed) {
                    ForEach(SpeedPreset.all) { Text($0.title).tag($0.bytes) }
                    if !SpeedPreset.all.contains(where: { $0.bytes == defaultSpeed }) {
                        Text(SpeedPreset.text(defaultSpeed)).tag(defaultSpeed)
                    }
                }
                .pickerStyle(.menu)
                Picker("When finished", selection: $defaultFinish) {
                    ForEach(Self.finishChoices, id: \.rawValue) { Label($0.title, systemImage: $0.symbol).tag($0.rawValue) }
                }
                .pickerStyle(.menu)
            } header: {
                Text("Defaults for new queues")
            } footer: {
                Text("Defaults apply to queues you create from now on. Run command and Shut down are set per queue.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
        .scrollContentBackground(.hidden)
        .formStyle(.grouped)
        .task { await refresh() }
    }

    private func run(_ work: () async -> Void) async {
        busy = true
        await work()
        await refresh()
        busy = false
    }

    private func refresh() async {
        (installed, missing) = await WakePermission.status()
    }
}
