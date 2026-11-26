//! Unix socket listener for the `dl` CLI. See design doc "Socket protocol".
use crate::hf::{self, VerifyStatus};
use crate::protocol::{self, Added, BestTimeLine, BucketLine, GrabLine, JobLine, ListingLine, ObjectLine, ProviderLine, QueueLine, QueueRef, Rejected, Request, Response, SpeedLine, SpeedTestLine, VerifyLine};
use crate::s3::{self, BucketConfig};
use crate::scheduler::Scheduler;
use crate::speed::{BestTime, Confidence};
use crate::speedtest;
use crate::types::{EngineError, JobState, QueueState, QueueView};
use std::io::ErrorKind;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};

const IDLE_TIMEOUT: Duration = Duration::from_secs(10);

/// Binds `path` (parent dir 0700, socket 0600). Stale socket (connect refused) is replaced;
/// a live one returns `EngineError::SocketInUse`. Must be called inside the tokio runtime.
pub fn bind(path: &Path) -> Result<UnixListener, EngineError> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
        std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))?;
    }
    match std::os::unix::net::UnixStream::connect(path) {
        Ok(_) => return Err(EngineError::SocketInUse),
        Err(e) if matches!(e.kind(), ErrorKind::ConnectionRefused | ErrorKind::NotFound) => {}
        Err(e) => return Err(e.into()),
    }
    // A failed removal surfaces as the bind error below.
    let _ = std::fs::remove_file(path);
    let listener = UnixListener::bind(path)?;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    Ok(listener)
}

/// Accept loop: one JSON `Request` line in, one `Response` line out, per request; 10 s idle timeout.
pub async fn serve(listener: UnixListener, sched: Arc<Scheduler>) {
    loop {
        match listener.accept().await {
            Ok((stream, _)) => {
                tokio::spawn(handle(stream, sched.clone()));
            }
            // shortcut: a persistent accept error (e.g. EMFILE) would spin; back off briefly, no retry cap.
            Err(_) => tokio::time::sleep(Duration::from_millis(10)).await,
        }
    }
}

async fn handle(stream: UnixStream, sched: Arc<Scheduler>) {
    let (read, mut write) = stream.into_split();
    let mut reader = BufReader::new(read);
    loop {
        let mut line = Vec::new();
        let limit = protocol::MAX_LINE as u64 + 1;
        let read = tokio::time::timeout(IDLE_TIMEOUT, (&mut reader).take(limit).read_until(b'\n', &mut line)).await;
        if !matches!(read, Ok(Ok(n)) if n > 0) {
            return;
        }
        let too_long = line.last() != Some(&b'\n') && line.len() > protocol::MAX_LINE;
        let reply = if too_long {
            Response { error: Some("line too long".into()), ..Default::default() }
        } else {
            respond(&sched, &line).await
        };
        let Ok(mut out) = serde_json::to_vec(&reply) else { return };
        out.push(b'\n');
        if write.write_all(&out).await.is_err() || too_long {
            return;
        }
    }
}

