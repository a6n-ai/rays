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
                if progress.bps > 0 { badge(progress.bps) }
            } else if let test = model.lastTest {
                badge(test.bps)
            }
        }
        .contextMenu {
            if model.testing {
                Button("Stop speed test", systemImage: "stop.fill") { model.cancelSpeedTest() }
            } else {
                Button("Run speed test", systemImage: "play.fill") { model.requestSpeedTest() }
                    .disabled(model.automaticTestRunning)
            }
        }
    }

    /// Number only, so it never truncates; the unit lives in the help text and accessibility label.
    private func badge(_ bps: UInt64) -> some View {
        let full = SpeedFormat.mbps(bps, whole: true)
        return Text(full.replacingOccurrences(of: " Mb/s", with: ""))
            .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            .help(full)
            .accessibilityLabel(full)
    }
}
