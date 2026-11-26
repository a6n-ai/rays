import SwiftUI

/// A trending model as a tinted glass card.
struct ModelCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let hit: HfModel
    let isSelected: Bool
    @State private var isHovered = false

    private var kind: ModelKind { ModelKind(pipelineTag: hit.pipelineTag) }
    private var parts: (org: String, name: String) { hfNameParts(hit.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                IconTile(kind.tile, size: TileSize.list)
                VStack(alignment: .leading, spacing: 1) {
                    Text(parts.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !parts.org.isEmpty {
                        Text(parts.org).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            HStack(spacing: 6) {
                ModelCapsule(text: kind.label, tint: kind.color)
                if hit.gguf { ModelCapsule(text: "GGUF") }
                Spacer(minLength: 4)
                Text("↓ \(hit.downloads.formatted(.number.notation(.compactName))) · ♥ \(hit.likes.formatted(.number.notation(.compactName)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(10)
        .glassEffect(.regular.tint(kind.color.opacity(0.18)), in: .rect(cornerRadius: 14))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 14).strokeBorder(kind.color, lineWidth: 2)
            }
        }
        .scaleEffect(isHovered ? 1.02 : 1)
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: isHovered)
        .onHover { isHovered = $0 }
        .contentShape(.rect(cornerRadius: 14))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(parts.name), \(parts.org), \(kind.label)")
        .accessibilityAddTraits(.isButton)
    }
}

/// Kind chips plus a separate GGUF toggle; they filter whatever list is loaded.
struct ModelFilterBar: View {
    @Binding var filter: ModelFilter
    @Binding var ggufOnly: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(ModelFilter.allCases, id: \.self) { item in
                        chip(item.label, tint: item.color, on: filter == item) { filter = item }
                    }
                    Divider().frame(height: 16)
                    chip("GGUF only", tint: .accentColor, on: ggufOnly) { ggufOnly.toggle() }
                }
            }
        }
        .scrollClipDisabled()
        .padding(.horizontal, 12)
    }

    private func chip(_ title: String, tint: Color, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .glassEffect(on ? .regular.tint(tint) : .regular, in: .capsule)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
