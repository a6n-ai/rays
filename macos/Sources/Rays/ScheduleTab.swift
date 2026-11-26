import SwiftUI

/// Repeat, start and stop times, and the conditions, with the queue's next run on top.
struct ScheduleTab: View {
    @Binding var draft: QueueConfig
    let queue: QueueView
    let isDirty: Bool
    @Environment(EngineModel.self) private var model
    @State private var wakeInstalled = false

    private var kind: RepeatKind { RepeatKind(draft.schedule) }

    private var schedule: Binding<QueueSchedule> {
        Binding(get: { draft.schedule ?? SchedulerTime.schedule(for: .daily, keeping: nil)! }, set: { draft.schedule = $0 })
    }

    private var pillText: String {
        if isDirty { return "Save to update" }
        guard draft.schedule != nil, draft.enabled else { return "Not scheduled" }
        return queue.nextRun.map { "Next run " + SchedulerTime.nextRunText($0) } ?? "No upcoming run"
    }

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: LayoutMetrics.gap) {
            formRow("Next run") {
                GlassEffectContainer {
                    Label(pillText, systemImage: "clock")
                        .font(.callout)
                        .monospacedDigit()
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .glassEffect(.regular, in: Capsule())
                }
            }
            formRow("Repeat") {
                Picker("Repeat", selection: Binding(get: { kind }, set: setKind)) {
                    ForEach(RepeatKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
                .labelsHidden()
                repeatDetail
                if kind == .none { formNote("Runs only when you start it. Pick a repeat to run it at set times.") }
            }
            if draft.schedule != nil {
                if model.isBestTimeQueue(queue) {
                    formRow("Best time") {
                        Toggle("Follow best time", isOn: Binding(get: { queue.config.followBestTime }, set: setFollow))
                            .toggleStyle(.switch)
                        formNote("Rays moves this schedule to your fastest hours once a day")
                        if queue.config.followBestTime, model.bestTime?.hasWindow == false {
                            formNote("Default night window until Rays has 7 days of speed data")
                        }
                    }
                }
                formRow("Start at") {
                    DatePicker("Start at", selection: Binding(get: { SchedulerTime.clock(schedule.wrappedValue.startMin) },
                                                              set: { schedule.wrappedValue.startMin = SchedulerTime.minutes($0) }),
                               displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .fixedSize()
                    Button { useBestTime() } label: { Label("Use best time", systemImage: "sparkles") }
                        .disabled(!(model.bestTime?.hasWindow ?? false))
                        .help(model.bestTime?.hasWindow == true ? "Fill in the fastest hours" : "Not enough speed data yet")
                    if !(draft.wake && wakeInstalled) {
                        formNote("Rays starts this queue at \(SchedulerTime.hhmm(schedule.wrappedValue.startMin)) if your Mac is awake and Rays is running.")
                    }
                }
                formRow("Stop at") {
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
                    formNote("Unfinished files pause and continue next time")
                }
                formRow("Only when") {
                    Toggle("Only on Wi-Fi (not a phone hotspot)", isOn: schedule.wifi)
                    Toggle("Only while charging", isOn: schedule.power)
                    Toggle("Only when the Mac is idle", isOn: schedule.idle)
                }
            }
        }
        .toggleStyle(.checkbox)
        .formColumn()
        .task { wakeInstalled = await WakePermission.status().installed }
    }

    private func useBestTime() {
        guard case .window(let start, let end, _, _, _)? = model.bestTime else { return }
        schedule.wrappedValue.startMin = start
        schedule.wrappedValue.stopMin = end
    }

    private func setFollow(_ on: Bool) {
        var config = queue.config
        config.followBestTime = on
        do { _ = try model.saveQueue(config) } catch { model.queueFailed("change the queue", error) }
    }

    private func setKind(_ new: RepeatKind) {
        draft.schedule = SchedulerTime.schedule(for: new, keeping: draft.schedule)
        if new == .none { draft.wake = false }
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
}
