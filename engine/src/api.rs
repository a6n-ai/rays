//! UniFFI-exported `Engine` object: owns the tokio runtime and wires the modules together.
use crate::events::EventHub;
use crate::hf::{self, HfAdd, HfFile, HfManifest, HfModel, HfRepo, VerifyResult, VerifyStatus};
use crate::ipc;
use crate::s3::{self, BucketConfig, Keychain, Listing, ProviderPreset};
use crate::scheduler::Scheduler;
use crate::speed::{BestTime, NetworkKind, SpeedSample, SpeedSettings};
use crate::speedtest::{self, SpeedTestResult};
use crate::store::Store;
use crate::queue::QueueConfig;
use crate::types::{AddResult, EngineConfig, EngineError, HostView, JobEvent, JobId, JobView, QueueRun, QueueView};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

#[derive(uniffi::Object)]
pub struct Engine {
    rt: tokio::runtime::Runtime,
    sched: Arc<Scheduler>,
    hub: Arc<EventHub>,
    socket_path: PathBuf,
    /// Speed test server and duration in ms; tests point these at a local server.
    speed_test: Arc<Mutex<(String, u64)>>,
    /// The running speed test's stop flag; each run has its own, so a cancel can't be erased by a later start.
    cancel_test: Mutex<Option<Arc<AtomicBool>>>,
}

#[uniffi::export]
impl Engine {
    /// Opens the DB, restores jobs as Paused, binds the socket, starts the accept loop.
    #[uniffi::constructor]
    pub fn new(config: EngineConfig) -> Result<Arc<Engine>, EngineError> {
        let rt = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .thread_name("dl-engine")
            .build()?;
        let store = Arc::new(Store::open(Path::new(&config.data_dir))?);
        let hub = Arc::new(EventHub::new());
        let hf_base = config.hf_base.unwrap_or_else(|| "https://huggingface.co".into()).trim_end_matches('/').to_owned();
        let sched = Scheduler::new(
            rt.handle().clone(),
            store,
            Arc::clone(&hub),
            PathBuf::from(&config.downloads_dir),
            config.max_running,
            config.connections.max(1),
            config.speed_limit,
            Arc::new(Keychain(s3::KEYCHAIN_SERVICE)),
            Arc::new(Keychain(hf::KEYCHAIN_SERVICE)),
            hf_base,
        )?;
        let warm = Arc::clone(&sched);
        rt.spawn_blocking(move || warm.warm_hf_token());
        let socket_path = PathBuf::from(&config.socket_path);
        {
            let _g = rt.enter();
            let listener = ipc::bind(&socket_path)?;
            rt.spawn(ipc::serve(listener, Arc::clone(&sched)));
        }
        let speed_test = Arc::new(Mutex::new((String::from(speedtest::DEFAULT_BASE), speedtest::DEFAULT_MS)));
        let (weak, cfg) = (Arc::downgrade(&sched), Arc::clone(&speed_test));
        rt.spawn(async move {
            let minute = std::time::Duration::from_secs(60);
            let mut tick = tokio::time::interval_at(tokio::time::Instant::now() + minute, minute);
            loop {
                tick.tick().await;
                let Some(sched) = weak.upgrade() else { break };
                let (base, ms) = cfg.lock().unwrap_or_else(|e| e.into_inner()).clone();
                speedtest::auto(&sched, &base, ms).await;
            }
        });
        Ok(Arc::new(Engine { rt, sched, hub, socket_path, speed_test, cancel_test: Mutex::default() }))
    }

    pub fn add(&self, urls: Vec<String>) -> Vec<AddResult> {
        self.sched.add(urls)
    }

    pub fn add_to(&self, urls: Vec<String>, dir: Option<String>, names: Vec<Option<String>>, queue: Option<u64>) -> Vec<AddResult> {
        self.sched.add_to(urls, dir.map(PathBuf::from), names, queue)
    }

    /// `add_to` with an expected SHA-256 per url (empty list: none), checked after the download.
    pub fn add_with(&self, urls: Vec<String>, dir: Option<String>, names: Vec<Option<String>>, sha256s: Vec<Option<String>>, mirrors: Vec<Vec<String>>, queue: Option<u64>) -> Vec<AddResult> {
        self.sched.add_with(urls, dir.map(PathBuf::from), names, sha256s, mirrors, queue)
    }

    pub fn queues(&self) -> Vec<QueueView> {
        self.sched.queues()
    }

    pub fn save_queue(&self, config: QueueConfig) -> Result<u64, EngineError> {
        self.sched.save_queue(&config)
    }

