use axum::Router;
use axum::body::Body;
use axum::extract::{Request, State};
use axum::http::{StatusCode, header};
use axum::middleware::{self, Next};
use axum::response::Response;
use axum::routing::get;
use dl_engine::download;
use dl_engine::events::EventHub;
use dl_engine::{Engine, EngineConfig, JobId};
use dl_engine::limit::RateLimiter;
use dl_engine::names;
use dl_engine::types::{Job, JobState, Live, Outcome};
use sha2::{Digest, Sha256};
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tempfile::TempDir;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::watch;
use tower_http::services::ServeFile;

const SIZE: usize = 2 * 1024 * 1024;
const DROP_AT: usize = 512 * 1024;
const ETAG_VAL: &str = "\"v1\"";

fn data() -> Vec<u8> {
    (0..SIZE).map(|i| ((i * 7 + i / 256) % 256) as u8).collect()
}

fn sha(bytes: &[u8]) -> Vec<u8> {
    Sha256::digest(bytes).as_slice().to_vec()
}

fn setup() {
    // SAFETY: set before any download starts in this test; every test sets the same value.
    unsafe { std::env::set_var("DL_RETRY_SCALE_MS", "1") };
}

#[derive(Clone)]
struct St {
    data: Arc<Vec<u8>>,
    missing_hits: Arc<AtomicUsize>,
}

struct Srv {
    base: String,
    flaky: SocketAddr,
    stall: SocketAddr,
    flaky_hits: Arc<AtomicUsize>,
    missing_hits: Arc<AtomicUsize>,
    _dir: TempDir,
}

impl Srv {
    fn url(&self, path: &str) -> String {
        format!("{}{path}", self.base)
    }
}

async fn start() -> Srv {
    let dir = tempfile::tempdir().unwrap();
    let src = dir.path().join("source.bin");
    std::fs::write(&src, data()).unwrap();
    let st = St { data: Arc::new(data()), missing_hits: Arc::new(AtomicUsize::new(0)) };
    let app = Router::new()
        .route_service("/file", ServeFile::new(&src))
        .route("/noranges", get(noranges))
        .route("/404", get(missing))
        .route("/evil", get(evil))
        .route("/named", get(named))
        .with_state(st.clone());
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let flaky_hits = Arc::new(AtomicUsize::new(0));
    Srv {
        base: format!("http://{addr}"),
        flaky: flaky_server(Arc::new(data()), flaky_hits.clone()).await,
        stall: stall_server().await,
        flaky_hits,
        missing_hits: st.missing_hits,
        _dir: dir,
    }
}

/// Raw TCP, because axum cannot send a body that errors partway without a stream type this crate lacks.
/// First request: headers promising the full length, then `DROP_AT` bytes, then the socket closes.
/// Later requests: honour `Range` (206) or send the whole file (200).
async fn flaky_server(data: Arc<Vec<u8>>, hits: Arc<AtomicUsize>) -> SocketAddr {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        while let Ok((mut sock, _)) = listener.accept().await {
            let (data, hits) = (data.clone(), hits.clone());
            tokio::spawn(async move {
                let mut buf = vec![0u8; 8192];
                let n = sock.read(&mut buf).await.unwrap_or(0);
                let req = String::from_utf8_lossy(&buf[..n]).to_lowercase();
                let first = hits.fetch_add(1, Ordering::SeqCst) == 0;
                let from = req
                    .lines()
                    .find_map(|l| l.strip_prefix("range: bytes="))
                    .and_then(|r| r.trim().strip_suffix('-'))
                    .and_then(|n| n.parse::<usize>().ok());
                let (head, body) = if first {
                    (
                        format!("HTTP/1.1 200 OK\r\nContent-Length: {SIZE}\r\n"),
                        data[..DROP_AT].to_vec(),
                    )
                } else {
                    match from {
                        Some(n) if n < SIZE => (
                            format!(
                                "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes {n}-{}/{SIZE}\r\nContent-Length: {}\r\n",
                                SIZE - 1,
                                SIZE - n
                            ),
                            data[n..].to_vec(),
                        ),
                        Some(_) => ("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Length: 0\r\n".to_string(), vec![]),
                        None => (format!("HTTP/1.1 200 OK\r\nContent-Length: {SIZE}\r\n"), data.to_vec()),
                    }
                };
                let head = format!("{head}ETag: {ETAG_VAL}\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n");
                let _ = sock.write_all(head.as_bytes()).await;
                let _ = sock.write_all(&body).await;
                let _ = sock.shutdown().await;
            });
        }
    });
    addr
}

/// Always 200 with the full body, no Accept-Ranges, Range ignored.
async fn noranges(State(st): State<St>) -> Response {
    Response::builder()
        .header(header::CONTENT_LENGTH, st.data.len().to_string())
        .body(Body::from(st.data.to_vec()))
        .unwrap()
}

async fn missing(State(st): State<St>) -> StatusCode {
    st.missing_hits.fetch_add(1, Ordering::SeqCst);
    StatusCode::NOT_FOUND
}

async fn evil() -> Response {
    Response::builder()
        .header(header::CONTENT_DISPOSITION, "attachment; filename=\"../../evil.sh\"")
        .body(Body::from("echo hi\n"))
        .unwrap()
}

async fn named(State(st): State<St>) -> Response {
    Response::builder()
        .header(header::CONTENT_DISPOSITION, "attachment; filename=\"other.bin\"")
        .body(Body::from(st.data.to_vec()))
        .unwrap()
}

/// Sends headers, then never sends a body.
async fn stall_server() -> SocketAddr {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        while let Ok((mut sock, _)) = listener.accept().await {
            tokio::spawn(async move {
                let mut buf = [0u8; 4096];
                let _ = sock.read(&mut buf).await;
                let _ = sock.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2000000\r\n\r\n").await;
                std::future::pending::<()>().await;
            });
        }
    });
    addr
}

fn job(url: String, dir: &Path, name: &str) -> (Arc<Live>, watch::Receiver<bool>) {
    job_with_id(url, dir, name, 1)
}

fn job_with_id(url: String, dir: &Path, name: &str, id: u64) -> (Arc<Live>, watch::Receiver<bool>) {
    let (tx, rx) = watch::channel(false);
    let job = Job {
        id,
        url,
        name: name.to_string(),
        part_path: names::part_path(dir, name, id),
        final_path: None,
        done: 0,
        total: None,
        etag: None,
        last_modified: None,
        resumable: true,
        state: JobState::Queued,
        segments: Vec::new(),
        position: 0,
        created_at: 0,
        updated_at: 0,
        dir: None,
        fixed_name: false,
        sha256: None,
        queue_id: 1,
    };
    let live = Live { job: Mutex::new(job), done: AtomicU64::new(0), connections: std::sync::atomic::AtomicU32::new(0), started: dl_engine::download::next_seq(), cancel: Mutex::new(tx) };
    (Arc::new(live), rx)
}

