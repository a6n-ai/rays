import SwiftUI

/// The sidebar's speed summary, a row of the sidebar list tagged `Destination.speed`: the last result or the live
/// test, and a button to run or stop a test.
struct SpeedCard: View {
    @Environment(EngineModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            return (model.testing ? "Testing \(seconds)" : "Automatic test \(progress.elapsedMs / 1000) s", false)
        }
        return (model.lastTest.map { SpeedFormat.ago($0.at) } ?? "Not tested yet", false)
    }

    var body: some View {
        HStack(spacing: 8) {
            tile
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(value)
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .transaction { if reduceMotion { $0.animation = nil } }
                    if progress != nil, model.liveSamples.count > 1 { Sparkline(points: model.liveSamples) }
                }
                Text(caption.text)
                    .font(.caption)
                    .foregroundStyle(caption.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            Spacer(minLength: 0)
            actionButton
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Speed, \(value), \(caption.text)")
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

/// The last 20 readings of the running test as a tiny teal line.
private struct Sparkline: View {
    let points: [LivePoint]

    var body: some View {
        let recent = points.suffix(20).map { Double($0.bps) }
        let top = max(recent.max() ?? 1, 1)
        Path { path in
            for (index, value) in recent.enumerated() {
                let point = CGPoint(x: 40 * Double(index) / Double(max(recent.count - 1, 1)), y: 12 - 12 * value / top)
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
        .stroke(Color.teal, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        .frame(width: 40, height: 12)
        .accessibilityHidden(true)
    }
}
