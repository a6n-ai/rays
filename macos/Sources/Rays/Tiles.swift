import SwiftUI

enum TileSize {
    static let sidebar: CGFloat = 20
    static let menu: CGFloat = 18
    static let row: CGFloat = 20
    static let list: CGFloat = 28
    static let hero: CGFloat = 28
    static let heroLarge: CGFloat = 64
}

/// One concept, one symbol and colour, wherever it shows: sidebar, hero, Settings rows, menu bar panel, Shortcuts.
struct Tile: Hashable {
    let symbol: String
    let color: Color
    var glyphScale: CGFloat = 0.5
}

extension Tile {
    static let downloads = Tile(symbol: "arrow.down", color: TilePalette.blue, glyphScale: 0.52)
    static let models = Tile(symbol: "cpu.fill", color: TilePalette.purple, glyphScale: 0.5)
    static let sorter = Tile(symbol: "wand.and.stars", color: TilePalette.pink, glyphScale: 0.5)
    static let cloud = Tile(symbol: "icloud.fill", color: TilePalette.sky, glyphScale: 0.48)
    static let queues = Tile(symbol: "list.bullet", color: TilePalette.orange, glyphScale: 0.46)
    static let schedules = Tile(symbol: "calendar.badge.clock", color: TilePalette.orange, glyphScale: 0.52)
    static let speed = Tile(symbol: "gauge.with.dots.needle.67percent", color: TilePalette.teal, glyphScale: 0.6)
    static let stats = Tile(symbol: "chart.bar.fill", color: TilePalette.green, glyphScale: 0.44)
    static let shortcuts = Tile(symbol: "square.stack.3d.up.fill", color: TilePalette.indigo, glyphScale: 0.48)
    static let general = Tile(symbol: "gearshape.fill", color: TilePalette.gray, glyphScale: 0.58)
    static let ai = Tile(symbol: "apple.intelligence", color: TilePalette.purple, glyphScale: 0.58)
    static let browsers = Tile(symbol: "safari.fill", color: TilePalette.indigo, glyphScale: 0.6)

    static let appearance = Tile(symbol: "circle.lefthalf.filled", color: TilePalette.gray)
    static let folder = Tile(symbol: "folder.fill", color: TilePalette.blue)
    static let menuBar = Tile(symbol: "menubar.arrow.down.rectangle", color: TilePalette.indigo)
    static let clipboard = Tile(symbol: "doc.on.clipboard", color: TilePalette.teal)
    static let notifications = Tile(symbol: "bell.badge.fill", color: TilePalette.red)
    static let concurrency = Tile(symbol: "arrow.triangle.branch", color: TilePalette.green)
    static let parts = Tile(symbol: "point.3.connected.trianglepath.dotted", color: TilePalette.purple)
    static let speedLimit = Tile(symbol: "hare.fill", color: TilePalette.teal)
    static let duplicates = Tile(symbol: "doc.on.doc.fill", color: TilePalette.blue)
    static let modelsFolder = Tile(symbol: "shippingbox.fill", color: TilePalette.purple)
    static let commandLine = Tile(symbol: "terminal.fill", color: TilePalette.gray)
    static let updates = Tile(symbol: "arrow.triangle.2.circlepath", color: TilePalette.blue)
    static let unpack = Tile(symbol: "archivebox.fill", color: TilePalette.orange)
    static let trash = Tile(symbol: "trash.fill", color: TilePalette.gray)
    static let wake = Tile(symbol: "alarm.fill", color: TilePalette.orange)
    static let sortDelay = Tile(symbol: "timer", color: TilePalette.pink)
    static let rename = Tile(symbol: "pencil", color: TilePalette.pink)
    static let watchedFolders = Tile(symbol: "folder.badge.gearshape", color: TilePalette.pink)
    static let warning = Tile(symbol: "exclamationmark.triangle.fill", color: TilePalette.orange)
    static let history = Tile(symbol: "clock.arrow.circlepath", color: TilePalette.teal)
    static let localModel = Tile(symbol: "internaldrive.fill", color: TilePalette.gray)
}

/// An app-icon-like square: gradient fill, white symbol at 50% of the tile.
struct IconTile: View {
    let tile: Tile
    let size: CGFloat

    init(_ tile: Tile, size: CGFloat = TileSize.row) {
        self.tile = tile
        self.size = size
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
        Image(systemName: tile.symbol)
            .symbolRenderingMode(.monochrome)
            .imageScale(.medium)  // a sidebar List sets .large on row images, which would overfill the tile
            // Small tiles need a larger share to read, like System Settings; large tiles keep the base scale.
            .font(.system(size: (size * (tile.glyphScale + (size <= 24 ? 0.08 : 0))).rounded(), weight: .semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.2), radius: 0.5, y: 0.5)
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: [tile.color.mix(with: .white, by: 0.12), tile.color], startPoint: .top, endPoint: .bottom),
                in: shape)
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.25), .black.opacity(0.12)],
                                                       startPoint: .top, endPoint: .bottom), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.15), radius: 0.5, y: 0.5)
            .accessibilityHidden(true)
    }
}

/// An 8pt status circle that goes before a secondary line.
struct StatusDot: View {
    enum Kind { case ok, active, warning, error, off }
    let kind: Kind

    init(_ kind: Kind) { self.kind = kind }

    private var color: Color {
        switch kind {
        case .ok: TilePalette.green
        case .active: TilePalette.blue
        case .warning: TilePalette.orange
        case .error: TilePalette.red
        case .off: TilePalette.gray
        }
    }

    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
    }
}
