//! Hugging Face search, model info and token. A fake hf server (127.0.0.1) redirects big files to a fake
//! cdn (localhost), so the two hosts differ and the token's path can be checked end to end.
use axum::Router;
use axum::body::Body;
use axum::extract::{Path, RawQuery, State};
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::Response;
use axum::routing::get;
use dl_engine::events::EventHub;
use dl_engine::hf::HfFile;
use dl_engine::s3::MemorySecrets;
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
const LICENSE_MSG: &str = "Accept this model's license on huggingface.co";

type Auths = Arc<Mutex<Vec<Option<String>>>>;

fn data() -> Vec<u8> {
    (0..SIZE).map(|i| ((i * 7 + i / 256) % 256) as u8).collect()
}

#[derive(Clone)]
struct Hf {
    cdn: u16,
    data: Arc<Vec<u8>>,
    auths: Auths,
}

fn auth_of(headers: &HeaderMap) -> Option<String> {
    headers.get(header::AUTHORIZATION).map(|v| v.to_str().unwrap().to_owned())
}

async fn search(State(st): State<Hf>, headers: HeaderMap, RawQuery(q): RawQuery) -> Result<axum::Json<serde_json::Value>, StatusCode> {
    st.auths.lock().unwrap().push(auth_of(&headers));
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
    let st = Hf { cdn, data: Arc::new(data()), auths: auths.clone() };
    let app = Router::new()
        .route("/api/models", get(search))
        .route("/api/models/{org}/{name}", get(model))
        .route("/{org}/{name}/resolve/{sha}/{file}", get(resolve))
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
    let store = Arc::new(Store::open(&root.join("data")).unwrap());
    let downloads = root.join("downloads");
    std::fs::create_dir_all(&downloads).unwrap();
    let hf_secrets = Arc::new(MemorySecrets::default());
    let sched = Scheduler::new(
        tokio::runtime::Handle::current(),
        store,
        Arc::new(EventHub::new()),
        downloads,
        2,
        1,
        0,
        Arc::new(MemorySecrets::default()),
        hf_secrets.clone(),
        hf_base,
    )
    .unwrap();
    (sched, hf_secrets)
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
    assert!(matches!(&v.state, JobState::Failed { reason } if reason == LICENSE_MSG), "{:?}", v.state);
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