async fn respond(sched: &Arc<Scheduler>, line: &[u8]) -> Response {
    match serde_json::from_slice::<Request>(line) {
        Ok(Request::Add { urls, queue, best_time, sha256, mirrors, headers }) => {
            let queue = if best_time {
                sched.best_time_queue().map(Some).map_err(|e| e.to_string())
            } else {
                queue.map(|q| find_queue(sched, &q)).transpose()
            };
            let queue = match queue {
                Ok(id) => id,
                Err(e) => return Response { error: Some(e), ..Default::default() },
            };
            let mut reply = Response { ok: true, ..Default::default() };
            let none = vec![None; urls.len()];
            let headers = if headers.is_empty() { Vec::new() } else { vec![headers; urls.len()] };
            for result in sched.add_with(urls, None, none, sha256, mirrors, headers, queue) {
                match result.id {
                    Some(id) => reply.added.push(Added { url: result.url, id }),
                    None => reply.rejected.push(Rejected {
                        url: result.url,
                        reason: result.error.unwrap_or_default(),
                    }),
                }
            }
            reply
        }
        Ok(Request::List) => Response {
            ok: true,
            jobs: sched
                .views()
                .into_iter()
                .map(|v| JobLine { id: v.id, name: v.name, state: state_name(&v.state).into(), done: v.done, total: v.total })
                .collect(),
            ..Default::default()
        },
        Ok(Request::Relink { id, url, restart }) => done(sched.relink(id, &url, restart).await),
        Ok(Request::Grab { url }) => match sched.grab_links(&url).await {
            Ok(links) => Response { ok: true, grabbed: links.into_iter().map(|l| GrabLine { url: l.url, name: l.name, kind: l.kind }).collect(), ..Default::default() },
            Err(e) => Response { error: Some(e.to_string()), ..Default::default() },
        },
        Ok(Request::Queues) => Response { ok: true, queues: sched.queues().into_iter().filter_map(queue_line).collect(), ..Default::default() },
        Ok(Request::Speed) => Response {
            ok: true,
            speed: Some(SpeedLine {
                last: speedtest::last(sched).map(speed_test_line),
                best_time: best_time_line(sched.best_time()),
            }),
            ..Default::default()
        },
        Ok(Request::SpeedTest { force }) => match speedtest::run(sched, speedtest::DEFAULT_BASE, speedtest::DEFAULT_MS, force, &std::sync::atomic::AtomicBool::new(false)).await {
            Ok(result) => Response { ok: true, speed_test: Some(speed_test_line(result)), ..Default::default() },
            Err(e) => Response { error: Some(e.to_string()), ..Default::default() },
        },
        Ok(Request::QueueStart { queue }) => queue_op(sched, &queue, Scheduler::start_queue),
        Ok(Request::QueueStop { queue }) => queue_op(sched, &queue, Scheduler::stop_queue),
        Ok(Request::QueueRunNow { queue }) => queue_op(sched, &queue, Scheduler::run_queue_now),
        Ok(Request::VerifyModel { dir }) => verify_model(&dir).await,
        Ok(Request::Providers) => Response {
            ok: true,
            providers: s3::providers()
                .into_iter()
                .map(|p| ProviderLine { id: p.id, name: p.name, endpoint: p.endpoint, region: p.region, field: p.field, path_style: p.path_style })
                .collect(),
            ..Default::default()
        },
        Ok(Request::Buckets) => Response { ok: true, buckets: sched.buckets().into_iter().map(bucket_line).collect(), ..Default::default() },
        Ok(Request::BucketAdd { name, provider, endpoint, region, field, access_key_id, secret, path_style, profile }) => {
            let added = async {
                let preset = s3::providers().into_iter().find(|p| p.id == provider);
                let preset = preset.ok_or_else(|| EngineError::InvalidUrl { msg: format!("unknown provider {provider}") })?;
                let region = if region.is_empty() { preset.region.clone() } else { region };
                let endpoint = if endpoint.is_empty() { s3::endpoint_for(&provider, &region, &field)? } else { endpoint };
                let path_style = path_style.unwrap_or(preset.path_style);
                let cfg = BucketConfig { name, provider, endpoint, region, access_key_id, path_style, profile };
                sched.add_bucket(cfg, secret).await
            };
            done(added.await)
        }
        Ok(Request::BucketRemove { name }) => done(sched.remove_bucket(&name)),
        Ok(Request::BucketList { bucket, prefix, token }) => match sched.list_bucket(&bucket, &prefix, token).await {
            Ok(l) => Response {
                ok: true,
                listing: Some(ListingLine {
                    folders: l.folders,
                    objects: l.objects.into_iter().map(|o| ObjectLine { key: o.key, size: o.size, modified: o.modified }).collect(),
                    next_token: l.next_token,
                }),
                ..Default::default()
            },
            Err(e) => Response { error: Some(e.to_string()), ..Default::default() },
        },
        // A serde message can quote the request, which may carry header values: keep only the position.
        Err(e) => Response { error: Some(format!("invalid request at line {} column {}", e.line(), e.column())), ..Default::default() },
    }
}

fn queue_op(sched: &Arc<Scheduler>, queue: &QueueRef, op: fn(&Arc<Scheduler>, u64)) -> Response {
    match find_queue(sched, queue) {
        Ok(id) => {
            op(sched, id);
            Response { ok: true, ..Default::default() }
        }
        Err(e) => Response { error: Some(e), ..Default::default() },
    }
}