async fn run_job(live: Arc<Live>, dir: &Path, rx: watch::Receiver<bool>) -> Outcome {
    run_conn(live, dir.to_path_buf(), rx, 1, unlimited()).await
}

async fn run_conn(
    live: Arc<Live>,
    dir: PathBuf,
    rx: watch::Receiver<bool>,
    connections: u32,
    limiter: Arc<RateLimiter>,
) -> Outcome {
    download::run(live, reqwest::Client::new(), &dir, Arc::new(EventHub::new()), rx, connections, 2, limiter, None, None, download::RunOpts::default()).await
}

fn unlimited() -> Arc<RateLimiter> {
    Arc::new(RateLimiter::new(0))
}

/// Paths the fake Trash was asked to remove; the real Trash is never touched.
static TRASHED: Mutex<Vec<PathBuf>> = Mutex::new(Vec::new());

fn fake_trash(path: &Path) -> std::io::Result<()> {
    TRASHED.lock().unwrap().push(path.to_path_buf());
    std::fs::remove_file(path)
}

fn failing_trash(_: &Path) -> std::io::Result<()> {
    Err(std::io::Error::other("trash unavailable"))
}

/// Trash calls made under `dir`; other tests share the list, so each one looks only at its own folder.
fn trashed_in(dir: &Path) -> Vec<PathBuf> {
    TRASHED.lock().unwrap().iter().filter(|p| p.starts_with(dir)).cloned().collect()
}

async fn run_replacing(live: Arc<Live>, dir: &Path, rx: watch::Receiver<bool>, opts: download::RunOpts) -> Outcome {
    download::run(live, reqwest::Client::new(), dir, Arc::new(EventHub::new()), rx, 1, 1, unlimited(), None, None, opts).await
}

fn expect_done(out: Outcome) -> PathBuf {
    match out {
        Outcome::Done(path) => path,
        other => panic!("expected Done, got {other:?}"),
    }
}

#[tokio::test]
async fn full_download_matches_source() {
    setup();
    let srv = start().await;
    let dir = tempfile::tempdir().unwrap();
    let (live, rx) = job(srv.url("/file"), dir.path(), "data.bin");
    let path = expect_done(run_job(live, dir.path(), rx).await);
    assert_eq!(sha(&std::fs::read(&path).unwrap()), sha(&data()));
}

#[tokio::test]
async fn dropped_connection_resumes() {
    setup();
    let srv = start().await;
    let dir = tempfile::tempdir().unwrap();
    let (live, rx) = job(format!("http://{}/", srv.flaky), dir.path(), "data.bin");
    let path = expect_done(run_job(live, dir.path(), rx).await);
    assert_eq!(sha(&std::fs::read(&path).unwrap()), sha(&data()));
    assert_eq!(srv.flaky_hits.load(Ordering::SeqCst), 2);
}

#[tokio::test]
async fn existing_part_resumes_with_range() {
    setup();
    let srv = start().await;
    let dir = tempfile::tempdir().unwrap();
    let (live, rx) = job(srv.url("/file"), dir.path(), "data.bin");
    std::fs::write(&live.job.lock().unwrap().part_path, &data()[..100 * 1024]).unwrap();
    let path = expect_done(run_job(live, dir.path(), rx).await);
    assert_eq!(sha(&std::fs::read(&path).unwrap()), sha(&data()));
}

#[tokio::test]
async fn ignored_range_restarts_and_marks_not_resumable() {
    setup();
    let srv = start().await;
    let dir = tempfile::tempdir().unwrap();
    let (live, rx) = job(srv.url("/noranges"), dir.path(), "data.bin");
    // Junk prefix: a restart must truncate it, not append to it.
    std::fs::write(&live.job.lock().unwrap().part_path, vec![0xAA; 100 * 1024]).unwrap();
    let job_ref = live.clone();
    let path = expect_done(run_job(live, dir.path(), rx).await);
    assert_eq!(sha(&std::fs::read(&path).unwrap()), sha(&data()));
    assert!(!job_ref.job.lock().unwrap().resumable);
}

