//! One download (all retry attempts) for one job. See design doc "Download task".
//! A file is fetched as one stream, or, when the server supports ranges and the file is large, as segments
//! on several connections that write into one preallocated `.part` file.
use crate::events::EventHub;
use crate::limit::RateLimiter;
use crate::names;
use crate::store::MAX_PARTS;
use crate::types::{Job, JobId, JobState, Live, Outcome, Segment};
use reqwest::header::{
    ACCEPT_RANGES, CONTENT_DISPOSITION, CONTENT_RANGE, ETAG, HeaderName, IF_RANGE, LAST_MODIFIED, RANGE,
};
use std::collections::VecDeque;
use std::future::Future;
use std::io::SeekFrom;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock, PoisonError};
use std::time::{Duration, Instant};
use tokio::io::{AsyncSeekExt, AsyncWriteExt};
use tokio::sync::watch;
use tokio::task::JoinSet;

/// Wait before retry attempt n (1-based); 5 attempts max.
pub const RETRY_WAITS: [u64; 5] = [2, 5, 15, 30, 60];

/// A connection that sends nothing for this long counts as a failed attempt.
const STALL: Duration = Duration::from_secs(30);
/// Smaller files are never split; no segment is smaller than `MIN_SEGMENT`.
const MIN_SPLIT: u64 = 4 << 20;
const MIN_SEGMENT: u64 = 1 << 20;
/// Split points are rounded down to this, so ranges start on round offsets.
const SPLIT_ALIGN: u64 = 64 << 10;
/// The connection count is judged on 2 s windows of total throughput, sampled every `TICK`.
const TICK: Duration = Duration::from_secs(1);
/// Ticks ignored after a change, then the ticks whose throughput judges it. One warm tick lets a new connection
/// get past its TLS handshake and slow start before it is judged; each probe then takes 3 s instead of 4 s.
const WARM_TICKS: u8 = 1;
const WINDOW_TICKS: u8 = 2;
/// A held connection count is re-checked this often.
const HOLD_TICKS: u8 = 15;
/// Connection failures this close together on different segments suggest the server blocks extra connections.
const CONN_FAIL_WINDOW: Duration = Duration::from_secs(10);

/// Runs until the file is complete, `cancel` turns true (-> `Outcome::Paused`), or it fails for good.
/// Mutates `live.job` (state, total, etag, last_modified, resumable, segments) and `live.done`/`live.connections`,
/// calling `hub.state_changed` / `hub.progress`. `store` is only used to save a split plan before the
/// file is preallocated (None in tests that don't need crash safety).
#[allow(clippy::too_many_arguments)]
pub async fn run(
    live: Arc<Live>,
    client: reqwest::Client,
    downloads_dir: &Path,
    hub: Arc<EventHub>,
    mut cancel: watch::Receiver<bool>,
    connections: u32,
    start: u32,
    limiter: Arc<RateLimiter>,
    store: Option<Arc<crate::store::Store>>,
    sign: Option<SignUrl>,
) -> Outcome {
    let env = Env {
        live,
        client,
        dir: downloads_dir.to_path_buf(),
        hub,
        connections,
        start,
        limiter,
        store,
        sign,
        retry_hint: Arc::new(AtomicU64::new(0)),
        dirty: Arc::new(AtomicBool::new(false)),
    };
    // Failed tries in a row; equals the retry number while waiting (1..=5).
    let mut attempt: u8 = 0;
    let mut split_allowed = true;
    loop {
        if *cancel.borrow() {
            return Outcome::Paused;
        }
        let mut received = 0;
        let err = match run_attempt(&env, &mut cancel, &mut received, split_allowed).await {
            Ok(outcome) => {
                if matches!(outcome, Outcome::Done(_)) && !env.dirty.load(Ordering::Relaxed) {
                    env.relax_host();
                }
                return outcome;
            }
            Err(Stop::Paused) => return Outcome::Paused,
            Err(Stop::Failed(reason)) => return Outcome::Failed(reason),
            Err(Stop::Fallback) => {
                // The server stopped honouring ranges: start over as one stream and never split again.
                split_allowed = false;
                attempt = 0;
                continue;
            }
            Err(Stop::Retry(err)) => {
                env.dirty.store(true, Ordering::Relaxed);
                err
            }
        };
        attempt = if received > 0 { 1 } else { attempt + 1 };
        if usize::from(attempt) > RETRY_WAITS.len() {
            return Outcome::Failed(err);
        }
        let id = with_job(&env.live, |j| {
            j.state = JobState::Retrying { attempt };
            j.id
        });
        env.hub.state_changed(id);
        tokio::select! {
            biased;
            _ = cancelled(&mut cancel) => return Outcome::Paused,
            _ = tokio::time::sleep(env.next_wait(attempt)) => {}
        }
        with_job(&env.live, |j| j.state = JobState::Running);
        env.hub.state_changed(id);
    }
}

/// Why an attempt stopped before finishing.
enum Stop {
    /// The run was cancelled (pause, remove, shutdown).
    Paused,
    /// Ranges stopped working mid-split; the file must be restarted as one stream.
    Fallback,
    /// Terminal for the job.
    Failed(String),
    /// Retryable; the message is the last error.
    Retry(String),
}

impl From<std::io::Error> for Stop {
    fn from(e: std::io::Error) -> Stop {
        Stop::Retry(format!("io: {e}"))
    }
}

/// Returns a freshly signed URL for the job's object; see `crate::s3`.
pub type SignUrl = Arc<dyn Fn() -> String + Send + Sync>;

