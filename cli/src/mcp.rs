//! `dl mcp`: a Model Context Protocol server on stdio (JSON-RPC 2.0, one message per line).
//! Tools reach Rays through the same socket as `dl` and the bundled sorter through `sorter.rs`.
use crate::sorter;
use dl_engine::protocol::{QueueRef, Request, Response};
use serde_json::{Value, json};
use std::io::{BufRead, Write};
use std::process::ExitCode;

const PROTOCOL: &str = "2025-06-18";

pub fn serve() -> ExitCode {
    let stdin = std::io::stdin();
    let mut out = std::io::stdout().lock();
    for line in stdin.lock().lines() {
        let Ok(line) = line else { return ExitCode::from(1) };
        if line.trim().is_empty() {
            continue;
        }
        let Some(reply) = handle_line(&line, &mut crate::ask_rays) else { continue };
        if writeln!(out, "{reply}").and_then(|_| out.flush()).is_err() {
            return ExitCode::from(1);
        }
    }
    ExitCode::SUCCESS
}

/// Returns the reply line, or None for notifications. `ask` sends one request to Rays (swapped out in tests).
fn handle_line(line: &str, ask: &mut dyn FnMut(&Request) -> Result<Response, String>) -> Option<Value> {
    let msg: Value = match serde_json::from_str(line) {
        Ok(v) => v,
        Err(e) => return Some(error(Value::Null, -32700, &format!("parse error: {e}"))),
    };
    let id = msg.get("id").cloned()?; // no id: a notification, never answered
    let method = msg.get("method").and_then(Value::as_str).unwrap_or_default();
    let params = msg.get("params").cloned().unwrap_or(Value::Null);
    let result = match method {
        "initialize" => json!({
            "protocolVersion": params.get("protocolVersion").and_then(Value::as_str).unwrap_or(PROTOCOL),
            "capabilities": { "tools": {} },
            "serverInfo": { "name": "rays", "version": env!("CARGO_PKG_VERSION") },
            "instructions": "Rays is a macOS download manager. Use add_downloads to download http/https links or s3://bucket/key objects, list_downloads to check progress, list_queues, start_queue, stop_queue and run_queue_now to manage download queues, verify_model to check a downloaded Hugging Face model, list_buckets and browse_bucket to find objects in S3 buckets the user added to Rays, sorter_status and sort_folder to file downloads into folders, speed_test to measure download speed and best_time for the fastest time of day to download."
        }),
        "ping" => json!({}),
        "tools/list" => json!({ "tools": tools() }),
        "tools/call" => {
            let name = params.get("name").and_then(Value::as_str).unwrap_or_default();
            let args = params.get("arguments").cloned().unwrap_or_else(|| json!({}));
            match call(name, &args, ask) {
                Some(Ok(text)) => json!({ "content": [{ "type": "text", "text": text }], "isError": false }),
                Some(Err(text)) => json!({ "content": [{ "type": "text", "text": text }], "isError": true }),
                None => return Some(error(id, -32602, &format!("unknown tool: {name}"))),
            }
        }
        _ => return Some(error(id, -32601, &format!("method not found: {method}"))),
    };
    Some(json!({ "jsonrpc": "2.0", "id": id, "result": result }))
}

fn error(id: Value, code: i64, message: &str) -> Value {
    json!({ "jsonrpc": "2.0", "id": id, "error": { "code": code, "message": message } })
}

fn queue_schema() -> Value {
    json!({
        "type": "object",
        "properties": { "queue": { "type": "string", "description": "Queue name (any case) or id from list_queues." } },
        "required": ["queue"]
    })
}

fn queue_arg(args: &Value) -> Result<Option<QueueRef>, String> {
    match args.get("queue") {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) if !s.is_empty() => Ok(Some(QueueRef::parse(s))),
        Some(Value::Number(n)) if n.as_u64().is_some() => Ok(n.as_u64().map(QueueRef::Id)),
        _ => Err("queue must be a queue name or id".into()),
    }
}

fn queue_req(args: &Value, make: fn(QueueRef) -> Request) -> Result<Request, String> {
    queue_arg(args)?.map(make).ok_or_else(|| "queue is required".into())
}

