import SwiftUI

/// App-wide settings as sidebar pages, after System Settings > General.
struct GeneralPage: View {
    @AppStorage(SettingsKey.menuBar) private var showsMenuBar = true
    @AppStorage(SidebarIconSize.key) private var iconSize = SidebarIconSize.medium

    var body: some View {
        Form {
            Section {
                HeroCard(.general, title: "General", subtitle: "Appearance, menu bar, updates and the command line tool.",
                         style: .centered)
            }
            Section {
                SettingRow(title: "Appearance") { AppearancePicker() }
                SettingRow(title: "Accent colour") { AccentPicker() }
                SettingRow(title: "Sidebar icon size") {
                    RadioChoice(title: "Sidebar icon size", selection: $iconSize, choices: SidebarIconSize.allCases) { Text($0.title) }
                }
            }
            Section {
                SettingRow(title: "Show in menu bar", hint: "Closing the window keeps Rays running.") {
                    Toggle("Show in menu bar", isOn: $showsMenuBar).labelsHidden()
                }
            }
            CommandLineSection()
            UpdateSettingsSection()
            UninstallSection()
        }
        .formStyle(.grouped)
        .navigationTitle("General")
    }
}

struct AIPage: View {
    var body: some View {
        Form {
            Section {
                HeroCard(.ai, title: "AI", subtitle: "Apple Intelligence on this Mac sorts and renames your files.")
            }
            Section { AIStatusRow() }
        }
        .formStyle(.grouped)
        .navigationTitle("AI")
    }
}

/// Auto, Light and Dark as small window pictures with a selection ring, like System Settings > Appearance.
private struct AppearancePicker: View {
    @AppStorage(AppearanceChoice.key) private var appearance = AppearanceChoice.system

    var body: some View {
        HStack(spacing: 10) {
            ForEach(AppearanceChoice.allCases) { choice in
                let selected = appearance == choice
                Button { appearance = choice } label: {
                    VStack(spacing: 4) {
                        AppearanceThumbnail(choice: choice)
                            .frame(width: 64, height: 44)
                            .padding(3)
                            .overlay {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(Color.accentColor, lineWidth: 2.5)
                                    .opacity(selected ? 1 : 0)
                            }
                        Text(choice.title).font(.subheadline)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(choice.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

private struct AppearanceThumbnail: View {
    let choice: AppearanceChoice

    var body: some View {
        ZStack {
            scene(dark: false)
            if choice == .dark {
                scene(dark: true)
            } else if choice == .system {
                scene(dark: true).mask { HStack(spacing: 0) { Color.clear; Color.black } }
            }
        }
        .clipShape(.rect(cornerRadius: 6, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.primary.opacity(0.18), lineWidth: 0.5) }
    }

    /// A desktop with a small window: title bar dots, a sidebar strip and content.
    private func scene(dark: Bool) -> some View {
        ZStack {
            LinearGradient(colors: dark ? [Color(red: 0.10, green: 0.14, blue: 0.32), Color(red: 0.36, green: 0.16, blue: 0.40)]
                                        : [Color(red: 0.36, green: 0.62, blue: 0.95), Color(red: 0.76, green: 0.58, blue: 0.92)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 0) {
                HStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { _ in Circle().fill(.gray.opacity(0.7)).frame(width: 3, height: 3) }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 3)
                .frame(height: 8)
                .background(dark ? Color(white: 0.22) : Color(white: 0.90))
                HStack(spacing: 0) {
                    Rectangle().fill(dark ? Color(white: 0.17) : Color(white: 0.94)).frame(width: 14)
                    Rectangle().fill(dark ? Color(white: 0.11) : Color.white)
                }
            }
            .frame(width: 44, height: 28)
            .clipShape(.rect(cornerRadius: 3, style: .continuous))
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
        }
    }
}

/// Round swatches with the chosen name under them. Multicolour follows the system accent.
private struct AccentPicker: View {
    @AppStorage(AccentChoice.key) private var choice = AccentChoice.multicolor

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                ForEach(AccentChoice.allCases) { accent in
                    let selected = choice == accent
                    Button { choice = accent } label: {
                        swatch(accent)
                            .frame(width: 18, height: 18)
                            .padding(3)
                            .overlay {
                                Circle().strokeBorder(accent.color ?? .secondary, lineWidth: 2).opacity(selected ? 1 : 0)
                            }
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .help(accent.title)
                    .accessibilityLabel(accent.title)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            Text(choice.title).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func swatch(_ accent: AccentChoice) -> some View {
        if let color = accent.color {
            Circle().fill(color.gradient)
        } else {
            Circle().fill(AngularGradient(colors: [TilePalette.red, TilePalette.orange, AccentChoice.yellow.color ?? .yellow,
                                                   TilePalette.green, TilePalette.blue, TilePalette.purple, TilePalette.red],
                                          center: .center))
        }
    }
}