/// What one run needs, cheap to clone into the segment tasks.
#[derive(Clone)]
struct Env {
    live: Arc<Live>,
    client: reqwest::Client,
    dir: PathBuf,
    hub: Arc<EventHub>,
    connections: u32,
    /// Parts a fresh split starts on (the app uses 1); growth adds more only when they pay.
    start: u32,
    limiter: Arc<RateLimiter>,
    store: Option<Arc<crate::store::Store>>,
    /// Makes a fresh signed URL for each request (S3 links); `None` uses the job URL as is.
    sign: Option<SignUrl>,
    /// Server-requested wait (Retry-After), in ms, consumed by the next retry sleep.
    retry_hint: Arc<AtomicU64>,
    /// Set by a retry, a 429/503 or a connection failure; a run that set it keeps the remembered limit.
    dirty: Arc<AtomicBool>,
}

/// Counts one transferring connection; dropping it decrements on every exit path.
struct Transfer(Arc<Live>);

impl Transfer {
    fn start(live: &Arc<Live>) -> Transfer {
        live.connections.fetch_add(1, Ordering::Relaxed);
        Transfer(Arc::clone(live))
    }
}

impl Drop for Transfer {
    fn drop(&mut self) {
        self.0.connections.fetch_sub(1, Ordering::Relaxed);
    }
}

/// Resolves with `Err(Stop::Paused)` if `cancel` fires before `fut`.
async fn or_cancel<T>(cancel: &mut watch::Receiver<bool>, fut: impl Future<Output = T>) -> Result<T, Stop> {
    tokio::select! {
        biased;
        _ = cancelled(cancel) => Err(Stop::Paused),
        x = fut => Ok(x),
    }
}

/// One pass over the file: a resumed split, a freshly planned split, or a single stream.
async fn run_attempt(
    env: &Env,
    cancel: &mut watch::Receiver<bool>,
    received: &mut u64,
    split_allowed: bool,
) -> Result<Outcome, Stop> {
    let (id, url, part, validator, has_plan) = with_job(&env.live, |j| {
        (
            j.id,
            j.url.clone(),
            j.part_path.clone(),
            j.etag.clone().or_else(|| j.last_modified.clone()),
            !j.segments.is_empty(),
        )
    });
    if has_plan {
        return run_split(env, cancel, false, None).await;
    }
    let have = tokio::fs::metadata(&part).await.map(|m| m.len()).unwrap_or(0);

    let mut req = env.client.get(env.request_url(&url));
    if have > 0 {
        req = req.header(RANGE, format!("bytes={have}-"));
        if let Some(v) = &validator {
            req = req.header(IF_RANGE, v.as_str());
        }
    }
    let mut resp = or_cancel(cancel, tokio::time::timeout(STALL, req.send()))
        .await?
        .map_err(|_| Stop::Retry("timeout waiting for response".to_string()))?
        .map_err(|e| Stop::Retry(format!("request: {e}")))?;

    let status = resp.status().as_u16();
    match status {
        416 => {
            // Only "complete" if the server's total matches what is on disk; a stray .part of another
            // size (or a missing Content-Range) must not be renamed into a finished file.
            let server_total = header(&resp, reqwest::header::CONTENT_RANGE)
                .and_then(|v| v.rsplit('/').next().and_then(|t| t.trim().parse::<u64>().ok()));
            let on_disk = tokio::fs::metadata(&part).await.map(|m| m.len()).ok();
            if server_total.is_some() && server_total == on_disk {
                return finish(env).await;
            }
            tokio::fs::File::create(&part).await?;
            env.live.done.store(0, Ordering::Relaxed);
            return Err(Stop::Retry("range not satisfiable; restarting from zero".to_string()));
        }
        200 | 206 => {}
        s if retryable(s) => {
            env.note_retry_after(&resp);
            return Err(Stop::Retry(format!("HTTP {status}")));
        }
        _ => return Err(Stop::Failed(format!("HTTP {status}"))),
    }

    let ranged = status == 206;
    let start = if ranged { have } else { 0 };
    let accept_ranges = header(&resp, ACCEPT_RANGES).is_some_and(|v| v.eq_ignore_ascii_case("bytes"));
    let total = content_range_total(&resp).or_else(|| resp.content_length().map(|len| start + len));
    let disposition = header(&resp, CONTENT_DISPOSITION).and_then(|d| names::from_disposition(&d));
    let (etag, last_modified) = (header(&resp, ETAG), header(&resp, LAST_MODIFIED));
    with_job(&env.live, |j| {
        if etag.is_some() {
            j.etag = etag;
        }
        if last_modified.is_some() {
            j.last_modified = last_modified;
        }
        if let Some(name) = disposition {
            j.name = name;
        }
        if total.is_some() {
            j.total = total;
        }
        j.resumable = ranged || accept_ranges;
    });
    env.hub.state_changed(id);

    // The user's setting is the maximum; a server that blocked us before caps it lower.
    let host_cap = host_of(&url).and_then(|h| env.store.as_ref()?.host_limit(&h).ok().flatten()).map(|(n, _)| n);
    let cap = env.connections.min(MAX_PARTS).min(host_cap.unwrap_or(MAX_PARTS));
    let split = total.filter(|&t| have == 0 && split_allowed && cap > 1 && (ranged || accept_ranges) && t >= MIN_SPLIT);
    if let Some(total) = split {
        // The plan must be on disk before preallocating: a full-size .part without a saved plan would be
        // mistaken for a finished single-stream download after a crash.
        let segments = plan(total, u64::from(env.start.min(cap)));
        let job = with_job(&env.live, |j| {
            j.segments = segments;
            j.clone()
        });
        if let Some(store) = &env.store {
            store.save(&job).map_err(|e| Stop::Retry(e.to_string()))?;
        }
        let file = tokio::fs::File::create(&part).await?;
        file.set_len(total).await?;
        drop(file);
        env.hub.state_changed(id);
        let split_env = Env { connections: cap, ..env.clone() };
        return run_split(&split_env, cancel, true, Some(resp)).await;
    }

    let mut opts = tokio::fs::OpenOptions::new();
    opts.create(true);
    if ranged {
        opts.append(true);
    } else {
        opts.write(true).truncate(true);
    }
    let mut file = opts.open(&part).await?;

    let transfer = Transfer::start(&env.live);
    let mut offset = start;
    env.live.done.store(offset, Ordering::Relaxed);
    loop {
        let chunk = or_cancel(cancel, tokio::time::timeout(STALL, resp.chunk()))
            .await?
            .map_err(|_| Stop::Retry("timeout: no data for 30 s".to_string()))?
            .map_err(|e| Stop::Retry(format!("body: {e}")))?;
        let Some(bytes) = chunk else { break };
        or_cancel(cancel, env.limiter.acquire(bytes.len())).await?;
        file.write_all(&bytes).await?;
        let n = bytes.len() as u64;
        offset += n;
        *received += n;
        env.live.done.store(offset, Ordering::Relaxed);
        env.hub.progress(id);
    }
    // tokio buffers writes, and dropping the File does not flush them.
    file.flush().await?;
    drop(file);
    drop(transfer);
    with_job(&env.live, |j| j.done = offset);
    finish(env).await
}

