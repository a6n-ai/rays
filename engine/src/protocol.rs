//! JSON-lines messages on `dl.sock`, shared by the engine and the `dl` CLI.
//! One JSON object per line, request then reply. Lines are capped at `MAX_LINE` bytes.
use serde::{Deserialize, Serialize};

pub const MAX_LINE: usize = 1 << 20;

#[derive(Serialize, Deserialize, Debug, PartialEq)]
#[serde(tag = "op", rename_all = "lowercase")]
pub enum Request {
    Add { urls: Vec<String> },
    List,
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
