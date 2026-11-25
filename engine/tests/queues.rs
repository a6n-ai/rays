//! Queue gating, per-queue limits, holds, runs and events. A raw TCP server serves paced, rangeable bodies
//! at `/<tag>/<KiB>`, so a job stays running for a predictable time.
use dl_engine::events::EventHub;
use dl_engine::queue::{FinishAction, QueueConfig, QueueSchedule, Repeat};
use dl_engine::s3::MemorySecrets;
use dl_engine::speed::NetworkKind;
use dl_engine::scheduler::Scheduler;
use dl_engine::store::Store;
use dl_engine::types::{JobId, JobState, JobView, QueueRun, RunOutcome};
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
        follow_best_time: false,
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
    assert_eq!(most_at_once(&r.sched, &ids, 0).await, 2, "direct downloads use the global 2");
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

    r.sched.set_conditions(true, false, false, NetworkKind::Unknown);
    wait_for(&r.sched, id, |v| busy(v) && v.done > 0).await;

    r.sched.set_conditions(false, false, false, NetworkKind::Unknown);
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
    let mut cfg = queue("Open all day", 0, 0);
    cfg.schedule = Some(all_day(false));
    let q = first.sched.save_queue(&cfg).unwrap();
    let id = add(&first.sched, &base, "big", 1024, Some(q));
    let main_id = add(&first.sched, &base, "main", 2048, None);
    wait_for(&first.sched, id, |v| busy(v) && v.done > 0).await;
    wait_for(&first.sched, main_id, |v| busy(v) && v.done > 0).await;
    first.sched.shutdown();
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(first.finished.lock().unwrap().is_empty());
    drop(first);

    let second = rig(dir.path(), 2);
    wait_for(&second.sched, id, is_done).await;
    tokio::time::sleep(Duration::from_millis(400)).await;
    assert_eq!(*second.finished.lock().unwrap(), vec![q]);
    assert_eq!(second.sched.view(main_id).unwrap().state, JobState::Paused, "an unscheduled queue does not auto-start");
}

#[tokio::test(flavor = "multi_thread")]
async fn delete_queue_moves_only_its_own_jobs() {
    let base = server().await;
    let dir = tempfile::tempdir().unwrap();
    let r = rig(dir.path(), 2);
    let a = r.sched.save_queue(&queue("A", 0, 0)).unwrap();
    let b = r.sched.save_queue(&queue("B", 0, 0)).unwrap();
    r.sched.stop_queue(a);
    r.sched.stop_queue(b);
    let in_a = add(&r.sched, &base, "a", 64, Some(a));
    let in_b = add(&r.sched, &base, "b", 64, Some(b));
    r.sched.delete_queue(a).unwrap();
    assert_eq!(r.sched.view(in_a).unwrap().queue_id, 0);
    assert_eq!(r.sched.view(in_b).unwrap().queue_id, b);
    r.sched.shutdown();
    drop(r);
    let again = rig(dir.path(), 2);
    assert_eq!(again.sched.view(in_b).unwrap().queue_id, b);
    assert_eq!(again.sched.view(in_a).unwrap().queue_id, 0);
}

#[tokio::test(flavor = "multi_thread")]
async fn no_stop_window_opened_yesterday_runs_on_load() {
    let base = server().await;
    let dir = tempfile::tempdir().unwrap();
    let r = rig(dir.path(), 2);
    r.sched.set_clock(Arc::new(|| date(2026, 11, 26).at(3, 0, 0, 0)));
    let mut cfg = queue("Overnight", 0, 0);
    cfg.enabled = false;
    let q = r.sched.save_queue(&cfg).unwrap();
    let id = add(&r.sched, &base, "o", 64, Some(q));
    cfg.id = Some(q);
    cfg.enabled = true;
    cfg.schedule = Some(QueueSchedule { repeat: Repeat::Daily, start_min: 23 * 60, stop_min: None, wifi: false, power: false, idle: false });
    r.sched.save_queue(&cfg).unwrap();
    let v = wait_for(&r.sched, id, |v| busy(v) || is_done(v)).await;
    assert_eq!(v.waiting, None);
}

