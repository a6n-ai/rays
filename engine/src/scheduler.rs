//! Queue order, concurrency limit, and job lifecycle. See design doc "Engine API".
use crate::download::{self, SignUrl};
use crate::events::EventHub;
use crate::limit::RateLimiter;
use crate::names;
use crate::s3::{self, BucketConfig, Listing, Secrets, Signer};
use crate::store::Store;
use crate::types::{PartView, AddResult, EngineError, HostView, Job, JobId, JobState, JobView, Live, Outcome, now_secs};
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, AtomicBool, AtomicI64, AtomicU64, Ordering, AtomicU32};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};
use tokio::sync::watch;

const PROGRESS_INTERVAL: Duration = Duration::from_secs(2);
const SPEED_WINDOW: Duration = Duration::from_millis(500);

/// More than this many connections to one server tends to get an IP throttled or blocked.
pub const MAX_CONNECTIONS: u32 = 16;

pub struct Scheduler {
    rt: tokio::runtime::Handle,
    store: Arc<Store>,
    hub: Arc<EventHub>,
    dir: Mutex<PathBuf>,
    max_running: AtomicUsize,
    /// Connections per file for downloads started from now on.
    connections: AtomicU32,
    /// One bucket shared by every transfer, so the cap is global.
    limiter: Arc<RateLimiter>,
    client: reqwest::Client,
    /// Secret keys of S3 buckets, by bucket name.
    secrets: Arc<dyn Secrets>,
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
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

fn is_active(state: &JobState) -> bool {
    matches!(state, JobState::Running | JobState::Retrying { .. })
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
    ) -> Result<Arc<Scheduler>, EngineError> {
        let loaded = store.load_all()?;
        let next_position = loaded.iter().map(|j| j.position).max().map_or(0, |p| p + 1);
        let lives = loaded
            .into_iter()
            .map(|job| {
                Arc::new(Live {
                    done: AtomicU64::new(job.done),
                    job: Mutex::new(job),
                    connections: AtomicU32::new(0),
                    cancel: Mutex::new(watch::channel(false).0),
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
        let sched = Arc::new(Scheduler {
            rt,
            store,
            hub,
            dir: Mutex::new(downloads_dir),
            max_running: AtomicUsize::new((max_running as usize).max(1)),
            connections: AtomicU32::new(connections.clamp(1, MAX_CONNECTIONS)),
            limiter: Arc::new(RateLimiter::new(speed_limit)),
            client,
            secrets,
            jobs: Mutex::new(lives),
            speed: Mutex::new(HashMap::new()),
            inflight: Mutex::new(HashSet::new()),
            doomed_parts: Mutex::new(HashMap::new()),
            next_position: AtomicI64::new(next_position),
            stopping: AtomicBool::new(false),
        });
        let weak = Arc::downgrade(&sched);
        sched.rt.spawn(async move {
            let mut tick = tokio::time::interval(PROGRESS_INTERVAL);
            loop {
                tick.tick().await;
                match weak.upgrade() {
                    Some(s) => s.flush_progress(),
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
        self.pump();
    }

    /// New downloads (and the final rename of jobs started after this call) use `dir`.
    pub fn set_downloads_dir(&self, dir: PathBuf) {
        *lock(&self.dir) = dir;
    }

    pub fn set_connections(&self, n: u32) {
        self.connections.store(n.clamp(1, MAX_CONNECTIONS), Ordering::Relaxed);
    }

    pub fn difficult_hosts(&self) -> Vec<HostView> {
        self.store.hosts().unwrap_or_default()
    }

    pub fn forget_host(&self, host: &str) {
        let _ = self.store.forget_host(host);
    }

    /// Validates http/https, creates Queued jobs, starts as many as the limit allows.
    pub fn add(self: &Arc<Self>, urls: Vec<String>) -> Vec<AddResult> {
        let results = urls.into_iter().map(|url| self.add_one(url)).collect();
        self.pump();
        results
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
            self.pump();
        }
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
        self.pump();
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

    /// Pauses every running job and saves all jobs.
    pub fn shutdown(&self) {
        self.stopping.store(true, Ordering::Relaxed);
        let lives = lock(&self.jobs).to_vec();
        for live in &lives {
            let mut job = lock(&live.job);
            if is_active(&job.state) {
                lock(&live.cancel).send_replace(true);
                job.state = JobState::Paused;
            }
            job.done = live.done.load(Ordering::Relaxed);
            let _ = self.store.save(&job);
        }
    }

    fn add_one(&self, url: String) -> AddResult {
        if let Err(error) = self.check_url(&url) {
            return AddResult { url, id: None, error: Some(error) };
        }
        match self.insert_job(&url) {
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

    fn insert_job(&self, url: &str) -> Result<JobId, EngineError> {
        let now = now_secs();
        let position = self.next_position.fetch_add(1, Ordering::Relaxed);
        let mut job = Job {
            id: 0,
            url: url.to_owned(),
            name: names::from_url(url),
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
        };
        let id = self.store.insert(&mut job)?;
        job.part_path = names::part_path(&lock(&self.dir), &job.name, id);
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
        if cfg.access_key_id.is_empty() || secret.is_empty() {
            return Err(invalid("access key ID and secret are required"));
        }
        Signer::new(&cfg, &secret)?.list(&self.client, "", None).await?;
        self.secrets.set(&cfg.name, &secret)?;
        self.store.save_bucket(&cfg)
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

    fn bucket(&self, name: &str) -> Result<BucketConfig, String> {
        self.buckets().into_iter().find(|b| b.name == name).ok_or_else(|| format!("no bucket named {name} in Rays"))
    }

    fn signer(&self, name: &str) -> Result<Signer, String> {
        let cfg = self.bucket(name)?;
        let secret = self.secrets.get(name).ok_or_else(|| format!("no secret key saved for bucket {name}"))?;
        Signer::new(&cfg, &secret).map_err(|e| e.to_string())
    }

    /// `None` for web links; for an `s3://` link, a function that signs a fresh GET each time it is called.
    fn sign_for(&self, url: &str) -> Result<Option<SignUrl>, String> {
        let Some((bucket, key)) = s3::parse_link(url) else {
            return Ok(None);
        };
        let signer = self.signer(&bucket)?;
        Ok(Some(Arc::new(move || signer.get(&key))))
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
            let limiter = Arc::clone(&self.limiter);
            let store = Arc::clone(&self.store);
            let url = lock(&live.job).url.clone();
            let sign = self.sign_for(&url);
            self.rt.spawn(async move {
                let outcome = match sign {
                    Ok(sign) => download::run(live, client, &dir, hub, rx, connections, 1, limiter, Some(store), sign).await,
                    Err(reason) => Outcome::Failed(reason),
                };
                sched.finish(id, outcome);
            });
        }
    }

    /// Picks the first Queued job and claims a slot for it, all under the locks so two pumps cannot pick the same job.
    fn start_next(&self) -> Option<(Arc<Live>, JobId, watch::Receiver<bool>)> {
        let jobs = lock(&self.jobs);
        let mut inflight = lock(&self.inflight);
        if inflight.len() >= self.max_running.load(Ordering::Relaxed) {
            return None;
        }
        let live = Arc::clone(jobs.iter().find(|l| {
            let job = lock(&l.job);
            job.state == JobState::Queued && !inflight.contains(&job.id)
        })?);
        let id = {
            let mut job = lock(&live.job);
            job.state = JobState::Running;
            job.id
        };
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
            {
                let mut job = lock(&live.job);
                job.done = live.done.load(Ordering::Relaxed);
                match outcome {
                    Outcome::Done(path) => {
                        job.state = JobState::Done { path: path.to_string_lossy().into_owned() };
                        job.final_path = Some(path);
                    }
                    Outcome::Failed(reason) => job.state = JobState::Failed { reason },
                    Outcome::Paused => {
                        if is_active(&job.state) {
                            job.state = JobState::Paused;
                        }
                    }
                }
                let _ = self.store.save(&job);
            }
            self.hub.state_changed(id);
        }
        self.pump();
    }

    /// Copies the live byte counters into the jobs that are transferring and saves them.
    fn flush_progress(&self) {
        let lives = lock(&self.jobs).to_vec();
        for live in &lives {
            let mut job = lock(&live.job);
            if is_active(&job.state) {
                job.done = live.done.load(Ordering::Relaxed);
                let _ = self.store.save(&job);
            }
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
