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
        VStack(alignment: .leading, spacing: 8) {
            ModelTile(kind: kind, size: 44)
            Text(parts.name)
                .font(.body.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if !parts.org.isEmpty {
                Text(parts.org).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 6) {
                ModelCapsule(text: kind.label, tint: kind.color)
                if hit.gguf { ModelCapsule(text: "GGUF") }
            }
            Spacer(minLength: 0)
            Text("↓ \(hit.downloads.formatted(.number.notation(.compactName))) · ♥ \(hit.likes.formatted(.number.notation(.compactName)))")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
        .padding(14)
        .glassEffect(.regular.tint(kind.color.opacity(0.18)).interactive(), in: .rect(cornerRadius: 18))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 18).strokeBorder(kind.color, lineWidth: 2)
            }
        }
        .scaleEffect(isHovered ? 1.02 : 1)
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: isHovered)
        .onHover { isHovered = $0 }
        .contentShape(.rect(cornerRadius: 18))
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
        .padding(.horizontal, LayoutMetrics.margin)
        .padding(.bottom, 8)
    }

    private func chip(_ title: String, tint: Color, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .glassEffect(on ? .regular.tint(tint).interactive() : .regular.interactive(), in: .capsule)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
