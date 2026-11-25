import Charts
import SwiftUI

/// The Speed page: Overview (the test and the best time), History and Settings, with its own toolbar like the other pages.
struct SpeedPage: View {
    @Environment(EngineModel.self) private var model
    @AppStorage("speedSection") private var section = SpeedSection.overview

    enum SpeedSection: String { case overview, history, settings }

    var body: some View {
        NavigationStack {
            Group {
                switch section {
                case .overview: SpeedOverview()
                case .history: SpeedHistoryTab()
                case .settings: SpeedSettingsTab()
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
                         (SpeedSection.history, "clock.arrow.circlepath", "History"),
                         (SpeedSection.settings, "slider.horizontal.3", "Settings")], id: \.0) { item in
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var progress: SpeedProgress? { model.speedProgress }

    /// Live rate while testing, else the last result.
    private var mbps: Double {
        if let progress { return Double(progress.bps) * 8 / 1_000_000 }
        return model.lastTest.map { Double($0.bps) * 8 / 1_000_000 } ?? 0
    }

    private var scaleMax: Double {
        let seen = ([mbps] + model.hourly.compactMap { $0 }.map { Double($0) * 8 / 1_000_000 }
            + model.liveSamples.map { Double($0.bps) * 8 / 1_000_000 }).max() ?? 0
        return max(100, 1.25 * seen)
    }

    private var phaseText: String {
        guard let progress else { return model.lastTest == nil ? "No test yet" : "Last test" }
        if progress.phase == .latency { return "Checking latency" }
        return "Downloading \(progress.elapsedMs / 1000) s"
    }

    private var accessibility: String {
        let base = "Speed test, \(Int(mbps.rounded())) megabits per second"
        guard let progress else { return base }
        let phase = progress.phase == .latency ? "checking latency" : "downloading"
        return "\(base), \(phase), \(progress.elapsedMs / 1000) of \(progress.totalMs / 1000) seconds"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LayoutMetrics.gap) {
            VStack(spacing: 8) {
                SpeedGauge(value: mbps, maxValue: scaleMax, phase: phaseText, animates: progress == nil && !reduceMotion)
                    .frame(width: 240, height: 190)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibility)
                if let progress {
                    ProgressView(value: Double(progress.elapsedMs), total: Double(max(progress.totalMs, 1)))
                        .progressViewStyle(.linear)
                        .tint(.teal)
                        .frame(maxWidth: 320)
                    if model.automaticTestRunning {
                        Text("Automatic test").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    details
                }
                if let error = model.speedError {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity)
            if !model.liveSamples.isEmpty { LiveChart(samples: model.liveSamples) }
            Text("Best time").font(.headline).padding(.top, LayoutMetrics.gap)
            recommendation
        }
        .formColumn()
    }

    /// The network the last test ran on, if its sample is still in the history.
    private func network(of test: SpeedTestResult) -> NetworkKind? {
        model.speedHistory.first { $0.source == .test && $0.at == test.at }?.network
    }

    @ViewBuilder private var details: some View {
        if let test = model.lastTest {
            Text(([ "\(test.latencyMs) ms latency" ] + [network(of: test)?.title].compactMap { $0 } + [SpeedFormat.ago(test.at)]).joined(separator: " · "))
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if !test.saved {
                Text("Downloads were running, so this result wasn't saved")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder private var recommendation: some View {
        switch model.bestTime {
        case .window(let start, let end, _, let days, _)?:
            Text("Usually fastest \(SchedulerTime.hhmm(start))–\(SchedulerTime.hhmm(end)) · \(days) days")
                .foregroundStyle(.secondary)
            HourlyChart(hourly: model.hourly, start: Int(start), end: Int(end))
        case .notEnoughData(let days, let needed)?:
            EmptyState(symbol: "chart.bar", title: "Not enough data yet",
                       message: "\(days) of \(needed) days. Rays learns from your downloads and speed tests.")
                .frame(height: 220)
            if model.speedSettings.nightPromptAnswered && !model.nightWeekActive {
                Button("Test at night for a week") { model.startNightWeek() }
                    .frame(maxWidth: .infinity)
            }
        case nil:
            EmptyView()
        }
    }
}

/// A 240 degree speedometer: a track and a teal-to-blue fill up to the current Mb/s.
private struct SpeedGauge: View {
    let value: Double
    let maxValue: Double
    let phase: String
    let animates: Bool

    private var fraction: Double { min(1, max(0, value / maxValue)) }

    var body: some View {
        ZStack {
            GaugeArc().stroke(.quaternary, style: StrokeStyle(lineWidth: 16, lineCap: .round))
            GaugeArc()
                .trim(from: 0, to: fraction)
                .stroke(AngularGradient(colors: [.teal, .blue], center: .center, startAngle: .degrees(150), endAngle: .degrees(390)),
                        style: StrokeStyle(lineWidth: 16, lineCap: .round))
                .animation(animates ? .smooth(duration: 0.4) : nil, value: fraction)
            VStack(spacing: 0) {
                Text(value >= 100 ? String(Int(value.rounded())) : String(format: "%.1f", value))
                    .font(.system(size: 44, weight: .semibold))
                    .monospacedDigit()
                Text("Mb/s").font(.callout).foregroundStyle(.secondary)
                Text(phase).font(.caption).foregroundStyle(.secondary).padding(.top, 6)
            }
        }
        .padding(12)
    }
}

private struct GaugeArc: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) / 2
        var path = Path()
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: radius, startAngle: .degrees(150),
                    endAngle: .degrees(390), clockwise: false)
        return path
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
                AreaMark(x: .value("Seconds", x), y: .value("Mb/s", y)).foregroundStyle(Color.teal.opacity(0.15))
                LineMark(x: .value("Seconds", x), y: .value("Mb/s", y)).foregroundStyle(Color.teal)
            }
        }
        .chartXAxisLabel("seconds")
        .chartYAxisLabel("Mb/s")
        .frame(height: 100)
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
                        .foregroundStyle(hourInWindow(hour, start: start, end: end) ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
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
        .chartYAxisLabel("Mb/s")
        .frame(height: 180)
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
    @State private var hovered: String?

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
                         sorts: [.newest, .fastest], sort: $sort, count: 0, page: $page)
            if shown.isEmpty {
                EmptyState(symbol: "clock.arrow.circlepath", title: "No speed history yet",
                           message: "Run a test, or download something. Rays keeps 60 days.")
            } else {
                List {
                    ForEach(shown.enumerated().map { (id: "\($0.element.at)-\($0.offset)", sample: $0.element) }, id: \.id) { entry in
                        let (id, sample) = (entry.id, entry.sample)
                        row(sample)
                            .background(RowHighlight(selected: false, hovered: hovered == id))
                            .onHover { hovered = $0 ? id : nil }
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
            ModelTile(symbol: isTest ? "gauge.with.dots.needle.67percent" : "arrow.down.circle.fill", color: isTest ? .teal : .blue)
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

// MARK: Settings

private struct SpeedSettingsTab: View {
    @Environment(EngineModel.self) private var model
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section {
                Toggle("Test automatically every 3 hours",
                       isOn: Binding(get: { model.speedSettings.autoTests }, set: { model.setAutoTests($0) }))
            } footer: {
                Text("Uses about 50 to 200 MB per test").font(.footnote).foregroundStyle(.tertiary)
            }
            Section {
                LabeledContent("Night tests") {
                    if let until = model.speedSettings.nightUntil, model.nightWeekActive {
                        Text("On until " + Date(timeIntervalSince1970: TimeInterval(until)).formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Test at night for a week") { model.startNightWeek() }
                    }
                }
            }
            Section {
                Button("Clear speed history…", role: .destructive) { confirmClear = true }
            } footer: {
                Text("Speed data stays on this Mac.").font(.footnote).foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Clear speed history?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { model.clearSpeedHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Rays forgets every speed test and sample, and the best time resets.")
        }
    }
}
