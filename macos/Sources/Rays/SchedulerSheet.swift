import SwiftUI

/// Presented from ContentView for one queue; the list on the left switches between queues.
struct SchedulerSheet: View {
    let queueId: UInt64
    @Environment(EngineModel.self) private var model

    var body: some View {
        if let initial = model.sortedQueues.first(where: { $0.id == queueId }) ?? model.sortedQueues.first {
            SchedulerPane(initial: initial)
        } else {
            EmptyState(symbol: "clock", title: "No queues").frame(width: 760, height: 560)
        }
    }
}

private struct SchedulerPane: View {
    @Environment(EngineModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selected: UInt64
    @State private var draft: QueueConfig
    @State private var pending: Pending?
    @State private var saveError: String?

    private enum Pending { case select(UInt64), newQueue, close }

    init(initial: QueueView) {
        _selected = State(initialValue: initial.id)
        _draft = State(initialValue: initial.config)
    }

    private var saved: QueueView? { model.queues.first { $0.id == selected } }
    private var isDirty: Bool { saved.map { draft != $0.config } ?? false }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 200)
            Divider()
            if let saved {
                SchedulerEditor(draft: $draft, queue: saved, isDirty: isDirty, saveError: saveError,
                                onSave: { _ = save() },
                                onRevert: { draft = saved.config; saveError = nil },
                                onDelete: delete,
                                onClose: { request(.close) })
                    .id(selected)
            } else {
                EmptyState(symbol: "clock", title: "This queue no longer exists")
            }
        }
        .frame(minWidth: 760, minHeight: 560)
        .interactiveDismissDisabled()
        .confirmationDialog("Save changes to \(draft.name)?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible) {
            Button("Save") { if let next = pending, save() { perform(next) } }
            Button("Don't Save", role: .destructive) { if let next = pending { perform(next) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: Binding<UInt64?>(get: { selected }, set: { if let id = $0, id != selected { request(.select(id)) } })) {
                ForEach(model.sortedQueues) { queue in
                    QueueListRow(queue: queue, selected: queue.id == selected).tag(queue.id)
                }
            }
            .listStyle(.plain)
            .tint(.gray)
            .scrollContentBackground(.hidden)
            Divider()
            Button { request(.newQueue) } label: { Label("New queue", systemImage: "plus") }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .padding(.horizontal, LayoutMetrics.gap)
        }
    }

    private func request(_ next: Pending) {
        if isDirty { pending = next } else { perform(next) }
    }

    private func perform(_ next: Pending) {
        switch next {
        case .select(let id): select(id)
        case .newQueue: if let id = model.newQueue() { select(id) }
        case .close: dismiss()
        }
    }

    private func select(_ id: UInt64) {
        guard let queue = model.queues.first(where: { $0.id == id }) else { return }
        selected = id
        draft = queue.config
        saveError = nil
    }

    private func save() -> Bool {
        do {
            let id = try model.saveQueue(draft)
            saveError = nil
            if let config = model.queues.first(where: { $0.id == id })?.config { draft = config }
            return true
        } catch {
            saveError = "Couldn't save the schedule: \(EngineModel.message(for: error))"
            return false
        }
    }

    private func delete() {
        do {
            try model.deleteQueue(selected)
            select(1)
        } catch {
            model.queueFailed("delete the queue", error)
        }
    }
}

private struct QueueListRow: View {
    let queue: QueueView
    let selected: Bool
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(queue.config.name).font(.body).lineLimit(1)
            Text(SchedulerTime.summary(queue))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .listRowBackground(RowHighlight(selected: selected, hovered: hovered))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
