import SwiftUI

/// Unsaved queue edits, kept per queue so leaving a page loses nothing. A draft exists only while it differs from the saved config.
@Observable @MainActor final class QueueDrafts {
    var items: [UInt64: QueueConfig] = [:]
    func isDirty(_ id: UInt64) -> Bool { items[id] != nil }
}

enum QueueSection: String { case downloads, schedule, options }

/// One queue's page: header, then Downloads, Schedule or Options, with a floating save bar while the draft is unsaved.
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
                if section != .downloads && (dirty || problem != nil) { saveBar(queue, problem: problem) }
            }
            .toolbar { toolbar(queue) }
        } else {
            EmptyState(symbol: "clock", title: "This queue no longer exists")
        }
    }

    private func binding(_ queue: QueueView) -> Binding<QueueConfig> {
        Binding(get: { drafts.items[queueId] ?? queue.config },
                set: { new in
                    saveError = nil
                    drafts.items[queueId] = new == queue.config ? nil : new
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
        guard let draft = drafts.items[queueId] else { return }
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

    @ToolbarContentBuilder private func toolbar(_ queue: QueueView) -> some ToolbarContent {
        ToolbarItem(placement: .principal) {
            ToolbarIconGroup {
                ForEach([(QueueSection.downloads, "list.bullet", "Downloads"),
                         (QueueSection.schedule, "calendar.badge.clock", "Schedule"),
                         (QueueSection.options, "slider.horizontal.3", "Options")], id: \.0) { item in
                    Button { section = item.0 } label: {
                        ToolbarIcon(symbol: item.1, title: item.2, selected: section == item.0)
                    }
                    .buttonStyle(.plain)
                    .help(item.2)
                    .accessibilityAddTraits(section == item.0 ? .isSelected : [])
                }
            }
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .primaryAction) {
            ToolbarIconGroup {
                Button {
                    if queue.isStopped { model.startQueue(queue.id) } else { model.stopQueue(queue.id) }
                } label: {
                    ToolbarIcon(symbol: queue.isStopped ? "play.circle" : "stop.circle",
                                title: queue.isStopped ? "Start queue" : "Stop queue")
                }
                .buttonStyle(.plain)
                .help(queue.isStopped ? "Start queue" : "Stop queue")
            }
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .primaryAction) { SettingsToolbarButton() }
    }
}
