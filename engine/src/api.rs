//! UniFFI-exported `Engine` object: owns the tokio runtime and wires the modules together.
use crate::events::EventHub;
use crate::hf::{self, HfModel, HfRepo};
use crate::ipc;
use crate::s3::{self, BucketConfig, Keychain, Listing, ProviderPreset};
use crate::scheduler::Scheduler;
use crate::store::Store;
use crate::types::{AddResult, EngineConfig, EngineError, HostView, JobEvent, JobId, JobView};
use std::path::{Path, PathBuf};
use std::sync::Arc;

#[derive(uniffi::Object)]
pub struct Engine {
    rt: tokio::runtime::Runtime,
    sched: Arc<Scheduler>,
    hub: Arc<EventHub>,
    socket_path: PathBuf,
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
        Ok(Arc::new(Engine { rt, sched, hub, socket_path }))
    }

    pub fn add(&self, urls: Vec<String>) -> Vec<AddResult> {
        self.sched.add(urls)
    }

    pub fn add_to(&self, urls: Vec<String>, dir: Option<String>, names: Vec<Option<String>>) -> Vec<AddResult> {
        self.sched.add_to(urls, dir.map(PathBuf::from), names)
    }

    pub fn pause(&self, id: JobId) {
        self.sched.pause(id);
    }

    pub fn resume(&self, id: JobId) {
        self.sched.resume(id);
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
