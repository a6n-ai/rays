import SwiftUI

/// The Queues page: the list of queues with the queue settings card. A queue and the Activity view are drill-ins
/// kept in the navigation history ("queue:<id>", "activity").
struct QueuesPage: View {
    let isDropTargeted: Bool
    let drafts: QueueDrafts
    @Environment(EngineModel.self) private var model
    @Environment(NavHistory.self) private var nav
    @AppStorage("queueSection") private var queueSection = QueueSection.downloads

    var body: some View {
        Group {
            if let id = openQueue {
                QueuePage(queueId: id, isDropTargeted: isDropTargeted, drafts: drafts, onDeleted: { nav.replaceSub(nil) })
            } else if nav.sub == "activity" {
                ActivityTab(open: { open($0, nil) })
                    .navigationTitle("Queue Activity")
            } else {
                QueueListTab(drafts: drafts, open: { open($0, nil) }, newQueue: newQueue)
                    .navigationTitle("Queues")
            }
        }
    }

    private var openQueue: UInt64? {
        guard let sub = nav.sub, sub.hasPrefix("queue:") else { return nil }
        return UInt64(sub.dropFirst("queue:".count))
    }

    private func open(_ id: UInt64, _ target: QueueSection?) {
        if let target { queueSection = target }
        nav.open("queue:\(id)")
    }

    private func newQueue() {
        if let id = model.newQueue() { open(id, .schedule) }
    }
}
