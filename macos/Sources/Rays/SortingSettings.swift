import AppKit
import SwiftUI

@MainActor
@Observable
final class SorterModel {
    private(set) var watching = false
    private(set) var busy = false
    private(set) var error: String?
    private(set) var sortResult: String?

    func refresh() {
        let plist = Sorter.plistURL(for: EngineModel.downloadsURL).path(percentEncoded: false)
        watching = FileManager.default.fileExists(atPath: plist)
    }

    func setWatching(_ on: Bool, sorterPath: String) async {
        busy = true
        error = nil
        let folder = EngineModel.downloadsURL.path(percentEncoded: false)
        let result = await Sorter.run(sorterPath, [on ? "watch" : "unwatch", folder])
        busy = false
        if result.status != 0 { error = result.failure }
        refresh()
    }

    /// After the download folder changes, a watch on the old folder moves to the new one.
    func moveWatch(from old: URL, sorterPath: String) async {
        let new = EngineModel.downloadsURL
        guard old.standardizedFileURL != new.standardizedFileURL,
              FileManager.default.fileExists(atPath: Sorter.plistURL(for: old).path(percentEncoded: false))
        else { return }
        busy = true
        error = nil
        let stop = await Sorter.run(sorterPath, ["unwatch", old.path(percentEncoded: false)])
        let start = await Sorter.run(sorterPath, ["watch", new.path(percentEncoded: false)])
        busy = false
        error = [stop, start].first { $0.status != 0 }?.failure
        refresh()
    }

    func sortNow(sorterPath: String) async {
        busy = true
        error = nil
        sortResult = nil
        let result = await Sorter.run(sorterPath, [EngineModel.downloadsURL.path(percentEncoded: false)])
        busy = false
        if result.status == 0 {
            sortResult = Sorter.lastLine(result.stdout)
        } else {
            error = result.failure
        }
    }
}

struct SortingTab: View {
    @AppStorage(SettingsKey.sorterPath) private var sorterPath = Sorter.defaultPath
    let sorter: SorterModel

    private var sorterFound: Bool { FileManager.default.isExecutableFile(atPath: sorterPath) }

    var body: some View {
        Form {
            Section {
                SettingRow(symbol: "sparkles", color: .pink, title: "Sort with AI",
                           hint: "Puts finished downloads into folders like Work or Personal. It runs on your Mac; nothing is uploaded.") {
                    HStack(spacing: 8) {
                        if sorter.busy { ProgressView().controlSize(.small) }
                        Toggle("Sort with AI", isOn: Binding(
                            get: { sorter.watching },
                            set: { on in Task { await sorter.setWatching(on, sorterPath: sorterPath) } }))
                            .labelsHidden()
                            .disabled(!sorterFound || sorter.busy)
                    }
                }
            }

            Section {
                SettingRow(symbol: "wand.and.stars", color: .indigo, title: "Sort now",
                           hint: "Tidy up new files in your downloads folder right away.") {
                    Button("Sort Now") { Task { await sorter.sortNow(sorterPath: sorterPath) } }
                        .buttonStyle(.glass)
                        .disabled(!sorterFound || sorter.busy)
                }
                if let result = sorter.sortResult {
                    Text(result).font(.callout).foregroundStyle(.secondary)
                }
                if let error = sorter.error {
                    ErrorLine(text: error)
                }

                SettingRow(symbol: "location.fill", color: .teal, title: "Find my files",
                           hint: "Rays keeps track of files after they're sorted.") {
                    EmptyView()
                }

                SettingRow(symbol: "wrench.and.screwdriver.fill", color: Color(nsColor: .systemGray),
                           title: "Sorter location", hint: "Where the sorter tool is installed.") {
                    HStack(spacing: 8) {
                        Text(URL(filePath: sorterPath).tildePath)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…", action: chooseSorter).buttonStyle(.glass)
                    }
                }
                if !sorterFound {
                    ErrorLine(text: "sorter wasn't found at \(sorterPath).")
                }
            }

            SavedNote()
        }
        .scrollContentBackground(.hidden)
        .formStyle(.grouped)
        .onAppear { sorter.refresh() }
    }

    private func chooseSorter() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(filePath: sorterPath).deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        sorterPath = url.path(percentEncoded: false)
    }
}
