import SwiftUI

/// Glass pill under the update pill after a removal: Undo for 6 seconds (longer while the pointer is on it).
struct RemovalPillView: View {
    @Environment(EngineModel.self) private var model
    @State private var hovering = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if let pill = model.removalPill {
            // Colour says what happened: orange for the Trash, blue for a row taken off the list (green is updates, red is errors).
            let tint: Color = pill.trash ? .orange : .blue
            HStack(spacing: 10) {
                Image(systemName: pill.trash ? "trash.fill" : "minus.circle.fill").foregroundStyle(tint)
                // One line: a long file name is shortened in the middle, so the pill never grows to several lines.
                Text(pill.text).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Button("Undo") { model.undoRemoval() }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule)
                    .tint(tint)
                    .controlSize(.small)
                    .help("Undo (\u{2318}Z)")
                Text("\u{2318}Z").font(.subheadline).foregroundStyle(.secondary)
                Button { model.commitRemoval() } label: {
                    Image(systemName: "xmark").font(.subheadline.weight(.bold)).foregroundStyle(.secondary)
                        .frame(width: 20, height: 20).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Dismiss")
                .accessibilityLabel("Dismiss removal notice")
            }
            .frame(maxWidth: 560)
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.vertical, 6)
            .glassEffect(reduceTransparency ? .regular : .regular.tint(tint.opacity(0.18)), in: .capsule)
            .padding(.top, 8)
            .onHover { hovering = $0 }
            .task(id: pill.token) {
                try? await Task.sleep(for: .seconds(6))
                while hovering, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(500)) }
                if !Task.isCancelled { model.commitRemoval() }
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