fn tools() -> Value {
    json!([
        {
            "name": "add_downloads",
            "description": "Download one or more http/https links, or s3://bucket/key objects from buckets added to Rays. Returns the new download ids and any rejected links.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "urls": { "type": "array", "items": { "type": "string" }, "minItems": 1 },
                    "queue": { "type": "string", "description": "Queue name or id from list_queues. Without it the downloads start now, in no queue." },
                    "best_time": { "type": "boolean", "default": false, "description": "Add to the Best time queue instead; queue is ignored." }
                },
                "required": ["urls"]
            }
        },
        {
            "name": "list_queues",
            "description": "Rays download queues: id, name, state (open, waiting for time, waiting for condition, stopped, off), next scheduled start in unix seconds, and counts of queued and running downloads.",
            "inputSchema": { "type": "object", "properties": {} },
            "annotations": { "readOnlyHint": true }
        },
        {
            "name": "start_queue",
            "description": "Start a queue: lifts a stop on a queue without a schedule, and on a scheduled queue is the same as run_queue_now.",
            "inputSchema": queue_schema()
        },
        {
            "name": "stop_queue",
            "description": "Stop a queue: its queued downloads wait and its running ones pause until the queue is started again.",
            "inputSchema": queue_schema()
        },
        {
            "name": "run_queue_now",
            "description": "Run a queue now, whatever its schedule window and conditions say, until its run finishes.",
            "inputSchema": queue_schema()
        },
        {
            "name": "verify_model",
            "description": "Check a Hugging Face model downloaded by Rays against the record Rays kept of it (.rays-model.json). Returns one line per file (ok, size-checked, missing, wrong-size, wrong-checksum) and a summary. Needs the absolute path of the model folder.",
            "inputSchema": {
                "type": "object",
                "properties": { "dir": { "type": "string", "description": "Absolute path of the model folder." } },
                "required": ["dir"]
            },
            "annotations": { "readOnlyHint": true }
        },
        {
            "name": "list_downloads",
            "description": "List Rays downloads with id, state (queued, running, paused, retrying, done, failed), bytes done and total, and file name.",
            "inputSchema": { "type": "object", "properties": {} },
            "annotations": { "readOnlyHint": true }
        },
        {
            "name": "list_buckets",
            "description": "S3-compatible buckets the user added to Rays: name, provider, region and endpoint. Secret keys are never returned.",
            "inputSchema": { "type": "object", "properties": {} },
            "annotations": { "readOnlyHint": true }
        },
        {
            "name": "browse_bucket",
            "description": "One level of a bucket: folders (prefixes ending in /) and objects with key, size and modified time. Pass next_token from a previous reply for the next page. Download an object with add_downloads and s3://bucket/key.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "bucket": { "type": "string" },
                    "prefix": { "type": "string", "description": "Folder to list, ending in /. Default: the bucket's top level." },
                    "next_token": { "type": "string" }
                },
                "required": ["bucket"]
            },
            "annotations": { "readOnlyHint": true }
        },
        {
            "name": "sorter_status",
            "description": "Watched folders, sorter categories, settings and recent moves, as JSON.",
            "inputSchema": { "type": "object", "properties": {} },
            "annotations": { "readOnlyHint": true }
        },
        {
            "name": "sort_folder",
            "description": "Sort a folder into category folders (Work, Images, Installers, ...). Dry run by default: set dry_run to false to move files.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "folder": { "type": "string", "description": "Folder to sort. Default ~/Downloads." },
                    "dry_run": { "type": "boolean", "default": true, "description": "Only report what would move." },
                    "all": { "type": "boolean", "default": false, "description": "Also sort files that were there before the first run." }
                }
            },
            "annotations": { "destructiveHint": true }
        },
        {
            "name": "speed_test",
            "description": "Measure download speed against the speed test server now and save the result. Refused on a metered link, or on a network Rays has not identified (for example while the Rays app is closed), unless force is true. A forced test on such a network is not saved.",
            "inputSchema": {
                "type": "object",
                "properties": { "force": { "type": "boolean", "default": false, "description": "Also test on a metered or unidentified network. Set only when the user asked for it." } }
            }
        },
        {
            "name": "best_time",
            "description": "The last speed test and the fastest 4 hours of the day to download over the last 28 days (local time, with typical speed and confidence), or how many days of data are still needed.",
            "inputSchema": { "type": "object", "properties": {} },
            "annotations": { "readOnlyHint": true }
        }
    ])
}