#[tokio::test(flavor = "multi_thread")]
async fn run_now_on_empty_queue_ends() {
    let base = server().await;
    let dir = tempfile::tempdir().unwrap();
    let r = rig(dir.path(), 2);
    r.sched.set_clock(Arc::new(|| date(2026, 11, 25).at(15, 0, 0, 0)));
    let mut cfg = queue("Morning", 0, 0);
    cfg.schedule = Some(QueueSchedule { repeat: Repeat::Daily, start_min: 600, stop_min: Some(660), wifi: false, power: false, idle: false });
    let q = r.sched.save_queue(&cfg).unwrap();
    r.sched.run_queue_now(q);
    let id = add(&r.sched, &base, "m", 64, Some(q));
    tokio::time::sleep(Duration::from_millis(300)).await;
    let v = r.sched.view(id).unwrap();
    assert_eq!((v.state, v.waiting.as_deref()), (JobState::Queued, Some("Waiting for schedule")));
    assert!(r.finished.lock().unwrap().is_empty());
}

#[tokio::test(flavor = "multi_thread")]
async fn holding_a_retrying_job_keeps_it_queued() {
    let dir = tempfile::tempdir().unwrap();
    let r = rig(dir.path(), 2);
    let q = r.sched.save_queue(&queue("Side", 0, 0)).unwrap();
    // Nothing listens on port 9, so the job fails and waits to retry.
    let id = r.sched.add_to(vec!["http://127.0.0.1:9/x".into()], None, vec![Some("x.bin".into())], Some(q))[0].id.unwrap();
    wait_for(&r.sched, id, |v| matches!(v.state, JobState::Retrying { .. })).await;
    r.sched.stop_queue(q);
    wait_for(&r.sched, id, |v| v.state == JobState::Queued).await;
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert_eq!(r.sched.view(id).unwrap().state, JobState::Queued);
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
    assert_eq!(jobs.iter().find(|j| j.id == old).unwrap().queue_id, 0);
    engine.shutdown();
}

fn engine_with_queue(dir: &Path) -> (Arc<Engine>, std::path::PathBuf) {
    let engine = engine_in(dir);
    assert_eq!(engine.save_queue(queue("Night Shift", 0, 0)).unwrap(), 2);
    (engine, dir.join("dl.sock"))
}

