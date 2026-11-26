//! Download totals for the Stats page, read from finished jobs and speed samples.
use crate::speed::SpeedSample;
use std::collections::BTreeMap;

const TOP_HOSTS: usize = 8;

#[derive(uniffi::Record, Clone, Debug, Default, PartialEq, Eq)]
pub struct DayTotal {
    /// Unix seconds at local midnight.
    pub day: i64,
    pub bytes: u64,
    pub files: u64,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct HostTotal {
    pub host: String,
    pub bytes: u64,
    pub files: u64,
}

#[derive(uniffi::Record, Clone, Debug, Default, PartialEq, Eq)]
pub struct Stats {
    pub total_bytes: u64,
    pub total_files: u64,
    /// Every day of the window, oldest first.
    pub per_day: Vec<DayTotal>,
    pub top_hosts: Vec<HostTotal>,
    pub avg_bps: Option<u64>,
    pub peak_bps: Option<u64>,
}

/// A finished download: link, size in bytes and finish time in unix seconds.
pub type Finished = (String, u64, i64);

/// Local midnights of the `days` days ending on `today`, oldest first.
pub fn local_midnights(today: jiff::civil::Date, days: u32, tz: &jiff::tz::TimeZone) -> Vec<i64> {
    (0..days)
        .rev()
        .filter_map(|i| {
            let day = today.checked_sub(jiff::Span::new().days(i64::from(i))).ok()?;
            Some(day.at(0, 0, 0, 0).to_zoned_datetime(tz.clone()).ok()?.timestamp().as_second())
        })
        .collect()
}

/// Site a link counts under: the host without `www.`, or `s3://bucket`.
pub fn host_of(url: &str) -> String {
    let Ok(u) = reqwest::Url::parse(url) else { return "unknown".into() };
    let host = u.host_str().unwrap_or("unknown");
    if u.scheme() == "s3" { format!("s3://{host}") } else { host.strip_prefix("www.").unwrap_or(host).to_owned() }
}

/// `midnights` are the window's day starts, oldest first; downloads and samples before the first are ignored.
pub fn compute(finished: &[Finished], midnights: &[i64], samples: &[SpeedSample]) -> Stats {
    let Some(&start) = midnights.first() else { return Stats::default() };
    let mut per_day: Vec<DayTotal> = midnights.iter().map(|&day| DayTotal { day, ..Default::default() }).collect();
    let mut hosts: BTreeMap<String, (u64, u64)> = BTreeMap::new();
    let (mut total_bytes, mut total_files) = (0, 0);
    for (url, bytes, at) in finished.iter().filter(|f| f.2 >= start) {
        let i = midnights.partition_point(|&d| d <= *at) - 1;
        per_day[i].bytes += bytes;
        per_day[i].files += 1;
        let h = hosts.entry(host_of(url)).or_default();
        h.0 += bytes;
        h.1 += 1;
        total_bytes += bytes;
        total_files += 1;
    }
    let mut top_hosts: Vec<HostTotal> = hosts.into_iter().map(|(host, (bytes, files))| HostTotal { host, bytes, files }).collect();
    top_hosts.sort_by_key(|h| std::cmp::Reverse(h.bytes));
    top_hosts.truncate(TOP_HOSTS);
    let bps: Vec<u64> = samples.iter().filter(|s| s.at >= start && s.source == crate::speed::SampleSource::Downloads).map(|s| s.bps).collect();
    let avg_bps = (!bps.is_empty()).then(|| bps.iter().sum::<u64>() / bps.len() as u64);
    Stats { total_bytes, total_files, per_day, top_hosts, avg_bps, peak_bps: bps.iter().copied().max() }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::speed::{NetworkKind, SampleSource};

    const DAY: i64 = 86_400;

    fn days(n: i64) -> Vec<i64> {
        (0..n).map(|i| 1000 * DAY + i * DAY).collect()
    }

    fn f(url: &str, bytes: u64, at: i64) -> Finished {
        (url.into(), bytes, at)
    }

    fn sample(at: i64, bps: u64) -> SpeedSample {
        SpeedSample { at, bps, source: SampleSource::Downloads, network: NetworkKind::Other }
    }

    #[test]
    fn empty_input_is_zero_filled_with_no_speed() {
        let s = compute(&[], &days(3), &[]);
        assert_eq!((s.total_bytes, s.total_files, s.avg_bps, s.peak_bps), (0, 0, None, None));
        let got: Vec<_> = s.per_day.iter().map(|d| (d.day, d.bytes, d.files)).collect();
        assert_eq!(got, vec![(1000 * DAY, 0, 0), (1001 * DAY, 0, 0), (1002 * DAY, 0, 0)]);
        assert!(s.top_hosts.is_empty());
    }

    #[test]
    fn downloads_land_on_their_day_and_older_ones_are_cut() {
        let rows = [f("https://a.com/x", 10, 1000 * DAY), f("https://a.com/y", 5, 1001 * DAY - 1), f("https://a.com/z", 7, 1002 * DAY + 5), f("https://a.com/old", 99, 1000 * DAY - 1)];
        let s = compute(&rows, &days(3), &[]);
        assert_eq!(s.per_day.iter().map(|d| (d.bytes, d.files)).collect::<Vec<_>>(), vec![(15, 2), (0, 0), (7, 1)]);
        assert_eq!((s.total_bytes, s.total_files), (22, 3));
    }

    #[test]
    fn hosts_drop_www_and_group_s3_by_bucket() {
        let rows = [
            f("https://www.example.com/a", 10, 1000 * DAY),
            f("https://example.com/b", 20, 1000 * DAY),
            f("s3://media/k1", 5, 1000 * DAY),
            f("s3://media/dir/k2", 6, 1000 * DAY),
        ];
        let hosts = compute(&rows, &days(1), &[]).top_hosts;
        assert_eq!(hosts, vec![HostTotal { host: "example.com".into(), bytes: 30, files: 2 }, HostTotal { host: "s3://media".into(), bytes: 11, files: 2 }]);
    }

    #[test]
    fn top_hosts_keeps_the_eight_biggest() {
        let rows: Vec<Finished> = (0..10).map(|i| f(&format!("https://h{i}.com/f"), 100 + i, 1000 * DAY)).collect();
        let hosts = compute(&rows, &days(1), &[]).top_hosts;
        assert_eq!(hosts.len(), 8);
        assert_eq!((hosts[0].host.as_str(), hosts[7].host.as_str()), ("h9.com", "h2.com"));
    }

    #[test]
    fn speed_comes_from_samples_inside_the_window() {
        let s = compute(&[], &days(2), &[sample(1000 * DAY - 1, 9_000), sample(1000 * DAY, 100), sample(1001 * DAY, 300)]);
        assert_eq!((s.avg_bps, s.peak_bps), (Some(200), Some(300)));
    }

    #[test]
    fn midnights_are_one_per_day_oldest_first() {
        let tz = jiff::tz::TimeZone::UTC;
        let m = local_midnights(jiff::civil::date(2026, 3, 3), 3, &tz);
        let day = |d| jiff::civil::date(2026, 3, d).at(0, 0, 0, 0).to_zoned_datetime(tz.clone()).unwrap().timestamp().as_second();
        assert_eq!(m, vec![day(1), day(2), day(3)]);
    }
}