#[tokio::test]
async fn not_found_fails_without_retry() {
    setup();
    let srv = start().await;
    let dir = tempfile::tempdir().unwrap();
    let (live, rx) = job(srv.url("/404"), dir.path(), "data.bin");
    let started = Instant::now();
    let out = run_job(live, dir.path(), rx).await;
    assert_eq!(out, Outcome::Failed("HTTP 404".to_string()));
    assert!(started.elapsed() < Duration::from_secs(1));
    assert_eq!(srv.missing_hits.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn hostile_disposition_name_is_sanitized() {
    setup();
    let srv = start().await;
    let dir = tempfile::tempdir().unwrap();
    let (live, rx) = job(srv.url("/evil"), dir.path(), "download");
    let path = expect_done(run_job(live, dir.path(), rx).await);
    assert_eq!(path, dir.path().join("evil.sh"));
}

fn engine_in(root: &Path) -> Arc<Engine> {
    let downloads = root.join("downloads");
    std::fs::create_dir_all(&downloads).unwrap();
    Engine::new(EngineConfig {
        downloads_dir: downloads.to_string_lossy().into_owned(),
        data_dir: root.join("data").to_string_lossy().into_owned(),
        socket_path: root.join("dl.sock").to_string_lossy().into_owned(),
        max_running: 2,
        connections: 1,
        speed_limit: 0,
        hf_base: None,
    })
    .unwrap()
}

fn wait_done(engine: &Engine, id: JobId) -> PathBuf {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        match engine.snapshot().into_iter().find(|j| j.id == id).map(|j| j.state) {
            Some(JobState::Done { path }) => return PathBuf::from(path),
            Some(JobState::Failed { reason }) => panic!("job failed: {reason}"),
            _ => {}
        }
        assert!(Instant::now() < deadline, "timed out waiting for job {id}");
        std::thread::sleep(Duration::from_millis(5));
    }
}

#[test]
fn add_to_saves_in_given_dir_with_fixed_name() {
    setup();
    let rt = tokio::runtime::Runtime::new().unwrap();
    let srv = rt.block_on(start());
    let root = tempfile::tempdir().unwrap();
    let engine = engine_in(root.path());
    let dest = root.path().join("m/sub");
    let add = engine.add_to(
        vec![srv.url("/named")],
        Some(dest.to_string_lossy().into_owned()),
        vec![Some("weights.gguf".into())],
    );
    let path = wait_done(&engine, add[0].id.expect("url accepted"));
    assert_eq!(path, dest.join("weights.gguf"));
    assert_eq!(sha(&std::fs::read(&path).unwrap()), sha(&data()));
}

#[test]
fn add_keeps_disposition_name_in_default_dir() {
    setup();
    let rt = tokio::runtime::Runtime::new().unwrap();
    let srv = rt.block_on(start());
    let root = tempfile::tempdir().unwrap();
    let engine = engine_in(root.path());
    let id = engine.add(vec![srv.url("/named")])[0].id.expect("url accepted");
    assert_eq!(wait_done(&engine, id), root.path().join("downloads/other.bin"));
}

#[test]
fn add_rejects_unsafe_dir_and_file_name_without_a_job() {
    let root = tempfile::tempdir().unwrap();
    let engine = engine_in(root.path());
    let url = "https://example.com/f.bin".to_string();
    let dir = root.path().join("ok").to_string_lossy().into_owned();
    for name in ["../x", "/abs", "a/b", "", ".", "..", "a\0b"] {
        let r = engine.add_to(vec![url.clone()], Some(dir.clone()), vec![Some(name.into())]).remove(0);
        assert!(r.id.is_none() && r.error.is_some(), "name {name:?} accepted");
    }
    for bad_dir in ["rel/dir".to_string(), "/tmp/../x".to_string()] {
        let r = engine.add_to(vec![url.clone()], Some(bad_dir.clone()), vec![None]).remove(0);
        assert!(r.id.is_none() && r.error.is_some(), "dir {bad_dir:?} accepted");
    }
    assert!(engine.snapshot().is_empty());
}

#[test]
fn add_rejects_names_that_do_not_match_urls() {
    let root = tempfile::tempdir().unwrap();
    let engine = engine_in(root.path());
    let urls = vec!["https://example.com/a.bin".to_string(), "https://example.com/b.bin".to_string()];
    let dir = root.path().join("ok").to_string_lossy().into_owned();
    let results = engine.add_to(urls.clone(), Some(dir), vec![Some("one.bin".into())]);
    assert_eq!(results.len(), 2);
    for (r, url) in results.iter().zip(&urls) {
        assert!(r.id.is_none() && r.error.as_deref() == Some("names must match urls"), "{r:?}");
        assert_eq!(&r.url, url);
    }
    assert!(engine.snapshot().is_empty());
}

#[tokio::test]
async fn cancel_pauses_stalled_body() {
    setup();
    let srv = start().await;
    let dir = tempfile::tempdir().unwrap();
    let (live, rx) = job(format!("http://{}/", srv.stall), dir.path(), "data.bin");
    let cancel_handle = live.clone();
    let handle = tokio::spawn({
        let dir = dir.path().to_path_buf();
        async move { run_job(live, &dir, rx).await }
    });
    tokio::time::sleep(Duration::from_millis(300)).await;
    let _ = cancel_handle.cancel.lock().unwrap().send(true);
    let out = tokio::time::timeout(Duration::from_millis(200), handle)
        .await
        .expect("paused within 200 ms")
        .unwrap();
    assert_eq!(out, Outcome::Paused);
}

const BIG: usize = 20 << 20;
const RAW_CHUNK: usize = 64 << 10;

const MIB: f64 = (1 << 20) as f64;

fn big_data() -> Vec<u8> {
    sized_data(BIG)
}

fn sized_data(len: usize) -> Vec<u8> {
    (0..len).map(|i| ((i * 13 + i / 4096) % 251) as u8).collect()
}

struct Big {
    base: String,
    ranged_hits: Arc<AtomicUsize>,
    _dir: TempDir,
}

async fn count_ranges(State(hits): State<Arc<AtomicUsize>>, req: Request, next: Next) -> Response {
    if req.headers().contains_key(header::RANGE) {
        hits.fetch_add(1, Ordering::SeqCst);
    }
    next.run(req).await
}

/// `/big` (20 MiB), `/mid` (3 MiB) and `/small` (1 MiB) are ServeFile routes; `/big-noranges` is a plain 200.
async fn big_server() -> Big {
    let dir = tempfile::tempdir().unwrap();
    let write = |name: &str, bytes: &[u8]| {
        let path = dir.path().join(name);
        std::fs::write(&path, bytes).unwrap();
        path
    };
    let big = write("big.bin", &big_data());
    let mid = write("mid.bin", &big_data()[..3 << 20]);
    let small = write("small.bin", &big_data()[..1 << 20]);
    let plain = Arc::new(big_data());
    let ranged_hits = Arc::new(AtomicUsize::new(0));
    let app = Router::new()
        .route_service("/big", tower_http::services::ServeFile::new(big))
        .route_service("/mid", tower_http::services::ServeFile::new(mid))
        .route_service("/small", tower_http::services::ServeFile::new(small))
        .route(
            "/big-noranges",
            get(move || {
                let plain = plain.clone();
                async move {
                    Response::builder()
                        .header(header::CONTENT_LENGTH, plain.len().to_string())
                        .body(Body::from(plain.to_vec()))
                        .unwrap()
                }
            }),
        )
        .layer(middleware::from_fn_with_state(ranged_hits.clone(), count_ranges));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    Big { base: format!("http://{addr}"), ranged_hits, _dir: dir }
}

/// Raw origin for pause and fault tests. Honours Range with 206 and sends one 64 KiB chunk every `pace`.
/// `cut_next`: the next ranged response that reaches 1 MiB is cut off, and `whole_only` is set so every
/// later ranged request gets a whole-file 200.
#[derive(Default)]
struct Raw {
    ranges: Mutex<Vec<u64>>,
    cut_next: AtomicBool,
    whole_only: AtomicBool,
}

type Pace = Arc<dyn Fn(u64) -> Duration + Send + Sync>;

async fn raw_server(data: Arc<Vec<u8>>, raw: Arc<Raw>, pace: Pace) -> SocketAddr {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        while let Ok((mut sock, _)) = listener.accept().await {
            let (data, raw, pace) = (data.clone(), raw.clone(), pace.clone());
            tokio::spawn(async move {
                let mut head = Vec::new();
                let mut byte = [0u8; 1];
                while !head.ends_with(b"\r\n\r\n") {
                    match sock.read(&mut byte).await {
                        Ok(1) => head.push(byte[0]),
                        _ => return,
                    }
                }
                let text = String::from_utf8_lossy(&head).to_lowercase();
                let requested = text
                    .lines()
                    .find_map(|l| l.strip_prefix("range: bytes="))
                    .and_then(|r| r.trim().split('-').next())
                    .and_then(|n| n.parse::<usize>().ok());
                if let Some(from) = requested {
                    raw.ranges.lock().unwrap().push(from as u64);
                }
                let ranged = requested.filter(|_| !raw.whole_only.load(Ordering::SeqCst));
                let len = data.len();
                let (status, start) = match ranged {
                    Some(from) => (
                        format!("HTTP/1.1 206 Partial Content\r\nContent-Range: bytes {from}-{}/{len}\r\n", len - 1),
                        from,
                    ),
                    None => ("HTTP/1.1 200 OK\r\n".to_string(), 0),
                };
                let reply = format!(
                    "{status}Content-Length: {}\r\nETag: \"v1\"\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n",
                    len - start
                );
                if sock.write_all(reply.as_bytes()).await.is_err() {
                    return;
                }
                let cut = ranged.is_some() && raw.cut_next.swap(false, Ordering::SeqCst);
                let gap = pace(start as u64);
                let mut pos = start;
                while pos < len {
                    let end = (pos + RAW_CHUNK).min(len);
                    if sock.write_all(&data[pos..end]).await.is_err() {
                        return;
                    }
                    pos = end;
                    if cut && pos >= start + (1 << 20) {
                        raw.whole_only.store(true, Ordering::SeqCst);
                        return;
                    }
                    tokio::time::sleep(gap).await;
                }
            });
        }
    });
    addr
}

