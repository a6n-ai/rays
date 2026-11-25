import SwiftUI

/// The sidebar's speed summary: the last result, and a button to run a test. Clicking the card opens the Speed page.
struct SpeedCard: View {
    @Environment(EngineModel.self) private var model
    @Binding var selection: Destination?

    private var summary: String {
        guard let test = model.lastTest else { return "No test yet" }
        return "\(SpeedFormat.mbps(test.bps)) · \(SpeedFormat.ago(test.at))"
    }

    var body: some View {
        HStack(spacing: 8) {
            Button { selection = .speed } label: {
                HStack(spacing: 8) {
                    ModelTile(symbol: "gauge.with.dots.needle.67percent", color: .teal, size: 28)
                    Text(summary)
                        .font(.callout)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Speed, \(summary)")
            .help("Open Speed")
            Button { model.requestSpeedTest() } label: {
                Group {
                    if model.testing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "play.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.blue)
                            .offset(x: 1)
                    }
                }
                .frame(width: LayoutMetrics.rowAction, height: LayoutMetrics.rowAction)
                .glassEffect(.regular.interactive(), in: .circle)
                .frame(width: LayoutMetrics.rowHitArea, height: LayoutMetrics.rowHitArea)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(model.testing)
            .help("Run a speed test")
            .accessibilityLabel("Run test")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
