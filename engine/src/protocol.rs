//! JSON-lines messages on `dl.sock`, shared by the engine and the `dl` CLI.
//! One JSON object per line, request then reply. Lines are capped at `MAX_LINE` bytes.
use serde::{Deserialize, Serialize};

pub const MAX_LINE: usize = 1 << 20;

#[derive(Serialize, Deserialize, Debug, PartialEq)]
#[serde(tag = "op", rename_all = "lowercase")]
pub enum Request {
    Add { urls: Vec<String> },
    List,
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
        access_key_id: String,
        secret: String,
        #[serde(default)]
        path_style: Option<bool>,
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub listing: Option<ListingLine>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
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
