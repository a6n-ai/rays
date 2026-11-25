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
const HIGH_PER_HOUR: usize = 5;
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

/// `hours` outside 1..=24 gives `NotEnoughData`.
pub fn best_window(local: &[(jiff::civil::DateTime, u64)], hours: u8) -> BestTime {
    let days = local.iter().map(|(at, _)| at.date()).collect::<std::collections::BTreeSet<_>>().len() as u32;
    let not_enough = BestTime::NotEnoughData { days, needed: MIN_DAYS };
    if days < MIN_DAYS || !(1..=24).contains(&hours) {
        return not_enough;
    }
    let mut buckets = hour_buckets(local);
    let lens: Vec<usize> = buckets.iter().map(Vec::len).collect();
    let medians: Vec<Option<u64>> = buckets
        .iter_mut()
        .map(|v| (v.len() >= MIN_BUCKET).then(|| median(v)))
        .collect();
    let width = usize::from(hours);
    let mut best: Option<(u64, usize, usize)> = None;
    for start in 0..24 {
        let sum: Option<u64> = (0..width).map(|i| medians[(start + i) % 24]).sum();
        if let Some(sum) = sum.filter(|&s| best.is_none_or(|(b, _, _)| s > b)) {
            let min_len = (0..width).map(|i| lens[(start + i) % 24]).min().unwrap_or(0);
            best = Some((sum, start, min_len));
        }
    }
    let Some((sum, start, min_len)) = best else {
        return not_enough;
    };
    BestTime::Window {
        start_min: (start * 60) as u16,
        end_min: (((start + width) % 24) * 60) as u16,
        typical_bps: sum / u64::from(hours),
        days,
        confidence: if days >= HIGH_DAYS && min_len >= HIGH_PER_HOUR {
            Confidence::High
        } else {
            Confidence::Medium
        },
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

/// Folds per-tick download rates into one sample per clean wall-clock minute. Pure: the caller supplies time and rates.
#[derive(Default)]
pub struct Sampler {
    minute: i64,
    sum: u64,
    ticks: u64,
    clean: bool,
    network: Option<NetworkKind>,
}

const MIN_SAMPLE_BPS: u64 = 50_000;

impl Sampler {
    /// Call once per progress tick. Returns the finished minute's sample when `at` enters a new minute.
    pub fn observe(&mut self, at: i64, total_bps: u64, any_running: bool, limited: bool, network: NetworkKind) -> Option<SpeedSample> {
        let minute = at.div_euclid(60);
        let done = (self.ticks > 0 && minute != self.minute).then(|| {
            let bps = self.sum / self.ticks;
            self.network.filter(|_| self.clean && bps > MIN_SAMPLE_BPS).map(|network| SpeedSample {
                at: self.minute * 60,
                bps,
                source: SampleSource::Downloads,
                network,
            })
        });
        if done.is_some() || self.ticks == 0 {
            *self = Sampler { minute, clean: true, ..Sampler::default() };
        }
        self.sum += total_bps;
        self.ticks += 1;
        self.network = Some(network);
        self.clean &= any_running && !limited && matches!(network, NetworkKind::Wifi | NetworkKind::Wired | NetworkKind::Other);
        done.flatten()
    }
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
        let fast = |h: i8| if (10..=13).contains(&h) { 100_000_000 } else { 20_000_000 };
        let base = samples(8, 5, fast);
        let dst = day_samples(date(2026, 11, 1), 5, fast);
        let outliers: Vec<_> = dst
            .iter()
            .filter(|(at, _)| at.hour() == 1)
            .map(|(at, bps)| (*at, bps * 10))
            .collect();
        let mut with_dst = base;
        with_dst.extend(dst);
        let mut with_dups = with_dst.clone();
        with_dups.extend(outliers);
        let expected = BestTime::Window {
            start_min: 600,
            end_min: 840,
            typical_bps: 100_000_000,
            days: 9,
            confidence: Confidence::Medium,
        };
        assert_eq!(best_window(&with_dst, 4), expected);
        assert_eq!(best_window(&with_dups, 4), expected);
    }

    #[test]
    fn high_needs_five_per_hour() {
        let mut s = samples(14, 1, fast_1_to_4);
        s.retain(|(at, _)| !((1..=4).contains(&at.hour()) && at.date().day() > 4));
        assert!(matches!(best_window(&s, 4), BestTime::Window { confidence: Confidence::Medium, .. }));
    }

    #[test]
    fn no_fully_covered_window() {
        let mut s = samples(8, 5, fast_1_to_4);
        let mut kept = [0; 24];
        s.retain(|(at, _)| {
            let h = at.hour() as usize;
            if h.is_multiple_of(4) {
                kept[h] += 1;
                kept[h] <= 2
            } else {
                true
            }
        });
        assert_eq!(best_window(&s, 4), BestTime::NotEnoughData { days: 8, needed: 7 });
    }

    #[test]
    fn typical_bps_at_needs_three_samples_and_takes_even_median() {
        assert_eq!(typical_bps_at(&samples(1, 2, |_| 7), 3), None);
        assert_eq!(typical_bps_at(&samples(1, 3, |_| 7), 3), Some(7));
        let even: Vec<_> = [10u64, 40, 20, 30].iter().map(|&b| (date(2026, 10, 1).at(3, 0, 0, 0), b)).collect();
        assert_eq!(typical_bps_at(&even, 3), Some(25));
    }

    fn run_minute(s: &mut Sampler, bps: u64, running: bool, limited_at: Option<i64>, net: NetworkKind) -> Option<SpeedSample> {
        for t in (0..60).step_by(5) {
            assert_eq!(s.observe(t, bps, running, limited_at == Some(t), net), None);
        }
        s.observe(60, bps, true, false, net)
    }

    #[test]
    fn full_minute_sampled() {
        let got = run_minute(&mut Sampler::default(), 1_000_000, true, None, NetworkKind::Wifi);
        assert_eq!(got, Some(SpeedSample { at: 0, bps: 1_000_000, source: SampleSource::Downloads, network: NetworkKind::Wifi }));
    }

    #[test]
    fn limited_minute_not_sampled() {
        assert_eq!(run_minute(&mut Sampler::default(), 1_000_000, true, Some(25), NetworkKind::Wifi), None);
    }

    #[test]
    fn idle_tick_not_sampled() {
        let mut s = Sampler::default();
        for t in (0..60).step_by(5) {
            s.observe(t, 1_000_000, t != 30, false, NetworkKind::Wifi);
        }
        assert_eq!(s.observe(60, 1_000_000, true, false, NetworkKind::Wifi), None);
    }

    #[test]
    fn slow_not_sampled() {
        assert_eq!(run_minute(&mut Sampler::default(), 40_000, true, None, NetworkKind::Wifi), None);
    }

    #[test]
    fn expensive_not_sampled() {
        assert_eq!(run_minute(&mut Sampler::default(), 1_000_000, true, None, NetworkKind::Expensive), None);
        assert_eq!(run_minute(&mut Sampler::default(), 1_000_000, true, None, NetworkKind::Unknown), None);
    }

    #[test]
    fn next_minute_starts_clean() {
        let mut s = Sampler::default();
        run_minute(&mut s, 1_000_000, true, Some(25), NetworkKind::Wifi);
        let got = (65..=120).step_by(5).find_map(|t| s.observe(t, 1_000_000, true, false, NetworkKind::Wired));
        assert_eq!(got.map(|g| (g.at, g.network)), Some((60, NetworkKind::Wired)));
    }
}