/// Each extra connection must bring this much more speed to be worth its cost (the 1.02^n in speed / 1.02^n).
const PENALTY: f64 = 1.02;

/// `parts` equal segments, aligned. Segment 0 streams on the probe's own connection, so starting on one part
/// costs no extra request and a link one connection already fills never pays for splitting.
fn plan(total: u64, parts: u64) -> Vec<Segment> {
    let parts = parts.max(1);
    let step = total / parts / SPLIT_ALIGN * SPLIT_ALIGN;
    (0..parts)
        .map(|i| Segment { start: i * step, end: if i + 1 == parts { total } else { (i + 1) * step }, done: 0 })
        .collect()
}

/// Sets the connection count of a split run. It probes one connection up and keeps it only if the next 2 s window
/// beats the best by 10%. When a probe fails it removes it and then tries one fewer, keeping the lower count while
/// it is within `PENALTY` of the best (each count scored as speed / 1.02^n, after Falcon and FastBioDL), so a link
/// where extra connections don't help settles low. While holding, it steps down when throughput falls 25%.
struct Grow {
    /// Throughput of the best count so far, bytes per second.
    best: f64,
    /// `(time, bytes done)` at the last three ticks; the first and last bound the current window.
    samples: VecDeque<(Instant, u64)>,
    stage: Stage,
}

#[derive(Clone, Copy)]
enum Stage {
    /// Holding the count; ticks since the last check.
    Hold(u8),
    /// Ignoring the warm-up after a change; ticks left.
    Warm(u8, Change),
    /// Measuring the window that judges a change; ticks left.
    Measure(u8, Change),
}

#[derive(Clone, Copy)]
enum Change {
    /// A connection was added: keep it only if the window beats `best` by 10%.
    Probe,
    /// A connection was removed: keep the lower count if the window is within `PENALTY` of `best`.
    Shrink,
    /// The window becomes `best`; then one fewer is tried when `shrink` is set, else a probe up when `probe` is.
    Rebase { probe: bool, shrink: bool },
}

/// What the caller must do to the connection count after a tick.
#[derive(Debug, PartialEq, Eq)]
enum Act {
    None,
    Add,
    Remove,
}

impl Grow {
    /// Starts by measuring the planned count, then probes up.
    fn new(now: Instant, done: u64) -> Grow {
        Grow {
            best: 0.0,
            samples: VecDeque::from([(now, done)]),
            stage: Stage::Warm(WARM_TICKS, Change::Rebase { probe: true, shrink: false }),
        }
    }

    /// Bytes per second over the last two ticks.
    fn window(&self) -> f64 {
        match (self.samples.front(), self.samples.back()) {
            (Some(&(t0, d0)), Some(&(t1, d1))) if t1 > t0 => d1.saturating_sub(d0) as f64 / (t1 - t0).as_secs_f64(),
            _ => 0.0,
        }
    }

    /// Called every `TICK` with the bytes written so far. `growable` is false under a speed limit or after a 429.
    fn tick(&mut self, now: Instant, done: u64, growable: bool, target: usize, cap: usize) -> Act {
        self.samples.push_back((now, done));
        if self.samples.len() > 3 {
            self.samples.pop_front();
        }
        match self.stage {
            Stage::Hold(n) if n + 1 < HOLD_TICKS => {
                self.stage = Stage::Hold(n + 1);
                Act::None
            }
            Stage::Hold(_) => {
                self.stage = Stage::Hold(0);
                if target > 1 && self.window() < self.best * 0.75 {
                    self.stage = Stage::Warm(WARM_TICKS, Change::Rebase { probe: false, shrink: false });
                    Act::Remove
                } else if growable && target < cap {
                    self.stage = Stage::Warm(WARM_TICKS, Change::Probe);
                    Act::Add
                } else {
                    Act::None
                }
            }
            Stage::Warm(n, change) => {
                self.stage = if n > 1 { Stage::Warm(n - 1, change) } else { Stage::Measure(WINDOW_TICKS, change) };
                Act::None
            }
            Stage::Measure(n, change) if n > 1 => {
                self.stage = Stage::Measure(n - 1, change);
                Act::None
            }
            Stage::Measure(_, change) => self.judge(change, growable, target, cap),
        }
    }

