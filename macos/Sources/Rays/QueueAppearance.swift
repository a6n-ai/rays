import SwiftUI

/// A queue's symbol and colour, kept in the app (UserDefaults `queueAppearance.<id>`, JSON), never in the engine.
struct QueueAppearance: Codable, Equatable {
    var symbol: String
    var color: String
}

@Observable @MainActor final class QueueAppearances {
    static let shared = QueueAppearances()
    static let keyPrefix = "queueAppearance."
    /// Blue is Main's colour; the rest are handed to new queues in turn.
    static let cycle = ["orange", "purple", "teal", "pink", "green", "indigo", "red", "sky"]
    static let colors = ["blue"] + cycle
    static let symbols = ["tray.full.fill", "bolt.fill", "moon.stars.fill", "calendar", "clock.fill", "cube.fill",
                          "film.fill", "music.note", "photo.fill", "doc.fill", "shippingbox.fill", "externaldrive.fill",
                          "server.rack", "cloud.fill", "globe", "gamecontroller.fill", "book.fill", "briefcase.fill",
                          "hammer.fill", "leaf.fill", "flame.fill", "star.fill", "heart.fill", "airplane"]

    private var stored: [UInt64: QueueAppearance] = [:]
    private let defaults = UserDefaults.standard

    private init() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.keyPrefix) {
            guard let id = UInt64(key.dropFirst(Self.keyPrefix.count)), let data = defaults.data(forKey: key),
                  let value = try? JSONDecoder().decode(QueueAppearance.self, from: data) else {
                defaults.removeObject(forKey: key)
                continue
            }
            stored[id] = value
        }
    }

    static func color(named name: String) -> Color {
        switch name {
        case "orange": TilePalette.orange
        case "purple": TilePalette.purple
        case "teal": TilePalette.teal
        case "pink": TilePalette.pink
        case "green": TilePalette.green
        case "indigo": TilePalette.indigo
        case "red": TilePalette.red
        case "sky", "yellow": TilePalette.sky
        default: TilePalette.blue
        }
    }

    /// The chosen look, or the default: Main is a blue tray, others take the next colour by id and a symbol from their schedule.
    func appearance(for queue: QueueView) -> QueueAppearance {
        if let saved = stored[queue.id] { return saved }
        if queue.isMain { return QueueAppearance(symbol: "tray.full.fill", color: "blue") }
        let color = Self.cycle[((Int(queue.id) - 2) % Self.cycle.count + Self.cycle.count) % Self.cycle.count]
        let symbol: String
        if let start = queue.config.schedule?.startMin {
            symbol = start >= 20 * 60 || start < 6 * 60 ? "moon.stars.fill" : "calendar"
        } else {
            symbol = "bolt.fill"
        }
        return QueueAppearance(symbol: symbol, color: color)
    }

    func set(_ value: QueueAppearance, for id: UInt64) {
        stored[id] = value
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: Self.keyPrefix + String(id)) }
    }

    func setIfMissing(_ value: QueueAppearance, for id: UInt64) {
        if stored[id] == nil { set(value, for: id) }
    }

    func clear(_ id: UInt64) {
        stored[id] = nil
        defaults.removeObject(forKey: Self.keyPrefix + String(id))
    }
}

/// The queue's rounded tile, the same as the Models rows use.
struct QueueTile: View {
    let queue: QueueView
    var size: CGFloat = LayoutMetrics.iconSize

    var body: some View {
        let look = QueueAppearances.shared.appearance(for: queue)
        IconTile(Tile(symbol: look.symbol, color: QueueAppearances.color(named: look.color)), size: size)
    }
}

/// The Options row: the tile, opening a popover of colours and symbols. A choice saves at once, outside the draft.
struct QueueIconPicker: View {
    let queue: QueueView
    @State private var shown = false

    var body: some View {
        Button { shown = true } label: {
            HStack(spacing: 8) {
                QueueTile(queue: queue)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Choose an icon and colour")
        .accessibilityLabel("Icon and color")
        .popover(isPresented: $shown, arrowEdge: .bottom) { QueueIconPopover(queue: queue) }
    }
}

private struct QueueIconPopover: View {
    let queue: QueueView
    private let appearances = QueueAppearances.shared

    var body: some View {
        let current = appearances.appearance(for: queue)
        VStack(alignment: .leading, spacing: LayoutMetrics.gap) {
            HStack(spacing: 8) {
                ForEach(QueueAppearances.colors, id: \.self) { name in
                    let on = name == current.color
                    Button { appearances.set(QueueAppearance(symbol: current.symbol, color: name), for: queue.id) } label: {
                        Circle()
                            .fill(QueueAppearances.color(named: name).gradient)
                            .frame(width: 22, height: 22)
                            .padding(3)
                            .overlay { if on { Circle().strokeBorder(Color.primary, lineWidth: 2) } }
                            .frame(width: 28, height: 28)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(name.capitalized)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 6), count: 6), spacing: 6) {
                ForEach(QueueAppearances.symbols, id: \.self) { symbol in
                    let on = symbol == current.symbol
                    Button { appearances.set(QueueAppearance(symbol: symbol, color: current.color), for: queue.id) } label: {
                        Image(systemName: symbol)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(on ? Color.white : Color.primary)
                            .frame(width: 32, height: 32)
                            .background(on ? AnyShapeStyle(QueueAppearances.color(named: current.color).gradient) : AnyShapeStyle(.clear),
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(symbol.replacingOccurrences(of: ".fill", with: "").replacingOccurrences(of: ".", with: " "))
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
        .padding(LayoutMetrics.gap)
    }
}
