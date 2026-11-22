//! Coalesces job changes for `Engine::next_events`. Executor-agnostic (tokio::sync only, no runtime needed).
use std::collections::BTreeSet;
use std::sync::{Mutex, MutexGuard, PoisonError};

use tokio::sync::Notify;
use tokio::time::Instant;

use crate::types::JobId;

pub const PROGRESS_INTERVAL: std::time::Duration = std::time::Duration::from_millis(250);

/// What changed since the last `wait`.
#[derive(Debug, Default, PartialEq)]
pub struct Changes {
    pub changed: Vec<JobId>,
    pub removed: Vec<JobId>,
}

#[derive(Default)]
struct State {
    changed: BTreeSet<JobId>,
    removed: BTreeSet<JobId>,
    urgent: bool,
    last_delivery: Option<Instant>,
}

pub struct EventHub {
    state: Mutex<State>,
    notify: Notify,
}

impl Default for EventHub {
    fn default() -> Self {
        Self::new()
    }
}

impl EventHub {
    pub fn new() -> Self {
        Self {
            state: Mutex::new(State::default()),
            notify: Notify::new(),
        }
    }
    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }
    /// A state change (queued/running/paused/done/failed/retrying/added): delivered immediately.
    pub fn state_changed(&self, id: JobId) {
        {
            let mut s = self.lock();
            s.changed.insert(id);
            s.urgent = true;
        }
        self.notify.notify_one();
    }
    /// Bytes arrived: delivered no sooner than PROGRESS_INTERVAL after the previous delivery.
    pub fn progress(&self, id: JobId) {
        // Already pending means the consumer is already woken; another notify only spins it.
        if self.lock().changed.insert(id) {
            self.notify.notify_one();
        }
    }
    /// Job deleted: delivered immediately; also drops any pending change for `id`.
    pub fn removed(&self, id: JobId) {
        {
            let mut s = self.lock();
            s.changed.remove(&id);
            s.removed.insert(id);
            s.urgent = true;
        }
        self.notify.notify_one();
    }
    /// Waits until something is pending, then drains it. Ids are sorted and de-duplicated.
    pub async fn wait(&self) -> Changes {
        loop {
            let hold_until = {
                let mut s = self.lock();
                let pending = !s.changed.is_empty() || !s.removed.is_empty();
                if !pending {
                    None
                } else {
                    let due = s.last_delivery.map(|t| t + PROGRESS_INTERVAL);
                    match due {
                        Some(due) if !s.urgent && due > Instant::now() => Some(due),
                        _ => return Self::drain(&mut s),
                    }
                }
            };
            match hold_until {
                Some(due) => {
                    tokio::select! {
                        _ = tokio::time::sleep_until(due) => {}
                        _ = self.notify.notified() => {}
                    }
                }
                None => self.notify.notified().await,
            }
        }
    }
    fn drain(s: &mut State) -> Changes {
        s.urgent = false;
        s.last_delivery = Some(Instant::now());
        Changes {
            changed: std::mem::take(&mut s.changed).into_iter().collect(),
            removed: std::mem::take(&mut s.removed).into_iter().collect(),
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::time::Duration;

    use super::*;

    #[tokio::test]
    async fn state_changed_before_wait_returns_immediately() {
        let hub = EventHub::new();
        hub.state_changed(1);
        let c = hub.wait().await;
        assert_eq!(c.changed, vec![1]);
        assert!(c.removed.is_empty());
    }

    #[tokio::test]
    async fn progress_right_after_delivery_is_held() {
        let hub = EventHub::new();
        hub.state_changed(1);
        hub.wait().await;
        hub.progress(2);
        let start = Instant::now();
        let c = hub.wait().await;
        assert!(start.elapsed() >= PROGRESS_INTERVAL);
        assert_eq!(c.changed, vec![2]);
    }

    #[tokio::test]
    async fn progress_for_same_id_coalesces() {
        let hub = EventHub::new();
        for _ in 0..5 {
            hub.progress(7);
        }
        let c = hub.wait().await;
        assert_eq!(c.changed, vec![7]);
    }

    #[tokio::test]
    async fn state_changed_releases_held_progress() {
        let hub = Arc::new(EventHub::new());
        hub.state_changed(1);
        hub.wait().await;
        hub.progress(2);
        let h = hub.clone();
        let waiter = tokio::spawn(async move { h.wait().await });
        tokio::task::yield_now().await;
        let start = Instant::now();
        hub.state_changed(3);
        let c = waiter.await.unwrap();
        assert!(start.elapsed() < PROGRESS_INTERVAL);
        assert_eq!(c.changed, vec![2, 3]);
    }

    #[tokio::test]
    async fn removed_drops_pending_change_for_same_id() {
        let hub = EventHub::new();
        hub.state_changed(4);
        hub.progress(5);
        hub.removed(4);
        let c = hub.wait().await;
        assert_eq!(c.changed, vec![5]);
        assert_eq!(c.removed, vec![4]);
    }

    #[tokio::test]
    async fn wait_with_nothing_pending_stays_pending() {
        let hub = EventHub::new();
        let r = tokio::time::timeout(Duration::from_secs(1), hub.wait()).await;
        assert!(r.is_err());
    }
}
