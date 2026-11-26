mod bucket;
mod framing;
mod mcp;
mod sorter;

use dl_engine::protocol::{BestTimeLine, QueueRef, Request, Response, SpeedLine, SpeedTestLine, StatsLine};
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
  dl add [--queue NAME|ID] [--best-time] [--sha256 HEX] URL [--mirror URL]...
                                download links into a queue (default: Main), or the Best time queue
  dl relink ID URL [--restart]  give a paused or failed download a new link and resume it;
                                --restart starts over if the new link is a different file
  dl grab URL [--json]          list the downloadable files linked from a web page, one URL per line
  dl queues [--json]            list queues with state, next start and job counts
  dl queue start|stop|run NAME|ID
                                start, stop or run a queue now
  dl speed                      last speed test and the best time of day to download
  dl speed test [--force]       run a speed test now (--force also on a metered link)
  dl stats [--days N]           totals of downloads finished in the last N days (default 30)
  dl verify MODEL_FOLDER        check a Hugging Face model download against its record
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

/// Verifying hashes whole model files, and a speed test runs for seconds; other requests answer at once.
fn read_timeout(req: &Request) -> Duration {
    match req {
        Request::VerifyModel { .. } => Duration::from_secs(3600),
        Request::SpeedTest { .. } => Duration::from_secs(60),
        Request::Grab { .. } => Duration::from_secs(30),
        _ => Duration::from_secs(10),
    }
}

