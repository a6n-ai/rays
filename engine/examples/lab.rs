//! Fault-injecting HTTP/1.1 test server, so download tools can be timed on the same conditions without the
//! noise of a real line: `cargo run --release -p dl-engine --example lab -- [flags]`, then download
//! `http://127.0.0.1:<port>/<bytes>.bin` (zeros; any size). Keep-alive and single `bytes=a-b` ranges.
//!
//! Flags (all optional): `--port 8766`, `--conn-rate B/s` cap per request, `--link-rate B/s` cap shared by all,
//! `--latency ms` before each response, `--slow-every N` and `--slow-rate B/s` (every Nth request is slow),
//! `--max-conns N` (503 with Retry-After: 1 above N transfers at once), `--drop-after B` (each response closes
//! after B bytes), `--no-range` (always 200, no Accept-Ranges).
//! `GET /stats` returns requests, 503s, peak concurrent transfers and bytes sent as JSON; `GET /reset` zeroes them.
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream};

const CHUNK: usize = 64 << 10;

#[derive(Default)]
struct Cfg {
    port: u16,
    conn_rate: u64,
    link_rate: u64,
    latency: u64,
    slow_every: u64,
    slow_rate: u64,
    max_conns: u64,
    drop_after: u64,
    no_range: bool,
}

#[derive(Default)]
struct Stats {
    requests: AtomicU64,
    rejected: AtomicU64,
    active: AtomicU64,
    peak: AtomicU64,
    bytes: AtomicU64,
}

/// Token bucket shared by every transfer: the "link".
struct Link {
    rate: u64,
    state: Mutex<(Instant, f64)>,
}

impl Link {
    /// Waits until `n` bytes fit under the shared rate. 0 means unlimited.
    async fn take(&self, n: usize) {
        if self.rate == 0 {
            return;
        }
        let wait = {
            let mut s = self.state.lock().unwrap();
            let now = Instant::now();
            // Allow a burst of at most 100 ms of the rate.
            let burst = self.rate as f64 / 10.0;
            s.1 = (s.1 + now.duration_since(s.0).as_secs_f64() * self.rate as f64).min(burst);
            s.0 = now;
            s.1 -= n as f64;
            if s.1 < 0.0 { Duration::from_secs_f64(-s.1 / self.rate as f64) } else { Duration::ZERO }
        };
        tokio::time::sleep(wait).await;
    }
}

struct Lab {
    cfg: Cfg,
    stats: Stats,
    link: Link,
}

/// Decrements the active count on every exit path of a transfer.
struct Active<'a>(&'a Stats);

impl Drop for Active<'_> {
    fn drop(&mut self) {
        self.0.active.fetch_sub(1, Ordering::SeqCst);
    }
}

fn parse_args() -> Cfg {
    let mut cfg = Cfg { port: 8766, ..Cfg::default() };
    let mut args = std::env::args().skip(1);
    while let Some(flag) = args.next() {
        if flag == "--no-range" {
            cfg.no_range = true;
            continue;
        }
        let value: u64 = args.next().and_then(|v| v.parse().ok()).unwrap_or_else(|| panic!("{flag} needs a number"));
        match flag.as_str() {
            "--port" => cfg.port = value as u16,
            "--conn-rate" => cfg.conn_rate = value,
            "--link-rate" => cfg.link_rate = value,
            "--latency" => cfg.latency = value,
            "--slow-every" => cfg.slow_every = value,
            "--slow-rate" => cfg.slow_rate = value,
            "--max-conns" => cfg.max_conns = value,
            "--drop-after" => cfg.drop_after = value,
            _ => panic!("unknown flag {flag}"),
        }
    }
    cfg
}

#[tokio::main]
async fn main() {
    let cfg = parse_args();
    let listener = TcpListener::bind(("127.0.0.1", cfg.port)).await.expect("bind");
    println!("lab on http://127.0.0.1:{}/<bytes>.bin", cfg.port);
    let link = Link { rate: cfg.link_rate, state: Mutex::new((Instant::now(), 0.0)) };
    let lab = Arc::new(Lab { cfg, stats: Stats::default(), link });
    loop {
        let Ok((sock, _)) = listener.accept().await else { continue };
        let lab = Arc::clone(&lab);
        tokio::spawn(async move {
            let _ = serve(sock, &lab).await;
        });
    }
}

