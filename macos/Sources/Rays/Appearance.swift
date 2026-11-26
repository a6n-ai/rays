import AppKit
import SwiftUI

enum AppearanceChoice: String, CaseIterable, Identifiable {
    case system, light, dark

    static let key = "appearance"

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "Auto"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// nil follows the system, so the app tracks the Mac's setting.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// The accent colour of controls, selection and links. Multicolour follows the system setting.
enum AccentChoice: String, CaseIterable, Identifiable {
    case multicolor, blue, purple, pink, red, orange, yellow, green, graphite

    static let key = "accentChoice"

    var id: Self { self }

    var title: String { self == .multicolor ? "Multicolour" : rawValue.capitalized }

    /// nil leaves the system accent in place.
    var color: Color? {
        switch self {
        case .multicolor: nil
        case .blue: TilePalette.blue
        case .purple: TilePalette.purple
        case .pink: TilePalette.pink
        case .red: TilePalette.red
        case .orange: TilePalette.orange
        case .yellow: Color(red: 0.98, green: 0.76, blue: 0.05)
        case .green: TilePalette.green
        case .graphite: TilePalette.gray
        }
    }
}

extension View {
    /// Applies the chosen accent colour; used on the main window and the menu bar panel.
    func accentChoice() -> some View { modifier(AccentChoiceModifier()) }
}

private struct AccentChoiceModifier: ViewModifier {
    @AppStorage(AccentChoice.key) private var choice = AccentChoice.multicolor

    func body(content: Content) -> some View { content.tint(choice.color) }
}

/// Sidebar icon size, like System Settings > Appearance: scales the tiles and the row text.
enum SidebarIconSize: String, CaseIterable, Identifiable {
    case small, medium, large

    static let key = "sidebarIconSize"

    var id: Self { self }

    var title: String { rawValue.capitalized }

    var tile: CGFloat {
        switch self {
        case .small: 16
        case .medium: TileSize.sidebar
        case .large: 24
        }
    }

    var rowSize: SidebarRowSize {
        switch self {
        case .small: .small
        case .medium: .medium
        case .large: .large
        }
    }
}
