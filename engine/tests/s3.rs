//! S3 buckets end to end against a local fake S3 server that refuses unsigned requests and serves `Range`.
use axum::Router;
use axum::body::Body;
use axum::extract::{Path, RawQuery, State};
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::Response;
use axum::routing::get;
use dl_engine::events::EventHub;
use dl_engine::s3::{BucketConfig, MemorySecrets};
use dl_engine::scheduler::Scheduler;
use dl_engine::store::Store;
use dl_engine::JobState;
use sha2::{Digest, Sha256};
use std::net::SocketAddr;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

const SECRET: &str = "wJalrXUtnFEMI-test-secret";

#[derive(Clone)]
struct Fake {
    data: Arc<Vec<u8>>,
    signed_gets: Arc<AtomicUsize>,
    ranges: Arc<Mutex<Vec<String>>>,
}

fn signed(query: &Option<String>) -> bool {
    query.as_deref().is_some_and(|q| q.contains("X-Amz-Signature=") && q.contains("X-Amz-Credential=AKID"))
}

async fn list(State(_): State<Fake>, Path(bucket): Path<String>, RawQuery(q): RawQuery) -> Response {
    if !signed(&q) || bucket != "media" {
        return Response::builder().status(StatusCode::FORBIDDEN).body(Body::from("<Error><Code>AccessDenied</Code></Error>")).unwrap();
    }
    let xml = r#"<?xml version="1.0" encoding="UTF-8"?>
<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>media</Name><Prefix></Prefix><KeyCount>2</KeyCount>
<MaxKeys>1000</MaxKeys><Delimiter>/</Delimiter><IsTruncated>false</IsTruncated>
<Contents><Key>big.bin</Key><LastModified>2026-11-01T00:00:00.000Z</LastModified><ETag>"e"</ETag><Size>12582912</Size><StorageClass>STANDARD</StorageClass></Contents>
<CommonPrefixes><Prefix>photos/</Prefix></CommonPrefixes></ListBucketResult>"#;
    Response::builder().header(header::CONTENT_TYPE, "application/xml").body(Body::from(xml)).unwrap()
}

async fn object(State(f): State<Fake>, Path((bucket, key)): Path<(String, String)>, RawQuery(q): RawQuery, headers: HeaderMap) -> Response {
    if !signed(&q) || bucket != "media" || key != "big.bin" {
        return Response::builder().status(StatusCode::FORBIDDEN).body(Body::empty()).unwrap();
    }
    f.signed_gets.fetch_add(1, Ordering::SeqCst);
    let len = f.data.len();
    let range = headers.get(header::RANGE).and_then(|v| v.to_str().ok()).map(str::to_owned);
    let Some(range) = range else {
        return Response::builder()
            .header(header::ACCEPT_RANGES, "bytes")
            .header(header::CONTENT_LENGTH, len)
            .header(header::ETAG, "\"e\"")
            .body(Body::from(f.data.to_vec()))
            .unwrap();
    };
    f.ranges.lock().unwrap().push(range.clone());
    let spec = range.trim_start_matches("bytes=");
    let (a, b) = spec.split_once('-').unwrap();
    let a: usize = a.parse().unwrap();
    let b: usize = if b.is_empty() { len - 1 } else { b.parse::<usize>().unwrap().min(len - 1) };
    Response::builder()
        .status(StatusCode::PARTIAL_CONTENT)
        .header(header::ACCEPT_RANGES, "bytes")
        .header(header::CONTENT_RANGE, format!("bytes {a}-{b}/{len}"))
        .header(header::CONTENT_LENGTH, b - a + 1)
        .header(header::ETAG, "\"e\"")
        .body(Body::from(f.data[a..=b].to_vec()))
        .unwrap()
}

async fn fake_s3(fake: Fake) -> SocketAddr {
    let app = Router::new().route("/{bucket}", get(list)).route("/{bucket}/", get(list)).route("/{bucket}/{*key}", get(object)).with_state(fake);
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    addr
}

