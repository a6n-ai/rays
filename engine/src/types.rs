//! Types shared by every engine module. Records/enums are exported to Swift via UniFFI.
use crate::queue::QueueConfig;
use std::path::PathBuf;
use std::sync::Mutex;
use std::sync::atomic::{AtomicU32, AtomicU64};

pub type JobId = u64;

#[derive(uniffi::Record, Clone, Debug)]
pub struct EngineConfig {
    pub downloads_dir: String,
    pub data_dir: String,
    pub socket_path: String,
    pub max_running: u32,
    /// Connections per file for servers that support ranges; 1 disables splitting.
    pub connections: u32,
    /// Global cap in bytes per second across all downloads; 0 means unlimited.
    pub speed_limit: u64,
    /// Hugging Face site; `None` means https://huggingface.co. Tests point it at a local server.
    #[uniffi(default = None)]
    pub hf_base: Option<String>,
}

#[derive(uniffi::Enum, Clone, Debug, PartialEq, Eq)]
pub enum JobState {
    Queued,
    Running,
    Paused,
    Retrying { attempt: u8 },
    /// Hashing the finished `.part`. Pause does not apply; a job saved this way loads as Paused.
    Verifying,
    Done { path: String },
    Failed { reason: String },
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct JobView {
    pub id: JobId,
    pub url: String,
    pub name: String,
    pub done: u64,
    pub total: Option<u64>,
    pub bytes_per_sec: u64,
    pub resumable: bool,
    pub state: JobState,
    /// Connections currently transferring this file (0 when not running).
    pub connections: u32,
    /// The file's byte ranges for a split download, in file order; empty for a single stream.
    pub parts: Vec<PartView>,
    /// The folder the file goes into; None for the downloads folder.
    pub dir: Option<String>,
    pub queue_id: u64,
    /// Why a Queued job is not starting: its queue is closed ("Waiting for schedule", "Waiting for Wi-Fi",
    /// "Waiting for charger", "Waiting for idle" or "Queue stopped"). None for other jobs.
    pub waiting: Option<String>,
}

/// One range of a split download, for drawing a segmented progress bar.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct PartView {
    pub start: u64,
    pub end: u64,
    pub done: u64,
}

/// A server the engine limited to fewer connections after rate limiting or blocking.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct HostView {
    pub host: String,
    pub max_parts: u32,
    pub reason: String,
    pub updated_at: i64,
}

/// Whether a queue lets its jobs start right now.
#[derive(uniffi::Enum, Clone, Debug, PartialEq, Eq)]
pub enum QueueState {
    Open,
    /// Outside its run window; `next` is the next opening, in unix seconds.
    WaitingForTime { next: i64 },
    /// In its window, but a condition is unmet: "Wi-Fi", "charger" or "idle".
    WaitingForCondition { missing: Vec<String> },
    /// Held by Stop queue.
    Stopped,
    Off,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct QueueView {
    pub config: QueueConfig,
    pub state: QueueState,
    /// Jobs waiting to start, held ones included.
    pub queued: u32,
    /// Jobs transferring, retrying or verifying.
    pub running: u32,
    /// Sum of the known sizes of the jobs that are not done.
    pub total_bytes: u64,
    /// Next scheduled start in unix seconds; None for a queue without a schedule or a disabled one.
    pub next_run: Option<i64>,
}

#[derive(uniffi::Enum, Clone, Debug, PartialEq)]
pub enum JobEvent {
    Upsert { job: JobView },
    Removed { id: JobId },
    QueueChanged { queue: QueueView },
    /// A run of the queue ended: nothing is left queued, running or paused in it.
    QueueFinished { id: u64 },
    /// A queue run opened, closed, or (while running) has new counts; at most every 5 s while running.
    RunChanged { run: QueueRun },
}

#[derive(uniffi::Enum, Clone, Debug, PartialEq, Eq)]
pub enum RunOutcome {
    Running,
    /// Nothing was left in the queue.
    Finished,
    /// The window closed with work left.
    WindowClosed,
    StoppedByUser,
    /// Found open at the next engine start.
    AppQuit,
}

/// One run of a queue: from its first job starting until it finished, closed, was stopped or the app quit.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct QueueRun {
    pub id: u64,
    pub queue_id: u64,
    pub started_at: i64,
    pub ended_at: Option<i64>,
    pub files_done: u32,
    pub bytes_done: u64,
    pub outcome: RunOutcome,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct AddResult {
    pub url: String,
    pub id: Option<JobId>,
    pub error: Option<String>,
}

#[derive(uniffi::Error, Debug)]
pub enum EngineError {
    Io { msg: String },
    Db { msg: String },
    SocketInUse,
    InvalidUrl { msg: String },
    InvalidQueue { msg: String },
}

impl std::fmt::Display for EngineError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            EngineError::Io { msg } => write!(f, "io: {msg}"),
            EngineError::Db { msg } => write!(f, "database: {msg}"),
            EngineError::SocketInUse => f.write_str("another dl engine is already listening on the socket"),
            EngineError::InvalidUrl { msg } => write!(f, "invalid url: {msg}"),
            EngineError::InvalidQueue { msg } => write!(f, "invalid queue: {msg}"),
        }
    }
}
impl std::error::Error for EngineError {}

impl From<std::io::Error> for EngineError {
    fn from(e: std::io::Error) -> Self {
        EngineError::Io { msg: e.to_string() }
    }
}
impl From<rusqlite::Error> for EngineError {
    fn from(e: rusqlite::Error) -> Self {
        EngineError::Db { msg: e.to_string() }
    }
}

/// One byte range of a split download: bytes `start..end` (end exclusive), `done` of them written.
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct Segment {
    pub start: u64,
    pub end: u64,
    pub done: u64,
}

/// One persisted job row (mirrors the `jobs` table).
#[derive(Clone, Debug, PartialEq)]
pub struct Job {
    pub id: JobId,
    pub url: String,
    pub name: String,
    pub part_path: PathBuf,
    pub final_path: Option<PathBuf>,
    pub done: u64,
    pub total: Option<u64>,
    pub etag: Option<String>,
    pub last_modified: Option<String>,
    pub resumable: bool,
    pub state: JobState,
    /// Empty for a single-stream download; otherwise the file is preallocated and filled per segment.
    pub segments: Vec<Segment>,
    pub position: i64,
    pub created_at: i64,
    pub updated_at: i64,
    /// Folder to save into; None means the engine's downloads dir.
    pub dir: Option<PathBuf>,
    /// True when `name` was set by the caller, so the server's Content-Disposition cannot rename the file.
    pub fixed_name: bool,
    /// Expected SHA-256 (hex), checked when the download finishes.
    pub sha256: Option<String>,
    /// The queue this job belongs to; 1 is the Main queue.
    pub queue_id: u64,
}

/// A job held in memory by the scheduler while the engine runs.
/// `done` is the live byte counter updated per chunk; `job.done` is copied from it before saving.
pub struct Live {
    pub job: Mutex<Job>,
    pub done: AtomicU64,
    pub connections: AtomicU32,
    /// Send `true` to stop the running download (pause/remove/shutdown); a fresh channel per run.
    pub cancel: Mutex<tokio::sync::watch::Sender<bool>>,
    /// Order of this job's creation (`download::next_seq`), kept in memory only. A replace trashes a file only
    /// if it was produced before this, so a paused job that resumes later still keeps the file it raced.
    pub started: u64,
}

/// How one run of `download::run` ended.
#[derive(Debug, PartialEq)]
pub enum Outcome {
    Done(PathBuf),
    Paused,
    Failed(String),
}

pub fn now_secs() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}
