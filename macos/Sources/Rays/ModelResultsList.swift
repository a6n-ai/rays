import SwiftUI

/// The sections of the Models search page's List: trending models as cards under Top models, then a card of rows.
/// The page owns the List, the selection, the paging and the key handling.
struct ModelResultsList: View {
    let cards: ArraySlice<HfModel>
    let rows: ArraySlice<HfModel>
    let selection: String?
    let choose: (String) -> Void

    private static let cardLimit = 6

    /// The first few hits shown as cards, for the trending list only.
    static func cards(_ hits: [HfModel], featured: Bool) -> ArraySlice<HfModel> {
        featured ? hits.prefix(cardLimit) : []
    }

    var body: some View {
        if !cards.isEmpty {
            Section("Top models") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 10)], spacing: 10) {
                    ForEach(cards, id: \.id) { hit in
                        ModelCard(hit: hit, isSelected: selection == hit.id)
                            .onTapGesture { choose(hit.id) }
                    }
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 4, bottom: 6, trailing: 4))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        }
        if !rows.isEmpty {
            Section {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, hit in
                    ModelResultRow(hit: hit, position: CardRowBackground.position(index, of: rows.count), isSelected: selection == hit.id)
                        .onTapGesture { choose(hit.id) }
                }
            } header: {
                if !cards.isEmpty { Text("More trending") }
            }
        }
    }
}

private struct ModelResultRow: View {
    @Environment(EngineModel.self) private var model
    let hit: HfModel
    let position: CardRowBackground.Position
    let isSelected: Bool
    @State private var isHovered = false

    private var name: String { hit.id.split(separator: "/", maxSplits: 1).last.map(String.init) ?? hit.id }
    private var org: String { hit.id.contains("/") ? String(hit.id.split(separator: "/")[0]) : "" }

    private var status: String {
        var parts: [String] = []
        if !org.isEmpty { parts.append(org) }
        if hit.gguf { parts.append("GGUF") }
        if hit.gated && !model.hasHFToken { parts.append("Gated") }
        parts.append("↓ \(hit.downloads.formatted(.number.notation(.compactName)))")
        parts.append("♥ \(hit.likes.formatted(.number.notation(.compactName)))")
        return parts.joined(separator: " · ")
    }

    var body: some View {
        CardRow(title: name, subtitle: status) {
            IconTile(ModelKind(pipelineTag: hit.pipelineTag).tile, size: TileSize.list)
        } trailing: {
            CardChevron()
        }
        .help(hit.id)
        .cardRow(position, selected: isSelected, hovered: isHovered)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