    fn judge(&mut self, change: Change, growable: bool, target: usize, cap: usize) -> Act {
        let window = self.window();
        match change {
            // The probe didn't pay: remove it, re-measure, then see whether even fewer is as good.
            Change::Probe if window < self.best * 1.1 => {
                self.stage = Stage::Warm(WARM_TICKS, Change::Rebase { probe: false, shrink: true });
                Act::Remove
            }
            Change::Probe => self.advance(window, true, false, growable, target, cap),
            // Fewer is as good: keep it, and try one fewer again.
            Change::Shrink if window * PENALTY >= self.best => self.advance(window, false, true, growable, target, cap),
            // Fewer is worse: put the connection back and hold (a periodic probe re-checks later).
            Change::Shrink => {
                self.stage = Stage::Warm(WARM_TICKS, Change::Rebase { probe: false, shrink: false });
                Act::Add
            }
            Change::Rebase { probe, shrink } => self.advance(window, probe, shrink, growable, target, cap),
        }
    }

    fn advance(&mut self, window: f64, probe: bool, shrink: bool, growable: bool, target: usize, cap: usize) -> Act {
        self.best = window;
        if shrink && target > 1 {
            self.stage = Stage::Warm(WARM_TICKS, Change::Shrink);
            Act::Remove
        } else if probe && growable && target < cap {
            self.stage = Stage::Warm(WARM_TICKS, Change::Probe);
            Act::Add
        } else {
            self.stage = Stage::Hold(0);
            Act::None
        }
    }
}

/// The lowercase host name, the key for remembered limits (no port).
fn host_of(url: &str) -> Option<String> {
    reqwest::Url::parse(url).ok()?.host_str().map(str::to_ascii_lowercase)
}

/// Shared by the coordinator and the segment tasks of one split run.
struct Shared {
    env: Env,
    id: JobId,
    url: String,
    part: PathBuf,
    validator: Option<String>,
    /// Per segment, indexed like the job's segments: the attempt it is waiting to retry, 0 when it is not waiting.
    waits: Mutex<Vec<u8>>,
    /// Set after an HTTP 429 or 503; no further splits for the rest of this run.
    throttled: AtomicBool,
    /// Segments that got 429/503 while others were transferring, oldest first. Resumed as connections free up.
    parked: Mutex<VecDeque<usize>>,
    /// Most segment tasks allowed at once while throttled: the transferring count at the first park, then lower.
    cap: AtomicUsize,
    /// Segment tasks wanted at once; the connection controller moves it.
    target: AtomicUsize,
    /// Stop signal of each running segment task, in start order. The newest is stopped to remove a connection.
    running: Mutex<Vec<(usize, watch::Sender<bool>)>>,
    host: Option<String>,
    /// True when this split came right after a successful probe, so the server has answered us once.
    probed: bool,
    /// The probe's still-open response, streamed as segment 0 so the first request isn't thrown away.
    first: Mutex<Option<reqwest::Response>>,
    /// When each recent connection failure happened, and on which segment.
    conn_fails: Mutex<Vec<(Instant, usize)>>,
    blocked_noted: AtomicBool,
}

/// How a segment task ended without error.
#[derive(Debug, PartialEq, Eq)]
enum SegEnd {
    Complete,
    Parked,
}

/// Each task reports its segment index with its result, so the coordinator knows which one to unlist.
type SegSet = JoinSet<(usize, Result<SegEnd, Stop>)>;

impl Shared {
    fn wait_slots(&self) -> MutexGuard<'_, Vec<u8>> {
        self.waits.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn parked_queue(&self) -> MutexGuard<'_, VecDeque<usize>> {
        self.parked.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn running_list(&self) -> MutexGuard<'_, Vec<(usize, watch::Sender<bool>)>> {
        self.running.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Returns true when another connection is transferring, so the caller parks instead of retrying, and
    /// lowers the cap to those. False for the last connection, which then retries like any other failure.
    fn park(&self) -> bool {
        let others = self.env.live.connections.load(Ordering::Relaxed);
        if others == 0 {
            return false;
        }
        self.cap.fetch_min(others as usize, Ordering::Relaxed);
        true
    }

    fn forget(&self, idx: usize) {
        self.running_list().retain(|(i, _)| *i != idx);
    }

    /// Stops the newest running segment. It stops at its write position, and its segment resumes later.
    fn stop_newest(&self) {
        let newest = self.running_list().pop();
        if let Some((_, stop)) = newest {
            let _ = stop.send(true);
        }
    }

    /// Best effort: if the write fails, the next download just starts with more connections.
    fn note_host(&self, max_parts: u32, reason: &str) {
        if let (Some(store), Some(host)) = (&self.env.store, &self.host) {
            let _ = store.note_host(host, max_parts, reason);
        }
    }

    fn conn_failed(&self, idx: usize) {
        self.env.dirty.store(true, Ordering::Relaxed);
        let now = Instant::now();
        let mut fails = self.conn_fails.lock().unwrap_or_else(PoisonError::into_inner);
        fails.retain(|(t, _)| now.duration_since(*t) < CONN_FAIL_WINDOW);
        fails.push((now, idx));
        let mut segs: Vec<usize> = fails.iter().map(|&(_, i)| i).collect();
        segs.sort_unstable();
        segs.dedup();
        drop(fails);
        if self.probed && segs.len() >= 2 && !self.blocked_noted.swap(true, Ordering::Relaxed) {
            self.note_host(1, "blocked extra connections");
        }
    }

