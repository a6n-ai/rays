import SwiftUI

/// Unsaved queue edits, kept per queue so leaving a page loses nothing. A draft exists only while it differs from the saved config.
@Observable @MainActor final class QueueDrafts {
    /// `base` is the saved config the edits started from, so a change made elsewhere can be told apart from the user's own.
    struct Draft { var base: QueueConfig; var config: QueueConfig }
    var items: [UInt64: Draft] = [:]
    func isDirty(_ id: UInt64) -> Bool { items[id] != nil }

    /// Rebases each draft onto the queue's newest saved config, keeping only the fields the user changed; drops it once nothing differs.
    func reconcile(_ queues: [QueueView]) {
        for (id, draft) in items {
            guard let saved = queues.first(where: { $0.id == id })?.config else { items[id] = nil; continue }
            guard draft.base != saved else { continue }
            var merged = saved
            if draft.config.name != draft.base.name { merged.name = draft.config.name }
            if draft.config.maxRunning != draft.base.maxRunning { merged.maxRunning = draft.config.maxRunning }
            if draft.config.speedLimit != draft.base.speedLimit { merged.speedLimit = draft.config.speedLimit }
            if draft.config.enabled != draft.base.enabled { merged.enabled = draft.config.enabled }
            if draft.config.schedule != draft.base.schedule { merged.schedule = draft.config.schedule }
            if draft.config.retryFailed != draft.base.retryFailed { merged.retryFailed = draft.config.retryFailed }
            if draft.config.wake != draft.base.wake { merged.wake = draft.config.wake }
            if draft.config.whenFinished != draft.base.whenFinished { merged.whenFinished = draft.config.whenFinished }
            items[id] = merged == saved ? nil : Draft(base: saved, config: merged)
        }
    }
}

enum QueueSection: String, CaseIterable {
    case downloads, schedule, options
    var title: String { rawValue.capitalized }
}

/// One queue's detail, pushed from the Queues list: the header, a segmented Picker, then Downloads, Schedule or Options,
/// with a floating save bar while the draft is unsaved. The toolbar belongs to QueuesPage.
struct QueuePage: View {
    let queueId: UInt64
    let isDropTargeted: Bool
    let drafts: QueueDrafts
    let onDeleted: () -> Void
    @Environment(EngineModel.self) private var model
    @AppStorage("queueSection") private var section = QueueSection.downloads
    @State private var saveError: String?

    private var queue: QueueView? { model.queues.first { $0.id == queueId } }

    var body: some View {
        if let queue {
            let draft = binding(queue)
            let dirty = drafts.isDirty(queueId)
            let problem = draft.wrappedValue.problem
            VStack(spacing: 0) {
                QueueHeader(queue: queue, items: model.jobs.filter { $0.queueId == queueId }.count, draft: draft,
                            showsRunNow: section == .downloads, isDirty: dirty)
                Picker("Section", selection: $section) {
                    ForEach(QueueSection.allCases, id: \.self) { Text($0.title) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 320)
                .padding(.horizontal, LayoutMetrics.margin)
                .padding(.bottom, 10)
                switch section {
                case .downloads:
                    DownloadsView(isDropTargeted: isDropTargeted, queue: queueId)
                case .schedule:
                    ScheduleTab(draft: draft, queue: queue, isDirty: dirty)
                case .options:
                    OptionsTab(draft: draft, queueId: queueId, onDelete: { delete() })
                }
            }
            .safeAreaInset(edge: .bottom) {
                if dirty || problem != nil { saveBar(queue, problem: problem) }
            }
            .navigationTitle(queue.config.name)
        } else {
            EmptyState(symbol: "clock", title: "This queue no longer exists")
        }
    }

    private func binding(_ queue: QueueView) -> Binding<QueueConfig> {
        Binding(get: { drafts.items[queueId]?.config ?? queue.config },
                set: { new in
                    saveError = nil
                    drafts.items[queueId] = new == queue.config ? nil : QueueDrafts.Draft(base: drafts.items[queueId]?.base ?? queue.config, config: new)
                })
    }

    private func saveBar(_ queue: QueueView, problem: String?) -> some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: LayoutMetrics.gap) {
                if let message = saveError ?? problem {
                    Text(message).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Revert") { saveError = nil; drafts.items[queueId] = nil }
                    .buttonStyle(.plain)
                    .frame(minHeight: 28)
                Button("Save schedule", action: save)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil)
            }
            .padding(.horizontal, LayoutMetrics.gap)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
        }
        .padding(.horizontal, LayoutMetrics.margin)
        .padding(.bottom, LayoutMetrics.gap)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
    }

    private func save() {
        guard let draft = drafts.items[queueId]?.config else { return }
        do {
            _ = try model.saveQueue(draft)
            saveError = nil
            drafts.items[queueId] = nil
        } catch {
            saveError = "Couldn't save the schedule: \(EngineModel.message(for: error))"
        }
    }

    private func delete() {
        do {
            try model.deleteQueue(queueId)
            drafts.items[queueId] = nil
            onDeleted()
        } catch {
            model.queueFailed("delete the queue", error)
        }
    }
}
