import SwiftUI

/// What is running now, what starts next, and the last runs.
struct ActivityTab: View {
    let open: (UInt64) -> Void
    @Environment(EngineModel.self) private var model
    @State private var page = 0
    @AppStorage(Paging.key) private var pageSize = Paging.defaultSize

    private var running: [QueueView] { model.sortedQueues.filter { $0.state == .open && $0.running > 0 } }

    var body: some View {
        List {
            Section {
                if running.isEmpty {
                    note("No queue is running")
                }
                ForEach(running) { queue in
                    runningRow(queue)
                        .contentShape(Rectangle())
                        .onTapGesture { open(queue.id) }
                        .hoverHighlight()
                        .rowStyle()
                }
            } header: { header("Running now") }
            Section {
                if model.runs.isEmpty {
                    note("No runs yet")
                }
                ForEach(ListControls.page(model.runs, page, pageSize), id: \.id) { run in
                    historyRow(run).rowStyle()
                }
            } header: { header("History") }
        }
        .listStyle(.inset)
        .tint(.gray)
        .scrollContentBackground(.hidden)
        .scrollEdgeEffectStyle(.soft, for: .all)
        .safeAreaInset(edge: .bottom, spacing: 0) { PageBar(count: model.runs.count, page: $page, padded: true) }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.primary)
            .padding(.leading, LayoutMetrics.hoverInset)
    }

    private func note(_ text: String, @ViewBuilder action: () -> some View = { EmptyView() }) -> some View {
        HStack(spacing: LayoutMetrics.gap) {
            Text(text).foregroundStyle(.secondary)
            action()
        }
        .frame(minHeight: LayoutMetrics.rowAction)
        .padding(.horizontal, LayoutMetrics.hoverInset)
        .listRowSeparator(.hidden)
    }

    private func runningRow(_ queue: QueueView) -> some View {
        let run = model.openRun(queue.id)
        var detail = "\(queue.running) downloading"
        if let run { detail += " · " + countText(files: run.filesDone, bytes: run.bytesDone) + " this run" }
        return row(leading: QueueTile(queue: queue), title: queue.config.name, detail: detail) { EmptyView() }
    }

    private func historyRow(_ run: QueueRun) -> some View {
        let queue = model.queues.first { $0.id == run.queueId }
        let outcome = Outcome(run.outcome)
        return row(leading: historyTile(queue), title: queue?.config.name ?? "Deleted queue", detail: timeText(run)) {
            HStack(spacing: LayoutMetrics.gap) {
                Text(countText(files: run.filesDone, bytes: run.bytesDone))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Label(outcome.text, systemImage: outcome.symbol)
                    .font(.callout)
                    .foregroundStyle(outcome.tint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(outcome.tint.opacity(0.15), in: Capsule())
            }
        }
    }

    @ViewBuilder private func historyTile(_ queue: QueueView?) -> some View {
        if let queue { QueueTile(queue: queue) } else { ModelTile(symbol: "trash", color: .gray) }
    }

    private func row(leading: some View, title: String, detail: String, @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: LayoutMetrics.gap) {
            leading
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .frame(height: LayoutMetrics.rowHeight)
        .padding(.horizontal, LayoutMetrics.hoverInset)
        .accessibilityElement(children: .combine)
    }

    private func countText(files: UInt32, bytes: UInt64) -> String {
        "\(files) \(files == 1 ? "file" : "files") · \(byteText(bytes))"
    }

    /// "Mon 25 Nov, 02:00–07:30", or both dates when the run crossed midnight.
    private func timeText(_ run: QueueRun) -> String {
        let start = Date(timeIntervalSince1970: TimeInterval(run.startedAt))
        let day = Date.FormatStyle().weekday(.abbreviated).day().month(.abbreviated)
        let clock = Date.FormatStyle().hour().minute()
        let head = start.formatted(day) + ", " + start.formatted(clock)
        guard let ended = run.endedAt else { return "Started " + head }
        let end = Date(timeIntervalSince1970: TimeInterval(ended))
        if Calendar.current.isDate(start, inSameDayAs: end) { return head + "–" + end.formatted(clock) }
        return head + " – " + end.formatted(day) + ", " + end.formatted(clock)
    }
}

private struct Outcome {
    let symbol: String
    let text: String
    let tint: Color

    init(_ outcome: RunOutcome) {
        switch outcome {
        case .running: (symbol, text, tint) = ("arrow.down.circle", "Running", .blue)
        case .finished: (symbol, text, tint) = ("checkmark.circle", "Finished", .green)
        case .windowClosed: (symbol, text, tint) = ("clock", "Window ended", .orange)
        case .stoppedByUser: (symbol, text, tint) = ("stop.circle", "Stopped", .secondary)
        case .appQuit: (symbol, text, tint) = ("power", "Rays quit", .secondary)
        }
    }
}

private struct HoverHighlight: ViewModifier {
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .listRowBackground(RowHighlight(selected: false, hovered: hovered))
            .onHover { hovered = $0 }
    }
}

extension View {
    func hoverHighlight() -> some View { modifier(HoverHighlight()) }

    func rowStyle() -> some View {
        listRowInsets(EdgeInsets(top: LayoutMetrics.rowSpacing / 2, leading: LayoutMetrics.margin - LayoutMetrics.hoverInset,
                                 bottom: LayoutMetrics.rowSpacing / 2, trailing: LayoutMetrics.margin - LayoutMetrics.hoverInset))
            .listRowSeparator(.hidden)
    }
}
