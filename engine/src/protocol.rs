//! JSON-lines messages on `dl.sock`, shared by the engine and the `dl` CLI.
//! One JSON object per line, request then reply. Lines are capped at `MAX_LINE` bytes.
use serde::{Deserialize, Serialize};

pub const MAX_LINE: usize = 1 << 20;

/// A request header sent with every request to a job's own site. Lives here so the CLI can build it;
/// the value is a secret, so `Debug` leaves it out.
#[derive(Serialize, Deserialize, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "full", derive(uniffi::Record))]
pub struct HttpHeader {
    pub name: String,
    pub value: String,
}

impl std::fmt::Debug for HttpHeader {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("HttpHeader").field("name", &self.name).finish_non_exhaustive()
    }
}

#[derive(Serialize, Deserialize, Debug, PartialEq)]
#[serde(tag = "op", rename_all = "lowercase")]
pub enum Request {
    /// `queue` is a queue's id or name; absent means the Main queue. `best_time` adds to the Best time queue instead.
    Add {
        urls: Vec<String>,
        #[serde(default)]
        queue: Option<QueueRef>,
        #[serde(default)]
        best_time: bool,
        /// Expected SHA-256 per url, same order; empty means none.
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        sha256: Vec<Option<String>>,
        /// Extra links for the same file per url, same order; empty means none.
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        mirrors: Vec<Vec<String>>,
        /// Request headers sent with every url of this command, to the link's own host only.
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        headers: Vec<HttpHeader>,
    },
    List,
    /// Gives a paused or failed download a new link and queues it.
    Relink {
        id: u64,
        url: String,
        /// Start over when the new link is a different file.
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        restart: bool,
    },
    /// Lists the downloadable files linked from a web page.
    Grab { url: String },
    Queues,
    /// The last speed test and the best time of day to download.
    Speed,
    /// Totals of downloads finished in the last `days` days.
    Stats {
        #[serde(default = "default_days")]
        days: u32,
    },
    #[serde(rename = "speed_test")]
    SpeedTest {
        #[serde(default)]
        force: bool,
    },
    // Queues are only listed, started, stopped or run now here. Editing one's config, schedule, finish action or
    // Run command, and deleting one, stay app-only: Run command executes shell commands, so letting a local
    // socket client set it would be code execution. Speed settings and clearing speed history stay app-only too.
    #[serde(rename = "queue_start")]
    QueueStart { queue: QueueRef },
    #[serde(rename = "queue_stop")]
    QueueStop { queue: QueueRef },
    #[serde(rename = "queue_run_now")]
    QueueRunNow { queue: QueueRef },
    /// Checks the files of the model download in `dir` (an absolute path) against its `.rays-model.json`.
    #[serde(rename = "verify_model")]
    VerifyModel { dir: String },
    Providers,
    Buckets,
    /// Adds a bucket. An empty `endpoint` is filled from the `provider` preset with `region` and `field`.
    /// `path_style` defaults to the preset's. The secret is stored in the Keychain by the app.
    #[serde(rename = "bucket_add")]
    BucketAdd {
        name: String,
        provider: String,
        #[serde(default)]
        endpoint: String,
        #[serde(default)]
        region: String,
        #[serde(default)]
        field: String,
        #[serde(default)]
        access_key_id: String,
        #[serde(default)]
        secret: String,
        #[serde(default)]
        path_style: Option<bool>,
        /// An AWS CLI profile to take keys from instead of `access_key_id` and `secret`.
        #[serde(default)]
        profile: Option<String>,
    },
    #[serde(rename = "bucket_remove")]
    BucketRemove { name: String },
    /// One level of `prefix` in `bucket`.
    #[serde(rename = "bucket_list")]
    BucketList {
        bucket: String,
        #[serde(default)]
        prefix: String,
        #[serde(default)]
        token: Option<String>,
    },
    Pause { id: u64 },
    Resume { id: u64 },
    /// Takes a download off the list. `delete_partial` also deletes an unfinished `.part`; a finished file stays.
    Remove {
        id: u64,
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        delete_partial: bool,
    },
    #[serde(rename = "hf_search")]
    HfSearch { query: String },
    #[serde(rename = "hf_model")]
    HfModel { repo: String },
    /// Downloads files of a Hugging Face model into `dir` (absolute), or into AI Models/<repo> in the download
    /// folder. Empty `files` means the recommended ones.
    #[serde(rename = "hf_add")]
    HfAdd {
        repo: String,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        files: Vec<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        dir: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        queue: Option<QueueRef>,
    },
}

/// A queue by id, or by name (matched case-insensitively).
#[derive(Serialize, Deserialize, Debug, PartialEq, Clone)]
#[serde(untagged)]
pub enum QueueRef {
    Id(u64),
    Name(String),
}

