import SwiftUI

/// Glass pill under the update pill after a removal: Undo for 6 seconds (longer while the pointer is on it).
struct RemovalPillView: View {
    @Environment(EngineModel.self) private var model
    @State private var hovering = false

    var body: some View {
        if let pill = model.removalPill {
            HStack(spacing: 10) {
                Image(systemName: "trash.fill").foregroundStyle(.secondary)
                Text(pill.text).font(.callout.weight(.medium))
                Button("Undo") { model.undoRemoval() }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .help("Undo (\u{2318}Z)")
                Text("\u{2318}Z").font(.caption).foregroundStyle(.secondary)
                Button { model.commitRemoval() } label: {
                    Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                        .frame(width: 20, height: 20).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Dismiss")
                .accessibilityLabel("Dismiss removal notice")
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.vertical, 6)
            .glassEffect(.regular, in: .capsule)
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