/// None means no such tool. Errors are tool errors the model can read, not protocol errors.
fn call(name: &str, args: &Value, ask: &mut dyn FnMut(&Request) -> Result<Response, String>) -> Option<Result<String, String>> {
    Some(match name {
        "add_downloads" => urls(args)
            .and_then(|urls| Ok(Request::Add { urls, queue: queue_arg(args)?, best_time: args.get("best_time").and_then(Value::as_bool).unwrap_or(false) }))
            .and_then(|req| reply_text(ask(&req))),
        "speed_test" => {
            let force = args.get("force").and_then(Value::as_bool).unwrap_or(false);
            reply_text(ask(&Request::SpeedTest { force }))
        }
        "best_time" => reply_text(ask(&Request::Speed)),
        "list_queues" => reply_text(ask(&Request::Queues)),
        "start_queue" => queue_req(args, |queue| Request::QueueStart { queue }).and_then(|req| reply_text(ask(&req))),
        "stop_queue" => queue_req(args, |queue| Request::QueueStop { queue }).and_then(|req| reply_text(ask(&req))),
        "run_queue_now" => queue_req(args, |queue| Request::QueueRunNow { queue }).and_then(|req| reply_text(ask(&req))),
        "verify_model" => match args.get("dir").and_then(Value::as_str) {
            Some(dir) if dir.starts_with('/') => reply_text(ask(&Request::VerifyModel { dir: dir.to_owned() })),
            _ => Err("dir must be an absolute path".into()),
        },
        "list_downloads" => reply_text(ask(&Request::List)),
        "list_buckets" => reply_text(ask(&Request::Buckets)),
        "browse_bucket" => browse(args).and_then(|req| reply_text(ask(&req))),
        "sorter_status" => sorter::output(&["status".into(), "--json".into()]),
        "sort_folder" => sort_args(args).and_then(|a| sorter::output(&a)),
        _ => return None,
    })
}

fn urls(args: &Value) -> Result<Vec<String>, String> {
    let list = args.get("urls").and_then(Value::as_array).ok_or("urls must be an array of strings")?;
    let urls: Vec<String> = list.iter().filter_map(|u| u.as_str().map(str::to_owned)).collect();
    if urls.is_empty() || urls.len() != list.len() {
        return Err("urls must be a non-empty array of strings".into());
    }
    Ok(urls)
}

fn browse(args: &Value) -> Result<Request, String> {
    let text = |k: &str| args.get(k).and_then(Value::as_str).map(str::to_owned);
    let bucket = text("bucket").filter(|b| !b.is_empty()).ok_or("bucket must be a non-empty string")?;
    Ok(Request::BucketList { bucket, prefix: text("prefix").unwrap_or_default(), token: text("next_token") })
}

fn sort_args(args: &Value) -> Result<Vec<String>, String> {
    let mut out = Vec::new();
    if let Some(folder) = args.get("folder").and_then(Value::as_str) {
        if folder.starts_with('-') {
            return Err("folder must be a path".into());
        }
        out.push(folder.to_owned());
    }
    if args.get("dry_run").and_then(Value::as_bool).unwrap_or(true) {
        out.push("--dry-run".into());
    }
    if args.get("all").and_then(Value::as_bool).unwrap_or(false) {
        out.push("--all".into());
    }
    Ok(out)
}

