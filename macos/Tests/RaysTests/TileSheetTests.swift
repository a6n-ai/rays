import AppKit
import SwiftUI
import Testing
@testable import Rays

/// Renders every Tile in the map to a contact sheet PNG for visual review. Writes only when RAYS_TILE_SHEET is set.
@MainActor @Test func tileSheet() throws {
    guard let out = ProcessInfo.processInfo.environment["RAYS_TILE_SHEET"] else { return }
    let tiles: [(String, Tile)] = [("downloads", Tile.downloads), ("models", Tile.models), ("sorter", Tile.sorter), ("cloud", Tile.cloud), ("queues", Tile.queues), ("schedules", Tile.schedules), ("speed", Tile.speed), ("stats", Tile.stats), ("shortcuts", Tile.shortcuts), ("general", Tile.general), ("ai", Tile.ai), ("browsers", Tile.browsers), ("appearance", Tile.appearance), ("folder", Tile.folder), ("menuBar", Tile.menuBar), ("clipboard", Tile.clipboard), ("notifications", Tile.notifications), ("concurrency", Tile.concurrency), ("parts", Tile.parts), ("speedLimit", Tile.speedLimit), ("duplicates", Tile.duplicates), ("modelsFolder", Tile.modelsFolder), ("commandLine", Tile.commandLine), ("updates", Tile.updates), ("unpack", Tile.unpack), ("trash", Tile.trash), ("wake", Tile.wake), ("sortDelay", Tile.sortDelay), ("rename", Tile.rename), ("watchedFolders", Tile.watchedFolders), ("warning", Tile.warning), ("history", Tile.history), ("localModel", Tile.localModel)]
    for scheme in [ColorScheme.light, .dark] {
        let sheet = VStack(alignment: .leading, spacing: 6) {
            ForEach(tiles, id: \.0) { name, tile in
                HStack(spacing: 14) {
                    IconTile(tile, size: 20)
                    IconTile(tile, size: 28)
                    IconTile(tile, size: 64)
                    Text("\(name)  \(tile.symbol)  ×\(String(format: "%.2f", tile.glyphScale))").font(.system(size: 13))
                }
            }
        }
        .padding(16)
        .background(scheme == .light ? Color(white: 0.93) : Color(white: 0.15))
        .environment(\.colorScheme, scheme)
        let r = ImageRenderer(content: sheet)
        r.scale = 2
        let image = try #require(r.nsImage)
        let rep = NSBitmapImageRep(data: try #require(image.tiffRepresentation))
        try #require(rep?.representation(using: .png, properties: [:])).write(to: URL(filePath: out + "-\(scheme == .light ? "light" : "dark").png"))
    }
}
