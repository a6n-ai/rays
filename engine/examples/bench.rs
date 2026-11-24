//! Throughput A/B check:
//! `cargo run --release -p dl-engine --example bench -- <url> [connections,connections,...] [runs]`
//! Runs the connection counts interleaved (1,8,1,8,...) so network drift hits both, throws away one warm-up run,
//! then prints the median MB/s per count. Defaults: connections 1,8 and 5 measured runs.
//! RAYS_BENCH_OUT=<path> moves the downloaded file there instead of deleting it.
use dl_engine::{Engine, EngineConfig, JobState};
use std::time::{Duration, Instant};

fn once(url: &str, connections: u32) -> Result<(f64, usize), String> {
    let root = std::env::temp_dir().join(format!("rays-bench-{}-{connections}", std::process::id()));
    std::fs::create_dir_all(root.join("dl")).map_err(|e| e.to_string())?;
    let engine = Engine::new(EngineConfig {
        downloads_dir: root.join("dl").to_string_lossy().into(),
        data_dir: root.join("data").to_string_lossy().into(),
        socket_path: root.join("s.sock").to_string_lossy().into(),
        max_running: 1,
        connections,
        speed_limit: 0,
        hf_base: None,
    })
    .map_err(|e| e.to_string())?;
    let start = Instant::now();
    let id = engine.add(vec![url.to_owned()])[0].id.ok_or("not added")?;
    let result = loop {
        std::thread::sleep(Duration::from_millis(100));
        let job = engine.snapshot().into_iter().find(|j| j.id == id).ok_or("job vanished")?;
        if std::env::var_os("RAYS_BENCH_TRACE").is_some() {
            eprintln!("{:5.1}s {:>4} MB {} connections", start.elapsed().as_secs_f64(), job.done >> 20, job.connections);
        }
        match job.state {
            JobState::Done { .. } => break Ok((job.done as f64 / start.elapsed().as_secs_f64() / 1e6, job.parts.len())),
            JobState::Failed { reason } => break Err(reason),
            _ => {}
        }
    };
    engine.shutdown();
    // RAYS_BENCH_OUT=<path> keeps the file there, so a script can hash it outside the timed run.
    if let (Ok(_), Some(out)) = (&result, std::env::var_os("RAYS_BENCH_OUT")) {
        let file = std::fs::read_dir(root.join("dl")).ok().and_then(|mut d| d.next()?.ok()).ok_or("no file")?;
        std::fs::rename(file.path(), out).map_err(|e| e.to_string())?;
    }
    let _ = std::fs::remove_dir_all(&root);
    result
}

fn median(mut v: Vec<f64>) -> f64 {
    v.sort_by(|a, b| a.total_cmp(b));
    let n = v.len();
    if n % 2 == 1 { v[n / 2] } else { (v[n / 2 - 1] + v[n / 2]) / 2.0 }
}

fn main() {
    let mut args = std::env::args().skip(1);
    let url = args.next().expect("usage: bench <url> [1,8] [runs]");
    let counts: Vec<u32> = args.next().unwrap_or_else(|| "1,8".into()).split(',').map(|c| c.parse().expect("connections")).collect();
    let runs: usize = args.next().map(|r| r.parse().expect("runs")).unwrap_or(5);

    // Warm-up: DNS, TLS session and CDN cache, not counted. scripts/bench-vs.sh warms up once for every tool itself.
    let warm = std::env::var_os("RAYS_BENCH_NO_WARMUP").is_none();
    for &c in counts.iter().filter(|_| warm) {
        if let Err(e) = once(&url, c) {
            eprintln!("warm-up with {c} connections failed: {e}");
            std::process::exit(1);
        }
    }
    let mut speeds = vec![Vec::new(); counts.len()];
    for run in 1..=runs {
        for (i, &c) in counts.iter().enumerate() {
            match once(&url, c) {
                Ok((mbps, parts)) => {
                    println!("run {run} connections={c} parts={parts} MB/s={mbps:.1}");
                    speeds[i].push(mbps);
                }
                Err(e) => println!("run {run} connections={c} failed: {e}"),
            }
        }
    }
    for (i, &c) in counts.iter().enumerate() {
        if !speeds[i].is_empty() {
            println!("median connections={c}: {:.1} MB/s over {} runs", median(speeds[i].clone()), speeds[i].len());
        }
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn median_odd_and_even() {
        assert_eq!(super::median(vec![3.0, 1.0, 2.0]), 2.0);
        assert_eq!(super::median(vec![4.0, 1.0, 3.0, 2.0]), 2.5);
    }
}