#[test]
fn ipc_queues_lists_state_and_counts() {
    let dir = tempfile::tempdir().unwrap();
    let (engine, sock) = engine_with_queue(dir.path());
    engine.stop_queue(2);
    ask(&sock, r#"{"op":"add","urls":["http://127.0.0.1:9/one"],"queue":2}"#);
    let reply = ask(&sock, r#"{"op":"queues"}"#);
    assert_eq!(reply["ok"], true);
    let q = reply["queues"].as_array().unwrap();
    assert_eq!(q.len(), 2);
    assert_eq!((q[0]["id"].as_u64(), q[0]["state"].as_str()), (Some(1), Some("open")));
    assert_eq!(q[1]["name"], "Night Shift");
    assert_eq!(q[1]["state"], "stopped");
    assert_eq!((q[1]["queued"].as_u64(), q[1]["running"].as_u64()), (Some(1), Some(0)));
    engine.shutdown();
}

#[test]
fn ipc_queue_start_stop_by_name_and_id() {
    let dir = tempfile::tempdir().unwrap();
    let (engine, sock) = engine_with_queue(dir.path());
    let state = |sock: &Path| ask(sock, r#"{"op":"queues"}"#)["queues"][1]["state"].as_str().unwrap().to_owned();
    assert_eq!(ask(&sock, r#"{"op":"queue_stop","queue":"night shift"}"#)["ok"], true);
    assert_eq!(state(&sock), "stopped");
    assert_eq!(ask(&sock, r#"{"op":"queue_start","queue":2}"#)["ok"], true);
    assert_eq!(state(&sock), "open");
    assert_eq!(ask(&sock, r#"{"op":"queue_run_now","queue":"NIGHT SHIFT"}"#)["ok"], true);
    let bad = ask(&sock, r#"{"op":"queue_stop","queue":"nope"}"#);
    assert_eq!(bad["ok"], false);
    assert!(bad["error"].as_str().unwrap().contains("no queue"));
    engine.shutdown();
}

#[test]
fn ipc_add_by_queue_name() {
    let dir = tempfile::tempdir().unwrap();
    let (engine, sock) = engine_with_queue(dir.path());
    engine.stop_queue(2);
    let reply = ask(&sock, r#"{"op":"add","urls":["http://127.0.0.1:9/one"],"queue":"night shift"}"#);
    let id = reply["added"][0]["id"].as_u64().expect("added");
    assert_eq!(engine.snapshot().iter().find(|j| j.id == id).unwrap().queue_id, 2);
    let reply = ask(&sock, r#"{"op":"add","urls":["http://127.0.0.1:9/two"],"queue":"nope"}"#);
    assert_eq!(reply["ok"], false);
    engine.shutdown();
}

#[test]
fn ipc_verify_model() {
    let dir = tempfile::tempdir().unwrap();
    let (engine, sock) = engine_with_queue(dir.path());
    let model = dir.path().join("model");
    std::fs::create_dir_all(&model).unwrap();
    let ask_dir = |d: &str| ask(&sock, &serde_json::json!({"op": "verify_model", "dir": d}).to_string());

    let r = ask_dir(model.to_str().unwrap());
    assert_eq!(r["ok"], false);
    assert_eq!(r["error"], "no record of this download (.rays-model.json missing)");
    assert_eq!(ask_dir("relative/dir")["ok"], false);

    std::fs::write(model.join("w.bin"), b"abc").unwrap();
    std::fs::write(
        model.join(".rays-model.json"),
        r#"{"repo":"a/b","sha":"s","files":[{"path":"w.bin","size":3,"sha256":null},{"path":"gone.bin","size":1,"sha256":null}]}"#,
    )
    .unwrap();
    let r = ask_dir(model.to_str().unwrap());
    assert_eq!(r["ok"], true, "{r}");
    assert_eq!(r["verified"][0], serde_json::json!({"path": "w.bin", "status": "size-checked"}));
    assert_eq!(r["verified"][1]["status"], "missing");
    assert!(r["summary"].as_str().unwrap().contains("1 missing"));
    engine.shutdown();
}

fn runs(sched: &Scheduler) -> Vec<QueueRun> {
    sched.queue_runs(50)
}

#[tokio::test(flavor = "multi_thread")]
async fn run_recorded_on_finish() {
    let base = server().await;
    let dir = tempfile::tempdir().unwrap();
    let r = rig(dir.path(), 2);
    let q = r.sched.save_queue(&queue("Pair", 0, 0)).unwrap();
    let ids: Vec<_> = ["a", "b"].iter().map(|t| add(&r.sched, &base, t, 64, Some(q))).collect();
    for id in ids {
        wait_for(&r.sched, id, is_done).await;
    }
    tokio::time::sleep(Duration::from_millis(400)).await;
    let all = runs(&r.sched);
    assert_eq!(all.len(), 1);
    let run = &all[0];
    assert_eq!((run.queue_id, run.outcome.clone(), run.files_done), (q, RunOutcome::Finished, 2));
    assert!(run.bytes_done >= 2 * 64 * 1024, "{}", run.bytes_done);
    assert!(run.ended_at.is_some());
}

#[tokio::test(flavor = "multi_thread")]
async fn window_close_records_windowclosed() {
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
    assert_eq!(runs(&r.sched)[0].outcome, RunOutcome::Running);

    *clock.lock().unwrap() = date(2026, 11, 25).at(11, 30, 0, 0);
    r.sched.tick();
    wait_for(&r.sched, id, |v| v.state == JobState::Queued).await;
    tokio::time::sleep(Duration::from_millis(200)).await;
    let all = runs(&r.sched);
    assert_eq!((all.len(), all[0].outcome.clone()), (1, RunOutcome::WindowClosed));
    assert!(all[0].ended_at.is_some());

    *clock.lock().unwrap() = date(2026, 11, 26).at(10, 15, 0, 0);
    r.sched.tick();
    wait_for(&r.sched, id, is_done).await;
    tokio::time::sleep(Duration::from_millis(400)).await;
    let all = runs(&r.sched);
    assert_eq!((all.len(), all[0].outcome.clone(), all[0].files_done), (2, RunOutcome::Finished, 1));
    assert_eq!(all[1].outcome, RunOutcome::WindowClosed);
}

#[tokio::test(flavor = "multi_thread")]
async fn stop_queue_records_stopped_by_user() {
    let base = server().await;
    let dir = tempfile::tempdir().unwrap();
    let r = rig(dir.path(), 2);
    let q = r.sched.save_queue(&queue("Side", 0, 0)).unwrap();
    let id = add(&r.sched, &base, "big", 2048, Some(q));
    wait_for(&r.sched, id, |v| busy(v) && v.done > 0).await;
    r.sched.stop_queue(q);
    wait_for(&r.sched, id, |v| v.state == JobState::Queued).await;
    let all = runs(&r.sched);
    assert_eq!((all.len(), all[0].outcome.clone()), (1, RunOutcome::StoppedByUser));
}

#[tokio::test(flavor = "multi_thread")]
async fn open_run_closed_as_app_quit_on_restart() {
    let base = server().await;
    let dir = tempfile::tempdir().unwrap();
    let first = rig(dir.path(), 2);
    let q = first.sched.save_queue(&queue("Side", 0, 0)).unwrap();
    let id = add(&first.sched, &base, "big", 2048, Some(q));
    wait_for(&first.sched, id, |v| busy(v) && v.done > 0).await;
    first.sched.shutdown();
    drop(first);

    let second = rig(dir.path(), 2);
    let all = runs(&second.sched);
    assert_eq!((all.len(), all[0].outcome.clone()), (1, RunOutcome::AppQuit));
    assert!(all[0].ended_at.is_some());
}

#[test]
fn runs_pruned_to_200() {
    let dir = tempfile::tempdir().unwrap();
    let store = Store::open(dir.path()).unwrap();
    let ids: Vec<u64> = (0..205).map(|i| store.open_run(1, i).unwrap()).collect();
    let kept = store.runs(1000).unwrap();
    assert_eq!(kept.len(), 200);
    assert_eq!(kept[0].id, ids[204], "newest first");
    assert_eq!(kept[199].id, ids[5]);
}

#[test]
fn delete_queue_drops_its_runs() {
    let dir = tempfile::tempdir().unwrap();
    let store = Store::open(dir.path()).unwrap();
    let id = store.save_queue(&queue("Temp", 0, 0)).unwrap();
    store.open_run(id, 1).unwrap();
    let main_run = store.open_run(1, 2).unwrap();
    store.delete_queue(id).unwrap();
    let left = store.runs(10).unwrap();
    assert_eq!(left.len(), 1);
    assert_eq!(left[0].id, main_run);
}

#[tokio::test(flavor = "multi_thread")]
async fn condition_drop_keeps_one_run() {
    let base = server().await;
    let dir = tempfile::tempdir().unwrap();
    let r = rig(dir.path(), 2);
    let mut cfg = queue("Wi-Fi only", 0, 0);
    cfg.schedule = Some(all_day(true));
    let q = r.sched.save_queue(&cfg).unwrap();
    r.sched.set_conditions(true, false, false, NetworkKind::Unknown);
    let id = add(&r.sched, &base, "w", 1024, Some(q));
    wait_for(&r.sched, id, |v| busy(v) && v.done > 0).await;

    r.sched.set_conditions(false, false, false, NetworkKind::Unknown);
    wait_for(&r.sched, id, |v| v.state == JobState::Queued).await;
    tokio::time::sleep(Duration::from_millis(200)).await;
    let all = runs(&r.sched);
    assert_eq!((all.len(), all[0].outcome.clone()), (1, RunOutcome::Running));

    r.sched.set_conditions(true, false, false, NetworkKind::Unknown);
    wait_for(&r.sched, id, is_done).await;
    tokio::time::sleep(Duration::from_millis(400)).await;
    let all = runs(&r.sched);
    assert_eq!((all.len(), all[0].outcome.clone(), all[0].files_done), (1, RunOutcome::Finished, 1));
}

#[tokio::test(flavor = "multi_thread")]
async fn disabling_mid_run_records_stopped_by_user() {
    let base = server().await;
    let dir = tempfile::tempdir().unwrap();
    let r = rig(dir.path(), 2);
    let mut cfg = queue("Side", 0, 0);
    let q = r.sched.save_queue(&cfg).unwrap();
    let id = add(&r.sched, &base, "big", 2048, Some(q));
    wait_for(&r.sched, id, |v| busy(v) && v.done > 0).await;
    cfg.id = Some(q);
    cfg.enabled = false;
    r.sched.save_queue(&cfg).unwrap();
    wait_for(&r.sched, id, |v| v.state == JobState::Queued).await;
    tokio::time::sleep(Duration::from_millis(200)).await;
    let all = runs(&r.sched);
    assert_eq!((all.len(), all[0].outcome.clone()), (1, RunOutcome::StoppedByUser));
}

#[tokio::test(flavor = "multi_thread")]
async fn finished_no_stop_window_stays_closed_after_reload() {
    let base = server().await;
    let dir = tempfile::tempdir().unwrap();
    let first = rig(dir.path(), 2);
    let mut cfg = queue("Overnight", 0, 0);
    cfg.schedule = Some(all_day(false));
    let q = first.sched.save_queue(&cfg).unwrap();
    let id = add(&first.sched, &base, "a", 64, Some(q));
    wait_for(&first.sched, id, is_done).await;
    tokio::time::sleep(Duration::from_millis(400)).await;
    assert_eq!(*first.finished.lock().unwrap(), vec![q]);
    first.sched.shutdown();
    drop(first);

    let second = rig(dir.path(), 2);
    let late = add(&second.sched, &base, "b", 64, Some(q));
    tokio::time::sleep(Duration::from_millis(300)).await;
    let v = second.sched.view(late).unwrap();
    assert_eq!((v.state, v.waiting.as_deref()), (JobState::Queued, Some("Waiting for schedule")));
}

#[tokio::test(flavor = "multi_thread")]
async fn repeated_dst_hour_does_not_reopen_the_window() {
    let base = server().await;
    let dir = tempfile::tempdir().unwrap();
    let r = rig(dir.path(), 2);
    let clock = Arc::new(Mutex::new(date(2026, 11, 1).at(1, 10, 0, 0)));
    let shared = clock.clone();
    r.sched.set_clock(Arc::new(move || -> DateTime { *shared.lock().unwrap() }));
    let mut cfg = queue("Fall back", 0, 0);
    cfg.schedule = Some(QueueSchedule { repeat: Repeat::Daily, start_min: 60, stop_min: Some(105), wifi: false, power: false, idle: false });
    let q = r.sched.save_queue(&cfg).unwrap();
    let id = add(&r.sched, &base, "dst", 4096, Some(q));
    wait_for(&r.sched, id, |v| busy(v) && v.done > 0).await;
    r.sched.stop_queue(q);
    wait_for(&r.sched, id, |v| v.state == JobState::Queued).await;

    *clock.lock().unwrap() = date(2026, 11, 1).at(1, 50, 0, 0);
    r.sched.tick();
    *clock.lock().unwrap() = date(2026, 11, 1).at(1, 10, 0, 0);
    r.sched.tick();
    tokio::time::sleep(Duration::from_millis(300)).await;
    let v = r.sched.view(id).unwrap();
    assert_eq!((v.state, v.waiting.as_deref()), (JobState::Queued, Some("Queue stopped")), "the repeated hour is not a new opening");
}

#[tokio::test(flavor = "multi_thread")]
async fn once_in_the_past_is_rejected_and_a_lowered_global_cap_is_not() {
    let dir = tempfile::tempdir().unwrap();
    let r = rig(dir.path(), 2);
    r.sched.set_clock(Arc::new(|| date(2026, 11, 25).at(10, 0, 0, 0)));
    let once = |start_min: u16, stop_min| {
        let mut cfg = queue("Once", 0, 0);
        cfg.schedule = Some(QueueSchedule { repeat: Repeat::Once { date: "2026-11-25".into() }, start_min, stop_min, wifi: false, power: false, idle: false });
        cfg
    };
    assert!(r.sched.save_queue(&once(540, Some(570))).is_err(), "ended at 09:30");
    assert!(r.sched.save_queue(&once(540, None)).is_ok(), "no stop: open until midnight");
    assert!(r.sched.save_queue(&once(660, None)).is_ok(), "starts later today");
    let mut off = once(540, Some(570));
    off.enabled = false;
    assert!(r.sched.save_queue(&off).is_ok(), "a disabled queue can still be edited");

    let mut cfg = queue("Wide", 5, 0);
    cfg.max_running = 5;
    assert!(r.sched.save_queue(&cfg).is_ok(), "the global cap applies at run time, not on save");
}
