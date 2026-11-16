//! Unix socket listener for the `dl` CLI. See design doc "Socket protocol".
use crate::protocol::{self, Added, JobLine, Rejected, Request, Response};
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
            respond(&sched, &line)
        };
        let Ok(mut out) = serde_json::to_vec(&reply) else { return };
        out.push(b'\n');
        if write.write_all(&out).await.is_err() || too_long {
            return;
        }
    }
}

fn respond(sched: &Arc<Scheduler>, line: &[u8]) -> Response {
    match serde_json::from_slice::<Request>(line) {
        Ok(Request::Add { urls }) => {
            let mut reply = Response { ok: true, ..Default::default() };
            for result in sched.add(urls) {
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
        Err(e) => Response { error: Some(e.to_string()), ..Default::default() },
    }
}

fn state_name(state: &JobState) -> &'static str {
    match state {
        JobState::Queued => "queued",
        JobState::Running => "running",
        JobState::Paused => "paused",
        JobState::Retrying { .. } => "retrying",
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
