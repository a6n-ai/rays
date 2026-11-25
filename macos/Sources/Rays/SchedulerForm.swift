import SwiftUI

/// The Schedule tab: a two-column grid with a 110pt label column.
struct SchedulerForm: View {
    @Binding var draft: QueueConfig
    @Environment(EngineModel.self) private var model
    @AppStorage(SettingsKey.maxRunning) private var cap = 3
    @State private var wakeInstalled = false
    @State private var wakeMissing = false

    private var kind: RepeatKind { RepeatKind(draft.schedule) }

    private var schedule: Binding<QueueSchedule> {
        Binding(get: { draft.schedule ?? SchedulerTime.schedule(for: .daily, keeping: nil)! },
                set: { draft.schedule = $0 })
    }

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: LayoutMetrics.gap) {
            row("Repeat") {
                Picker("Repeat", selection: Binding(get: { kind },
                                                    set: { draft.schedule = SchedulerTime.schedule(for: $0, keeping: draft.schedule) })) {
                    ForEach(RepeatKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                repeatDetail
                if kind == .none { note("Runs only when you start it. Pick a repeat to run it at set times.") }
            }
            if draft.schedule != nil { timing }
            row("Simultaneous") {
                Stepper(value: Binding(get: { Int(min(draft.maxRunning, UInt32(cap))) }, set: { draft.maxRunning = UInt32($0) }),
                        in: 0...max(cap, 1)) {
                    Text(draft.maxRunning == 0 ? "Same as Rays" : "\(draft.maxRunning) download\(draft.maxRunning == 1 ? "" : "s") at a time")
                        .monospacedDigit()
                }
            }
            row("Speed limit") {
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
            if draft.schedule != nil {
                row("Only when") {
                    Toggle("Only on Wi-Fi (not a phone hotspot)", isOn: schedule.wifi)
                    Toggle("Only while charging", isOn: schedule.power)
                    Toggle("Only when the Mac is idle", isOn: schedule.idle)
                }
            }
            row("Options") {
                Toggle("Retry failed downloads", isOn: $draft.retryFailed)
                if draft.schedule != nil { wake }
            }
            row("When finished") { FinishActionGrid(action: $draft.whenFinished) }
        }
        .toggleStyle(.checkbox)
        .task { await refreshWake() }
    }

    @ViewBuilder private var repeatDetail: some View {
        switch draft.schedule?.repeat {
        case .once(let date)?:
            DatePicker("Date", selection: Binding(get: { SchedulerTime.date(date) ?? Date() },
                                                  set: { schedule.wrappedValue.repeat = .once(date: SchedulerTime.text($0)) }),
                       displayedComponents: .date)
                .labelsHidden()
                .fixedSize()
        case .days(let mask)?:
            DayPills(mask: Binding(get: { mask }, set: { schedule.wrappedValue.repeat = .days(mask: $0) }))
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var timing: some View {
        row("Start at") {
            DatePicker("Start at", selection: Binding(get: { SchedulerTime.clock(schedule.wrappedValue.startMin) },
                                                      set: { schedule.wrappedValue.startMin = SchedulerTime.minutes($0) }),
                       displayedComponents: .hourAndMinute)
                .labelsHidden()
                .fixedSize()
            if !(draft.wake && wakeInstalled) {
                note("Rays starts this queue at \(SchedulerTime.hhmm(schedule.wrappedValue.startMin)) if your Mac is awake and Rays is running.")
            }
        }
        row("Stop at") {
            HStack(spacing: 8) {
                Toggle("Stop at", isOn: Binding(get: { schedule.wrappedValue.stopMin != nil },
                                                set: { schedule.wrappedValue.stopMin = $0 ? (schedule.wrappedValue.startMin + 300) % 1440 : nil }))
                    .labelsHidden()
                DatePicker("Stop at", selection: Binding(get: { SchedulerTime.clock(schedule.wrappedValue.stopMin ?? 0) },
                                                         set: { schedule.wrappedValue.stopMin = SchedulerTime.minutes($0) }),
                           displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .fixedSize()
                    .disabled(schedule.wrappedValue.stopMin == nil)
            }
            note("Unfinished files pause and continue next time")
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

    private func row(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)
            VStack(alignment: .leading, spacing: 8) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
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
        wakeInstalled = await Task.detached { WakePermission.isInstalled }.value
        wakeMissing = WakePermission.isMissingForWakeQueues
    }
}
