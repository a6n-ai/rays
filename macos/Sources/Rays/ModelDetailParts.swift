import SwiftUI
import UniformTypeIdentifiers

/// Org and model name of a Hugging Face repo id like `org/name`.
func hfNameParts(_ id: String) -> (org: String, name: String) {
    let parts = id.split(separator: "/", maxSplits: 1).map(String.init)
    return parts.count == 2 ? (parts[0], parts[1]) : ("", id)
}

struct ModelHeaderCard: View {
    let repo: HfRepo
    let isGGUF: Bool
    let total: UInt64
    let freeBytes: UInt64?

    private var kind: ModelKind { ModelKind(pipelineTag: repo.pipelineTag) }
    private var fits: Bool { freeBytes.map { total <= $0 } ?? true }

    private var subtitle: String {
        let parts = hfNameParts(repo.id)
        var items: [String] = []
        if !parts.org.isEmpty { items.append(parts.org) }
        items.append("↓ \(repo.downloads.formatted(.number.notation(.compactName)))")
        items.append("♥ \(repo.likes.formatted(.number.notation(.compactName)))")
        return items.joined(separator: " · ")
    }

    private var caption: String {
        [kind.label, isGGUF ? "GGUF" : nil, repo.gated ? "Gated" : nil].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        HeroCard(kind.tile, title: hfNameParts(repo.id).name, subtitle: subtitle, caption: caption) {
            VStack(alignment: .trailing, spacing: 6) {
                Text(byteText(total))
                    .font(.title3.weight(.semibold).monospaced())
                    .foregroundStyle(fits ? Color.primary : Color.red)
                if let freeBytes {
                    Capsule()
                        .fill(.primary.opacity(0.1))
                        .frame(width: 120, height: 4)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(fits ? Color.accentColor : Color.red)
                                .frame(width: 120 * min(1, freeBytes == 0 ? 1 : Double(total) / Double(freeBytes)))
                        }
                    Text("\(byteText(freeBytes)) free").font(.subheadline).foregroundStyle(.secondary)
                }
                if let url = URL(string: "https://huggingface.co/\(repo.id)") {
                    Button("Open on Hugging Face") { NSWorkspace.shared.open(url) }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .help("Open \(repo.id) on Hugging Face")
                }
            }
        }
    }
}

struct ModelVersionPills: View {
    let versions: [HfVersion]
    let tint: Color
    @Binding var selected: Set<String>
    @Namespace private var pills
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(versions, id: \.label) { version in
                        let on = Set(version.files) == selected
                        Button {
                            withAnimation(reduceMotion ? nil : .smooth) { selected = Set(version.files) }
                        } label: {
                            Text("\(version.label)\(version.recommended ? " ★" : "")  \(byteText(version.size))")
                                .font(.callout)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(on ? .regular.tint(tint).interactive() : .regular.interactive(), in: .capsule)
                        .glassEffectID(version.label, in: pills)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
        }
        .scrollClipDisabled()
    }
}

struct ModelFileRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let file: HfFile
    @Binding var isOn: Bool
    let note: (text: String, isError: Bool)?
    @State private var isHovered = false

    private var icon: NSImage {
        NSWorkspace.shared.icon(for: UTType(filenameExtension: URL(filePath: file.path).pathExtension) ?? .data)
    }

    var body: some View {
        HStack(spacing: LayoutMetrics.gap) {
            Toggle(file.path, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.checkbox)
            Image(nsImage: icon)
                .resizable()
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(file.path)
                if let note {
                    Text(note.text)
                        .font(.callout)
                        .foregroundStyle(note.isError ? Color.red : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(byteText(file.size)).foregroundStyle(.secondary).monospacedDigit()
        }
        .frame(minHeight: 40)
        .padding(.horizontal, LayoutMetrics.hoverInset)
        .contentShape(Rectangle())
        .onTapGesture { isOn.toggle() }
        .listRowBackground(RowHighlight(selected: false, hovered: isHovered))
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .smooth(duration: 0.15), value: isHovered)
    }
}
