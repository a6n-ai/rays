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
use std::collections::{BTreeMap, HashMap, VecDeque};
use std::future::Future;
use std::io::{self, SeekFrom};
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
const MIRROR_PROBE: Duration = Duration::from_secs(10);
/// Smaller files are never split; no segment is smaller than `MIN_SEGMENT`.
const MIN_SPLIT: u64 = 4 << 20;
const MIN_SEGMENT: u64 = 1 << 20;
/// Split points are rounded down to this, so ranges start on round offsets.
const SPLIT_ALIGN: u64 = 64 << 10;
/// Bytes a segment task gathers before one write and flush (each is a blocking-pool round trip). It must stay
/// below `MIN_SEGMENT`: a split cuts at least that far past the recorded bytes, so it never lands in the buffer.
const WRITE_BATCH: usize = 256 << 10;
/// A segment connection that wrote at least this much before failing reconnects without waiting.
const RECONNECT_AFTER: u64 = 64 << 10;
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

/// Engine settings one run reads. `Default` has every setting off.
#[derive(Clone)]
pub struct RunOpts {
    /// A finished file replaces one already holding its name (that one goes to the Trash) instead of getting a new name.
    pub replace_existing: bool,
    /// Moves a file to the Trash. Injected so tests never touch the real Trash.
    pub trash: fn(&Path) -> io::Result<()>,
    pub hf: HfAccess,
}

impl Default for RunOpts {
    fn default() -> Self {
        RunOpts { replace_existing: false, trash: trash_file, hf: HfAccess::default() }
    }
}

/// The Hugging Face site and the saved token. `host` is `host:port`; the default (empty) matches no URL.
#[derive(Clone, Default)]
pub struct HfAccess {
    pub host: String,
    pub token: Option<String>,
}

impl HfAccess {
    fn covers(&self, url: &str) -> bool {
        !self.host.is_empty() && host_port(url).as_deref() == Some(self.host.as_str())
    }
}

/// `host:port` of an http(s) URL, the form `HfAccess::host` holds.
pub fn host_port(url: &str) -> Option<String> {
    let u = reqwest::Url::parse(url).ok()?;
    Some(format!("{}:{}", u.host_str()?, u.port_or_known_default()?))
}

/// The failure text for a status. `answered` is the URL that answered, after redirects, so a CDN's 401 keeps its status;
/// `job_url` is the URL the job asked for, which names the model.
/// `error_code` is Hugging Face's `X-Error-Code` header: it separates a gated repo from one that does not exist, both of which answer 401 without a token.
/// Prefix of the failure text when a link that was already transferring starts refusing; `JobView::link_expired` keys on it.
pub const LINK_EXPIRED: &str = "Link expired";

/// `started` is true when bytes of the file are already on disk: a 403, 404 or 410 then means the link expired.
fn http_failure(hf: &HfAccess, job_url: &str, answered: &str, status: u16, error_code: Option<&str>, started: bool) -> String {
    let sent_token = hf.token.is_some() && hf.covers(job_url);
    match status {
        401 if hf.covers(answered) && sent_token => "Hugging Face rejected the saved token. Check it in Settings".into(),
        401 if hf.covers(answered) && error_code == Some("GatedRepo") => "This model is gated: add your Hugging Face token in Settings".into(),
        401 | 404 if hf.covers(answered) && hf.token.is_none() => {
            "Couldn't find this model on Hugging Face. If it's private or gated, add your Hugging Face token in Settings.".into()
        }
        403 if hf.covers(answered) => match model_page(job_url) {
            Some(page) => format!("Accept this model's license at {page}"),
            None => "Accept this model's license on huggingface.co".into(),
        },
        403 | 404 | 410 if started => format!("{LINK_EXPIRED} (HTTP {status})"),
        _ => format!("HTTP {status}"),
    }
}

fn error_code(resp: &reqwest::Response) -> Option<&str> {
    resp.headers().get("x-error-code").and_then(|v| v.to_str().ok())
}

/// `<origin>/<org>/<repo>` for a `.../<org>/<repo>/resolve/...` URL.
fn model_page(job_url: &str) -> Option<String> {
    let u = reqwest::Url::parse(job_url).ok()?;
    let (model, _) = u.path().split_once("/resolve/")?;
    let mut segs = model.trim_start_matches('/').split('/');
    let (org, repo) = (segs.next()?, segs.next()?);
    (!org.is_empty() && !repo.is_empty() && segs.next().is_none()).then(|| format!("{}/{org}/{repo}", u.origin().ascii_serialization()))
}

