import Charts
import SwiftUI

/// The Speed page: Overview (the test, its settings and the best time) and History, with its own toolbar like the other pages.
struct SpeedPage: View {
    @Environment(EngineModel.self) private var model
    @AppStorage("speedSection") private var section = SpeedSection.overview

    enum SpeedSection: String { case overview, history }

    var body: some View {
        NavigationStack {
            Group {
                switch section {
                case .overview: SpeedOverview()
                case .history: SpeedHistoryTab()
                }
            }
            .navigationTitle("Speed")
            .toolbar { toolbar }
        }
        .task { model.loadSpeedHistory() }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            ToolbarIconGroup {
                ForEach([(SpeedSection.overview, "gauge.with.dots.needle.67percent", "Overview"),
                         (SpeedSection.history, "clock.arrow.circlepath", "History")], id: \.0) { item in
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
                Button { model.testing ? model.cancelSpeedTest() : model.requestSpeedTest() } label: {
                    ToolbarIcon(symbol: model.testing ? "stop.fill" : "play.fill", title: model.testing ? "Stop test" : "Run test",
                                tint: model.testing ? .red : .blue)
                }
                .buttonStyle(.plain)
                .disabled(model.automaticTestRunning)
                .help(model.testing ? "Stop the speed test" : "Run a speed test")
            }
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .primaryAction) { SettingsToolbarButton() }
    }
}

// MARK: Overview

private struct SpeedOverview: View {
    @Environment(EngineModel.self) private var model

    private var progress: SpeedProgress? { model.speedProgress }

    private var subtitle: String {
        if let progress {
            if progress.phase == .latency { return "Checking latency" }
            var parts = ["Downloading", "\(progress.elapsedMs / 1000) of \(progress.totalMs / 1000) s"]
            if progress.bps > 0 { parts.append(SpeedFormat.mbps(progress.bps)) }
            return parts.joined(separator: " · ")
        }
        guard let test = model.lastTest else { return "Not tested yet" }
        let network = network(of: test)?.title
        return ([SpeedFormat.mbps(test.bps), "\(test.latencyMs) ms latency"] + [network].compactMap { $0 } + [SpeedFormat.ago(test.at)])
            .joined(separator: " · ")
    }

    var body: some View {
        Form {
            Section {
                HeroCard(.speed, title: "Speed test", subtitle: subtitle, caption: model.automaticTestRunning ? "Automatic test" : nil,
                         learnMore: URL(string: "https://rays.a6n.ai/docs/app/speed/"))
                    .monospacedDigit()
                if let progress {
                    ProgressView(value: Double(progress.elapsedMs), total: Double(max(progress.totalMs, 1)))
                        .progressViewStyle(.linear)
                        .tint(TilePalette.teal)
                }
            }
            CollapsibleSettingsCard(page: "speed") { SpeedSettingsRows() }
            if let test = model.lastTest, !test.saved, progress == nil {
                Section { notice(model.unsavedReason, .warning) }
            }
            if let error = model.speedError { Section { notice(error, .error) } }
            if !model.liveSamples.isEmpty {
                Section { ChartCard<Int, _>("Speed during the test") { LiveChart(samples: model.liveSamples) } }
            }
            bestTime
        }
        .formStyle(.grouped)
    }

