import SwiftUI

/// Plain-language explanation of the browser helper, collapsed by default in Settings → Browsers.
struct HelperExplainer: View {
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 14) {
                flow
                    .padding(.top, 6)
                point("checkmark.shield.fill", TilePalette.green, "What it does",
                      "Lets the Rays extension hand a link to the Rays app when you choose Download with Rays.")
                point("eye.slash.fill", TilePalette.blue, "What it doesn't do",
                      "It doesn't read your browsing, run in the background, or talk to the internet. It only lets our extension reach Rays.")
                point("square.stack.fill", TilePalette.orange, "One click for every browser",
                      "Each browser keeps its own helper file. Install All Helpers writes them all at once; Firefox and Zen share one.")
                point(Tile.trash.symbol, Tile.trash.color, "Easy to remove",
                      "Each helper is one small file named ai.a6n.rays.json in the browser's NativeMessagingHosts folder. Delete it to undo.")
            }
            .padding(.vertical, 4)
        } label: {
            Label("How the helper works", systemImage: "questionmark.circle")
        }
    }

    /// Extension → Helper → Rays, the path a link takes.
    private var flow: some View {
        HStack(spacing: 8) {
            step(.browsers, "Extension", "You right-click a link")
            arrow
            step(Tile(symbol: "link", color: TilePalette.purple), "Helper", "Browser lets the link out")
            arrow
            step(.downloads, "Rays", "Download starts")
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("The extension sends the link through the helper to Rays, which starts the download.")
    }

    private var arrow: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.tertiary)
    }

    private func step(_ tile: Tile, _ title: String, _ caption: String) -> some View {
        VStack(spacing: 6) {
            IconTile(tile, size: 40)
            Text(title).font(.callout.weight(.semibold))
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private func point(_ symbol: String, _ color: Color, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            IconTile(Tile(symbol: symbol, color: color))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(text).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