fn exchange(mut stream: UnixStream, req: &Request) -> Result<Response, Box<dyn Error>> {
    stream.set_read_timeout(Some(read_timeout(req)))?;
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
        [cmd, ..] if ["add", "relink", "grab", "queues", "queue", "verify", "speed", "stats"].contains(&cmd.as_str()) => match queue_command(&args) {
            Ok(req) => req,
            Err(e) => {
                eprintln!("dl: {e}");
                return usage();
            }
        },
        // Sorter commands run the sorter bundled beside dl; `dl sort` is the sorter's default command.
        [cmd, rest @ ..] if cmd == "bucket" => return bucket::run(rest),
        [cmd, link] if cmd == "ls" => return bucket::ls(link),
        [cmd, rest @ ..] if cmd == "sort" => return sorter::run(rest),
        [cmd, rest @ ..] if cmd == "status" => return sorter::status(rest),
        [cmd, ..] if ["watch", "unwatch", "config"].contains(&cmd.as_str()) => return sorter::run(&args),
        [a, ..] if a.starts_with('-') => return usage(),
        urls => Request::Add { urls: urls.to_vec(), queue: None, best_time: false, sha256: vec![], mirrors: vec![] },
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

    if args.iter().any(|a| a == "--json") && args[0] == "queues" {
        let rows: Vec<Value> = reply
            .queues
            .iter()
            .map(|q| {
                let mut row = serde_json::to_value(q).unwrap_or_default();
                row["next_run_local"] = q.next_run.and_then(local_time).map_or(Value::Null, Value::from);
                row
            })
            .collect();
        println!("{}", serde_json::to_string_pretty(&rows).unwrap_or_default());
        return ExitCode::SUCCESS;
    }
    if args[0] == "grab" {
        if args.iter().any(|a| a == "--json") {
            println!("{}", serde_json::to_string_pretty(&reply.grabbed).unwrap_or_default());
        } else {
            for l in &reply.grabbed {
                println!("{}", l.url);
            }
        }
        return ExitCode::SUCCESS;
    }
    if let Some(speed) = &reply.speed {
        for line in speed_lines(speed, jiff::Timestamp::now().as_second()) {
            println!("{line}");
        }
        return ExitCode::SUCCESS;
    }
    if let Some(stats) = &reply.stats {
        for line in stats_lines(stats) {
            println!("{line}");
        }
        return ExitCode::SUCCESS;
    }
    if let Some(test) = &reply.speed_test {
        println!("{}", speed_test_line(test));
        return ExitCode::SUCCESS;
    }
    for q in &reply.queues {
        let next = q.next_run.map_or(String::new(), |t| local_time(t).map_or(String::new(), |t| format!("\tnext {t}")));
        println!("{}\t{}\t{}\t{} queued, {} running{next}", q.id, q.name, q.state, q.queued, q.running);
    }
    for v in &reply.verified {
        let actual = v.actual.map_or(String::new(), |n| format!(" ({n} bytes on disk)"));
        println!("{}\t{}{actual}", v.status, v.path);
    }
    if let Some(summary) = &reply.summary {
        println!("{summary}");
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
    let unverified = reply.verified.iter().any(|v| !matches!(v.status.as_str(), "ok" | "size-checked"));
    if reply.rejected.is_empty() && !unverified { ExitCode::SUCCESS } else { ExitCode::from(1) }
}

/// Unix seconds as local time, like `Wed 26 Nov 02:00`.
fn local_time(secs: i64) -> Option<String> {
    let at = jiff::tz::TimeZone::system().to_datetime(jiff::Timestamp::from_second(secs).ok()?);
    Some(at.strftime("%a %d %b %H:%M").to_string())
}

/// Speed lines for `dl speed`: the last test, then the best time of day.
fn speed_lines(s: &SpeedLine, now: i64) -> Vec<String> {
    let last = match &s.last {
        Some(t) => format!("last test {} Mb/s, {} ms, {}", mbps(t.bps), t.latency_ms, ago(t.at, now)),
        None => "no speed test yet".into(),
    };
    let best = match &s.best_time {
        BestTimeLine::Window { start_min, end_min, typical_bps, days, confidence } => {
            format!("best time {}–{}, usually {} Mb/s ({days} days, {confidence})", clock(*start_min), clock(*end_min), mbps(*typical_bps))
        }
        BestTimeLine::NotEnoughData { days, needed } => format!("not enough data: {days} of {needed} days"),
    };
    vec![last, best]
}

/// Lines for `dl stats`: totals, speed, top sites, then one line per day.
fn stats_lines(s: &StatsLine) -> Vec<String> {
    let mut out = vec![format!("{} in {} files", megabytes(s.total_bytes), s.total_files)];
    if let (Some(avg), Some(peak)) = (s.avg_bps, s.peak_bps) {
        out.push(format!("speed average {} Mb/s, peak {} Mb/s", mbps(avg), mbps(peak)));
    }
    out.extend(s.top_hosts.iter().map(|h| format!("{}\t{} files\t{}", h.host, h.files, megabytes(h.bytes))));
    out.extend(s.per_day.iter().map(|d| {
        let day = jiff::Timestamp::from_second(d.day).map_or_else(|_| d.day.to_string(), |t| jiff::tz::TimeZone::system().to_datetime(t).strftime("%Y-%m-%d").to_string());
        format!("{day}\t{} files\t{}", d.files, megabytes(d.bytes))
    }));
    out
}

fn megabytes(bytes: u64) -> String {
    let m = bytes as f64 / 1_000_000.0;
    if m >= 1000.0 { format!("{:.2} GB", m / 1000.0) } else { format!("{m:.1} MB") }
}

fn speed_test_line(t: &SpeedTestLine) -> String {
    let note = if t.saved { "" } else { ", not saved: downloads ran during the test" };
    format!("test {} Mb/s, {} ms{note}", mbps(t.bps), t.latency_ms)
}

/// Megabits per second from bytes per second: no decimals from 100 up, one decimal below.
fn mbps(bps: u64) -> String {
    let m = bps as f64 * 8.0 / 1_000_000.0;
    if m >= 100.0 { format!("{m:.0}") } else { format!("{m:.1}") }
}

/// Minutes of the local day as `HH:MM`.
fn clock(min: u16) -> String {
    format!("{:02}:{:02}", min / 60, min % 60)
}

/// `N min ago` under an hour, else `N h ago`.
fn ago(at: i64, now: i64) -> String {
    let mins = (now - at).max(0) / 60;
    if mins < 60 { format!("{mins} min ago") } else { format!("{} h ago", mins / 60) }
}

/// `add`, `queues`, `queue start|stop|run`, `verify` and `speed`; `args[0]` is the command.
fn queue_command(args: &[String]) -> Result<Request, String> {
    match args {
        [c, rest @ ..] if c == "add" => {
            let (mut queue, mut best_time, mut urls, mut it) = (None, false, Vec::new(), rest.iter());
            let (mut sha256, mut pending, mut mirrors) = (Vec::new(), None, Vec::<Vec<String>>::new());
            while let Some(a) = it.next() {
                match a.as_str() {
                    "--queue" => queue = Some(QueueRef::parse(it.next().ok_or("--queue needs a name or id")?)),
                    "--best-time" => best_time = true,
                    "--sha256" => pending = Some(it.next().ok_or("--sha256 needs a hash")?.clone()),
                    "--mirror" => {
                        let link = it.next().ok_or("--mirror needs a URL")?.clone();
                        mirrors.last_mut().ok_or("--mirror goes after the URL it belongs to")?.push(link);
                    }
                    f if f.starts_with('-') => return Err(format!("unknown option {f}")),
                    _ => {
                        urls.push(a.clone());
                        mirrors.push(Vec::new());
                        sha256.push(pending.take());
                    }
                }
            }
            if pending.is_some() {
                return Err("--sha256 goes before the URL it checks".into());
            }
            if sha256.iter().all(Option::is_none) {
                sha256.clear();
            }
            if mirrors.iter().all(Vec::is_empty) {
                mirrors.clear();
            }
            if urls.is_empty() {
                return Err("add needs at least one URL".into());
            }
            if best_time && queue.is_some() {
                return Err("use --queue or --best-time, not both".into());
            }
            Ok(Request::Add { urls, queue, best_time, sha256, mirrors })
        }
        [c, id, url, rest @ ..] if c == "relink" && matches!(rest, [] | [_]) && rest.iter().all(|f| f == "--restart") => {
            Ok(Request::Relink { id: id.parse().map_err(|_| "relink takes a download id and a URL")?, url: url.clone(), restart: !rest.is_empty() })
        }
        [c, url] if c == "grab" && !url.starts_with('-') => Ok(Request::Grab { url: url.clone() }),
        [c, url, f] if c == "grab" && f == "--json" && !url.starts_with('-') => Ok(Request::Grab { url: url.clone() }),
        [c] if c == "stats" => Ok(Request::Stats { days: 30 }),
        [c, f, n] if c == "stats" && f == "--days" => match n.parse() {
            Ok(days) if days > 0 => Ok(Request::Stats { days }),
            _ => Err("--days takes a whole number of days".into()),
        },
        [c] if c == "speed" => Ok(Request::Speed),
        [c, t] if c == "speed" && t == "test" => Ok(Request::SpeedTest { force: false }),
        [c, t, f] if c == "speed" && t == "test" && f == "--force" => Ok(Request::SpeedTest { force: true }),
        [c] if c == "queues" => Ok(Request::Queues),
        [c, f] if c == "queues" && f == "--json" => Ok(Request::Queues),
        [c, op, q] if c == "queue" => {
            let queue = QueueRef::parse(q);
            match op.as_str() {
                "start" => Ok(Request::QueueStart { queue }),
                "stop" => Ok(Request::QueueStop { queue }),
                "run" => Ok(Request::QueueRunNow { queue }),
                _ => Err("queue takes start, stop or run".into()),
            }
        }
        [c, dir] if c == "verify" => {
            let abs = std::path::absolute(dir).map_err(|e| e.to_string())?;
            Ok(Request::VerifyModel { dir: abs.to_string_lossy().into_owned() })
        }
        _ => Err("bad arguments".into()),
    }
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

    let resp = ask_rays(&Request::Add { urls, queue: None, best_time: false, sha256: vec![], mirrors: vec![] })?;
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
    fn add_queue_flag_parses_name_or_id() {
        assert_eq!(
            queue_command(&args(&["add", "--queue", "Night", "https://a/x", "https://a/y"])).unwrap(),
            Request::Add { urls: vec!["https://a/x".into(), "https://a/y".into()], queue: Some(QueueRef::Name("Night".into())), best_time: false, sha256: vec![], mirrors: vec![] }
        );
        assert_eq!(
            queue_command(&args(&["add", "https://a/x", "--queue", "3"])).unwrap(),
            Request::Add { urls: vec!["https://a/x".into()], queue: Some(QueueRef::Id(3)), best_time: false, sha256: vec![], mirrors: vec![] }
        );
        assert_eq!(
            queue_command(&args(&["add", "https://a/x"])).unwrap(),
            Request::Add { urls: vec!["https://a/x".into()], queue: None, best_time: false, sha256: vec![], mirrors: vec![] }
        );
        assert_eq!(
            queue_command(&args(&["add", "https://a/x", "--sha256", "ab", "https://a/y"])).unwrap(),
            Request::Add { urls: vec!["https://a/x".into(), "https://a/y".into()], queue: None, best_time: false, sha256: vec![None, Some("ab".into())], mirrors: vec![] }
        );
        assert!(queue_command(&args(&["add", "https://a/x", "--sha256", "ab"])).is_err());
        assert_eq!(
            queue_command(&args(&["add", "https://a/x", "--mirror", "https://b/x", "--mirror", "https://c/x", "https://a/y"])).unwrap(),
            Request::Add {
                urls: vec!["https://a/x".into(), "https://a/y".into()],
                queue: None,
                best_time: false,
                sha256: vec![],
                mirrors: vec![vec!["https://b/x".into(), "https://c/x".into()], vec![]]
            }
        );
        assert!(queue_command(&args(&["add", "--mirror", "https://b/x", "https://a/x"])).is_err());
        assert!(queue_command(&args(&["add", "--queue"])).is_err());
        assert!(queue_command(&args(&["add", "--queue", "Night"])).is_err());
    }

    #[test]
    fn read_timeout_covers_speed_tests_and_verify() {
        assert_eq!(read_timeout(&Request::SpeedTest { force: false }), Duration::from_secs(60));
        assert_eq!(read_timeout(&Request::VerifyModel { dir: "/m".into() }), Duration::from_secs(3600));
        assert_eq!(read_timeout(&Request::List), Duration::from_secs(10));
    }

    #[test]
    fn best_time_add_and_speed_commands_parse() {
        assert_eq!(
            queue_command(&args(&["add", "--best-time", "https://a/x"])).unwrap(),
            Request::Add { urls: vec!["https://a/x".into()], queue: None, best_time: true, sha256: vec![], mirrors: vec![] }
        );
        assert_eq!(queue_command(&args(&["stats"])).unwrap(), Request::Stats { days: 30 });
        assert_eq!(queue_command(&args(&["stats", "--days", "7"])).unwrap(), Request::Stats { days: 7 });
        assert!(queue_command(&args(&["stats", "--days", "0"])).is_err());
        assert_eq!(queue_command(&args(&["speed"])).unwrap(), Request::Speed);
        assert_eq!(queue_command(&args(&["speed", "test"])).unwrap(), Request::SpeedTest { force: false });
        assert_eq!(queue_command(&args(&["speed", "test", "--force"])).unwrap(), Request::SpeedTest { force: true });
        assert!(queue_command(&args(&["speed", "fast"])).is_err());
        let both = queue_command(&args(&["add", "--best-time", "--queue", "Night", "https://a/x"])).unwrap_err();
        assert_eq!(both, "use --queue or --best-time, not both");
    }

    #[test]
    fn speed_lines_read_like_the_spec() {
        let window = BestTimeLine::Window { start_min: 60, end_min: 300, typical_bps: 38_750_000, days: 14, confidence: "high".into() };
        let s = SpeedLine { last: Some(SpeedTestLine { bps: 11_500_000, latency_ms: 14, at: 0, saved: true }), best_time: window };
        assert_eq!(speed_lines(&s, 7200), ["last test 92.0 Mb/s, 14 ms, 2 h ago", "best time 01:00–05:00, usually 310 Mb/s (14 days, high)"]);
        let s = SpeedLine { last: None, best_time: BestTimeLine::NotEnoughData { days: 3, needed: 7 } };
        assert_eq!(speed_lines(&s, 0), ["no speed test yet", "not enough data: 3 of 7 days"]);
        assert_eq!(mbps(1_250_000), "10.0");
        assert_eq!(ago(0, 300), "5 min ago");
    }

    #[test]
    fn local_time_formats_weekday_day_month_time() {
        let t = local_time(1_795_638_600).unwrap();
        assert!(t.len() == 16 && t.as_bytes()[3] == b' ' && t.as_bytes()[13] == b':', "{t}");
    }

    #[test]
    fn queue_commands_parse() {
        assert_eq!(queue_command(&args(&["queues", "--json"])).unwrap(), Request::Queues);
        assert_eq!(queue_command(&args(&["queue", "run", "Night"])).unwrap(), Request::QueueRunNow { queue: QueueRef::Name("Night".into()) });
        assert_eq!(queue_command(&args(&["queue", "stop", "2"])).unwrap(), Request::QueueStop { queue: QueueRef::Id(2) });
        assert!(queue_command(&args(&["queue", "delete", "2"])).is_err());
        assert_eq!(queue_command(&args(&["relink", "7", "https://x/f"])).unwrap(), Request::Relink { id: 7, url: "https://x/f".into(), restart: false });
        assert_eq!(queue_command(&args(&["relink", "7", "https://x/f", "--restart"])).unwrap(), Request::Relink { id: 7, url: "https://x/f".into(), restart: true });
        assert!(queue_command(&args(&["relink", "x", "https://x/f"])).is_err());
        assert_eq!(queue_command(&args(&["grab", "https://x/p", "--json"])).unwrap(), Request::Grab { url: "https://x/p".into() });
        assert!(queue_command(&args(&["grab"])).is_err());
        assert_eq!(queue_command(&args(&["verify", "/m/x"])).unwrap(), Request::VerifyModel { dir: "/m/x".into() });
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