/// On macOS the default backend drives Finder through AppleScript, which raises an Automation prompt; NSFileManager does not.
pub(crate) fn trash_file(path: &Path) -> io::Result<()> {
    #[cfg(target_os = "macos")]
    {
        use trash::macos::{DeleteMethod, TrashContextExtMacos};
        let mut ctx = trash::TrashContext::new();
        ctx.set_delete_method(DeleteMethod::NsFileManager);
        ctx.delete(path).map_err(io::Error::other)
    }
    #[cfg(not(target_os = "macos"))]
    {
        trash::delete(path).map_err(io::Error::other)
    }
}

/// Every final path this process has produced, with when it was produced. A replacing finish trashes one of
/// these only if its job started after that, so a job still racing the producer keeps both files.
static PRODUCED: Mutex<BTreeMap<PathBuf, u64>> = Mutex::new(BTreeMap::new());
/// Orders job creations and productions: a larger number is later.
static SEQ: AtomicU64 = AtomicU64::new(0);

/// The next number in the order that `Live::started` and `PRODUCED` share.
pub fn next_seq() -> u64 {
    SEQ.fetch_add(1, Ordering::Relaxed)
}
const PRODUCED_CAP: usize = 1000;

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
    opts: RunOpts,
) -> Outcome {
    let dir = with_job(&live, |j| j.dir.clone()).unwrap_or_else(|| downloads_dir.to_path_buf());
    if let Err(e) = tokio::fs::create_dir_all(&dir).await {
        return Outcome::Failed(format!("create {}: {e}", dir.display()));
    }
    let env = Env {
        started: live.started,
        live,
        client,
        dir,
        hub,
        connections,
        start,
        limiter,
        store,
        sign,
        replace_existing: opts.replace_existing,
        trash: opts.trash,
        hf: opts.hf,
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
            if matches!(j.state, JobState::Running | JobState::Retrying { .. }) {
                j.state = JobState::Retrying { attempt };
            }
            j.id
        });
        env.hub.state_changed(id);
        tokio::select! {
            biased;
            _ = cancelled(&mut cancel) => return Outcome::Paused,
            _ = tokio::time::sleep(env.next_wait(attempt)) => {}
        }
        with_job(&env.live, |j| {
            if matches!(j.state, JobState::Retrying { .. }) {
                j.state = JobState::Running;
            }
        });
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
    /// Set from the engine's replace setting when the job starts; see `RunOpts`.
    replace_existing: bool,
    trash: fn(&Path) -> io::Result<()>,
    hf: HfAccess,
    /// Server-requested wait (Retry-After), in ms, consumed by the next retry sleep.
    retry_hint: Arc<AtomicU64>,
    /// Set by a retry, a 503 or a connection failure; a run that set it keeps the remembered limit.
    dirty: Arc<AtomicBool>,
    /// The job's creation number (`Live::started`), checked against `PRODUCED` before a replace.
    started: u64,
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

    let mut req = env.get(&url);
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
        _ => return Err(Stop::Failed(http_failure(&env.hf, &url, resp.url().as_str(), status, error_code(&resp), have > 0))),
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
        if let Some(name) = disposition.filter(|_| !j.fixed_name) {
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
        let start = if total >= BIG_FILE { env.start.max(BIG_START) } else { env.start };
        let segments = plan(total, u64::from(start.min(cap)));
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

/// Sets the connection count of a split run. It probes up and keeps the added connections only if the next 2 s window
/// beats the best by 10%. While each step brings at least `DOUBLE_GAIN`, a probe doubles the count (1, 2, 4, 8),
/// so a server that caps each connection is filled in a few steps; after that, probes add one. When a probe fails it removes it and then tries one fewer, keeping the lower count while
/// it is within `PENALTY` of the best (each count scored as speed / 1.02^n, after Falcon and FastBioDL), so a link
/// where extra connections don't help settles low. While holding, it steps down when throughput falls 25%.
struct Grow {
    /// Throughput of the best count so far, bytes per second.
    best: f64,
    /// `(time, bytes done)` at the last three ticks; the first and last bound the current window.
    samples: VecDeque<(Instant, u64)>,
    stage: Stage,
    /// Still doubling: no probe has yet gained less than `DOUBLE_GAIN`.
    doubling: bool,
    /// Connections the pending probe added, removed together if it fails.
    added: usize,
    /// Ticks in the window being measured.
    span: u8,
}

/// A probe that gains at least this much keeps the count doubling.
const DOUBLE_GAIN: f64 = 1.25;
/// Added connections that each bring at least this share of an existing one's speed scaled linearly: no overshoot.
const LINEAR_SHARE: f64 = 0.9;
/// A doubling probe is judged on one tick: a jump of 25% or more shows in one second.
const DOUBLE_WINDOW_TICKS: u8 = 1;
/// Fresh files at least this big start on `BIG_START` parts, as other download managers start on 8 to 16; the
/// trim after doubling, and the step down, still settle on one where more don't help.
const BIG_FILE: u64 = 32 << 20;
const BIG_START: u32 = 4;
/// While throttled, the cap is raised by one after this long without a 429/503, in case the first refusal came
/// before every accepted connection was counted.
const THROTTLE_RETRY: Duration = Duration::from_secs(3);
/// A connection is reconnected when it runs below 1/`SHED_RATIO` of its fair share (after MDM's shed rule): the
/// lower of the best single connection seen and the best total divided by the connections running, so
/// connections that share one link are never shed for sharing it.
const SHED_RATIO: f64 = 4.0;
/// A new connection gets this long before it can be judged slow, and must have this much work left.
const SHED_GRACE: Duration = Duration::from_secs(2);

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
    Add(usize),
    Remove(usize),
}

