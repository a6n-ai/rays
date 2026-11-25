import SwiftUI

/// What is running now, what starts next, and the last runs.
struct ActivityTab: View {
    let open: (UInt64, QueueSection?) -> Void
    @Environment(EngineModel.self) private var model

    private var running: [QueueView] { model.sortedQueues.filter { $0.state == .open && $0.running > 0 } }
    private var upcoming: [(queue: QueueView, next: Int64)] {
        model.queues.compactMap { queue in
            guard queue.config.enabled, queue.config.schedule != nil, let next = queue.nextRun else { return nil }
            return (queue, next)
        }
        .sorted { $0.next < $1.next }
    }

    var body: some View {
        List {
            Section {
                if running.isEmpty {
                    note("No queue is running")
                }
                ForEach(running) { queue in
                    runningRow(queue)
                        .contentShape(Rectangle())
                        .onTapGesture { open(queue.id, .downloads) }
                        .rowStyle()
                }
            } header: { header("Running now") }
            Section {
                if upcoming.isEmpty {
                    note("Nothing scheduled") {
                        Button("Schedule a queue") { open(1, .schedule) }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                    }
                }
                ForEach(upcoming, id: \.queue.id) { item in
                    upcomingRow(item.queue, next: item.next)
                        .contentShape(Rectangle())
                        .onTapGesture { open(item.queue.id, .schedule) }
                        .rowStyle()
                }
            } header: { header("Upcoming") }
            Section {
                if model.runs.isEmpty {
                    note("No runs yet")
                }
                ForEach(model.runs, id: \.id) { run in
                    historyRow(run).rowStyle()
                }
            } header: { header("History") }
        }
        .listStyle(.inset)
        .tint(.gray)
        .scrollContentBackground(.hidden)
        .scrollEdgeEffectStyle(.soft, for: .all)
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
        return row(symbol: "arrow.down.circle.fill", tint: .blue, title: queue.config.name, detail: detail) { EmptyView() }
    }

    private func upcomingRow(_ queue: QueueView, next: Int64) -> some View {
        let date = Date(timeIntervalSince1970: TimeInterval(next))
        return row(symbol: "clock", tint: .orange, title: queue.config.name, detail: queue.config.schedule?.summary ?? "") {
            VStack(alignment: .trailing, spacing: 2) {
                Text(SchedulerTime.nextRunText(next))
                Text(date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .monospacedDigit()
        }
    }

    private func historyRow(_ run: QueueRun) -> some View {
        let name = model.queues.first { $0.id == run.queueId }?.config.name ?? "Deleted queue"
        let outcome = Outcome(run.outcome)
        return row(symbol: outcome.symbol, tint: outcome.tint, title: name, detail: timeText(run)) {
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

    private func row(symbol: String, tint: Color, title: String, detail: String, @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: LayoutMetrics.gap) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: LayoutMetrics.iconSize, height: LayoutMetrics.iconSize)
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

private extension View {
    func rowStyle() -> some View {
        listRowInsets(EdgeInsets(top: LayoutMetrics.rowSpacing / 2, leading: LayoutMetrics.margin - LayoutMetrics.hoverInset,
                                 bottom: LayoutMetrics.rowSpacing / 2, trailing: LayoutMetrics.margin - LayoutMetrics.hoverInset))
            .listRowSeparator(.hidden)
    }
}
