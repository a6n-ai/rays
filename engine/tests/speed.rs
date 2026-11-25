//! On-demand speed test against a local fake of speed.cloudflare.com: `/__down?bytes=N` serves N zero bytes.
use dl_engine::speed::{NetworkKind, SampleSource};
use dl_engine::store::Store;
use dl_engine::types::JobState;
use dl_engine::{Engine, EngineConfig};
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicU8, Ordering};
use std::time::{Duration, Instant};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

const NORMAL: u8 = 0;
const BLOCKED: u8 = 1;
const STALL: u8 = 2;
const TINY: u8 = 3;

async fn server(blocked: Arc<AtomicU8>) -> String {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(async move {
        while let Ok((sock, _)) = listener.accept().await {
            tokio::spawn(serve(sock, Arc::clone(&blocked)));
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

async fn serve(mut sock: TcpStream, blocked: Arc<AtomicU8>) {
    let Some(head) = read_head(&mut sock).await else { return };
    let path = head.split_whitespace().nth(1).unwrap_or("/").to_owned();
    if path.starts_with("/__down") && blocked.load(Ordering::Relaxed) == BLOCKED {
        let html = "<html>blocked</html>";
        let reply = format!(
            "HTTP/1.1 403 Forbidden\r\nContent-Type: text/html\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{html}",
            html.len()
        );
        let _ = sock.write_all(reply.as_bytes()).await;
        return;
    }
    let slow = path.starts_with("/slow");
    let asked: usize = path.split("bytes=").nth(1).and_then(|s| s.parse().ok()).unwrap_or(0);
    let mode = blocked.load(Ordering::Relaxed);
    let len: usize = if slow { 20 << 20 } else if mode == TINY { 100 << 10 } else { asked };
    let head = format!("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: {len}\r\nConnection: close\r\n\r\n");
    if sock.write_all(head.as_bytes()).await.is_err() {
        return;
    }
    let chunk = vec![0u8; 8 * 1024];
    let mut left = len;
    let mut sent = 0;
    while left > 0 {
        if mode == STALL && asked > 0 && sent >= 2 << 20 {
            tokio::time::sleep(Duration::from_secs(120)).await;
            return;
        }
        sent += chunk.len().min(left);
        let n = left.min(chunk.len());
        if sock.write_all(&chunk[..n]).await.is_err() {
            return;
        }
        left -= n;
        if slow {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }
}

fn engine(root: &Path) -> Arc<Engine> {
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

/// The engine owns a runtime, so it must be created and dropped outside the test's own.
fn rig(rt: &tokio::runtime::Runtime, network: NetworkKind) -> (tempfile::TempDir, Arc<Engine>, Arc<AtomicU8>, String) {
    let blocked = Arc::new(AtomicU8::new(NORMAL));
    let base = rt.block_on(server(Arc::clone(&blocked)));
    let dir = tempfile::tempdir().unwrap();
    let e = engine(dir.path());
    e.set_conditions(true, true, true, network);
    e.set_speed_test_base(base.clone());
    e.set_speed_test_duration(1000);
    (dir, e, blocked, base)
}

fn stored(dir: &Path) -> Vec<dl_engine::speed::SpeedSample> {
    Store::open(&dir.join("data")).unwrap().samples_since(0).unwrap()
}

#[test]
fn speed_test_measures_and_saves() {
    let rt = tokio::runtime::Runtime::new().unwrap();
    let (dir, e, _, _) = rig(&rt, NetworkKind::Wifi);
    let r = rt.block_on(e.run_speed_test(false)).unwrap();
    assert!(r.bps > 0 && r.saved);
    let samples = stored(dir.path());
    assert_eq!(samples.len(), 1);
    assert_eq!((samples[0].source, samples[0].network, samples[0].bps), (SampleSource::Test, NetworkKind::Wifi, r.bps));
    assert_eq!(e.last_speed_test(), Some(r));
}

#[test]
fn speed_test_refuses_expensive() {
    let rt = tokio::runtime::Runtime::new().unwrap();
    let (_dir, e, _, _) = rig(&rt, NetworkKind::Expensive);
    let err = rt.block_on(e.run_speed_test(false)).unwrap_err();
    assert!(err.to_string().contains("hotspot"), "{err}");
    assert!(rt.block_on(e.run_speed_test(true)).unwrap().saved);
}

#[test]
fn speed_test_proxy_error_saves_nothing() {
    let rt = tokio::runtime::Runtime::new().unwrap();
    let (dir, e, blocked, _) = rig(&rt, NetworkKind::Wifi);
    blocked.store(BLOCKED, Ordering::Relaxed);
    let err = rt.block_on(e.run_speed_test(false)).unwrap_err();
    assert!(err.to_string().contains("Couldn't reach the speed test server"), "{err}");
    assert!(stored(dir.path()).is_empty());
    assert_eq!(e.last_speed_test(), None);
}

#[test]
fn speed_test_during_download_not_saved() {
    let rt = tokio::runtime::Runtime::new().unwrap();
    let (dir, e, _, base) = rig(&rt, NetworkKind::Wifi);
    e.add(vec![format!("{base}/slow/big.bin")]);
    let start = Instant::now();
    while !e.snapshot().iter().any(|j| j.state == JobState::Running) {
        assert!(start.elapsed() < Duration::from_secs(10), "job never ran");
        std::thread::sleep(Duration::from_millis(20));
    }
    let r = rt.block_on(e.run_speed_test(false)).unwrap();
    assert!(r.bps > 0 && !r.saved);
    assert!(stored(dir.path()).is_empty());
}

#[test]
fn speed_test_stalled_connection_finishes_on_time() {
    let rt = tokio::runtime::Runtime::new().unwrap();
    let (_dir, e, mode, _) = rig(&rt, NetworkKind::Wifi);
    e.set_speed_test_duration(1500);
    mode.store(STALL, Ordering::Relaxed);
    let start = Instant::now();
    let r = rt.block_on(e.run_speed_test(false));
    assert!(r.is_ok(), "{r:?}");
    assert!(start.elapsed() < Duration::from_secs(4), "{:?}", start.elapsed());
}

#[test]
fn speed_test_tiny_body_errors() {
    let rt = tokio::runtime::Runtime::new().unwrap();
    let (dir, e, mode, _) = rig(&rt, NetworkKind::Wifi);
    mode.store(TINY, Ordering::Relaxed);
    let err = rt.block_on(e.run_speed_test(false)).unwrap_err();
    assert!(err.to_string().contains("Couldn't reach the speed test server"), "{err}");
    assert!(stored(dir.path()).is_empty());
}

mod best_time {
    use super::*;
    use dl_engine::queue::{QueueConfig, Repeat};
    use dl_engine::speed::{BestTime, SpeedSample};
    use dl_engine::types::JobEvent;
    use jiff::civil::{date, DateTime};
    use jiff::tz::TimeZone;
    use std::sync::Mutex;

    fn unix(dt: DateTime) -> i64 {
        dt.to_zoned_datetime(TimeZone::system()).unwrap().timestamp().as_second()
    }

    fn seed(dir: &Path, first_day: i8, days: i8) {
        let store = Store::open(&dir.join("data")).unwrap();
        for d in first_day..first_day + days {
            for h in 0..24 {
                for k in 0..3 {
                    let bps = if (1..=4).contains(&h) { 100_000_000 } else { 20_000_000 };
                    let at = unix(date(2026, 11, d).at(h, k * 10, 0, 0));
                    store.add_sample(&SpeedSample { at, bps, source: SampleSource::Downloads, network: NetworkKind::Wifi }).unwrap();
                }
            }
        }
    }

    fn clocked(e: &Engine, start: DateTime) -> Arc<Mutex<DateTime>> {
        let clock = Arc::new(Mutex::new(start));
        let shared = Arc::clone(&clock);
        e.set_clock(Arc::new(move || *shared.lock().unwrap()));
        clock
    }

    fn follow_config(e: &Engine, id: u64) -> QueueConfig {
        e.queues().into_iter().find(|q| q.config.id == Some(id)).unwrap().config
    }

    fn events(rt: &tokio::runtime::Runtime, e: &Engine, ms: u64) -> Vec<JobEvent> {
        rt.block_on(async { tokio::time::timeout(Duration::from_millis(ms), e.next_events()).await.unwrap_or_default() })
    }

    #[test]
    fn best_time_queue_created_once() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        let (_dir, e, _, _) = rig(&rt, NetworkKind::Wifi);
        clocked(&e, date(2026, 11, 25).at(10, 0, 0, 0));
        let id = e.best_time_queue().unwrap();
        let c = follow_config(&e, id);
        assert_eq!(c.name, "Best time");
        assert!(c.follow_best_time && c.enabled && c.retry_failed && !c.wake);
        assert_eq!((c.max_running, c.speed_limit), (0, 0));
        let s = c.schedule.clone().unwrap();
        assert_eq!((s.repeat, s.start_min, s.stop_min), (Repeat::Daily, 60, Some(360)));
        assert_eq!(e.best_time_queue().unwrap(), id);
        e.save_queue(QueueConfig { name: "Mine".into(), ..c }).unwrap();
        assert_eq!(e.best_time_queue().unwrap(), id);
        assert_eq!(e.queues().len(), 2);
    }

    #[test]
    fn follower_updates_window() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        let (dir, e, _, _) = rig(&rt, NetworkKind::Wifi);
        let clock = clocked(&e, date(2026, 11, 25).at(10, 0, 0, 0));
        let id = e.best_time_queue().unwrap();
        seed(dir.path(), 17, 8);
        assert!(matches!(e.best_time(), BestTime::Window { start_min: 60, end_min: 300, .. }));
        *clock.lock().unwrap() = date(2026, 11, 26).at(10, 0, 0, 0);
        e.tick();
        let c = follow_config(&e, id);
        let s = c.schedule.unwrap();
        assert_eq!((s.start_min, s.stop_min), (60, Some(300)));
        assert!(c.follow_best_time);
    }

    #[test]
    fn follower_ignores_small_moves() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        let (dir, e, _, _) = rig(&rt, NetworkKind::Wifi);
        let clock = clocked(&e, date(2026, 11, 25).at(10, 0, 0, 0));
        seed(dir.path(), 17, 8);
        let id = e.best_time_queue().unwrap();
        assert_eq!(follow_config(&e, id).schedule.unwrap().stop_min, Some(300));
        *clock.lock().unwrap() = date(2026, 11, 26).at(10, 0, 0, 0);
        // The hub holds a delivery back up to 2 s, so quiet means a gap longer than that.
        while !events(&rt, &e, 2500).is_empty() {}
        e.tick();
        assert!(events(&rt, &e, 2500).is_empty());
        assert_eq!(follow_config(&e, id).schedule.unwrap().stop_min, Some(300));
    }

    #[test]
    fn manual_edit_stops_following() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        let (dir, e, _, _) = rig(&rt, NetworkKind::Wifi);
        let clock = clocked(&e, date(2026, 11, 25).at(10, 0, 0, 0));
        let id = e.best_time_queue().unwrap();
        let mut c = follow_config(&e, id);
        let mut s = c.schedule.clone().unwrap();
        s.start_min = 120;
        s.stop_min = Some(420);
        c.schedule = Some(s);
        e.save_queue(c).unwrap();
        assert!(!follow_config(&e, id).follow_best_time);
        seed(dir.path(), 17, 8);
        *clock.lock().unwrap() = date(2026, 11, 26).at(10, 0, 0, 0);
        e.tick();
        let s = follow_config(&e, id).schedule.unwrap();
        assert_eq!((s.start_min, s.stop_min), (120, Some(420)));
    }

    #[test]
    fn switching_follow_back_on_keeps_schedule_until_refresh() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        let (dir, e, _, _) = rig(&rt, NetworkKind::Wifi);
        let clock = clocked(&e, date(2026, 11, 25).at(10, 0, 0, 0));
        let id = e.best_time_queue().unwrap();
        let mut c = follow_config(&e, id);
        c.schedule.as_mut().unwrap().start_min = 120;
        e.save_queue(c.clone()).unwrap();
        e.save_queue(QueueConfig { follow_best_time: true, ..follow_config(&e, id) }).unwrap();
        let c = follow_config(&e, id);
        assert!(c.follow_best_time);
        assert_eq!(c.schedule.unwrap().start_min, 120);
        seed(dir.path(), 17, 8);
        *clock.lock().unwrap() = date(2026, 11, 26).at(10, 0, 0, 0);
        e.tick();
        assert_eq!(follow_config(&e, id).schedule.unwrap().start_min, 60);
    }

    #[test]
    fn night_week_runs_tests() {
        for (network, expected) in [(NetworkKind::Wifi, 3), (NetworkKind::Expensive, 0)] {
            let rt = tokio::runtime::Runtime::new().unwrap();
            let (dir, e, _, _) = rig(&rt, network);
            let clock = clocked(&e, date(2026, 11, 25).at(23, 0, 0, 0));
            e.start_night_week();
            let s = e.speed_settings();
            assert!(s.night_prompt_answered && !s.auto_tests);
            assert_eq!(s.night_until, Some(unix(date(2026, 11, 25).at(23, 0, 0, 0)) + 7 * 86_400));
            let planned = [date(2026, 11, 26).at(0, 41, 0, 0), date(2026, 11, 26).at(3, 7, 0, 0), date(2026, 11, 26).at(4, 59, 0, 0)];
            e.set_auto_test_plan(planned.iter().map(|d| unix(*d)).collect());
            for at in planned {
                *clock.lock().unwrap() = at;
                rt.block_on(e.auto_test_tick());
            }
            assert_eq!(stored(dir.path()).len(), expected, "{network:?}");
        }
    }

    #[test]
    fn missed_minute_is_skipped() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        let (dir, e, _, _) = rig(&rt, NetworkKind::Wifi);
        let clock = clocked(&e, date(2026, 11, 26).at(0, 41, 0, 0));
        e.set_auto_test_plan(vec![unix(date(2026, 11, 26).at(0, 41, 0, 0))]);
        *clock.lock().unwrap() = date(2026, 11, 26).at(0, 44, 30, 0);
        rt.block_on(e.auto_test_tick());
        assert!(stored(dir.path()).is_empty());
    }

    #[test]
    fn late_tick_still_runs_planned_minute() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        let (dir, e, _, _) = rig(&rt, NetworkKind::Wifi);
        let clock = clocked(&e, date(2026, 11, 26).at(0, 40, 0, 0));
        e.set_auto_test_plan(vec![unix(date(2026, 11, 26).at(0, 41, 0, 0))]);
        rt.block_on(e.auto_test_tick());
        *clock.lock().unwrap() = date(2026, 11, 26).at(0, 42, 5, 0);
        rt.block_on(e.auto_test_tick());
        assert_eq!(stored(dir.path()).len(), 1);
        *clock.lock().unwrap() = date(2026, 11, 26).at(0, 43, 5, 0);
        rt.block_on(e.auto_test_tick());
        assert_eq!(stored(dir.path()).len(), 1);
    }

    #[test]
    fn follow_queue_is_always_daily() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        let (dir, e, _, _) = rig(&rt, NetworkKind::Wifi);
        let clock = clocked(&e, date(2026, 11, 25).at(10, 0, 0, 0));
        let id = e.best_time_queue().unwrap();
        let mut c = follow_config(&e, id);
        c.schedule.as_mut().unwrap().repeat = Repeat::Days { mask: 0b11 };
        c.schedule.as_mut().unwrap().wifi = true;
        e.save_queue(c.clone()).unwrap();
        let off = follow_config(&e, id);
        assert!(!off.follow_best_time);
        assert_eq!(off.schedule.as_ref().unwrap().repeat, Repeat::Days { mask: 0b11 });
        e.save_queue(QueueConfig { follow_best_time: true, ..off }).unwrap();
        let on = follow_config(&e, id).schedule.unwrap();
        assert_eq!(on.repeat, Repeat::Daily);
        assert!(on.wifi);
        let new = e.save_queue(QueueConfig { id: None, name: "N".into(), follow_best_time: true, schedule: c.schedule.clone(), ..c }).unwrap();
        assert_eq!(follow_config(&e, new).schedule.unwrap().repeat, Repeat::Daily);
        seed(dir.path(), 17, 8);
        *clock.lock().unwrap() = date(2026, 11, 26).at(10, 0, 0, 0);
        e.tick();
        let s = follow_config(&e, id).schedule.unwrap();
        assert_eq!((s.repeat, s.stop_min, s.wifi), (Repeat::Daily, Some(300), true));
    }

    #[test]
    fn planned_night_tests_fall_in_slots() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        let (dir, e, _, _) = rig(&rt, NetworkKind::Wifi);
        let clock = clocked(&e, date(2026, 11, 25).at(23, 0, 0, 0));
        e.start_night_week();
        let mut ran = 0;
        for h in 0..6 {
            for m in 0..60 {
                *clock.lock().unwrap() = date(2026, 11, 26).at(h, m, 0, 0);
                let before = stored(dir.path()).len();
                rt.block_on(e.auto_test_tick());
                if stored(dir.path()).len() > before {
                    assert_eq!(h / 2, ran, "one test per two-hour slot, in order");
                    ran += 1;
                }
            }
        }
        assert_eq!(ran, 3);
    }

    #[test]
    fn history_and_hourly() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        let (dir, e, _, _) = rig(&rt, NetworkKind::Wifi);
        clocked(&e, date(2026, 11, 25).at(10, 0, 0, 0));
        seed(dir.path(), 17, 8);
        let h = e.hourly_typical();
        assert_eq!(h.len(), 24);
        assert_eq!((h[2], h[10]), (Some(100_000_000), Some(20_000_000)));
        e.clear_speed_history();
        assert!(stored(dir.path()).is_empty());
        assert!(e.hourly_typical().iter().all(Option::is_none));
    }
}
