import SwiftUI

/// A trending model as a plain card; the kind tile and capsule carry the only colour.
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
                IconTile(kind.tile, size: TileSize.row)
                VStack(alignment: .leading, spacing: 1) {
                    Text(parts.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !parts.org.isEmpty {
                        Text(parts.org).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            HStack(spacing: 6) {
                ModelCapsule(text: kind.label, tint: kind.color)
                if hit.gguf { ModelCapsule(text: "GGUF") }
                Spacer(minLength: 4)
                Text("↓ \(hit.downloads.formatted(.number.notation(.compactName))) · ♥ \(hit.likes.formatted(.number.notation(.compactName)))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 10, style: .continuous))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(kind.color, lineWidth: 2)
            }
        }
        .scaleEffect(isHovered ? 1.02 : 1)
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: isHovered)
        .onHover { isHovered = $0 }
        .contentShape(.rect(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(parts.name), \(parts.org), \(kind.label)")
        .accessibilityAddTraits(.isButton)
    }
}

/// One compact control row: the kind as a small menu and a GGUF checkbox; they filter whatever list is loaded.
struct ModelFilterBar: View {
    @Binding var filter: ModelFilter
    @Binding var ggufOnly: Bool

    var body: some View {
        HStack(spacing: 10) {
            Picker("Kind", selection: $filter) {
                ForEach(ModelFilter.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            Toggle("GGUF", isOn: $ggufOnly)
                .toggleStyle(.checkbox)
        }
        .controlSize(.small)
    }
}