    pub fn delete_queue(&self, id: u64) -> Result<(), EngineError> {
        self.sched.delete_queue(id)
    }

    pub fn move_to_queue(&self, job: JobId, queue: u64) {
        self.sched.move_to_queue(job, queue);
    }

    /// Queue runs, newest first.
    pub fn queue_runs(&self, limit: u32) -> Vec<QueueRun> {
        self.sched.queue_runs(limit)
    }

    pub fn stop_queue(&self, id: u64) {
        self.sched.stop_queue(id);
    }

    pub fn start_queue(&self, id: u64) {
        self.sched.start_queue(id);
    }

    pub fn run_queue_now(&self, id: u64) {
        self.sched.run_queue_now(id);
    }

    /// What the app measured: connected over Wi-Fi, on power, idle for a while.
    pub fn set_conditions(&self, wifi: bool, on_power: bool, idle: bool, network: NetworkKind) {
        self.sched.set_conditions(wifi, on_power, idle, network);
    }

    /// Measures download speed against the speed test server. Refuses on a metered link unless `force`.
    pub async fn run_speed_test(&self, force: bool) -> Result<SpeedTestResult, EngineError> {
        let (base, ms) = self.speed_test.lock().unwrap_or_else(|e| e.into_inner()).clone();
        let sched = Arc::clone(&self.sched);
        let cancel = Arc::new(AtomicBool::new(false));
        // A second call is refused by the engine; it must not take over the running test's cancel flag.
        self.cancel_test.lock().unwrap_or_else(|e| e.into_inner()).get_or_insert_with(|| Arc::clone(&cancel));
        let flag = Arc::clone(&cancel);
        let result = self.rt.spawn(async move { speedtest::run(&sched, &base, ms, force, &flag).await }).await.map_err(join_error)?;
        let mut current = self.cancel_test.lock().unwrap_or_else(|e| e.into_inner());
        if current.as_ref().is_some_and(|c| Arc::ptr_eq(c, &cancel)) {
            *current = None;
        }
        result
    }

    /// Stops a running speed test; it returns "Speed test stopped" and saves nothing.
    pub fn cancel_speed_test(&self) {
        if let Some(flag) = self.cancel_test.lock().unwrap_or_else(|e| e.into_inner()).as_ref() {
            flag.store(true, Ordering::Relaxed);
        }
    }

    /// Saved speed samples, newest first.
    pub fn speed_history(&self, limit: u32) -> Vec<SpeedSample> {
        self.sched.store().samples_newest(limit).unwrap_or_default()
    }

    /// The newest saved test result.
    pub fn last_speed_test(&self) -> Option<SpeedTestResult> {
        speedtest::last(&self.sched)
    }

    /// The fastest 4 hours of the last 28 days, once there is enough data.
    pub fn best_time(&self) -> BestTime {
        self.sched.best_time()
    }

    /// Typical speed for each local hour of the day over the last 28 days.
    pub fn hourly_typical(&self) -> Vec<Option<u64>> {
        self.sched.hourly_typical()
    }

    /// The Best time queue, created on first use.
    pub fn best_time_queue(&self) -> Result<u64, EngineError> {
        self.sched.best_time_queue()
    }

    /// The Best time queue if it exists; unlike `best_time_queue` it never creates one.
    pub fn best_time_queue_id(&self) -> Option<u64> {
        self.sched.existing_best_time_queue()
    }

    pub fn speed_settings(&self) -> SpeedSettings {
        self.sched.speed_settings()
    }

    pub fn set_speed_settings(&self, s: SpeedSettings) {
        self.sched.set_speed_settings(s);
    }

    /// Automatic night tests for 7 days; also records that the prompt was answered.
    pub fn start_night_week(&self) {
        self.sched.start_night_week();
    }

    pub fn clear_speed_history(&self) {
        self.sched.clear_speed_history();
    }

    #[doc(hidden)]
    pub fn set_auto_test_plan(&self, at: Vec<i64>) {
        self.sched.set_auto_test_plan(at);
    }

    #[doc(hidden)]
    pub fn set_speed_test_base(&self, base: String) {
        self.speed_test.lock().unwrap_or_else(|e| e.into_inner()).0 = base;
    }

    #[doc(hidden)]
    pub fn set_speed_test_duration(&self, ms: u64) {
        self.speed_test.lock().unwrap_or_else(|e| e.into_inner()).1 = ms;
    }

    pub fn pause(&self, id: JobId) {
        self.sched.pause(id);
    }

    pub fn resume(&self, id: JobId) {
        self.sched.resume(id);
    }

