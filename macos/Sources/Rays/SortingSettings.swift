import SwiftUI

struct SortDelayRow: View {
    let sorter: SorterModel

    var body: some View {
        SettingRow(title: "Sort new files after",
                   hint: "Gives you time to open or move a file first.") {
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
        SettingRow(title: "Rename files from their content",
                   hint: "Off keeps original names. Files are still sorted.") {
            Toggle("Rename files from their content", isOn: Binding(
                get: { sorter.status?.renameFiles ?? true },
                set: { on in Task { await sorter.setRename(on) } }))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(sorter.busy || sorter.loadFailed)
        }
    }
}
