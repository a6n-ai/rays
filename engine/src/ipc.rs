//! Unix socket listener for the `dl` CLI. See design doc "Socket protocol".
use crate::protocol::{self, Added, BucketLine, JobLine, ListingLine, ObjectLine, ProviderLine, Rejected, Request, Response};
use crate::s3::{self, BucketConfig};
use crate::scheduler::Scheduler;
use crate::types::{EngineError, JobState};
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
        Ok(Request::Add { urls, queue }) => {
            let mut reply = Response { ok: true, ..Default::default() };
            let none = vec![None; urls.len()];
            for result in sched.add_to(urls, None, none, queue) {
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
        Err(e) => Response { error: Some(e.to_string()), ..Default::default() },
    }
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
    use std::os::unix::net::UnixListener as StdListener;

    fn sock_in_tmp() -> (tempfile::TempDir, std::path::PathBuf) {
        let dir = tempfile::Builder::new().tempdir_in("/tmp").unwrap();
        let path = dir.path().join("dl.sock");
        (dir, path)
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