    fn set_wait(&self, idx: usize, attempt: u8) {
        self.wait_slots()[idx] = attempt;
        self.refresh_state();
    }

    /// Shows the highest pending retry as Retrying, or Running when none is pending.
    fn refresh_state(&self) {
        let attempt = self.wait_slots().iter().copied().max().unwrap_or(0);
        let changed = with_job(&self.env.live, |j| {
            if !matches!(j.state, JobState::Running | JobState::Retrying { .. }) {
                return false;
            }
            let want = if attempt > 0 { JobState::Retrying { attempt } } else { JobState::Running };
            if j.state == want {
                return false;
            }
            j.state = want;
            true
        });
        if changed {
            self.env.hub.state_changed(self.id);
        }
    }

    /// Records `n` written bytes and returns how many count. A split may have moved `end` back during the write,
    /// so bytes past it are not counted; the next segment writes them again.
    fn record(&self, idx: usize, n: u64) -> u64 {
        let got = with_job(&self.env.live, |j| match j.segments.get_mut(idx) {
            Some(seg) => {
                let got = n.min(seg.end.saturating_sub(seg.start + seg.done));
                seg.done += got;
                got
            }
            None => 0,
        });
        self.env.live.done.fetch_add(got, Ordering::Relaxed);
        self.env.hub.progress(self.id);
        got
    }
}

/// Fetches every unfinished segment on its own connection, then finishes the file.
async fn run_split(
    env: &Env,
    cancel: &mut watch::Receiver<bool>,
    probed: bool,
    first: Option<reqwest::Response>,
) -> Result<Outcome, Stop> {
    let (id, url, part, validator, segments) = with_job(&env.live, |j| {
        (
            j.id,
            j.url.clone(),
            j.part_path.clone(),
            j.etag.clone().or_else(|| j.last_modified.clone()),
            j.segments.clone(),
        )
    });
    let done: u64 = segments.iter().map(|s| s.done).sum();
    env.live.done.store(done, Ordering::Relaxed);
    let unfinished = segments.iter().filter(|s| s.start + s.done < s.end).count();
    let shared = Arc::new(Shared {
        env: env.clone(),
        id,
        host: host_of(&url),
        url,
        part,
        validator,
        waits: Mutex::new(vec![0; segments.len()]),
        throttled: AtomicBool::new(false),
        parked: Mutex::new(VecDeque::new()),
        cap: AtomicUsize::new(usize::MAX),
        target: AtomicUsize::new(unfinished),
        running: Mutex::new(Vec::new()),
        probed,
        first: Mutex::new(first),
        conn_fails: Mutex::new(Vec::new()),
        blocked_noted: AtomicBool::new(false),
    });

    let mut set: SegSet = JoinSet::new();
    for (idx, seg) in segments.iter().enumerate() {
        if seg.start + seg.done < seg.end {
            spawn_segment(&mut set, &shared, idx);
        }
    }
    steal(&mut set, &shared);
    let mut grow = Grow::new(Instant::now(), done);
    let mut tick = tokio::time::interval_at(tokio::time::Instant::now() + TICK, TICK);
    loop {
        tokio::select! {
            biased;
            _ = cancelled(cancel) => {
                stop_all(&mut set, &shared).await;
                return Ok(Outcome::Paused);
            }
            _ = tick.tick() => {
                let growable = !env.limiter.is_limited() && !shared.throttled.load(Ordering::Relaxed);
                let target = shared.target.load(Ordering::Relaxed);
                let written = env.live.done.load(Ordering::Relaxed);
                match grow.tick(Instant::now(), written, growable, target, env.connections as usize) {
                    Act::None => {}
                    Act::Add => {
                        shared.target.fetch_add(1, Ordering::Relaxed);
                        let before = set.len();
                        // A segment parked by an earlier step down resumes before a new one is split off.
                        if !hand_off(&mut set, &shared) {
                            steal(&mut set, &shared);
                        }
                        // No segment left to split: undo the probe and hold.
                        if set.len() == before {
                            shared.target.fetch_sub(1, Ordering::Relaxed);
                            grow.stage = Stage::Hold(0);
                        }
                    }
                    Act::Remove => {
                        shared.target.fetch_sub(1, Ordering::Relaxed);
                        shared.stop_newest();
                    }
                }
            }
            next = set.join_next() => {
                let stop = match next {
                    None => {
                        if !hand_off(&mut set, &shared) {
                            break;
                        }
                        continue;
                    }
                    Some(Ok((idx, Ok(SegEnd::Complete)))) => {
                        shared.forget(idx);
                        hand_off(&mut set, &shared);
                        steal(&mut set, &shared);
                        continue;
                    }
                    // Queued like any parked segment; the cap or target just lowered keeps it from restarting here.
                    Some(Ok((idx, Ok(SegEnd::Parked)))) => {
                        shared.forget(idx);
                        shared.parked_queue().push_back(idx);
                        hand_off(&mut set, &shared);
                        continue;
                    }
                    Some(Ok((_, Err(stop)))) => stop,
                    Some(Err(join)) => Stop::Failed(format!("segment task: {join}")),
                };
                stop_all(&mut set, &shared).await;
                return match stop {
                    Stop::Paused => Ok(Outcome::Paused),
                    Stop::Failed(reason) | Stop::Retry(reason) => Ok(Outcome::Failed(reason)),
                    Stop::Fallback => fall_back(env, &shared).await,
                };
            }
        }
    }
    finish(env).await
}

/// Starts segment `idx` on a new task and lists its stop signal.
fn spawn_segment(set: &mut SegSet, shared: &Arc<Shared>, idx: usize) {
    let (stop, rx) = watch::channel(false);
    shared.running_list().push((idx, stop));
    let task = Arc::clone(shared);
    set.spawn(async move { (idx, segment_task(task, idx, rx).await) });
}

