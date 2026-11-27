//! Queue order, concurrency limit, and job lifecycle. See design doc "Engine API".
use crate::download::{self, SignUrl};
use crate::events::EventHub;
use crate::hf;
use crate::limit::RateLimiter;
use crate::names;
use crate::cloud;
use crate::queue::{self, QueueConfig, Repeat, NO_QUEUE};
use crate::speed::{self, BestTime, NetworkKind, Sampler, SpeedSettings};
use crate::s3::{self, BucketConfig, Listing, Secrets, Signer};
use crate::store::Store;
use crate::types::{PartView, AddResult, EngineError, HostView, HttpHeader, Job, JobId, JobState, JobView, Live, Outcome, QueueRun, QueueState, QueueView, RunOutcome, now_secs};
use jiff::civil::DateTime;
use jiff::ToSpan;
use std::collections::{HashMap, HashSet};
use std::io;
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicUsize, AtomicBool, AtomicI64, AtomicU64, Ordering, AtomicU32};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};
use tokio::sync::watch;

/// The error `relink` returns when the new link is a different file and no restart was asked for.
pub const DIFFERENT_FILE: &str = "The new link is a different file";
const PROGRESS_INTERVAL: Duration = Duration::from_secs(2);
/// How often queues re-check their windows.
const QUEUE_TICK: Duration = Duration::from_secs(30);
const SPEED_WINDOW: Duration = Duration::from_millis(500);

/// More than this many connections to one server tends to get an IP throttled or blocked.
pub const MAX_CONNECTIONS: u32 = 16;

/// Local wall-clock time; tests replace it.
pub type Clock = Arc<dyn Fn() -> DateTime + Send + Sync>;

/// Wi-Fi, on power, idle: what the app last reported. All false until it reports.
type Conditions = (bool, bool, bool);

/// The open run of a queue; the store row is kept in step.
struct RunRt {
    id: u64,
    files: u32,
    bytes: u64,
    last_emit: Instant,
    /// Counts changed since the last emit.
    dirty: bool,
}

/// Running counts reach the app at most this often.
const RUN_EMIT: Duration = Duration::from_secs(5);

/// A queue's config and what the engine tracks about its current run, in memory.
struct QueueRt {
    config: QueueConfig,
    /// Stop queue: persisted in the store.
    held: bool,
    /// The queue's own bucket, chained under the global one.
    limiter: Arc<RateLimiter>,
    /// Run now: the queue stays open until its run finishes.
    run_now: bool,
    /// A job started since the last finish; a run that started nothing never finishes.
    started_any: bool,
    run: Option<RunRt>,
    /// The pure window was open at the last evaluation.
    was_open: bool,
    /// The start of the window that last opened, so the repeated hour when clocks go back is not a second opening.
    opened_at: Option<DateTime>,
    /// A window without a stop stays open until its run finishes, even past midnight.
    latched: bool,
    /// A window without a stop whose run finished stays closed until it opens again.
    spent: bool,
    /// Inside the run window (or run now) at the last evaluation, for Once to disable itself.
    was_in_window: bool,
    last_view: Option<QueueView>,
}

impl QueueRt {
    /// A queue loaded or created at `now`: a window that is already open counts as opened before now, so
    /// loading is not an opening (it neither lifts a hold nor retries failed jobs).
    fn new(config: QueueConfig, held: bool, global: &Arc<RateLimiter>, now: DateTime) -> QueueRt {
        let opened_at = config.schedule.as_ref().and_then(|s| queue::open_start(s, now));
        let was_open = opened_at.is_some();
        // A window without a stop that opened before now (today, or yesterday on an active day) runs until done.
        let latched = config.schedule.as_ref().is_some_and(|s| {
            s.stop_min.is_none()
                && [now.date() - 1.day(), now.date()].into_iter().any(|d| queue::is_active(&s.repeat, d) && queue::at(d, s.start_min) <= now)
        });
        QueueRt {
            limiter: Arc::new(RateLimiter::with_parent(config.speed_limit, Arc::clone(global))),
            config,
            held,
            run_now: false,
            started_any: false,
            run: None,
            was_open,
            opened_at,
            latched,
            spent: false,
            was_in_window: was_open,
            last_view: None,
        }
    }

    /// A no-stop window whose run finished at `at` (unix seconds), at or after the latest start, stays closed until it opens again.
    fn restore_spent(&mut self, at: i64, now: DateTime) {
        let Some(s) = self.config.schedule.as_ref().filter(|s| s.stop_min.is_none()) else { return };
        let latest = [now.date() - 1.day(), now.date()]
            .into_iter()
            .filter(|d| queue::is_active(&s.repeat, *d) && queue::at(*d, s.start_min) <= now)
            .map(|d| unix_secs(queue::at(d, s.start_min)))
            .max();
        if latest.is_some_and(|start| at >= start) {
            self.latched = false;
            self.spent = self.was_open;
        }
    }

    fn in_window(&self, s: &queue::QueueSchedule, now: DateTime) -> bool {
        (queue::window_open(s, now) && !self.spent) || self.latched
    }

    fn gate(&self, cond: Conditions, now: DateTime) -> QueueState {
        if !self.config.enabled {
            return QueueState::Off;
        }
        if self.run_now {
            return QueueState::Open;
        }
        if self.held {
            return QueueState::Stopped;
        }
        let Some(s) = &self.config.schedule else { return QueueState::Open };
        if !self.in_window(s, now) {
            return QueueState::WaitingForTime { next: queue::next_start(s, now).map_or(0, unix_secs) };
        }
        let missing: Vec<String> = [(s.wifi && !cond.0, "Wi-Fi"), (s.power && !cond.1, "charger"), (s.idle && !cond.2, "idle")]
            .into_iter()
            .filter(|(unmet, _)| *unmet)
            .map(|(_, name)| name.to_owned())
            .collect();
        if missing.is_empty() { QueueState::Open } else { QueueState::WaitingForCondition { missing } }
    }
}

/// Local calendar day as one number, so the prune runs once per local day.
fn day_key(dt: DateTime) -> i64 {
    i64::from(dt.year()) * 1000 + i64::from(dt.day_of_year())
}

/// Unix seconds of the scheduler's local clock; the wall clock only if the zone lookup fails.
fn clock_secs(dt: DateTime) -> i64 {
    match unix_secs(dt) {
        0 => now_secs(),
        s => s,
    }
}

fn unix_secs(dt: DateTime) -> i64 {
    dt.to_zoned_datetime(jiff::tz::TimeZone::system()).map_or(0, |z| z.timestamp().as_second())
}

#[derive(Default)]
struct Counts {
    queued: u32,
    running: u32,
    paused: u32,
    total_bytes: u64,
}

pub struct Scheduler {
    rt: tokio::runtime::Handle,
    store: Arc<Store>,
    hub: Arc<EventHub>,
    dir: Mutex<PathBuf>,
    max_running: AtomicUsize,
    /// Connections per file for downloads started from now on.
    connections: AtomicU32,
    /// Downloads started from now on replace a same-name file (see `download::RunOpts`).
    replace_existing: AtomicBool,
    /// Moves a replaced file to the trash; tests swap it for a local move.
    trash: Mutex<fn(&Path) -> io::Result<()>>,
    /// One bucket shared by every transfer, so the cap is global.
    limiter: Arc<RateLimiter>,
    client: reqwest::Client,
    /// Secret keys of S3 buckets, by bucket name.
    secrets: Arc<dyn Secrets>,
    /// Holds the Hugging Face token under `hf::TOKEN_ACCOUNT`.
    hf_secrets: Arc<dyn Secrets>,
    /// Hugging Face site without a trailing slash; `https://huggingface.co` unless a test points it elsewhere.
    hf_base: String,
    /// The saved token once read: `None` until the first read, then `Some(token or None)`.
    hf_token_cache: Mutex<Option<Option<String>>>,
    jobs: Mutex<Vec<Arc<Live>>>,
    speed: Mutex<HashMap<JobId, (Instant, u64, u64)>>,
    /// Ids whose download task has not returned yet. A paused job keeps its slot until its task stops,
    /// so a resumed job cannot start a second task on the same `.part` file.
    inflight: Mutex<HashSet<JobId>>,
    /// `.part` paths of removed jobs whose task was still running. A task that had not opened its file yet
    /// can re-create it, so `finish` deletes it again once the task has stopped.
    doomed_parts: Mutex<HashMap<JobId, PathBuf>>,
    next_position: AtomicI64,
    stopping: AtomicBool,
    testing: AtomicBool,
    queues: Mutex<std::collections::BTreeMap<u64, QueueRt>>,
    conditions: Mutex<Conditions>,
    network: Mutex<NetworkKind>,
    sampler: Mutex<Sampler>,
    /// `day_key` of the last speed-log prune.
    pruned_day: AtomicI64,
    clock: Mutex<Clock>,
    /// One `refresh` at a time, so edges and events are not interleaved.
    refreshing: Mutex<()>,
    auto_plan: Mutex<AutoPlan>,
    /// Serialises user saves with the follower's writes, so neither overwrites the other from a stale copy.
    queue_edit: Mutex<()>,
    /// One `best_time_queue` at a time, so concurrent first calls cannot create two queues.
    best_queue: Mutex<()>,
}

/// Unix seconds of the minutes at which automatic speed tests start.
#[derive(Default)]
struct AutoPlan {
    /// What the plan was made for: local date, night week on, automatic tests on.
    made_for: Option<(String, bool, bool)>,
    at: Vec<i64>,
    /// Set by tests; the plan is then left alone.
    pinned: bool,
    /// The last minute `auto_test_due` looked at.
    checked: Option<i64>,
}

const KEY_BEST_QUEUE: &str = "best_time_queue_id";
const KEY_REFRESHED: &str = "best_time_refreshed";
const KEY_AUTO: &str = "auto_tests";
const KEY_NIGHT_UNTIL: &str = "night_until";
const KEY_NIGHT_ANSWERED: &str = "night_prompt_answered";
const SAMPLE_DAYS: i64 = 28;

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

