import SwiftUI

/// A provider's badge: an SF Symbol on the brand's color, in the same tile as Settings rows.
/// SF Symbols has no brand logos, so each provider gets a fitting symbol in its brand color.
struct ProviderIcon: View {
    let provider: String

    var body: some View {
        let (symbol, color) = Self.style(provider)
        IconTile(Tile(symbol: symbol, color: color))
    }

    static func style(_ provider: String) -> (String, Color) {
        switch provider {
        case "aws": ("shippingbox.fill", Color(hex: 0xC96A00))
        case "r2": ("cloud.fill", Color(hex: 0xF38020))
        case "b2": ("flame.fill", Color(hex: 0xE21E29))
        case "wasabi": ("leaf.fill", Color(hex: 0x2A8F37))
        case "spaces": ("drop.fill", Color(hex: 0x0080FF))
        case "gcs": ("g.circle.fill", Color(hex: 0x4285F4))
        case "hetzner": ("h.square.fill", Color(hex: 0xD50C2D))
        case "linode": ("server.rack", Color(hex: 0x00B159))
        case "scaleway": ("s.circle.fill", Color(hex: 0x4F0599))
        case "ovh": ("o.circle.fill", Color(hex: 0x123F6D))
        case "oracle": ("o.square.fill", Color(hex: 0xC74634))
        case "alibaba": ("a.square.fill", Color(hex: 0xFF6A00))
        case "supabase": ("bolt.fill", Color(hex: 0x178A5C))
        case "tigris": ("pawprint.fill", Color(hex: 0x6F4EF2))
        case "minio": ("m.circle.fill", Color(hex: 0xC72E49))
        default: ("externaldrive.fill", Color(nsColor: .systemGray))
        }
    }
}

/// A cloud row laid out like the Sorter's folder rows: badge, name, a status line, then small icon buttons.
struct CloudRow<Trailing: View>: View {
    let provider: String
    let title: String
    let detail: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            ProviderIcon(provider: provider)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1).truncationMode(.middle)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            trailing
        }
    }
}

/// The Sorter's small row button: a tinted glyph, borderless, with help and an accessibility label.
struct RowIcon: View {
    let symbol: String
    let label: String
    let tint: Color
    let action: () -> Void

    init(_ symbol: String, _ label: String, tint: Color, action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
