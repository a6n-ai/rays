import SwiftUI

/// Search results or trending models as Downloads-style rows; a click or Return opens one.
struct ModelResultsList: View {
    let hits: [HfModel]
    var header: String?
    let open: (String) -> Void
    @State private var selection: String?

    var body: some View {
        List {
            Section {
                ForEach(hits, id: \.id) { hit in
                    ModelResultRow(hit: hit, isSelected: selection == hit.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selection = hit.id
                            open(hit.id)
                        }
                        .listRowInsets(EdgeInsets(
                            top: LayoutMetrics.rowSpacing / 2,
                            leading: LayoutMetrics.margin - LayoutMetrics.hoverInset,
                            bottom: LayoutMetrics.rowSpacing / 2,
                            trailing: LayoutMetrics.margin - LayoutMetrics.hoverInset))
                        .listRowSeparator(.hidden)
                }
            } header: {
                if let header { Text(header) }
            }
        }
        .listStyle(.inset)
        .tint(.gray)
        .scrollContentBackground(.hidden)
        .scrollEdgeEffectStyle(.soft, for: .all)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { step(-1) }
        .onKeyPress(.downArrow) { step(1) }
        .onKeyPress(.return) {
            guard let selection else { return .ignored }
            open(selection)
            return .handled
        }
    }

    private func step(_ delta: Int) -> KeyPress.Result {
        guard !hits.isEmpty else { return .ignored }
        let current = hits.firstIndex { $0.id == selection }
        let next = current.map { min(max($0 + delta, 0), hits.count - 1) } ?? (delta > 0 ? 0 : hits.count - 1)
        selection = hits[next].id
        return .handled
    }
}

private struct ModelResultRow: View {
    @Environment(EngineModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let hit: HfModel
    let isSelected: Bool
    @State private var isHovered = false

    private var name: String { hit.id.split(separator: "/", maxSplits: 1).last.map(String.init) ?? hit.id }
    private var org: String { hit.id.contains("/") ? String(hit.id.split(separator: "/")[0]) : "" }

    private var status: String {
        var parts: [String] = []
        if !org.isEmpty { parts.append(org) }
        if hit.gguf { parts.append("GGUF") }
        parts.append("↓ \(hit.downloads.formatted(.number.notation(.compactName)))")
        parts.append("♥ \(hit.likes.formatted(.number.notation(.compactName)))")
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: LayoutMetrics.gap) {
            Image(systemName: "cube.fill")
                .font(.system(size: LayoutMetrics.iconSize * 0.7))
                .foregroundStyle(.secondary)
                .frame(width: LayoutMetrics.iconSize, height: LayoutMetrics.iconSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(hit.id)
                HStack(spacing: 6) {
                    Text(status)
                    if hit.gated && !model.hasHFToken {
                        Image(systemName: "lock.fill").accessibilityLabel("Gated")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .frame(height: LayoutMetrics.rowHeight)
        .padding(.horizontal, LayoutMetrics.hoverInset)
        .listRowBackground(RowHighlight(selected: isSelected, hovered: isHovered))
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .smooth(duration: 0.15), value: isHovered)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
