//! `dl mcp --http`: the MCP server over Streamable HTTP on 127.0.0.1, one JSON-RPC message per POST.
//! A local port is reachable from any web page, so every request needs the bearer token from `mcp-token`
//! (next to the socket, 0600), a localhost Host header (against DNS rebinding) and, when sent, a localhost Origin.
use crate::mcp;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::Path;
use std::process::ExitCode;
use std::time::Duration;

pub const DEFAULT_PORT: u16 = 7467;
const MAX_HEADERS: usize = 16 * 1024;
const MAX_BODY: usize = 1024 * 1024;

pub fn serve(port: u16) -> ExitCode {
    let token = match load_token(&crate::socket_path().with_file_name("mcp-token")) {
        Ok(t) => t,
        Err(e) => {
            eprintln!("dl: could not read or create the MCP token: {e}");
            return ExitCode::from(1);
        }
    };
    let listener = match TcpListener::bind(("127.0.0.1", port)) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("dl: could not listen on 127.0.0.1:{port}: {e}");
            return ExitCode::from(1);
        }
    };
    eprintln!("Rays MCP server on http://127.0.0.1:{port}/mcp");
    // Started by the app: quit with it, even after a crash, so the port is free for the next launch.
    if let Some(owner) = std::env::var("RAYS_MCP_PARENT").ok().and_then(|p| p.parse::<u32>().ok()) {
        std::thread::spawn(move || loop {
            if std::os::unix::process::parent_id() != owner {
                std::process::exit(0);
            }
            std::thread::sleep(Duration::from_secs(2));
        });
    }
    for stream in listener.incoming().flatten() {
        let token = token.clone();
        std::thread::spawn(move || {
            let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));
            let _ = handle(stream, port, &token);
        });
    }
    ExitCode::SUCCESS
}

pub fn print_token() -> ExitCode {
    match load_token(&crate::socket_path().with_file_name("mcp-token")) {
        Ok(t) => {
            println!("{t}");
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("dl: could not read or create the MCP token: {e}");
            ExitCode::from(1)
        }
    }
}

/// Reads the token, or writes a new random one readable only by this user.
fn load_token(path: &Path) -> std::io::Result<String> {
    if let Ok(t) = std::fs::read_to_string(path) {
        let t = t.trim().to_owned();
        if t.len() >= 32 {
            std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
            return Ok(t);
        }
    }
    let mut bytes = [0u8; 32];
    std::fs::File::open("/dev/urandom")?.read_exact(&mut bytes)?;
    let token: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let mut f = std::fs::OpenOptions::new().write(true).create(true).truncate(true).mode(0o600).open(path)?;
    f.write_all(token.as_bytes())?;
    Ok(token)
}

struct Http {
    method: String,
    path: String,
    headers: Vec<(String, String)>,
    body: Vec<u8>,
}

impl Http {
    fn header(&self, name: &str) -> Option<&str> {
        self.headers.iter().find(|(k, _)| k.eq_ignore_ascii_case(name)).map(|(_, v)| v.as_str())
    }
}

fn read_request(stream: &TcpStream) -> Result<Http, &'static str> {
    let mut r = BufReader::new(stream);
    let mut head = Vec::new();
    while !head.ends_with(b"\r\n\r\n") {
        let n = r.read_until(b'\n', &mut head).map_err(|_| "read failed")?;
        if n == 0 || head.len() > MAX_HEADERS {
            return Err("bad request");
        }
    }
    let head = String::from_utf8(head).map_err(|_| "bad request")?;
    let mut lines = head.split("\r\n");
    let mut first = lines.next().unwrap_or_default().split(' ');
    let (method, target) = (first.next().unwrap_or_default().to_owned(), first.next().unwrap_or_default());
    let path = target.split('?').next().unwrap_or_default().to_owned();
    let headers: Vec<(String, String)> = lines
        .filter_map(|l| l.split_once(':'))
        .map(|(k, v)| (k.trim().to_owned(), v.trim().to_owned()))
        .collect();
    let len = headers.iter().find(|(k, _)| k.eq_ignore_ascii_case("content-length")).map_or(Ok(0), |(_, v)| v.parse::<usize>());
    let len = len.map_err(|_| "bad request")?;
    if len > MAX_BODY {
        return Err("too large");
    }
    let mut body = vec![0; len];
    r.read_exact(&mut body).map_err(|_| "read failed")?;
    Ok(Http { method, path, headers, body })
}

fn is_local_host(host: &str, port: u16) -> bool {
    ["127.0.0.1", "localhost"].iter().any(|h| host == *h || host == format!("{h}:{port}"))
}