/// Stops every segment task. Aborting is enough: each task's `Transfer` guard still runs on drop.
async fn stop_all(set: &mut SegSet, shared: &Shared) {
    set.abort_all();
    while set.join_next().await.is_some() {}
    shared.wait_slots().fill(0);
    shared.refresh_state();
}

/// Starts the oldest parked segment on a free connection, while fewer tasks run than the cap and target allow.
fn hand_off(set: &mut SegSet, shared: &Arc<Shared>) -> bool {
    let limit = shared.cap.load(Ordering::Relaxed).min(shared.target.load(Ordering::Relaxed));
    if set.len() >= limit {
        return false;
    }
    let Some(idx) = shared.parked_queue().pop_front() else {
        return false;
    };
    spawn_segment(set, shared, idx);
    true
}

/// Starts a task on each free connection, each taking part of the unfinished segment with the most bytes left.
fn steal(set: &mut SegSet, shared: &Arc<Shared>) {
    // Under a user speed cap more connections add requests, not bandwidth; after a 429 they get us blocked.
    if shared.env.limiter.is_limited() || shared.throttled.load(Ordering::Relaxed) {
        return;
    }
    while set.len() < shared.target.load(Ordering::Relaxed) {
        let Some(idx) = split_one(shared) else { break };
        shared.wait_slots().push(0);
        shared.env.hub.state_changed(shared.id);
        spawn_segment(set, shared, idx);
    }
}

/// Splits the job's largest unfinished segment and saves the new plan before the new range can be written.
/// If the app crashes before that save, the old plan still covers those bytes: they are downloaded again.
fn split_one(shared: &Shared) -> Option<usize> {
    with_job(&shared.env.live, |j| {
        let mut next = j.clone();
        let idx = split_largest(&mut next.segments)?;
        if let Some(store) = &shared.env.store {
            store.save(&next).ok()?;
        }
        *j = next;
        Some(idx)
    })
}

/// Moves the tail off the unfinished segment with the most bytes left, at a 64 KiB boundary near its middle.
/// Returns the new segment's index, or None when no segment has `2 * MIN_SEGMENT` left.
fn split_largest(segments: &mut Vec<Segment>) -> Option<usize> {
    let (idx, left) = segments
        .iter()
        .enumerate()
        .map(|(i, s)| (i, s.end.saturating_sub(s.start + s.done)))
        .max_by_key(|&(_, left)| left)?;
    if left < 2 * MIN_SEGMENT {
        return None;
    }
    let pos = segments[idx].start + segments[idx].done;
    // left / 2 >= MIN_SEGMENT, so rounding down to SPLIT_ALIGN still lands strictly between pos and the old end.
    let mid = (pos + left / 2) / SPLIT_ALIGN * SPLIT_ALIGN;
    let old_end = std::mem::replace(&mut segments[idx].end, mid);
    segments.push(Segment { start: mid, end: old_end, done: 0 });
    Some(segments.len() - 1)
}

/// The next byte a segment writes and the segment's current end. Splits only ever lower `end`.
fn seg_pos(shared: &Shared, idx: usize) -> Result<(u64, u64), Stop> {
    with_job(&shared.env.live, |j| j.segments.get(idx).map(|s| (s.start + s.done, s.end)))
        .ok_or_else(|| Stop::Failed(format!("no segment {idx}")))
}

/// Truncates the preallocated file, then forgets the plan. The other order would leave a file that
/// looks finished on the next start; a truncate failure keeps the plan and fails the job instead.
async fn fall_back(env: &Env, shared: &Shared) -> Result<Outcome, Stop> {
    if let Err(e) = tokio::fs::File::create(&shared.part).await {
        return Ok(Outcome::Failed(format!("io: {e}")));
    }
    with_job(&env.live, |j| {
        j.segments.clear();
        j.done = 0;
    });
    env.live.done.store(0, Ordering::Relaxed);
    Err(Stop::Fallback)
}

/// One segment, with the same retry policy as a single stream. Stops early when the range is fully written, or
/// when `cancel` fires: the bytes written so far stay on the segment, and it comes back as `Parked`.
async fn segment_task(shared: Arc<Shared>, idx: usize, mut cancel: watch::Receiver<bool>) -> Result<SegEnd, Stop> {
    let mut attempt: u8 = 0;
    loop {
        let mut received = 0;
        let err = match segment_attempt(&shared, idx, &mut cancel, &mut received).await {
            Ok(end) => return Ok(end),
            Err(Stop::Paused) => return Ok(SegEnd::Parked),
            Err(Stop::Retry(err)) => err,
            Err(other) => return Err(other),
        };
        attempt = if received > 0 { 1 } else { attempt + 1 };
        if usize::from(attempt) > RETRY_WAITS.len() {
            return Err(Stop::Failed(err));
        }
        shared.set_wait(idx, attempt);
        let waited = or_cancel(&mut cancel, tokio::time::sleep(shared.env.next_wait(attempt))).await;
        shared.set_wait(idx, 0);
        if waited.is_err() {
            return Ok(SegEnd::Parked);
        }
    }
}

