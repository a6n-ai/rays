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

private struct GeneralTab: View {
    @AppStorage(AppearanceChoice.key) private var appearance = AppearanceChoice.system
    @AppStorage(SettingsKey.menuBar) private var showsMenuBar = true
    let sorter: SorterModel

    var body: some View {
        Form {
            Section {
                SettingRow(.appearance,
                           title: "Appearance", hint: "Match your Mac, or always light or dark.") {
                    RadioChoice(title: "Appearance", selection: $appearance, choices: AppearanceChoice.allCases) { Text($0.title) }
                }

                SaveFolderRow(sorter: sorter)

                SettingRow(.menuBar,
                           title: "Show in menu bar", hint: "See and pause downloads from the menu bar. Closing the window keeps Rays running.") {
                    Toggle("Show in menu bar", isOn: $showsMenuBar)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                CopiedLinksRow()

                NotifyRow()
            }

            CommandLineSection()

            UpdateSettingsSection()

            UninstallSection()

            SavedNote()
        }
        .scrollContentBackground(.hidden)
        .formStyle(.grouped)
    }
}

struct SaveFolderRow: View {
    @Environment(EngineModel.self) private var model
    @AppStorage(SettingsKey.downloadsDir) private var customFolder = ""
    @AppStorage(SettingsKey.sorterPath) private var sorterPath = Sorter.defaultPath
    let sorter: SorterModel
    @State private var folderError: String?

    private var folder: URL { EngineModel.downloadsURL }

    var body: some View {
        SettingRow(.folder,
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

struct CopiedLinksRow: View {
    @AppStorage(SettingsKey.clipboard) private var offersCopiedLinks = true

    var body: some View {
        SettingRow(.clipboard,
                   title: "Offer copied download links",
                   hint: "When you copy a link to a file, like a .zip or .dmg, a notification offers to download it. macOS asks once to let Rays read copied links.") {
            Toggle("Offer copied download links", isOn: $offersCopiedLinks)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }
}

struct NotifyRow: View {
    @AppStorage(SettingsKey.notifyDone) private var notifiesWhenDone = true

    var body: some View {
        SettingRow(.notifications,
                   title: "Notify when downloads finish",
                   hint: "A notification when a download finishes or fails, with buttons to open it, show it in Finder or retry. Many at once become one summary.") {
            Toggle("Notify when downloads finish", isOn: $notifiesWhenDone)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }
}

struct MaxRunningRow: View {
    @Environment(EngineModel.self) private var model
    @AppStorage(SettingsKey.maxRunning) private var maxRunning = 3

    var body: some View {
        SettingRow(.concurrency,
                   title: "Downloads at once", hint: "How many files download at the same time.") {
            StepSlider(title: "Downloads at once", value: Binding(get: { maxRunning }, set: { model.setMaxRunning($0) }), range: 1...10)
        }
    }
}

struct PartsRow: View {
    @Environment(EngineModel.self) private var model
    @AppStorage(SettingsKey.connections) private var connections = 4

    var body: some View {
        SettingRow(.parts,
                   title: "Parts per file", hint: "Big files download in parts at once. 4 works well for most sites.") {
            StepSlider(title: "Parts per file", value: Binding(get: { connections }, set: { model.setConnections($0) }), range: 1...16)
        }
    }
}

struct SpeedLimitRow: View {
    @Environment(EngineModel.self) private var model
    @AppStorage(SettingsKey.speedLimit) private var speedLimit = 0

    var body: some View {
        SettingRow(.speedLimit,
                   title: "Speed limit", hint: "Leave some internet for everything else on your Mac. 0 means no limit.") {
            SpeedLimitField(bytes: Binding(get: { speedLimit }, set: { model.setSpeedLimit($0) }))
        }
    }
}

/// Also the Download settings page of the Downloads view.
struct DownloadsTab: View {
    var body: some View {
        Form {
            Section {
                MaxRunningRow()
                PartsRow()
                ReplaceExistingRow()
            }

            Section { SpeedLimitRow() }

            Section { UnpackSettingsRows() }

            Section { WakePermissionRow() }

            HuggingFaceTokenSection()

            SavedNote()
        }
        .scrollContentBackground(.hidden)
        .formStyle(.grouped)
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

struct WakePermissionRow: View {
    @Environment(EngineModel.self) private var model
    @State private var installed: Bool?

    var body: some View {
        SettingRow(.wake, title: "Wake permission",
                   hint: "Lets a queue wake your Mac to start on time.") {
            HStack(spacing: 10) {
                Text(installed == true ? "Installed" : "Not set up").foregroundStyle(.secondary)
                if installed == true {
                    Button("Remove wake permission") {
                        Task {
                            if !(await WakePermission.remove()) {
                                model.showNotice("Couldn't remove the wake permission. Try Remove wake permission again.")
                            }
                            installed = await Task.detached { WakePermission.isInstalled }.value
                        }
                    }
                }
            }
        }
        .task { installed = await Task.detached { WakePermission.isInstalled }.value }
    }
}