impl QueueRef {
    pub fn parse(s: &str) -> Self {
        s.parse().map_or_else(|_| Self::Name(s.to_owned()), Self::Id)
    }
}

#[derive(Serialize, Deserialize, Debug, PartialEq, Default)]
pub struct Response {
    pub ok: bool,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub added: Vec<Added>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub rejected: Vec<Rejected>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub jobs: Vec<JobLine>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub providers: Vec<ProviderLine>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub buckets: Vec<BucketLine>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub queues: Vec<QueueLine>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub verified: Vec<VerifyLine>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub listing: Option<ListingLine>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub grabbed: Vec<GrabLine>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub speed: Option<SpeedLine>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub speed_test: Option<SpeedTestLine>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stats: Option<StatsLine>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub models: Vec<ModelLine>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<ModelRepoLine>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub model_adds: Vec<ModelAddLine>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

fn default_days() -> u32 {
    30
}

#[derive(Serialize, Deserialize, Debug, PartialEq, Clone)]
pub struct StatsLine {
    pub total_bytes: u64,
    pub total_files: u64,
    /// Oldest first; `day` is unix seconds at local midnight.
    pub per_day: Vec<StatsDay>,
    pub top_hosts: Vec<StatsHost>,
    pub avg_bps: Option<u64>,
    pub peak_bps: Option<u64>,
}

#[derive(Serialize, Deserialize, Debug, PartialEq, Clone)]
pub struct StatsDay {
    pub day: i64,
    pub bytes: u64,
    pub files: u64,
}

#[derive(Serialize, Deserialize, Debug, PartialEq, Clone)]
pub struct StatsHost {
    pub host: String,
    pub bytes: u64,
    pub files: u64,
}

#[derive(Serialize, Deserialize, Debug, PartialEq, Clone)]
pub struct SpeedLine {
    pub last: Option<SpeedTestLine>,
    pub best_time: BestTimeLine,
}

#[derive(Serialize, Deserialize, Debug, PartialEq, Clone)]
pub struct SpeedTestLine {
    /// Bytes per second.
    pub bps: u64,
    pub latency_ms: u32,
    /// Unix seconds.
    pub at: i64,
    /// False when downloads ran during the test, which skews it.
    pub saved: bool,
}

#[derive(Serialize, Deserialize, Debug, PartialEq, Clone)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum BestTimeLine {
    /// Minutes of the local day; `confidence` is low, medium or high.
    Window { start_min: u16, end_min: u16, typical_bps: u64, days: u32, confidence: String },
    NotEnoughData { days: u32, needed: u32 },
}

#[derive(Serialize, Deserialize, Debug, PartialEq, Clone)]
pub struct QueueLine {
    pub id: u64,
    pub name: String,
    /// open, waiting for time, waiting for condition, stopped or off
    pub state: String,
    /// Next scheduled start in unix seconds.
    pub next_run: Option<i64>,
    pub queued: u32,
    pub running: u32,
}

#[derive(Serialize, Deserialize, Debug, PartialEq, Clone)]
pub struct VerifyLine {
    pub path: String,
    /// ok, size-checked, missing, wrong-size or wrong-checksum
    pub status: String,
    /// The size on disk, for wrong-size.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub actual: Option<u64>,
}

#[derive(Serialize, Deserialize, Debug, PartialEq, Clone)]
pub struct ProviderLine {
    pub id: String,
    pub name: String,
    /// Template with `{region}` and `{field}`; empty when the user supplies the endpoint.
    pub endpoint: String,
    pub region: String,
    pub field: Option<String>,
    pub path_style: bool,
}

/// A bucket without its secret.
#[derive(Serialize, Deserialize, Debug, PartialEq, Clone)]
pub struct BucketLine {
    pub name: String,
    pub provider: String,
    pub endpoint: String,
    pub region: String,
    pub access_key_id: String,
    pub path_style: bool,
}

#[derive(Serialize, Deserialize, Debug, PartialEq)]
pub struct GrabLine {
    pub url: String,
    pub name: String,
    pub kind: String,
}

#[derive(Serialize, Deserialize, Debug, PartialEq, Clone, Default)]
pub struct ListingLine {
    pub folders: Vec<String>,
    pub objects: Vec<ObjectLine>,
    pub next_token: Option<String>,
}

#[derive(Serialize, Deserialize, Debug, PartialEq, Clone)]
pub struct ObjectLine {
    pub key: String,
    pub size: u64,
    pub modified: String,
}

#[derive(Serialize, Deserialize, Debug, PartialEq, Clone)]
pub struct ModelLine {
    pub id: String,
    pub downloads: u64,
    pub likes: u64,
    pub gated: bool,
    pub gguf: bool,
    pub pipeline_tag: Option<String>,
}

