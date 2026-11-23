mod bucket;
mod framing;
mod mcp;
mod sorter;

use dl_engine::protocol::{Request, Response};
use serde_json::{Value, json};
use std::error::Error;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode, Stdio};
use std::time::{Duration, Instant};

const USAGE: &str = "usage:
  dl URL...                     download links with Rays
  dl list                       list downloads (also: dl --list)
  dl sort [FOLDER] [--all] [--dry-run] [--projects]
                                sort FOLDER into category folders (default ~/Downloads)
  dl watch FOLDER | dl unwatch FOLDER
                                sort FOLDER automatically whenever a file lands in it
  dl status [--json]            watched folders, categories and recent moves
  dl config add|remove FOLDER
  dl config set-dest FOLDER CATEGORY PATH | clear-dest FOLDER CATEGORY | set-wait SECONDS | set-rename on|off
  dl mcp                        run the MCP server on stdio (for AI assistants)
  dl s3://BUCKET/KEY            download an object from a bucket added to Rays";

fn socket_path() -> PathBuf {
    if let Some(p) = std::env::var_os("DL_SOCKET") {
        return PathBuf::from(p);
    }
    let home = std::env::var_os("HOME").unwrap_or_default();
    PathBuf::from(home).join("Library/Application Support/Rays/dl.sock")
}

fn connect(path: &Path) -> std::io::Result<UnixStream> {
    if let Ok(stream) = UnixStream::connect(path) {
        return Ok(stream);
    }
    if std::env::var_os("DL_SOCKET").is_none() && std::env::var_os("DL_NO_LAUNCH").is_none() {
        let _ = Command::new("open")
            .args(["-b", "ai.a6n.rays"])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
    }
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        std::thread::sleep(Duration::from_millis(200));
        match UnixStream::connect(path) {
            Ok(stream) => return Ok(stream),
            Err(e) if Instant::now() >= deadline => return Err(e),
            Err(_) => {}
        }
    }
}

fn exchange(mut stream: UnixStream, req: &Request) -> Result<Response, Box<dyn Error>> {
    stream.set_read_timeout(Some(Duration::from_secs(10)))?;
    let mut line = serde_json::to_string(req)?;
    line.push('\n');
    stream.write_all(line.as_bytes())?;
    let mut reply = String::new();
    BufReader::new(stream).read_line(&mut reply)?;
    Ok(serde_json::from_str(&reply)?)
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if is_native_host_launch(&args) {
        return run_host();
    }
    let req = match args.as_slice() {
        [] => return usage(),
        [a] if a == "-h" || a == "--help" || a == "help" => {
            println!("{USAGE}\n{}", bucket::USAGE);
            return ExitCode::SUCCESS;
        }
        [a] if a == "mcp" => return mcp::serve(),
        [a] if a == "--list" || a == "list" => Request::List,
        // Sorter commands run the sorter bundled beside dl; `dl sort` is the sorter's default command.
        [cmd, rest @ ..] if cmd == "bucket" => return bucket::run(rest),
        [cmd, link] if cmd == "ls" => return bucket::ls(link),
        [cmd, rest @ ..] if cmd == "sort" => return sorter::run(rest),
        [cmd, rest @ ..] if cmd == "status" => return sorter::status(rest),
        [cmd, ..] if ["watch", "unwatch", "config"].contains(&cmd.as_str()) => return sorter::run(&args),
        [a, ..] if a.starts_with('-') => return usage(),
        urls => Request::Add { urls: urls.to_vec() },
    };

    let reply = match ask_rays(&req) {
        Ok(reply) => reply,
        Err(e) => {
            eprintln!("dl: {e}");
            return ExitCode::from(2);
        }
    };
    if !reply.ok {
        eprintln!("dl: {}", reply.error.unwrap_or_default());
        return ExitCode::from(1);
    }

    for a in &reply.added {
        println!("added {} {}", a.id, a.url);
    }
    for r in &reply.rejected {
        println!("rejected {}: {}", r.url, r.reason);
    }
    for j in &reply.jobs {
        let total = j.total.map_or_else(|| "?".to_string(), |t| t.to_string());
        println!("{}\t{}\t{}/{}\t{}", j.id, j.state, j.done, total, j.name);
    }
    if reply.rejected.is_empty() { ExitCode::SUCCESS } else { ExitCode::from(1) }
}

/// One request to Rays, opening the app if needed. Shared by the CLI and `dl mcp`.
pub(crate) fn ask_rays(req: &Request) -> Result<Response, String> {
    let stream = connect(&socket_path()).map_err(|e| format!("app not reachable: {e}"))?;
    exchange(stream, req).map_err(|e| e.to_string())
}

/// Chrome passes its origin as an argument; Firefox passes the manifest path and the extension id.
/// `--native-host` forces the mode for manual testing. Stdin alone is not a signal: `dl --list`
/// run from a script also has a non-terminal stdin.
fn is_native_host_launch(args: &[String]) -> bool {
    args.iter().any(|a| a == "--native-host" || a.starts_with("chrome-extension://"))
        || matches!(args, [manifest, id] if manifest.ends_with(".json") && id.contains('@'))
}

fn run_host() -> ExitCode {
    let mut input = std::io::stdin().lock();
    let mut output = std::io::stdout().lock();
    loop {
        let reply = match framing::read_frame(&mut input) {
            Ok(payload) => handle_host_message(&payload),
            Err(framing::FrameError::Eof) => return ExitCode::SUCCESS,
            Err(framing::FrameError::TooLarge(n)) => {
                json!({"ok": false, "error": format!("message of {n} bytes exceeds 1 MiB")})
            }
            Err(framing::FrameError::Io(e)) => {
                eprintln!("dl: native host read: {e}");
                return ExitCode::from(1);
            }
        };
        if let Err(e) = framing::write_frame(&mut output, &reply_bytes(&reply)) {
            eprintln!("dl: native host write: {e}");
            return ExitCode::from(1);
        }
    }
}