#[tokio::test]
async fn large_file_splits_into_ranged_connections() {
    setup();
    let srv = big_server().await;
    let dir = tempfile::tempdir().unwrap();
    let (live, rx) = job(format!("{}/big", srv.base), dir.path(), "big.bin");
    let check = live.clone();
    let path = expect_done(run_conn(live, dir.path().to_path_buf(), rx, 4, unlimited()).await);
    assert_eq!(sha(&std::fs::read(&path).unwrap()), sha(&big_data()));
    // Two segments: the first streams on the probe (no Range), the second is a ranged request; growth may add more.
    assert!(srv.ranged_hits.load(Ordering::SeqCst) >= 1);
    assert!(check.job.lock().unwrap().segments.len() >= 2);
}

#[tokio::test]
async fn split_starting_on_one_part_streams_on_the_probe_connection() {
    setup();
    let srv = big_server().await;
    let dir = tempfile::tempdir().unwrap();
    let (live, rx) = job(format!("{}/big", srv.base), dir.path(), "big.bin");
    let check = live.clone();
    let out = download::run(live, reqwest::Client::new(), dir.path(), Arc::new(EventHub::new()), rx, 4, 1, unlimited(), None, None, download::RunOpts::default()).await;
    assert_eq!(sha(&std::fs::read(expect_done(out)).unwrap()), sha(&big_data()));
    // A fast local link finishes before growth's first probe: the probe's response carried the whole file.
    assert_eq!(srv.ranged_hits.load(Ordering::SeqCst), 0, "the probe's stream was not reused");
    assert_eq!(check.job.lock().unwrap().segments.len(), 1);
}