#[derive(Serialize, Deserialize, Debug, PartialEq, Clone)]
pub struct ModelRepoLine {
    pub id: String,
    pub sha: String,
    pub gated: bool,
    pub files: Vec<ModelFileLine>,
    /// The files Rays picks when none are named.
    pub recommended: Vec<String>,
}

#[derive(Serialize, Deserialize, Debug, PartialEq, Clone)]
pub struct ModelFileLine {
    pub path: String,
    pub size: u64,
}

#[derive(Serialize, Deserialize, Debug, PartialEq, Clone)]
pub struct ModelAddLine {
    pub path: String,
    /// added, already there, already queued or rejected
    pub status: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Serialize, Deserialize, Debug, PartialEq)]
pub struct Added {
    pub url: String,
    pub id: u64,
}

#[derive(Serialize, Deserialize, Debug, PartialEq)]
pub struct Rejected {
    pub url: String,
    pub reason: String,
}

#[derive(Serialize, Deserialize, Debug, PartialEq)]
pub struct JobLine {
    pub id: u64,
    pub name: String,
    /// lowercase state name: queued, running, paused, retrying, done, failed
    pub state: String,
    pub done: u64,
    pub total: Option<u64>,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn round<T: Serialize + for<'a> Deserialize<'a> + PartialEq + std::fmt::Debug>(v: T, json: &str) {
        assert_eq!(serde_json::to_string(&v).unwrap(), json);
        assert_eq!(serde_json::from_str::<T>(json).unwrap(), v);
    }

    #[test]
    fn queue_requests_round_trip() {
        round(Request::Queues, r#"{"op":"queues"}"#);
        round(Request::QueueStart { queue: QueueRef::Id(2) }, r#"{"op":"queue_start","queue":2}"#);
        round(Request::QueueStop { queue: QueueRef::Name("Night".into()) }, r#"{"op":"queue_stop","queue":"Night"}"#);
        round(Request::QueueRunNow { queue: QueueRef::Id(1) }, r#"{"op":"queue_run_now","queue":1}"#);
        round(Request::Pause { id: 3 }, r#"{"op":"pause","id":3}"#);
        round(Request::Remove { id: 3, delete_partial: true }, r#"{"op":"remove","id":3,"delete_partial":true}"#);
        round(Request::HfAdd { repo: "a/b".into(), files: vec![], dir: None, queue: None }, r#"{"op":"hf_add","repo":"a/b"}"#);
        round(
            Request::Add { urls: vec!["u".into()], queue: Some(QueueRef::Name("Night".into())), best_time: false, sha256: vec![], mirrors: vec![], headers: vec![] },
            r#"{"op":"add","urls":["u"],"queue":"Night","best_time":false}"#,
        );
    }

    #[test]
    fn add_still_takes_numeric_or_missing_queue() {
        let r: Request = serde_json::from_str(r#"{"op":"add","urls":[],"queue":2}"#).unwrap();
        assert_eq!(r, Request::Add { urls: vec![], queue: Some(QueueRef::Id(2)), best_time: false, sha256: vec![], mirrors: vec![], headers: vec![] });
        let r: Request = serde_json::from_str(r#"{"op":"add","urls":[]}"#).unwrap();
        assert_eq!(r, Request::Add { urls: vec![], queue: None, best_time: false, sha256: vec![], mirrors: vec![], headers: vec![] });
    }

    #[test]
    fn add_best_time_is_optional() {
        let r: Request = serde_json::from_str(r#"{"op":"add","urls":["u"],"best_time":true}"#).unwrap();
        assert_eq!(r, Request::Add { urls: vec!["u".into()], queue: None, best_time: true, sha256: vec![], mirrors: vec![], headers: vec![] });
    }

    #[test]
    fn speed_requests_round_trip() {
        round(Request::Speed, r#"{"op":"speed"}"#);
        round(Request::Stats { days: 7 }, r#"{"op":"stats","days":7}"#);
        assert_eq!(serde_json::from_str::<Request>(r#"{"op":"stats"}"#).unwrap(), Request::Stats { days: 30 });
        round(Request::SpeedTest { force: false }, r#"{"op":"speed_test","force":false}"#);
        round(Request::SpeedTest { force: true }, r#"{"op":"speed_test","force":true}"#);
        let r: Request = serde_json::from_str(r#"{"op":"speed_test"}"#).unwrap();
        assert_eq!(r, Request::SpeedTest { force: false });
    }

    #[test]
    fn verify_request_round_trips() {
        round(Request::VerifyModel { dir: "/m".into() }, r#"{"op":"verify_model","dir":"/m"}"#);
    }

    #[test]
    fn queue_ref_parses_ids_and_names() {
        assert_eq!(QueueRef::parse("12"), QueueRef::Id(12));
        assert_eq!(QueueRef::parse("Night"), QueueRef::Name("Night".into()));
    }
}
