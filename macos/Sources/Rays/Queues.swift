import Foundation
import SwiftUI

extension QueueView: Identifiable {
    public var id: UInt64 { config.id ?? 0 }

    /// Stop queue holds the queue, and a disabled one is off; Start clears either.
    var isStopped: Bool { state == .stopped || state == .off }

    /// Main (id 1) is the default queue and holds the jobs other queues hand back, so it cannot go.
    var isMain: Bool { id == 1 }
}

/// A queue's state as an SF Symbol, a word and a semantic colour, never colour alone.
struct QueueBadge {
    let symbol: String
    let text: String
    let tint: Color
}

extension QueueView {
    /// nil for an open queue with nothing running.
    var badge: QueueBadge? {
        switch state {
        case .open:
            running > 0 ? QueueBadge(symbol: "arrow.down.circle.fill", text: "Running", tint: .blue) : nil
        case .waitingForTime(let next):
            QueueBadge(symbol: "clock", text: "Starts " + Date(timeIntervalSince1970: TimeInterval(next)).formatted(Date.FormatStyle().hour().minute()), tint: .orange)
        case .waitingForCondition(let missing):
            QueueBadge(symbol: Self.conditionSymbol(missing), text: "Waiting for " + missing.joined(separator: ", "), tint: .yellow)
        case .stopped:
            QueueBadge(symbol: "pause.circle", text: "Stopped", tint: .secondary)
        case .off:
            QueueBadge(symbol: "minus.circle", text: "Off", tint: Color(nsColor: .tertiaryLabelColor))
        }
    }

    private static func conditionSymbol(_ missing: [String]) -> String {
        switch missing.first {
        case "charger"?: "bolt"
        case "idle"?: "moon"
        default: "wifi"
        }
    }

    /// The pieces of the status line, each with a small symbol. `withNext` adds the next start.
    func statusParts(withNext: Bool = true) -> [QueueStatusPart] {
        var parts: [QueueStatusPart] = []
        if let schedule = config.schedule {
            parts.append(QueueStatusPart(symbol: "calendar", text: schedule.summary))
            if let conditions = schedule.conditionsText {
                parts.append(QueueStatusPart(symbol: schedule.wifi ? "wifi" : schedule.power ? "bolt" : "moon", text: conditions))
            }
            if withNext, config.enabled, let next = nextRun {
                parts.append(QueueStatusPart(symbol: "clock", text: "next " + Date(timeIntervalSince1970: TimeInterval(next)).formatted(Date.FormatStyle().weekday(.abbreviated).hour().minute())))
            }
        } else {
            parts.append(QueueStatusPart(symbol: "calendar", text: "Not scheduled"))
        }
        if running > 0 { parts.append(QueueStatusPart(symbol: "arrow.down.circle.fill", text: "\(running) downloading", tint: .blue)) }
        if queued > 0 { parts.append(QueueStatusPart(symbol: "arrow.down.circle", text: "\(queued) waiting")) }
        return parts
    }

    var statusLine: String { statusParts().map(\.text).joined(separator: " · ") }
}

struct QueueStatusPart {
    let symbol: String
    let text: String
    var tint: Color?
}

/// A status line with a small inline symbol before each piece.
struct QueueStatusText: View {
    let parts: [QueueStatusPart]

    var body: some View {
        parts.enumerated().reduce(Text("")) { text, item in
            let piece = Text("\(Image(systemName: item.element.symbol)) \(item.element.text)")
            return text + Text(item.offset == 0 ? "" : "  ·  ") + (item.element.tint.map { piece.foregroundColor($0) } ?? piece)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .lineLimit(1)
        .truncationMode(.tail)
    }
}

extension QueueSchedule {
    /// "Weekdays 02:00–07:30": the repeat rule, then the start and optional stop time.
    var summary: String {
        let times = SchedulerTime.hhmm(startMin) + (stopMin.map { "–" + SchedulerTime.hhmm($0) } ?? "")
        let rule: String
        switch `repeat` {
        case .once(let date):
            rule = SchedulerTime.date(date).map { $0.formatted(Date.FormatStyle().day().month(.abbreviated)) } ?? "Once"
        case .daily:
            rule = "Every day"
        case .days(let mask):
            switch mask {
            case SchedulerTime.weekdays: rule = "Weekdays"
            case 0b1100000: rule = "Weekends"
            case 0b1111111: rule = "Every day"
            default: rule = SchedulerTime.dayLetters.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element).joined(separator: " ")
            }
        }
        return rule + " " + times
    }

    var conditionsText: String? {
        let names = [wifi ? "Wi-Fi" : nil, power ? "Charging" : nil, idle ? "Idle" : nil].compactMap { $0 }
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }
}

extension EngineModel {
    /// The engine returns queues in no fixed order; Main is id 1, so it sorts first.
    var sortedQueues: [QueueView] { queues.sorted { $0.id < $1.id } }

    /// The run a queue is in now, from the newest run still open.
    func openRun(_ queue: UInt64) -> QueueRun? { runs.first { $0.queueId == queue && $0.endedAt == nil } }

    /// A new unscheduled queue using the defaults chosen in the Queues settings, or nil after the failure is shown in the notice line.
    func newQueue(schedule: QueueSchedule? = nil) -> UInt64? {
        let defaults = UserDefaults.standard
        let finish = FinishKind(rawValue: defaults.string(forKey: SettingsKey.queueDefaultFinish) ?? "")?.action ?? .nothing
        do {
            return try saveQueue(QueueConfig(
                id: nil, name: "New queue",
                maxRunning: UInt32(max(0, defaults.integer(forKey: SettingsKey.queueDefaultMaxRunning))),
                speedLimit: UInt64(max(0, defaults.integer(forKey: SettingsKey.queueDefaultSpeed))),
                enabled: true, schedule: schedule, retryFailed: false, wake: false, whenFinished: finish))
        } catch {
            queueFailed("create the queue", error)
            return nil
        }
    }

    /// Saves at once against the saved config, so edits still waiting in a draft are not saved with it. A failure leaves the switch where it was.
    func setQueueEnabled(_ queue: QueueView, _ on: Bool) {
        var config = queue.config
        config.enabled = on
        do { _ = try saveQueue(config) } catch { queueFailed("change the queue", error) }
    }

    /// Start all and Stop all act on every enabled queue.
    func setAllQueues(running: Bool) {
        for queue in queues where queue.config.enabled {
            if running { startQueue(queue.id) } else { stopQueue(queue.id) }
        }
    }
}