#[tokio::test]
async fn split_pause_then_resume_does_not_rerequest_written_bytes() {
    setup();
    let raw = Arc::new(Raw::default());
    let addr = raw_server(Arc::new(big_data()), raw.clone(), Arc::new(|_: u64| Duration::from_millis(5))).await;
    let dir = tempfile::tempdir().unwrap();
    let (live, rx) = job(format!("http://{addr}/"), dir.path(), "big.bin");
    let handle = tokio::spawn(run_conn(live.clone(), dir.path().to_path_buf(), rx, 4, unlimited()));

    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    while live.done.load(Ordering::Relaxed) < 4 << 20 {
        assert!(std::time::Instant::now() < deadline, "no progress");
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
    let _ = live.cancel.lock().unwrap().send(true);
    let out = tokio::time::timeout(Duration::from_millis(200), handle)
        .await
        .expect("paused within 200 ms")
        .unwrap();
    assert_eq!(out, Outcome::Paused);
    let segments = live.job.lock().unwrap().segments.clone();
    assert!(segments.len() >= 2);
    assert!(segments.iter().all(|s| s.done > 0 && s.start + s.done < s.end), "{segments:?}");

    raw.ranges.lock().unwrap().clear();
    let (tx, rx) = watch::channel(false);
    *live.cancel.lock().unwrap() = tx;
    let path = expect_done(run_conn(live.clone(), dir.path().to_path_buf(), rx, 4, unlimited()).await);
    assert_eq!(sha(&std::fs::read(&path).unwrap()), sha(&big_data()));
    let starts = raw.ranges.lock().unwrap().clone();
    assert!(!starts.is_empty());
    for from in starts {
        assert!(
            segments.iter().any(|s| from > s.start && from < s.end),
            "resume asked for {from}, which is not past any segment's written bytes: {segments:?}"
        );
    }
}

#[tokio::test]
async fn split_falls_back_to_single_stream_when_a_segment_gets_200() {
    setup();
    let raw = Arc::new(Raw::default());
    raw.cut_next.store(true, Ordering::SeqCst);
    let addr = raw_server(Arc::new(big_data()), raw.clone(), Arc::new(|_: u64| Duration::from_millis(2))).await;
    let dir = tempfile::tempdir().unwrap();
    let (live, rx) = job(format!("http://{addr}/"), dir.path(), "big.bin");
    let check = live.clone();
    let path = expect_done(run_conn(live, dir.path().to_path_buf(), rx, 4, unlimited()).await);
    assert_eq!(sha(&std::fs::read(&path).unwrap()), sha(&big_data()));
    assert!(check.job.lock().unwrap().segments.is_empty());
}

#[tokio::test]
async fn server_without_ranges_stays_single_stream() {
    setup();
    let srv = big_server().await;
    let dir = tempfile::tempdir().unwrap();
    let (live, rx) = job(format!("{}/big-noranges", srv.base), dir.path(), "big.bin");
    let check = live.clone();
    let path = expect_done(run_conn(live, dir.path().to_path_buf(), rx, 4, unlimited()).await);
    assert_eq!(sha(&std::fs::read(&path).unwrap()), sha(&big_data()));
    assert!(check.job.lock().unwrap().segments.is_empty());
    assert_eq!(srv.ranged_hits.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn small_file_stays_single_stream() {
    setup();
    let srv = big_server().await;
    let dir = tempfile::tempdir().unwrap();
    let (live, rx) = job(format!("{}/small", srv.base), dir.path(), "small.bin");
    let check = live.clone();
    let path = expect_done(run_conn(live, dir.path().to_path_buf(), rx, 4, unlimited()).await);
    assert_eq!(sha(&std::fs::read(&path).unwrap()), sha(&big_data()[..1 << 20]));
    assert!(check.job.lock().unwrap().segments.is_empty());
}

#[tokio::test]
async fn one_mib_per_second_limit_paces_a_three_mib_download() {
    setup();
    let srv = big_server().await;
    let dir = tempfile::tempdir().unwrap();
    let (live, rx) = job(format!("{}/mid", srv.base), dir.path(), "mid.bin");
    let limiter = Arc::new(RateLimiter::new(1 << 20));
    let started = std::time::Instant::now();
    let path = expect_done(run_conn(live, dir.path().to_path_buf(), rx, 1, limiter).await);
    let took = started.elapsed();
    assert!(took >= Duration::from_secs(2) && took < Duration::from_secs(5), "took {took:?}");
    assert_eq!(sha(&std::fs::read(&path).unwrap()), sha(&big_data()[..3 << 20]));
}

#[tokio::test]
async fn pause_during_throttled_wait_returns_promptly() {
    setup();
    let srv = big_server().await;
    let dir = tempfile::tempdir().unwrap();
    let (live, rx) = job(format!("{}/big", srv.base), dir.path(), "big.bin");
    let cancel_handle = live.clone();
    let handle = tokio::spawn(run_conn(live, dir.path().to_path_buf(), rx, 1, Arc::new(RateLimiter::new(1024))));
    tokio::time::sleep(Duration::from_millis(300)).await;
    let _ = cancel_handle.cancel.lock().unwrap().send(true);
    let out = tokio::time::timeout(Duration::from_millis(200), handle)
        .await
        .expect("paused within 200 ms")
        .unwrap();
    assert_eq!(out, Outcome::Paused);
}

const RANDOM_LEN: usize = 24 << 20;
const SLOW_GAP: Duration = Duration::from_millis(10);

fn random_data() -> Vec<u8> {
    let mut x: u64 = 0x9E37_79B9_7F4A_7C15;
    (0..RANDOM_LEN)
        .map(|_| {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            x as u8
        })
        .collect()
}

/// Ranges starting in the second half of the file trickle; the rest arrive at full speed.
fn second_half_slow() -> Pace {
    Arc::new(|from: u64| if from as usize >= RANDOM_LEN / 2 { SLOW_GAP } else { Duration::ZERO })
}

#[tokio::test]
async fn idle_connections_steal_from_slow_second_half() {
    setup();
    let data = Arc::new(random_data());
    let addr = raw_server(data.clone(), Arc::new(Raw::default()), second_half_slow()).await;
    let dir = tempfile::tempdir().unwrap();
    let (live, rx) = job(format!("http://{addr}/"), dir.path(), "big.bin");
    let check = live.clone();
    let path = expect_done(run_conn(live, dir.path().to_path_buf(), rx, 4, unlimited()).await);
    assert_eq!(sha(&std::fs::read(&path).unwrap()), sha(&data));
    assert!(check.job.lock().unwrap().segments.len() > 2);
}

#[tokio::test]
async fn pause_during_stealing_then_resume_is_correct() {
    setup();
    let data = Arc::new(random_data());
    let addr = raw_server(data.clone(), Arc::new(Raw::default()), second_half_slow()).await;
    let dir = tempfile::tempdir().unwrap();
    let (live, rx) = job(format!("http://{addr}/"), dir.path(), "big.bin");
    let handle = tokio::spawn(run_conn(live.clone(), dir.path().to_path_buf(), rx, 4, unlimited()));

    let deadline = Instant::now() + Duration::from_secs(10);
    while live.job.lock().unwrap().segments.len() <= 2 {
        assert!(Instant::now() < deadline, "no split happened");
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
    let _ = live.cancel.lock().unwrap().send(true);
    let out = tokio::time::timeout(Duration::from_millis(200), handle)
        .await
        .expect("paused within 200 ms")
        .unwrap();
    assert_eq!(out, Outcome::Paused);

    let (tx, rx) = watch::channel(false);
    *live.cancel.lock().unwrap() = tx;
    let path = expect_done(run_conn(live.clone(), dir.path().to_path_buf(), rx, 4, unlimited()).await);
    assert_eq!(sha(&std::fs::read(&path).unwrap()), sha(&data));
    assert!(live.job.lock().unwrap().segments.len() > 2);
}

/// Admits two ranged requests at a time; a third concurrent one gets 429 at once.
#[derive(Default)]
struct Gate {
    active: Mutex<usize>,
    rejected: AtomicUsize,
    /// Highest concurrent count (admitted plus the refused one) seen by arrivals after the first 429.
    peak_after_429: AtomicUsize,
}

async fn read_head(sock: &mut tokio::net::TcpStream) -> Option<String> {
    let mut head = Vec::new();
    let mut byte = [0u8; 1];
    while !head.ends_with(b"\r\n\r\n") {
        match sock.read(&mut byte).await {
            Ok(1) => head.push(byte[0]),
            _ => return None,
        }
    }
    Some(String::from_utf8_lossy(&head).to_lowercase())
}

async fn gate_server(data: Arc<Vec<u8>>, gate: Arc<Gate>) -> SocketAddr {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        while let Ok((mut sock, _)) = listener.accept().await {
            let (data, gate) = (data.clone(), gate.clone());
            tokio::spawn(async move {
                let Some(text) = read_head(&mut sock).await else { return };
                let from = text
                    .lines()
                    .find_map(|l| l.strip_prefix("range: bytes="))
                    .and_then(|r| r.trim().split('-').next())
                    .and_then(|n| n.parse::<usize>().ok());
                let Some(from) = from else {
                    // The probe that plans the split: headers only, the client drops the body.
                    let head = format!(
                        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nAccept-Ranges: bytes\r\nETag: \"v1\"\r\nConnection: close\r\n\r\n",
                        data.len()
                    );
                    let _ = sock.write_all(head.as_bytes()).await;
                    return;
                };
                let admitted = {
                    let mut active = gate.active.lock().unwrap();
                    let seen = *active + 1;
                    if gate.rejected.load(Ordering::SeqCst) > 0 {
                        gate.peak_after_429.fetch_max(seen, Ordering::SeqCst);
                    }
                    if *active >= 2 {
                        gate.rejected.fetch_add(1, Ordering::SeqCst);
                        false
                    } else {
                        *active += 1;
                        true
                    }
                };
                if !admitted {
                    let _ = sock
                        .write_all(b"HTTP/1.1 429 Too Many Requests\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                        .await;
                    return;
                }
                let len = data.len();
                let head = format!(
                    "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes {from}-{}/{len}\r\nContent-Length: {}\r\nETag: \"v1\"\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n",
                    len - 1,
                    len - from
                );
                if sock.write_all(head.as_bytes()).await.is_ok() {
                    for chunk in data[from..].chunks(RAW_CHUNK) {
                        if sock.write_all(chunk).await.is_err() {
                            break;
                        }
                        // Slow enough that the download outlasts the first probe, about 4 s in.
                        tokio::time::sleep(Duration::from_millis(40)).await;
                    }
                }
                *gate.active.lock().unwrap() -= 1;
            });
        }
    });
    addr
}

#[tokio::test]
async fn throttled_split_parks_segments_and_still_completes() {
    setup();
    let data = Arc::new(big_data());
    let gate = Arc::new(Gate::default());
    let addr = gate_server(data.clone(), gate.clone()).await;
    let dir = tempfile::tempdir().unwrap();
    let (live, rx) = job(format!("http://{addr}/"), dir.path(), "big.bin");
    let path = expect_done(run_conn(live, dir.path().to_path_buf(), rx, 4, unlimited()).await);
    assert_eq!(sha(&std::fs::read(&path).unwrap()), sha(&data));
    assert!(gate.rejected.load(Ordering::SeqCst) > 0, "server never answered 429");
    let peak = gate.peak_after_429.load(Ordering::SeqCst);
    assert!(peak <= 3, "{peak} concurrent requests after the first 429");
}

#[tokio::test]
async fn retry_after_429_on_single_connection_waits_then_succeeds() {
    setup();
    async fn once_throttled(State(hits): State<Arc<AtomicUsize>>) -> Response {
        if hits.fetch_add(1, Ordering::SeqCst) == 0 {
            return Response::builder()
                .status(StatusCode::TOO_MANY_REQUESTS)
                .header(header::RETRY_AFTER, "1")
                .body(Body::empty())
                .unwrap();
        }
        Response::builder().body(Body::from(data())).unwrap()
    }
    let hits = Arc::new(AtomicUsize::new(0));
    let app = Router::new().route("/once", get(once_throttled)).with_state(hits.clone());
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let dir = tempfile::tempdir().unwrap();
    let (live, rx) = job(format!("http://{addr}/once"), dir.path(), "data.bin");
    let started = Instant::now();
    let path = expect_done(run_job(live, dir.path(), rx).await);
    let took = started.elapsed();
    assert!(took >= Duration::from_secs(1) && took < Duration::from_secs(5), "took {took:?}");
    assert_eq!(hits.load(Ordering::SeqCst), 2);
    assert_eq!(sha(&std::fs::read(&path).unwrap()), sha(&data()));
}

#[tokio::test]
async fn speed_limit_plans_at_most_two_segments() {
    setup();
    let srv = big_server().await;
    let dir = tempfile::tempdir().unwrap();
    let (live, rx) = job(format!("{}/big", srv.base), dir.path(), "big.bin");
    let limiter = Arc::new(RateLimiter::new(2 << 20));
    let handle = tokio::spawn(run_conn(live.clone(), dir.path().to_path_buf(), rx, 8, limiter));
    let deadline = Instant::now() + Duration::from_secs(10);
    while live.done.load(Ordering::Relaxed) == 0 {
        assert!(Instant::now() < deadline, "no progress");
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
    let planned = live.job.lock().unwrap().segments.len();
    let _ = live.cancel.lock().unwrap().send(true);
    tokio::time::timeout(Duration::from_millis(200), handle)
        .await
        .expect("paused within 200 ms")
        .unwrap();
    assert_eq!(planned, 2);
}

/// Paced origin for the adaptive tests: `gap` per chunk on each connection, an optional bandwidth budget shared
/// by all of them, and an optional admission limit (a ranged request beyond it gets 429).
struct Link {
    data: Arc<Vec<u8>>,
    gap: Duration,
    /// (total bytes sent after which, bytes per second shared by all connections).
    shared: Option<(usize, f64)>,
    admit: Option<usize>,
    next_free: Mutex<Instant>,
    active: AtomicUsize,
    sent: AtomicUsize,
    rejected: AtomicUsize,
}

impl Link {
    fn new(data: Arc<Vec<u8>>, gap: Duration, shared: Option<(usize, f64)>, admit: Option<usize>) -> Arc<Link> {
        Arc::new(Link {
            data,
            gap,
            shared,
            admit,
            next_free: Mutex::new(Instant::now()),
            active: AtomicUsize::new(0),
            sent: AtomicUsize::new(0),
            rejected: AtomicUsize::new(0),
        })
    }
}

struct Leave<'a>(&'a AtomicUsize);

impl Drop for Leave<'_> {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::SeqCst);
    }
}

async fn link_server(link: Arc<Link>) -> SocketAddr {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        while let Ok((mut sock, _)) = listener.accept().await {
            let link = link.clone();
            tokio::spawn(async move { serve_link(&link, &mut sock).await });
        }
    });
    addr
}

