//! Link grabber against a local page server.
use axum::Router;
use axum::http::{StatusCode, header};
use axum::response::{IntoResponse, Redirect};
use axum::routing::get;
use dl_engine::grab::grab;
use dl_engine::types::EngineError;

const PAGE: &str = r#"<html><head><base href="/files/"></head><body>
<a href="a.zip">a</a> <a href="a.zip#again">dup</a> <a href='/abs/b.PDF'>b</a>
<a href="http://other.test/c.mp4?x=1&amp;y=2">c</a> <img src="pic.png"> <a href="page2.html">page</a>
<a href="mailto:me@x.test">mail</a> <a href="javascript:void(0)">js</a> <a href="notes.zip.html">no</a>
<!-- <a href="hidden.zip">hidden</a> --></body></html>"#;

async fn serve() -> String {
    let app = Router::new()
        .route("/dir/page", get(|| async { ([(header::CONTENT_TYPE, "text/html; charset=utf-8")], PAGE) }))
        .route("/dir/plain", get(|| async { ([(header::CONTENT_TYPE, "text/html")], r#"<a href="rel.zip">r</a>"#) }))
        .route("/go", get(|| async { Redirect::temporary("/dir/plain") }))
        .route("/f.zip", get(|| async { ([(header::CONTENT_TYPE, "application/zip")], "PK") }))
        .route("/gone", get(|| async { StatusCode::NOT_FOUND.into_response() }));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    format!("http://127.0.0.1:{port}")
}

#[tokio::test]
async fn lists_file_links_resolved_deduped_and_filtered() {
    let base = serve().await;
    let links = grab(&reqwest::Client::new(), &format!("{base}/dir/page")).await.unwrap();
    let got: Vec<(String, String, String)> = links.into_iter().map(|l| (l.url, l.name, l.kind)).collect();
    let want = [
        (format!("{base}/files/a.zip"), "a.zip", "zip"),
        (format!("{base}/abs/b.PDF"), "b.PDF", "pdf"),
        ("http://other.test/c.mp4?x=1&y=2".to_owned(), "c.mp4", "mp4"),
        (format!("{base}/files/pic.png"), "pic.png", "png"),
    ];
    assert_eq!(got, want.map(|(u, n, k)| (u, n.to_owned(), k.to_owned())));
}

#[tokio::test]
async fn relative_links_resolve_against_the_redirect_target() {
    let base = serve().await;
    let links = grab(&reqwest::Client::new(), &format!("{base}/go")).await.unwrap();
    assert_eq!(links.iter().map(|l| l.url.as_str()).collect::<Vec<_>>(), [format!("{base}/dir/rel.zip")]);
}

#[tokio::test]
async fn a_file_and_a_bad_page_are_errors() {
    let base = serve().await;
    let c = reqwest::Client::new();
    let err = grab(&c, &format!("{base}/f.zip")).await.unwrap_err();
    assert!(matches!(&err, EngineError::InvalidUrl { msg } if msg == "That link is a file, not a page"), "{err}");
    assert!(grab(&c, &format!("{base}/gone")).await.is_err());
    assert!(grab(&c, "ftp://x/y").await.is_err());
}
