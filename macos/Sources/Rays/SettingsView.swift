import AppKit
import SwiftUI

struct SaveFolderRow: View {
    @Environment(EngineModel.self) private var model
    @AppStorage(SettingsKey.downloadsDir) private var customFolder = ""
    @AppStorage(SettingsKey.sorterPath) private var sorterPath = Sorter.defaultPath
    let sorter: SorterModel
    @State private var folderError: String?

    private var folder: URL { EngineModel.downloadsURL }

    var body: some View {
        SettingRow(title: "Save downloads to") {
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
        panel.prompt = "Use folder"
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
        SettingRow(title: "Offer copied download links",
                   hint: "Offers to download links you copy. macOS asks once to allow it.") {
            Toggle("Offer copied download links", isOn: $offersCopiedLinks)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }
}

struct NotifyRow: View {
    @AppStorage(SettingsKey.notifyDone) private var notifiesWhenDone = true

    var body: some View {
        SettingRow(title: "Notify when downloads finish") {
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
        SettingRow(title: "Downloads at once") {
            StepSlider(title: "Downloads at once", value: Binding(get: { maxRunning }, set: { model.setMaxRunning($0) }), range: 1...10)
        }
    }
}

struct PartsRow: View {
    @Environment(EngineModel.self) private var model
    @AppStorage(SettingsKey.connections) private var connections = 4

    var body: some View {
        SettingRow(title: "Parts per file", hint: "4 works well for most sites.") {
            StepSlider(title: "Parts per file", value: Binding(get: { connections }, set: { model.setConnections($0) }), range: 1...16)
        }
    }
}

struct SpeedLimitRow: View {
    @Environment(EngineModel.self) private var model
    @AppStorage(SettingsKey.speedLimit) private var speedLimit = 0

    var body: some View {
        SettingRow(title: "Speed limit", hint: "0 means no limit.") {
            SpeedLimitField(bytes: Binding(get: { speedLimit }, set: { model.setSpeedLimit($0) }))
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
        SettingRow(title: "Wake permission",
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