fn find_queue(sched: &Scheduler, queue: &QueueRef) -> Result<u64, String> {
    let queues: Vec<(u64, String)> = sched.queues().into_iter().filter_map(|q| Some((q.config.id?, q.config.name))).collect();
    resolve_queue(&queues, queue)
}

/// An id; else a name matched case-insensitively exactly, then `main` for the Main queue (id 1), then as a unique prefix.
fn resolve_queue(queues: &[(u64, String)], queue: &QueueRef) -> Result<u64, String> {
    let name = match queue {
        QueueRef::Id(id) => return queues.iter().find(|(i, _)| i == id).map(|(i, _)| *i).ok_or_else(|| format!("no queue \"{id}\"")),
        QueueRef::Name(name) => name,
    };
    let lower = name.to_lowercase();
    let pick = |hits: Vec<u64>, how: &str| match hits.as_slice() {
        [] => Ok(None),
        [id] => Ok(Some(*id)),
        _ => Err(format!("several queues {how} \"{name}\"; use the id")),
    };
    let exact = queues.iter().filter(|(_, n)| n.to_lowercase() == lower).map(|(i, _)| *i).collect();
    if let Some(id) = pick(exact, "are named")? {
        return Ok(id);
    }
    if lower == "main" && queues.iter().any(|(i, _)| *i == 1) {
        return Ok(1);
    }
    let prefix = queues.iter().filter(|(_, n)| n.to_lowercase().starts_with(&lower)).map(|(i, _)| *i).collect();
    pick(prefix, "start with")?.ok_or_else(|| format!("no queue \"{name}\""))
}

fn speed_test_line(r: speedtest::SpeedTestResult) -> SpeedTestLine {
    SpeedTestLine { bps: r.bps, latency_ms: r.latency_ms, at: r.at, saved: r.saved }
}

fn best_time_line(best: BestTime) -> BestTimeLine {
    match best {
        BestTime::Window { start_min, end_min, typical_bps, days, confidence } => BestTimeLine::Window {
            start_min,
            end_min,
            typical_bps,
            days,
            confidence: match confidence {
                Confidence::Low => "low",
                Confidence::Medium => "medium",
                Confidence::High => "high",
            }
            .into(),
        },
        BestTime::NotEnoughData { days, needed } => BestTimeLine::NotEnoughData { days, needed },
    }
}

fn queue_line(q: QueueView) -> Option<QueueLine> {
    let state = match q.state {
        QueueState::Open => "open",
        QueueState::WaitingForTime { .. } => "waiting for time",
        QueueState::WaitingForCondition { .. } => "waiting for condition",
        QueueState::Stopped => "stopped",
        QueueState::Off => "off",
    };
    Some(QueueLine { id: q.config.id?, name: q.config.name, state: state.into(), next_run: q.next_run, queued: q.queued, running: q.running })
}

/// Reads and checks only through `hf`, which rejects unsafe paths and symlinks; nothing else touches `dir`.
async fn verify_model(dir: &str) -> Response {
    let fail = |e: &str| Response { error: Some(e.into()), ..Default::default() };
    let dir = Path::new(dir);
    if !dir.is_absolute() {
        return fail("dir must be an absolute path");
    }
    let Some(manifest) = hf::read_manifest(dir) else {
        return fail("no record of this download (.rays-model.json missing)");
    };
    let results = hf::verify_files(dir, manifest.files).await;
    let bad = |s: &VerifyStatus| !matches!(s, VerifyStatus::Ok | VerifyStatus::SizeChecked);
    let (problems, size_only) = (results.iter().filter(|r| bad(&r.status)).count(), results.iter().filter(|r| r.status == VerifyStatus::SizeChecked).count());
    let missing = results.iter().filter(|r| r.status == VerifyStatus::Missing).count();
    let summary = format!("{} files, {} ok, {problems} with problems ({missing} missing), {size_only} checked by size only", results.len(), results.len() - problems);
    let verified = results
        .into_iter()
        .map(|r| {
            let (status, actual) = match r.status {
                VerifyStatus::Ok => ("ok", None),
                VerifyStatus::SizeChecked => ("size-checked", None),
                VerifyStatus::Missing => ("missing", None),
                VerifyStatus::WrongSize { actual } => ("wrong-size", Some(actual)),
                VerifyStatus::WrongChecksum => ("wrong-checksum", None),
            };
            VerifyLine { path: r.path, status: status.into(), actual }
        })
        .collect();
    Response { ok: true, verified, summary: Some(summary), ..Default::default() }
}