fn reply_bytes(reply: &Value) -> Vec<u8> {
    let bytes = serde_json::to_vec(reply)
        .unwrap_or_else(|_| br#"{"ok":false,"error":"encode failed"}"#.to_vec());
    if bytes.len() > framing::MAX_MESSAGE {
        br#"{"ok":false,"error":"reply exceeds 1 MiB"}"#.to_vec()
    } else {
        bytes
    }
}

fn handle_host_message(payload: &[u8]) -> Value {
    host_reply(payload).unwrap_or_else(|e| json!({"ok": false, "error": e}))
}

/// `{"ping": true}` reports whether the app answers (the extension sends `"urls": []` with it, so an older host,
/// which only adds, still answers ok); anything else adds `urls`.
fn host_reply(payload: &[u8]) -> Result<Value, String> {
    let msg: Value = serde_json::from_slice(payload).map_err(|e| format!("bad message: {e}"))?;
    note_browser(msg.get("version").and_then(Value::as_str));
    if msg.get("ping").and_then(Value::as_bool) == Some(true) {
        return Ok(host_ping(&socket_path()));
    }
    host_add(&msg)
}

/// Records which browser runs the extension, in `browsers.json` next to the socket: the app reads it to show the
/// extension as added, since macOS keeps it out of other browsers' profile folders. The browser is the host's
/// parent process; keyed by its `.app` path. Best effort: a failure only leaves the old record.
fn note_browser(version: Option<&str>) {
    let ppid = std::os::unix::process::parent_id().to_string();
    let Ok(out) = Command::new("ps").args(["-o", "comm=", "-p", &ppid]).output() else { return };
    let exe = String::from_utf8_lossy(&out.stdout).trim().to_string();
    let Some(app) = exe.find(".app/").map(|i| exe[..i + 4].to_string()) else { return };
    let Some(dir) = socket_path().parent().map(Path::to_path_buf) else { return };
    let file = dir.join("browsers.json");
    let mut seen: serde_json::Map<String, Value> =
        std::fs::read(&file).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    seen.insert(app, json!({"seen": now, "version": version}));
    let tmp = dir.join(format!("browsers.json.{}", std::process::id()));
    if std::fs::write(&tmp, Value::Object(seen).to_string()).is_ok() {
        let _ = std::fs::rename(&tmp, &file);
    }
}

/// Whether Rays is running, and how many downloads are queued or running. Always `ok`: the host itself answered.
/// Unlike `connect`, it never opens Rays: the extension asks every time its popup opens.
fn host_ping(socket: &Path) -> Value {
    let reply = UnixStream::connect(socket)
        .map_err(|e| e.to_string())
        .and_then(|s| exchange(s, &Request::List).map_err(|e| e.to_string()));
    match reply {
        Ok(resp) if resp.ok => {
            let active = resp.jobs.iter().filter(|j| matches!(j.state.as_str(), "running" | "queued" | "retrying")).count();
            json!({"ok": true, "rays": true, "active": active})
        }
        Ok(resp) => json!({"ok": true, "rays": false, "error": resp.error}),
        Err(e) => json!({"ok": true, "rays": false, "error": format!("app not reachable: {e}")}),
    }
}

fn host_add(msg: &Value) -> Result<Value, String> {
    let urls: Vec<String> = msg
        .get("urls")
        .and_then(Value::as_array)
        .ok_or("message needs a \"urls\" array")?
        .iter()
        .map(|u| u.as_str().map(str::to_owned).ok_or("urls must be strings"))
        .collect::<Result<_, _>>()?;
    if urls.is_empty() {
        return Ok(json!({"ok": true, "added": 0, "rejected": []}));
    }

    let resp = ask_rays(&Request::Add { urls })?;
    if !resp.ok {
        return Err(resp.error.unwrap_or_else(|| "Rays rejected the request".into()));
    }
    Ok(json!({"ok": true, "added": resp.added.len(), "rejected": resp.rejected}))
}

fn usage() -> ExitCode {
    eprintln!("{USAGE}");
    ExitCode::from(2)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn detects_browser_launches() {
        assert!(is_native_host_launch(&args(&["--native-host"])));
        assert!(is_native_host_launch(&args(&["chrome-extension://abcdefghijklmnop/"])));
        assert!(is_native_host_launch(&args(&["/x/ai.a6n.rays.json", "rays@a6n.ai"])));
        assert!(!is_native_host_launch(&args(&["https://a.com/x.zip"])));
        assert!(!is_native_host_launch(&args(&["--list"])));
        assert!(!is_native_host_launch(&args(&[])));
    }

    #[test]
    fn host_rejects_malformed_messages() {
        assert_eq!(handle_host_message(b"not json")["ok"], false);
        assert_eq!(handle_host_message(br#"{"urls":"x"}"#)["ok"], false);
        assert_eq!(handle_host_message(br#"{"urls":[1]}"#)["ok"], false);
    }

    #[test]
    fn host_empty_urls_is_ok_without_app() {
        let v = handle_host_message(br#"{"urls":[]}"#);
        assert_eq!(v["ok"], true);
        assert_eq!(v["added"], 0);
    }

    #[test]
    fn host_ping_without_app_says_rays_is_not_running() {
        let v = host_ping(Path::new("/nonexistent/rays-test/dl.sock"));
        assert_eq!((v["ok"].clone(), v["rays"].clone()), (json!(true), json!(false)));
    }
}
