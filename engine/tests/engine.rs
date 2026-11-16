//! Engine behaviour through the public API: jobs, restart, pause/remove, and the socket protocol.
//! The origin server runs on std threads (blocking sockets), so no test needs a runtime of its own
//! except the one `drain_until_done` builds for `next_events`.
use dl_engine::protocol::Response;
use dl_engine::store::Store;
use dl_engine::{Engine, EngineConfig, EngineError, JobEvent, JobId, JobState, JobView};
use sha2::{Digest, Sha256};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Once};
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

/// Origin on a std thread. Paths: `/file/*` honours Range and sends an ETag; `/noranges/*` always
/// answers 200 with no Accept-Ranges. While `stall` is set, a response sends `STALL_AT` bytes and then
/// goes silent until the client gives up.
struct Origin {
    addr: SocketAddr,
    stall: Arc<AtomicBool>,
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
        thread::spawn(move || {
            for conn in listener.incoming().flatten() {
                let (data, stalling) = (data.clone(), flag.load(Ordering::SeqCst));
                thread::spawn(move || serve(conn, &data, stalling));
            }
        });
        Origin { addr, stall }
    }

    fn url(&self, path: &str) -> String {
        format!("http://{}{path}", self.addr)
    }

    fn set_stall(&self, on: bool) {
        self.stall.store(on, Ordering::SeqCst);
    }
}

fn serve(mut sock: TcpStream, data: &[u8], stalling: bool) {
    let mut head = Vec::new();
    let mut byte = [0u8; 1];
    while !head.ends_with(b"\r\n\r\n") {
        match sock.read(&mut byte) {
            Ok(1) => head.push(byte[0]),
            _ => return,
        }
    }
    let text = String::from_utf8_lossy(&head).to_lowercase();
    let path = text.split_whitespace().nth(1).unwrap_or("/").to_string();
    let ranges = !path.starts_with("/noranges/");
    let from = text
        .lines()
        .find_map(|l| l.strip_prefix("range: bytes="))
        .and_then(|r| r.trim().split('-').next())
        .and_then(|n| n.parse::<usize>().ok())
        .filter(|_| ranges);
    let start = from.unwrap_or(0).min(data.len());
    let partial = from.is_some();

    let mut reply = if partial {
        format!("HTTP/1.1 206 Partial Content\r\nContent-Range: bytes {start}-{}/{}\r\n", data.len() - 1, data.len())
    } else {
        "HTTP/1.1 200 OK\r\n".to_string()
    };
    reply += &format!("Content-Length: {}\r\nETag: \"v1\"\r\nConnection: close\r\n", data.len() - start);
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
    assert!(started.elapsed() < Duration::from_secs(8), "still slow after lifting limit: {:?}", started.elapsed());
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