fn done(result: Result<(), EngineError>) -> Response {
    match result {
        Ok(()) => Response { ok: true, ..Default::default() },
        Err(e) => Response { error: Some(e.to_string()), ..Default::default() },
    }
}

fn bucket_line(b: BucketConfig) -> BucketLine {
    BucketLine { name: b.name, provider: b.provider, endpoint: b.endpoint, region: b.region, access_key_id: b.access_key_id, path_style: b.path_style }
}

fn state_name(state: &JobState) -> &'static str {
    match state {
        JobState::Queued => "queued",
        JobState::Running => "running",
        JobState::Paused => "paused",
        JobState::Retrying { .. } => "retrying",
        JobState::Verifying => "verifying",
        JobState::Done { .. } => "done",
        JobState::Failed { .. } => "failed",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::events::EventHub;
    use crate::s3::MemorySecrets;
    use crate::store::Store;
    use std::os::unix::net::UnixListener as StdListener;

    fn sock_in_tmp() -> (tempfile::TempDir, std::path::PathBuf) {
        let dir = tempfile::Builder::new().tempdir_in("/tmp").unwrap();
        let path = dir.path().join("dl.sock");
        (dir, path)
    }

    #[test]
    fn queue_names_resolve_exact_then_main_then_prefix() {
        let qs: Vec<(u64, String)> = [(1, "Main queue"), (2, "Night Shift"), (3, "Night"), (4, "Nightly")].iter().map(|(i, n)| (*i, n.to_string())).collect();
        let by = |n: &str| resolve_queue(&qs, &QueueRef::Name(n.into()));
        assert_eq!(by("MAIN"), Ok(1));
        assert_eq!(by("main queue"), Ok(1));
        assert_eq!(by("night"), Ok(3), "exact beats prefix");
        assert_eq!(by("night s"), Ok(2));
        assert!(by("nigh").unwrap_err().contains("use the id"));
        assert!(by("zzz").unwrap_err().contains("no queue"));
        assert_eq!(resolve_queue(&qs, &QueueRef::Id(4)), Ok(4));
        assert!(resolve_queue(&qs, &QueueRef::Id(9)).is_err());
    }

    #[tokio::test]
    async fn speed_reports_not_enough_data() {
        let dir = tempfile::tempdir().unwrap();
        let store = Arc::new(Store::open(dir.path()).unwrap());
        let secrets = || Arc::new(MemorySecrets::default());
        let sched = Scheduler::new(
            tokio::runtime::Handle::current(),
            store,
            Arc::new(EventHub::new()),
            dir.path().join("downloads"),
            2,
            4,
            0,
            secrets(),
            secrets(),
            "http://127.0.0.1:9".into(),
        )
        .unwrap();
        let speed = respond(&sched, br#"{"op":"speed"}"#).await.speed.unwrap();
        assert!(speed.last.is_none());
        assert!(matches!(speed.best_time, BestTimeLine::NotEnoughData { days: 0, .. }));
    }

    #[tokio::test]
    async fn bind_replaces_stale_socket() {
        let (_dir, path) = sock_in_tmp();
        drop(StdListener::bind(&path).unwrap());
        assert!(path.exists());
        bind(&path).unwrap();
    }

    #[tokio::test]
    async fn bind_reports_live_socket() {
        let (_dir, path) = sock_in_tmp();
        let _live = StdListener::bind(&path).unwrap();
        assert!(matches!(bind(&path), Err(EngineError::SocketInUse)));
    }

    #[tokio::test]
    async fn bind_sets_socket_mode_0600() {
        let (_dir, path) = sock_in_tmp();
        let _listener = bind(&path).unwrap();
        let mode = std::fs::metadata(&path).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600);
    }
}
