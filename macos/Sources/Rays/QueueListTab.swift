import SwiftUI

/// Every queue, Main first: state, schedule summary and counts, with the enabled switch. A click opens the queue.
struct QueueListTab: View {
    let drafts: QueueDrafts
    let open: (UInt64) -> Void
    let newQueue: () -> Void
    @Environment(EngineModel.self) private var model
    @Environment(NavHistory.self) private var nav
    @State private var deleting: QueueView?
    @State private var status = "All"
    @State private var sort = ListSort.newest
    @State private var page = 0
    @State private var kind = FileKind.all
    @AppStorage(Paging.key) private var pageSize = Paging.defaultSize

    private var shown: [QueueView] { model.queues.listed(status: status, sort: sort) }

    var body: some View {
        VStack(spacing: 0) {
            ListControls(statuses: QueueFilter.queues, status: $status, kind: $kind, showsKind: false,
                         sorts: [.name, .newest, .nextRun], sort: $sort, count: shown.count, page: $page, part: .paging)
            list
        }
        .confirmationDialog(
            "Delete \(deleting?.config.name ?? "queue")?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete queue", role: .destructive) {
                if let id = deleting?.id {
                    do {
                        try model.deleteQueue(id)
                        drafts.items[id] = nil
                    } catch {
                        model.queueFailed("delete the queue", error)
                    }
                }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("Its downloads leave the queue and stay in Downloads.")
        }
    }

    private var list: some View {
        let queues = Array(ListControls.page(shown, page, pageSize))
        return List {
            Section {
                HeroCard(.queues, title: "Queues", subtitle: "Group downloads and start them together, now or on a schedule.",
                         learnMore: URL(string: "https://rays.a6n.ai/docs/app/queues")) {
                    HeroActions {
                        Button("New queue", action: newQueue)
                        HeroMenu {
                            Button("Start all queues", systemImage: "play.circle") { model.setAllQueues(running: true) }
                            Button("Stop all queues", systemImage: "stop.circle") { model.setAllQueues(running: false) }
                        }
                    }
                }
                .cardRow(.only)
            }
            CollapsibleSettingsCard(page: "queues", summary: "Defaults for new queues") { QueueSettingsTab() }
            Section {
                DrillInRow(tile: .history, title: "Activity", subtitle: "Running now and recent runs") { nav.open("activity") }
                    .cardRow(.only)
            }
            Section {
                if queues.isEmpty {
                    Text("No queues match")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: LayoutMetrics.cardRowMinHeight)
                        .cardRow(.only)
                }
                ForEach(Array(queues.enumerated()), id: \.element.id) { index, queue in
                    QueueRow(queue: queue, position: CardRowBackground.position(index, of: queues.count),
                             isDirty: drafts.isDirty(queue.id), onDelete: { deleting = queue })
                        .contentShape(Rectangle())
                        .onTapGesture { open(queue.id) }
                }
            } header: {
                HStack {
                    Text("Your queues").font(.headline).foregroundStyle(.primary)
                    Spacer()
                    ListControls(statuses: QueueFilter.queues, status: $status, kind: $kind, showsKind: false,
                                 sorts: [.name, .newest, .nextRun], sort: $sort, count: shown.count, page: $page, part: .menus)
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .scrollEdgeEffectStyle(.soft, for: .all)
    }
}

struct QueueRow: View {
    let queue: QueueView
    let position: CardRowBackground.Position
    let isDirty: Bool
    /// Replaces the status line, e.g. Schedules shows the next run beside the row instead.
    var trailing: AnyView?
    var parts: [QueueStatusPart]?
    let onDelete: (() -> Void)?
    @Environment(EngineModel.self) private var model
    @State private var isHovered = false

    init(queue: QueueView, position: CardRowBackground.Position, isDirty: Bool, parts: [QueueStatusPart]? = nil,
         trailing: AnyView? = nil, onDelete: (() -> Void)? = nil) {
        self.queue = queue
        self.position = position
        self.isDirty = isDirty
        self.parts = parts
        self.trailing = trailing
        self.onDelete = onDelete
    }

    private var statusKind: StatusDot.Kind {
        switch queue.state {
        case .open: queue.running > 0 || queue.config.schedule != nil ? .active : .off
        case .waitingForTime: .active
        case .waitingForCondition: .warning
        case .stopped, .off: .off
        }
    }

    var body: some View {
        CardRow(title: queue.config.name, subtitle: (parts ?? queue.statusParts()).map(\.text).joined(separator: " · "),
                status: statusKind) {
            QueueTile(queue: queue, size: TileSize.list)
        } trailing: {
            HStack(spacing: LayoutMetrics.gap) {
                if isDirty {
                    Circle().fill(.secondary).frame(width: 6, height: 6).accessibilityLabel("Unsaved changes")
                }
                if let trailing { trailing }
                if let badge = queue.badge, queue.state != .open { QueueBadgePill(badge: badge) }
                Toggle("Enabled", isOn: Binding(get: { queue.config.enabled }, set: { model.setQueueEnabled(queue, $0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .tint(.accentColor)
                    .help("Enabled")
                if onDelete != nil { primaryButton }
            }
        }
        .cardRow(position, hovered: isHovered)
        .onHover { isHovered = $0 }
        .contextMenu { if onDelete != nil { actions } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(queue.config.name), \(queue.statusLine)")
    }

    private enum Primary {
        case start, stop, run
        var symbol: String { self == .stop ? "stop.fill" : "play.fill" }
        var title: String { self == .start ? "Start queue" : self == .stop ? "Stop queue" : "Run now" }
        var tint: Color { self == .stop ? .red : .blue }
    }

    private var primary: Primary { queue.running > 0 ? .stop : queue.isStopped ? .start : .run }

    private func perform(_ action: Primary) {
        switch action {
        case .start: model.startQueue(queue.id)
        case .stop: model.stopQueue(queue.id)
        case .run: model.runQueueNow(queue.id)
        }
    }

    private var primaryButton: some View {
        Button { perform(primary) } label: {
            Image(systemName: primary.symbol)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: LayoutMetrics.rowHitArea, height: LayoutMetrics.rowHitArea)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(primary == .run && isDirty)
        .help("\(primary.title) \(queue.config.name)")
        .accessibilityLabel("\(primary.title) \(queue.config.name)")
    }

    @ViewBuilder private var actions: some View {
        Button("Run now") { model.runQueueNow(queue.id) }
            .disabled(isDirty)
        Button(queue.isStopped ? "Start queue" : "Stop queue") {
            if queue.isStopped { model.startQueue(queue.id) } else { model.stopQueue(queue.id) }
        }
        if !queue.isMain, let onDelete {
            Divider()
            Button("Delete queue…", role: .destructive, action: onDelete)
        }
    }
}
