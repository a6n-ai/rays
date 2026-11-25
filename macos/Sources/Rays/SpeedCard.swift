import SwiftUI

/// The sidebar's speed summary: the last result or the live test, and a button to run or stop a test.
/// Clicking the card opens the Speed page.
struct SpeedCard: View {
    @Environment(EngineModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var selection: Destination?
    @State private var hovered = false

    private var progress: SpeedProgress? { model.speedProgress }

    private var value: String {
        if let progress { return progress.bps > 0 ? SpeedFormat.mbps(progress.bps) : "Testing" }
        return model.lastTest.map { SpeedFormat.mbps($0.bps) } ?? "Speed test"
    }

    private var caption: (text: String, isError: Bool) {
        if let error = model.speedError { return (error, true) }
        if let progress {
            if progress.phase == .latency { return ("Checking latency", false) }
            let seconds = "\(progress.elapsedMs / 1000) s of \(progress.totalMs / 1000)"
            return (model.testing ? "Testing  \(seconds)" : "Automatic test  \(seconds)", false)
        }
        return (model.lastTest.map { SpeedFormat.ago($0.at) } ?? "Check your connection", false)
    }

    var body: some View {
        HStack(spacing: 8) {
            Button { selection = .speed } label: {
                HStack(spacing: 8) {
                    tile
                    VStack(alignment: .leading, spacing: 1) {
                        Text(value)
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .transaction { if reduceMotion { $0.animation = nil } }
                        Text(caption.text)
                            .font(.caption)
                            .foregroundStyle(caption.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Speed, \(value), \(caption.text)")
            .help("Open Speed")
            actionButton
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RowHighlight(selected: selection == .speed, hovered: hovered), alignment: .center)
        .onHover { hovered = $0 }
        .padding(.bottom, 6)
    }

    private var tile: some View {
        ModelTile(symbol: "gauge.with.dots.needle.67percent", color: .teal, size: 28)
            .padding(3)
            .overlay {
                if let progress {
                    Circle()
                        .trim(from: 0, to: progress.fraction)
                        .stroke(Color.teal, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(reduceMotion ? nil : .linear(duration: 0.25), value: progress.fraction)
                }
            }
    }

    private var actionButton: some View {
        let stops = model.testing
        return Button { stops ? model.cancelSpeedTest() : model.requestSpeedTest() } label: {
            Image(systemName: stops ? "stop.fill" : "play.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(stops ? Color.red : Color.blue)
                .offset(x: stops ? 0 : 1)
                .frame(width: LayoutMetrics.rowAction, height: LayoutMetrics.rowAction)
                .glassEffect(.regular.interactive(), in: .circle)
                .frame(width: LayoutMetrics.rowHitArea, height: LayoutMetrics.rowHitArea)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(model.automaticTestRunning)
        .help(stops ? "Stop the speed test" : "Run a speed test")
        .accessibilityLabel(stops ? "Stop test" : "Run test")
    }
}