/// Answers requests on one keep-alive connection until the client closes it or a response is dropped.
async fn serve(sock: TcpStream, lab: &Lab) -> std::io::Result<()> {
    let _ = sock.set_nodelay(true);
    let mut sock = BufReader::new(sock);
    loop {
        let mut head = Vec::new();
        loop {
            let mut line = String::new();
            if sock.read_line(&mut line).await? == 0 {
                return Ok(());
            }
            if line == "\r\n" || line == "\n" {
                break;
            }
            head.push(line.trim_end().to_ascii_lowercase());
        }
        let path = head.first().and_then(|l| l.split_whitespace().nth(1)).unwrap_or("/").to_string();
        let range = head.iter().find_map(|l| l.strip_prefix("range: bytes=").map(str::to_string));
        let out = sock.get_mut();
        match path.as_str() {
            "/stats" => {
                let s = &lab.stats;
                let body = format!(
                    "{{\"requests\":{},\"rejected\":{},\"peak\":{},\"bytes\":{}}}\n",
                    s.requests.load(Ordering::SeqCst),
                    s.rejected.load(Ordering::SeqCst),
                    s.peak.load(Ordering::SeqCst),
                    s.bytes.load(Ordering::SeqCst)
                );
                reply(out, "200 OK", &[("Content-Type", "application/json")], body.as_bytes()).await?;
                continue;
            }
            "/reset" => {
                for c in [&lab.stats.requests, &lab.stats.rejected, &lab.stats.peak, &lab.stats.bytes] {
                    c.store(0, Ordering::SeqCst);
                }
                reply(out, "200 OK", &[], b"reset\n").await?;
                continue;
            }
            _ => {}
        }
        let Some(total) = path.strip_prefix('/').and_then(|p| p.strip_suffix(".bin")).and_then(|n| n.parse::<u64>().ok())
        else {
            reply(out, "404 Not Found", &[], b"not found\n").await?;
            continue;
        };
        let n = lab.stats.requests.fetch_add(1, Ordering::SeqCst) + 1;
        let active = lab.stats.active.fetch_add(1, Ordering::SeqCst) + 1;
        let guard = Active(&lab.stats);
        if lab.cfg.max_conns > 0 && active > lab.cfg.max_conns {
            lab.stats.rejected.fetch_add(1, Ordering::SeqCst);
            drop(guard);
            reply(out, "503 Service Unavailable", &[("Retry-After", "1")], b"busy\n").await?;
            continue;
        }
        lab.stats.peak.fetch_max(active, Ordering::SeqCst);
        if lab.cfg.latency > 0 {
            tokio::time::sleep(Duration::from_millis(lab.cfg.latency)).await;
        }

        let (start, end) = match range.filter(|_| !lab.cfg.no_range) {
            Some(r) => {
                let (a, b) = r.split_once('-').unwrap_or((&r, ""));
                let a: u64 = a.trim().parse().unwrap_or(0);
                let b: u64 = b.trim().parse().map(|b: u64| b + 1).unwrap_or(total);
                (a.min(total), b.min(total))
            }
            None => (0, total),
        };
        let len = end.saturating_sub(start);
        let mut head = if lab.cfg.no_range || start == 0 && end == total && !head.iter().any(|l| l.starts_with("range:")) {
            format!("HTTP/1.1 200 OK\r\nContent-Length: {total}\r\n")
        } else {
            format!("HTTP/1.1 206 Partial Content\r\nContent-Range: bytes {start}-{}/{total}\r\nContent-Length: {len}\r\n", end.saturating_sub(1))
        };
        if !lab.cfg.no_range {
            head += "Accept-Ranges: bytes\r\nETag: \"lab\"\r\n";
        }
        head += "Content-Type: application/octet-stream\r\n\r\n";
        out.write_all(head.as_bytes()).await?;

        let rate = if lab.cfg.slow_every > 0 && n.is_multiple_of(lab.cfg.slow_every) { lab.cfg.slow_rate } else { lab.cfg.conn_rate };
        let zeros = [0u8; CHUNK];
        let began = Instant::now();
        let mut sent: u64 = 0;
        while sent < len {
            if lab.cfg.drop_after > 0 && sent >= lab.cfg.drop_after {
                return Ok(()); // closes the connection mid-body
            }
            let take = (len - sent).min(CHUNK as u64) as usize;
            lab.link.take(take).await;
            out.write_all(&zeros[..take]).await?;
            sent += take as u64;
            lab.stats.bytes.fetch_add(take as u64, Ordering::Relaxed);
            if rate > 0 && sent < len {
                let due = Duration::from_secs_f64(sent as f64 / rate as f64);
                if let Some(wait) = due.checked_sub(began.elapsed()) {
                    tokio::time::sleep(wait).await;
                }
            }
        }
        drop(guard);
    }
}

async fn reply(out: &mut TcpStream, status: &str, headers: &[(&str, &str)], body: &[u8]) -> std::io::Result<()> {
    let mut head = format!("HTTP/1.1 {status}\r\nContent-Length: {}\r\n", body.len());
    for (k, v) in headers {
        head += &format!("{k}: {v}\r\n");
    }
    head += "\r\n";
    out.write_all(head.as_bytes()).await?;
    out.write_all(body).await
}
