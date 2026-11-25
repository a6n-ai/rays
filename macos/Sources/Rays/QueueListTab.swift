import SwiftUI

/// Every queue, Main first: state, schedule summary and counts, with the enabled switch. A click opens the queue.
struct QueueListTab: View {
    let drafts: QueueDrafts
    let open: (UInt64) -> Void
    @Environment(EngineModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var deleting: QueueView?
    @State private var status = "All"
    @State private var sort = ListSort.newest
    @State private var page = 0
    @State private var kind = FileKind.all

    private var shown: [QueueView] { model.queues.listed(status: status, sort: sort) }

    var body: some View {
        VStack(spacing: 0) {
            ListControls(statuses: QueueFilter.queues, status: $status, kind: $kind, showsKind: false,
                         sorts: [.name, .newest, .nextRun], sort: $sort, count: 0, page: $page)
            if shown.isEmpty { EmptyState(symbol: "tray", title: "No queues match") } else { list }
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
            Text("Its downloads move to Main.")
        }
    }

    private var list: some View {
        List {
            ForEach(shown) { queue in
                QueueRow(queue: queue, isDirty: drafts.isDirty(queue.id), onDelete: { deleting = queue })
                    .contentShape(Rectangle())
                    .onTapGesture { open(queue.id) }
                    .listRowInsets(EdgeInsets(
                        top: LayoutMetrics.rowSpacing / 2,
                        leading: LayoutMetrics.margin - LayoutMetrics.hoverInset,
                        bottom: LayoutMetrics.rowSpacing / 2,
                        trailing: LayoutMetrics.margin - LayoutMetrics.hoverInset))
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.inset)
        .tint(.gray)
        .scrollContentBackground(.hidden)
        .scrollEdgeEffectStyle(.soft, for: .all)
        .animation(reduceMotion ? nil : .smooth, value: shown.map(\.id))
    }
}

struct QueueRow: View {
    let queue: QueueView
    let isDirty: Bool
    /// Replaces the status line, e.g. Schedules shows the next run beside the row instead.
    var trailing: AnyView?
    var parts: [QueueStatusPart]?
    let onDelete: (() -> Void)?
    @Environment(EngineModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    init(queue: QueueView, isDirty: Bool, parts: [QueueStatusPart]? = nil, trailing: AnyView? = nil, onDelete: (() -> Void)? = nil) {
        self.queue = queue
        self.isDirty = isDirty
        self.parts = parts
        self.trailing = trailing
        self.onDelete = onDelete
    }

    var body: some View {
        HStack(spacing: LayoutMetrics.gap) {
            QueueTile(queue: queue)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(queue.config.name)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if queue.isMain {
                        Text("Default")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                    if isDirty {
                        Circle().fill(.secondary).frame(width: 6, height: 6).accessibilityLabel("Unsaved changes")
                    }
                }
                QueueStatusText(parts: parts ?? queue.statusParts())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let trailing { trailing }
            if let badge = queue.badge, queue.state != .open { QueueBadgePill(badge: badge) }
            if onDelete != nil { moreMenu }
            Toggle("Enabled", isOn: Binding(get: { queue.config.enabled }, set: { model.setQueueEnabled(queue, $0) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .tint(.accentColor)
                .help("Enabled")
            if onDelete != nil { primaryButton }
        }
        .frame(height: LayoutMetrics.rowHeight)
        .padding(.horizontal, LayoutMetrics.hoverInset)
        .listRowBackground(RowHighlight(selected: false, hovered: isHovered))
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .smooth(duration: 0.15), value: isHovered)
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
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(primary.tint)
                .offset(x: primary == .stop ? 0 : 1)
                .frame(width: LayoutMetrics.rowAction, height: LayoutMetrics.rowAction)
                .glassEffect(.regular.interactive(), in: .circle)
                .frame(width: LayoutMetrics.rowHitArea, height: LayoutMetrics.rowHitArea)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(primary == .run && isDirty)
        .help("\(primary.title) \(queue.config.name)")
        .accessibilityLabel("\(primary.title) \(queue.config.name)")
    }

    private var moreMenu: some View {
        Menu { actions } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: LayoutMetrics.rowHitArea, height: LayoutMetrics.rowHitArea)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .opacity(isHovered ? 1 : 0)
        .allowsHitTesting(isHovered)
        .help("More")
        .accessibilityLabel("More actions for \(queue.config.name)")
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
