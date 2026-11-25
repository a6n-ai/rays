import SwiftUI

/// Every queue by schedule: what starts next, what is paused, and what has no schedule. A click opens the queue on Schedule.
struct SchedulesPage: View {
    let isDropTargeted: Bool
    let drafts: QueueDrafts
    @Environment(EngineModel.self) private var model
    @AppStorage("queueSection") private var queueSection = QueueSection.downloads
    @State private var selected: UInt64?
    @State private var status = "All"
    @State private var sort = ListSort.nextRun
    @State private var page = 0
    @State private var naming = false
    @State private var newName = SchedulesPage.defaultName
    @State private var kind = FileKind.all

    private var shown: [QueueView] { model.queues.listed(status: status, sort: sort, pinMain: false) }
    private var upcoming: [QueueView] { shown.filter { $0.config.schedule != nil && $0.config.enabled } }
    private var paused: [QueueView] { shown.filter { $0.config.schedule != nil && !$0.config.enabled } }
    private var unscheduled: [QueueView] { shown.filter { $0.config.schedule == nil } }
    private var nothingScheduled: Bool { !model.queues.contains { $0.config.schedule != nil } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ListControls(statuses: QueueFilter.schedules, status: $status, kind: $kind, showsKind: false,
                             sorts: [.nextRun, .name], sort: $sort, count: 0, page: $page)
                if shown.isEmpty { EmptyState(symbol: "tray", title: "No schedules match") } else { list }
            }
            .navigationTitle("Schedules")
            .alert("New queue with a schedule", isPresented: $naming) {
                TextField("Name", text: $newName)
                Button("Create", action: createScheduled)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel", role: .cancel) { newName = Self.defaultName }
            } message: {
                Text("It runs every day at \(SchedulerTime.hhmm(SchedulerTime.defaultStart)).")
            }
            .toolbar { if selected == nil { toolbar } }
            .navigationDestination(item: $selected) { id in
                QueuePage(queueId: id, isDropTargeted: isDropTargeted, drafts: drafts, onDeleted: { selected = nil })
                    .toolbar { toolbar }
            }
        }
    }

    private var list: some View {
        List {
            if nothingScheduled {
                // The toolbar's + and each queue's calendar button add one, so no button of its own here.
                HStack(spacing: LayoutMetrics.gap) {
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                    Text("Nothing scheduled yet. Add a schedule to a queue below, or use + in the toolbar.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(minHeight: LayoutMetrics.rowAction)
                .padding(.horizontal, LayoutMetrics.hoverInset)
                .rowInsets()
            }
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
                            Button { addSchedule(to: queue) } label: {
                                Image(systemName: "calendar.badge.plus")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.tint)
                                    .frame(width: LayoutMetrics.rowAction, height: LayoutMetrics.rowAction)
                                    .glassEffect(.regular.interactive(), in: .circle)
                                    .frame(width: LayoutMetrics.rowHitArea, height: LayoutMetrics.rowHitArea)
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .help("Add schedule to \(queue.config.name)")
                            .accessibilityLabel("Add schedule to \(queue.config.name)")
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
        QueueRow(queue: queue, isDirty: drafts.isDirty(queue.id), parts: queue.statusParts(withNext: false, withDownloads: false),
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

    private var dailySchedule: QueueSchedule? { SchedulerTime.schedule(for: .daily, keeping: nil) }

    /// Opens the queue on Schedule with a daily draft; nothing is saved until Save.
    private func addSchedule(to queue: QueueView) {
        // An unsaved draft is kept; it only gains the daily schedule when it has none.
        var draft = drafts.items[queue.id] ?? QueueDrafts.Draft(base: queue.config, config: queue.config)
        if draft.config.schedule == nil {
            draft.config.schedule = dailySchedule
            drafts.items[queue.id] = draft
        }
        open(queue.id)
    }

    fileprivate static let defaultName = "Night downloads"

    private func createScheduled() {
        defer { newName = Self.defaultName }
        if let id = model.newQueue(name: newName.trimmingCharacters(in: .whitespaces), schedule: dailySchedule) { open(id) }
    }

    @ViewBuilder private var addMenu: some View {
        let free = model.sortedQueues.filter { $0.config.schedule == nil }
        if !free.isEmpty {
            Section("Add schedule to…") {
                ForEach(free) { queue in
                    Button { addSchedule(to: queue) } label: {
                        Label(queue.config.name, systemImage: QueueAppearances.shared.appearance(for: queue).symbol)
                    }
                }
            }
            Divider()
        }
        Button("New queue with a schedule…") { naming = true }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            ToolbarIconGroup {
                Menu { addMenu } label: { ToolbarIcon(symbol: "plus", title: "New schedule") }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
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
