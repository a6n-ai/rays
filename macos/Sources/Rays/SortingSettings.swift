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

            Section {
                SettingRow(symbol: "timer", color: .orange, title: "Sort new files after",
                           hint: "Rays waits this long after a file arrives, so you can open or move it first.") {
                    Picker("Sort new files after", selection: Binding(
                        get: { sorter.status?.waitSeconds ?? 10 },
                        set: { secs in Task { await sorter.setWait(secs) } })) {
                        ForEach(SorterModel.waitChoices, id: \.seconds) { Text($0.title).tag($0.seconds) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .disabled(sorter.busy || sorter.loadFailed)
                }
            }

            Section {
                SettingRow(symbol: "character.cursor.ibeam", color: .purple, title: "Rename files from their content",
                           hint: "Off keeps every file's original name. Files are still sorted into folders.") {
                    Toggle("Rename files from their content", isOn: Binding(
                        get: { sorter.status?.renameFiles ?? true },
                        set: { on in Task { await sorter.setRename(on) } }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(sorter.busy || sorter.loadFailed)
                }
            }

            Section {
                SettingRow(symbol: "folder.badge.gearshape", color: .blue,
                           title: watched == 1 ? "1 folder watched" : "\(watched) folders watched",
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
