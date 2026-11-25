//! On-demand speed test: latency, then parallel downloads from a Cloudflare-style `/__down?bytes=N` endpoint.
use crate::scheduler::Scheduler;
use crate::events::EventHub;
use crate::types::{JobEvent, SpeedTestPhase};
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

async fn cancelled(cancel: &AtomicBool) {
    while !cancel.load(Ordering::Relaxed) {
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

async fn latency_ms(client: &reqwest::Client, base: &str, hub: &EventHub, total: Duration, cancel: &AtomicBool) -> Result<u32, EngineError> {
    let never = AtomicBool::new(false);
    let mut times = Vec::new();
    for _ in 0..5 {
        let start = Instant::now();
        let probe = fetch(client, base, 0, &never, start + Duration::from_secs(2), |_| {});
        let done = tokio::select! {
            done = probe => done?,
            () = cancelled(cancel) => return Err(stopped()),
        };
        if !done {
            return Err(unreachable());
        }
        times.push(start.elapsed().as_millis() as u32);
        // Each probe is a sign of life, so the app keeps the indicator through a slow phase.
        progress(hub, SpeedTestPhase::Latency, 0, Duration::ZERO, total);
    }
    times.sort_unstable();
    Ok(times[2])
}

fn stopped() -> EngineError {
    EngineError::Io { msg: "Speed test stopped".into() }
}

fn progress(hub: &EventHub, phase: SpeedTestPhase, bps: u64, elapsed: Duration, total: Duration) {
    hub.speed_progress(JobEvent::SpeedTestProgress {
        phase,
        bps,
        elapsed_ms: elapsed.as_millis() as u32,
        total_ms: total.as_millis() as u32,
    });
}

/// Bytes per second over the run, skipping the first tenth (1 s of the default 10 s) for TCP slow start.
async fn throughput(
    client: &reqwest::Client,
    base: &str,
    total: Duration,
    hub: &EventHub,
    cancel: &AtomicBool,
) -> Result<u64, EngineError> {
    let bytes = Arc::new(AtomicU64::new(0));
    let stop = Arc::new(AtomicBool::new(false));
    let (started, skip) = (Instant::now(), total / 10);
    let deadline = started + total;
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
    let mut warm: Option<(u64, Instant)> = None;
    let mut last_tick = started;
    let rate = |warm: Option<(u64, Instant)>, now: Instant| match warm {
        Some((b0, t0)) if now > t0 => (bytes.load(Ordering::Relaxed).saturating_sub(b0) as f64 / (now - t0).as_secs_f64()) as u64,
        _ => 0,
    };
    loop {
        let now = Instant::now();
        if cancel.load(Ordering::Relaxed) {
            tasks.iter().for_each(|t| t.abort());
            return Err(stopped());
        }
        if stop.load(Ordering::Relaxed) || now >= deadline {
            break;
        }
        if warm.is_none() && now - started >= skip {
            warm = Some((bytes.load(Ordering::Relaxed), now));
        }
        if now - last_tick >= Duration::from_millis(250) {
            last_tick = now;
            progress(hub, SpeedTestPhase::Download, rate(warm, now), now - started, total);
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let bps = rate(warm.or(Some((0, started))), Instant::now());
    stop.store(true, Ordering::Relaxed);
    for task in tasks {
        task.await.map_err(|_| unreachable())??;
    }
    if cancel.load(Ordering::Relaxed) {
        return Err(stopped());
    }
    if bytes.load(Ordering::Relaxed) < START_BYTES {
        return Err(unreachable());
    }
    progress(hub, SpeedTestPhase::Download, bps, total, total);
    Ok(bps)
}

/// Runs one test and announces how it ended, on every path.
pub async fn run(sched: &Scheduler, base: &str, ms: u64, force: bool, cancel: &AtomicBool) -> Result<SpeedTestResult, EngineError> {
    if sched.testing().swap(true, Ordering::SeqCst) {
        return Err(EngineError::Io { msg: "A speed test is already running.".into() });
    }
    let _guard = Testing(sched.testing());
    let result = measure(sched, base, ms, force, cancel).await;
    sched.hub().speed_progress(JobEvent::SpeedTestEnded {
        saved: result.as_ref().is_ok_and(|r| r.saved),
        error: result.as_ref().err().map(ToString::to_string),
    });
    result
}

struct Testing<'a>(&'a AtomicBool);

impl Drop for Testing<'_> {
    fn drop(&mut self) {
        self.0.store(false, Ordering::SeqCst);
    }
}

async fn measure(sched: &Scheduler, base: &str, ms: u64, force: bool, cancel: &AtomicBool) -> Result<SpeedTestResult, EngineError> {
    let network = sched.network();
    if !force {
        let msg = match network {
            NetworkKind::Expensive => "You're on a hotspot or metered connection. A test uses about 50 to 200 MB.",
            NetworkKind::Unknown => "Rays can't tell what network this is yet. Try again in a moment.",
            _ => "",
        };
        if !msg.is_empty() {
            return Err(EngineError::Io { msg: msg.into() });
        }
    }
    let busy = sched.any_running();
    let (client, base, total) = (sched.client(), base.trim_end_matches('/'), Duration::from_millis(ms));
    progress(sched.hub(), SpeedTestPhase::Latency, 0, Duration::ZERO, total);
    let latency_ms = latency_ms(client, base, sched.hub(), total, cancel).await?;
    let bps = throughput(client, base, total, sched.hub(), cancel).await?;
    let at = sched.now_secs();
    // A metered or unknown link never feeds the history, even when the user forced the test.
    let saved = matches!(network, NetworkKind::Wifi | NetworkKind::Wired | NetworkKind::Other) && !busy && !sched.any_running();
    if saved {
        sched.store().add_sample(&SpeedSample { at, bps, source: SampleSource::Test, network })?;
        sched.store().set_setting(LATENCY_KEY, Some(&latency_ms.to_string()))?;
    }
    Ok(SpeedTestResult { bps, latency_ms, at, saved })
}

pub fn last(sched: &Scheduler) -> Option<SpeedTestResult> {
    let store = sched.store();
    let sample = store.last_test().ok()??;
    let latency_ms = store.setting(LATENCY_KEY).ok().flatten().and_then(|v| v.parse().ok()).unwrap_or(0);
    Some(SpeedTestResult { bps: sample.bps, latency_ms, at: sample.at, saved: true })
}

/// One minute of the automatic tests: runs a test if this minute was planned, on Wi-Fi or wired, with no download running.
pub async fn auto(sched: &Arc<Scheduler>, base: &str, ms: u64) {
    if sched.auto_test_due() && matches!(sched.network(), NetworkKind::Wifi | NetworkKind::Wired) && !sched.any_running() {
        let _ = run(sched, base, ms, false, &AtomicBool::new(false)).await;
    }
}