impl Grow {
    /// Starts by measuring the planned count, then probes up.
    fn new(now: Instant, done: u64) -> Grow {
        Grow {
            best: 0.0,
            samples: VecDeque::from([(now, done)]),
            stage: Stage::Warm(WARM_TICKS, Change::Rebase { probe: true, shrink: false }),
            doubling: true,
            added: 0,
            span: WINDOW_TICKS,
        }
    }

    /// Starts a probe: as many again as `target` while doubling, else one, never past `cap`.
    fn probe(&mut self, target: usize, cap: usize) -> Act {
        self.added = if self.doubling { target.max(1) } else { 1 }.min(cap - target);
        self.stage = Stage::Warm(WARM_TICKS, Change::Probe);
        Act::Add(self.added)
    }

    /// Bytes per second over the last `span` ticks.
    fn window(&self) -> f64 {
        let first = self.samples.len().saturating_sub(usize::from(self.span) + 1);
        match (self.samples.get(first), self.samples.back()) {
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
                self.span = WINDOW_TICKS;
                if target > 1 && self.window() < self.best * 0.75 {
                    self.stage = Stage::Warm(WARM_TICKS, Change::Rebase { probe: false, shrink: false });
                    Act::Remove(1)
                } else if growable && target < cap {
                    self.probe(target, cap)
                } else {
                    Act::None
                }
            }
            Stage::Warm(n, change) if n > 1 => {
                self.stage = Stage::Warm(n - 1, change);
                Act::None
            }
            Stage::Warm(_, change) => {
                // While doubling, both the first count and each doubling step are judged on one tick: the start
                // only sets the baseline the first doubling must beat by 25%, so a short window costs nothing there.
                let doubling_probe =
                    matches!(change, Change::Probe | Change::Rebase { probe: true, .. }) && self.doubling;
                self.span = if doubling_probe { DOUBLE_WINDOW_TICKS } else { WINDOW_TICKS };
                self.stage = Stage::Measure(self.span, change);
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
            // The probe didn't pay: remove what it added, re-measure, then see whether even fewer is as good.
            Change::Probe if window < self.best * 1.1 => {
                self.doubling = false;
                self.stage = Stage::Warm(WARM_TICKS, Change::Rebase { probe: false, shrink: true });
                Act::Remove(self.added)
            }
            Change::Probe => {
                let doubled = self.added > 1;
                self.doubling &= window >= self.best * DOUBLE_GAIN && target < cap;
                // A doubling step that ends the doubling may have overshot: trim down while speed holds. Not when
                // every added connection pulled about as much as the ones before it (it stopped only at the cap):
                // the trim would just cost a slower window to learn that.
                let before = target.saturating_sub(self.added).max(1) as f64;
                let linear = window >= self.best * (1.0 + LINEAR_SHARE * self.added as f64 / before);
                let trim = doubled && !self.doubling && !linear;
                self.advance(window, !trim, trim, growable, target, cap)
            }
            // Fewer is as good: keep it, and try one fewer again.
            Change::Shrink if window * PENALTY >= self.best => self.advance(window, false, true, growable, target, cap),
            // Fewer is worse: put the connection back and hold (a periodic probe re-checks later).
            Change::Shrink => {
                self.stage = Stage::Warm(WARM_TICKS, Change::Rebase { probe: false, shrink: false });
                Act::Add(1)
            }
            Change::Rebase { probe, shrink } => self.advance(window, probe, shrink, growable, target, cap),
        }
    }

    fn advance(&mut self, window: f64, probe: bool, shrink: bool, growable: bool, target: usize, cap: usize) -> Act {
        self.best = window;
        if shrink && target > 1 {
            self.stage = Stage::Warm(WARM_TICKS, Change::Shrink);
            Act::Remove(1)
        } else if probe && growable && target < cap {
            self.probe(target, cap)
        } else {
            self.stage = Stage::Hold(0);
            Act::None
        }
    }
}

