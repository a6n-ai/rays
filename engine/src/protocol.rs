//! JSON-lines messages on `dl.sock`, shared by the engine and the `dl` CLI.
//! One JSON object per line, request then reply. Lines are capped at `MAX_LINE` bytes.
use serde::{Deserialize, Serialize};

pub const MAX_LINE: usize = 1 << 20;

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
    },
    List,
    Queues,
    /// The last speed test and the best time of day to download.
    Speed,
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub speed: Option<SpeedLine>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub speed_test: Option<SpeedTestLine>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
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
        round(
            Request::Add { urls: vec!["u".into()], queue: Some(QueueRef::Name("Night".into())), best_time: false },
            r#"{"op":"add","urls":["u"],"queue":"Night","best_time":false}"#,
        );
    }

    #[test]
    fn add_still_takes_numeric_or_missing_queue() {
        let r: Request = serde_json::from_str(r#"{"op":"add","urls":[],"queue":2}"#).unwrap();
        assert_eq!(r, Request::Add { urls: vec![], queue: Some(QueueRef::Id(2)), best_time: false });
        let r: Request = serde_json::from_str(r#"{"op":"add","urls":[]}"#).unwrap();
        assert_eq!(r, Request::Add { urls: vec![], queue: None, best_time: false });
    }

    #[test]
    fn add_best_time_is_optional() {
        let r: Request = serde_json::from_str(r#"{"op":"add","urls":["u"],"best_time":true}"#).unwrap();
        assert_eq!(r, Request::Add { urls: vec!["u".into()], queue: None, best_time: true });
    }

    #[test]
    fn speed_requests_round_trip() {
        round(Request::Speed, r#"{"op":"speed"}"#);
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
