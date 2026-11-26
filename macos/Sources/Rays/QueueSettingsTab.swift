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
        SettingRow(.wake, title: "Wake permission",
                   hint: "Rays can wake your Mac to start a scheduled queue. It asks for your administrator password once, to allow setting wake times and nothing else. Without it, keep your Mac awake and Rays running at the start time.",
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
        .cardRow(row(0), separatorInset: TileSize.row + 10)
        .task { await refresh() }
        if missing {
            SettingRow(.warning, title: "Wake permission missing", hint: "A queue wakes the Mac but the permission is missing.", status: .warning) {
                EmptyView()
            }
            .cardRow(row(1), separatorInset: TileSize.row + 10)
        }
        SettingRow(.concurrency, title: "Simultaneous", hint: "Defaults apply to queues you create from now on. Run command and Shut down are set per queue.") {
            Stepper(value: Binding(get: { shownRunning }, set: { defaultRunning = $0 }), in: 0...max(cap, 1)) {
                Text(shownRunning == 0 ? "Same as Rays" : "\(shownRunning) download\(shownRunning == 1 ? "" : "s") at a time")
                    .monospacedDigit()
            }
        }
        .cardRow(row(missing ? 2 : 1), separatorInset: TileSize.row + 10)
        SettingRow(.speedLimit, title: "Speed limit") {
            Picker("Speed limit", selection: $defaultSpeed) {
                ForEach(SpeedPreset.all) { Text($0.title).tag($0.bytes) }
                if !SpeedPreset.all.contains(where: { $0.bytes == defaultSpeed }) {
                    Text(SpeedPreset.text(defaultSpeed)).tag(defaultSpeed)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
        .cardRow(row(missing ? 3 : 2), separatorInset: TileSize.row + 10)
        SettingRow(.queues, title: "When finished") {
            Picker("When finished", selection: $defaultFinish) {
                ForEach(Self.finishChoices, id: \.rawValue) { Label($0.title, systemImage: $0.symbol).tag($0.rawValue) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
        .cardRow(row(missing ? 4 : 3), separatorInset: TileSize.row + 10)
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
