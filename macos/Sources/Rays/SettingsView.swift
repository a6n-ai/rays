import AppKit
import SwiftUI

struct SettingsView: View {
    @AppStorage("settingsTab") private var tab = "general"
    @State private var sorter = SorterModel()

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: "general") {
                GeneralTab(sorter: sorter)
            }
            Tab("Downloads", systemImage: "arrow.down.circle", value: "downloads") {
                DownloadsTab()
            }
            Tab("Sorting", systemImage: "sparkles", value: "sorting") {
                SortingTab(sorter: sorter)
            }
            Tab("Browsers", systemImage: "globe", value: "browsers") {
                BrowsersTab()
            }
        }
        .containerBackground(.thinMaterial, for: .window)
        .frame(width: 520)
    }
}

struct SettingIcon: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(color, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct SettingRow<Control: View>: View {
    let symbol: String
    let color: Color
    let title: String
    let hint: String
    @ViewBuilder let control: Control

    init(symbol: String, color: Color, title: String, hint: String, @ViewBuilder control: () -> Control) {
        self.symbol = symbol
        self.color = color
        self.title = title
        self.hint = hint
        self.control = control()
    }

    var body: some View {
        LabeledContent {
            control
        } label: {
            HStack(spacing: 10) {
                SettingIcon(symbol: symbol, color: color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(hint)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct GeneralTab: View {
    @Environment(EngineModel.self) private var model
    @AppStorage(AppearanceChoice.key) private var appearance = AppearanceChoice.system
    @AppStorage(SettingsKey.downloadsDir) private var customFolder = ""
    @AppStorage(SettingsKey.sorterPath) private var sorterPath = Sorter.defaultPath
    let sorter: SorterModel
    @State private var folderError: String?

    private var folder: URL { EngineModel.downloadsURL }

    var body: some View {
        Form {
            Section {
                SettingRow(symbol: "circle.lefthalf.filled", color: Color(nsColor: .systemGray),
                           title: "Appearance", hint: "Match your Mac, or always light or dark.") {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(AppearanceChoice.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }

                SettingRow(symbol: "folder.fill", color: .blue,
                           title: "Save downloads to", hint: "New downloads go here.") {
                    HStack(spacing: 8) {
                        Text(folder.tildePath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(folder.path(percentEncoded: false))
                        Button("Change…", action: chooseFolder)
                            .buttonStyle(.glass)
                            .accessibilityLabel("Choose download folder")
                        Button("Reset") { change(to: nil) }
                            .buttonStyle(.glass)
                            .disabled(customFolder.isEmpty)
                            .help("Use the Downloads folder")
                    }
                }
                if let folderError {
                    ErrorLine(text: folderError)
                }
            }

            CommandLineSection()

            UpdateSettingsSection()

            UninstallSection()

            SavedNote()
        }
        .scrollContentBackground(.hidden)
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.directoryURL = folder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        change(to: url)
    }

    private func change(to url: URL?) {
        let old = folder
        do {
            try model.setDownloadsDir(url)
        } catch {
            folderError = EngineModel.message(for: error)
            return
        }
        folderError = nil
        Task { await sorter.moveWatch(from: old, sorterPath: sorterPath) }
    }
}

private struct DownloadsTab: View {
    @Environment(EngineModel.self) private var model
    @AppStorage(SettingsKey.maxRunning) private var maxRunning = 3
    @AppStorage(SettingsKey.connections) private var connections = 4
    @AppStorage(SettingsKey.speedLimit) private var speedLimit = 0
    @State private var customMode = false
    @State private var customMB = 0.0

    /// Sentinel tag for the Custom… row; presets are tagged with their byte counts.
    private let customTag = -1

    private var showsCustom: Bool {
        customMode || !SpeedPreset.all.contains { $0.bytes == speedLimit }
    }

    var body: some View {
        Form {
            Section {
                SettingRow(symbol: "square.stack.3d.down.right.fill", color: .green,
                           title: "Downloads at once", hint: "How many files download at the same time.") {
                    Picker("Downloads at once", selection: Binding(get: { maxRunning }, set: { model.setMaxRunning($0) })) {
                        ForEach(1...10, id: \.self) { Text($0 == 3 ? "3 (Recommended)" : "\($0)").tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }

                SettingRow(symbol: "point.3.connected.trianglepath.dotted", color: .purple,
                           title: "Parts per file", hint: "Big files download in parts at once. 4 works well for most sites.") {
                    Picker("Parts per file", selection: Binding(get: { connections }, set: { model.setConnections($0) })) {
                        ForEach(1...16, id: \.self) { Text($0 == 4 ? "4 (Recommended)" : "\($0)").tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }

            Section {
                SettingRow(symbol: "hare.fill", color: .orange,
                           title: "Speed limit", hint: "Leave some internet for everything else on your Mac.") {
                    Picker("Speed limit", selection: limitSelection) {
                        ForEach(SpeedPreset.all) { Text($0.title).tag($0.bytes) }
                        Text("Custom…").tag(customTag)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if showsCustom {
                    LabeledContent("Custom limit") {
                        HStack(spacing: 6) {
                            TextField("MB/s", value: $customMB, format: .number)
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                                .onChange(of: customMB) { _, mb in model.setSpeedLimit(Int(max(0, mb) * 1_000_000)) }
                            Text("MB/s").foregroundStyle(.secondary)
                        }
                    }
                }
            }

            SavedNote()
        }
        .scrollContentBackground(.hidden)
        .formStyle(.grouped)
        .onAppear { customMB = Double(speedLimit) / 1_000_000 }
    }

    private var limitSelection: Binding<Int> {
        Binding(
            get: { showsCustom ? customTag : speedLimit },
            set: { value in
                if value == customTag {
                    customMode = true
                    customMB = max(customMB, 1)
                    model.setSpeedLimit(Int(customMB * 1_000_000))
                } else {
                    customMode = false
                    model.setSpeedLimit(value)
                }
            })
    }
}

struct SavedNote: View {
    var body: some View {
        Section {
            Text("Changes save automatically.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ErrorLine: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.red)
    }
}

extension URL {
    var tildePath: String { (path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath }
}