async fn serve_link(link: &Link, sock: &mut tokio::net::TcpStream) {
    let Some(text) = read_head(sock).await else { return };
    let len = link.data.len();
    let range = text.lines().find_map(|l| l.strip_prefix("range: bytes=")).and_then(|r| {
        let (from, to) = r.trim().split_once('-')?;
        Some((from.parse::<usize>().ok()?, to.parse::<usize>().unwrap_or(len - 1).min(len - 1)))
    });
    // Each ranged response ends at its range end, so a finished segment's connection closes with it.
    let _leave = range.map(|_| {
        link.active.fetch_add(1, Ordering::SeqCst);
        Leave(&link.active)
    });
    if let (Some(_), Some(n)) = (range, link.admit)
        && link.active.load(Ordering::SeqCst) > n
    {
        link.rejected.fetch_add(1, Ordering::SeqCst);
        let _ = sock.write_all(b"HTTP/1.1 429 Too Many Requests\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").await;
        return;
    }
    let (from, to) = range.unwrap_or((0, len - 1));
    let head = match range {
        Some(_) => format!(
            "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes {from}-{to}/{len}\r\nContent-Length: {}\r\nETag: \"v1\"\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n",
            to - from + 1
        ),
        None => format!("HTTP/1.1 200 OK\r\nContent-Length: {len}\r\nAccept-Ranges: bytes\r\nETag: \"v1\"\r\nConnection: close\r\n\r\n"),
    };
    if sock.write_all(head.as_bytes()).await.is_err() {
        return;
    }
    for chunk in link.data[from..=to].chunks(RAW_CHUNK) {
        let wait = match link.shared {
            Some((after, rate)) if link.sent.load(Ordering::SeqCst) >= after => {
                let mut free = link.next_free.lock().unwrap();
                let at = (*free).max(Instant::now());
                *free = at + Duration::from_secs_f64(chunk.len() as f64 / rate);
                at.saturating_duration_since(Instant::now())
            }
            _ => link.gap,
        };
        tokio::time::sleep(wait).await;
        if sock.write_all(chunk).await.is_err() {
            return;
        }
        link.sent.fetch_add(chunk.len(), Ordering::SeqCst);
    }
}

/// Connections and bytes done, sampled every 2 ms from `start` until `finish`.
struct Sampler {
    hist: Arc<Mutex<Vec<(usize, u64)>>>,
    stop: Arc<AtomicBool>,
}

impl Sampler {
    fn start(live: Arc<Live>) -> Sampler {
        let hist = Arc::new(Mutex::new(Vec::new()));
        let stop = Arc::new(AtomicBool::new(false));
        let (h, s) = (hist.clone(), stop.clone());
        tokio::spawn(async move {
            while !s.load(Ordering::SeqCst) {
                let point = (live.connections.load(Ordering::Relaxed) as usize, live.done.load(Ordering::Relaxed));
                h.lock().unwrap().push(point);
                tokio::time::sleep(Duration::from_millis(2)).await;
            }
        });
        Sampler { hist, stop }
    }

    fn finish(self) -> Vec<(usize, u64)> {
        self.stop.store(true, Ordering::SeqCst);
        self.hist.lock().unwrap().clone()
    }
}

fn peak(hist: &[(usize, u64)]) -> usize {
    hist.iter().map(|p| p.0).max().unwrap_or(0)
}

/// The connection count fell before the last tenth of the file (not as segments finished at the end).
fn stepped_down(hist: &[(usize, u64)], total: u64) -> bool {
    hist.windows(2).any(|w| w[1].0 < w[0].0 && w[1].1 < total * 9 / 10)
}

