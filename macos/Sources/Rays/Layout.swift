import CoreGraphics

/// Named to avoid shadowing SwiftUI's `Layout` protocol.
enum LayoutMetrics {
    static let margin: CGFloat = 20
    static let barHeight: CGFloat = 36
    static let barMaxWidth: CGFloat = 560
    static let rowHeight: CGFloat = 56
    static let rowAction: CGFloat = 28
    static let rowHitArea: CGFloat = 32
    static let rowSpacing: CGFloat = 4
    /// The row highlight extends this far past the content column on each side.
    static let hoverInset: CGFloat = 4
    static let gap: CGFloat = 12
    static let iconSize: CGFloat = 32
}
