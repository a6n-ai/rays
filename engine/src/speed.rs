//! Speed samples: measured transfer rates, kept for the Speed insights view.

#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct SpeedSample {
    /// Unix seconds.
    pub at: i64,
    pub bps: u64,
    pub source: SampleSource,
    pub network: NetworkKind,
}

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum SampleSource {
    Test,
    Downloads,
}

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum NetworkKind {
    Wifi,
    Wired,
    Expensive,
    Other,
    Unknown,
}