/// Finds a connection to reconnect because it is far slower than the others (one bad path or a slow mirror). Each
/// running segment's speed is measured over its last two ticks.
#[derive(Default)]
struct Slow {
    /// Per running segment: when it was first seen, and `(time, bytes done)` at its last three ticks.
    seen: HashMap<usize, (Instant, VecDeque<(Instant, u64)>)>,
    best_single: f64,
    best_total: f64,
    total: VecDeque<(Instant, u64)>,
}

impl Slow {
    /// Returns at most one segment to reconnect.
    fn tick(&mut self, shared: &Shared, now: Instant) -> Option<usize> {
        let running: Vec<usize> = shared.running_list().iter().map(|(i, _)| *i).collect();
        self.seen.retain(|i, _| running.contains(i));
        let segs = with_job(&shared.env.live, |j| j.segments.clone());
        let rate = |q: &VecDeque<(Instant, u64)>| match (q.front(), q.back()) {
            (Some(&(t0, d0)), Some(&(t1, d1))) if t1 > t0 && q.len() == 3 => {
                Some(d1.saturating_sub(d0) as f64 / (t1 - t0).as_secs_f64())
            }
            _ => None,
        };
        let total: u64 = segs.iter().map(|s| s.done).sum();
        self.total.push_back((now, total));
        if self.total.len() > 3 {
            self.total.pop_front();
        }
        if let Some(r) = rate(&self.total) {
            self.best_total = self.best_total.max(r);
        }
        let mut speeds = Vec::new();
        for &idx in &running {
            let Some(seg) = segs.get(idx) else { continue };
            let (born, q) = self.seen.entry(idx).or_insert_with(|| (now, VecDeque::new()));
            q.push_back((now, seg.done));
            if q.len() > 3 {
                q.pop_front();
            }
            if let Some(r) = rate(q) {
                self.best_single = self.best_single.max(r);
                let left = seg.end.saturating_sub(seg.start + seg.done) as f64;
                speeds.push((idx, *born, r, left));
            }
        }
        let bar = self.best_single.min(self.best_total / running.len().max(1) as f64);
        let (idx, ..) = speeds.into_iter().filter(|&(_, born, r, left)| {
            now.duration_since(born) >= SHED_GRACE && r * SHED_RATIO < bar && left > r * SHED_GRACE.as_secs_f64()
        }).min_by(|a, b| a.2.total_cmp(&b.2))?;
        // Measured afresh once it reconnects.
        self.seen.remove(&idx);
        Some(idx)
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
    part: PathBuf,
    validator: Option<String>,
    /// Per segment, indexed like the job's segments: the attempt it is waiting to retry, 0 when it is not waiting.
    waits: Mutex<Vec<u8>>,
    /// Set after an HTTP 429 or 503: no more probing up for the rest of this run, and splits only within `cap`.
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
    /// The last 429/503, which restarts the wait before the cap is raised again.
    last_reject: Mutex<Option<Instant>>,
    /// The primary link first, then the mirrors that passed the probe.
    links: Mutex<Vec<Link>>,
}

/// One link of a job and what is known about it, for choosing where a new connection goes.
struct Link {
    url: String,
    /// An error on this link ended its use for this run; the last live link is never marked.
    dead: bool,
    picks: u32,
    /// Bytes per second of the latest connection on this link.
    speed: Option<f64>,
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
    fn links(&self) -> MutexGuard<'_, Vec<Link>> {
        self.links.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The live link for a new connection: round-robin while some are unmeasured, then the fastest.
    fn pick(&self) -> (usize, String) {
        let mut links = self.links();
        let live = || links.iter().enumerate().filter(|(_, l)| !l.dead);
        let i = live()
            .filter(|(_, l)| l.speed.is_none())
            .min_by_key(|(_, l)| l.picks)
            .or_else(|| live().max_by(|a, b| a.1.speed.partial_cmp(&b.1.speed).unwrap_or(std::cmp::Ordering::Equal)))
            .map_or(0, |(i, _)| i);
        links[i].picks += 1;
        (i, links[i].url.clone())
    }

    /// Marks link `i` dead. Returns false when it is the last live link, which stays in use and retries as usual.
    fn kill(&self, i: usize) -> bool {
        let mut links = self.links();
        if !links[i].dead {
            if links.iter().filter(|l| !l.dead).count() < 2 {
                return false;
            }
            links[i].dead = true;
        }
        true
    }

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
        // Parts started together can be refused before the accepted ones begin transferring: other tasks still
        // count, and `retry_cap` raises the cap to the transfers once they start.
        if others == 0 && self.running_list().len() <= 1 {
            return false;
        }
        self.cap.fetch_min((others as usize).max(1), Ordering::Relaxed);
        true
    }

