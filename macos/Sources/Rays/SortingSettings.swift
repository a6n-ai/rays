import SwiftUI

/// Settings that apply to every sorter folder. Per-folder choices (watching, where files go) live in the Sorter page.
struct SortingTab: View {
    @Environment(\.openWindow) private var openWindow
    let sorter: SorterModel

    private var folders: [SorterFolder] { sorter.status?.folders ?? [] }
    private var watched: Int { folders.filter(\.watching).count }

    var body: some View {
        Form {
            Section {
                AIStatusRow()
            }

            Section { SortDelayRow(sorter: sorter) }

            Section { RenameRow(sorter: sorter) }

            Section {
                SettingRow(.watchedFolders, title: watched == 1 ? "1 folder watched" : "\(watched) folders watched",
                           hint: folders.isEmpty ? "Add folders to sort in the Sorter page."
                                                 : folders.map(\.name).joined(separator: ", ")) {
                    Button("Open Sorter", action: openSorter)
                        .buttonStyle(.glass)
                }
            }

            SavedNote()
        }
        .scrollContentBackground(.hidden)
        .formStyle(.grouped)
        .task { if sorter.status == nil { await sorter.refresh() } }
    }

    private func openSorter() {
        openWindow(id: "main")
        NotificationCenter.default.post(name: .openSorter, object: nil)
    }
}

struct SortDelayRow: View {
    let sorter: SorterModel

    var body: some View {
        SettingRow(.sortDelay, title: "Sort new files after",
                   hint: "Rays waits this long after a file arrives, so you can open or move it first.") {
            StepSlider(title: "Sort new files after",
                       value: Binding(
                           get: { SorterModel.waitChoices.firstIndex { $0.seconds == (sorter.status?.waitSeconds ?? 10) } ?? 0 },
                           set: { i in Task { await sorter.setWait(SorterModel.waitChoices[i].seconds) } }),
                       range: 0...(SorterModel.waitChoices.count - 1), lowLabel: "10 seconds", highLabel: "1 hour", width: 190) {
                SorterModel.waitChoices[$0].title.replacingOccurrences(of: " (Recommended)", with: "")
            }
            .disabled(sorter.busy || sorter.loadFailed)
        }
    }
}

struct RenameRow: View {
    let sorter: SorterModel

    var body: some View {
        SettingRow(.rename, title: "Rename files from their content",
                   hint: "Off keeps every file's original name. Files are still sorted into folders.") {
            Toggle("Rename files from their content", isOn: Binding(
                get: { sorter.status?.renameFiles ?? true },
                set: { on in Task { await sorter.setRename(on) } }))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(sorter.busy || sorter.loadFailed)
        }
    }
}
