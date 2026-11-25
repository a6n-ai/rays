//! Queue order, concurrency limit, and job lifecycle. See design doc "Engine API".
use crate::download::{self, SignUrl};
use crate::events::EventHub;
use crate::hf;
use crate::limit::RateLimiter;
use crate::names;
use crate::cloud;
use crate::s3::{self, BucketConfig, Listing, Secrets, Signer};
use crate::store::Store;
use crate::types::{PartView, AddResult, EngineError, HostView, Job, JobId, JobState, JobView, Live, Outcome, now_secs};
use std::collections::{HashMap, HashSet};
use std::io;
use std::path::{Component, Path, PathBuf};
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
}

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
            replace_existing: AtomicBool::new(false),
            trash: Mutex::new(download::trash_file),
            limiter: Arc::new(RateLimiter::new(speed_limit)),
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
        });
        let weak = Arc::downgrade(&sched);
        sched.rt.spawn(async move {
            let mut tick = tokio::time::interval(PROGRESS_INTERVAL);
            loop {
                tick.tick().await;
                match weak.upgrade() {
                    // It fsyncs, so it runs on the blocking pool, not on one of the two runtime threads.
                    Some(s) => {
                        let _ = tokio::task::spawn_blocking(move || s.flush_progress()).await;
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
        self.pump();
    }

    /// New downloads (and the final rename of jobs started after this call) use `dir`.
    pub fn set_downloads_dir(&self, dir: PathBuf) {
        *lock(&self.dir) = dir;
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
        self.add_to(urls, None, vec![None; n])
    }

    /// Like `add`, saving into `dir` (None: the downloads dir). `fixed_names[i]` names job `i` and keeps the
    /// server's Content-Disposition from renaming it.
    pub fn add_to(self: &Arc<Self>, urls: Vec<String>, dir: Option<PathBuf>, fixed_names: Vec<Option<String>>) -> Vec<AddResult> {
        if dir.as_ref().is_some_and(|d| !is_plain_abs(d)) {
            return urls
                .into_iter()
                .map(|url| AddResult { url, id: None, error: Some("destination must be an absolute path with no ..".to_owned()) })
                .collect();
        }
        if !fixed_names.is_empty() && fixed_names.len() != urls.len() {
            return urls.into_iter().map(|url| AddResult { url, id: None, error: Some("names must match urls".to_owned()) }).collect();
        }
        let mut fixed = fixed_names.into_iter();
        let results = urls.into_iter().map(|url| self.add_one(url, dir.clone(), fixed.next().flatten(), None)).collect();
        self.pump();
        results
    }

    /// Queues each file of a Hugging Face commit as `dest_dir/<its repo path>`, with its SHA-256 when one is
    /// published. A file already there with the same size is skipped; the rest follow the same-name setting.
    pub fn add_hf(self: &Arc<Self>, repo: &str, sha: &str, files: Vec<hf::HfFile>, dest_dir: &Path) -> Vec<hf::HfAdd> {
        let results = files
            .into_iter()
            .map(|file| {
                let status = self.add_hf_file(repo, sha, dest_dir, &file);
                hf::HfAdd { path: file.path, status }
            })
            .collect();
        self.pump();
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

    fn add_hf_file(self: &Arc<Self>, repo: &str, sha: &str, dest_dir: &Path, file: &hf::HfFile) -> hf::HfAddStatus {
        let rejected = |error: &str| hf::HfAddStatus::Rejected { error: error.to_owned() };
        if !is_plain_abs(dest_dir) {
            return rejected("destination must be an absolute path with no ..");
        }
        let Some((parent, name)) = hf::hf_target(dest_dir, &file.path) else {
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
            self.resume(id);
            return hf::HfAddStatus::Added { id };
        }
        let res = self.add_one(url, Some(parent), Some(name), file.sha256.clone());
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

    fn add_one(&self, url: String, dir: Option<PathBuf>, fixed_name: Option<String>, sha256: Option<String>) -> AddResult {
        if let Err(error) = self.check_url(&url) {
            return AddResult { url, id: None, error: Some(error) };
        }
        if fixed_name.as_deref().is_some_and(|n| !valid_file_name(n)) {
            return AddResult { url, id: None, error: Some("file name must be one path component".to_owned()) };
        }
        match self.insert_job(&url, dir, fixed_name, sha256) {
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

    fn insert_job(&self, url: &str, dir: Option<PathBuf>, fixed_name: Option<String>, sha256: Option<String>) -> Result<JobId, EngineError> {
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
            let limiter = Arc::clone(&self.limiter);
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

/// R2 rejects a token for a moment after it is created.
fn token_not_ready(e: &EngineError) -> bool {
    e.to_string().contains("InvalidAccessKeyId") || e.to_string().contains("Unauthorized")
}
