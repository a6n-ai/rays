//! Queue gating, per-queue limits, holds, runs and events. A raw TCP server serves paced, rangeable bodies
//! at `/<tag>/<KiB>`, so a job stays running for a predictable time.
use dl_engine::events::EventHub;
use dl_engine::queue::{FinishAction, QueueConfig, QueueSchedule, Repeat};
use dl_engine::s3::MemorySecrets;
use dl_engine::scheduler::Scheduler;
use dl_engine::store::Store;
use dl_engine::types::{JobId, JobState, JobView};
use dl_engine::{Engine, EngineConfig};
use jiff::civil::{DateTime, date};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

const CHUNK: usize = 8 * 1024;
const PACE: Duration = Duration::from_millis(10);

fn body(len: usize) -> Vec<u8> {
    (0..len).map(|i| ((i * 7 + i / 256) % 256) as u8).collect()
}

async fn server() -> String {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(async move {
        while let Ok((sock, _)) = listener.accept().await {
            tokio::spawn(serve(sock));
        }
    });
    format!("http://127.0.0.1:{port}")
}

async fn read_head(sock: &mut TcpStream) -> Option<String> {
    let mut buf = Vec::new();
    let mut byte = [0u8; 1];
    while !buf.ends_with(b"\r\n\r\n") {
        sock.read_exact(&mut byte).await.ok()?;
        buf.push(byte[0]);
    }
    Some(String::from_utf8_lossy(&buf).into_owned())
}

async fn serve(mut sock: TcpStream) {
    let Some(head) = read_head(&mut sock).await else { return };
    let path = head.split_whitespace().nth(1).unwrap_or("/").to_owned();
    let kib: usize = path.rsplit('/').next().and_then(|s| s.parse().ok()).unwrap_or(64);
    let data = body(kib * 1024);
    let method = head.split_whitespace().next().unwrap_or("GET");
    let range = head.lines().skip(1).find_map(|l| {
        let (k, v) = l.split_once(':')?;
        k.eq_ignore_ascii_case("range").then(|| v.trim().to_owned())
    });
    let from = range.as_deref().and_then(|r| r.strip_prefix("bytes=")?.strip_suffix('-')?.parse::<usize>().ok());
    let (status, extra) = match from {
        Some(f) => ("206 Partial Content", format!("Content-Range: bytes {f}-{}/{}\r\n", data.len() - 1, data.len())),
        None => ("200 OK", String::new()),
    };
    let start = from.unwrap_or(0);
    let head = format!(
        "HTTP/1.1 {status}\r\nContent-Length: {}\r\n{extra}ETag: \"v1\"\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n",
        data.len() - start
    );
    if sock.write_all(head.as_bytes()).await.is_err() || method == "HEAD" {
        return;
    }
    for chunk in data[start..].chunks(CHUNK) {
        if sock.write_all(chunk).await.is_err() {
            return;
        }
        tokio::time::sleep(PACE).await;
    }
}

struct Rig {
    sched: Arc<Scheduler>,
    finished: Arc<Mutex<Vec<u64>>>,
}

fn rig(root: &Path, max_running: u32) -> Rig {
    let store = Arc::new(Store::open(&root.join("data")).unwrap());
    let downloads = root.join("downloads");
    std::fs::create_dir_all(&downloads).unwrap();
    let hub = Arc::new(EventHub::new());
    let sched = Scheduler::new(
        tokio::runtime::Handle::current(),
        store,
        hub.clone(),
        downloads,
        max_running,
        1,
        0,
        Arc::new(MemorySecrets::default()),
        Arc::new(MemorySecrets::default()),
        "http://127.0.0.1:1".into(),
    )
    .unwrap();
    let finished: Arc<Mutex<Vec<u64>>> = Arc::default();
    let log = finished.clone();
    tokio::spawn(async move {
        loop {
            let changes = hub.wait().await;
            log.lock().unwrap().extend(changes.finished);
        }
    });
    Rig { sched, finished }
}