    /// Gives a paused or failed job a new link and queues it; see `Scheduler::relink`.
    pub async fn relink(&self, id: JobId, url: String, restart: bool) -> Result<(), EngineError> {
        let sched = Arc::clone(&self.sched);
        self.rt.spawn(async move { sched.relink(id, &url, restart).await }).await.map_err(join_error)?
    }
    /// Files linked from a web page; fails with "That link is a file, not a page" when the link is a file.
    pub async fn grab_links(&self, page_url: String) -> Result<Vec<crate::grab::GrabbedLink>, EngineError> {
        let sched = Arc::clone(&self.sched);
        self.rt.spawn(async move { sched.grab_links(&page_url).await }).await.map_err(join_error)?
    }

    pub fn remove(&self, id: JobId, delete_partial: bool) {
        self.sched.remove(id, delete_partial);
    }

    /// Bytes per second across all downloads; 0 means unlimited.
    pub fn set_speed_limit(&self, bytes_per_sec: u64) {
        self.sched.set_speed_limit(bytes_per_sec);
    }

    /// Connections per file (1..=16) for downloads started after this call.
    /// Downloads running at once (1..=10); applies immediately.
    pub fn set_max_running(&self, n: u32) {
        self.sched.set_max_running(n);
    }

    /// Folder for downloads added after this call; created if missing.
    pub fn set_downloads_dir(&self, path: String) -> Result<(), EngineError> {
        std::fs::create_dir_all(&path)?;
        self.sched.set_downloads_dir(std::path::PathBuf::from(path));
        Ok(())
    }

    pub fn set_connections(&self, n: u32) {
        self.sched.set_connections(n);
    }
    /// Downloads started after this call replace a same-name file (moved to the Trash) instead of keeping both.
    pub fn set_replace_existing(&self, on: bool) {
        self.sched.set_replace_existing(on);
    }

    pub fn snapshot(&self) -> Vec<JobView> {
        self.sched.views()
    }

    /// Servers the engine currently limits to fewer connections, newest first.
    pub fn difficult_hosts(&self) -> Vec<HostView> {
        self.sched.difficult_hosts()
    }

    /// Lifts the remembered limit for `host` so the next download tries the full connection count.
    pub fn forget_host(&self, host: String) {
        self.sched.forget_host(&host.to_ascii_lowercase());
    }

    /// Waits for changes, returns Upsert for each changed job and Removed for deleted ones.
    pub async fn next_events(&self) -> Vec<JobEvent> {
        // Runs on our runtime: the host's executor only awaits the JoinHandle.
        let hub = Arc::clone(&self.hub);
        let changes = match self.rt.spawn(async move { hub.wait().await }).await {
            Ok(c) => c,
            Err(_) => return vec![],
        };
        let mut events: Vec<JobEvent> = changes
            .changed
            .into_iter()
            .filter_map(|id| self.sched.view(id))
            .map(|job| JobEvent::Upsert { job })
            .collect();
        events.extend(changes.removed.into_iter().map(|id| JobEvent::Removed { id }));
        events.extend(changes.queues.into_iter().filter_map(|id| self.sched.queue_view(id)).map(|queue| JobEvent::QueueChanged { queue }));
        events.extend(changes.finished.into_iter().map(|id| JobEvent::QueueFinished { id }));
        events.extend(changes.runs.into_iter().filter_map(|id| self.sched.run(id)).map(|run| JobEvent::RunChanged { run }));
        events.extend(changes.speed);
        events
    }

    /// Cloud provider presets for the bucket form, ending with Generic S3.
    pub fn providers(&self) -> Vec<ProviderPreset> {
        s3::providers()
    }

    /// Fills a preset's endpoint from its region and extra field (for example an R2 account ID).
    pub fn provider_endpoint(&self, provider: String, region: String, field: String) -> Result<String, EngineError> {
        s3::endpoint_for(&provider, &region, &field)
    }

    /// Checks the endpoint and keys with one listing, then saves the bucket; the secret goes to the Keychain.
    pub async fn add_bucket(&self, config: BucketConfig, secret: String) -> Result<(), EngineError> {
        let sched = Arc::clone(&self.sched);
        self.rt.spawn(async move { sched.add_bucket(config, secret).await }).await.map_err(join_error)?
    }

    /// Profiles the AWS CLI knows on this Mac, for linking buckets without typing keys.
    pub fn aws_profiles(&self) -> Vec<String> {
        crate::cloud::aws_profiles()
    }

