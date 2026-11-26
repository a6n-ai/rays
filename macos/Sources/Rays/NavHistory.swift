import SwiftUI

/// Back and forward over where you have been: sidebar destinations, and the drill-ins a page opens from one of its
/// cards (Speed's History, Downloads' Files). A page reads `sub` to know which view to show and calls `open` to drill in.
@MainActor @Observable
final class NavHistory {
    struct Entry: Hashable {
        var destination: Destination?
        var sub: String?
    }

    private var stack = [Entry(destination: .home, sub: nil)]
    private var index = 0
    private var fresh = true

    var current: Entry { stack[index] }
    var sub: String? { current.sub }
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index < stack.count - 1 }

    /// A sidebar selection. The first one, restoring the last page at launch, replaces the starting entry.
    func visit(_ destination: Destination?) {
        let entry = Entry(destination: destination, sub: nil)
        if fresh {
            fresh = false
            stack = [entry]
            index = 0
        } else if entry != current {
            push(entry)
        }
    }

    func open(_ sub: String) {
        fresh = false
        push(Entry(destination: current.destination, sub: sub))
    }

    /// Swaps the current drill-in without adding history, for a queue that was just deleted.
    func replaceSub(_ sub: String?) { stack[index].sub = sub }

    func goBack() -> Entry? { move(-1) }
    func goForward() -> Entry? { move(1) }

    private func push(_ entry: Entry) {
        stack = Array(stack[...index]) + [entry]
        index += 1
    }

    private func move(_ step: Int) -> Entry? {
        let target = index + step
        guard stack.indices.contains(target) else { return nil }
        index = target
        return current
    }
}

/// Back and forward as one glass capsule, ⌘[ and ⌘], disabled when there is nowhere to go.
struct NavButtons: View {
    @Environment(NavHistory.self) private var nav
    let go: (NavHistory.Entry) -> Void

    var body: some View {
        ToolbarIconGroup {
            Button {
                if let entry = nav.goBack() { go(entry) }
            } label: {
                ToolbarIcon(symbol: "chevron.left", title: "Back")
            }
            .buttonStyle(.plain)
            .disabled(!nav.canGoBack)
            .keyboardShortcut("[", modifiers: .command)
            .help("Back")
            Button {
                if let entry = nav.goForward() { go(entry) }
            } label: {
                ToolbarIcon(symbol: "chevron.right", title: "Forward")
            }
            .buttonStyle(.plain)
            .disabled(!nav.canGoForward)
            .keyboardShortcut("]", modifiers: .command)
            .help("Forward")
        }
    }
}

/// The primary-action row of a hero: up to two buttons and one ••• menu, small like System Settings' "Details…".
struct HeroActions<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 8) { content }
            .buttonStyle(.glass)
            .controlSize(.small)
    }
}

/// The overflow ••• menu of a hero.
struct HeroMenu<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Menu { content } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .font(.title3)
            .foregroundStyle(.secondary)
            .fixedSize()
            .accessibilityLabel("More")
    }
}

/// A card row that drills in: tile, title, one-line summary and a chevron.
struct DrillInRow: View {
    let tile: Tile
    let title: String
    var subtitle: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            CardRow(title: title, subtitle: subtitle, leading: { IconTile(tile, size: TileSize.list) }, trailing: { CardChevron() })
        }
        .buttonStyle(.plain)
    }
}

/// A slim row above a drilled-in view for its view options (layout, refresh), where the toolbar used to hold them.
struct ViewBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 10) {
            Spacer()
            content
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, LayoutMetrics.margin)
        .padding(.vertical, 6)
    }
}
