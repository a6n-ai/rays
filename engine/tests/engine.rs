//! Engine behaviour through the public API: jobs, restart, pause/remove, and the socket protocol.
//! The origin server runs on std threads (blocking sockets), so no test needs a runtime of its own
//! except the one `drain_until_done` builds for `next_events`.
use dl_engine::protocol::Response;
use dl_engine::store::Store;
use dl_engine::{Engine, EngineConfig, EngineError, HttpHeader, JobEvent, JobId, JobState, JobView};
use sha2::{Digest, Sha256};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, Once};
use std::thread;
use std::time::{Duration, Instant};
use tempfile::TempDir;

const SIZE: usize = 1 << 20;
/// Large enough to split across connections.
const BIG: usize = 20 << 20;
const CHUNK: usize = 64 << 10;
/// Stalling routes send this many bytes, then go silent.
const STALL_AT: usize = 256 << 10;
/// Pause between chunks, so a download lasts long enough to observe its Running state.
const PACE: Duration = Duration::from_millis(10);
const WAIT: Duration = Duration::from_secs(10);

fn setup() {
    static ONCE: Once = Once::new();
    // SAFETY: runs once, before any engine or download in this test binary reads the environment.
    ONCE.call_once(|| unsafe { std::env::set_var("DL_RETRY_SCALE_MS", "1") });
}

fn payload() -> Vec<u8> {
    payload_of(SIZE)
}

fn big_payload() -> Vec<u8> {
    payload_of(BIG)
}

fn payload_of(len: usize) -> Vec<u8> {
    (0..len).map(|i| ((i * 7 + i / 256) % 256) as u8).collect()
}

fn sha(bytes: &[u8]) -> Vec<u8> {
    Sha256::digest(bytes).as_slice().to_vec()
}

fn sha_of(path: &Path) -> Vec<u8> {
    sha(&std::fs::read(path).expect("read final file"))
}

/// Origin on a std thread. `/flaky/*` is like `/file/*` but answers 500 to any range that does not start at byte 0. Paths: `/file/*` honours Range and sends an ETag; `/noranges/*` always
/// answers 200 with no Accept-Ranges. While `stall` is set, a response sends `STALL_AT` bytes and then
/// goes silent until the client gives up.
struct Origin {
    addr: SocketAddr,
    stall: Arc<AtomicBool>,
    /// The lowercased request head of every request received.
    seen: Arc<Mutex<Vec<String>>>,
}

impl Origin {
    fn start() -> Origin {
        Origin::serve_data(Arc::new(payload()))
    }

    fn start_big() -> Origin {
        Origin::serve_data(Arc::new(big_payload()))
    }

    fn serve_data(data: Arc<Vec<u8>>) -> Origin {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind origin");
        let addr = listener.local_addr().expect("origin addr");
        let stall = Arc::new(AtomicBool::new(false));
        let flag = stall.clone();
        let seen = Arc::new(Mutex::new(Vec::new()));
        let log = seen.clone();
        thread::spawn(move || {
            for conn in listener.incoming().flatten() {
                let (data, stalling, log) = (data.clone(), flag.load(Ordering::SeqCst), log.clone());
                thread::spawn(move || serve(conn, &data, stalling, &log));
            }
        });
        Origin { addr, stall, seen }
    }

    fn url(&self, path: &str) -> String {
        format!("http://{}{path}", self.addr)
    }

    fn requests(&self) -> Vec<String> {
        self.seen.lock().unwrap().clone()
    }

    fn set_stall(&self, on: bool) {
        self.stall.store(on, Ordering::SeqCst);
    }
}

