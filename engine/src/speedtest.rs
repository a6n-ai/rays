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
async fn fetch(
    client: &reqwest::Client,
    base: &str,
    bytes: u64,
    stop: &AtomicBool,
    mut on_bytes: impl FnMut(u64),
) -> Result<(), EngineError> {
    let mut resp = client.get(format!("{base}/__down?bytes={bytes}")).send().await.map_err(|_| unreachable())?;
    let html = resp.headers().get(reqwest::header::CONTENT_TYPE).and_then(|v| v.to_str().ok()).is_some_and(|v| v.contains("text/html"));
    if !resp.status().is_success() || html {
        return Err(unreachable());
    }
    while !stop.load(Ordering::Relaxed) {
        match resp.chunk().await.map_err(|_| unreachable())? {
            Some(chunk) => on_bytes(chunk.len() as u64),
            None => break,
        }
    }
    Ok(())
}

async fn latency_ms(client: &reqwest::Client, base: &str) -> Result<u32, EngineError> {
    let never = AtomicBool::new(false);
    let mut times = Vec::new();
    for _ in 0..5 {
        let start = Instant::now();
        fetch(client, base, 0, &never, |_| {}).await?;
        times.push(start.elapsed().as_millis() as u32);
    }
    times.sort_unstable();
    Ok(times[2])
}

/// Bytes per second over the run, skipping the first tenth (1 s of the default 10 s) for TCP slow start.
async fn throughput(client: &reqwest::Client, base: &str, total: Duration) -> Result<u64, EngineError> {
    let bytes = Arc::new(AtomicU64::new(0));
    let stop = Arc::new(AtomicBool::new(false));
    let tasks: Vec<_> = (0..CONNECTIONS)
        .map(|_| {
            let (client, base, bytes, stop) = (client.clone(), base.to_owned(), Arc::clone(&bytes), Arc::clone(&stop));
            tokio::spawn(async move {
                let mut size = START_BYTES;
                while !stop.load(Ordering::Relaxed) {
                    fetch(&client, &base, size, &stop, |n| {
                        bytes.fetch_add(n, Ordering::Relaxed);
                    })
                    .await?;
                    size = (size * 2).min(MAX_BYTES);
                }
                Ok::<(), EngineError>(())
            })
        })
        .collect();
    tokio::time::sleep(total / 10).await;
    let (from_bytes, from) = (bytes.load(Ordering::Relaxed), Instant::now());
    tokio::time::sleep(total - total / 10).await;
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