fn is_active(state: &JobState) -> bool {
    matches!(state, JobState::Running | JobState::Retrying { .. })
}

/// Absolute, and no `..`, so a job's folder cannot climb out of where the caller meant.
fn is_plain_abs(dir: &Path) -> bool {
    dir.is_absolute() && !dir.components().any(|c| matches!(c, Component::ParentDir))
}

/// One plain file name: it joins onto the job's folder without leaving it.
fn valid_file_name(name: &str) -> bool {
    !name.is_empty() && name != "." && name != ".." && !name.contains(['/', '\\', '\0'])
}

impl Scheduler {
    /// Loads jobs from `store` (already reconciled, all unfinished are Paused).
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        rt: tokio::runtime::Handle,
        store: Arc<Store>,
        hub: Arc<EventHub>,
        downloads_dir: PathBuf,
        max_running: u32,
        connections: u32,
        speed_limit: u64,
        secrets: Arc<dyn Secrets>,
        hf_secrets: Arc<dyn Secrets>,
        hf_base: String,
    ) -> Result<Arc<Scheduler>, EngineError> {
        store.close_open_runs(now_secs())?;
        let mut loaded = Vec::new();
        {
            // Jobs of a scheduled queue that were waiting or running stay Queued, so its window decides; the rest reload Paused.
            let all = store.queues()?;
            let scheduled: HashSet<u64> = all.iter().filter(|(q, _)| q.schedule.is_some()).filter_map(|(q, _)| q.id).collect();
            let known: HashSet<u64> = all.iter().filter_map(|(q, _)| q.id).collect();
            for (mut job, saved) in store.load_with_saved_state()? {
                if job.queue_id != NO_QUEUE && !known.contains(&job.queue_id) {
                    job.queue_id = NO_QUEUE;
                }
                if scheduled.contains(&job.queue_id) && matches!(saved, JobState::Queued | JobState::Running | JobState::Retrying { .. }) {
                    job.state = JobState::Queued;
                }
                loaded.push(job);
            }
        }
        let next_position = loaded.iter().map(|j| j.position).max().map_or(0, |p| p + 1);
        let lives = loaded
            .into_iter()
            .map(|job| {
                Arc::new(Live {
                    done: AtomicU64::new(job.done),
                    job: Mutex::new(job),
                    connections: AtomicU32::new(0),
                    cancel: Mutex::new(watch::channel(false).0),
                    started: download::next_seq(),
                })
            })
            .collect();
        // HTTP/3's QUIC endpoint binds its UDP socket on the runtime, so the client is built inside it.
        let _in_runtime = rt.enter();
        let builder = reqwest::Client::builder();
        // Experimental, build-time `http3` feature: RAYS_HTTP3=1 sends every request over HTTP/3 (fails on servers without it).
        #[cfg(feature = "http3")]
        let builder = if std::env::var_os("RAYS_HTTP3").is_some() { builder.tls_backend_rustls().http3_prior_knowledge() } else { builder };
        let client = builder
            // Some servers and CDNs reject requests that carry no User-Agent (speed.cloudflare.com answers 403).
            .user_agent(concat!("Rays/", env!("CARGO_PKG_VERSION"), " (+https://rays.a6n.ai)"))
            .connect_timeout(Duration::from_secs(15))
            .read_timeout(Duration::from_secs(30))
            .build()
            .map_err(|e| EngineError::Io { msg: e.to_string() })?;
        let limiter = Arc::new(RateLimiter::new(speed_limit));
        let clock: Clock = Arc::new(|| jiff::ZonedDateTime::now().datetime());
        let now = clock();
        let queues = store
            .queues()?
            .into_iter()
            .filter_map(|(config, held)| {
                let id = config.id?;
                let mut rt = QueueRt::new(config, held, &limiter, now);
                if let Ok(Some(at)) = store.last_finished_at(id) {
                    rt.restore_spent(at, now);
                }
                Some((id, rt))
            })
            .collect();
        let sched = Arc::new(Scheduler {
            rt,
            store,
            hub,
            dir: Mutex::new(downloads_dir),
            max_running: AtomicUsize::new((max_running as usize).max(1)),
            connections: AtomicU32::new(connections.clamp(1, MAX_CONNECTIONS)),
            replace_existing: AtomicBool::new(false),
            trash: Mutex::new(download::trash_file),
            limiter,
            client,
            secrets,
            hf_secrets,
            hf_base,
            hf_token_cache: Mutex::new(None),
            jobs: Mutex::new(lives),
            speed: Mutex::new(HashMap::new()),
            inflight: Mutex::new(HashSet::new()),
            doomed_parts: Mutex::new(HashMap::new()),
            next_position: AtomicI64::new(next_position),
            stopping: AtomicBool::new(false),
            testing: AtomicBool::new(false),
            queues: Mutex::new(queues),
            conditions: Mutex::new((false, false, false)),
            network: Mutex::new(NetworkKind::Unknown),
            sampler: Mutex::new(Sampler::default()),
            pruned_day: AtomicI64::new(i64::MIN),
            clock: Mutex::new(clock),
            refreshing: Mutex::new(()),
            auto_plan: Mutex::new(AutoPlan::default()),
            queue_edit: Mutex::new(()),
            best_queue: Mutex::new(()),
        });
        let weak = Arc::downgrade(&sched);
        sched.rt.spawn(async move {
            let mut tick = tokio::time::interval(PROGRESS_INTERVAL);
            loop {
                tick.tick().await;
                match weak.upgrade() {
                    // It fsyncs, so it runs on the blocking pool, not on one of the two runtime threads.
                    Some(s) => {
                        let _ = tokio::task::spawn_blocking(move || { s.flush_progress(); s.sample_speed(); }).await;
                    }
                    None => break,
                }
            }
        });
        let weak = Arc::downgrade(&sched);
        sched.rt.spawn(async move {
            let mut tick = tokio::time::interval(QUEUE_TICK);
            loop {
                tick.tick().await;
                match weak.upgrade() {
                    Some(s) => {
                        let _ = tokio::task::spawn_blocking(move || s.tick()).await;
                    }
                    None => break,
                }
            }
        });
        Ok(sched)
    }

    /// Bytes per second across all downloads; 0 means unlimited. Takes effect within about 100 ms.
    pub fn set_speed_limit(&self, bytes_per_sec: u64) {
        self.limiter.set_rate(bytes_per_sec);
    }

    /// Applies to downloads started after this call.
    /// Applies at once: lowering it lets running jobs finish; raising it starts queued ones.
    pub fn set_max_running(self: &Arc<Self>, n: u32) {
        self.max_running.store((n as usize).clamp(1, 10), Ordering::Relaxed);
        self.refresh();
    }

    /// New downloads (and the final rename of jobs started after this call) use `dir`.
    pub fn set_downloads_dir(&self, dir: PathBuf) {
        *lock(&self.dir) = dir;
    }

    pub fn downloads_dir(&self) -> PathBuf {
        lock(&self.dir).clone()
    }

    pub fn set_connections(&self, n: u32) {
        self.connections.store(n.clamp(1, MAX_CONNECTIONS), Ordering::Relaxed);
    }
    /// Applies to downloads started after this call.
    pub fn set_replace_existing(&self, on: bool) {
        self.replace_existing.store(on, Ordering::Relaxed);
    }

    /// Applies to downloads started after this call.
    pub fn set_trash(&self, trash: fn(&Path) -> io::Result<()>) {
        *lock(&self.trash) = trash;
    }

    pub fn difficult_hosts(&self) -> Vec<HostView> {
        self.store.hosts().unwrap_or_default()
    }

    pub fn forget_host(&self, host: &str) {
        let _ = self.store.forget_host(host);
    }

    /// Validates http/https, creates Queued jobs, starts as many as the limit allows.
    pub fn add(self: &Arc<Self>, urls: Vec<String>) -> Vec<AddResult> {
        let n = urls.len();
        self.add_to(urls, None, vec![None; n], None)
    }

    /// Like `add`, saving into `dir` (None: the downloads dir). `fixed_names[i]` names job `i` and keeps the
    /// server's Content-Disposition from renaming it.
    pub fn add_to(
        self: &Arc<Self>,
        urls: Vec<String>,
        dir: Option<PathBuf>,
        fixed_names: Vec<Option<String>>,
        queue: Option<u64>,
    ) -> Vec<AddResult> {
        self.add_with(urls, dir, fixed_names, Vec::new(), Vec::new(), Vec::new(), queue)
    }

    /// Like `add_to`, with an expected SHA-256 per url (`sha256s` empty: none). A bad hash rejects only that url.
    #[allow(clippy::too_many_arguments)]
    pub fn add_with(
        self: &Arc<Self>,
        urls: Vec<String>,
        dir: Option<PathBuf>,
        fixed_names: Vec<Option<String>>,
        sha256s: Vec<Option<String>>,
        mirrors: Vec<Vec<String>>,
        headers: Vec<Vec<HttpHeader>>,
        queue: Option<u64>,
    ) -> Vec<AddResult> {
        let queue_id = queue.unwrap_or(NO_QUEUE);
        if queue_id != NO_QUEUE && !lock(&self.queues).contains_key(&queue_id) {
            return urls.into_iter().map(|url| AddResult { url, id: None, error: Some("no such queue".to_owned()) }).collect();
        }
        if dir.as_ref().is_some_and(|d| !is_plain_abs(d)) {
            return urls
                .into_iter()
                .map(|url| AddResult { url, id: None, error: Some("destination must be an absolute path with no ..".to_owned()) })
                .collect();
        }
        if !fixed_names.is_empty() && fixed_names.len() != urls.len() {
            return urls.into_iter().map(|url| AddResult { url, id: None, error: Some("names must match urls".to_owned()) }).collect();
        }
        if !sha256s.is_empty() && sha256s.len() != urls.len() {
            return urls.into_iter().map(|url| AddResult { url, id: None, error: Some("checksums must match urls".to_owned()) }).collect();
        }
        if !mirrors.is_empty() && mirrors.len() != urls.len() {
            return urls.into_iter().map(|url| AddResult { url, id: None, error: Some("mirrors must match urls".to_owned()) }).collect();
        }
        if !headers.is_empty() && headers.len() != urls.len() {
            return urls.into_iter().map(|url| AddResult { url, id: None, error: Some("headers must match urls".to_owned()) }).collect();
        }
        let origins: HashSet<Option<String>> =
            urls.iter().zip(&headers).filter(|(_, h)| !h.is_empty()).map(|(u, _)| reqwest::Url::parse(u).ok().map(|u| u.origin().ascii_serialization())).collect();
        if origins.len() > 1 {
            let error = "headers apply to one site; add links for other sites separately";
            return urls.into_iter().map(|url| AddResult { url, id: None, error: Some(error.to_owned()) }).collect();
        }
        let (mut fixed, mut sums, mut extra, mut sent) = (fixed_names.into_iter(), sha256s.into_iter(), mirrors.into_iter(), headers.into_iter());
        let results = urls
            .into_iter()
            .map(|url| {
                let headers: Vec<HttpHeader> = sent.next().unwrap_or_default().into_iter().map(|h| HttpHeader { name: h.name.trim().to_owned(), value: h.value }).collect();
                let (sum, name, mut mirrors) = (sums.next().flatten().map(|h| h.trim().to_ascii_lowercase()), fixed.next().flatten(), extra.next().unwrap_or_default());
                if sum.as_deref().is_some_and(|h| h.len() != 64 || !h.bytes().all(|c| c.is_ascii_hexdigit())) {
                    return AddResult { url, id: None, error: Some("sha256 must be 64 hex characters".to_owned()) };
                }
                let mut seen = vec![url.clone()];
                mirrors.retain(|m| {
                    let new = !seen.contains(m);
                    seen.push(m.clone());
                    new
                });
                if url.starts_with("s3://") && !mirrors.is_empty() {
                    return AddResult { url, id: None, error: Some("mirrors are not supported for s3 links".to_owned()) };
                }
                if let Some(bad) = mirrors.iter().find_map(|m| self.check_url(m).err()) {
                    return AddResult { url, id: None, error: Some(format!("mirror: {bad}")) };
                }
                if let Err(error) = download::check_headers(&url, &headers) {
                    return AddResult { url, id: None, error: Some(error) };
                }
                self.add_one(url, dir.clone(), name, sum, mirrors, headers, queue_id)
            })
            .collect();
        self.refresh();
        results
    }

    /// Queues each file of a Hugging Face commit as `dest_dir/<its repo path>`, with its SHA-256 when one is
    /// published. A file already there with the same size is skipped; the rest follow the same-name setting.
    pub fn add_hf(self: &Arc<Self>, repo: &str, sha: &str, files: Vec<hf::HfFile>, dest_dir: &Path, queue: Option<u64>) -> Vec<hf::HfAdd> {
        let queue_id = queue.unwrap_or(NO_QUEUE);
        let known = queue_id == NO_QUEUE || lock(&self.queues).contains_key(&queue_id);
        let mut recorded = Vec::new();
        let results = files
            .into_iter()
            .map(|file| {
                let status = if known {
                    self.add_hf_file(repo, sha, dest_dir, &file, queue_id)
                } else {
                    hf::HfAddStatus::Rejected { error: "no such queue".to_owned() }
                };
                if !matches!(status, hf::HfAddStatus::Rejected { .. }) {
                    recorded.push(file.clone());
                }
                hf::HfAdd { path: file.path, status }
            })
            .collect();
        if !recorded.is_empty() {
            // The downloads still go ahead; only offline verify loses this manifest.
            if let Err(e) = hf::merge_manifest(dest_dir, repo, sha, recorded) {
                eprintln!("warn: could not write the model manifest in {}: {e}", dest_dir.display());
            }
        }
        self.refresh();
        results
    }

    /// The first job for the same folder and name whose state passes `keep`. Same file means same folder and name.
    fn twin(&self, folder: &Path, name: &str, keep: impl Fn(&JobState) -> bool) -> Option<JobId> {
        let default = lock(&self.dir).clone();
        lock(&self.jobs).iter().find_map(|live| {
            let job = lock(&live.job);
            let job_dir = job.dir.as_deref().unwrap_or(default.as_path());
            (job_dir == folder && job.name == name && keep(&job.state)).then_some(job.id)
        })
    }

    fn add_hf_file(self: &Arc<Self>, repo: &str, sha: &str, dest_dir: &Path, file: &hf::HfFile, queue_id: u64) -> hf::HfAddStatus {
        let rejected = |error: &str| hf::HfAddStatus::Rejected { error: error.to_owned() };
        if !is_plain_abs(dest_dir) {
            return rejected("destination must be an absolute path with no ..");
        }
        // The manifest lives at the folder's root under this name, so a repo file must not take it.
        let Some((parent, name)) = hf::hf_target(dest_dir, &file.path).filter(|_| !hf::is_manifest_name(&file.path)) else {
            return rejected("unsafe file path");
        };
        if !file.sha256.as_deref().is_none_or(|h| h.len() == 64 && h.bytes().all(|c| c.is_ascii_hexdigit())) {
            return rejected("Hugging Face gave an invalid checksum for this file");
        }
        if std::fs::metadata(parent.join(&name)).is_ok_and(|m| m.is_file() && m.len() == file.size) {
            return hf::HfAddStatus::AlreadyThere;
        }
        let Some(url) = hf::file_url(&self.hf_base, repo, sha, &file.path) else {
            return rejected("not a Hugging Face file");
        };
        if let Some(id) = self.twin(&parent, &name, |s| !matches!(s, JobState::Done { .. } | JobState::Failed { .. })) {
            return hf::HfAddStatus::AlreadyQueued { id };
        }
        if let Some(id) = self.twin(&parent, &name, |s| matches!(s, JobState::Failed { .. })) {
            let same = self.find(id).is_some_and(|live| {
                let job = lock(&live.job);
                job.url == url && job.sha256.as_deref().map(str::to_ascii_lowercase) == file.sha256.as_deref().map(str::to_ascii_lowercase)
            });
            if same {
                self.resume(id);
                return hf::HfAddStatus::Added { id };
            }
            // Another revision or checksum, or another URL: the old job must not finish under the new add.
            self.remove(id, true);
        }
        let res = self.add_one(url, Some(parent), Some(name), file.sha256.clone(), Vec::new(), Vec::new(), queue_id);
        match (res.id, res.error) {
            (Some(id), _) => hf::HfAddStatus::Added { id },
            (None, error) => rejected(&error.unwrap_or_default()),
        }
    }

    pub fn pause(self: &Arc<Self>, id: JobId) {
        let Some(live) = self.find(id) else { return };
        let changed = {
            let mut job = lock(&live.job);
            let pausable = is_active(&job.state) || job.state == JobState::Queued;
            if pausable {
                if is_active(&job.state) {
                    lock(&live.cancel).send_replace(true);
                }
                job.state = JobState::Paused;
                job.done = live.done.load(Ordering::Relaxed);
                let _ = self.store.save(&job);
            }
            pausable
        };
        if changed {
            self.hub.state_changed(id);
            self.refresh();
        }
    }

    pub fn resume(self: &Arc<Self>, id: JobId) {
        let Some(live) = self.find(id) else { return };
        let changed = {
            let mut job = lock(&live.job);
            let resumable = matches!(job.state, JobState::Paused | JobState::Failed { .. });
            if resumable {
                job.state = JobState::Queued;
                let _ = self.store.save(&job);
            }
            resumable
        };
        if changed {
            self.hub.state_changed(id);
            self.refresh();
        }
    }

    /// Points a paused, failed or queued job at a new link and queues it. The `.part` is kept when the new link
    /// reports the same size (and the same ETag when both links have one). A different file is refused with
    /// `DIFFERENT_FILE` unless `restart` is set, which deletes the `.part` and starts over.
    pub async fn relink(self: &Arc<Self>, id: JobId, url: &str, restart: bool) -> Result<(), EngineError> {
        let invalid = |msg: String| EngineError::InvalidUrl { msg };
        self.check_url(url).map_err(invalid)?;
        let live = self.find(id).ok_or_else(|| invalid("no such download".into()))?;
        let idle = |s: &JobState| matches!(s, JobState::Paused | JobState::Failed { .. } | JobState::Queued);
        if !idle(&lock(&live.job).state) {
            return Err(invalid("pause the download before changing its link".into()));
        }
        let target = self.sign_for(url).map_err(invalid)?.map_or_else(|| url.to_owned(), |sign| sign());
        let (req, saved) = {
            let job = lock(&live.job);
            (download::job_request(&self.client, &job, url, &target).header(reqwest::header::RANGE, "bytes=0-0"), job.headers.clone())
        };
        let probe = download::send_following(req, &saved);
        let io = |msg: String| EngineError::Io { msg };
        let resp = tokio::time::timeout(Duration::from_secs(15), probe)
            .await
            .map_err(|_| io("the new link did not answer".into()))?
            .map_err(|e| io(format!("the new link: {e}")))?;
        let status = resp.status();
        if !status.is_success() {
            return Err(io(format!("the new link answered HTTP {}", status.as_u16())));
        }
        let header = |name| resp.headers().get(name).and_then(|v| v.to_str().ok()).map(str::to_owned);
        if header(reqwest::header::CONTENT_TYPE).is_some_and(|t| t.trim_start().to_ascii_lowercase().starts_with("text/html")) {
            return Err(io("That link is a web page, not the file".into()));
        }
        let new_total = header(reqwest::header::CONTENT_RANGE)
            .and_then(|v| v.rsplit('/').next()?.parse::<u64>().ok())
            .or_else(|| if status.as_u16() == 200 { resp.content_length() } else { None });
        let new_etag = header(reqwest::header::ETAG);
        let new_modified = header(reqwest::header::LAST_MODIFIED);
        let mut job = lock(&live.job);
        if !idle(&job.state) {
            return Err(invalid("the download started while its link was being checked".into()));
        }
        let etag_conflict = job.etag.is_some() && new_etag.is_some() && job.etag != new_etag;
        let same = match job.total {
            Some(_) => job.total == new_total && !etag_conflict,
            None => job.etag.is_some() && job.etag == new_etag,
        };
        let has_bytes = job.done > 0 || job.part_path.exists();
        if !same && has_bytes && !restart {
            return Err(io(DIFFERENT_FILE.into()));
        }
        if !same {
            let _ = std::fs::remove_file(&job.part_path);
            job.segments.clear();
            job.done = 0;
            live.done.store(0, Ordering::Relaxed);
            job.total = new_total;
            job.etag = new_etag;
            job.last_modified = new_modified;
        }
        if download::headers_for(&job, url).is_empty() {
            job.headers.clear();
        }
        job.url = url.to_owned();
        job.state = JobState::Queued;
        let _ = self.store.save(&job);
        drop(job);
        self.hub.state_changed(id);
        self.refresh();
        Ok(())
    }

    pub fn remove(self: &Arc<Self>, id: JobId, delete_partial: bool) {
        let removed = {
            let mut jobs = lock(&self.jobs);
            let at = jobs.iter().position(|l| lock(&l.job).id == id);
            at.map(|at| jobs.remove(at))
        };
        let Some(live) = removed else { return };
        lock(&live.cancel).send_replace(true);
        let part_path = lock(&live.job).part_path.clone();
        let _ = self.store.delete(id);
        lock(&self.speed).remove(&id);
        if delete_partial {
            let _ = std::fs::remove_file(&part_path);
            // Taking `inflight` first pairs with `finish`, so a task that is still running cannot slip past.
            let inflight = lock(&self.inflight);
            if inflight.contains(&id) {
                lock(&self.doomed_parts).insert(id, part_path);
            }
        }
        self.hub.removed(id);
        self.refresh();
    }

    /// All jobs in queue order.
    pub fn views(&self) -> Vec<JobView> {
        let lives = lock(&self.jobs).to_vec();
        lives.iter().map(|live| self.view_of(live)).collect()
    }

    /// One job, or None if it no longer exists.
    pub fn view(&self, id: JobId) -> Option<JobView> {
        self.find(id).map(|live| self.view_of(&live))
    }

    /// Stops every running job (Paused, or Queued in a scheduled queue) and saves all jobs.
    pub fn shutdown(&self) {
        self.stopping.store(true, Ordering::Relaxed);
        let scheduled: HashSet<u64> = lock(&self.queues).iter().filter(|(_, rt)| rt.config.schedule.is_some()).map(|(id, _)| *id).collect();
        let lives = lock(&self.jobs).to_vec();
        for live in &lives {
            let mut job = lock(&live.job);
            if is_active(&job.state) {
                lock(&live.cancel).send_replace(true);
                // A scheduled queue's job stays Queued, so its window decides after the next launch.
                job.state = if scheduled.contains(&job.queue_id) { JobState::Queued } else { JobState::Paused };
            }
            job.done = live.done.load(Ordering::Relaxed);
            let _ = self.store.save(&job);
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn add_one(&self, url: String, dir: Option<PathBuf>, fixed_name: Option<String>, sha256: Option<String>, mirrors: Vec<String>, headers: Vec<HttpHeader>, queue_id: u64) -> AddResult {
        if let Err(error) = self.check_url(&url) {
            return AddResult { url, id: None, error: Some(error) };
        }
        if fixed_name.as_deref().is_some_and(|n| !valid_file_name(n)) {
            return AddResult { url, id: None, error: Some("file name must be one path component".to_owned()) };
        }
        match self.insert_job(&url, dir, fixed_name, sha256, mirrors, headers, queue_id) {
            Ok(id) => AddResult { url, id: Some(id), error: None },
            Err(e) => AddResult { url, id: None, error: Some(e.to_string()) },
        }
    }

    fn check_url(&self, url: &str) -> Result<(), String> {
        if url.starts_with("s3://") {
            let (bucket, _) = s3::parse_link(url).ok_or("an s3 link is s3://bucket/key")?;
            return self.bucket(&bucket).map(|_| ());
        }
        let parsed = reqwest::Url::parse(url).map_err(|e| e.to_string())?;
        let web = matches!(parsed.scheme(), "http" | "https");
        if web && parsed.host_str().is_some_and(|h| !h.is_empty()) {
            Ok(())
        } else {
            Err("only http, https and s3 links".to_owned())
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn insert_job(&self, url: &str, dir: Option<PathBuf>, fixed_name: Option<String>, sha256: Option<String>, mirrors: Vec<String>, headers: Vec<HttpHeader>, queue_id: u64) -> Result<JobId, EngineError> {
        let now = now_secs();
        let position = self.next_position.fetch_add(1, Ordering::Relaxed);
        let folder = dir.clone().unwrap_or_else(|| lock(&self.dir).clone());
        let mut job = Job {
            id: 0,
            url: url.to_owned(),
            fixed_name: fixed_name.is_some(),
            name: fixed_name.unwrap_or_else(|| names::from_url(url)),
            dir,
            sha256,
            mirrors,
            headers,
            part_path: PathBuf::new(),
            final_path: None,
            done: 0,
            total: None,
            etag: None,
            last_modified: None,
            resumable: true,
            state: JobState::Queued,
            segments: Vec::new(),
            position,
            created_at: now,
            updated_at: now,
            queue_id,
        };
        let id = self.store.insert(&mut job)?;
        job.part_path = names::part_path(&folder, &job.name, id);
        // A new job owns no bytes yet: a leftover .part with the same name (ids restart with a new
        // database) would otherwise be resumed or mistaken for a finished file.
        let _ = std::fs::remove_file(&job.part_path);
        if let Err(e) = self.store.save(&job) {
            let _ = self.store.delete(id);
            return Err(e);
        }
        let live = Arc::new(Live {
            done: AtomicU64::new(0),
            job: Mutex::new(job),
            connections: AtomicU32::new(0),
            cancel: Mutex::new(watch::channel(false).0),
            started: download::next_seq(),
        });
        {
            let mut jobs = lock(&self.jobs);
            let at = jobs.partition_point(|l| lock(&l.job).position < position);
            jobs.insert(at, live);
        }
        self.hub.state_changed(id);
        Ok(id)
    }

    /// Saves a bucket after one listing proves the endpoint and keys work. The secret goes to `secrets` only.
    pub async fn add_bucket(&self, cfg: BucketConfig, secret: String) -> Result<(), EngineError> {
        let invalid = |msg: &str| EngineError::InvalidUrl { msg: msg.to_owned() };
        if cfg.name.is_empty() || cfg.name.contains('/') {
            return Err(invalid("bucket name is empty or has a slash"));
        }
        if !(cfg.endpoint.starts_with("https://") || cfg.endpoint.starts_with("http://")) {
            return Err(invalid("endpoint must start with https://"));
        }
        if let Some(profile) = &cfg.profile {
            let keys = cloud::aws_keys(profile).map_err(|msg| EngineError::InvalidUrl { msg })?;
            Signer::with_keys(&cfg, &keys)?.list(&self.client, "", None).await?;
            return self.store.save_bucket(&cfg);
        }
        if cfg.access_key_id.is_empty() || secret.is_empty() {
            return Err(invalid("access key ID and secret are required"));
        }
        Signer::new(&cfg, &secret)?.list(&self.client, "", None).await?;
        self.secrets.set(&cfg.name, &secret)?;
        self.store.save_bucket(&cfg)
    }

    /// Adds an R2 bucket from the `cf` login. The first one creates a read-only R2 token, kept in
    /// `secrets` under a name no bucket can have, so later buckets reuse it.
    pub async fn add_cloudflare_bucket(&self, account_id: String, name: String) -> Result<(), EngineError> {
        let slot = format!("cloudflare/{account_id}");
        let saved = self.secrets.get(&slot).and_then(|s| s.split_once('\n').map(|(k, v)| (k.to_owned(), v.to_owned())));
        let (key, secret) = match saved {
            Some(pair) => pair,
            None => {
                let acct = account_id.clone();
                let keys = tokio::task::spawn_blocking(move || cloud::cf_create_keys(&acct))
                    .await
                    .map_err(|e| EngineError::Io { msg: e.to_string() })?
                    .map_err(|msg| EngineError::InvalidUrl { msg })?;
                self.secrets.set(&slot, &format!("{}\n{}", keys.key, keys.secret))?;
                (keys.key, keys.secret)
            }
        };
        let cfg = BucketConfig {
            name,
            provider: "r2".into(),
            endpoint: format!("https://{account_id}.r2.cloudflarestorage.com"),
            region: "auto".into(),
            access_key_id: key,
            path_style: true,
            profile: None,
        };
        // A new token can take a few seconds to work everywhere.
        let mut tries = 0;
        loop {
            match self.add_bucket(cfg.clone(), secret.clone()).await {
                Err(e) if tries < 5 && token_not_ready(&e) => {
                    tries += 1;
                    tokio::time::sleep(std::time::Duration::from_secs(2)).await;
                }
                other => return other,
            }
        }
    }

    pub fn remove_bucket(&self, name: &str) -> Result<(), EngineError> {
        self.store.remove_bucket(name)?;
        self.secrets.delete(name);
        Ok(())
    }

    pub fn buckets(&self) -> Vec<BucketConfig> {
        self.store.buckets().unwrap_or_default()
    }

    pub async fn list_bucket(&self, name: &str, prefix: &str, token: Option<String>) -> Result<Listing, EngineError> {
        let signer = self.signer(name).map_err(|msg| EngineError::InvalidUrl { msg })?;
        signer.list(&self.client, prefix, token.as_deref()).await
    }

    pub async fn grab_links(&self, page_url: &str) -> Result<Vec<crate::grab::GrabbedLink>, EngineError> {
        crate::grab::grab(&self.client, page_url).await
    }

    pub async fn hf_search(self: &Arc<Self>, query: &str) -> Result<Vec<hf::HfModel>, EngineError> {
        let token = self.hf_token_off_thread().await;
        hf::search(&self.client, &self.hf_base, token.as_deref(), query).await
    }

    pub async fn hf_model(self: &Arc<Self>, repo: &str) -> Result<hf::HfRepo, EngineError> {
        let token = self.hf_token_off_thread().await;
        hf::model(&self.client, &self.hf_base, token.as_deref(), repo).await
    }

    /// `None` or an empty token deletes the saved one.
    pub fn set_hf_token(&self, token: Option<&str>) -> Result<(), EngineError> {
        let token = token.filter(|t| !t.is_empty());
        match token {
            Some(token) => self.hf_secrets.set(hf::TOKEN_ACCOUNT, token)?,
            None => self.hf_secrets.delete(hf::TOKEN_ACCOUNT),
        }
        *lock(&self.hf_token_cache) = Some(token.map(str::to_owned));
        Ok(())
    }

    pub fn has_hf_token(&self) -> bool {
        self.hf_token().is_some()
    }

    /// Reads the Keychain once, the first time the token is needed; later reads come from memory.
    /// Blocking: call it off the runtime workers (see `warm_hf_token`, `hf_token_off_thread`).
    fn hf_token(&self) -> Option<String> {
        let cached = lock(&self.hf_token_cache).clone();
        if let Some(token) = cached {
            return token;
        }
        let token = self.hf_secrets.get(hf::TOKEN_ACCOUNT);
        lock(&self.hf_token_cache).get_or_insert(token).clone()
    }

    /// Loads the token now, on the caller's blocking thread, so later reads never block a worker.
    pub fn warm_hf_token(&self) {
        self.hf_token();
    }

    async fn hf_token_off_thread(self: &Arc<Self>) -> Option<String> {
        let sched = Arc::clone(self);
        self.rt.spawn_blocking(move || sched.hf_token()).await.ok().flatten()
    }

    fn bucket(&self, name: &str) -> Result<BucketConfig, String> {
        self.buckets().into_iter().find(|b| b.name == name).ok_or_else(|| format!("no bucket named {name} in Rays"))
    }

    fn signer(&self, name: &str) -> Result<Signer, String> {
        let cfg = self.bucket(name)?;
        if let Some(profile) = &cfg.profile {
            let keys = cloud::aws_keys(profile)?;
            return Signer::with_keys(&cfg, &keys).map_err(|e| e.to_string());
        }
        let secret = self.secrets.get(name).ok_or_else(|| format!("no secret key saved for bucket {name}"))?;
        Signer::new(&cfg, &secret).map_err(|e| e.to_string())
    }

    /// `None` for web links; for an `s3://` link, a function that signs a fresh GET each time it is called.
    fn sign_for(&self, url: &str) -> Result<Option<SignUrl>, String> {
        let Some((bucket, key)) = s3::parse_link(url) else {
            return Ok(None);
        };
        let signer = self.signer(&bucket)?;
        let Some(profile) = self.bucket(&bucket)?.profile else {
            return Ok(Some(Arc::new(move || signer.get(&key))));
        };
        // Login keys expire (often after an hour), so a long download asks the CLI again; the
        // keys are cached, so this costs a process run only every few minutes.
        let cfg = self.bucket(&bucket)?;
        Ok(Some(Arc::new(move || match cloud::aws_keys(&profile).and_then(|k| Signer::with_keys(&cfg, &k).map_err(|e| e.to_string())) {
            Ok(fresh) => fresh.get(&key),
            Err(_) => signer.get(&key),
        })))
    }

    fn find(&self, id: JobId) -> Option<Arc<Live>> {
        lock(&self.jobs).iter().find(|l| lock(&l.job).id == id).cloned()
    }

    /// Starts queued jobs while a slot is free.
    fn pump(self: &Arc<Self>) {
        if self.stopping.load(Ordering::Relaxed) {
            return;
        }
        while let Some((live, id, rx)) = self.start_next() {
            {
                let job = lock(&live.job);
                let _ = self.store.save(&job);
            }
            self.hub.state_changed(id);
            let sched = Arc::clone(self);
            let client = self.client.clone();
            let dir = lock(&self.dir).clone();
            let hub = Arc::clone(&self.hub);
            let connections = self.connections.load(Ordering::Relaxed);
            let url = lock(&live.job).url.clone();
            // Only a Hugging Face job may read the token, so other downloads never touch the Keychain.
            let host = download::host_port(&self.hf_base).unwrap_or_default();
            let token = if download::host_port(&url).as_deref() == Some(host.as_str()) { self.hf_token() } else { None };
            let hf = download::HfAccess { host, token };
            let trash = *lock(&self.trash);
            let opts = download::RunOpts { replace_existing: self.replace_existing.load(Ordering::Relaxed), trash, hf };
            let limiter = self.queue_limiter(lock(&live.job).queue_id);
            let store = Arc::clone(&self.store);
            let sign = self.sign_for(&url);
            self.rt.spawn(async move {
                let outcome = match sign {
                    Ok(sign) => download::run(live, client, &dir, hub, rx, connections, 1, limiter, Some(store), sign, opts).await,
                    Err(reason) => Outcome::Failed(reason),
                };
                sched.finish(id, outcome);
            });
        }
    }

    /// Picks the first Queued job and claims a slot for it, all under the locks so two pumps cannot pick the same job.
    fn start_next(&self) -> Option<(Arc<Live>, JobId, watch::Receiver<bool>)> {
        // Taken before the job locks, to keep one order: queue state, then job locks. `finish` is the exception and
        // takes the queue lock under one job lock, so nothing may take a job lock while holding the queue lock.
        let gates = self.queue_gates();
        let jobs = lock(&self.jobs);
        let mut inflight = lock(&self.inflight);
        if inflight.len() >= self.max_running.load(Ordering::Relaxed) {
            return None;
        }
        // Verifying and held jobs still own their task, so they count against both caps.
        let mut running: HashMap<u64, usize> = HashMap::new();
        for l in jobs.iter() {
            let job = lock(&l.job);
            if inflight.contains(&job.id) {
                *running.entry(job.queue_id).or_default() += 1;
            }
        }
        let live = Arc::clone(jobs.iter().find(|l| {
            let job = lock(&l.job);
            job.state == JobState::Queued
                && !inflight.contains(&job.id)
                && gates.get(&job.queue_id).is_none_or(|&(open, cap)| open && running.get(&job.queue_id).copied().unwrap_or(0) < cap)
        })?);
        let (id, queue_id) = {
            let mut job = lock(&live.job);
            job.state = JobState::Running;
            (job.id, job.queue_id)
        };
        if let Some(rt) = lock(&self.queues).get_mut(&queue_id) {
            rt.started_any = true;
            if rt.run.is_none() {
                match self.store.open_run(queue_id, now_secs()) {
                    Ok(run) => {
                        rt.run = Some(RunRt { id: run, files: 0, bytes: 0, last_emit: Instant::now(), dirty: false });
                        self.hub.run_changed(run);
                    }
                    Err(e) => eprintln!("warn: could not record a run of queue {queue_id}: {e}"),
                }
            }
        }
        let (tx, rx) = watch::channel(false);
        *lock(&live.cancel) = tx;
        inflight.insert(id);
        Some((live, id, rx))
    }

    fn finish(self: &Arc<Self>, id: JobId, outcome: Outcome) {
        lock(&self.inflight).remove(&id);
        if let Some(part) = lock(&self.doomed_parts).remove(&id) {
            let _ = std::fs::remove_file(part);
        }
        if let Some(live) = self.find(id) {
            let mut scrub = false;
            {
                let mut job = lock(&live.job);
                job.done = live.done.load(Ordering::Relaxed);
                match outcome {
                    Outcome::Done(path) => {
                        job.state = JobState::Done { path: path.to_string_lossy().into_owned() };
                        job.final_path = Some(path);
                        // Saved headers are secrets: gone from memory and the row once the file is here.
                        scrub = !job.headers.is_empty();
                        job.headers.clear();
                    }
                    // A failed job keeps its headers so a retry or resume still works.
                    Outcome::Failed(reason) => job.state = JobState::Failed { reason },
                    Outcome::Paused => {
                        if is_active(&job.state) {
                            job.state = JobState::Paused;
                        }
                    }
                }
                let _ = self.store.save(&job);
                if matches!(job.state, JobState::Done { .. })
                    && let Some(run) = lock(&self.queues).get_mut(&job.queue_id).and_then(|rt| rt.run.as_mut())
                {
                    run.files += 1;
                    run.dirty = true;
                    run.bytes += job.total.unwrap_or(job.done);
                    let _ = self.store.update_run(run.id, run.files, run.bytes, None);
                }
            }
            if scrub {
                self.store.checkpoint();
            }
            self.hub.state_changed(id);
        }
        self.refresh();
    }

    /// Copies the live byte counters into the jobs that are transferring and saves them.
    /// Saves each active job's progress. The progress is read before the `.part` is synced, so every byte the
    /// saved plan counts is on disk even after a power cut, not just in the page cache. The save itself runs under
    /// the job lock, as before, so it can never overwrite a newer Done or Paused.
    fn flush_progress(&self) {
        let lives = lock(&self.jobs).to_vec();
        for live in &lives {
            let snapshot = {
                let job = lock(&live.job);
                if !is_active(&job.state) {
                    continue;
                }
                let mut snap = job.clone();
                snap.done = live.done.load(Ordering::Relaxed);
                snap
            };
            if let Ok(file) = std::fs::OpenOptions::new().write(true).open(&snapshot.part_path) {
                let _ = file.sync_data();
            }
            let job = lock(&live.job);
            if is_active(&job.state) {
                // A split since the snapshot only lowered ends; the older plan still covers every byte.
                let _ = self.store.save(&Job { state: job.state.clone(), ..snapshot });
            }
        }
    }

    /// Feeds the speed log: one sample per clean minute of unthrottled downloading. Runs every progress tick.
    fn sample_speed(&self) {
        let local = self.now();
        let (now, day) = (clock_secs(local), day_key(local));
        if self.pruned_day.swap(day, Ordering::Relaxed) != day {
            let _ = self.store.prune_samples(now - 60 * 86_400);
        }
        let lives = lock(&self.jobs).to_vec();
        let (mut total, mut any, mut limited) = (0, false, false);
        for live in &lives {
            let (id, running, queue) = {
                let job = lock(&live.job);
                (job.id, job.state == JobState::Running, job.queue_id)
            };
            if running {
                any = true;
                total += self.bytes_per_sec(id, true, live.done.load(Ordering::Relaxed));
                // A queue limiter also checks the global one through its parent.
                limited |= self.queue_limiter(queue).is_limited();
            }
        }
        let network = *lock(&self.network);
        if let Some(sample) = lock(&self.sampler).observe(now, total, any, limited, network) {
            let _ = self.store.add_sample(&sample);
        }
    }

    fn view_of(&self, live: &Live) -> JobView {
        let done = live.done.load(Ordering::Relaxed);
        let job = lock(&live.job);
        let bytes_per_sec = self.bytes_per_sec(job.id, job.state == JobState::Running, done);
        JobView {
            id: job.id,
            url: job.url.clone(),
            name: job.name.clone(),
            done,
            total: job.total,
            bytes_per_sec,
            resumable: job.resumable,
            state: job.state.clone(),
            connections: live.connections.load(Ordering::Relaxed),
            parts: {
                // Segments are appended by work stealing, so sort into file order for drawing.
                let mut parts: Vec<PartView> =
                    job.segments.iter().map(|s| PartView { start: s.start, end: s.end, done: s.done }).collect();
                parts.sort_by_key(|p| p.start);
                parts
            },
            dir: job.dir.as_ref().map(|d| d.to_string_lossy().into_owned()),
            queue_id: job.queue_id,
            waiting: if job.state == JobState::Queued { self.waiting_reason(job.queue_id) } else { None },
            verified: job.sha256.is_some() && matches!(job.state, JobState::Done { .. }),
            mirrors: job.mirrors.len() as u32,
            has_headers: !job.headers.is_empty(),
            link_expired: matches!(&job.state, JobState::Failed { reason } if reason.starts_with(download::LINK_EXPIRED)),
        }
    }

    /// Rate over the last sample window; the sample is refreshed at most every `SPEED_WINDOW`.
    fn bytes_per_sec(&self, id: JobId, running: bool, done: u64) -> u64 {
        let mut speed = lock(&self.speed);
        if !running {
            speed.remove(&id);
            return 0;
        }
        let now = Instant::now();
        match speed.get(&id).copied() {
            Some((at, _, rate)) if now.duration_since(at) < SPEED_WINDOW => rate,
            Some((at, then, _)) => {
                let secs = now.duration_since(at).as_secs_f64();
                let rate = (done.saturating_sub(then) as f64 / secs) as u64;
                speed.insert(id, (now, done, rate));
                rate
            }
            None => {
                speed.insert(id, (now, done, 0));
                0
            }
        }
    }
}


impl Scheduler {
    /// Replaces the clock that windows are read from, and re-checks every queue.
    pub fn set_clock(self: &Arc<Self>, clock: Clock) {
        *lock(&self.clock) = clock;
        self.refresh();
    }

    /// Re-checks every queue now; the 30 s timer calls this.
    pub fn tick(self: &Arc<Self>) {
        self.follow_best_time();
        self.refresh();
    }

    /// What the app last measured. Queues that need a condition hold until it is true.
    pub fn set_conditions(self: &Arc<Self>, wifi: bool, on_power: bool, idle: bool, network: NetworkKind) {
        *lock(&self.conditions) = (wifi, on_power, idle);
        *lock(&self.network) = network;
        self.refresh();
    }

    fn now(&self) -> DateTime {
        let clock = lock(&self.clock).clone();
        clock()
    }

    pub(crate) fn hub(&self) -> &EventHub {
        &self.hub
    }

    pub(crate) fn client(&self) -> &reqwest::Client {
        &self.client
    }

    pub(crate) fn store(&self) -> &Store {
        &self.store
    }

    /// Set while a speed test runs, so two never share the link.
    pub(crate) fn testing(&self) -> &AtomicBool {
        &self.testing
    }

    pub(crate) fn network(&self) -> NetworkKind {
        *lock(&self.network)
    }

    pub(crate) fn now_secs(&self) -> i64 {
        clock_secs(self.now())
    }

    pub(crate) fn any_running(&self) -> bool {
        lock(&self.jobs).iter().any(|live| lock(&live.job).state == JobState::Running)
    }

    pub fn queues(&self) -> Vec<QueueView> {
        let (now, cond, counts) = (self.now(), *lock(&self.conditions), self.counts());
        lock(&self.queues).values().map(|rt| view_of_queue(rt, &counts, cond, now)).collect()
    }

    pub fn queue_view(&self, id: u64) -> Option<QueueView> {
        let (now, cond, counts) = (self.now(), *lock(&self.conditions), self.counts());
        lock(&self.queues).get(&id).map(|rt| view_of_queue(rt, &counts, cond, now))
    }

    pub fn save_queue(self: &Arc<Self>, config: &QueueConfig) -> Result<u64, EngineError> {
        validate_queue(config, self.now())?;
        let _edit = lock(&self.queue_edit);
        let mut config = config.clone();
        // Editing the schedule of a following queue is the user taking over.
        if config.follow_best_time {
            let current = config.id.and_then(|id| lock(&self.queues).get(&id).map(|rt| rt.config.clone()));
            if current.is_some_and(|c| c.follow_best_time && c.schedule != config.schedule) {
                config.follow_best_time = false;
            }
        }
        // A following queue always has a Daily window; its conditions stay as the user set them.
        if let Some(s) = config.schedule.as_mut().filter(|_| config.follow_best_time) {
            s.repeat = Repeat::Daily;
        }
        // Switching Follow on moves the window now, not at tomorrow's refresh.
        let was_following = config.id.is_some_and(|id| lock(&self.queues).get(&id).is_some_and(|rt| rt.config.follow_best_time));
        if config.follow_best_time && config.id.is_some() && !was_following {
            let (start_min, end_min) = self.target_window();
            config.schedule = Some(followed_schedule(config.schedule.as_ref(), start_min, end_min));
        }
        self.write_queue(&config)
    }

    /// Stores `config` and applies it to the running state, whoever asked for it.
    fn write_queue(self: &Arc<Self>, config: &QueueConfig) -> Result<u64, EngineError> {
        let id = self.store.save_queue(config)?;
        let (now, config) = (self.now(), QueueConfig { id: Some(id), ..config.clone() });
        {
            let mut queues = lock(&self.queues);
            match queues.get_mut(&id) {
                Some(rt) => {
                    rt.limiter.set_rate(config.speed_limit);
                    if rt.config.schedule != config.schedule {
                        let fresh = QueueRt::new(config.clone(), rt.held, &self.limiter, now);
                        (rt.was_open, rt.opened_at, rt.was_in_window, rt.latched, rt.spent) = (fresh.was_open, fresh.opened_at, fresh.was_open, fresh.latched, false);
                    }
                    rt.config = config;
                }
                None => {
                    queues.insert(id, QueueRt::new(config, false, &self.limiter, now));
                }
            }
        }
        self.refresh();
        Ok(id)
    }

    /// Its jobs leave every queue. The Main queue (id 1) cannot be deleted.
    pub fn delete_queue(self: &Arc<Self>, id: u64) -> Result<(), EngineError> {
        if id == 1 {
            return self.store.delete_queue(id);
        }
        // Jobs move in memory first, so a progress flush in between cannot write the deleted id back.
        let lives = lock(&self.jobs).to_vec();
        for live in lives {
            let moved = {
                let mut job = lock(&live.job);
                let moved = job.queue_id == id;
                if moved {
                    job.queue_id = NO_QUEUE;
                }
                moved.then_some(job.id)
            };
            if let Some(job) = moved {
                self.hub.state_changed(job);
            }
        }
        let _one = lock(&self.best_queue);
        self.store.delete_queue(id)?;
        // Queue ids are reused, so a stale id would hand the next queue the Best time role.
        if self.store.setting(KEY_BEST_QUEUE)?.is_some_and(|v| v == id.to_string()) {
            self.store.set_setting(KEY_BEST_QUEUE, None)?;
        }
        lock(&self.queues).remove(&id);
        self.refresh();
        Ok(())
    }

    /// A running job moved to another queue keeps its old queue's speed limiter until it restarts.
    /// A running job moved into a closed queue goes back to Queued at once.
    /// `NO_QUEUE` takes the job out of every queue.
    pub fn move_to_queue(self: &Arc<Self>, id: JobId, queue: u64) {
        if queue != NO_QUEUE && !lock(&self.queues).contains_key(&queue) {
            return;
        }
        let Some(live) = self.find(id) else { return };
        {
            let mut job = lock(&live.job);
            job.queue_id = queue;
            let _ = self.store.save(&job);
        }
        self.hub.state_changed(id);
        self.refresh();
    }

    /// Holds the queue's jobs until Start queue, Run now or (on a scheduled queue) its next window.
    pub fn stop_queue(self: &Arc<Self>, id: u64) {
        {
            let mut queues = lock(&self.queues);
            let Some(rt) = queues.get_mut(&id) else { return };
            rt.held = true;
            rt.run_now = false;
            rt.latched = false;
            let _ = self.store.set_held(id, true);
            self.close_run(rt, RunOutcome::StoppedByUser);
        }
        self.refresh();
    }

    /// On an unscheduled queue: lifts the hold. On a scheduled one it is the same as Run now.
    pub fn start_queue(self: &Arc<Self>, id: u64) {
        let scheduled = lock(&self.queues).get(&id).map(|rt| rt.config.schedule.is_some());
        match scheduled {
            Some(true) => self.run_queue_now(id),
            Some(false) => self.open_queue(id, false),
            None => {}
        }
    }

    /// Opens the queue until its run finishes, whatever its window and conditions say.
    pub fn run_queue_now(self: &Arc<Self>, id: u64) {
        self.open_queue(id, true);
    }

    fn open_queue(self: &Arc<Self>, id: u64, run_now: bool) {
        let retry = {
            let mut queues = lock(&self.queues);
            let Some(rt) = queues.get_mut(&id) else { return };
            rt.held = false;
            rt.run_now = run_now;
            let _ = self.store.set_held(id, false);
            rt.config.retry_failed
        };
        if retry {
            self.retry_failed(id);
        }
        self.refresh();
    }

    fn retry_failed(&self, queue: u64) {
        let lives = lock(&self.jobs).to_vec();
        for live in lives {
            let id = {
                let mut job = lock(&live.job);
                if job.queue_id != queue || !matches!(job.state, JobState::Failed { .. }) {
                    continue;
                }
                job.state = JobState::Queued;
                let _ = self.store.save(&job);
                job.id
            };
            self.hub.state_changed(id);
        }
    }

    fn waiting_reason(&self, queue: u64) -> Option<String> {
        let (now, cond) = (self.now(), *lock(&self.conditions));
        let state = lock(&self.queues).get(&queue)?.gate(cond, now);
        match state {
            QueueState::Open => None,
            QueueState::WaitingForTime { .. } => Some("Waiting for schedule".to_owned()),
            QueueState::WaitingForCondition { missing } => Some(format!("Waiting for {}", missing.first().map_or("conditions", String::as_str))),
            QueueState::Stopped | QueueState::Off => Some("Queue stopped".to_owned()),
        }
    }

    /// Per queue: open now, and how many jobs it may run at once.
    fn queue_gates(&self) -> HashMap<u64, (bool, usize)> {
        let (now, cond, global) = (self.now(), *lock(&self.conditions), self.max_running.load(Ordering::Relaxed));
        let queues = lock(&self.queues);
        queues
            .iter()
            .map(|(id, rt)| {
                let cap = if rt.config.max_running == 0 { global } else { (rt.config.max_running as usize).min(global) };
                (*id, (rt.gate(cond, now) == QueueState::Open, cap))
            })
            .collect()
    }

    fn queue_limiter(&self, queue: u64) -> Arc<RateLimiter> {
        lock(&self.queues).get(&queue).map_or_else(|| Arc::clone(&self.limiter), |rt| Arc::clone(&rt.limiter))
    }

    fn counts(&self) -> HashMap<u64, Counts> {
        let lives = lock(&self.jobs).to_vec();
        let mut counts: HashMap<u64, Counts> = HashMap::new();
        for live in &lives {
            let job = lock(&live.job);
            let c = counts.entry(job.queue_id).or_default();
            match job.state {
                JobState::Queued => c.queued += 1,
                JobState::Running | JobState::Retrying { .. } | JobState::Verifying => c.running += 1,
                JobState::Paused => c.paused += 1,
                JobState::Done { .. } | JobState::Failed { .. } => {}
            }
            if !matches!(job.state, JobState::Done { .. }) {
                c.total_bytes += job.total.unwrap_or(0);
            }
        }
        counts
    }

    /// Applies window openings and closings, holds what a closed queue was running, starts what may start,
    /// ends finished runs and announces changed queues.
    fn refresh(self: &Arc<Self>) {
        if self.stopping.load(Ordering::Relaxed) {
            return;
        }
        let _one = lock(&self.refreshing);
        let (now, cond) = (self.now(), *lock(&self.conditions));
        let mut retry = Vec::new();
        {
            let counts = self.counts();
            let mut queues = lock(&self.queues);
            for (id, rt) in queues.iter_mut() {
                self.advance(*id, rt, now, &counts, &mut retry);
            }
        }
        for id in retry {
            self.retry_failed(id);
        }
        self.hold_closed(cond, now);
        self.pump();
        let counts = self.counts();
        let finished = self.end_runs(&counts);
        self.close_or_report_runs(cond, now);
        let mut changed = Vec::new();
        {
            let mut queues = lock(&self.queues);
            for (id, rt) in queues.iter_mut() {
                let view = view_of_queue(rt, &counts, cond, now);
                if rt.last_view.as_ref() != Some(&view) {
                    rt.last_view = Some(view);
                    changed.push(*id);
                }
            }
        }
        for id in changed {
            self.hub.queue_changed(id);
        }
        for id in finished {
            self.hub.queue_finished(id);
        }
    }

    /// Window edges. A window opening lifts Stop queue and retries failed jobs; a closing Once queue turns itself off.
    fn advance(&self, id: u64, rt: &mut QueueRt, now: DateTime, counts: &HashMap<u64, Counts>, retry: &mut Vec<u64>) {
        let Some(s) = rt.config.schedule.clone() else { return };
        let start = queue::open_start(&s, now);
        let raw = start.is_some();
        if raw && !rt.was_open && start != rt.opened_at {
            rt.opened_at = start;
            rt.latched = s.stop_min.is_none();
            rt.spent = false;
            if rt.held {
                rt.held = false;
                let _ = self.store.set_held(id, false);
            }
            if rt.config.retry_failed && rt.config.enabled {
                retry.push(id);
            }
        } else if !raw {
            rt.spent = false;
            // A window without a stop outlives midnight only while there is work left.
            if rt.latched && counts.get(&id).is_none_or(|c| c.queued + c.running == 0) {
                rt.latched = false;
            }
        }
        rt.was_open = raw;
        let in_window = rt.in_window(&s, now) || rt.run_now;
        if matches!(s.repeat, Repeat::Once { .. }) && rt.was_in_window && !in_window && rt.config.enabled {
            self.disable(rt);
        }
        rt.was_in_window = in_window;
    }

    fn disable(&self, rt: &mut QueueRt) {
        rt.config.enabled = false;
        let _ = self.store.save_queue(&rt.config);
    }

    /// Sends running jobs of queues that are no longer open back to Queued, keeping their progress.
    /// Verifying jobs finish: they cannot be cancelled.
    fn hold_closed(&self, cond: Conditions, now: DateTime) {
        let open: HashMap<u64, bool> = lock(&self.queues).iter().map(|(id, rt)| (*id, rt.gate(cond, now) == QueueState::Open)).collect();
        let lives = lock(&self.jobs).to_vec();
        for live in &lives {
            let held = {
                let mut job = lock(&live.job);
                if !is_active(&job.state) || open.get(&job.queue_id).copied().unwrap_or(true) {
                    continue;
                }
                lock(&live.cancel).send_replace(true);
                job.state = JobState::Queued;
                job.done = live.done.load(Ordering::Relaxed);
                let _ = self.store.save(&job);
                job.id
            };
            self.hub.state_changed(held);
        }
    }

    /// A queue whose run started a job and has nothing queued, running or paused left is finished.
    fn end_runs(&self, counts: &HashMap<u64, Counts>) -> Vec<u64> {
        let mut finished = Vec::new();
        let mut queues = lock(&self.queues);
        for (id, rt) in queues.iter_mut() {
            let left = counts.get(id).is_some_and(|c| c.queued + c.running + c.paused > 0);
            if !left && !rt.started_any {
                // Run now on an empty queue: nothing ran, so there is no finish, but the override ends.
                rt.run_now = false;
            }
            if !rt.started_any || left {
                continue;
            }
            rt.started_any = false;
            rt.run_now = false;
            rt.latched = false;
            if rt.config.schedule.as_ref().is_some_and(|s| s.stop_min.is_none()) {
                rt.spent = rt.was_open;
            }
            if matches!(rt.config.schedule.as_ref().map(|s| &s.repeat), Some(Repeat::Once { .. })) {
                self.disable(rt);
            }
            self.close_run(rt, RunOutcome::Finished);
            finished.push(*id);
        }
        finished
    }

    /// Ends the queue's open run; the next job to start opens a new one.
    fn close_run(&self, rt: &mut QueueRt, outcome: RunOutcome) {
        rt.started_any = false;
        if let Some(run) = rt.run.take() {
            let _ = self.store.update_run(run.id, run.files, run.bytes, Some((now_secs(), outcome)));
            self.hub.run_changed(run.id);
        }
    }

    /// A run whose queue closed with work left ends; a run still open reports its counts every `RUN_EMIT`.
    fn close_or_report_runs(&self, cond: Conditions, now: DateTime) {
        let mut queues = lock(&self.queues);
        for rt in queues.values_mut() {
            if rt.run.is_none() {
                continue;
            }
            match rt.gate(cond, now) {
                QueueState::WaitingForTime { .. } => self.close_run(rt, RunOutcome::WindowClosed),
                QueueState::Off => self.close_run(rt, RunOutcome::StoppedByUser),
                _ => {
                    if let Some(run) = rt.run.as_mut().filter(|r| r.dirty && r.last_emit.elapsed() >= RUN_EMIT) {
                        run.dirty = false;
                        run.last_emit = Instant::now();
                        self.hub.run_changed(run.id);
                    }
                }
            }
        }
    }

    pub fn queue_runs(&self, limit: u32) -> Vec<QueueRun> {
        self.store.runs(limit).unwrap_or_default()
    }

    pub fn run(&self, id: u64) -> Option<QueueRun> {
        self.store.run(id).ok().flatten()
    }
}

fn view_of_queue(rt: &QueueRt, counts: &HashMap<u64, Counts>, cond: Conditions, now: DateTime) -> QueueView {
    let c = counts.get(&rt.config.id.unwrap_or(0));
    QueueView {
        config: rt.config.clone(),
        state: rt.gate(cond, now),
        queued: c.map_or(0, |c| c.queued),
        running: c.map_or(0, |c| c.running),
        total_bytes: c.map_or(0, |c| c.total_bytes),
        next_run: rt.config.schedule.as_ref().filter(|_| rt.config.enabled).and_then(|s| queue::next_start(s, now)).map(unix_secs),
    }
}

/// The overall limit is not checked: `queue_gates` caps each queue at it, so lowering it never blocks a save.
fn validate_queue(config: &QueueConfig, now: DateTime) -> Result<(), EngineError> {
    let bad = |msg: &str| Err(EngineError::InvalidQueue { msg: msg.to_owned() });
    let Some(s) = &config.schedule else { return Ok(()) };
    if s.start_min >= 1440 || s.stop_min.is_some_and(|m| m >= 1440) {
        return bad("a start or stop time is not within a day");
    }
    match &s.repeat {
        Repeat::Days { mask } if mask & 0x7f == 0 => bad("pick at least one day"),
        Repeat::Once { date } => match date.parse::<jiff::civil::Date>() {
            Err(_) => bad("the date is not a valid day"),
            // A Once queue that is off may still be edited; an enabled one must have a window left.
            Ok(day) if config.enabled && queue::window_end(s, queue::at(day, s.start_min)).is_some_and(|end| end <= now) => bad("that time has already passed"),
            Ok(_) => Ok(()),
        },
        _ => Ok(()),
    }
}

/// R2 rejects a token for a moment after it is created.
fn token_not_ready(e: &EngineError) -> bool {
    e.to_string().contains("InvalidAccessKeyId") || e.to_string().contains("Unauthorized")
}

impl Scheduler {
    fn local_samples(&self) -> Result<Vec<(DateTime, u64)>, EngineError> {
        let since = self.now_secs() - SAMPLE_DAYS * 86_400;
        let tz = jiff::tz::TimeZone::system();
        Ok(self
            .store
            .samples_since(since)?
            .into_iter()
            .filter_map(|s| Some((jiff::Timestamp::from_second(s.at).ok()?.to_zoned_datetime(tz.clone()).datetime(), s.bps)))
            .collect())
    }

    pub fn stats(&self, days: u32) -> Result<crate::stats::Stats, EngineError> {
        let midnights = crate::stats::local_midnights(self.now().date(), days.clamp(1, 3650), &jiff::tz::TimeZone::system());
        let start = midnights.first().copied().unwrap_or_default();
        Ok(crate::stats::compute(&self.store.finished_since(start)?, &midnights, &self.store.samples_since(start)?))
    }

    pub fn best_time(&self) -> BestTime {
        speed::best_window(&self.local_samples().unwrap_or_default(), 4)
    }

    pub fn hourly_typical(&self) -> Vec<Option<u64>> {
        let local = self.local_samples().unwrap_or_default();
        (0..24).map(|h| speed::typical_bps_at(&local, h)).collect()
    }

    pub fn clear_speed_history(&self) {
        let _ = self.store.clear_samples();
    }

    /// The Best time queue if it already exists; never creates one.
    pub fn existing_best_time_queue(&self) -> Option<u64> {
        let stored = self.store.setting(KEY_BEST_QUEUE).ok()??.parse::<u64>().ok()?;
        lock(&self.queues).contains_key(&stored).then_some(stored)
    }

    /// The queue that follows the best time, made on first use. Found by its stored id, never its name.
    pub fn best_time_queue(self: &Arc<Self>) -> Result<u64, EngineError> {
        let _one = lock(&self.best_queue);
        let stored = self.store.setting(KEY_BEST_QUEUE)?.and_then(|v| v.parse::<u64>().ok());
        if let Some(id) = stored.filter(|id| lock(&self.queues).contains_key(id)) {
            return Ok(id);
        }
        let (start_min, end_min) = self.target_window();
        let schedule = speed::window_schedule(start_min, end_min);
        let id = self.save_queue(&QueueConfig {
            id: None,
            name: "Best time".into(),
            max_running: 0,
            speed_limit: 0,
            enabled: true,
            schedule: Some(schedule),
            retry_failed: true,
            wake: false,
            when_finished: queue::FinishAction::Nothing,
            follow_best_time: true,
        })?;
        self.store.set_setting(KEY_BEST_QUEUE, Some(&id.to_string()))?;
        Ok(id)
    }

    /// The best window, or 01:00-06:00 until there is enough data.
    fn target_window(&self) -> (u16, u16) {
        window_or_default(self.best_time())
    }

    /// Once per local date, moves every following queue to the current best window if it moved by 30 minutes.
    fn follow_best_time(self: &Arc<Self>) {
        let today = self.now().date().to_string();
        if self.store.setting(KEY_REFRESHED).ok().flatten().as_deref() == Some(today.as_str()) {
            return;
        }
        // A database error must not use up the day.
        let Ok(local) = self.local_samples() else { return };
        let _ = self.store.set_setting(KEY_REFRESHED, Some(&today));
        let (start_min, end_min) = window_or_default(speed::best_window(&local, 4));
        let following: Vec<QueueConfig> =
            lock(&self.queues).values().filter(|rt| rt.config.follow_best_time).map(|rt| rt.config.clone()).collect();
        for snapshot in following {
            if let Some(id) = self.follow_write(&snapshot, start_min, end_min) {
                self.hub.queue_changed(id);
            }
        }
    }

    /// Moves `snapshot`'s queue to the window if it moved by 30 minutes. It re-reads the queue under the edit lock
    /// and leaves it alone when the user took over or changed the schedule since the snapshot.
    fn follow_write(self: &Arc<Self>, snapshot: &QueueConfig, start_min: u16, end_min: u16) -> Option<u64> {
        let _edit = lock(&self.queue_edit);
        let current = lock(&self.queues).get(&snapshot.id?)?.config.clone();
        if !current.follow_best_time || current.schedule != snapshot.schedule {
            return None;
        }
        let schedule = match &current.schedule {
            Some(s) if !speed::window_moved(s, start_min, end_min) => return None,
            s => followed_schedule(s.as_ref(), start_min, end_min),
        };
        self.write_queue(&QueueConfig { schedule: Some(schedule), ..current }).ok()
    }

    pub fn speed_settings(&self) -> SpeedSettings {
        let get = |k: &str| self.store.setting(k).ok().flatten();
        SpeedSettings {
            auto_tests: get(KEY_AUTO).is_some_and(|v| v == "1"),
            night_until: get(KEY_NIGHT_UNTIL).and_then(|v| v.parse().ok()),
            night_prompt_answered: get(KEY_NIGHT_ANSWERED).is_some_and(|v| v == "1"),
        }
    }

    pub fn set_speed_settings(&self, s: SpeedSettings) {
        let flag = |on: bool| on.then_some("1");
        let _ = self.store.set_setting(KEY_AUTO, flag(s.auto_tests));
        let _ = self.store.set_setting(KEY_NIGHT_UNTIL, s.night_until.map(|t| t.to_string()).as_deref());
        let _ = self.store.set_setting(KEY_NIGHT_ANSWERED, flag(s.night_prompt_answered));
    }

    pub fn start_night_week(&self) {
        let s = SpeedSettings { night_until: Some(self.now_secs() + 7 * 86_400), night_prompt_answered: true, ..self.speed_settings() };
        self.set_speed_settings(s);
    }

    #[doc(hidden)]
    pub fn set_auto_test_plan(&self, at: Vec<i64>) {
        *lock(&self.auto_plan) = AutoPlan { made_for: None, at, pinned: true, checked: None };
    }

    /// True when this local minute is one a test was planned for. Planned minutes that passed are dropped, not caught up.
    pub(crate) fn auto_test_due(&self) -> bool {
        if self.stopping.load(Ordering::Relaxed) {
            return false;
        }
        let (now, secs) = (self.now(), self.now_secs());
        let settings = self.speed_settings();
        let (night, auto) = (settings.night_until.is_some_and(|t| t > secs), settings.auto_tests);
        let mut plan = lock(&self.auto_plan);
        let made_for = (now.date().to_string(), night, auto);
        if !plan.pinned && plan.made_for.as_ref() != Some(&made_for) {
            let slots = speed::test_slots(night, auto);
            let seed = day_key(now) as u64 ^ (u64::from(night) << 40) ^ (u64::from(auto) << 41);
            plan.at = speed::pick_minutes(seed, &slots).into_iter().map(|m| unix_secs(queue::at(now.date(), m))).collect();
            plan.made_for = Some(made_for);
        }
        // Minutes since the last look count, so a late tick does not skip one; older ones are gone.
        let minute = secs.div_euclid(60);
        let from = plan.checked.filter(|c| *c <= minute).unwrap_or(minute - 1).max(minute - 3);
        plan.checked = Some(minute);
        let due = plan.at.iter().any(|at| (from + 1..=minute).contains(&at.div_euclid(60)));
        plan.at.retain(|at| at.div_euclid(60) > minute);
        due
    }
}

fn window_or_default(best: BestTime) -> (u16, u16) {
    match best {
        BestTime::Window { start_min, end_min, .. } => (start_min, end_min),
        BestTime::NotEnoughData { .. } => (60, 360),
    }
}

/// The window as a Daily schedule that keeps the other conditions of `current`.
fn followed_schedule(current: Option<&queue::QueueSchedule>, start_min: u16, end_min: u16) -> queue::QueueSchedule {
    match current {
        Some(s) => queue::QueueSchedule { repeat: Repeat::Daily, start_min, stop_min: Some(end_min), ..s.clone() },
        None => speed::window_schedule(start_min, end_min),
    }
}

#[cfg(test)]
mod clock_tests {
    use super::*;
    use jiff::civil::date;

    #[test]
    fn sample_time_follows_the_injected_clock() {
        let dt = date(2026, 11, 25).at(10, 0, 0, 0);
        assert_eq!(clock_secs(dt), unix_secs(dt));
        assert_eq!(clock_secs(dt) - clock_secs(date(2026, 11, 25).at(9, 0, 0, 0)), 3600);
        assert_ne!(day_key(dt), day_key(date(2026, 11, 26).at(0, 0, 0, 0)));
        assert_eq!(day_key(dt), day_key(date(2026, 11, 25).at(23, 59, 0, 0)));
    }
}
