//! dl download engine. See docs/designs/dl-download-manager.md.
//! Without the `full` feature only `protocol` is built (used by the `dl` CLI).
pub mod protocol;

#[cfg(feature = "full")]
uniffi::setup_scaffolding!();

#[cfg(feature = "full")]
mod api;
#[cfg(feature = "full")]
pub mod download;
#[cfg(feature = "full")]
pub mod events;
#[cfg(feature = "full")]
pub mod ipc;
#[cfg(feature = "full")]
pub mod limit;
#[cfg(feature = "full")]
pub mod names;
#[cfg(feature = "full")]
pub mod scheduler;
#[cfg(feature = "full")]
pub mod store;
#[cfg(feature = "full")]
pub mod types;

#[cfg(feature = "full")]
pub use api::Engine;
#[cfg(feature = "full")]
pub use types::*;
