//! Local file server with Range support, for measuring the engine without the network:
//! `cargo run --release -p dl-engine --example serve -- <dir> [port]`, then point `bench` at
//! `http://127.0.0.1:<port>/<file>`. The default port is 8765.
use tower_http::services::ServeDir;

#[tokio::main]
async fn main() {
    let mut args = std::env::args().skip(1);
    let dir = args.next().expect("usage: serve <dir> [port]");
    let port = args.next().unwrap_or_else(|| "8765".into());
    let listener = tokio::net::TcpListener::bind(format!("127.0.0.1:{port}")).await.expect("bind");
    println!("serving {dir} on http://127.0.0.1:{port}/");
    axum::serve(listener, axum::Router::new().fallback_service(ServeDir::new(dir))).await.expect("serve");
}
