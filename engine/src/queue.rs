//! Download queues: a named list of jobs with its own schedule, speed limit and finish action.
use jiff::civil::{Date, DateTime};
use jiff::ToSpan;
use serde::{Deserialize, Serialize};

#[derive(uniffi::Enum, Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Repeat {
    Once { date: String },
    Daily,
    /// Bit 0 is Monday through bit 6 is Sunday.
    Days { mask: u8 },
}

#[derive(uniffi::Enum, Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum FinishAction {
    #[default]
    Nothing,
    Sound,
    Quit,
    Sleep,
    Lock,
    ShutDown,
    Command { command: String },
}

#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct QueueSchedule {
    pub repeat: Repeat,
    /// Minutes since midnight.
    pub start_min: u16,
    pub stop_min: Option<u16>,
    pub wifi: bool,
    pub power: bool,
    pub idle: bool,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct QueueConfig {
    /// None until saved.
    pub id: Option<u64>,
    pub name: String,
    pub max_running: u32,
    /// Bytes per second for this queue; 0 means unlimited.
    pub speed_limit: u64,
    pub enabled: bool,
    pub schedule: Option<QueueSchedule>,
    pub retry_failed: bool,
    pub wake: bool,
    pub when_finished: FinishAction,
}

pub(crate) fn at(day: Date, min: u16) -> DateTime {
    day.at(0, 0, 0, 0) + i64::from(min).minutes()
}

pub(crate) fn is_active(repeat: &Repeat, day: Date) -> bool {
    match repeat {
        Repeat::Once { date } => date.parse::<Date>().is_ok_and(|d| d == day),
        Repeat::Daily => true,
        Repeat::Days { mask } => mask & (1u8 << day.weekday().to_monday_zero_offset()) != 0,
    }
}

/// Opening at `opened` ends at this moment. Windows without a stop end at midnight.
pub fn window_end(s: &QueueSchedule, opened: DateTime) -> Option<DateTime> {
    let day = opened.date();
    if opened != at(day, s.start_min) || !is_active(&s.repeat, day) {
        return None;
    }
    Some(match s.stop_min {
        None => at(day + 1.day(), 0),
        Some(stop) if stop > s.start_min => at(day, stop),
        Some(stop) => at(day + 1.day(), stop),
    })
}

/// The start of the window that is open at `now`.
pub(crate) fn open_start(s: &QueueSchedule, now: DateTime) -> Option<DateTime> {
    let today = now.date();
    [today - 1.day(), today].into_iter().map(|day| at(day, s.start_min)).find(|opened| window_end(s, *opened).is_some_and(|end| *opened <= now && now < end))
}

pub fn window_open(s: &QueueSchedule, now: DateTime) -> bool {
    open_start(s, now).is_some()
}

pub fn next_start(s: &QueueSchedule, now: DateTime) -> Option<DateTime> {
    if let Repeat::Once { date } = &s.repeat {
        let opened = at(date.parse().ok()?, s.start_min);
        return (opened > now).then_some(opened);
    }
    let today = now.date();
    // Daily and Days recur within any seven days, so this covers the next opening.
    (0..=7i64).find_map(|n| {
        let day = today + n.days();
        let opened = at(day, s.start_min);
        (is_active(&s.repeat, day) && opened > now).then_some(opened)
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use jiff::civil::date;

    fn sched(repeat: Repeat, start_min: u16, stop_min: Option<u16>) -> QueueSchedule {
        QueueSchedule { repeat, start_min, stop_min, wifi: false, power: false, idle: false }
    }

    #[test]
    fn daily_window() {
        let s = sched(Repeat::Daily, 120, Some(450));
        let day = date(2026, 11, 25);
        assert!(window_open(&s, day.at(3, 0, 0, 0)));
        assert!(!window_open(&s, day.at(8, 0, 0, 0)));
        assert!(!window_open(&s, day.at(1, 59, 0, 0)));
    }

    #[test]
    fn no_stop_stays_open() {
        let s = sched(Repeat::Daily, 120, None);
        assert!(window_open(&s, date(2026, 11, 25).at(23, 59, 0, 0)));
        assert!(!window_open(&s, date(2026, 11, 26).at(1, 59, 0, 0)));
    }

    #[test]
    fn cross_midnight_days() {
        let fri_night = sched(Repeat::Days { mask: 0b0001_0000 }, 1320, Some(360));
        assert!(window_open(&fri_night, date(2026, 11, 28).at(3, 0, 0, 0)));
        assert!(!window_open(&fri_night, date(2026, 11, 28).at(22, 0, 0, 0)));
        assert!(!window_open(&fri_night, date(2026, 11, 26).at(23, 0, 0, 0)));
    }

    #[test]
    fn once_date() {
        let s = sched(Repeat::Once { date: "2026-12-01".into() }, 60, Some(120));
        assert!(window_open(&s, date(2026, 12, 1).at(1, 30, 0, 0)));
        assert!(!window_open(&s, date(2026, 12, 1).at(0, 30, 0, 0)));
        assert!(!window_open(&s, date(2026, 12, 2).at(1, 30, 0, 0)));
        assert_eq!(next_start(&s, date(2026, 12, 1).at(2, 30, 0, 0)), None);
    }

    #[test]
    fn next_start_days() {
        let s = sched(Repeat::Days { mask: 0b0001_1111 }, 120, None);
        assert_eq!(
            next_start(&s, date(2026, 11, 27).at(8, 0, 0, 0)),
            Some(date(2026, 11, 30).at(2, 0, 0, 0))
        );
    }

    #[test]
    fn dst_gap_does_not_panic() -> Result<(), jiff::Error> {
        let s = sched(Repeat::Daily, 150, None);
        let next = next_start(&s, date(2027, 3, 13).at(12, 0, 0, 0)).unwrap();
        let local = next.to_zoned_datetime(jiff::tz::TimeZone::get("America/New_York")?)?;
        assert_eq!(local.datetime(), date(2027, 3, 14).at(3, 30, 0, 0));
        Ok(())
    }
}