fn queue(name: &str, max_running: u32, speed_limit: u64) -> QueueConfig {
    QueueConfig {
        id: None,
        name: name.into(),
        max_running,
        speed_limit,
        enabled: true,
        schedule: None,
        retry_failed: false,
        wake: false,
        when_finished: FinishAction::Nothing,
    }
}

fn all_day(wifi: bool) -> QueueSchedule {
    QueueSchedule { repeat: Repeat::Daily, start_min: 0, stop_min: None, wifi, power: false, idle: false }
}

fn add(sched: &Arc<Scheduler>, base: &str, tag: &str, kib: u32, queue: Option<u64>) -> JobId {
    let url = format!("{base}/{tag}/{kib}");
    sched.add_to(vec![url], None, vec![Some(format!("{tag}.bin"))], queue)[0].id.expect("queued")
}

fn busy(v: &JobView) -> bool {
    matches!(v.state, JobState::Running | JobState::Retrying { .. } | JobState::Verifying)
}

fn is_done(v: &JobView) -> bool {
    matches!(v.state, JobState::Done { .. })
}

async fn wait_for(sched: &Scheduler, id: JobId, done: impl Fn(&JobView) -> bool) -> JobView {
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        if let Some(v) = sched.view(id).filter(|v| done(v)) {
            return v;
        }
        assert!(Instant::now() < deadline, "job {id} did not reach the awaited state: {:?}", sched.view(id));
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}

