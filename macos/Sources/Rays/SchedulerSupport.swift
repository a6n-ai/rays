import Foundation
import SwiftUI

/// The four choices of the Repeat control. `none` is a queue without a schedule.
enum RepeatKind: String, CaseIterable, Identifiable {
    case none = "Not scheduled", once = "Once", daily = "Every day", days = "On days"
    var id: String { rawValue }

    init(_ schedule: QueueSchedule?) {
        switch schedule?.repeat {
        case nil: self = .none
        case .once?: self = .once
        case .daily?: self = .daily
        case .days?: self = .days
        }
    }
}

enum SchedulerTime {
    static let weekdays: UInt8 = 0b0011111
    static let dayLetters = ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]
    static let dayNames = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
    static let defaultStart: UInt16 = 120

    private static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func date(_ text: String) -> Date? { dateFormat.date(from: text) }
    static func text(_ date: Date) -> String { dateFormat.string(from: date) }
    static var today: String { text(Date()) }

    static func clock(_ minutes: UInt16) -> Date {
        // A fixed mid-January date, so a daylight saving jump never shifts the shown time.
        Calendar.current.date(from: DateComponents(year: 2001, month: 1, day: 15, hour: Int(minutes) / 60, minute: Int(minutes) % 60)) ?? Date()
    }

    static func minutes(_ date: Date) -> UInt16 {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return UInt16((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
    }

    static func hhmm(_ minutes: UInt16) -> String {
        clock(minutes).formatted(Date.FormatStyle().hour().minute())
    }

    static func nextRunText(_ unix: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(unix))
            .formatted(Date.FormatStyle().weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }

    static func schedule(for kind: RepeatKind, keeping old: QueueSchedule?) -> QueueSchedule? {
        let repeatRule: Repeat
        switch kind {
        case .none: return nil
        case .once: repeatRule = .once(date: today)
        case .daily: repeatRule = .daily
        case .days: repeatRule = .days(mask: weekdays)
        }
        guard var schedule = old else {
            return QueueSchedule(repeat: repeatRule, startMin: defaultStart, stopMin: nil, wifi: false, power: false, idle: false)
        }
        if RepeatKind(old) != kind { schedule.repeat = repeatRule }
        return schedule
    }
}

extension QueueConfig {
    /// Why this config can't be saved yet, or nil when it can.
    var problem: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Give the queue a name." }
        if case .days(let mask)? = schedule?.repeat, mask == 0 { return "Pick at least one day." }
        if case .command(let command) = whenFinished, command.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter a command to run." }
        return nil
    }
}

extension WakePermission {
    /// Whether the rule file works, and whether a wake queue is missing it. `isInstalled` runs sudo, so it stays off the main thread.
    static func status() async -> (installed: Bool, missing: Bool) {
        let installed = await Task.detached { isInstalled }.value
        return (installed, isMissingForWakeQueues)
    }
}

/// One row of a tab's two-column grid: a 110pt right-aligned label, then the controls.
func formRow(_ label: String, top: Bool = false, @ViewBuilder content: () -> some View) -> some View {
    GridRow(alignment: top ? .top : .firstTextBaseline) {
        Text(label)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(width: 110, alignment: .trailing)
        VStack(alignment: .leading, spacing: 8) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

func formNote(_ text: String) -> some View {
    Text(text)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
}

extension View {
    /// A centred column of at most 640pt, scrolling when the window is short.
    func formColumn() -> some View {
        ScrollView {
            self.frame(maxWidth: 640)
                .padding(LayoutMetrics.margin)
                .frame(maxWidth: .infinity)
        }
    }
}