fn reply_text(reply: Result<Response, String>) -> Result<String, String> {
    let reply = reply?;
    if !reply.ok {
        return Err(reply.error.unwrap_or_else(|| "Rays rejected the request".into()));
    }
    serde_json::to_string_pretty(&reply).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use dl_engine::protocol::{Added, JobLine, ListingLine, ObjectLine};

    fn fake(req: &Request) -> Result<Response, String> {
        Ok(match req {
            Request::Add { urls, .. } => Response {
                ok: true,
                added: urls.iter().enumerate().map(|(i, u)| Added { url: u.clone(), id: i as u64 + 1 }).collect(),
                ..Default::default()
            },
            Request::List => Response {
                ok: true,
                jobs: vec![JobLine { id: 1, name: "a.zip".into(), state: "done".into(), done: 3, total: Some(3) }],
                ..Default::default()
            },
            Request::BucketList { bucket, prefix, .. } => Response {
                ok: true,
                listing: Some(ListingLine {
                    folders: vec![format!("{prefix}sub/")],
                    objects: vec![ObjectLine { key: format!("{bucket}-{prefix}a.bin"), size: 5, modified: String::new() }],
                    next_token: None,
                }),
                ..Default::default()
            },
            other => panic!("unexpected request {other:?}"),
        })
    }

    fn ask(line: &str) -> Option<Value> {
        handle_line(line, &mut fake)
    }

    #[test]
    fn browse_bucket_passes_bucket_and_prefix_and_needs_a_bucket() {
        let r = ask(r#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"browse_bucket","arguments":{"bucket":"media","prefix":"p/"}}}"#).unwrap();
        let text = r["result"]["content"][0]["text"].as_str().unwrap();
        assert!(text.contains("media-p/a.bin") && text.contains("p/sub/"), "{text}");
        let r = ask(r#"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"browse_bucket","arguments":{}}}"#).unwrap();
        assert_eq!(r["result"]["isError"], true);
    }

    #[test]
    fn initialize_echoes_version_and_lists_tools() {
        let r = ask(r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}"#).unwrap();
        assert_eq!(r["result"]["protocolVersion"], "2025-03-26");
        assert_eq!(r["result"]["serverInfo"]["name"], "rays");
        let r = ask(r#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#).unwrap();
        let names: Vec<&str> = r["result"]["tools"].as_array().unwrap().iter().map(|t| t["name"].as_str().unwrap()).collect();
        assert_eq!(
            names,
            [
                "add_downloads",
                "list_queues",
                "start_queue",
                "stop_queue",
                "run_queue_now",
                "verify_model",
                "list_downloads",
                "list_buckets",
                "browse_bucket",
                "sorter_status",
                "sort_folder",
                "speed_test",
                "best_time"
            ]
        );
    }

    #[test]
    fn queue_tools_pass_name_or_id_and_verify_needs_absolute_dir() {
        let mut seen = Vec::new();
        let mut rec = |req: &Request| {
            seen.push(format!("{req:?}"));
            Ok(Response { ok: true, ..Default::default() })
        };
        let mut call_tool = |name: &str, args: Value| {
            let line = json!({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":name,"arguments":args}}).to_string();
            handle_line(&line, &mut rec).unwrap()["result"]["isError"].clone()
        };
        assert_eq!(call_tool("stop_queue", json!({"queue": "Night"})), false);
        assert_eq!(call_tool("run_queue_now", json!({"queue": 3})), false);
        assert_eq!(call_tool("start_queue", json!({})), true);
        assert_eq!(call_tool("add_downloads", json!({"urls": ["https://a/x"], "queue": "Night"})), false);
        assert_eq!(call_tool("verify_model", json!({"dir": "rel"})), true);
        assert_eq!(call_tool("verify_model", json!({"dir": "/m"})), false);
        assert_eq!(call_tool("list_queues", json!({})), false);
        assert_eq!(call_tool("speed_test", json!({"force": true})), false);
        assert_eq!(call_tool("best_time", json!({})), false);
        assert_eq!(call_tool("add_downloads", json!({"urls": ["https://a/y"], "best_time": true})), false);
        assert_eq!(
            seen,
            [
                r#"QueueStop { queue: Name("Night") }"#,
                "QueueRunNow { queue: Id(3) }",
                r#"Add { urls: ["https://a/x"], queue: Some(Name("Night")), best_time: false }"#,
                r#"VerifyModel { dir: "/m" }"#,
                "Queues",
                "SpeedTest { force: true }",
                "Speed",
                r#"Add { urls: ["https://a/y"], queue: None, best_time: true }"#,
            ]
        );
    }

    #[test]
    fn notifications_get_no_reply() {
        assert!(ask(r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#).is_none());
    }

    #[test]
    fn add_and_list_go_through_rays() {
        let r = ask(r#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"add_downloads","arguments":{"urls":["https://a.com/x.zip"]}}}"#).unwrap();
        assert_eq!(r["result"]["isError"], false);
        assert!(r["result"]["content"][0]["text"].as_str().unwrap().contains("https://a.com/x.zip"));
        let r = ask(r#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"list_downloads"}}"#).unwrap();
        assert!(r["result"]["content"][0]["text"].as_str().unwrap().contains("a.zip"));
    }

    #[test]
    fn bad_input_is_a_tool_error_unknown_is_protocol_error() {
        let r = ask(r#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"add_downloads","arguments":{"urls":[]}}}"#).unwrap();
        assert_eq!(r["result"]["isError"], true);
        let r = ask(r#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"nope"}}"#).unwrap();
        assert_eq!(r["error"]["code"], -32602);
        let r = ask(r#"{"jsonrpc":"2.0","id":7,"method":"nope"}"#).unwrap();
        assert_eq!(r["error"]["code"], -32601);
        assert_eq!(ask("not json").unwrap()["error"]["code"], -32700);
    }

    #[test]
    fn sort_defaults_to_dry_run_and_rejects_flag_folders() {
        assert_eq!(sort_args(&json!({})).unwrap(), ["--dry-run"]);
        assert_eq!(sort_args(&json!({"folder": "/x", "dry_run": false, "all": true})).unwrap(), ["/x", "--all"]);
        assert!(sort_args(&json!({"folder": "--all"})).is_err());
    }
}