    private func notice(_ text: String, _ kind: StatusDot.Kind) -> some View {
        HStack(spacing: 6) {
            StatusDot(kind)
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
    }

    /// The network the last test ran on, if its sample is still in the history.
    private func network(of test: SpeedTestResult) -> NetworkKind? {
        model.speedHistory.first { $0.source == .test && $0.at == test.at }?.network
    }

    @ViewBuilder private var bestTime: some View {
        switch model.bestTime {
        case .window(let start, let end, _, let days, _)?:
            Section {
                ChartCard<Int, _>("Best time") { HourlyChart(hourly: model.hourly, start: Int(start), end: Int(end)) }
                Text("Usually fastest \(SchedulerTime.hhmm(start))–\(SchedulerTime.hhmm(end)) · \(days) days")
                    .font(.callout).foregroundStyle(.secondary)
            }
        case .notEnoughData(let days, let needed)?:
            Section("Best time") {
                EmptyState(symbol: "chart.bar", title: "Not enough data yet",
                           message: "\(days) of \(needed) days. Rays learns from your downloads and speed tests.")
                    .frame(height: 220)
                if model.speedSettings.nightPromptAnswered && !model.nightWeekActive {
                    Button("Test at night for a week") { model.startNightWeek() }
                        .frame(maxWidth: .infinity)
                }
            }
        case nil:
            EmptyView()
        }
    }
}

/// The Y axis of every chart in a card: trailing side, hairline grid, small secondary labels.
@AxisContentBuilder
func trailingAxis(values: AxisMarkValues, format: ((AxisValue) -> String?)? = nil) -> some AxisContent {
    AxisMarks(position: .trailing, values: values) { value in
        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
        AxisValueLabel {
            if let text = format?(value) ?? value.as(Double.self).map({ $0.formatted() }) {
                Text(text).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Every progress reading of the test, as a line with a faint area under it.
private struct LiveChart: View {
    let samples: [LivePoint]

    var body: some View {
        Chart {
            ForEach(Array(samples.enumerated()), id: \.offset) { _, point in
                let x = Double(point.ms) / 1000
                let y = Double(point.bps) * 8 / 1_000_000
                AreaMark(x: .value("Seconds", x), y: .value("Mb/s", y)).foregroundStyle(TilePalette.teal.opacity(0.15))
                LineMark(x: .value("Seconds", x), y: .value("Mb/s", y)).foregroundStyle(TilePalette.teal)
            }
        }
        .chartYAxis { trailingAxis(values: .automatic(desiredCount: 3)) }
        .chartXAxisLabel("seconds")
        .chartYAxisLabel("Mb/s", position: .trailing)
        .transaction { $0.animation = nil }
        .accessibilityLabel("Speed over the test")
    }
}

private struct HourlyChart: View {
    let hourly: [UInt64?]
    let start: Int
    let end: Int

    var body: some View {
        Chart {
            ForEach(Array(hourly.enumerated()), id: \.offset) { hour, bps in
                if let bps {
                    BarMark(x: .value("Hour", hour), y: .value("Mb/s", Double(bps) * 8 / 1_000_000))
                        .foregroundStyle(TilePalette.teal.opacity(hourInWindow(hour, start: start, end: end) ? 1 : 0.3))
                        .cornerRadius(2)
                }
            }
        }
        .chartXScale(domain: -0.5...23.5)
        .chartXAxis {
            AxisMarks(values: Array(stride(from: 0, through: 21, by: 3))) { value in
                AxisGridLine()
                AxisValueLabel { if let hour = value.as(Int.self) { Text(String(format: "%02d", hour)) } }
            }
        }
        .chartYAxis { trailingAxis(values: .automatic) }
        .chartYAxisLabel("Mb/s", position: .trailing)
        .transaction { $0.animation = nil }
        .accessibilityLabel("Typical speed by hour of day")
    }
}

// MARK: History

private struct SpeedHistoryTab: View {
    @Environment(EngineModel.self) private var model
    @State private var filter = "All"
    @State private var sort = ListSort.newest
    @State private var kind = FileKind.all
    @State private var page = 0
    @AppStorage(Paging.key) private var pageSize = Paging.defaultSize

    private var shown: [SpeedSample] {
        let kept = model.speedHistory.filter {
            switch filter {
            case "Speed tests": $0.source == .test
            case "Downloads": $0.source == .downloads
            default: true
            }
        }
        return sort == .fastest ? kept.sorted { $0.bps > $1.bps } : kept
    }

    var body: some View {
        VStack(spacing: 0) {
            ListControls(statuses: ["All", "Speed tests", "Downloads"], status: $filter, kind: $kind, showsKind: false,
                         sorts: [.newest, .fastest], sort: $sort, count: shown.count, page: $page)
            if shown.isEmpty {
                EmptyState(symbol: "clock.arrow.circlepath", title: "No speed history yet",
                           message: "Run a test, or download something. Rays keeps 60 days.")
            } else {
                List {
                    ForEach(ListControls.page(shown, page, pageSize).enumerated().map { (id: "\(page)-\($0.offset)", sample: $0.element) }, id: \.id) { entry in
                        let (id, sample) = (entry.id, entry.sample)
                        row(sample)
                            .hoverHighlight()
                            .rowStyle()
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .scrollEdgeEffectStyle(.soft, for: .all)
            }
        }
    }

    private func row(_ sample: SpeedSample) -> some View {
        let isTest = sample.source == .test
        let date = Date(timeIntervalSince1970: TimeInterval(sample.at))
        return HStack(spacing: LayoutMetrics.gap) {
            IconTile(isTest ? .speed : .downloads, size: TileSize.list)
            VStack(alignment: .leading, spacing: 4) {
                Text(SpeedFormat.mbps(sample.bps)).font(.body.weight(.semibold)).monospacedDigit().lineLimit(1)
                HStack(spacing: 12) {
                    Label(isTest ? "Speed test" : "Downloads", systemImage: isTest ? "gauge.with.dots.needle.67percent" : "arrow.down.circle")
                    Label(sample.network.title, systemImage: sample.network.symbol)
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: LayoutMetrics.rowHeight)
        .padding(.horizontal, LayoutMetrics.hoverInset)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Settings card

private struct SpeedSettingsRows: View {
    @Environment(EngineModel.self) private var model
    @State private var confirmClear = false

    var body: some View {
        SettingRow(.speed, title: "Test automatically every 3 hours", hint: "Uses about 50 to 200 MB per test") {
            Toggle("Test automatically every 3 hours",
                   isOn: Binding(get: { model.speedSettings.autoTests }, set: { model.setAutoTests($0) }))
                .labelsHidden()
        }
        SettingRow(.schedules, title: "Night tests") {
            if let until = model.speedSettings.nightUntil, model.nightWeekActive {
                HStack {
                    Text("On until " + Date(timeIntervalSince1970: TimeInterval(until)).formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                        .foregroundStyle(.secondary)
                    Button("Stop night tests") { model.stopNightWeek() }
                }
            } else {
                Button("Test at night for a week") { model.startNightWeek() }
            }
        }
        SettingRow(.trash, title: "Speed history", hint: "Speed data stays on this Mac.") {
            Button("Clear speed history…", role: .destructive) { confirmClear = true }
        }
        .confirmationDialog("Clear speed history?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { model.clearSpeedHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Rays forgets every speed test and sample, and the best time resets.")
        }
    }
}
