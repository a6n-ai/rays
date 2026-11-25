//! On-demand speed test: latency, then parallel downloads from a Cloudflare-style `/__down?bytes=N` endpoint.
use crate::scheduler::Scheduler;
use crate::speed::{NetworkKind, SampleSource, SpeedSample};
use crate::types::EngineError;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::{Duration, Instant};

pub const DEFAULT_BASE: &str = "https://speed.cloudflare.com";
pub const DEFAULT_MS: u64 = 10_000;
const LATENCY_KEY: &str = "last_test_latency_ms";
const CONNECTIONS: usize = 4;
const START_BYTES: u64 = 1 << 20;
const MAX_BYTES: u64 = 64 << 20;
/// speed.cloudflare.com answers 403 for sizes from about 10.5 MB to 19.5 MB, so the ladder jumps over 16 MB.
const SKIPPED: u64 = 16 << 20;

#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct SpeedTestResult {
    pub bps: u64,
    pub latency_ms: u32,
    /// Unix seconds.
    pub at: i64,
    /// False when downloads ran during the test, which skews it.
    pub saved: bool,
}

fn unreachable() -> EngineError {
    EngineError::Io { msg: "Couldn't reach the speed test server. Check your connection or proxy.".into() }
}

/// Fetches `bytes` from the server and feeds each chunk length to `on_bytes` until `stop` is set.
/// Returns false when `deadline` passed first; a stalled server must not outlast it.
async fn fetch(
    client: &reqwest::Client,
    base: &str,
    bytes: u64,
    stop: &AtomicBool,
    deadline: Instant,
    mut on_bytes: impl FnMut(u64),
) -> Result<bool, EngineError> {
    let left = || deadline.saturating_duration_since(Instant::now());
    let Ok(sent) = tokio::time::timeout(left(), client.get(format!("{base}/__down?bytes={bytes}")).send()).await else {
        return Ok(false);
    };
    let mut resp = sent.map_err(|_| unreachable())?;
    let html = resp.headers().get(reqwest::header::CONTENT_TYPE).and_then(|v| v.to_str().ok()).is_some_and(|v| v.contains("text/html"));
    if !resp.status().is_success() || html {
        return Err(unreachable());
    }
    let mut got = 0;
    while !stop.load(Ordering::Relaxed) {
        let Ok(next) = tokio::time::timeout(left(), resp.chunk()).await else { return Ok(false) };
        match next.map_err(|_| unreachable())? {
            Some(chunk) => {
                got += chunk.len() as u64;
                on_bytes(chunk.len() as u64);
            }
            // A server that ends the body early is not the speed test server.
            None if got < bytes => return Err(unreachable()),
            None => break,
        }
    }
    Ok(true)
}

async fn latency_ms(client: &reqwest::Client, base: &str) -> Result<u32, EngineError> {
    let never = AtomicBool::new(false);
    let mut times = Vec::new();
    for _ in 0..5 {
        let start = Instant::now();
        if !fetch(client, base, 0, &never, start + Duration::from_secs(2), |_| {}).await? {
            return Err(unreachable());
        }
        times.push(start.elapsed().as_millis() as u32);
    }
    times.sort_unstable();
    Ok(times[2])
}

/// Bytes per second over the run, skipping the first tenth (1 s of the default 10 s) for TCP slow start.
async fn throughput(client: &reqwest::Client, base: &str, total: Duration) -> Result<u64, EngineError> {
    let bytes = Arc::new(AtomicU64::new(0));
    let stop = Arc::new(AtomicBool::new(false));
    let deadline = Instant::now() + total;
    let tasks: Vec<_> = (0..CONNECTIONS)
        .map(|_| {
            let (client, base, bytes, stop) = (client.clone(), base.to_owned(), Arc::clone(&bytes), Arc::clone(&stop));
            tokio::spawn(async move {
                let mut size = START_BYTES;
                while !stop.load(Ordering::Relaxed) && Instant::now() < deadline {
                    let done = fetch(&client, &base, size, &stop, deadline, |n| {
                        bytes.fetch_add(n, Ordering::Relaxed);
                    })
                    .await;
                    if done.is_err() {
                        stop.store(true, Ordering::Relaxed);
                    }
                    done?;
                    size = (size * 2).min(MAX_BYTES);
                    if size == SKIPPED {
                        size *= 2;
                    }
                }
                Ok::<(), EngineError>(())
            })
        })
        .collect();
    let wait = |until: Instant| {
        let stop = Arc::clone(&stop);
        async move {
            while Instant::now() < until && !stop.load(Ordering::Relaxed) {
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
        }
    };
    wait(Instant::now() + total / 10).await;
    let (from_bytes, from) = (bytes.load(Ordering::Relaxed), Instant::now());
    wait(deadline).await;
    let (to_bytes, secs) = (bytes.load(Ordering::Relaxed), from.elapsed().as_secs_f64());
    stop.store(true, Ordering::Relaxed);
    for task in tasks {
        task.await.map_err(|_| unreachable())??;
    }
    if to_bytes < START_BYTES {
        return Err(unreachable());
    }
    Ok((to_bytes.saturating_sub(from_bytes) as f64 / secs) as u64)
}

pub async fn run(sched: &Scheduler, base: &str, ms: u64, force: bool) -> Result<SpeedTestResult, EngineError> {
    let network = sched.network();
    if network == NetworkKind::Expensive && !force {
        return Err(EngineError::Io {
            msg: "You're on a hotspot or metered connection. A test uses about 50 to 200 MB.".into(),
        });
    }
    let busy = sched.any_running();
    let (client, base) = (sched.client(), base.trim_end_matches('/'));
    let latency_ms = latency_ms(client, base).await?;
    let bps = throughput(client, base, Duration::from_millis(ms)).await?;
    let at = sched.now_secs();
    let saved = !busy && !sched.any_running();
    if saved {
        sched.store().add_sample(&SpeedSample { at, bps, source: SampleSource::Test, network })?;
        sched.store().set_setting(LATENCY_KEY, Some(&latency_ms.to_string()))?;
    }
    Ok(SpeedTestResult { bps, latency_ms, at, saved })
}

pub fn last(sched: &Scheduler) -> Option<SpeedTestResult> {
    let store = sched.store();
    let sample = store.samples_since(0).ok()?.into_iter().rev().find(|s| s.source == SampleSource::Test)?;
    let latency_ms = store.setting(LATENCY_KEY).ok().flatten().and_then(|v| v.parse().ok()).unwrap_or(0);
    Some(SpeedTestResult { bps: sample.bps, latency_ms, at: sample.at, saved: true })
}

/// One minute of the automatic tests: runs a test if this minute was planned, on Wi-Fi or wired, with no download running.
pub async fn auto(sched: &Arc<Scheduler>, base: &str, ms: u64) {
    if sched.auto_test_due() && matches!(sched.network(), NetworkKind::Wifi | NetworkKind::Wired) && !sched.any_running() {
        let _ = run(sched, base, ms, false).await;
    }
}
