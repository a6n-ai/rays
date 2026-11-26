import SwiftUI

/// The Speed row of the sidebar's Tools section: a plain label with the last or live rate as a trailing badge.
struct SpeedCard: View {
    @Environment(EngineModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            SidebarLabel("Speed test", tile: .speed)
                .layoutPriority(1)
            Spacer(minLength: 0)
            if let progress = model.speedProgress {
                ProgressView().controlSize(.mini)
                if progress.bps > 0 { badge(SpeedFormat.mbps(progress.bps, whole: true)) }
            } else if let test = model.lastTest {
                badge(SpeedFormat.mbps(test.bps, whole: true))
            }
        }
        .contextMenu {
            if model.testing {
                Button("Stop Speed Test", systemImage: "stop.fill") { model.cancelSpeedTest() }
            } else {
                Button("Run Speed Test", systemImage: "play.fill") { model.requestSpeedTest() }
                    .disabled(model.automaticTestRunning)
            }
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
    }
}
