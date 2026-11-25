//! Hugging Face search, model info and token. A fake hf server (127.0.0.1) redirects big files to a fake
//! cdn (localhost), so the two hosts differ and the token's path can be checked end to end.
use axum::Router;
use axum::body::Body;
use axum::extract::{Path, RawQuery, State};
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::Response;
use axum::routing::get;
use dl_engine::events::EventHub;
use dl_engine::hf::{HfAddStatus, HfFile};
use dl_engine::s3::{MemorySecrets, Secrets};
use dl_engine::types::EngineError;
use sha2::{Digest, Sha256};
use std::sync::atomic::{AtomicUsize, Ordering};
use dl_engine::scheduler::Scheduler;
use dl_engine::store::Store;
use dl_engine::types::{JobId, JobState, JobView};
use std::net::SocketAddr;
use std::path::{Path as FsPath, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

const SIZE: usize = 2 * 1024 * 1024;
const DROP_AT: usize = 512 * 1024;
const GATED_MSG: &str = "This model is gated: add your Hugging Face token in Settings";
const REJECTED_MSG: &str = "Hugging Face rejected the saved token. Check it in Settings";

type Auths = Arc<Mutex<Vec<Option<String>>>>;

fn data() -> Vec<u8> {
    (0..SIZE).map(|i| ((i * 7 + i / 256) % 256) as u8).collect()
}

#[derive(Clone)]
struct Hf {
    cdn: u16,
    data: Arc<Vec<u8>>,
    auths: Auths,
    flips: Arc<AtomicUsize>,
}

fn auth_of(headers: &HeaderMap) -> Option<String> {
    headers.get(header::AUTHORIZATION).map(|v| v.to_str().unwrap().to_owned())
}

async fn search(State(st): State<Hf>, headers: HeaderMap, RawQuery(q): RawQuery) -> Result<axum::Json<serde_json::Value>, StatusCode> {
    st.auths.lock().unwrap().push(auth_of(&headers));
    if auth_of(&headers).as_deref() == Some("Bearer bad") {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let q = q.unwrap_or_default();
    if !q.contains("search=qwen") || !q.contains("sort=downloads") {
        return Err(StatusCode::BAD_REQUEST);
    }
    Ok(axum::Json(serde_json::json!([
        {"id": "Qwen/Qwen3-GGUF", "gated": "manual", "downloads": 5, "likes": 2, "tags": ["gguf", "text-generation"]},
        {"id": "org/plain", "gated": false, "downloads": 9, "likes": 0, "tags": ["safetensors"]}
    ])))
}

async fn model(State(st): State<Hf>, headers: HeaderMap, Path((org, name)): Path<(String, String)>, RawQuery(q): RawQuery) -> Result<axum::Json<serde_json::Value>, StatusCode> {
    st.auths.lock().unwrap().push(auth_of(&headers));
    if q.as_deref() != Some("blobs=true") || org != "org" || name != "m" {
        return Err(StatusCode::BAD_REQUEST);
    }
    Ok(axum::Json(serde_json::json!({
        "id": "org/m", "sha": "abc123", "gated": "auto", "downloads": 3, "likes": 1, "tags": [],
        "siblings": [
            {"rfilename": "w.gguf", "size": 10, "lfs": {"sha256": "ff00", "size": 10}},
            {"rfilename": "README.md", "size": 5}
        ]
    })))
}

async fn resolve(State(st): State<Hf>, headers: HeaderMap, Path((org, _name, _sha, file)): Path<(String, String, String, String)>) -> Response {
    st.auths.lock().unwrap().push(auth_of(&headers));
    let status = match org.as_str() {
        "gated" => StatusCode::UNAUTHORIZED,
        "lic" => StatusCode::FORBIDDEN,
        "open" => return Response::new(Body::from(st.data.to_vec())),
        // The first answer has a flipped first byte, so the first download fails its hash; later ones are right.
        "flip" => {
            let mut body = st.data.to_vec();
            if st.flips.fetch_add(1, Ordering::SeqCst) == 0 {
                body[0] ^= 0xff;
            }
            return Response::new(Body::from(body));
        }
        _ => {
            return Response::builder()
                .status(StatusCode::FOUND)
                .header(header::LOCATION, format!("http://localhost:{}/{file}", st.cdn))
                .body(Body::empty())
                .unwrap();
        }
    };
    Response::builder().status(status).body(Body::empty()).unwrap()
}

async fn fake_hf(cdn: u16) -> (SocketAddr, Auths) {
    let auths: Auths = Arc::default();
    let st = Hf { cdn, data: Arc::new(data()), auths: auths.clone(), flips: Arc::default() };
    let app = Router::new()
        .route("/api/models", get(search))
        .route("/api/models/{org}/{name}", get(model))
        .route("/{org}/{name}/resolve/{sha}/{*file}", get(resolve))
        .with_state(st);
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    (addr, auths)
}

/// Records (Authorization, Range) per request. The first request without a Range stalls after `DROP_AT`
/// bytes; a ranged request gets the rest.
type Seen = Arc<Mutex<Vec<(Option<String>, Option<String>)>>>;

async fn fake_cdn() -> (u16, Seen) {
    let seen: Seen = Arc::default();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let body = Arc::new(data());
    let log = seen.clone();
    tokio::spawn(async move {
        while let Ok((mut sock, _)) = listener.accept().await {
            let (body, log) = (body.clone(), log.clone());
            tokio::spawn(async move {
                let Some(head) = read_head(&mut sock).await else { return };
                if head.split_whitespace().nth(1).is_some_and(|p| p.contains("deny")) {
                    let _ = sock.write_all(b"HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").await;
                    return;
                }
                let auth = header_value(&head, "authorization");
                let range = header_value(&head, "range");
                log.lock().unwrap().push((auth, range.clone()));
                let start = range.as_deref().and_then(|r| r.strip_prefix("bytes=")?.strip_suffix('-')?.parse::<usize>().ok());
                let (status, extra) = match start {
                    Some(from) => ("206 Partial Content", format!("Content-Range: bytes {from}-{}/{}\r\n", SIZE - 1, SIZE)),
                    None => ("200 OK", String::new()),
                };
                let from = start.unwrap_or(0);
                let head = format!(
                    "HTTP/1.1 {status}\r\nContent-Length: {}\r\n{extra}ETag: \"v1\"\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n",
                    SIZE - from
                );
                let _ = sock.write_all(head.as_bytes()).await;
                if start.is_some() {
                    let _ = sock.write_all(&body[from..]).await;
                } else {
                    let _ = sock.write_all(&body[..DROP_AT]).await;
                    std::future::pending::<()>().await;
                }
            });
        }
    });
    (port, seen)
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

fn header_value(head: &str, name: &str) -> Option<String> {
    head.lines().skip(1).find_map(|l| {
        let (k, v) = l.split_once(':')?;
        k.eq_ignore_ascii_case(name).then(|| v.trim().to_owned())
    })
}

fn scheduler(root: &FsPath, hf_base: String) -> (Arc<Scheduler>, Arc<MemorySecrets>) {
    let hf_secrets = Arc::new(MemorySecrets::default());
    (scheduler_with(root, hf_base, hf_secrets.clone()), hf_secrets)
}

fn scheduler_with(root: &FsPath, hf_base: String, hf_secrets: Arc<dyn Secrets>) -> Arc<Scheduler> {
    let store = Arc::new(Store::open(&root.join("data")).unwrap());
    let downloads = root.join("downloads");
    std::fs::create_dir_all(&downloads).unwrap();
    Scheduler::new(
        tokio::runtime::Handle::current(),
        store,
        Arc::new(EventHub::new()),
        downloads,
        2,
        1,
        0,
        Arc::new(MemorySecrets::default()),
        hf_secrets,
        hf_base,
    )
    .unwrap()
}

/// Counts token reads, so a test can see whether a download touched the Keychain at all.
#[derive(Default)]
struct Counting {
    inner: MemorySecrets,
    gets: AtomicUsize,
}

impl Secrets for Counting {
    fn get(&self, bucket: &str) -> Option<String> {
        self.gets.fetch_add(1, Ordering::SeqCst);
        self.inner.get(bucket)
    }
    fn set(&self, bucket: &str, secret: &str) -> Result<(), EngineError> {
        self.inner.set(bucket, secret)
    }
    fn delete(&self, bucket: &str) {
        self.inner.delete(bucket)
    }
}

fn add(sched: &Arc<Scheduler>, dir: &FsPath, url: String) -> JobId {
    sched.add_to(vec![url], Some(PathBuf::from(dir)), vec![Some("w.gguf".into())])[0].id.expect("queued")
}

async fn wait_for(sched: &Scheduler, id: JobId, done: impl Fn(&JobView) -> bool) -> JobView {
    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        if let Some(v) = sched.view(id).filter(|v| done(v)) {
            return v;
        }
        assert!(Instant::now() < deadline, "job {id} did not reach the awaited state: {:?}", sched.view(id));
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn search_parses_fields() {
    let (cdn, _) = fake_cdn().await;
    let (hf, _) = fake_hf(cdn).await;
    let dir = tempfile::tempdir().unwrap();
    let (sched, _) = scheduler(dir.path(), format!("http://{hf}"));
    let models = sched.hf_search("qwen").await.unwrap();
    assert_eq!(models.len(), 2);
    assert_eq!(models[0].id, "Qwen/Qwen3-GGUF");
    assert!(models[0].gated, "manual gating maps to gated");
    assert!(models[0].gguf);
    assert_eq!((models[0].downloads, models[0].likes), (5, 2));
    assert!(!models[1].gated && !models[1].gguf);
}

#[tokio::test(flavor = "multi_thread")]
async fn model_parses_siblings() {
    let (cdn, _) = fake_cdn().await;
    let (hf, _) = fake_hf(cdn).await;
    let dir = tempfile::tempdir().unwrap();
    let (sched, _) = scheduler(dir.path(), format!("http://{hf}"));
    let repo = sched.hf_model("org/m").await.unwrap();
    assert_eq!(repo.sha, "abc123");
    assert!(repo.gated);
    assert_eq!(repo.files[0], HfFile { path: "w.gguf".into(), size: 10, sha256: Some("ff00".into()) });
    assert_eq!(repo.files[1], HfFile { path: "README.md".into(), size: 5, sha256: None });
}

#[tokio::test(flavor = "multi_thread")]
async fn api_calls_send_token_when_saved() {
    let (cdn, _) = fake_cdn().await;
    let (hf, auths) = fake_hf(cdn).await;
    let dir = tempfile::tempdir().unwrap();
    let (sched, _) = scheduler(dir.path(), format!("http://{hf}"));
    assert!(!sched.has_hf_token());
    sched.set_hf_token(Some("t")).unwrap();
    assert!(sched.has_hf_token());
    sched.hf_search("qwen").await.unwrap();
    sched.hf_model("org/m").await.unwrap();
    assert_eq!(*auths.lock().unwrap(), vec![Some("Bearer t".to_string()), Some("Bearer t".to_string())]);
    sched.set_hf_token(None).unwrap();
    assert!(!sched.has_hf_token());
}

#[tokio::test(flavor = "multi_thread")]
async fn rejected_saved_token_is_explained() {
    let (cdn, _) = fake_cdn().await;
    let (hf, _) = fake_hf(cdn).await;
    let dir = tempfile::tempdir().unwrap();
    let (sched, _) = scheduler(dir.path(), format!("http://{hf}"));
    sched.set_hf_token(Some("bad")).unwrap();
    let err = sched.hf_search("qwen").await.unwrap_err().to_string();
    assert!(err.contains("rejected the saved token"), "{err}");
}

#[tokio::test(flavor = "multi_thread")]
async fn token_only_to_hf_host() {
    let (cdn, seen) = fake_cdn().await;
    let (hf, auths) = fake_hf(cdn).await;
    let dir = tempfile::tempdir().unwrap();
    let (sched, _) = scheduler(dir.path(), format!("http://127.0.0.1:{}", hf.port()));
    sched.set_hf_token(Some("t")).unwrap();
    let id = add(&sched, dir.path(), format!("http://127.0.0.1:{}/org/m/resolve/abc/w.gguf", hf.port()));
    wait_for(&sched, id, |v| v.done >= DROP_AT as u64).await;
    sched.pause(id);
    wait_for(&sched, id, |v| matches!(v.state, JobState::Paused)).await;
    sched.resume(id);
    let done = wait_for(&sched, id, |v| matches!(v.state, JobState::Done { .. })).await;
    let JobState::Done { path } = done.state else { unreachable!() };
    assert!(std::fs::read(path).unwrap() == data());

    let auths = auths.lock().unwrap().clone();
    assert!(auths.len() >= 2 && auths.iter().all(|a| a.as_deref() == Some("Bearer t")), "{auths:?}");
    let seen = seen.lock().unwrap().clone();
    assert_eq!(seen.len(), 2, "first attempt, then the ranged resume: {seen:?}");
    assert!(seen.iter().all(|(auth, _)| auth.is_none()), "cdn saw a token: {seen:?}");
    assert!(seen[0].1.is_none());
    assert!(seen[1].1.as_deref().is_some_and(|r| r.starts_with("bytes=")), "{seen:?}");
}

#[tokio::test(flavor = "multi_thread")]
async fn gated_401_message() {
    let (cdn, _) = fake_cdn().await;
    let (hf, _) = fake_hf(cdn).await;
    let dir = tempfile::tempdir().unwrap();
    let (sched, _) = scheduler(dir.path(), format!("http://127.0.0.1:{}", hf.port()));
    let id = add(&sched, dir.path(), format!("http://127.0.0.1:{}/gated/m/resolve/abc/w.gguf", hf.port()));
    let v = wait_for(&sched, id, |v| matches!(v.state, JobState::Failed { .. })).await;
    assert!(matches!(&v.state, JobState::Failed { reason } if reason == GATED_MSG), "{:?}", v.state);

    let id = add(&sched, dir.path(), format!("http://127.0.0.1:{}/lic/m/resolve/abc/w.gguf", hf.port()));
    let v = wait_for(&sched, id, |v| matches!(v.state, JobState::Failed { .. })).await;
    let want = format!("Accept this model's license at http://127.0.0.1:{}/lic/m", hf.port());
    assert!(matches!(&v.state, JobState::Failed { reason } if *reason == want), "{:?}", v.state);
}

#[tokio::test(flavor = "multi_thread")]
async fn gated_401_with_saved_token_says_rejected() {
    let (cdn, _) = fake_cdn().await;
    let (hf, _) = fake_hf(cdn).await;
    let dir = tempfile::tempdir().unwrap();
    let (sched, _) = scheduler(dir.path(), format!("http://127.0.0.1:{}", hf.port()));
    sched.set_hf_token(Some("t")).unwrap();
    let id = add(&sched, dir.path(), format!("http://127.0.0.1:{}/gated/m/resolve/abc/w.gguf", hf.port()));
    let v = wait_for(&sched, id, |v| matches!(v.state, JobState::Failed { .. })).await;
    assert!(matches!(&v.state, JobState::Failed { reason } if reason == REJECTED_MSG), "{:?}", v.state);
}

#[tokio::test(flavor = "multi_thread")]
async fn no_token_no_header() {
    let (cdn, _) = fake_cdn().await;
    let (hf, auths) = fake_hf(cdn).await;
    let dir = tempfile::tempdir().unwrap();
    let (sched, _) = scheduler(dir.path(), format!("http://127.0.0.1:{}", hf.port()));
    let id = add(&sched, dir.path(), format!("http://127.0.0.1:{}/open/m/resolve/abc/w.gguf", hf.port()));
    wait_for(&sched, id, |v| matches!(v.state, JobState::Done { .. })).await;
    assert_eq!(*auths.lock().unwrap(), vec![None]);
}

#[tokio::test(flavor = "multi_thread")]
async fn cdn_401_after_redirect_keeps_status() {
    let (cdn, _) = fake_cdn().await;
    let (hf, _) = fake_hf(cdn).await;
    let dir = tempfile::tempdir().unwrap();
    let (sched, _) = scheduler(dir.path(), format!("http://127.0.0.1:{}", hf.port()));
    let id = add(&sched, dir.path(), format!("http://127.0.0.1:{}/bounce/m/resolve/abc/deny", hf.port()));
    let v = wait_for(&sched, id, |v| matches!(v.state, JobState::Failed { .. })).await;
    assert!(matches!(&v.state, JobState::Failed { reason } if reason == "HTTP 401"), "{:?}", v.state);
}

#[tokio::test(flavor = "multi_thread")]
async fn non_hf_401_and_403_keep_status() {
    let (cdn, _) = fake_cdn().await;
    let (hf, _) = fake_hf(cdn).await;
    let dir = tempfile::tempdir().unwrap();
    let (sched, _) = scheduler(dir.path(), "http://127.0.0.1:1".into());
    for (org, want) in [("gated", "HTTP 401"), ("lic", "HTTP 403")] {
        let id = add(&sched, dir.path(), format!("http://127.0.0.1:{}/{org}/m/resolve/abc/w.gguf", hf.port()));
        let v = wait_for(&sched, id, |v| matches!(v.state, JobState::Failed { .. })).await;
        assert!(matches!(&v.state, JobState::Failed { reason } if reason == want), "{:?}", v.state);
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn non_hf_download_never_reads_token() {
    let (cdn, _) = fake_cdn().await;
    let (hf, auths) = fake_hf(cdn).await;
    let dir = tempfile::tempdir().unwrap();
    let secrets = Arc::new(Counting::default());
    let sched = scheduler_with(dir.path(), "http://127.0.0.1:1".into(), secrets.clone());
    let id = add(&sched, dir.path(), format!("http://127.0.0.1:{}/open/m/resolve/abc/w.gguf", hf.port()));
    wait_for(&sched, id, |v| matches!(v.state, JobState::Done { .. })).await;
    assert_eq!(secrets.gets.load(Ordering::SeqCst), 0);
    assert_eq!(*auths.lock().unwrap(), vec![None]);
}

#[tokio::test(flavor = "multi_thread")]
async fn hf_job_reads_token_once() {
    let (cdn, _) = fake_cdn().await;
    let (hf, auths) = fake_hf(cdn).await;
    let dir = tempfile::tempdir().unwrap();
    let secrets = Arc::new(Counting::default());
    let sched = scheduler_with(dir.path(), format!("http://127.0.0.1:{}", hf.port()), secrets.clone());
    sched.set_hf_token(Some("t")).unwrap();
    for name in ["a.gguf", "b.gguf"] {
        let url = format!("http://127.0.0.1:{}/open/m/resolve/abc/{name}", hf.port());
        let id = sched.add_to(vec![url], Some(dir.path().to_path_buf()), vec![None])[0].id.unwrap();
        wait_for(&sched, id, |v| matches!(v.state, JobState::Done { .. })).await;
    }
    assert_eq!(secrets.gets.load(Ordering::SeqCst), 0, "set_hf_token fills the cache");
    assert_eq!(*auths.lock().unwrap(), vec![Some("Bearer t".to_string()), Some("Bearer t".to_string())]);
}

#[tokio::test(flavor = "multi_thread")]
async fn model_rejects_bad_repo() {
    let (cdn, _) = fake_cdn().await;
    let (hf, auths) = fake_hf(cdn).await;
    let dir = tempfile::tempdir().unwrap();
    let (sched, _) = scheduler(dir.path(), format!("http://127.0.0.1:{}", hf.port()));
    for bad in ["x?blobs=false&a=", "a#", "org/m/extra", "org/", "/m", "", "org/m?x", "org/a b", "org/..", "../m"] {
        assert!(matches!(sched.hf_model(bad).await, Err(EngineError::InvalidUrl { .. })), "{bad} was not rejected");
    }
    assert!(auths.lock().unwrap().is_empty(), "a bad repo reached the hf server");
}

fn file(path: &str, size: u64, sha256: Option<String>) -> HfFile {
    HfFile { path: path.into(), size, sha256 }
}

fn data_sha() -> String {
    Sha256::digest(data()).iter().map(|b| format!("{b:02x}")).collect()
}

#[tokio::test(flavor = "multi_thread")]
async fn adds_into_repo_paths() {
    let (cdn, _) = fake_cdn().await;
    let (hf, _) = fake_hf(cdn).await;
    let dir = tempfile::tempdir().unwrap();
    let (sched, _) = scheduler(dir.path(), format!("http://127.0.0.1:{}", hf.port()));
    let dest = dir.path().join("tmp/AI Models/open/m");
    let files = vec![file("w.gguf", SIZE as u64, None), file("onnx/m.onnx", SIZE as u64, None)];
    let res = sched.add_hf("open/m", "abc", files, &dest);
    assert_eq!(res.len(), 2);
    for r in &res {
        let HfAddStatus::Added { id } = r.status else { panic!("{r:?}") };
        wait_for(&sched, id, |v| matches!(v.state, JobState::Done { .. })).await;
    }
    assert!(std::fs::read(dest.join("w.gguf")).unwrap() == data());
    assert!(std::fs::read(dest.join("onnx/m.onnx")).unwrap() == data());
}

#[tokio::test(flavor = "multi_thread")]
async fn rejects_unsafe_paths() {
    let (cdn, _) = fake_cdn().await;
    let (hf, _) = fake_hf(cdn).await;
    let dir = tempfile::tempdir().unwrap();
    let (sched, _) = scheduler(dir.path(), format!("http://127.0.0.1:{}", hf.port()));
    let dest = dir.path().join("tmp/AI Models/open/m");
    let files = vec![file("../x", 1, None), file("/etc/x", 1, None), file("a/../../x", 1, None)];
    let res = sched.add_hf("open/m", "abc", files, &dest);
    assert_eq!(res.len(), 3);
    for r in &res {
        assert!(matches!(r.status, HfAddStatus::Rejected { .. }), "{r:?}");
    }
    assert!(sched.views().is_empty());
}

#[tokio::test(flavor = "multi_thread")]
async fn already_there_by_size() {
    let (cdn, _) = fake_cdn().await;
    let (hf, _) = fake_hf(cdn).await;
    let dir = tempfile::tempdir().unwrap();
    let (sched, _) = scheduler(dir.path(), format!("http://127.0.0.1:{}", hf.port()));
    let dest = dir.path().join("tmp/AI Models/open/m");
    std::fs::create_dir_all(dest.join("onnx")).unwrap();
    std::fs::write(dest.join("w.gguf"), vec![0u8; SIZE]).unwrap();
    std::fs::write(dest.join("onnx/m.onnx"), b"old").unwrap();
    let files = vec![file("w.gguf", SIZE as u64, None), file("onnx/m.onnx", SIZE as u64, None)];
    let res = sched.add_hf("open/m", "abc", files, &dest);
    assert_eq!(res[0].status, HfAddStatus::AlreadyThere);
    let HfAddStatus::Added { id } = res[1].status else { panic!("{:?}", res[1]) };
    assert_eq!(sched.views().len(), 1, "the file already there made no job");
    wait_for(&sched, id, |v| matches!(v.state, JobState::Done { .. })).await;
    assert_eq!(std::fs::read(dest.join("onnx/m.onnx")).unwrap(), b"old");
    assert!(std::fs::read(dest.join("onnx/m (1).onnx")).unwrap() == data());
}

#[tokio::test(flavor = "multi_thread")]
async fn sha_checked_on_finish() {
    let (cdn, _) = fake_cdn().await;
    let (hf, _) = fake_hf(cdn).await;
    let dir = tempfile::tempdir().unwrap();
    let (sched, _) = scheduler(dir.path(), format!("http://127.0.0.1:{}", hf.port()));

    let good = dir.path().join("good");
    let res = sched.add_hf("open/m", "abc", vec![file("w.gguf", SIZE as u64, Some(data_sha()))], &good);
    let HfAddStatus::Added { id } = res[0].status else { panic!("{:?}", res[0]) };
    let done = wait_for(&sched, id, |v| matches!(v.state, JobState::Done { .. })).await;
    let JobState::Done { path } = done.state else { unreachable!() };
    assert!(std::fs::read(path).unwrap() == data());

    let bad = dir.path().join("bad");
    let res = sched.add_hf("flip/m", "abc", vec![file("w.gguf", SIZE as u64, Some(data_sha()))], &bad);
    let HfAddStatus::Added { id } = res[0].status else { panic!("{:?}", res[0]) };
    let v = wait_for(&sched, id, |v| matches!(v.state, JobState::Failed { .. })).await;
    assert!(matches!(&v.state, JobState::Failed { reason } if reason == "Checksum didn't match"), "{:?}", v.state);
    assert_eq!(v.done, 0);
    assert!(std::fs::read_dir(&bad).unwrap().next().is_none(), "the file or its .part was left behind");

    sched.resume(id);
    let v = wait_for(&sched, id, |v| matches!(v.state, JobState::Done { .. })).await;
    let JobState::Done { path } = v.state else { unreachable!() };
    assert!(std::fs::read(path).unwrap() == data());
    let names: Vec<String> = std::fs::read_dir(&bad).unwrap().map(|e| e.unwrap().file_name().into_string().unwrap()).collect();
    assert_eq!(names, vec!["w.gguf".to_string()], "no .part left behind");
}

/// Starts a download that stalls at DROP_AT, pauses it, shuts the engine down and reopens it on the same data dir.
async fn stall_pause_and_reopen(root: &FsPath, base: String, dest: &FsPath, sha: String) -> (Arc<Scheduler>, JobId) {
    let (sched, _) = scheduler(root, base.clone());
    let res = sched.add_hf("org/m", "abc", vec![file("w.gguf", SIZE as u64, Some(sha))], dest);
    let HfAddStatus::Added { id } = res[0].status else { panic!("{:?}", res[0]) };
    wait_for(&sched, id, |v| v.done >= DROP_AT as u64).await;
    sched.pause(id);
    wait_for(&sched, id, |v| matches!(v.state, JobState::Paused)).await;
    sched.shutdown();
    drop(sched);
    (scheduler_with(root, base, Arc::new(MemorySecrets::default())), id)
}

#[tokio::test(flavor = "multi_thread")]
async fn restart_keeps_dir_name_hash() {
    let (cdn, _) = fake_cdn().await;
    let (hf, _) = fake_hf(cdn).await;
    let dir = tempfile::tempdir().unwrap();
    let dest = dir.path().join("models/org/m");
    let (sched, id) = stall_pause_and_reopen(dir.path(), format!("http://127.0.0.1:{}", hf.port()), &dest, data_sha()).await;

    sched.resume(id);
    let done = wait_for(&sched, id, |v| matches!(v.state, JobState::Done { .. })).await;
    let JobState::Done { path } = done.state else { unreachable!() };
    assert_eq!(FsPath::new(&path), dest.join("w.gguf"));
    assert!(std::fs::read(&path).unwrap() == data());
}

#[tokio::test(flavor = "multi_thread")]
async fn restart_keeps_the_hash_for_the_check() {
    let (cdn, _) = fake_cdn().await;
    let (hf, _) = fake_hf(cdn).await;
    let dir = tempfile::tempdir().unwrap();
    let dest = dir.path().join("models/org/m");
    let (sched, id) = stall_pause_and_reopen(dir.path(), format!("http://127.0.0.1:{}", hf.port()), &dest, "0".repeat(64)).await;

    sched.resume(id);
    let v = wait_for(&sched, id, |v| matches!(v.state, JobState::Failed { .. })).await;
    assert!(matches!(&v.state, JobState::Failed { reason } if reason == "Checksum didn't match"), "{:?}", v.state);
}

#[tokio::test(flavor = "multi_thread")]
async fn add_again_while_queued_is_not_a_second_job() {
    let (cdn, _) = fake_cdn().await;
    let (hf, _) = fake_hf(cdn).await;
    let dir = tempfile::tempdir().unwrap();
    let (sched, _) = scheduler(dir.path(), format!("http://127.0.0.1:{}", hf.port()));
    let dest = dir.path().join("models");
    let res = sched.add_hf("org/m", "abc", vec![file("w.gguf", SIZE as u64, None)], &dest);
    let HfAddStatus::Added { id } = res[0].status else { panic!("{:?}", res[0]) };
    wait_for(&sched, id, |v| v.done >= DROP_AT as u64).await;

    let again = sched.add_hf("org/m", "abc", vec![file("w.gguf", SIZE as u64, None)], &dest);
    assert_eq!(again[0].status, HfAddStatus::AlreadyQueued { id });
    assert_eq!(sched.views().len(), 1, "the second add made a job");
    sched.shutdown();
}
