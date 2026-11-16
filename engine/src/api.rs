//! UniFFI-exported `Engine` object: owns the tokio runtime and wires the modules together.
use crate::events::EventHub;
use crate::ipc;
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
        let sched = Scheduler::new(
            rt.handle().clone(),
            store,
            Arc::clone(&hub),
            PathBuf::from(&config.downloads_dir),
            config.max_running,
            config.connections.max(1),
            config.speed_limit,
        )?;
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

    /// Pauses running jobs, saves state, removes the socket file.
    pub fn shutdown(&self) {
        self.sched.shutdown();
        let _ = std::fs::remove_file(&self.socket_path);
    }
}
