import Charts
import SwiftUI

struct SpeedPage: View {
    @Environment(EngineModel.self) private var model
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section { header }
            Section("Best time") { recommendation }
            Section("Settings") {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Test automatically every 3 hours",
                           isOn: Binding(get: { model.speedSettings.autoTests }, set: { model.setAutoTests($0) }))
                    formNote("Uses about 50 to 200 MB per test")
                }
                if model.speedSettings.nightPromptAnswered && !model.nightWeekActive {
                    Button("Test at night for a week") { model.startNightWeek() }
                }
                Button("Clear speed history…", role: .destructive) { confirmClear = true }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Speed")
        .confirmationDialog("Clear speed history?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { model.clearSpeedHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Rays forgets every speed test and sample, and the best time resets.")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: LayoutMetrics.gap) {
            VStack(alignment: .leading, spacing: 4) {
                if let test = model.lastTest {
                    Text(SpeedFormat.mbps(test.bps))
                        .font(.largeTitle.weight(.semibold))
                        .monospacedDigit()
                    Text("\(test.latencyMs) ms latency · \(SpeedFormat.ago(test.at))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if !test.saved {
                        Text("Downloads were running, so this result wasn't saved")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } else {
                    Text("No test yet").font(.title2.weight(.semibold))
                }
                if let error = model.speedError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            Button { model.requestSpeedTest() } label: {
                if model.testing {
                    Label("Testing…", systemImage: "play.fill").labelStyle(.titleOnly)
                } else {
                    Label("Run test", systemImage: "play.fill")
                }
            }
            .buttonStyle(.glassProminent)
            .disabled(model.testing)
        }
    }

    @ViewBuilder private var recommendation: some View {
        switch model.bestTime {
        case .window(let start, let end, _, let days, _)?:
            Text("Usually fastest \(SchedulerTime.hhmm(start))–\(SchedulerTime.hhmm(end)) · \(days) days")
            HourlyChart(hourly: model.hourly, window: Int(start)..<Int(end))
        case .notEnoughData(let days, let needed)?:
            EmptyState(symbol: "chart.bar", title: "Not enough data yet",
                       message: "\(days) of \(needed) days. Rays learns from your downloads and speed tests.")
                .frame(height: 220)
        case nil:
            EmptyView()
        }
    }
}

private struct HourlyChart: View {
    let hourly: [UInt64?]
    let window: Range<Int>

    private func inWindow(_ hour: Int) -> Bool {
        let minute = hour * 60
        return window.lowerBound <= window.upperBound ? window.contains(minute) : (minute >= window.lowerBound || minute < window.upperBound)
    }

    var body: some View {
        Chart {
            ForEach(Array(hourly.enumerated()), id: \.offset) { hour, bps in
                if let bps {
                    BarMark(x: .value("Hour", hour), y: .value("Mb/s", Double(bps) * 8 / 1_000_000))
                        .foregroundStyle(inWindow(hour) ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
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
