import Foundation

extension QueueView: Identifiable {
    public var id: UInt64 { config.id ?? 0 }

    /// Stop queue holds the queue, and a disabled one is off; Start clears either.
    var isStopped: Bool { state == .stopped || state == .off }
}

extension EngineModel {
    /// The engine returns queues in no fixed order; Main is id 1.
    var sortedQueues: [QueueView] { queues.sorted { $0.id < $1.id } }

    /// A new unscheduled queue, or nil after the failure is shown in the notice line.
    func newQueue() -> UInt64? {
        do {
            return try saveQueue(QueueConfig(id: nil, name: "New queue", maxRunning: 0, speedLimit: 0, enabled: true,
                                             schedule: nil, retryFailed: false, wake: false, whenFinished: .nothing))
        } catch {
            queueFailed("create the queue", error)
            return nil
        }
    }
}