fn serve(mut sock: TcpStream, data: &[u8], stalling: bool, log: &Mutex<Vec<String>>) {
    let mut head = Vec::new();
    let mut byte = [0u8; 1];
    while !head.ends_with(b"\r\n\r\n") {
        match sock.read(&mut byte) {
            Ok(1) => head.push(byte[0]),
            _ => return,
        }
    }
    let text = String::from_utf8_lossy(&head).to_lowercase();
    log.lock().unwrap().push(text.clone());
    let path = text.split_whitespace().nth(1).unwrap_or("/").to_string();
    if let Some(rest) = path.strip_prefix("/to/") {
        // /to/PORT/path: a redirect to another origin on this machine.
        let (port, tail) = rest.split_once('/').unwrap_or((rest, ""));
        let _ = sock.write_all(format!("HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:{port}/{tail}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").as_bytes());
        return;
    }
    if let Some(tail) = path.strip_prefix("/same/") {
        let _ = sock.write_all(format!("HTTP/1.1 302 Found\r\nLocation: /{tail}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").as_bytes());
        return;
    }
    let ranges = !path.starts_with("/noranges/");
    let from = text
        .lines()
        .find_map(|l| l.strip_prefix("range: bytes="))
        .and_then(|r| r.trim().split('-').next())
        .and_then(|n| n.parse::<usize>().ok())
        .filter(|_| ranges);
    if path.starts_with("/flaky/") && from.is_some_and(|f| f > 0) {
        let _ = sock.write_all(b"HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        return;
    }
    let start = from.unwrap_or(0).min(data.len());
    let partial = from.is_some();

    let mut reply = if partial {
        format!("HTTP/1.1 206 Partial Content\r\nContent-Range: bytes {start}-{}/{}\r\n", data.len() - 1, data.len())
    } else {
        "HTTP/1.1 200 OK\r\n".to_string()
    };
    reply += &format!("Content-Length: {}\r\nETag: \"v1\"\r\nConnection: close\r\n", data.len() - start);
    if path.starts_with("/html/") {
        reply += "Content-Type: text/html\r\n";
    }
    if ranges {
        reply += "Accept-Ranges: bytes\r\n";
    }
    reply += "\r\n";
    if sock.write_all(reply.as_bytes()).is_err() {
        return;
    }

    let stop = if stalling { STALL_AT.max(start) } else { data.len() };
    let mut pos = start;
    while pos < stop {
        let end = (pos + CHUNK).min(stop);
        if sock.write_all(&data[pos..end]).is_err() {
            return;
        }
        pos = end;
        thread::sleep(PACE);
    }
    if stalling {
        thread::sleep(Duration::from_secs(120));
    }
}

fn tmp() -> TempDir {
    tempfile::Builder::new().tempdir_in("/tmp").expect("tempdir under /tmp")
}

fn config(root: &Path, max_running: u32) -> EngineConfig {
    let downloads = root.join("downloads");
    std::fs::create_dir_all(&downloads).expect("downloads dir");
    EngineConfig {
        downloads_dir: downloads.to_string_lossy().into_owned(),
        data_dir: root.join("data").to_string_lossy().into_owned(),
        socket_path: root.join("dl.sock").to_string_lossy().into_owned(),
        max_running,
        connections: 1,
        speed_limit: 0,
        hf_base: None,
    }
}

fn start(cfg: EngineConfig) -> Arc<Engine> {
    Engine::new(cfg).expect("engine starts")
}

fn add_one(engine: &Engine, url: String) -> JobId {
    engine.add(vec![url]).remove(0).id.expect("url accepted")
}

fn view(engine: &Engine, id: JobId) -> Option<JobView> {
    engine.snapshot().into_iter().find(|j| j.id == id)
}

/// Polls the snapshot until `ok` holds. Panics on timeout or if the job fails.
fn wait_view(engine: &Engine, id: JobId, what: &str, ok: impl Fn(&JobView) -> bool) -> JobView {
    let deadline = Instant::now() + WAIT;
    loop {
        if let Some(v) = view(engine, id) {
            assert!(!matches!(v.state, JobState::Failed { .. }), "job failed while waiting for {what}: {v:?}");
            if ok(&v) {
                return v;
            }
        }
        assert!(Instant::now() < deadline, "timed out waiting for {what}: {:?}", view(engine, id));
        thread::sleep(Duration::from_millis(5));
    }
}

fn wait_done(engine: &Engine, id: JobId) -> PathBuf {
    match wait_view(engine, id, "done", |v| matches!(v.state, JobState::Done { .. })).state {
        JobState::Done { path } => PathBuf::from(path),
        other => panic!("expected Done, got {other:?}"),
    }
}

/// Calls `next_events` until a Done upsert for `id` arrives; returns everything seen.
fn drain_until_done(engine: &Engine, id: JobId) -> Vec<JobEvent> {
    let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().expect("test runtime");
    rt.block_on(async {
        let mut seen = Vec::new();
        loop {
            let batch = tokio::time::timeout(WAIT, engine.next_events()).await.expect("event within 10 s");
            seen.extend(batch);
            let done = seen.iter().any(|e| {
                matches!(e, JobEvent::Upsert { job } if job.id == id && matches!(job.state, JobState::Done { .. }))
            });
            if done {
                return seen;
            }
        }
    })
}

fn partial_files(dir: &Path) -> Vec<String> {
    std::fs::read_dir(dir)
        .expect("read downloads dir")
        .map(|e| e.expect("dir entry").file_name().to_string_lossy().into_owned())
        .filter(|n| n.ends_with(".part"))
        .collect()
}

#[test]
fn add_downloads_file_with_matching_sha() {
    setup();
    let origin = Origin::start();
    let root = tmp();
    let engine = start(config(root.path(), 2));
    let id = add_one(&engine, origin.url("/file/x.bin"));

    let events = drain_until_done(&engine, id);
    let saw_running = events
        .iter()
        .any(|e| matches!(e, JobEvent::Upsert { job } if job.id == id && job.state == JobState::Running));
    assert!(saw_running, "no Running upsert in {events:?}");

    let path = wait_done(&engine, id);
    assert_eq!(path, root.path().join("downloads/x.bin"));
    assert_eq!(sha_of(&path), sha(&payload()));
    engine.shutdown();
}

fn relink(engine: &Engine, id: JobId, url: String, restart: bool) -> Result<(), EngineError> {
    let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().expect("test runtime");
    rt.block_on(engine.relink(id, url, restart))
}

/// A job stalled after `STALL_AT` bytes on `origin`, paused, with its bytes on disk.
fn paused_with_bytes(engine: &Engine, origin: &Origin) -> (JobId, u64) {
    origin.set_stall(true);
    let id = add_one(engine, origin.url("/file/x.bin"));
    wait_view(engine, id, "running with bytes", |v| v.state == JobState::Running && v.done > 0);
    engine.pause(id);
    let v = wait_view(engine, id, "paused", |v| v.state == JobState::Paused);
    (id, v.done)
}

#[test]
fn relink_with_the_same_size_keeps_the_bytes_and_resumes() {
    setup();
    let (old, new) = (Origin::start(), Origin::start());
    let root = tmp();
    let engine = start(config(root.path(), 2));
    let (id, kept) = paused_with_bytes(&engine, &old);
    assert!(kept > 0);
    relink(&engine, id, new.url("/file/x.bin"), false).expect("relink");
    let v = view(&engine, id).unwrap();
    assert_eq!(v.done, kept);
    assert_eq!(v.url, new.url("/file/x.bin"));
    let path = wait_done(&engine, id);
    assert_eq!(sha_of(&path), sha(&payload()));
    engine.shutdown();
}

#[test]
fn relink_with_a_different_size_needs_a_restart() {
    setup();
    let old = Origin::start();
    let other = payload_of(SIZE + 4096);
    let new = Origin::serve_data(Arc::new(other.clone()));
    let root = tmp();
    let engine = start(config(root.path(), 2));
    let (id, kept) = paused_with_bytes(&engine, &old);
    assert!(kept > 0);
    let part = std::fs::read_dir(root.path().join("downloads")).unwrap().flatten().map(|e| e.path()).find(|p| p.extension().is_some_and(|e| e == "part")).expect("a .part");
    let err = relink(&engine, id, new.url("/file/x.bin"), false).expect_err("different file is refused");
    assert!(err.to_string().contains("The new link is a different file"), "{err}");
    assert!(part.exists());
    let v = view(&engine, id).unwrap();
    assert_eq!((v.done, v.url.as_str(), &v.state), (kept, old.url("/file/x.bin").as_str(), &JobState::Paused));
    assert!(relink(&engine, id, new.url("/html/x.bin"), true).unwrap_err().to_string().contains("web page"));
    relink(&engine, id, new.url("/file/x.bin"), true).expect("relink with restart");
    assert!(view(&engine, id).unwrap().done < kept);
    let path = wait_done(&engine, id);
    assert_eq!(sha_of(&path), sha(&other));
    assert!(relink(&engine, id, new.url("/file/x.bin"), true).is_err(), "a finished job cannot be relinked");
    engine.shutdown();
}

#[test]
fn add_with_keeps_names_aligned_and_dedupes_mirrors() {
    setup();
    let origin = Origin::start();
    let root = tmp();
    let engine = start(config(root.path(), 2));
    let url = |n: &str| origin.url(&format!("/file/{n}.bin"));
    let (m1, m2) = (url("m1"), url("m2"));
    let mirrors = vec![vec![], vec![m2.clone(), m1.clone(), m2.clone(), url("b"), m1.clone()]];
    let names = vec![Some("first.bin".to_owned()), Some("second.bin".to_owned())];
    let r = engine.add_with(vec![url("a"), url("b")], None, names, vec![Some("xyz".into()), None], mirrors, vec![], None);
    assert!(r[0].id.is_none());
    let id = r[1].id.expect("second accepted");
    assert_eq!(view(&engine, id).unwrap().mirrors, 2, "order-preserving unique, primary dropped");
    assert_eq!(view(&engine, id).unwrap().name, "second.bin", "the first url's name is not shifted onto the second");
    engine.shutdown();
}

#[test]
fn add_with_checks_the_given_sha256() {
    setup();
    let origin = Origin::start();
    let root = tmp();
    let engine = start(config(root.path(), 2));
    let good: String = sha(&payload()).iter().map(|b| format!("{b:02x}")).collect();
    let url = |n: &str| origin.url(&format!("/file/{n}.bin"));
    let urls = vec![url("a"), url("b"), url("c"), url("d")];
    let sums = vec![Some(good.to_ascii_uppercase()), Some("0".repeat(64)), Some("xyz".into()), None];
    let r = engine.add_with(urls, None, vec![None; 4], sums, vec![], vec![], None);
    assert_eq!(r[2].error.as_deref(), Some("sha256 must be 64 hex characters"));
    assert!(r[2].id.is_none());
    let (a, b, d) = (r[0].id.unwrap(), r[1].id.unwrap(), r[3].id.unwrap());
    wait_done(&engine, a);
    assert!(view(&engine, a).unwrap().verified);
    wait_done(&engine, d);
    assert!(!view(&engine, d).unwrap().verified);
    let deadline = Instant::now() + WAIT;
    while !matches!(view(&engine, b).unwrap().state, JobState::Failed { .. }) {
        assert!(Instant::now() < deadline, "b never failed");
        thread::sleep(Duration::from_millis(5));
    }
    assert!(engine.add_with(vec![url("e")], None, vec![None], vec![], vec![], vec![], None)[0].id.is_some());
    assert!(engine.add_with(vec![url("f")], None, vec![None], vec![None, None], vec![], vec![], None)[0].id.is_none());
    engine.shutdown();
}

#[test]
fn same_url_twice_gets_suffixed_name_without_shared_part() {
    setup();
    let origin = Origin::start();
    let root = tmp();
    let engine = start(config(root.path(), 2));
    let url = origin.url("/file/x.bin");
    let ids: Vec<JobId> = engine.add(vec![url.clone(), url]).into_iter().map(|r| r.id.expect("accepted")).collect();

    let mut paths: Vec<PathBuf> = ids.iter().map(|id| wait_done(&engine, *id)).collect();
    paths.sort();
    let downloads = root.path().join("downloads");
    let mut expected = vec![downloads.join("x (1).bin"), downloads.join("x.bin")];
    expected.sort();
    assert_eq!(paths, expected);
    for path in &paths {
        assert_eq!(sha_of(path), sha(&payload()));
    }
    assert!(partial_files(&downloads).is_empty());
    engine.shutdown();
}

#[test]
fn max_running_one_keeps_second_job_queued() {
    setup();
    let origin = Origin::start();
    let root = tmp();
    let engine = start(config(root.path(), 1));
    let ids: Vec<JobId> = engine
        .add(vec![origin.url("/file/a.bin"), origin.url("/file/b.bin")])
        .into_iter()
        .map(|r| r.id.expect("accepted"))
        .collect();
    let (first, second) = (ids[0], ids[1]);
    assert_eq!(view(&engine, second).expect("second job").state, JobState::Queued);

    let deadline = Instant::now() + WAIT;
    loop {
        let snap = engine.snapshot();
        let running = snap.iter().filter(|j| j.state == JobState::Running).count();
        assert!(running <= 1, "two jobs running with max_running = 1: {snap:?}");
        let state = |id| snap.iter().find(|j| j.id == id).map(|j| j.state.clone());
        if !matches!(state(first), Some(JobState::Done { .. })) {
            assert_eq!(state(second), Some(JobState::Queued), "second job started before the first finished");
        }
        if snap.iter().filter(|j| matches!(j.state, JobState::Done { .. })).count() == 2 {
            break;
        }
        assert!(Instant::now() < deadline, "jobs did not finish: {snap:?}");
        thread::sleep(Duration::from_millis(2));
    }
    engine.shutdown();
}

#[test]
fn restart_restores_paused_job_and_resumes() {
    setup();
    let origin = Origin::start();
    origin.set_stall(true);
    let root = tmp();
    let cfg = config(root.path(), 2);
    let engine = start(cfg.clone());
    let id = add_one(&engine, origin.url("/file/x.bin"));
    wait_view(&engine, id, "running with bytes", |v| v.state == JobState::Running && v.done > 0);

    engine.shutdown();
    drop(engine);
    origin.set_stall(false);

    let engine = start(cfg);
    let restored = view(&engine, id).expect("job restored after restart");
    assert_eq!(restored.state, JobState::Paused);
    let part = root.path().join(format!("downloads/x.bin.{id}.part"));
    let part_len = std::fs::metadata(&part).expect("part file kept").len();
    assert!(restored.done > 0);
    assert_eq!(restored.done, part_len);

    engine.resume(id);
    let path = wait_done(&engine, id);
    assert_eq!(sha_of(&path), sha(&payload()));
    engine.shutdown();
}

#[test]
fn pause_on_stalled_route_is_prompt_and_resume_finishes() {
    setup();
    let origin = Origin::start();
    origin.set_stall(true);
    let root = tmp();
    let engine = start(config(root.path(), 2));
    let id = add_one(&engine, origin.url("/file/x.bin"));
    wait_view(&engine, id, "running with bytes", |v| v.state == JobState::Running && v.done > 0);

    let started = Instant::now();
    engine.pause(id);
    wait_view(&engine, id, "paused", |v| v.state == JobState::Paused);
    assert!(started.elapsed() < Duration::from_millis(200), "pause took {:?}", started.elapsed());

    origin.set_stall(false);
    engine.resume(id);
    let path = wait_done(&engine, id);
    assert_eq!(sha_of(&path), sha(&payload()));
    engine.shutdown();
}

#[test]
fn remove_while_running_deletes_partial_for_good() {
    setup();
    let origin = Origin::start();
    origin.set_stall(true);
    let root = tmp();
    let downloads = root.path().join("downloads");
    let engine = start(config(root.path(), 2));

    let busy = add_one(&engine, origin.url("/file/x.bin"));
    wait_view(&engine, busy, "running with bytes", |v| v.state == JobState::Running && v.done > 0);
    engine.remove(busy, true);

    // Removed before the transfer necessarily got going: the race that can re-create the .part.
    let early = add_one(&engine, origin.url("/file/y.bin"));
    engine.remove(early, true);

    assert!(engine.snapshot().is_empty());
    thread::sleep(Duration::from_secs(1));
    assert!(partial_files(&downloads).is_empty(), "partial reappeared: {:?}", partial_files(&downloads));
    engine.shutdown();
}

#[test]
fn socket_add_list_and_garbage() {
    setup();
    let origin = Origin::start();
    let root = tmp();
    let engine = start(config(root.path(), 2));
    let mut stream = UnixStream::connect(root.path().join("dl.sock")).expect("connect to engine socket");
    stream.set_read_timeout(Some(WAIT)).expect("read timeout");
    let mut reader = BufReader::new(stream.try_clone().expect("clone socket"));

    let add = serde_json::json!({"op": "add", "urls": [origin.url("/file/x.bin"), "ftp://bad"]}).to_string();
    let reply = ask(&mut stream, &mut reader, &add);
    assert!(reply.ok);
    assert_eq!(reply.added.len(), 1, "{reply:?}");
    assert_eq!(reply.rejected.len(), 1, "{reply:?}");
    assert_eq!(reply.rejected[0].url, "ftp://bad");
    let id = reply.added[0].id;

    let list = ask(&mut stream, &mut reader, r#"{"op":"list"}"#);
    assert!(list.ok);
    assert!(list.jobs.iter().any(|j| j.id == id), "{list:?}");

    let garbage = ask(&mut stream, &mut reader, "not json");
    assert!(!garbage.ok);
    assert!(garbage.error.is_some());

    wait_done(&engine, id);
    engine.shutdown();
}

fn ask(stream: &mut UnixStream, reader: &mut BufReader<UnixStream>, line: &str) -> Response {
    writeln!(stream, "{line}").expect("send request");
    let mut reply = String::new();
    reader.read_line(&mut reply).expect("read reply");
    serde_json::from_str(&reply).unwrap_or_else(|e| panic!("bad reply {reply:?}: {e}"))
}

#[test]
fn second_engine_on_live_socket_is_refused() {
    setup();
    let first_root = tmp();
    let engine = start(config(first_root.path(), 2));
    let second_root = tmp();
    let mut cfg = config(second_root.path(), 2);
    cfg.socket_path = first_root.path().join("dl.sock").to_string_lossy().into_owned();
    match Engine::new(cfg) {
        Err(EngineError::SocketInUse) => {}
        Err(other) => panic!("expected SocketInUse, got {other:?}"),
        Ok(_) => panic!("second engine took over a live socket"),
    }
    engine.shutdown();
}

#[test]
fn ignored_range_marks_job_not_resumable() {
    setup();
    let origin = Origin::start();
    origin.set_stall(true);
    let root = tmp();
    let engine = start(config(root.path(), 2));
    let id = add_one(&engine, origin.url("/noranges/x.bin"));

    let v = wait_view(&engine, id, "first progress", |v| v.done > 0);
    assert!(!v.resumable, "{v:?}");
    assert!(!view(&engine, id).expect("job still listed").resumable);
    engine.shutdown();
}

#[test]
fn restart_during_split_download_resumes_from_segments() {
    setup();
    let origin = Origin::start_big();
    origin.set_stall(true);
    let root = tmp();
    let cfg = EngineConfig { connections: 4, ..config(root.path(), 2) };
    let engine = start(cfg.clone());
    let id = add_one(&engine, origin.url("/file/big.bin"));
    wait_view(&engine, id, "split and transferring", |v| {
        v.state == JobState::Running && v.connections >= 2 && v.done > 0
    });

    engine.shutdown();
    drop(engine);
    origin.set_stall(false);

    let engine = start(cfg);
    let restored = view(&engine, id).expect("job restored after restart");
    assert_eq!(restored.state, JobState::Paused);
    let stored = Store::open(&root.path().join("data")).expect("open store").load_all().expect("load jobs");
    let segments = &stored[0].segments;
    assert!(segments.len() >= 2);
    assert_eq!(restored.done, segments.iter().map(|s| s.done).sum::<u64>());

    engine.resume(id);
    let path = wait_done(&engine, id);
    assert_eq!(sha_of(&path), sha(&big_payload()));
    engine.shutdown();
}

#[test]
fn speed_limit_lifted_mid_download_speeds_it_up() {
    setup();
    let origin = Origin::start_big();
    let root = tmp();
    let cfg = EngineConfig { connections: 4, speed_limit: 1 << 20, ..config(root.path(), 2) };
    let engine = start(cfg);
    let id = add_one(&engine, origin.url("/file/big.bin"));
    thread::sleep(Duration::from_secs(1));
    let throttled = view(&engine, id).expect("job listed").done;
    assert!(throttled < 4 << 20, "not throttled: {throttled} bytes after 1 s");

    engine.set_speed_limit(0);
    let started = Instant::now();
    let path = wait_done(&engine, id);
    // Relative, not a fixed time: the paced origin is slower on a busy CI runner. Still at the 1 MiB/s
    // limit, the rest would take `remaining` seconds; lifted, it must beat that clearly.
    let remaining = (BIG as u64 - throttled) as f64 / f64::from(1u32 << 20);
    let took = started.elapsed().as_secs_f64();
    assert!(took < remaining * 0.6, "still slow after lifting limit: {took:.1}s, limit would take {remaining:.1}s");
    assert_eq!(sha_of(&path), sha(&big_payload()));
    engine.shutdown();
}

#[test]
fn stale_part_from_an_old_database_is_not_taken_as_finished() {
    setup();
    let origin = Origin::start();
    let root = tmp();
    // A full-size, zero-filled leftover with the exact name the first new job will use.
    let downloads = root.path().join("downloads");
    std::fs::create_dir_all(&downloads).unwrap();
    std::fs::write(downloads.join("x.bin.1.part"), vec![0u8; payload().len()]).unwrap();
    let engine = start(config(root.path(), 2));
    let id = add_one(&engine, origin.url("/file/x.bin"));
    assert_eq!(id, 1, "test relies on the first job getting id 1");

    let path = wait_done(&engine, id);
    assert_eq!(sha_of(&path), sha(&payload()));
    engine.shutdown();
}

#[test]
fn mirror_takes_over_when_the_primary_fails() {
    setup();
    let (primary, mirror, short) = (Origin::start_big(), Origin::start_big(), Origin::start());
    let root = tmp();
    let engine = start(EngineConfig { connections: 4, ..config(root.path(), 2) });
    let mirrors = vec![vec![short.url("/file/big.bin"), mirror.url("/file/big.bin")]];
    let r = engine.add_with(vec![primary.url("/flaky/big.bin")], None, vec![None], vec![], mirrors, vec![], None);
    let id = r[0].id.expect("url accepted");
    let path = wait_done(&engine, id);
    assert_eq!(sha_of(&path), sha(&big_payload()));
    assert_eq!(view(&engine, id).unwrap().mirrors, 2, "the job keeps its mirrors even when one fails the probe");
    // Control: without a mirror the same flaky primary fails the job.
    let alone = add_one(&engine, primary.url("/flaky/alone.bin"));
    let deadline = Instant::now() + WAIT;
    while !matches!(view(&engine, alone).unwrap().state, JobState::Failed { .. }) {
        assert!(Instant::now() < deadline, "flaky primary alone never failed");
        thread::sleep(Duration::from_millis(5));
    }
    engine.shutdown();
}

fn token() -> Vec<HttpHeader> {
    vec![HttpHeader { name: "X-Token".into(), value: "s3cret".into() }]
}

#[test]
fn headers_reach_every_request_and_stay_off_other_hosts() {
    setup();
    let (primary, mirror) = (Origin::start_big(), Origin::start_big());
    let root = tmp();
    let engine = start(EngineConfig { connections: 4, ..config(root.path(), 2) });
    // localhost is another host than the primary's 127.0.0.1.
    let other = format!("http://localhost:{}/file/big.bin", mirror.addr.port());
    let r = engine.add_with(vec![primary.url("/file/big.bin")], None, vec![None], vec![], vec![vec![other]], vec![token()], None);
    let id = r[0].id.expect("url accepted");
    assert!(view(&engine, id).unwrap().has_headers);
    let path = wait_done(&engine, id);
    assert_eq!(sha_of(&path), sha(&big_payload()));

    let sent = primary.requests();
    assert!(sent.iter().all(|h| h.contains("x-token: s3cret")), "every primary request carries the header: {sent:?}");
    let probed = mirror.requests();
    assert!(!probed.is_empty(), "the mirror was probed");
    assert!(probed.iter().all(|h| !h.contains("x-token")), "the mirror never sees the header: {probed:?}");
    engine.shutdown();
}

#[test]
fn headers_are_validated_per_url() {
    setup();
    let origin = Origin::start();
    let root = tmp();
    let engine = start(config(root.path(), 2));
    let add = |name: &str, value: &str, url: String| {
        engine.add_with(vec![url], None, vec![None], vec![], vec![], vec![vec![HttpHeader { name: name.into(), value: value.into() }]], None)
    };
    let ok = origin.url("/file/x.bin");
    assert!(add("X-Token", "a", ok.clone())[0].id.is_some());
    let bad = add("bad name", "a", ok.clone());
    assert!(bad[0].id.is_none() && bad[0].error.as_deref().unwrap().contains("not valid"));
    let bad = add("X-Token", "line\nbreak", ok.clone());
    assert!(bad[0].error.as_deref().unwrap().contains("not valid"));
    assert!(!bad[0].error.as_deref().unwrap().contains("break"), "values stay out of errors");
    for name in ["Range", "host", "If-Range", "Content-Length", "Transfer-Encoding", "CONNECTION"] {
        let r = add(name, "x", ok.clone());
        assert_eq!(r[0].error.as_deref(), Some(format!("header {name} is set by Rays").as_str()));
    }
    let r = engine.add_with(vec![ok.clone(), origin.url("/file/y.bin")], None, vec![None; 2], vec![], vec![], vec![token()], None);
    assert_eq!(r[0].error.as_deref(), Some("headers must match urls"));
    engine.shutdown();
}

#[test]
fn headers_survive_a_restart_and_ride_the_resume() {
    setup();
    let origin = Origin::start_big();
    origin.set_stall(true);
    let root = tmp();
    let cfg = EngineConfig { connections: 4, ..config(root.path(), 2) };
    let engine = start(cfg.clone());
    let r = engine.add_with(vec![origin.url("/file/big.bin")], None, vec![None], vec![], vec![], vec![token()], None);
    let id = r[0].id.expect("url accepted");
    wait_view(&engine, id, "split and transferring", |v| v.state == JobState::Running && v.connections >= 2 && v.done > 0);
    engine.shutdown();
    drop(engine);
    origin.set_stall(false);
    let before = origin.requests().len();

    let engine = start(cfg);
    let stored = Store::open(&root.path().join("data")).expect("open store").load_all().expect("load jobs");
    assert_eq!(stored[0].headers, token());
    assert!(view(&engine, id).unwrap().has_headers);
    engine.resume(id);
    let path = wait_done(&engine, id);
    assert_eq!(sha_of(&path), sha(&big_payload()));
    let after = origin.requests().split_off(before);
    assert!(after.iter().any(|h| h.contains("range: bytes=")), "segments were requested: {after:?}");
    assert!(after.iter().all(|h| h.contains("x-token: s3cret")), "resume requests carry the header: {after:?}");
    engine.shutdown();
}

fn key() -> Vec<HttpHeader> {
    vec![HttpHeader { name: "X-Api-Key".into(), value: "k3y".into() }]
}

#[test]
fn headers_do_not_follow_a_redirect_to_another_origin() {
    setup();
    let (first, second) = (Origin::start(), Origin::start());
    let root = tmp();
    let engine = start(config(root.path(), 2));
    let link = first.url(&format!("/to/{}/file/x.bin", second.addr.port()));
    let r = engine.add_with(vec![link], None, vec![None], vec![], vec![], vec![key()], None);
    let path = wait_done(&engine, r[0].id.expect("url accepted"));
    assert_eq!(sha_of(&path), sha(&payload()));
    assert!(first.requests().iter().all(|h| h.contains("x-api-key: k3y")));
    let got = second.requests();
    assert!(!got.is_empty() && got.iter().all(|h| !h.contains("x-api-key")), "the other origin never sees it: {got:?}");
    engine.shutdown();
}

#[test]
fn headers_stay_on_a_same_origin_redirect() {
    setup();
    let origin = Origin::start();
    let root = tmp();
    let engine = start(config(root.path(), 2));
    let r = engine.add_with(vec![origin.url("/same/file/x.bin")], None, vec![None], vec![], vec![], vec![key()], None);
    wait_done(&engine, r[0].id.expect("url accepted"));
    let got = origin.requests();
    assert!(got.len() >= 2 && got.iter().all(|h| h.contains("x-api-key: k3y")), "{got:?}");
    engine.shutdown();
}

fn raw_headers(root: &Path) -> Vec<String> {
    let conn = rusqlite::Connection::open(root.join("data").join("queue.db")).expect("open db");
    let mut q = conn.prepare("SELECT headers FROM jobs ORDER BY id").expect("prepare");
    q.query_map([], |r| r.get::<_, String>(0)).expect("query").map(|r| r.unwrap()).collect()
}

#[test]
fn finished_jobs_drop_their_headers_and_paused_ones_keep_them() {
    setup();
    let origin = Origin::start();
    let root = tmp();
    let engine = start(config(root.path(), 2));
    let done = engine.add_with(vec![origin.url("/file/x.bin")], None, vec![None], vec![], vec![], vec![token()], None)[0].id.unwrap();
    wait_done(&engine, done);
    assert!(!view(&engine, done).unwrap().has_headers);
    let slow = Origin::start_big();
    slow.set_stall(true);
    let paused = engine.add_with(vec![slow.url("/file/big.bin")], None, vec![None], vec![], vec![], vec![token()], None)[0].id.unwrap();
    wait_view(&engine, paused, "transferring", |v| v.done > 0);
    engine.pause(paused);
    wait_view(&engine, paused, "paused", |v| v.state == JobState::Paused);
    engine.shutdown();
    drop(engine);

    let raw = raw_headers(root.path());
    assert_eq!(raw[0], "[]", "the finished job's column holds no header");
    assert!(raw[1].contains("X-Token"));
    let stored = Store::open(&root.path().join("data")).expect("open store").load_all().expect("load jobs");
    assert!(stored[0].headers.is_empty());
    assert_eq!(stored[1].headers, token());
}