    /// The profile's buckets with their regions; runs the AWS CLI, so it is off the caller's thread.
    pub async fn aws_buckets(&self, profile: String) -> Result<Vec<crate::cloud::AwsBucket>, EngineError> {
        self.rt
            .spawn_blocking(move || crate::cloud::aws_buckets(&profile))
            .await
            .map_err(join_error)?
            .map_err(|msg| EngineError::InvalidUrl { msg })
    }

    /// The account the `cf` command is logged in to, with its R2 buckets.
    pub async fn cloudflare_account(&self) -> Result<crate::cloud::CfAccount, EngineError> {
        self.rt
            .spawn_blocking(crate::cloud::cf_account)
            .await
            .map_err(join_error)?
            .map_err(|msg| EngineError::InvalidUrl { msg })
    }

    /// Adds an R2 bucket from the `cf` login; the first one creates a read-only R2 token.
    pub async fn add_cloudflare_bucket(&self, account_id: String, name: String) -> Result<(), EngineError> {
        let sched = Arc::clone(&self.sched);
        self.rt.spawn(async move { sched.add_cloudflare_bucket(account_id, name).await }).await.map_err(join_error)?
    }

    pub fn remove_bucket(&self, name: String) -> Result<(), EngineError> {
        self.sched.remove_bucket(&name)
    }

    pub fn buckets(&self) -> Vec<BucketConfig> {
        self.sched.buckets()
    }

    /// One level of `prefix` in `bucket`; pass `next_token` back for the next page.
    pub async fn list_bucket(&self, bucket: String, prefix: String, token: Option<String>) -> Result<Listing, EngineError> {
        let sched = Arc::clone(&self.sched);
        self.rt.spawn(async move { sched.list_bucket(&bucket, &prefix, token).await }).await.map_err(join_error)?
    }

    /// Models matching `query`, most downloaded first. Sends the saved token, so gated repos list.
    pub async fn hf_search(&self, query: String) -> Result<Vec<HfModel>, EngineError> {
        let sched = Arc::clone(&self.sched);
        self.rt.spawn(async move { sched.hf_search(&query).await }).await.map_err(join_error)?
    }

    /// One model's commit and files, with the LFS sha256 of each big file. `repo` is `org/name`.
    pub async fn hf_model(&self, repo: String) -> Result<HfRepo, EngineError> {
        let sched = Arc::clone(&self.sched);
        self.rt.spawn(async move { sched.hf_model(&repo).await }).await.map_err(join_error)?
    }

    /// Queues a Hugging Face commit's files under `dest_dir`, one result per file, in order.
    pub fn add_hf(&self, repo: String, sha: String, files: Vec<HfFile>, dest_dir: String, queue: Option<u64>) -> Vec<HfAdd> {
        self.sched.add_hf(&repo, &sha, files, Path::new(&dest_dir), queue)
    }
    /// The `.rays-model.json` that `add_hf` wrote in `dir`, or None.
    pub fn read_model_manifest(&self, dir: String) -> Option<HfManifest> {
        hf::read_manifest(Path::new(&dir))
    }
    /// Checks files under `dir` offline. Hashing runs on the blocking pool, two files at a time.
    pub async fn verify_files(&self, dir: String, files: Vec<HfFile>) -> Vec<VerifyResult> {
        let missing = files.iter().map(|f| VerifyResult { path: f.path.clone(), status: VerifyStatus::Missing }).collect();
        self.rt.spawn(async move { hf::verify_files(Path::new(&dir), files).await }).await.unwrap_or(missing)
    }

    /// Saves the Hugging Face token in the Keychain; `None` deletes it.
    pub fn set_hf_token(&self, token: Option<String>) -> Result<(), EngineError> {
        self.sched.set_hf_token(token.as_deref())
    }

    pub fn has_hf_token(&self) -> bool {
        self.sched.has_hf_token()
    }

    /// Pauses running jobs, saves state, removes the socket file.
    pub fn shutdown(&self) {
        self.sched.shutdown();
        let _ = std::fs::remove_file(&self.socket_path);
    }
}

fn join_error(e: tokio::task::JoinError) -> EngineError {
    EngineError::Io { msg: format!("engine task: {e}") }
}

impl Engine {
    #[doc(hidden)]
    pub fn set_clock(&self, clock: crate::scheduler::Clock) {
        self.sched.set_clock(clock);
    }

    #[doc(hidden)]
    pub fn tick(&self) {
        self.sched.tick();
    }

    #[doc(hidden)]
    pub async fn auto_test_tick(&self) {
        let (base, ms) = self.speed_test.lock().unwrap_or_else(|e| e.into_inner()).clone();
        let sched = Arc::clone(&self.sched);
        let _ = self.rt.spawn(async move { speedtest::auto(&sched, &base, ms).await }).await;
    }
}
