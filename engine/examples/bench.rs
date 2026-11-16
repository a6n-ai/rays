//! Throughput check: `cargo run --release -p dl-engine --example bench -- <url> <connections>`.
use dl_engine::{Engine, EngineConfig, JobState};
use std::time::{Duration, Instant};

fn main() {
    let mut args = std::env::args().skip(1);
    let url = args.next().expect("url");
    let connections: u32 = args.next().map(|c| c.parse().expect("connections")).unwrap_or(1);
    let root = std::env::temp_dir().join(format!("rays-bench-{}", std::process::id()));
    std::fs::create_dir_all(root.join("dl")).unwrap();
    let engine = Engine::new(EngineConfig {
        downloads_dir: root.join("dl").to_string_lossy().into(),
        data_dir: root.join("data").to_string_lossy().into(),
        socket_path: root.join("s.sock").to_string_lossy().into(),
        max_running: 1,
        connections,
        speed_limit: 0,
    })
    .unwrap();
    let start = Instant::now();
    let id = engine.add(vec![url])[0].id.expect("added");
    let (size, peak) = loop {
        std::thread::sleep(Duration::from_millis(200));
        let job = engine.snapshot().into_iter().find(|j| j.id == id).unwrap();
        match job.state {
            JobState::Done { .. } => break (job.done, job.parts.len()),
            JobState::Failed { reason } => panic!("failed: {reason}"),
            _ => {}
        }
    };
    let secs = start.elapsed().as_secs_f64();
    println!("connections={connections} parts={peak} bytes={size} secs={secs:.2} MB/s={:.2}", size as f64 / secs / 1e6);
    engine.shutdown();
    let _ = std::fs::remove_dir_all(&root);
}