#[tokio::test]
async fn per_connection_limit_grows_past_three() {
    setup();
    let data = Arc::new(sized_data(32 << 20));
    let link = Link::new(data.clone(), Duration::from_micros(62_500), None, None);
    let addr = link_server(link).await;
    let dir = tempfile::tempdir().unwrap();
    let (live, rx) = job(format!("http://{addr}/"), dir.path(), "big.bin");
    let sampler = Sampler::start(live.clone());
    // Starts on one part, as the app does, and must still climb on a link that limits each connection.
    let out = download::run(live, reqwest::Client::new(), dir.path(), Arc::new(EventHub::new()), rx, 6, 1, unlimited(), None, None, download::RunOpts::default()).await;
    let path = expect_done(out);
    let hist = sampler.finish();
    assert_eq!(sha(&std::fs::read(&path).unwrap()), sha(&data));
    let peak = peak(&hist);
    assert!(peak >= 4, "only {peak} connections");
}

#[tokio::test]
async fn shared_bandwidth_limit_removes_a_failed_probe() {
    setup();
    let data = Arc::new(big_data());
    let link = Link::new(data.clone(), Duration::ZERO, Some((0, 2.0 * MIB)), None);
    let addr = link_server(link).await;
    let dir = tempfile::tempdir().unwrap();
    let (live, rx) = job(format!("http://{addr}/"), dir.path(), "big.bin");
    let sampler = Sampler::start(live.clone());
    let path = expect_done(run_conn(live, dir.path().to_path_buf(), rx, 8, unlimited()).await);
    let hist = sampler.finish();
    assert_eq!(sha(&std::fs::read(&path).unwrap()), sha(&data));
    let total = data.len() as u64;
    assert!(peak(&hist) >= 3, "never probed above two connections");
    assert!(stepped_down(&hist, total), "the failed probe was not removed");
    // Two, plus at most the one connection of a periodic probe that may be running when the file ends.
    let late = hist.iter().filter(|p| p.1 >= total * 17 / 20).map(|p| p.0).max().unwrap_or(0);
    assert!(late <= 3, "{late} connections near the end");
}

#[tokio::test]
async fn slowdown_to_a_shared_limit_steps_the_count_down() {
    setup();
    let data = Arc::new(sized_data(24 << 20));
    let link = Link::new(data.clone(), Duration::from_micros(62_500), Some((6 << 20, 2.0 * MIB)), None);
    let addr = link_server(link).await;
    let dir = tempfile::tempdir().unwrap();
    let (live, rx) = job(format!("http://{addr}/"), dir.path(), "big.bin");
    let sampler = Sampler::start(live.clone());
    let path = expect_done(run_conn(live, dir.path().to_path_buf(), rx, 8, unlimited()).await);
    let hist = sampler.finish();
    assert_eq!(sha(&std::fs::read(&path).unwrap()), sha(&data));
    assert!(peak(&hist) >= 3, "never probed above two connections");
    assert!(stepped_down(&hist, data.len() as u64), "the count never stepped down");
}

#[tokio::test]
async fn rate_limit_429_is_remembered_and_caps_the_next_download() {
    setup();
    let data = Arc::new(big_data());
    let link = Link::new(data.clone(), Duration::from_millis(50), None, Some(2));
    let addr = link_server(link.clone()).await;
    let dir = tempfile::tempdir().unwrap();
    let store = Arc::new(dl_engine::store::Store::open(&dir.path().join("data")).unwrap());
    let host = "127.0.0.1";

    let (live, rx) = job(format!("http://{addr}/"), dir.path(), "first.bin");
    let out = download::run(live, reqwest::Client::new(), dir.path(), Arc::new(EventHub::new()), rx, 8, 2, unlimited(), Some(store.clone()), None, download::RunOpts::default()).await;
    assert_eq!(sha(&std::fs::read(expect_done(out)).unwrap()), sha(&data));
    assert!(link.rejected.load(Ordering::SeqCst) > 0, "server never answered 429");
    let (max, _) = store.host_limit(host).unwrap().expect("limit remembered");
    assert!(max <= 2, "remembered {max}");

    let (live, rx) = job(format!("http://{addr}/"), dir.path(), "second.bin");
    let sampler = Sampler::start(live.clone());
    let out = download::run(live, reqwest::Client::new(), dir.path(), Arc::new(EventHub::new()), rx, 8, 2, unlimited(), Some(store.clone()), None, download::RunOpts::default()).await;
    let hist = sampler.finish();
    assert_eq!(sha(&std::fs::read(expect_done(out)).unwrap()), sha(&data));
    let peak = peak(&hist);
    assert!(peak <= max as usize, "{peak} connections against a limit of {max}");

    store.forget_host(host).unwrap();
    assert_eq!(store.host_limit(host).unwrap(), None);
}

