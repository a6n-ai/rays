import SwiftUI

/// Every queue by schedule: what starts next, what is paused, and what has no schedule. A click opens the queue on Schedule.
struct SchedulesPage: View {
    let isDropTargeted: Bool
    let drafts: QueueDrafts
    @Environment(EngineModel.self) private var model
    @Environment(NavHistory.self) private var nav
    @AppStorage("queueSection") private var queueSection = QueueSection.downloads
    @State private var status = "All"
    @State private var sort = ListSort.nextRun
    @State private var page = 0
    @State private var naming = false
    @State private var newName = SchedulesPage.defaultName
    @State private var kind = FileKind.all
    @AppStorage(Paging.key) private var pageSize = Paging.defaultSize

    private var shown: [QueueView] { model.queues.listed(status: status, sort: sort, pinMain: false) }
    private var pageOfQueues: [QueueView] { Array(ListControls.page(shown, page, pageSize)) }
    private var upcoming: [QueueView] { pageOfQueues.filter { $0.config.schedule != nil && $0.config.enabled } }
    private var paused: [QueueView] { pageOfQueues.filter { $0.config.schedule != nil && !$0.config.enabled } }
    private var unscheduled: [QueueView] { pageOfQueues.filter { $0.config.schedule == nil } }
    private var nothingScheduled: Bool { !model.queues.contains { $0.config.schedule != nil } }

    var body: some View {
        Group {
            if let id = openQueue {
                QueuePage(queueId: id, isDropTargeted: isDropTargeted, drafts: drafts, onDeleted: { nav.replaceSub(nil) })
            } else {
                list
                    .safeAreaInset(edge: .top, spacing: 0) { controls(.paging) }
                    .navigationTitle("Schedules")
            }
        }
        .alert("New queue with a schedule", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Create", action: createScheduled)
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) { newName = Self.defaultName }
        } message: {
            Text("It runs every day at \(SchedulerTime.hhmm(SchedulerTime.defaultStart)).")
        }
    }

    private var openQueue: UInt64? {
        guard let sub = nav.sub, sub.hasPrefix("queue:") else { return nil }
        return UInt64(sub.dropFirst("queue:".count))
    }

    private func controls(_ part: ListControls.Part) -> some View {
        ListControls(statuses: QueueFilter.schedules, status: $status, kind: $kind, showsKind: false,
                     sorts: [.nextRun, .name], sort: $sort, count: shown.count, page: $page, part: part)
    }

    private var heroSubtitle: String {
        nothingScheduled
            ? "Nothing scheduled yet. Use New Schedule."
            : "Start queues at set times, on Wi-Fi, power or when idle."
    }

    private var list: some View {
        List {
            Section {
                HeroCard(.schedules, title: "Schedules", subtitle: heroSubtitle,
                         learnMore: URL(string: "https://rays.a6n.ai/docs/app/queues#schedules")) {
                    HeroActions { Menu("New schedule") { addMenu } }
                }
                .cardRow(.only)
            }
            CollapsibleSettingsCard(page: "schedules", summary: "Wake permission") {
                WakePermissionRow().cardRow(.last, separatorInset: 0)
            }
            if shown.isEmpty {
                Section {
                    Text("No schedules match")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: LayoutMetrics.cardRowMinHeight)
                        .cardRow(.only)
                } header: { header("Schedules", controls: true) }
            }
            if !upcoming.isEmpty {
                Section { ForEach(Array(upcoming.enumerated()), id: \.element.id) { scheduled($1, $0, of: upcoming.count) } } header: { header("Upcoming", controls: true) }
            }
            if !paused.isEmpty {
                Section { ForEach(Array(paused.enumerated()), id: \.element.id) { scheduled($1, $0, of: paused.count) } } header: { header("Paused", controls: upcoming.isEmpty) }
            }
            if !unscheduled.isEmpty {
                Section {
                    ForEach(Array(unscheduled.enumerated()), id: \.element.id) { index, queue in
                        CardRow(title: queue.config.name, subtitle: "Not scheduled", status: .off) {
                            QueueTile(queue: queue, size: TileSize.list)
                        } trailing: {
                            Button { addSchedule(to: queue) } label: {
                                Image(systemName: "calendar.badge.plus")
                                    .font(.system(size: 15))
                                    .foregroundStyle(.secondary)
                                    .frame(width: LayoutMetrics.rowHitArea, height: LayoutMetrics.rowHitArea)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .help("Add schedule to \(queue.config.name)")
                            .accessibilityLabel("Add schedule to \(queue.config.name)")
                        }
                        .cardRow(CardRowBackground.position(index, of: unscheduled.count))
                    }
                } header: { header("Not scheduled", controls: upcoming.isEmpty && paused.isEmpty) }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .scrollEdgeEffectStyle(.soft, for: .all)
    }

    private func header(_ title: String, controls showControls: Bool) -> some View {
        HStack {
            Text(title).font(.headline).foregroundStyle(.primary).padding(.leading, LayoutMetrics.hoverInset)
            Spacer()
            if showControls { controls(.menus) }
        }
    }

    private func scheduled(_ queue: QueueView, _ index: Int, of count: Int) -> some View {
        QueueRow(queue: queue, position: CardRowBackground.position(index, of: count), isDirty: drafts.isDirty(queue.id),
                 parts: queue.statusParts(withNext: false, withDownloads: false), trailing: AnyView(nextRun(queue)))
            .contentShape(Rectangle())
            .onTapGesture { open(queue.id) }
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
        nav.open("queue:\(id)")
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
}
