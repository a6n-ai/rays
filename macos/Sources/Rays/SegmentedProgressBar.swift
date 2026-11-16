import SwiftUI

/// One segment per connection, laid out along the file's full size, so a stalled connection shows as a stalled segment.
struct SegmentedProgressBar: View {
    let parts: [PartView]
    let total: UInt64
    let tint: Color

    private let height: CGFloat = 6
    private let gap: CGFloat = 1.5

    var body: some View {
        Canvas { context, size in
            let scale = size.width / CGFloat(total)
            let radius = size.height / 2
            for part in parts {
                let length = part.end - part.start
                let rect = CGRect(
                    x: CGFloat(part.start) * scale + gap / 2, y: 0,
                    width: max(0, CGFloat(length) * scale - gap), height: size.height)
                context.fill(Path(roundedRect: rect, cornerRadius: radius), with: .style(.quaternary))
                let fraction = length > 0 ? min(1, CGFloat(part.done) / CGFloat(length)) : 0
                let filledWidth = rect.width * fraction
                if filledWidth > 0 {
                    let filled = CGRect(x: rect.minX, y: 0, width: filledWidth, height: size.height)
                    context.fill(Path(roundedRect: filled, cornerRadius: min(radius, filledWidth / 2)), with: .color(tint))
                }
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Download progress")
        .accessibilityValue("\(percent) percent, \(finishedParts) of \(parts.count) parts finished")
    }

    private var done: UInt64 { parts.reduce(0) { $0 + $1.done } }

    private var percent: Int {
        total > 0 ? Int(Double(done) / Double(total) * 100) : 0
    }

    private var finishedParts: Int {
        parts.filter { $0.done >= $0.end - $0.start }.count
    }
}
