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
