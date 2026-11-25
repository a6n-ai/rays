//! Speed samples: measured transfer rates, kept for the Speed insights view.

#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct SpeedSample {
    /// Unix seconds.
    pub at: i64,
    pub bps: u64,
    pub source: SampleSource,
    pub network: NetworkKind,
}

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum SampleSource {
    Test,
    Downloads,
}

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum NetworkKind {
    Wifi,
    Wired,
    Expensive,
    Other,
    Unknown,
}

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum Confidence {
    Low,
    Medium,
    High,
}

#[derive(uniffi::Enum, Clone, Debug, PartialEq, Eq)]
pub enum BestTime {
    Window {
        start_min: u16,
        end_min: u16,
        typical_bps: u64,
        days: u32,
        confidence: Confidence,
    },
    NotEnoughData {
        days: u32,
        needed: u32,
    },
}

const MIN_DAYS: u32 = 7;
const HIGH_DAYS: u32 = 14;
const MIN_BUCKET: usize = 3;

fn hour_buckets(local: &[(jiff::civil::DateTime, u64)]) -> [Vec<u64>; 24] {
    let mut buckets: [Vec<u64>; 24] = std::array::from_fn(|_| Vec::new());
    for (at, bps) in local {
        buckets[at.hour() as usize].push(*bps);
    }
    buckets
}

fn median(v: &mut [u64]) -> u64 {
    v.sort_unstable();
    let n = v.len();
    if n % 2 == 1 { v[n / 2] } else { (v[n / 2 - 1] + v[n / 2]) / 2 }
}

pub fn best_window(local: &[(jiff::civil::DateTime, u64)], hours: u8) -> BestTime {
    let days = local.iter().map(|(at, _)| at.date()).collect::<std::collections::BTreeSet<_>>().len() as u32;
    let not_enough = BestTime::NotEnoughData { days, needed: MIN_DAYS };
    if days < MIN_DAYS || !(1..=24).contains(&hours) {
        return not_enough;
    }
    let medians: Vec<Option<u64>> = hour_buckets(local)
        .iter_mut()
        .map(|v| (v.len() >= MIN_BUCKET).then(|| median(v)))
        .collect();
    let width = usize::from(hours);
    let mut best: Option<(u64, usize)> = None;
    for start in 0..24 {
        let sum: Option<u64> = (0..width).map(|i| medians[(start + i) % 24]).sum();
        if let Some(sum) = sum.filter(|&s| best.is_none_or(|(b, _)| s > b)) {
            best = Some((sum, start));
        }
    }
    let Some((sum, start)) = best else {
        return not_enough;
    };
    BestTime::Window {
        start_min: (start * 60) as u16,
        end_min: (((start + width) % 24) * 60) as u16,
        typical_bps: sum / u64::from(hours),
        days,
        confidence: if days >= HIGH_DAYS { Confidence::High } else { Confidence::Medium },
    }
}

pub fn window_schedule(start_min: u16, end_min: u16) -> crate::queue::QueueSchedule {
    crate::queue::QueueSchedule {
        repeat: crate::queue::Repeat::Daily,
        start_min,
        stop_min: Some(end_min),
        wifi: false,
        power: false,
        idle: false,
    }
}

pub fn typical_bps_at(local: &[(jiff::civil::DateTime, u64)], hour: u8) -> Option<u64> {
    let mut buckets = hour_buckets(local);
    let v = buckets.get_mut(usize::from(hour))?;
    (v.len() >= MIN_BUCKET).then(|| median(v))
}

#[cfg(test)]
mod tests {
    use super::*;
    use jiff::civil::{date, Date};

    fn day_samples(day: Date, per_hour: i8, bps: impl Fn(i8) -> u64) -> Vec<(jiff::civil::DateTime, u64)> {
        let mut v = Vec::new();
        for h in 0..24 {
            for k in 0..per_hour {
                v.push((day.at(h, k * 10, 0, 0), bps(h)));
            }
        }
        v
    }

    fn samples(n_days: i8, per_hour: i8, bps: impl Fn(i8) -> u64) -> Vec<(jiff::civil::DateTime, u64)> {
        (1..=n_days).flat_map(|d| day_samples(date(2026, 10, d), per_hour, &bps)).collect()
    }

    fn fast_1_to_4(h: i8) -> u64 {
        if (1..=4).contains(&h) { 100_000_000 } else { 20_000_000 }
    }

    #[test]
    fn not_enough_days() {
        let s = samples(6, 5, fast_1_to_4);
        assert_eq!(best_window(&s, 4), BestTime::NotEnoughData { days: 6, needed: 7 });
    }

    #[test]
    fn picks_fastest_window() {
        let s = samples(8, 5, fast_1_to_4);
        assert_eq!(
            best_window(&s, 4),
            BestTime::Window { start_min: 60, end_min: 300, typical_bps: 100_000_000, days: 8, confidence: Confidence::Medium }
        );
    }

    #[test]
    fn high_confidence() {
        let s = samples(14, 5, fast_1_to_4);
        assert!(matches!(best_window(&s, 4), BestTime::Window { confidence: Confidence::High, .. }));
    }

    #[test]
    fn sparse_hour_skipped() {
        let mut s = samples(8, 5, fast_1_to_4);
        let mut seen = 0;
        s.retain(|(at, _)| {
            if at.hour() == 2 {
                seen += 1;
                seen <= 2
            } else {
                true
            }
        });
        match best_window(&s, 4) {
            BestTime::Window { start_min, .. } => assert!(!matches!(start_min / 60, 23 | 0 | 1 | 2)),
            other => panic!("expected a window, got {other:?}"),
        }
    }

    #[test]
    fn wrap_window_to_schedule() {
        let s = samples(8, 5, |h| if matches!(h, 22 | 23 | 0 | 1) { 100_000_000 } else { 20_000_000 });
        assert!(matches!(best_window(&s, 4), BestTime::Window { start_min: 1320, end_min: 120, .. }));
        assert_eq!(
            window_schedule(1320, 120),
            crate::queue::QueueSchedule {
                repeat: crate::queue::Repeat::Daily,
                start_min: 1320,
                stop_min: Some(120),
                wifi: false,
                power: false,
                idle: false,
            }
        );
    }

    #[test]
    fn best_window_dst_day() {
        let base = samples(8, 5, fast_1_to_4);
        let dst = day_samples(date(2026, 11, 1), 5, fast_1_to_4);
        let dup_hour_1: Vec<_> = dst.iter().filter(|(at, _)| at.hour() == 1).cloned().collect();
        let mut with_dst = base.clone();
        with_dst.extend(dst);
        let mut with_dups = with_dst.clone();
        with_dups.extend(dup_hour_1);
        let expected = best_window(&with_dst, 4);
        assert!(matches!(expected, BestTime::Window { .. }));
        assert_eq!(best_window(&with_dups, 4), expected);
    }

    #[test]
    fn typical_bps_at_needs_three_samples_and_takes_even_median() {
        assert_eq!(typical_bps_at(&samples(1, 2, |_| 7), 3), None);
        assert_eq!(typical_bps_at(&samples(1, 3, |_| 7), 3), Some(7));
        let even: Vec<_> = [10u64, 40, 20, 30].iter().map(|&b| (date(2026, 10, 1).at(3, 0, 0, 0), b)).collect();
        assert_eq!(typical_bps_at(&even, 3), Some(25));
    }
}