#[tokio::test]
async fn clean_split_under_a_remembered_limit_relaxes_it_by_one() {
    setup();
    let data = Arc::new(big_data());
    let link = Link::new(data.clone(), Duration::from_millis(50), None, None);
    let addr = link_server(link).await;
    let dir = tempfile::tempdir().unwrap();
    let store = Arc::new(dl_engine::store::Store::open(&dir.path().join("data")).unwrap());
    let host = "127.0.0.1";
    store.note_host(host, 3, "rate limited").unwrap();

    let (live, rx) = job(format!("http://{addr}/"), dir.path(), "big.bin");
    let sampler = Sampler::start(live.clone());
    let out = download::run(live, reqwest::Client::new(), dir.path(), Arc::new(EventHub::new()), rx, 8, 2, unlimited(), Some(store.clone()), None, download::RunOpts::default()).await;
    let hist = sampler.finish();
    assert_eq!(sha(&std::fs::read(expect_done(out)).unwrap()), sha(&data));
    let peak = peak(&hist);
    assert!(peak <= 3, "{peak} connections against a limit of 3");
    assert_eq!(store.host_limit(host).unwrap().map(|l| l.0), Some(4));
}
#[tokio::test]
async fn replace_off_keeps_both() {
    setup();
    let srv = start().await;
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join("a.bin"), b"old").unwrap();
    let (live, rx) = job(srv.url("/file"), dir.path(), "a.bin");
    let path = expect_done(run_replacing(live, dir.path(), rx, download::RunOpts::default()).await);
    assert_eq!(path, dir.path().join("a (1).bin"));
    assert_eq!(std::fs::read(dir.path().join("a.bin")).unwrap(), b"old");
    assert_eq!(sha(&std::fs::read(&path).unwrap()), sha(&data()));
}
#[tokio::test]
async fn replace_on_moves_old_to_trash() {
    setup();
    let srv = start().await;
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join("a.bin"), b"old").unwrap();
    let (live, rx) = job(srv.url("/file"), dir.path(), "a.bin");
    let opts = download::RunOpts { replace_existing: true, trash: fake_trash, ..Default::default() };
    let path = expect_done(run_replacing(live, dir.path(), rx, opts).await);
    assert_eq!(path, dir.path().join("a.bin"));
    assert_eq!(sha(&std::fs::read(&path).unwrap()), sha(&data()));
    assert!(!dir.path().join("a (1).bin").exists());
    assert_eq!(trashed_in(dir.path()), [dir.path().join("a.bin")]);
}
#[tokio::test]
async fn replace_never_trashes_a_directory() {
    setup();
    let srv = start().await;
    let dir = tempfile::tempdir().unwrap();
    std::fs::create_dir(dir.path().join("a")).unwrap();
    let (live, rx) = job(srv.url("/file"), dir.path(), "a");
    let opts = download::RunOpts { replace_existing: true, trash: fake_trash, ..Default::default() };
    let path = expect_done(run_replacing(live, dir.path(), rx, opts).await);
    assert_eq!(path, dir.path().join("a (1)"));
    assert!(dir.path().join("a").is_dir());
    assert!(trashed_in(dir.path()).is_empty());
}
#[tokio::test]
async fn replace_spares_a_file_this_engine_produced() {
    setup();
    let srv = start().await;
    let dir = tempfile::tempdir().unwrap();
    // The second job starts first, and a slow link keeps it running until the first has produced a.bin.
    // It starts before that file exists, so it must not trash it.
    let (second, rx2) = job_with_id(srv.url("/file"), dir.path(), "a.bin", 2);
    let opts = download::RunOpts { replace_existing: true, trash: fake_trash, ..Default::default() };
    let late_dir = dir.path().to_path_buf();
    let slow = Arc::new(RateLimiter::new(1 << 20));
    let late = tokio::spawn(async move {
        download::run(second, reqwest::Client::new(), &late_dir, Arc::new(EventHub::new()), rx2, 1, 1, slow, None, None, opts).await
    });
    let (first, rx) = job(srv.url("/file"), dir.path(), "a.bin");
    expect_done(run_replacing(first, dir.path(), rx, download::RunOpts::default()).await);
    std::fs::write(dir.path().join("a.bin"), b"first").unwrap();
    let path = expect_done(late.await.unwrap());
    assert_eq!(path, dir.path().join("a (1).bin"));
    assert_eq!(std::fs::read(dir.path().join("a.bin")).unwrap(), b"first");
    assert_eq!(sha(&std::fs::read(&path).unwrap()), sha(&data()));
    assert!(trashed_in(dir.path()).is_empty());
}
#[tokio::test]
async fn replace_takes_a_file_from_a_job_started_after_it() {
    setup();
    let srv = start().await;
    let dir = tempfile::tempdir().unwrap();
    let (first, rx) = job(srv.url("/file"), dir.path(), "a.bin");
    expect_done(run_replacing(first, dir.path(), rx, download::RunOpts::default()).await);
    std::fs::write(dir.path().join("a.bin"), b"first").unwrap();
    let (live, rx) = job(srv.url("/file"), dir.path(), "a.bin");
    let opts = download::RunOpts { replace_existing: true, trash: fake_trash, ..Default::default() };
    let path = expect_done(run_replacing(live, dir.path(), rx, opts).await);
    assert_eq!(path, dir.path().join("a.bin"));
    assert_eq!(sha(&std::fs::read(&path).unwrap()), sha(&data()));
    assert_eq!(trashed_in(dir.path()), [dir.path().join("a.bin")]);
}
#[tokio::test]
async fn replace_on_keeps_old_when_trash_fails() {
    setup();
    let srv = start().await;
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join("a.bin"), b"old").unwrap();
    let (live, rx) = job(srv.url("/file"), dir.path(), "a.bin");
    let opts = download::RunOpts { replace_existing: true, trash: failing_trash, ..Default::default() };
    let path = expect_done(run_replacing(live, dir.path(), rx, opts).await);
    assert_eq!(path, dir.path().join("a (1).bin"));
    assert_eq!(std::fs::read(dir.path().join("a.bin")).unwrap(), b"old");
    assert_eq!(sha(&std::fs::read(&path).unwrap()), sha(&data()));
}

#[test]
fn snapshot_carries_job_dir() {
    let root = tempfile::tempdir().unwrap();
    let engine = engine_in(root.path());
    let dest = root.path().join("m/sub");
    let add = engine.add_to(vec!["https://example.com/f.bin".into()], Some(dest.to_string_lossy().into_owned()), vec![Some("w.bin".into())]);
    assert!(add[0].id.is_some(), "{add:?}");
    let snap = engine.snapshot();
    assert_eq!(snap[0].dir, Some(dest.to_string_lossy().into_owned()));
}

#[tokio::test]
async fn verifying_shows_while_the_hash_runs_and_ignores_pause() {
    setup();
    let dir = tempfile::tempdir().unwrap();
    let big = dir.path().join("big.bin");
    std::fs::File::create(&big).unwrap().set_len(32 << 20).unwrap();
    let app = Router::new().route_service("/big", tower_http::services::ServeFile::new(big));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}/big", listener.local_addr().unwrap());
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });

    let (live, rx) = job(url, dir.path(), "out.bin");
    live.job.lock().unwrap().sha256 = Some("0".repeat(64));
    let watched = live.clone();
    let run_dir = dir.path().to_path_buf();
    let run = tokio::spawn(async move { run_replacing(live, &run_dir, rx, download::RunOpts::default()).await });
    let mut seen = false;
    while !run.is_finished() {
        if matches!(watched.job.lock().unwrap().state, JobState::Verifying) {
            seen = true;
            watched.cancel.lock().unwrap().send_replace(true);
            break;
        }
        tokio::time::sleep(Duration::from_millis(2)).await;
    }
    let out = run.await.unwrap();
    assert!(seen, "the job never showed Verifying");
    assert!(matches!(&out, Outcome::Failed(m) if m == "Checksum didn't match"), "{out:?}");
}

#[tokio::test]
async fn paused_job_does_not_trash_what_it_raced() {
    setup();
    let srv = start().await;
    let dir = tempfile::tempdir().unwrap();
    let (a, rx) = job_with_id(srv.url("/file"), dir.path(), "a.bin", 1);
    a.cancel.lock().unwrap().send_replace(true);
    assert_eq!(run_replacing(a.clone(), dir.path(), rx, download::RunOpts::default()).await, Outcome::Paused);

    let (b, rx) = job_with_id(srv.url("/file"), dir.path(), "a.bin", 2);
    expect_done(run_replacing(b, dir.path(), rx, download::RunOpts::default()).await);

    a.cancel.lock().unwrap().send_replace(false);
    let rx = a.cancel.lock().unwrap().subscribe();
    let opts = download::RunOpts { replace_existing: true, trash: fake_trash, ..Default::default() };
    let path = expect_done(run_replacing(a, dir.path(), rx, opts).await);
    assert_eq!(path, dir.path().join("a (1).bin"));
    assert_eq!(sha(&std::fs::read(dir.path().join("a.bin")).unwrap()), sha(&data()));
    assert!(trashed_in(dir.path()).is_empty());
}
