//! Download queues: a named list of jobs with its own schedule, speed limit and finish action.
use serde::{Deserialize, Serialize};

#[derive(uniffi::Enum, Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Repeat {
    Once { date: String },
    Daily,
    /// Bit 0 is Monday through bit 6 is Sunday.
    Days { mask: u8 },
}

#[derive(uniffi::Enum, Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum FinishAction {
    Nothing,
    Sound,
    Quit,
    Sleep,
    Lock,
    ShutDown,
    Command { command: String },
}

#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct QueueSchedule {
    pub repeat: Repeat,
    /// Minutes since midnight.
    pub start_min: u16,
    pub stop_min: Option<u16>,
    pub wifi: bool,
    pub power: bool,
    pub idle: bool,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct QueueConfig {
    /// None until saved.
    pub id: Option<u64>,
    pub name: String,
    pub max_running: u32,
    /// Bytes per second for this queue; 0 means unlimited.
    pub speed_limit: u64,
    pub enabled: bool,
    pub schedule: Option<QueueSchedule>,
    pub retry_failed: bool,
    pub wake: bool,
    pub when_finished: FinishAction,
}
