import SwiftUI

enum TileSize {
    static let sidebar: CGFloat = 20
    static let menu: CGFloat = 18
    static let row: CGFloat = 22
    static let list: CGFloat = 32
    static let hero: CGFloat = 28
    static let heroLarge: CGFloat = 64
}

/// One concept, one symbol and colour, wherever it shows: sidebar, hero, Settings rows, menu bar panel, Shortcuts.
struct Tile: Hashable {
    let symbol: String
    let color: Color
}

extension Tile {
    static let downloads = Tile(symbol: "arrow.down", color: TilePalette.blue)
    static let models = Tile(symbol: "cube.fill", color: TilePalette.purple)
    static let sorter = Tile(symbol: "sparkles", color: TilePalette.pink)
    static let cloud = Tile(symbol: "cloud.fill", color: TilePalette.sky)
    static let queues = Tile(symbol: "list.bullet", color: TilePalette.orange)
    static let schedules = Tile(symbol: "calendar", color: TilePalette.orange)
    static let speed = Tile(symbol: "gauge.with.dots.needle.67percent", color: TilePalette.teal)
    static let stats = Tile(symbol: "chart.bar.fill", color: TilePalette.green)
    static let shortcuts = Tile(symbol: "square.2.layers.3d.fill", color: TilePalette.indigo)
    static let general = Tile(symbol: "gearshape.fill", color: TilePalette.gray)
    static let ai = Tile(symbol: "apple.intelligence", color: TilePalette.purple)
    static let browsers = Tile(symbol: "globe", color: TilePalette.indigo)

    static let appearance = Tile(symbol: "circle.lefthalf.filled", color: TilePalette.gray)
    static let folder = Tile(symbol: "folder.fill", color: TilePalette.blue)
    static let menuBar = Tile(symbol: "menubar.arrow.down.rectangle", color: TilePalette.indigo)
    static let clipboard = Tile(symbol: "doc.on.clipboard", color: TilePalette.teal)
    static let notifications = Tile(symbol: "bell.badge.fill", color: TilePalette.red)
    static let concurrency = Tile(symbol: "square.stack.3d.down.right.fill", color: TilePalette.green)
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
    static let rename = Tile(symbol: "character.cursor.ibeam", color: TilePalette.pink)
    static let watchedFolders = Tile(symbol: "folder.badge.gearshape", color: TilePalette.pink)
    static let warning = Tile(symbol: "exclamationmark.triangle.fill", color: TilePalette.orange)
    static let history = Tile(symbol: "clock.arrow.circlepath", color: TilePalette.teal)
    static let localModel = Tile(symbol: "shippingbox.fill", color: TilePalette.gray)
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
        Image(systemName: tile.symbol)
            .font(.system(size: (size * 0.5).rounded(), weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tile.color.gradient, in: .rect(cornerRadius: size * 0.225, style: .continuous))
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