/// Polls until every id is done, returning the most jobs of `queue` that ran at once.
async fn most_at_once(sched: &Scheduler, ids: &[JobId], queue: u64) -> usize {
    let deadline = Instant::now() + Duration::from_secs(30);
    let mut most = 0;
    loop {
        let views = sched.views();
        most = most.max(views.iter().filter(|v| v.queue_id == queue && busy(v)).count());
        if ids.iter().all(|id| views.iter().any(|v| v.id == *id && is_done(v))) {
            return most;
        }
        assert!(Instant::now() < deadline, "jobs did not finish: {views:?}");
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn per_queue_concurrency() {
    let base = server().await;
    let dir = tempfile::tempdir().unwrap();
    let r = rig(dir.path(), 2);
    let q = r.sched.save_queue(&queue("One at a time", 1, 0)).unwrap();
    let ids: Vec<_> = ["a", "b", "c"].iter().map(|t| add(&r.sched, &base, t, 384, Some(q))).collect();
    assert_eq!(most_at_once(&r.sched, &ids, q).await, 1);

    let ids: Vec<_> = ["d", "e", "f"].iter().map(|t| add(&r.sched, &base, t, 384, None)).collect();
    assert_eq!(most_at_once(&r.sched, &ids, 1).await, 2, "Same as Rays uses the global 2");
}

#[tokio::test(flavor = "multi_thread")]
async fn stopped_queue_holds_and_starts() {
    let base = server().await;
    let dir = tempfile::tempdir().unwrap();
    let r = rig(dir.path(), 2);
    let q = r.sched.save_queue(&queue("Side", 0, 0)).unwrap();
    let id = add(&r.sched, &base, "big", 2048, Some(q));
    wait_for(&r.sched, id, |v| busy(v) && v.done > 64 * 1024).await;

    r.sched.stop_queue(q);
    let held = wait_for(&r.sched, id, |v| v.state == JobState::Queued).await;
    assert_eq!(held.waiting.as_deref(), Some("Queue stopped"));
    tokio::time::sleep(Duration::from_millis(200)).await;
    let held = r.sched.view(id).unwrap();
    assert_eq!(held.state, JobState::Queued, "stays held");
    assert!(held.done > 64 * 1024, "progress kept: {}", held.done);

    r.sched.start_queue(q);
    let again = wait_for(&r.sched, id, |v| busy(v) || is_done(v)).await;
    assert!(again.done >= held.done, "resumes from {}, not 0: {}", held.done, again.done);
    assert_eq!(again.waiting, None);
    let done = wait_for(&r.sched, id, is_done).await;
    let JobState::Done { path } = done.state else { unreachable!() };
    assert_eq!(std::fs::read(path).unwrap(), body(2048 * 1024));
}

#[tokio::test(flavor = "multi_thread")]
async fn conditions_gate() {
    let base = server().await;
    let dir = tempfile::tempdir().unwrap();
    let r = rig(dir.path(), 2);
    let mut cfg = queue("Wi-Fi only", 0, 0);
    cfg.schedule = Some(all_day(true));
    let q = r.sched.save_queue(&cfg).unwrap();
    let id = add(&r.sched, &base, "w", 2048, Some(q));

    tokio::time::sleep(Duration::from_millis(300)).await;
    let v = r.sched.view(id).unwrap();
    assert_eq!((v.state, v.waiting.as_deref()), (JobState::Queued, Some("Waiting for Wi-Fi")), "conditions start unmet");

    r.sched.set_conditions(true, false, false);
    wait_for(&r.sched, id, |v| busy(v) && v.done > 0).await;

    r.sched.set_conditions(false, false, false);
    let held = wait_for(&r.sched, id, |v| v.state == JobState::Queued).await;
    assert_eq!(held.waiting.as_deref(), Some("Waiting for Wi-Fi"));
    assert!(held.done > 0);
}

#[tokio::test(flavor = "multi_thread")]
async fn finished_fires_once() {
    let base = server().await;
    let dir = tempfile::tempdir().unwrap();
    let r = rig(dir.path(), 2);
    let q = r.sched.save_queue(&queue("Pair", 0, 0)).unwrap();
    let ids: Vec<_> = ["a", "b"].iter().map(|t| add(&r.sched, &base, t, 64, Some(q))).collect();
    for id in ids {
        wait_for(&r.sched, id, is_done).await;
    }
    tokio::time::sleep(Duration::from_millis(400)).await;
    assert_eq!(*r.finished.lock().unwrap(), vec![q]);
}

#[tokio::test(flavor = "multi_thread")]
async fn pausing_all_does_not_finish() {
    let base = server().await;
    let dir = tempfile::tempdir().unwrap();
    let r = rig(dir.path(), 2);
    let q = r.sched.save_queue(&queue("Pair", 0, 0)).unwrap();
    let ids: Vec<_> = ["a", "b"].iter().map(|t| add(&r.sched, &base, t, 2048, Some(q))).collect();
    for id in &ids {
        wait_for(&r.sched, *id, |v| busy(v) && v.done > 0).await;
    }
    for id in &ids {
        r.sched.pause(*id);
    }
    for id in &ids {
        wait_for(&r.sched, *id, |v| v.state == JobState::Paused).await;
    }
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(r.finished.lock().unwrap().is_empty());
}

#[tokio::test(flavor = "multi_thread")]
async fn restart_mid_run_no_stale_finish() {
    let base = server().await;
    let dir = tempfile::tempdir().unwrap();
    let first = rig(dir.path(), 2);
    let id = add(&first.sched, &base, "big", 1024, None);
    wait_for(&first.sched, id, |v| busy(v) && v.done > 0).await;
    first.sched.shutdown();
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(first.finished.lock().unwrap().is_empty());
    drop(first);

    let second = rig(dir.path(), 2);
    second.sched.resume(id);
    wait_for(&second.sched, id, is_done).await;
    tokio::time::sleep(Duration::from_millis(400)).await;
    assert_eq!(*second.finished.lock().unwrap(), vec![1]);
}

#[tokio::test(flavor = "multi_thread")]
async fn move_to_closed_queue_holds() {
    let base = server().await;
    let dir = tempfile::tempdir().unwrap();
    let r = rig(dir.path(), 2);
    let q = r.sched.save_queue(&queue("Closed", 0, 0)).unwrap();
    r.sched.stop_queue(q);
    let id = add(&r.sched, &base, "big", 1024, None);
    wait_for(&r.sched, id, |v| busy(v) && v.done > 0).await;

    r.sched.move_to_queue(id, q);
    let held = wait_for(&r.sched, id, |v| v.state == JobState::Queued).await;
    assert_eq!((held.queue_id, held.waiting.as_deref()), (q, Some("Queue stopped")));

    r.sched.start_queue(q);
    wait_for(&r.sched, id, is_done).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn per_queue_speed_limit() {
    let base = server().await;
    let dir = tempfile::tempdir().unwrap();
    let r = rig(dir.path(), 2);
    let q = r.sched.save_queue(&queue("Slow", 0, 200_000)).unwrap();
    let started = Instant::now();
    let id = add(&r.sched, &base, "s", 600, Some(q));
    wait_for(&r.sched, id, is_done).await;
    let took = started.elapsed();
    // The bucket's one-second burst is free, so 600 KiB at 200 KB/s needs about 2 s more.
    assert!(took >= Duration::from_millis(1500), "{took:?}");
    assert!(took < Duration::from_secs(10), "{took:?}");
}

#[tokio::test(flavor = "multi_thread")]
async fn window_close_holds_running() {
    let base = server().await;
    let dir = tempfile::tempdir().unwrap();
    let r = rig(dir.path(), 2);
    let clock = Arc::new(Mutex::new(date(2026, 11, 25).at(10, 30, 0, 0)));
    let shared = clock.clone();
    r.sched.set_clock(Arc::new(move || -> DateTime { *shared.lock().unwrap() }));
    let mut cfg = queue("Night", 0, 0);
    cfg.schedule = Some(QueueSchedule { repeat: Repeat::Daily, start_min: 600, stop_min: Some(660), wifi: false, power: false, idle: false });
    let q = r.sched.save_queue(&cfg).unwrap();
    let id = add(&r.sched, &base, "n", 2048, Some(q));
    wait_for(&r.sched, id, |v| busy(v) && v.done > 0).await;

    *clock.lock().unwrap() = date(2026, 11, 25).at(11, 30, 0, 0);
    r.sched.tick();
    let held = wait_for(&r.sched, id, |v| v.state == JobState::Queued).await;
    assert_eq!(held.waiting.as_deref(), Some("Waiting for schedule"));
    assert!(held.done > 0);
    assert!(r.finished.lock().unwrap().is_empty(), "a closing window is not a finish");

    *clock.lock().unwrap() = date(2026, 11, 26).at(10, 15, 0, 0);
    r.sched.tick();
    wait_for(&r.sched, id, is_done).await;
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

fn ask(sock: &Path, line: &str) -> serde_json::Value {
    let mut stream = UnixStream::connect(sock).unwrap();
    writeln!(stream, "{line}").unwrap();
    let mut reply = String::new();
    BufReader::new(stream).read_line(&mut reply).unwrap();
    serde_json::from_str(&reply).unwrap()
}

#[test]
fn ipc_add_with_queue() {
    let dir = tempfile::tempdir().unwrap();
    let engine = engine_in(dir.path());
    let q = engine.save_queue(queue("CLI", 0, 0)).unwrap();
    assert_eq!(q, 2);
    engine.stop_queue(q);
    let sock = dir.path().join("dl.sock");

    let reply = ask(&sock, r#"{"op":"add","urls":["http://127.0.0.1:9/one"],"queue":2}"#);
    let id = reply["added"][0]["id"].as_u64().expect("added");
    let reply = ask(&sock, r#"{"op":"add","urls":["http://127.0.0.1:9/two"]}"#);
    let old = reply["added"][0]["id"].as_u64().expect("added");

    let jobs = engine.snapshot();
    assert_eq!(jobs.iter().find(|j| j.id == id).unwrap().queue_id, 2);
    assert_eq!(jobs.iter().find(|j| j.id == old).unwrap().queue_id, 1);
    engine.shutdown();
}