fn bucket(addr: SocketAddr) -> BucketConfig {
    BucketConfig {
        name: "media".into(),
        provider: "minio".into(),
        endpoint: format!("http://{addr}"),
        region: "us-east-1".into(),
        access_key_id: "AKID".into(),
        path_style: true,
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn bucket_lists_and_downloads_with_signed_ranged_requests() {
    let data: Arc<Vec<u8>> = Arc::new((0..12 << 20).map(|i: usize| (i * 7 % 251) as u8).collect());
    let fake = Fake { data: data.clone(), signed_gets: Arc::default(), ranges: Arc::default() };
    let addr = fake_s3(fake.clone()).await;
    let dir = tempfile::tempdir().unwrap();
    let store = Arc::new(Store::open(&dir.path().join("data")).unwrap());
    let secrets = Arc::new(MemorySecrets::default());
    let downloads = dir.path().join("downloads");
    std::fs::create_dir_all(&downloads).unwrap();
    let sched = Scheduler::new(tokio::runtime::Handle::current(), store, Arc::new(EventHub::new()), downloads, 2, 4, 0, secrets.clone()).unwrap();

    // Bad keys never get saved.
    let wrong = BucketConfig { access_key_id: "WRONG".into(), ..bucket(addr) };
    let err = sched.add_bucket(wrong, SECRET.into()).await.unwrap_err();
    assert!(err.to_string().contains("AccessDenied"), "{err}");
    assert!(sched.buckets().is_empty());

    sched.add_bucket(bucket(addr), SECRET.into()).await.unwrap();
    assert_eq!(sched.buckets(), vec![bucket(addr)]);

    let listing = sched.list_bucket("media", "", None).await.unwrap();
    assert_eq!(listing.folders, vec!["photos/".to_string()]);
    assert_eq!((listing.objects[0].key.as_str(), listing.objects[0].size), ("big.bin", 12 << 20));

    let added = sched.add(vec!["s3://media/big.bin".into(), "s3://unknown/x".into()]);
    assert!(added[0].error.is_none(), "{:?}", added[0].error);
    assert!(added[1].error.as_deref().unwrap().contains("no bucket named unknown"));

    let deadline = Instant::now() + Duration::from_secs(30);
    let path = loop {
        let view = sched.views().into_iter().find(|v| v.url == "s3://media/big.bin").unwrap();
        match view.state {
            JobState::Done { path } => break path,
            JobState::Failed { reason } => panic!("failed: {reason}"),
            _ => {}
        }
        assert!(Instant::now() < deadline, "not done: {view:?}");
        tokio::time::sleep(Duration::from_millis(20)).await;
    };
    assert!(path.ends_with("big.bin"), "{path}");
    assert_eq!(Sha256::digest(std::fs::read(&path).unwrap()), Sha256::digest(data.as_slice()));
    assert!(fake.signed_gets.load(Ordering::SeqCst) >= 1);

    // The secret lives only in the secret store, never in the database.
    assert!(secrets_in_db(dir.path()).is_empty());
    sched.remove_bucket("media").unwrap();
    assert!(sched.buckets().is_empty());
    use dl_engine::s3::Secrets;
    assert_eq!(secrets.get("media"), None);
}

fn secrets_in_db(dir: &std::path::Path) -> Vec<String> {
    let mut hits = vec![];
    for entry in std::fs::read_dir(dir.join("data")).unwrap() {
        let path = entry.unwrap().path();
        if std::fs::read(&path).unwrap().windows(SECRET.len()).any(|w| w == SECRET.as_bytes()) {
            hits.push(path.display().to_string());
        }
    }
    hits
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn every_part_request_is_signed_fresh() {
    use dl_engine::download;
    use dl_engine::Outcome;
    use dl_engine::limit::RateLimiter;
    use dl_engine::s3::Signer;
    use dl_engine::{Job, Live, names};
    use std::sync::atomic::{AtomicU32, AtomicU64};
    use tokio::sync::watch;

    let data: Arc<Vec<u8>> = Arc::new((0..12 << 20).map(|i: usize| (i * 11 % 253) as u8).collect());
    let fake = Fake { data: data.clone(), signed_gets: Arc::default(), ranges: Arc::default() };
    let addr = fake_s3(fake.clone()).await;
    let dir = tempfile::tempdir().unwrap();
    let signer = Signer::new(&bucket(addr), SECRET).unwrap();
    let signs = Arc::new(AtomicUsize::new(0));
    let counted = signs.clone();
    let sign: download::SignUrl = Arc::new(move || {
        counted.fetch_add(1, Ordering::SeqCst);
        signer.get("big.bin")
    });
    let (tx, rx) = watch::channel(false);
    let job = Job {
        id: 1,
        url: "s3://media/big.bin".into(),
        name: "big.bin".into(),
        part_path: names::part_path(dir.path(), "big.bin", 1),
        final_path: None,
        done: 0,
        total: None,
        etag: None,
        last_modified: None,
        resumable: true,
        state: JobState::Queued,
        segments: Vec::new(),
        position: 0,
        created_at: 0,
        updated_at: 0,
    };
    let live = Arc::new(Live { job: Mutex::new(job), done: AtomicU64::new(0), connections: AtomicU32::new(0), cancel: Mutex::new(tx) });
    let out = download::run(live, reqwest::Client::new(), dir.path(), Arc::new(EventHub::new()), rx, 4, 2, Arc::new(RateLimiter::new(0)), None, Some(sign)).await;
    let Outcome::Done(path) = out else { panic!("{out:?}") };
    assert_eq!(Sha256::digest(std::fs::read(path).unwrap()), Sha256::digest(data.as_slice()));
    // The probe plus one ranged request for the second part, each with its own signature.
    assert!(!fake.ranges.lock().unwrap().is_empty(), "no ranged request");
    assert_eq!(signs.load(Ordering::SeqCst), fake.signed_gets.load(Ordering::SeqCst));
}

/// Real SigV4 check against a live server, run by hand: RAYS_S3_ENDPOINT, RAYS_S3_BUCKET, RAYS_S3_KEY_ID,
/// RAYS_S3_SECRET, RAYS_S3_OBJECT (an object in the bucket) and optional RAYS_S3_REGION, RAYS_S3_PATH_STYLE=1.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "needs a live S3 server; see doc comment"]
async fn live_bucket_lists_and_downloads() {
    let var = |k: &str| std::env::var(k).unwrap_or_else(|_| panic!("set {k}"));
    let cfg = BucketConfig {
        name: var("RAYS_S3_BUCKET"),
        provider: "generic".into(),
        endpoint: var("RAYS_S3_ENDPOINT"),
        region: std::env::var("RAYS_S3_REGION").unwrap_or_else(|_| "us-east-1".into()),
        access_key_id: var("RAYS_S3_KEY_ID"),
        path_style: std::env::var("RAYS_S3_PATH_STYLE").is_ok_and(|v| v == "1"),
    };
    let object = var("RAYS_S3_OBJECT");
    let dir = tempfile::tempdir().unwrap();
    let store = Arc::new(Store::open(&dir.path().join("data")).unwrap());
    let downloads = dir.path().join("downloads");
    std::fs::create_dir_all(&downloads).unwrap();
    let sched = Scheduler::new(tokio::runtime::Handle::current(), store, Arc::new(EventHub::new()), downloads, 2, 4, 0, Arc::new(MemorySecrets::default())).unwrap();
    sched.add_bucket(cfg.clone(), var("RAYS_S3_SECRET")).await.unwrap();
    let listing = sched.list_bucket(&cfg.name, "", None).await.unwrap();
    assert!(listing.objects.iter().any(|o| o.key == object), "{listing:?}");
    let link = format!("s3://{}/{object}", cfg.name);
    assert!(sched.add(vec![link.clone()])[0].error.is_none());
    let deadline = Instant::now() + Duration::from_secs(120);
    loop {
        let view = sched.views().into_iter().find(|v| v.url == link).unwrap();
        match view.state {
            JobState::Done { .. } => break,
            JobState::Failed { reason } => panic!("failed: {reason}"),
            _ => assert!(Instant::now() < deadline, "not done: {view:?}"),
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn socket_requests_add_list_browse_and_remove_buckets() {
    use dl_engine::ipc;
    use dl_engine::protocol::Response;
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

    let fake = Fake { data: Arc::new(vec![7; 1 << 20]), signed_gets: Arc::default(), ranges: Arc::default() };
    let addr = fake_s3(fake).await;
    let dir = tempfile::tempdir().unwrap();
    let store = Arc::new(Store::open(&dir.path().join("data")).unwrap());
    let downloads = dir.path().join("downloads");
    std::fs::create_dir_all(&downloads).unwrap();
    let sched = Scheduler::new(tokio::runtime::Handle::current(), store, Arc::new(EventHub::new()), downloads, 2, 4, 0, Arc::new(MemorySecrets::default())).unwrap();
    let sock = dir.path().join("dl.sock");
    tokio::spawn(ipc::serve(ipc::bind(&sock).unwrap(), sched));

    let stream = tokio::net::UnixStream::connect(&sock).await.unwrap();
    let (read, mut write) = stream.into_split();
    let mut lines = BufReader::new(read).lines();
    let mut ask = async |line: String| -> Response {
        write.write_all(format!("{line}\n").as_bytes()).await.unwrap();
        serde_json::from_str(&lines.next_line().await.unwrap().unwrap()).unwrap()
    };

    let r = ask(r#"{"op":"providers"}"#.into()).await;
    assert!(r.providers.iter().any(|p| p.id == "r2") && r.providers.last().unwrap().id == "generic");

    let r = ask(r#"{"op":"bucket_add","name":"media","provider":"r2","access_key_id":"AKID","secret":"s"}"#.into()).await;
    assert!(r.error.unwrap().contains("Account ID"), "a preset field is required");

    let add = format!(r#"{{"op":"bucket_add","name":"media","provider":"minio","endpoint":"http://{addr}","access_key_id":"AKID","secret":"{SECRET}"}}"#);
    let r = ask(add).await;
    assert!(r.ok, "{:?}", r.error);

    let r = ask(r#"{"op":"buckets"}"#.into()).await;
    assert_eq!((r.buckets.len(), r.buckets[0].path_style), (1, true), "minio preset is path style");
    assert!(!serde_json::to_string(&r).unwrap().contains(SECRET));

    let r = ask(r#"{"op":"bucket_list","bucket":"media"}"#.into()).await;
    assert_eq!(r.listing.unwrap().folders, vec!["photos/".to_string()]);

    let r = ask(r#"{"op":"add","urls":["s3://media/big.bin"]}"#.into()).await;
    assert_eq!(r.added.len(), 1, "{r:?}");

    let r = ask(r#"{"op":"bucket_remove","name":"media"}"#.into()).await;
    assert!(r.ok);
    let r = ask(r#"{"op":"buckets"}"#.into()).await;
    assert!(r.buckets.is_empty());
}
