import SwiftUI

struct SortingTab: View {
    @Environment(\.openWindow) private var openWindow
    let sorter: SorterModel

    var body: some View {
        Form {
            Section {
                SettingRow(symbol: "sparkles", color: .pink, title: "Sorting moved to the Sorter tab",
                           hint: "Add folders, turn sorting on, and see recent moves in one place.") {
                    Button("Open Sorter", action: openSorter)
                        .buttonStyle(.glass)
                }
            }

            SavedNote()
        }
        .scrollContentBackground(.hidden)
        .formStyle(.grouped)
    }

    private func openSorter() {
        openWindow(id: "main")
        NotificationCenter.default.post(name: .openSorter, object: nil)
    }
}
