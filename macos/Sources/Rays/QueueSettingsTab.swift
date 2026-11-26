import SwiftUI

/// App-wide queue settings as rows of the Queues settings card: the wake permission, and the defaults given to queues created from now on.
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

    private var count: Int { missing ? 5 : 4 }

    private func row(_ index: Int) -> CardRowBackground.Position { CardRowBackground.position(index + 1, of: count + 1) }

    var body: some View {
        SettingRow(title: "Wake permission",
                   hint: "Lets a queue wake your Mac on time. Asks for your administrator password once. Without it, keep the Mac awake.",
                   status: installed ? .ok : .off) {
            HStack(spacing: 8) {
                Text(installed ? "Set up" : "Not set up").foregroundStyle(.secondary)
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
        .cardRow(row(0), separatorInset: 0)
        .task { await refresh() }
        if missing {
            SettingRow(title: "Wake permission missing", hint: "A queue wakes the Mac but the permission is missing.", status: .warning) {
                EmptyView()
            }
            .cardRow(row(1), separatorInset: 0)
        }
        SettingRow(title: "Simultaneous", hint: "Defaults for new queues.") {
            StepSlider(title: "Simultaneous", value: Binding(get: { shownRunning }, set: { defaultRunning = $0 }),
                       range: 0...max(cap, 1), lowLabel: "Same as Rays", highLabel: "\(max(cap, 1))") {
                $0 == 0 ? "Auto" : "\($0)"
            }
        }
        .cardRow(row(missing ? 2 : 1), separatorInset: 0)
        SettingRow(title: "Speed limit") {
            SpeedLimitField(bytes: $defaultSpeed)
        }
        .cardRow(row(missing ? 3 : 2), separatorInset: 0)
        SettingRow(title: "When finished") {
            Picker("When finished", selection: $defaultFinish) {
                ForEach(Self.finishChoices, id: \.rawValue) { Label($0.title, systemImage: $0.symbol).tag($0.rawValue) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        }
        .cardRow(row(missing ? 4 : 3), separatorInset: 0)
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