async fn segment_attempt(
    shared: &Shared,
    idx: usize,
    cancel: &mut watch::Receiver<bool>,
    received: &mut u64,
) -> Result<SegEnd, Stop> {
    let (from, end) = seg_pos(shared, idx)?;
    if from >= end {
        return Ok(SegEnd::Complete);
    }
    // Segment 0 of a fresh split keeps reading the probe's response (a 200 or 206 from byte 0); the loop below
    // stops it at the segment end, which a split may lower while it streams.
    let first = if idx == 0 && from == 0 { shared.first.lock().unwrap_or_else(PoisonError::into_inner).take() } else { None };
    let mut resp = match first {
        Some(resp) => resp,
        None => {
            let mut req = shared.env.client.get(shared.env.request_url(&shared.url)).header(RANGE, format!("bytes={from}-{}", end - 1));
            if let Some(v) = &shared.validator {
                req = req.header(IF_RANGE, v.as_str());
            }
            let resp = match or_cancel(cancel, tokio::time::timeout(STALL, req.send())).await? {
                Ok(Ok(resp)) => resp,
                Ok(Err(e)) => {
                    shared.conn_failed(idx);
                    return Err(Stop::Retry(format!("request: {e}")));
                }
                Err(_) => {
                    shared.conn_failed(idx);
                    return Err(Stop::Retry("timeout waiting for response".to_string()));
                }
            };
            match resp.status().as_u16() {
                206 => {}
                // A whole-file answer: the file changed, or the server stopped honouring ranges.
                200 | 416 => return Err(Stop::Fallback),
                status if retryable(status) => {
                    if matches!(status, 429 | 503) {
                        // The server is counting our connections: stop opening new ones for this run, and
                        // remember the lower count (our other transfers are still open, so `active` counts them).
                        shared.throttled.store(true, Ordering::Relaxed);
                        shared.env.dirty.store(true, Ordering::Relaxed);
                        let active = shared.env.live.connections.load(Ordering::Relaxed);
                        if active >= 2 {
                            shared.note_host(active - 1, "rate limited");
                        }
                        if shared.park() {
                            return Ok(SegEnd::Parked);
                        }
                    }
                    shared.env.note_retry_after(&resp);
                    return Err(Stop::Retry(format!("HTTP {status}")));
                }
                status => return Err(Stop::Failed(format!("HTTP {status}"))),
            }
            resp
        }
    };

    let mut file = tokio::fs::OpenOptions::new().write(true).open(&shared.part).await?;
    file.seek(SeekFrom::Start(from)).await?;
    let _transfer = Transfer::start(&shared.env.live);
    let mut pos = from;
    loop {
        if pos >= seg_pos(shared, idx)?.1 {
            break;
        }
        let chunk = or_cancel(cancel, tokio::time::timeout(STALL, resp.chunk()))
            .await?
            .map_err(|_| Stop::Retry("timeout: no data for 30 s".to_string()))?
            .map_err(|e| Stop::Retry(format!("body: {e}")))?;
        let Some(bytes) = chunk else { break };
        // Read `end` after the wait: a split may have lowered it while the chunk was in transit.
        let end = seg_pos(shared, idx)?.1;
        if pos >= end {
            break;
        }
        // The server may send past the segment end; those bytes belong to the next segment.
        let take = bytes.len().min((end - pos) as usize);
        or_cancel(cancel, shared.env.limiter.acquire(take)).await?;
        file.write_all(&bytes[..take]).await?;
        file.flush().await?;
        let counted = shared.record(idx, take as u64);
        pos += counted;
        *received += counted;
    }
    if pos < seg_pos(shared, idx)?.1 {
        return Err(Stop::Retry(format!("segment {idx} ended early")));
    }
    Ok(SegEnd::Complete)
}

/// Checks the length, fsyncs and renames `.part` to its final name.
async fn finish(env: &Env) -> Result<Outcome, Stop> {
    let (part, name, total) = with_job(&env.live, |j| (j.part_path.clone(), j.name.clone(), j.total));
    let len = tokio::fs::metadata(&part).await?.len();
    if total.is_some_and(|t| t != len) {
        return Err(Stop::Retry(format!("size mismatch: {len} bytes, expected {total:?}")));
    }
    tokio::fs::OpenOptions::new().write(true).open(&part).await?.sync_all().await?;
    // hard_link refuses to overwrite, so two jobs finishing together cannot clobber each other's file.
    let final_path = loop {
        let candidate = names::unique_final(&env.dir, &name);
        match tokio::fs::hard_link(&part, &candidate).await {
            Ok(()) => break candidate,
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
            // shortcut: exFAT/FAT have no hard links; plain rename there can race with another finishing job.
            Err(_) => {
                tokio::fs::rename(&part, &candidate).await?;
                break candidate;
            }
        }
    };
    // The link already holds the data, so a failed unlink must not turn into a retry that links again.
    let _ = tokio::fs::remove_file(&part).await;
    with_job(&env.live, |j| {
        j.done = len;
        j.final_path = Some(final_path.clone());
    });
    Ok(Outcome::Done(final_path))
}

/// Resolves when `rx` turns true or its sender is dropped.
async fn cancelled(rx: &mut watch::Receiver<bool>) {
    loop {
        let stop = *rx.borrow_and_update();
        if stop || rx.changed().await.is_err() {
            return;
        }
    }
}

fn with_job<R>(live: &Live, f: impl FnOnce(&mut Job) -> R) -> R {
    // A poisoned lock still holds a usable Job; keep the download going instead of panicking.
    let mut job = live.job.lock().unwrap_or_else(PoisonError::into_inner);
    f(&mut job)
}

fn header(resp: &reqwest::Response, name: HeaderName) -> Option<String> {
    resp.headers().get(name)?.to_str().ok().map(str::to_owned)
}

/// The full file length from `Content-Range: bytes a-b/total`.
fn content_range_total(resp: &reqwest::Response) -> Option<u64> {
    header(resp, CONTENT_RANGE)?.rsplit('/').next()?.parse().ok()
}

