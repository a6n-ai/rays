//! Global bandwidth cap shared by every transfer: a token bucket refilled at `rate` bytes/s, burst of one second.
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};

pub struct RateLimiter {
    inner: Mutex<Bucket>,
    /// A queue's limiter also waits on the global one. One level only: the parent's own parent is not consulted.
    parent: Option<Arc<RateLimiter>>,
}

struct Bucket {
    /// Bytes per second; 0 means unlimited.
    rate: u64,
    tokens: f64,
    last: Instant,
}

impl Bucket {
    fn refill(&mut self, now: Instant) {
        let elapsed = now.duration_since(self.last).as_secs_f64();
        self.last = now;
        self.tokens = (self.tokens + elapsed * self.rate as f64).min(self.rate as f64);
    }
}

fn lock(m: &Mutex<Bucket>) -> MutexGuard<'_, Bucket> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

impl RateLimiter {
    pub fn new(rate: u64) -> RateLimiter {
        RateLimiter { inner: Mutex::new(Bucket { rate, tokens: rate as f64, last: Instant::now() }), parent: None }
    }

    /// Like `new`, but `acquire` waits on `parent` too.
    pub fn with_parent(rate: u64, parent: Arc<RateLimiter>) -> RateLimiter {
        RateLimiter { parent: Some(parent), ..RateLimiter::new(rate) }
    }

    pub fn is_limited(&self) -> bool {
        lock(&self.inner).rate > 0 || self.parent.as_ref().is_some_and(|p| p.is_limited())
    }

    pub fn set_rate(&self, rate: u64) {
        let mut b = lock(&self.inner);
        b.refill(Instant::now());
        b.rate = rate;
        b.tokens = b.tokens.min(rate as f64);
    }

    /// Waits until `n` bytes may pass, here and in the parent.
    pub async fn acquire(&self, n: usize) {
        self.take(n).await;
        if let Some(parent) = &self.parent {
            parent.take(n).await;
        }
    }

    /// Waits until `n` bytes may pass. A request above the burst waits for a full burst and goes into debt.
    async fn take(&self, n: usize) {
        let n = n as f64;
        loop {
            let wait = {
                let mut b = lock(&self.inner);
                if b.rate == 0 {
                    return;
                }
                b.refill(Instant::now());
                let need = n.min(b.rate as f64);
                if b.tokens >= need {
                    b.tokens -= n;
                    return;
                }
                Duration::from_secs_f64((need - b.tokens) / b.rate as f64)
            };
            // Capped so a rate change takes effect on the next wake-up.
            tokio::time::sleep(wait.min(Duration::from_millis(100))).await;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn child_waits_on_parent() {
        let parent = Arc::new(RateLimiter::new(100_000));
        let child = RateLimiter::with_parent(0, parent.clone());
        assert!(child.is_limited());
        child.acquire(100_000).await;
        let started = Instant::now();
        child.acquire(50_000).await;
        assert!(started.elapsed() >= Duration::from_millis(400), "{:?}", started.elapsed());
    }

    #[tokio::test]
    async fn burst_passes_at_once() {
        let limiter = RateLimiter::new(1_000_000);
        let started = Instant::now();
        limiter.acquire(1_000_000).await;
        assert!(started.elapsed() < Duration::from_millis(100), "{:?}", started.elapsed());
    }

    #[tokio::test]
    async fn bucket_refills_at_rate() {
        let limiter = RateLimiter::new(1_000_000);
        limiter.acquire(1_000_000).await;
        let started = Instant::now();
        limiter.acquire(500_000).await;
        let waited = started.elapsed();
        assert!(waited >= Duration::from_millis(400) && waited < Duration::from_millis(1500), "{waited:?}");
    }

    #[tokio::test]
    async fn request_above_burst_completes_in_debt() {
        let limiter = RateLimiter::new(1_000_000);
        let started = Instant::now();
        limiter.acquire(1_500_000).await;
        assert!(started.elapsed() < Duration::from_millis(100), "{:?}", started.elapsed());
        // 0.5 MB of debt, plus a 0.5 MB request that needs a full burst to be back: about one second.
        let started = Instant::now();
        limiter.acquire(500_000).await;
        let waited = started.elapsed();
        assert!(waited >= Duration::from_millis(800) && waited < Duration::from_millis(2000), "{waited:?}");
    }

    #[tokio::test]
    async fn zero_rate_is_unlimited() {
        let limiter = RateLimiter::new(0);
        let started = Instant::now();
        limiter.acquire(100_000_000).await;
        assert!(started.elapsed() < Duration::from_millis(50));
    }

    #[tokio::test]
    async fn raising_the_rate_releases_a_waiter() {
        let limiter = std::sync::Arc::new(RateLimiter::new(1024));
        limiter.acquire(1024).await;
        let waiter = tokio::spawn({
            let limiter = limiter.clone();
            async move { limiter.acquire(64 << 10).await }
        });
        tokio::time::sleep(Duration::from_millis(50)).await;
        limiter.set_rate(0);
        tokio::time::timeout(Duration::from_millis(500), waiter).await.expect("waiter released").expect("task ok");
    }
}
