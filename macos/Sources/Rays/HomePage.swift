import SwiftUI

/// The landing page, after System Settings > General: a centred hero, then cards of drill-in rows.
struct HomePage: View {
    @Environment(EngineModel.self) private var model
    @Binding var selection: Destination?
    private var updater: Updater { .shared }
    private static let docs = URL(string: "https://rays.a6n.ai/docs")!

    private struct Item: Identifiable {
        let id: String
        let tile: Tile
        var subtitle: String?
        let action: () -> Void
    }

    var body: some View {
        List {
            Section {
                HeroCard(.downloads, title: "Rays",
                         subtitle: "Downloads files fast, sorts them, and runs them on your schedule.",
                         learnMore: Self.docs, style: .home)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            card(files)
            card(automation)
            card(tools)
            card(app)
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    private func go(_ id: String, _ tile: Tile, _ destination: Destination, _ subtitle: String? = nil) -> Item {
        Item(id: id, tile: tile, subtitle: subtitle) { selection = destination }
    }

    private var files: [Item] {
        let active = model.jobs.filter(\.isActive).count
        return [
            go("Downloads", .downloads, .downloads, active > 0 ? "\(active) downloading" : nil),
            go("Models", .models, .models),
            go("Sorter", .sorter, .sorter),
            go("Cloud", .cloud, .cloud),
        ]
    }

    private var automation: [Item] {
        let running = model.queues.filter { $0.running > 0 }.count
        return [
            go("Queues", .queues, .queues, running > 0 ? "\(running) \(running == 1 ? "queue" : "queues") running" : nil),
            go("Schedules", .schedules, .schedules),
        ]
    }

    private var tools: [Item] {
        let speed = model.lastTest.map { "Last test \(SpeedFormat.mbps($0.bps, whole: true))" }
        return [go("Speed test", .speed, .speed, speed), go("Stats", .stats, .stats), go("Shortcuts", .shortcuts, .shortcuts)]
    }

    private var app: [Item] {
        let state: String? = switch updater.status {
        case .upToDate: "Up to date"
        case .checking: "Checking for updates"
        case .available(let release): "Version \(release.version) is available"
        default: nil
        }
        let version = ["Version \(updater.current)", state].compactMap { $0 }.joined(separator: " · ")
        return [
            go("General", .general, .general),
            Item(id: "About Rays", tile: .updates, subtitle: version) { NSApp.orderFrontStandardAboutPanel(nil) },
            Item(id: "Docs", tile: .browsers, subtitle: "rays.a6n.ai/docs") { NSWorkspace.shared.open(Self.docs) },
        ]
    }

    private func card(_ items: [Item]) -> some View {
        Section {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                Button(action: item.action) {
                    CardRow(title: item.id, subtitle: item.subtitle) {
                        IconTile(item.tile, size: TileSize.row)
                    } trailing: {
                        CardChevron()
                    }
                }
                .buttonStyle(.plain)
                .cardRow(CardRowBackground.position(index, of: items.count))
            }
        }
    }
}