/// Timeouts, "too early", rate limiting, and server errors are worth retrying; other statuses are not.
fn retryable(status: u16) -> bool {
    matches!(status, 408 | 425 | 429 | 500..=599)
}

impl Env {
    fn request_url(&self, url: &str) -> String {
        self.sign.as_ref().map_or_else(|| url.to_owned(), |sign| sign())
    }

    /// Lifts a remembered limit by one after a clean finish; a no-op for hosts without a row.
    fn relax_host(&self) {
        if let (Some(store), Some(host)) = (&self.store, with_job(&self.live, |j| host_of(&j.url))) {
            let _ = store.relax_host(&host);
        }
    }

    /// Remembers `Retry-After` (delta-seconds only, capped at 2 minutes) for the next retry sleep.
    fn note_retry_after(&self, resp: &reqwest::Response) {
        if let Some(secs) = header(resp, reqwest::header::RETRY_AFTER).and_then(|v| v.trim().parse::<u64>().ok()) {
            self.retry_hint.fetch_max(secs.min(120) * 1000, Ordering::Relaxed);
        }
    }

    fn next_wait(&self, attempt: u8) -> Duration {
        retry_wait(attempt).max(Duration::from_millis(self.retry_hint.swap(0, Ordering::Relaxed)))
    }
}

fn retry_wait(attempt: u8) -> Duration {
    static SCALE_MS: OnceLock<Option<u64>> = OnceLock::new();
    let secs = RETRY_WAITS[usize::from(attempt - 1)];
    // Test hook: DL_RETRY_SCALE_MS makes each wait that many milliseconds instead of seconds.
    match SCALE_MS.get_or_init(|| std::env::var("DL_RETRY_SCALE_MS").ok().and_then(|v| v.parse().ok())) {
        Some(ms) => Duration::from_millis(secs * ms),
        None => Duration::from_secs(secs),
    }
}

#[cfg(test)]
mod tests {
    /// Drives `Grow` on a synthetic link: `speed(n)` bytes/s with `n` connections. Returns the count after `ticks`.
    fn settle(start: usize, cap: usize, ticks: u32, speed: impl Fn(usize) -> f64) -> usize {
        let t0 = Instant::now();
        let mut grow = Grow::new(t0, 0);
        let (mut n, mut done) = (start, 0.0);
        for k in 1..=ticks {
            done += speed(n);
            match grow.tick(t0 + Duration::from_secs(u64::from(k)), done as u64, true, n, cap) {
                Act::Add => n += 1,
                Act::Remove => n -= 1,
                Act::None => {}
            }
        }
        n
    }

    #[test]
    fn grow_steps_down_when_more_connections_dont_help() {
        // One connection already fills the link: extra ones are dropped.
        assert_eq!(settle(4, 8, 30, |_| 10e6), 1);
        // Extra connections make it slower: dropped too.
        assert_eq!(settle(4, 8, 30, |n| 10e6 / n as f64), 1);
    }

    #[test]
    fn grow_climbs_when_each_connection_adds_speed() {
        // Each connection adds 5 MB/s up to 8: the count reaches the cap and stays.
        assert_eq!(settle(4, 8, 60, |n| 5e6 * n.min(8) as f64), 8);
        // Gains stop at 6: it settles there, not at the cap.
        assert_eq!(settle(4, 8, 60, |n| 5e6 * n.min(6) as f64), 6);
    }

    #[test]
    fn plan_splits_into_aligned_parts() {
        let total = (100 << 20) + 12345;
        assert_eq!(plan(total, 1), vec![Segment { start: 0, end: total, done: 0 }]);
        let p = plan(total, 4);
        assert_eq!((p.len(), p[0].start, p[3].end), (4, 0, total));
        assert!(p.windows(2).all(|w| w[0].end == w[1].start && w[0].end % SPLIT_ALIGN == 0));
    }

    use super::*;

    fn seg(start: u64, end: u64, done: u64) -> Segment {
        Segment { start, end, done }
    }

    #[test]
    fn split_takes_the_segment_with_most_bytes_left() {
        let mut segs = vec![seg(0, 4 << 20, 0), seg(4 << 20, 20 << 20, 1 << 20)];
        assert_eq!(split_largest(&mut segs), Some(2));
        // pos 5 MiB, left 15 MiB, mid 12.5 MiB (a 64 KiB multiple).
        let mid = 12_800 << 10;
        assert_eq!(segs[1], seg(4 << 20, mid, 1 << 20));
        assert_eq!(segs[2], seg(mid, 20 << 20, 0));
    }

    #[test]
    fn split_refuses_when_less_than_two_segments_of_bytes_left() {
        let mut segs = vec![seg(0, (2 << 20) - 1, 0)];
        assert_eq!(split_largest(&mut segs), None);
        let mut segs = vec![seg(0, 3 << 20, 1536 << 10)];
        assert_eq!(split_largest(&mut segs), None);
        assert_eq!(segs, vec![seg(0, 3 << 20, 1536 << 10)]);
    }

    #[test]
    fn split_point_is_aligned_and_past_the_written_bytes() {
        for (start, done, end) in [(0, 0, 2 << 20), (1000, 777, 1000 + 9_000_123), (3 << 20, 500_000, 40 << 20)] {
            let mut segs = vec![seg(start, end, done)];
            assert_eq!(split_largest(&mut segs), Some(1));
            let mid = segs[0].end;
            assert_eq!(mid % SPLIT_ALIGN, 0, "mid {mid} not aligned");
            assert!(mid > start + done && mid < end, "mid {mid} outside ({}, {end})", start + done);
            assert_eq!(segs[1], seg(mid, end, 0));
        }
    }
}
