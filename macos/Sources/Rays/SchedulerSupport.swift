import Foundation

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
        Calendar.current.date(bySettingHour: Int(minutes) / 60, minute: Int(minutes) % 60, second: 0, of: Date()) ?? Date()
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

    /// The subtitle under a queue's name in the scheduler's list.
    static func summary(_ queue: QueueView) -> String {
        let config = queue.config
        if queue.state == .open && queue.running > 0 { return "Running" }
        guard let schedule = config.schedule else { return "Not scheduled" }
        if !config.enabled { return "Off" }
        let time = hhmm(schedule.startMin)
        switch schedule.repeat {
        case .daily: return "Every day at \(time)"
        case .once(let date): return "Once, " + (Self.date(date)?.formatted(Date.FormatStyle().day().month(.abbreviated)) ?? date) + " at \(time)"
        case .days(let mask):
            if mask == weekdays { return "Weekdays at \(time)" }
            if mask == 0b1100000 { return "Weekends at \(time)" }
            let names = (0..<7).filter { mask & (1 << $0) != 0 }.map { String(dayNames[$0].prefix(3)) }
            return names.joined(separator: ", ") + " at \(time)"
        }
    }
}
