import SwiftUI

/// The Queues page: the list of queues, their activity, and the queue settings. A queue opens as a pushed detail.
struct QueuesPage: View {
    let isDropTargeted: Bool
    let drafts: QueueDrafts
    @Environment(EngineModel.self) private var model
    @AppStorage("queuesSection") private var section = QueuesSection.queues
    @AppStorage("queueSection") private var queueSection = QueueSection.downloads
    @State private var selected: UInt64?

    enum QueuesSection: String { case queues, activity, settings }

    var body: some View {
        NavigationStack {
            Group {
                switch section {
                case .queues: QueueListTab(drafts: drafts, open: { open($0, nil) })
                case .activity: ActivityTab(open: { open($0, nil) })
                case .settings: QueueSettingsTab()
                }
            }
            .navigationTitle("Queues")
            .toolbar { if selected == nil { toolbar } }
            .navigationDestination(item: $selected) { id in
                QueuePage(queueId: id, isDropTargeted: isDropTargeted, drafts: drafts, onDeleted: { selected = nil })
                    .toolbar { toolbar }
            }
        }
    }

    private func open(_ id: UInt64, _ target: QueueSection?) {
        if let target { queueSection = target }
        selected = id
    }

    private func newQueue() {
        if let id = model.newQueue() { open(id, .schedule) }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            ToolbarIconGroup {
                ForEach([(QueuesSection.queues, "list.bullet", "Queues"),
                         (QueuesSection.activity, "clock.arrow.circlepath", "Activity"),
                         (QueuesSection.settings, "slider.horizontal.3", "Queue settings")], id: \.0) { item in
                    Button {
                        section = item.0
                        selected = nil
                    } label: {
                        ToolbarIcon(symbol: item.1, title: item.2, selected: section == item.0)
                    }
                    .buttonStyle(.plain)
                    .help(item.2)
                    .accessibilityAddTraits(section == item.0 ? .isSelected : [])
                }
            }
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .primaryAction) {
            ToolbarIconGroup {
                Button(action: newQueue) {
                    ToolbarIcon(symbol: "plus", title: "New queue")
                }
                .buttonStyle(.plain)
                .help("New queue")
                Menu {
                    Button("Start all queues", systemImage: "play.circle") { model.setAllQueues(running: true) }
                    Button("Stop all queues", systemImage: "stop.circle") { model.setAllQueues(running: false) }
                } label: {
                    ToolbarIcon(symbol: "play.circle", title: "Start or stop all queues")
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .help("Start or stop every enabled queue")
            }
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .primaryAction) { SettingsToolbarButton() }
    }
}