fn is_local_origin(origin: &str) -> bool {
    let rest = origin.strip_prefix("http://").or_else(|| origin.strip_prefix("https://")).unwrap_or("");
    let host = rest.rsplit_once(':').filter(|(_, p)| p.parse::<u16>().is_ok()).map_or(rest, |(h, _)| h);
    host == "127.0.0.1" || host == "localhost"
}

/// Compares every byte so the time taken does not reveal how much of a guess matched.
fn same(a: &str, b: &str) -> bool {
    a.len() == b.len() && a.bytes().zip(b.bytes()).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

/// Status, content type and body for one request; the JSON-RPC handling is the stdio server's.
fn route(req: &Http, port: u16, token: &str, ask: &mut dyn FnMut(&dl_engine::protocol::Request) -> Result<dl_engine::protocol::Response, String>) -> (u16, &'static str, String) {
    if req.path != "/mcp" {
        return (404, "text/plain", "not found".into());
    }
    if !req.header("host").is_some_and(|h| is_local_host(h, port)) || req.header("origin").is_some_and(|o| !is_local_origin(o)) {
        return (403, "text/plain", "forbidden".into());
    }
    let bearer = req.header("authorization").and_then(|a| a.strip_prefix("Bearer "));
    if !bearer.is_some_and(|b| same(b.trim(), token)) {
        return (401, "text/plain", "unauthorized".into());
    }
    if req.method != "POST" {
        // No server-initiated stream and no sessions, so GET and DELETE are not offered.
        return (405, "text/plain", "method not allowed".into());
    }
    let Ok(line) = std::str::from_utf8(&req.body) else { return (400, "text/plain", "body must be UTF-8".into()) };
    match mcp::handle_line(line, ask) {
        None => (202, "text/plain", String::new()),
        Some(reply) => {
            let accept = req.header("accept").unwrap_or("");
            if accept.contains("text/event-stream") && !accept.contains("application/json") {
                (200, "text/event-stream", format!("event: message\ndata: {reply}\n\n"))
            } else {
                (200, "application/json", reply.to_string())
            }
        }
    }
}

fn handle(mut stream: TcpStream, port: u16, token: &str) -> std::io::Result<()> {
    let (status, kind, body) = match read_request(&stream) {
        Ok(req) => route(&req, port, token, &mut crate::ask_rays),
        Err(e) => (if e == "too large" { 413 } else { 400 }, "text/plain", e.into()),
    };
    let reason = match status {
        200 => "OK",
        202 => "Accepted",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        _ => "Payload Too Large",
    };
    let auth = if status == 401 { "WWW-Authenticate: Bearer\r\n" } else { "" };
    let allow = if status == 405 { "Allow: POST\r\n" } else { "" };
    write!(stream, "HTTP/1.1 {status} {reason}\r\nContent-Type: {kind}\r\nContent-Length: {}\r\n{auth}{allow}Connection: close\r\n\r\n{body}", body.len())
}

#[cfg(test)]
mod tests {
    use super::*;
    use dl_engine::protocol::{Request, Response};

    fn req(method: &str, headers: &[(&str, &str)], body: &str) -> Http {
        Http { method: method.into(), path: "/mcp".into(), headers: headers.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect(), body: body.into() }
    }

    fn run(r: &Http) -> (u16, &'static str, String) {
        route(r, 7467, "t0ken", &mut |_: &Request| Ok(Response { ok: true, ..Default::default() }))
    }

    const PING: &str = r#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#;

    #[test]
    fn needs_token_local_host_and_local_origin() {
        assert_eq!(run(&req("POST", &[("Host", "127.0.0.1:7467")], PING)).0, 401);
        assert_eq!(run(&req("POST", &[("Host", "evil.example:7467"), ("Authorization", "Bearer t0ken")], PING)).0, 403);
        assert_eq!(run(&req("POST", &[("Host", "localhost:7467"), ("Origin", "https://evil.example"), ("Authorization", "Bearer t0ken")], PING)).0, 403);
        assert_eq!(run(&req("POST", &[("Host", "localhost:7467"), ("Authorization", "Bearer t0kem")], PING)).0, 401);
        let ok = run(&req("POST", &[("Host", "localhost:7467"), ("Origin", "http://localhost:3000"), ("Authorization", "Bearer t0ken")], PING));
        assert_eq!((ok.0, ok.1), (200, "application/json"));
    }

    #[test]
    fn answers_json_sse_and_accepts_notifications() {
        let auth = [("Host", "127.0.0.1:7467"), ("Authorization", "Bearer t0ken"), ("Accept", "text/event-stream")];
        let sse = run(&req("POST", &auth, PING));
        assert!(sse.1 == "text/event-stream" && sse.2.starts_with("event: message\ndata: {"), "{sse:?}");
        assert_eq!(run(&req("POST", &auth, r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)).0, 202);
        assert_eq!(run(&req("GET", &auth, "")).0, 405);
    }
}
