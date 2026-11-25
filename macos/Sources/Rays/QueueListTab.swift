import SwiftUI

/// Every queue, Main first: state, schedule summary and counts, with the enabled switch. A click opens the queue.
struct QueueListTab: View {
    let drafts: QueueDrafts
    let open: (UInt64) -> Void
    @Environment(EngineModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var deleting: QueueView?

    var body: some View {
        List {
            ForEach(model.sortedQueues) { queue in
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
        .animation(reduceMotion ? nil : .smooth, value: model.sortedQueues.map(\.id))
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
}

private struct QueueRow: View {
    let queue: QueueView
    let isDirty: Bool
    let onDelete: () -> Void
    @Environment(EngineModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    private var tint: Color { queue.badge?.tint ?? .secondary }

    var body: some View {
        HStack(spacing: LayoutMetrics.gap) {
            Image(systemName: queue.config.schedule == nil ? "list.bullet" : "clock")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: LayoutMetrics.iconSize, height: LayoutMetrics.iconSize)
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
                Text(queue.statusLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let badge = queue.badge { QueueBadgePill(badge: badge) }
            startStopButton
            moreMenu
            Toggle("Enabled", isOn: Binding(get: { queue.config.enabled }, set: { model.setQueueEnabled(queue, $0) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .help("Enabled")
        }
        .frame(height: LayoutMetrics.rowHeight)
        .padding(.horizontal, LayoutMetrics.hoverInset)
        .listRowBackground(RowHighlight(selected: false, hovered: isHovered))
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .smooth(duration: 0.15), value: isHovered)
        .contextMenu { actions }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(queue.config.name), \(queue.statusLine)")
    }

    private var startStopButton: some View {
        Button {
            if queue.isStopped { model.startQueue(queue.id) } else { model.stopQueue(queue.id) }
        } label: {
            Image(systemName: queue.isStopped ? "play.circle" : "stop.circle")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: LayoutMetrics.rowHitArea, height: LayoutMetrics.rowHitArea)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(isHovered ? 1 : 0)
        .help(queue.isStopped ? "Start queue" : "Stop queue")
        .accessibilityLabel(queue.isStopped ? "Start queue" : "Stop queue")
    }

    private var moreMenu: some View {
        Menu { actions } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: LayoutMetrics.rowHitArea, height: LayoutMetrics.rowHitArea)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
        .accessibilityLabel("More actions for \(queue.config.name)")
    }

    @ViewBuilder private var actions: some View {
        Button("Run now") { model.runQueueNow(queue.id) }
            .disabled(isDirty)
        Button(queue.isStopped ? "Start queue" : "Stop queue") {
            if queue.isStopped { model.startQueue(queue.id) } else { model.stopQueue(queue.id) }
        }
        if !queue.isMain {
            Divider()
            Button("Delete queue…", role: .destructive, action: onDelete)
        }
    }
}
