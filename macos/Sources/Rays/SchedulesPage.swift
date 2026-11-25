import SwiftUI

/// Every queue by schedule: what starts next, what is paused, and what has no schedule. A click opens the queue on Schedule.
struct SchedulesPage: View {
    let isDropTargeted: Bool
    let drafts: QueueDrafts
    @Environment(EngineModel.self) private var model
    @AppStorage("queueSection") private var queueSection = QueueSection.downloads
    @State private var selected: UInt64?

    private var upcoming: [QueueView] {
        model.queues.filter { $0.config.schedule != nil && $0.config.enabled }.sorted { ($0.nextRun ?? .max) < ($1.nextRun ?? .max) }
    }
    private var paused: [QueueView] { model.sortedQueues.filter { $0.config.schedule != nil && !$0.config.enabled } }
    private var unscheduled: [QueueView] { model.sortedQueues.filter { $0.config.schedule == nil } }

    var body: some View {
        NavigationStack {
            Group {
                if upcoming.isEmpty && paused.isEmpty {
                    VStack(spacing: 0) {
                        EmptyState(symbol: "calendar.badge.clock", title: "Nothing scheduled",
                                   message: "Give a queue a schedule to start downloads at set times.")
                        Button("New schedule", action: newSchedule)
                            .buttonStyle(.glass)
                            .padding(.bottom, 80)
                    }
                } else {
                    list
                }
            }
            .navigationTitle("Schedules")
            .toolbar { if selected == nil { toolbar } }
            .navigationDestination(item: $selected) { id in
                QueuePage(queueId: id, isDropTargeted: isDropTargeted, drafts: drafts, onDeleted: { selected = nil })
                    .toolbar { toolbar }
            }
        }
    }

    private var list: some View {
        List {
            if !upcoming.isEmpty {
                Section { ForEach(upcoming) { scheduled($0) } } header: { header("Upcoming") }
            }
            if !paused.isEmpty {
                Section { ForEach(paused) { scheduled($0) } } header: { header("Paused") }
            }
            if !unscheduled.isEmpty {
                Section {
                    ForEach(unscheduled) { queue in
                        HStack(spacing: LayoutMetrics.gap) {
                            QueueTile(queue: queue, size: 24).opacity(0.6)
                            Text(queue.config.name).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            Button("Add schedule") { open(queue.id) }
                                .buttonStyle(.glass)
                                .controlSize(.small)
                        }
                        .frame(minHeight: LayoutMetrics.rowAction)
                        .padding(.horizontal, LayoutMetrics.hoverInset)
                        .rowInsets()
                    }
                } header: { header("Not scheduled") }
            }
        }
        .listStyle(.inset)
        .tint(.gray)
        .scrollContentBackground(.hidden)
        .scrollEdgeEffectStyle(.soft, for: .all)
    }

    private func header(_ title: String) -> some View {
        Text(title).font(.headline).foregroundStyle(.primary).padding(.leading, LayoutMetrics.hoverInset)
    }

    private func scheduled(_ queue: QueueView) -> some View {
        QueueRow(queue: queue, isDirty: drafts.isDirty(queue.id), parts: Array(queue.statusParts(withNext: false).prefix(2).filter { $0.symbol != "arrow.down.circle" }),
                 trailing: AnyView(nextRun(queue)))
            .contentShape(Rectangle())
            .onTapGesture { open(queue.id) }
            .rowInsets()
    }

    @ViewBuilder private func nextRun(_ queue: QueueView) -> some View {
        if queue.config.enabled, let next = queue.nextRun {
            let date = Date(timeIntervalSince1970: TimeInterval(next))
            HStack(spacing: 4) {
                Text("next " + SchedulerTime.nextRunText(next) + " ·")
                TimelineView(.periodic(from: .now, by: 60)) { _ in
                    Text(date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
        }
    }

    private func open(_ id: UInt64) {
        queueSection = .schedule
        selected = id
    }

    private func newSchedule() {
        if let id = model.newQueue(schedule: SchedulerTime.schedule(for: .daily, keeping: nil)) { open(id) }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            ToolbarIconGroup {
                Button(action: newSchedule) { ToolbarIcon(symbol: "plus", title: "New schedule") }
                    .buttonStyle(.plain)
                    .help("New schedule")
            }
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .primaryAction) { SettingsToolbarButton() }
    }
}

private extension View {
    func rowInsets() -> some View {
        listRowInsets(EdgeInsets(top: LayoutMetrics.rowSpacing / 2, leading: LayoutMetrics.margin - LayoutMetrics.hoverInset,
                                 bottom: LayoutMetrics.rowSpacing / 2, trailing: LayoutMetrics.margin - LayoutMetrics.hoverInset))
            .listRowSeparator(.hidden)
    }
}