    fn forget(&self, idx: usize) {
        self.running_list().retain(|(i, _)| *i != idx);
    }

    /// Stops segment `idx` at its write position; the coordinator restarts it on a new connection.
    fn stop_segment(&self, idx: usize) {
        let mut running = self.running_list();
        if let Some(pos) = running.iter().position(|(i, _)| *i == idx) {
            let (_, stop) = running.remove(pos);
            let _ = stop.send(true);
        }
    }

    /// Stops the newest running segment. It stops at its write position, and its segment resumes later.
    fn stop_newest(&self) {
        let newest = self.running_list().pop();
        if let Some((_, stop)) = newest {
            let _ = stop.send(true);
        }
    }

    /// While throttled with segments waiting, raises the cap by one after `THROTTLE_RETRY` without a refusal and
    /// starts a waiting segment. A refusal lowers it again (`park`). The first refusal can come before every
    /// accepted connection was counted, which would otherwise hold the run below what the server allows.
    fn retry_cap(self: &Arc<Self>, set: &mut SegSet) {
        if !self.throttled.load(Ordering::Relaxed) {
            return;
        }
        // Connections working now were accepted: the cap is at least that many, at no extra request.
        self.cap.fetch_max(self.env.live.connections.load(Ordering::Relaxed) as usize, Ordering::Relaxed);
        if self.parked_queue().is_empty() {
            return;
        }
        let quiet = self.last_reject.lock().unwrap_or_else(PoisonError::into_inner).is_none_or(|t| t.elapsed() >= THROTTLE_RETRY);
        let cap = self.cap.load(Ordering::Relaxed);
        if quiet && cap < self.target.load(Ordering::Relaxed) && set.len() >= cap {
            self.cap.store(cap + 1, Ordering::Relaxed);
            // Counts as a refusal for the wait, so the next raise waits another THROTTLE_RETRY.
            *self.last_reject.lock().unwrap_or_else(PoisonError::into_inner) = Some(Instant::now());
            hand_off(set, self);
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
    let mirrors = probe_mirrors(env, cancel).await?;
    let links = std::iter::once(url.clone()).chain(mirrors).map(|url| Link { url, dead: false, picks: 0, speed: None }).collect();
    let done: u64 = segments.iter().map(|s| s.done).sum();
    env.live.done.store(done, Ordering::Relaxed);
    let unfinished = segments.iter().filter(|s| s.start + s.done < s.end).count();
    let shared = Arc::new(Shared {
        env: env.clone(),
        id,
        host: host_of(&url),
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
        last_reject: Mutex::new(None),
        links: Mutex::new(links),
    });

    let mut set: SegSet = JoinSet::new();
    for (idx, seg) in segments.iter().enumerate() {
        if seg.start + seg.done < seg.end {
            spawn_segment(&mut set, &shared, idx);
        }
    }
    steal(&mut set, &shared);
    let mut grow = Grow::new(Instant::now(), done);
    let mut slow = Slow::default();
    let mut tick = tokio::time::interval_at(tokio::time::Instant::now() + TICK, TICK);
    loop {
        tokio::select! {
            biased;
            _ = cancelled(cancel) => {
                stop_all(&mut set, &shared).await;
                return Ok(Outcome::Paused);
            }
            _ = tick.tick() => {
                shared.retry_cap(&mut set);
                // Under a speed limit every connection is slow on purpose; after a 429 a reconnect is refused.
                if !env.limiter.is_limited()
                    && !shared.throttled.load(Ordering::Relaxed)
                    && let Some(idx) = slow.tick(&shared, Instant::now())
                {
                    shared.stop_segment(idx);
                }
                let growable = !env.limiter.is_limited() && !shared.throttled.load(Ordering::Relaxed);
                let target = shared.target.load(Ordering::Relaxed);
                let written = env.live.done.load(Ordering::Relaxed);
                match grow.tick(Instant::now(), written, growable, target, env.connections as usize) {
                    Act::None => {}
                    Act::Add(n) => {
                        shared.target.fetch_add(n, Ordering::Relaxed);
                        let before = set.len();
                        // Segments parked by an earlier step down resume before new ones are split off.
                        while set.len() < before + n && hand_off(&mut set, &shared) {}
                        steal(&mut set, &shared);
                        // Fewer segments left to split than asked: keep what started, or undo the probe and hold.
                        let started = set.len() - before;
                        shared.target.fetch_sub(n - started, Ordering::Relaxed);
                        grow.added = started;
                        if started == 0 {
                            grow.stage = Stage::Hold(0);
                        }
                    }
                    Act::Remove(n) => {
                        shared.target.fetch_sub(n, Ordering::Relaxed);
                        for _ in 0..n {
                            shared.stop_newest();
                        }
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

/// Asks every mirror at once for the first byte and keeps those that answer a range with the job's size. A mirror
/// that fails is skipped for this run only; the job keeps its list. shortcut: a mirror's ETag is not compared, only its size.
async fn probe_mirrors(env: &Env, cancel: &mut watch::Receiver<bool>) -> Result<Vec<String>, Stop> {
    let (mirrors, total) = with_job(&env.live, |j| (j.mirrors.clone(), j.total));
    let Some(total) = total.filter(|_| !mirrors.is_empty()) else { return Ok(Vec::new()) };
    // Mirrors are rejected on s3:// jobs at add time; one loaded from an older store would be signed as the primary.
    if with_job(&env.live, |j| j.url.starts_with("s3://")) {
        return Ok(Vec::new());
    }
    let mut set = tokio::task::JoinSet::new();
    for (i, url) in mirrors.iter().enumerate() {
        let req = env.get(url).header(RANGE, "bytes=0-0");
        set.spawn(async move {
            let ok = match tokio::time::timeout(MIRROR_PROBE, req.send()).await {
                Ok(Ok(resp)) => resp.status().as_u16() == 206 && content_range_total(&resp) == Some(total),
                _ => false,
            };
            (i, ok)
        });
    }
    let mut good = vec![false; mirrors.len()];
    while let Some(done) = or_cancel(cancel, set.join_next()).await? {
        if let Ok((i, true)) = done {
            good[i] = true;
        }
    }
    Ok(mirrors.into_iter().zip(good).filter_map(|(url, ok)| ok.then_some(url)).collect())
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
    // Under a user speed cap more connections add requests, not bandwidth. After a 429/503 a split still may run
    // up to the cap of connections the server accepted, so the last part does not finish on one connection.
    if shared.env.limiter.is_limited() {
        return;
    }
    let throttled = shared.throttled.load(Ordering::Relaxed);
    while set.len() < shared.target.load(Ordering::Relaxed)
        && (!throttled || set.len() < shared.cap.load(Ordering::Relaxed))
        && shared.parked_queue().is_empty()
    {
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
        let mut link = 0;
        // An error on a link with others still live drops that link and reconnects on another at once.
        let err = match segment_attempt(&shared, idx, &mut cancel, &mut received, &mut link).await {
            Ok(end) => return Ok(end),
            Err(Stop::Paused) => return Ok(SegEnd::Parked),
            Err(Stop::Retry(err)) => {
                if shared.kill(link) {
                    attempt = 0;
                    continue;
                }
                err
            }
            Err(Stop::Failed(reason)) => {
                if shared.kill(link) {
                    attempt = 0;
                    continue;
                }
                return Err(Stop::Failed(reason));
            }
            Err(Stop::Fallback) if link != 0 && shared.kill(link) => {
                attempt = 0;
                continue;
            }
            Err(other) => return Err(other),
        };
        // A real stretch of data arrived before the drop, so the server is up: reconnect at once, as aria2 does.
        // Waiting idled each connection most of the time on servers that drop often. A server that drops after
        // a few bytes still backs off, so it is not hammered.
        if received >= RECONNECT_AFTER {
            attempt = 0;
            continue;
        }
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
    link: &mut usize,
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
            let (i, url) = shared.pick();
            *link = i;
            let mut req = shared.env.get(&url).header(RANGE, format!("bytes={from}-{}", end - 1));
            // A mirror has its own validators, so only the primary can honour the job's.
            if let Some(v) = shared.validator.as_ref().filter(|_| i == 0) {
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
                        // The server is counting our connections: stop splitting for this run, and remember how many
                        // worked. This request never started transferring, so `active` counts only the others.
                        shared.throttled.store(true, Ordering::Relaxed);
                        shared.env.dirty.store(true, Ordering::Relaxed);
                        *shared.last_reject.lock().unwrap_or_else(PoisonError::into_inner) = Some(Instant::now());
                        let active = shared.env.live.connections.load(Ordering::Relaxed);
                        if active >= 1 {
                            shared.note_host(active, "rate limited");
                        }
                        if shared.park() {
                            return Ok(SegEnd::Parked);
                        }
                    }
                    shared.env.note_retry_after(&resp);
                    return Err(Stop::Retry(format!("HTTP {status}")));
                }
                status => return Err(Stop::Failed(http_failure(&shared.env.hf, &url, resp.url().as_str(), status, error_code(&resp), shared.env.live.done.load(Ordering::Relaxed) > 0))),
            }
            resp
        }
    };

    let mut file = tokio::fs::OpenOptions::new().write(true).open(&shared.part).await?;
    file.seek(SeekFrom::Start(from)).await?;
    let _transfer = Transfer::start(&shared.env.live);
    let began = (*link, Instant::now());
    let mut pos = from;
    // Written and recorded together, so a recorded byte is always on disk; a cancel drops the unrecorded rest.
    let mut buf: Vec<u8> = Vec::with_capacity(WRITE_BATCH);
    loop {
        if pos + buf.len() as u64 >= seg_pos(shared, idx)?.1 {
            break;
        }
        let chunk = match or_cancel(cancel, tokio::time::timeout(STALL, resp.chunk())).await? {
            Ok(Ok(chunk)) => chunk,
            failed => {
                // Keep what arrived before the drop, so the reconnect asks only for the rest.
                write_batch(shared, idx, &mut file, &mut buf, &mut pos, received, began).await?;
                return Err(Stop::Retry(match failed {
                    Err(_) => "timeout: no data for 30 s".to_string(),
                    Ok(Err(e)) => format!("body: {e}"),
                    Ok(Ok(_)) => unreachable!(),
                }));
            }
        };
        let Some(bytes) = chunk else { break };
        // Read `end` after the wait: a split may have lowered it while the chunk was in transit.
        let end = seg_pos(shared, idx)?.1;
        let at = pos + buf.len() as u64;
        if at >= end {
            break;
        }
        // The server may send past the segment end; those bytes belong to the next segment.
        let take = bytes.len().min((end - at) as usize);
        or_cancel(cancel, shared.env.limiter.acquire(take)).await?;
        buf.extend_from_slice(&bytes[..take]);
        if buf.len() >= WRITE_BATCH {
            write_batch(shared, idx, &mut file, &mut buf, &mut pos, received, began).await?;
        }
    }
    write_batch(shared, idx, &mut file, &mut buf, &mut pos, received, began).await?;
    if pos < seg_pos(shared, idx)?.1 {
        return Err(Stop::Retry(format!("segment {idx} ended early")));
    }
    Ok(SegEnd::Complete)
}

/// Writes the gathered bytes of segment `idx` at `pos`, then records them.
async fn write_batch(
    shared: &Shared,
    idx: usize,
    file: &mut tokio::fs::File,
    buf: &mut Vec<u8>,
    pos: &mut u64,
    received: &mut u64,
    began: (usize, Instant),
) -> Result<(), Stop> {
    if buf.is_empty() {
        return Ok(());
    }
    file.write_all(buf).await?;
    file.flush().await?;
    let counted = shared.record(idx, buf.len() as u64);
    *pos += counted;
    *received += counted;
    let secs = began.1.elapsed().as_secs_f64();
    if secs >= 0.1 {
        shared.links()[began.0].speed = Some(*received as f64 / secs);
    }
    buf.clear();
    Ok(())
}

/// Checks the length, fsyncs and renames `.part` to its final name.
async fn finish(env: &Env) -> Result<Outcome, Stop> {
    let (part, name, total) = with_job(&env.live, |j| (j.part_path.clone(), j.name.clone(), j.total));
    let len = tokio::fs::metadata(&part).await?.len();
    if total.is_some_and(|t| t != len) {
        return Err(Stop::Retry(format!("size mismatch: {len} bytes, expected {total:?}")));
    }
    tokio::fs::OpenOptions::new().write(true).open(&part).await?.sync_all().await?;
    if let Some(expected) = with_job(&env.live, |j| j.sha256.clone()) {
        let id = with_job(&env.live, |j| {
            j.state = JobState::Verifying;
            if let Some(store) = &env.store {
                let _ = store.save(j);
            }
            j.id
        });
        env.hub.state_changed(id);
        let hashed = part.clone();
        let actual = tokio::task::spawn_blocking(move || crate::hf::sha256_file(&hashed)).await.map_err(io::Error::other)??;
        if actual != expected.to_ascii_lowercase() {
            let _ = tokio::fs::remove_file(&part).await;
            // Forget the plan too, so a Resume starts from zero instead of asking for ranges of a deleted file.
            with_job(&env.live, |j| {
                j.segments.clear();
                j.done = 0;
            });
            env.live.done.store(0, Ordering::Relaxed);
            return Ok(Outcome::Failed("Checksum didn't match".to_owned()));
        }
    }
    // Only after the new bytes are whole: a failed download must not cost the old file.
    let mut replace = env.replace_existing.then_some(env.trash);
    // hard_link refuses to overwrite, so two jobs finishing together cannot clobber each other's file.
    let final_path = loop {
        let candidate = claim_name(env.dir.clone(), name.clone(), replace.take(), env.started).await?;
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

/// Picks the name for a finished file and records it in `PRODUCED`, all under one lock. With `trash`, a
/// same-name file is moved to the Trash and its name taken, unless this process produced it after `started`;
/// if the trash fails, the file stays and a free name is picked.
async fn claim_name(dir: PathBuf, name: String, trash: Option<fn(&Path) -> io::Result<()>>, started: u64) -> io::Result<PathBuf> {
    tokio::task::spawn_blocking(move || {
        let mut produced = PRODUCED.lock().unwrap_or_else(PoisonError::into_inner);
        let path = dir.join(&name);
        if let Some(trash) = trash
            && produced.get(&path).is_none_or(|&made| started > made)
            && path.is_file()
            && trash(&path).is_ok()
        {
            record(&mut produced, path.clone());
            return path;
        }
        let candidate = names::unique_final(&dir, &name);
        record(&mut produced, candidate.clone());
        candidate
    })
    .await
    .map_err(io::Error::other)
}

fn record(produced: &mut BTreeMap<PathBuf, u64>, path: PathBuf) {
    produced.insert(path, SEQ.fetch_add(1, Ordering::Relaxed));
    if produced.len() > PRODUCED_CAP
        && let Some(oldest) = produced.iter().min_by_key(|(_, made)| **made).map(|(p, _)| p.clone())
    {
        produced.remove(&oldest);
    }
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

    /// A GET for `url`. The Hugging Face token rides along only on requests to the HF host;
    /// reqwest drops it when a redirect leaves that host.
    fn get(&self, url: &str) -> reqwest::RequestBuilder {
        let target = self.request_url(url);
        let req = self.client.get(&target);
        match &self.hf.token {
            Some(token) if self.hf.covers(&target) => req.bearer_auth(token),
            _ => req,
        }
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
    #[test]
    fn license_text_falls_back_without_a_repo() {
        let hf = HfAccess { host: "huggingface.co:443".into(), token: None };
        let url = "https://huggingface.co/resolve/abc/w.gguf";
        assert_eq!(http_failure(&hf, url, url, 403, None, false), "Accept this model's license on huggingface.co");
        assert_eq!(http_failure(&hf, "https://a.test/f", "https://a.test/f", 403, None, true), "Link expired (HTTP 403)");
        assert_eq!(http_failure(&hf, "https://a.test/f", "https://a.test/f", 404, None, false), "HTTP 404");
        let url = "https://huggingface.co/org/repo/x/resolve/abc/w.gguf";
        assert_eq!(http_failure(&hf, url, url, 403, None, false), "Accept this model's license on huggingface.co");
    }

    /// Drives `Grow` on a synthetic link: `speed(n)` bytes/s with `n` connections. Returns the count held most
    /// over the last 20 ticks (a periodic probe or step-down changes it briefly).
    fn settle(start: usize, cap: usize, ticks: u32, speed: impl Fn(usize) -> f64) -> usize {
        let t0 = Instant::now();
        let mut grow = Grow::new(t0, 0);
        let (mut n, mut done, mut held) = (start, 0.0, [0u32; MAX_PARTS as usize + 1]);
        for k in 1..=ticks {
            done += speed(n);
            match grow.tick(t0 + Duration::from_secs(u64::from(k)), done as u64, true, n, cap) {
                Act::Add(k) => n += k,
                Act::Remove(k) => n -= k,
                Act::None => {}
            }
            if k + 20 > ticks {
                held[n] += 1;
            }
        }
        (0..held.len()).max_by_key(|&c| held[c]).unwrap_or(n)
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
    fn grow_doubles_to_fill_a_server_that_caps_each_connection() {
        // 2 MB/s per connection, up to 16: from one connection it reaches 16 by the 8th second (1, 2, 4, 8, 16,
        // the start and each doubling judged on one second), and holds 16 from then on: no trim at the cap.
        let t0 = Instant::now();
        let mut grow = Grow::new(t0, 0);
        let (mut n, mut done, mut reached, mut lowest_after) = (1usize, 0.0, None, usize::MAX);
        for k in 1..=12u64 {
            done += 2e6 * n as f64;
            match grow.tick(t0 + Duration::from_secs(k), done as u64, true, n, 16) {
                Act::Add(a) => n += a,
                Act::Remove(r) => n -= r,
                Act::None => {}
            }
            if n == 16 && reached.is_none() {
                reached = Some(k);
            }
            if reached.is_some() {
                lowest_after = lowest_after.min(n);
            }
        }
        assert!(reached.is_some_and(|k| k <= 8), "reached 16 at {reached:?}");
        assert_eq!(lowest_after, 16, "dipped below the cap after reaching it");
        assert_eq!(settle(1, 16, 60, |n| 2e6 * n as f64), 16);
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
