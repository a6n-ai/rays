import SwiftUI
import UniformTypeIdentifiers

extension EngineModel {
    private var transferring: [JobView] { jobs.filter { $0.isActive && $0.state != .verifying } }
    private var starting: Int { jobs.filter { $0.state == .queued && $0.waiting == nil }.count }
    private var verifying: Int { jobs.filter { $0.state == .verifying }.count }

    var hasActivity: Bool { jobs.contains { $0.isActive || ($0.state == .queued && $0.waiting == nil) } }
    var queuesRunning: Bool { queues.contains { $0.running > 0 } }

    fileprivate var activityTitle: String {
        let n = transferring.count
        if n > 0 { return "Downloading \(n) \(n == 1 ? "file" : "files")" }
        if starting > 0 { return "Starting \(starting) \(starting == 1 ? "file" : "files")" }
        return "Verifying"
    }
}

extension View {
    /// A small accent dot at the row's trailing edge while `active`, announced as "Downloading".
    func activeDot(_ active: Bool) -> some View {
        modifier(ActiveDot(active: active))
    }
}

private struct ActiveDot: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .trailing) {
                Circle().fill(.tint).frame(width: 7, height: 7)
                    .opacity(active ? 1 : 0)
                    .animation(.easeInOut(duration: 0.2), value: active)
                    .accessibilityHidden(true)
            }
            .accessibilityValue(active ? "Downloading" : "")
    }
}

/// Sidebar card above the speed row: what is downloading right now. Shown only while something is active.
struct ActivityCard: View {
    @Environment(EngineModel.self) private var model
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let open: () -> Void

    var body: some View {
        let running = model.jobs.filter { $0.state == .running || { if case .retrying = $0.state { true } else { false } }($0) }
        let shown = running.sorted { $0.id > $1.id }.prefix(2)
        let bps = running.reduce(0) { $0 + $1.bytesPerSec }
        let left = running.reduce(UInt64(0)) { $0 + (($1.total ?? 0) > $1.done ? $1.total! - $1.done : 0) }
        Button(action: open) {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.activityTitle).font(.callout.weight(.medium)).lineLimit(1)
                if bps > 0 {
                    let eta = left > 0
                        ? " · " + Duration.seconds(Double(left) / Double(bps))
                            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 1)) + " left"
                        : ""
                    Text(SpeedFormat.mbps(bps) + eta).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                }
                ForEach(Array(shown), id: \.id) { job in row(job) }
                if running.count > shown.count {
                    Text("and \(running.count - shown.count) more").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(reduceTransparency ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.quinary), in: .rect(cornerRadius: 10))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens Downloads")
    }

    private func row(_ job: JobView) -> some View {
        let type = UTType(filenameExtension: URL(filePath: job.name).pathExtension) ?? .data
        let fraction = job.total.map { $0 > 0 ? min(1, Double(job.done) / Double($0)) : 0 }
        return HStack(spacing: 6) {
            Image(nsImage: NSWorkspace.shared.icon(for: type)).resizable().frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.name).font(.subheadline).lineLimit(1).truncationMode(.middle)
                if let fraction {
                    ProgressView(value: fraction).progressViewStyle(.linear).controlSize(.mini)
                } else {
                    ProgressView().progressViewStyle(.linear).controlSize(.mini)
                }
            }
            if let fraction {
                Text(fraction, format: .percent.precision(.fractionLength(0)))
                    .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    .fixedSize()
                    .layoutPriority(1)
            }
        }
    }
}
