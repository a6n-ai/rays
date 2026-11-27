//! `dl mcp`: a Model Context Protocol server on stdio (JSON-RPC 2.0, one message per line).
//! Tools reach Rays through the same socket as `dl` and the bundled sorter through `sorter.rs`.
use crate::sorter;
use dl_engine::protocol::HttpHeader;
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
pub(crate) fn handle_line(line: &str, ask: &mut dyn FnMut(&Request) -> Result<Response, String>) -> Option<Value> {
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
            "instructions": "Rays is a macOS download manager. Use add_downloads to download http/https links or s3://bucket/key objects, list_downloads to check progress, pause_download, resume_download and remove_download to manage one, relink to give a paused or failed download a new link, list_queues, start_queue, stop_queue and run_queue_now to manage download queues, search_models, model_files and download_model to get Hugging Face models, verify_model to check a downloaded one, list_buckets and browse_bucket to find objects in S3 buckets the user added to Rays, grab_links to list the files linked from a web page, sorter_status and sort_folder to file downloads into folders, speed_test to measure download speed and best_time for the fastest time of day to download."
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
                    "best_time": { "type": "boolean", "default": false, "description": "Add to the Best time queue instead; queue is ignored." },
                    "sha256": { "type": "array", "items": { "type": ["string", "null"] }, "description": "Optional expected SHA-256 (64 hex characters) for each url, same order; null skips one. A download that does not match fails." },
                    "mirrors": { "type": "array", "items": { "type": "array", "items": { "type": "string" } }, "description": "Optional extra links for the same file, one list per url, same order. Each must serve the same size with range support or it is ignored." },
                    "headers": { "type": "object", "additionalProperties": { "type": "string" }, "description": "Optional request headers for links that need a login, for example {\"Cookie\": \"session=...\"}. Applied to every url. Values are stored on this Mac and only sent to the link's own host." }
                },
                "required": ["urls"]
            },
            "annotations": { "title": "Add downloads", "readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": true }
        },
        {
            "name": "relink",
            "description": "Give a paused or failed download (for example one that failed with Link expired) a new link and queue it. The partial file is kept when the new link reports the same size. A different file is refused with \"The new link is a different file\" unless restart is true, which deletes the partial file and starts over.",
            "inputSchema": {
                "type": "object",
                "properties": { "id": { "type": "integer", "description": "Download id from list_downloads." }, "url": { "type": "string" }, "restart": { "type": "boolean", "description": "Start over if the new link is a different file. Default false." } },
                "required": ["id", "url"]
            },
            "annotations": { "title": "Give a download a new link", "readOnlyHint": false, "destructiveHint": true, "idempotentHint": false, "openWorldHint": true }
        },
        {
            "name": "list_queues",
            "description": "Rays download queues: id, name, state (open, waiting for time, waiting for condition, stopped, off), next scheduled start in unix seconds, and counts of queued and running downloads.",
            "inputSchema": { "type": "object", "properties": {} },
            "annotations": { "title": "List queues", "readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false }
        },
        {
            "name": "start_queue",
            "description": "Start a queue: lifts a stop on a queue without a schedule, and on a scheduled queue is the same as run_queue_now.",
            "inputSchema": queue_schema(),
            "annotations": { "title": "Start queue", "readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": true }
        },
        {
            "name": "stop_queue",
            "description": "Stop a queue: its queued downloads wait and its running ones pause until the queue is started again.",
            "inputSchema": queue_schema(),
            "annotations": { "title": "Stop queue", "readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false }
        },
        {
            "name": "run_queue_now",
            "description": "Run a queue now, whatever its schedule window and conditions say, until its run finishes.",
            "inputSchema": queue_schema(),
            "annotations": { "title": "Run queue now", "readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": true }
        },
        {
            "name": "verify_model",
            "description": "Check a Hugging Face model downloaded by Rays against the record Rays kept of it (.rays-model.json). Returns one line per file (ok, size-checked, missing, wrong-size, wrong-checksum) and a summary. Needs the absolute path of the model folder.",
            "inputSchema": {
                "type": "object",
                "properties": { "dir": { "type": "string", "description": "Absolute path of the model folder." } },
                "required": ["dir"]
            },
            "annotations": { "title": "Verify model", "readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false }
        },
        {
            "name": "list_downloads",
            "description": "List Rays downloads with id, state (queued, running, paused, retrying, done, failed), bytes done and total, and file name.",
            "inputSchema": { "type": "object", "properties": {} },
            "annotations": { "title": "List downloads", "readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false }
        },
        {
            "name": "list_buckets",
            "description": "S3-compatible buckets the user added to Rays: name, provider, region and endpoint. Secret keys are never returned.",
            "inputSchema": { "type": "object", "properties": {} },
            "annotations": { "title": "List buckets", "readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false }
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
            "annotations": { "title": "Browse bucket", "readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": true }
        },
        {
            "name": "grab_links",
            "description": "List the downloadable files (archives, installers, video, audio, images, documents, models) linked from a web page: url, name and kind (file extension). Fails if the link is itself a file. Download the ones you want with add_downloads.",
            "inputSchema": { "type": "object", "properties": { "url": { "type": "string", "description": "An http or https page link." } }, "required": ["url"] },
            "annotations": { "title": "Grab links from a page", "readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": true }
        },
        {
            "name": "pause_download",
            "description": "Pause a queued or running download. The partial file is kept, so resume_download continues where it stopped.",
            "inputSchema": { "type": "object", "properties": { "id": { "type": "integer", "description": "Download id from list_downloads." } }, "required": ["id"] },
            "annotations": { "title": "Pause download", "readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false }
        },
        {
            "name": "resume_download",
            "description": "Queue a paused or failed download again. A download that failed with Link expired needs relink instead.",
            "inputSchema": { "type": "object", "properties": { "id": { "type": "integer", "description": "Download id from list_downloads." } }, "required": ["id"] },
            "annotations": { "title": "Resume download", "readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": true }
        },
        {
            "name": "remove_download",
            "description": "Take a download off the Rays list, stopping it if it runs. A finished file stays on disk. Set delete_partial to also delete the unfinished partial file, which cannot be resumed after that.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "id": { "type": "integer", "description": "Download id from list_downloads." },
                    "delete_partial": { "type": "boolean", "default": false, "description": "Also delete the unfinished partial file." }
                },
                "required": ["id"]
            },
            "annotations": { "title": "Remove download", "readOnlyHint": false, "destructiveHint": true, "idempotentHint": true, "openWorldHint": false }
        },
        {
            "name": "search_models",
            "description": "Search Hugging Face models by name: id, downloads, likes, whether it is gated (needs a login) or has GGUF files, and its task.",
            "inputSchema": { "type": "object", "properties": { "query": { "type": "string" } }, "required": ["query"] },
            "annotations": { "title": "Search models", "readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": true }
        },
        {
            "name": "model_files",
            "description": "The files of a Hugging Face model with sizes, and the ones Rays recommends (one GGUF quantization or the default checkpoint). Use the paths with download_model.",
            "inputSchema": { "type": "object", "properties": { "repo": { "type": "string", "description": "Model id like owner/name." } }, "required": ["repo"] },
            "annotations": { "title": "Model files", "readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": true }
        },
        {
            "name": "download_model",
            "description": "Download a Hugging Face model with checksums and a record verify_model can check later. Without files, downloads the recommended ones. Files already there or already queued are skipped. Returns the folder and one line per file.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "repo": { "type": "string", "description": "Model id like owner/name." },
                    "files": { "type": "array", "items": { "type": "string" }, "description": "File paths from model_files. Default: the recommended files." },
                    "dir": { "type": "string", "description": "Absolute folder to download into. Default: AI Models/<repo> in the Rays download folder." },
                    "queue": { "type": "string", "description": "Queue name or id from list_queues. Without it the files start now." }
                },
                "required": ["repo"]
            },
            "annotations": { "title": "Download model", "readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": true }
        },
        {
            "name": "sorter_status",
            "description": "Watched folders, sorter categories, settings and recent moves, as JSON.",
            "inputSchema": { "type": "object", "properties": {} },
            "annotations": { "title": "Sorter status", "readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false }
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
            "annotations": { "title": "Sort folder", "readOnlyHint": false, "destructiveHint": true, "idempotentHint": true, "openWorldHint": false }
        },
        {
            "name": "speed_test",
            "description": "Measure download speed against the speed test server now and save the result. Refused on a metered link, or on a network Rays has not identified (for example while the Rays app is closed), unless force is true. A forced test on such a network is not saved.",
            "inputSchema": {
                "type": "object",
                "properties": { "force": { "type": "boolean", "default": false, "description": "Also test on a metered or unidentified network. Set only when the user asked for it." } }
            },
            "annotations": { "title": "Speed test", "readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": true }
        },
        {
            "name": "stats",
            "description": "Totals of downloads finished in the last N days that are still in the Rays list: bytes and files overall and per local day, the top sites, and average and peak speed.",
            "inputSchema": {
                "type": "object",
                "properties": { "days": { "type": "integer", "minimum": 1, "default": 30, "description": "How many days back, counting today." } }
            },
            "annotations": { "title": "Download stats", "readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false }
        },
        {
            "name": "best_time",
            "description": "The last speed test and the fastest 4 hours of the day to download over the last 28 days (local time, with typical speed and confidence), or how many days of data are still needed.",
            "inputSchema": { "type": "object", "properties": {} },
            "annotations": { "title": "Best time to download", "readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false }
        }
    ])
}

/// None means no such tool. Errors are tool errors the model can read, not protocol errors.
fn call(name: &str, args: &Value, ask: &mut dyn FnMut(&Request) -> Result<Response, String>) -> Option<Result<String, String>> {
    Some(match name {
        "add_downloads" => urls(args)
            .and_then(|urls| {
                let sha256 = match args.get("sha256") {
                    None | Some(Value::Null) => Vec::new(),
                    Some(Value::Array(a)) => a.iter().map(|v| v.as_str().map(str::to_owned)).collect(),
                    _ => return Err("sha256 must be an array of hex strings".into()),
                };
                let mirrors = match args.get("mirrors") {
                    None | Some(Value::Null) => Vec::new(),
                    Some(Value::Array(a)) => a
                        .iter()
                        .map(|v| v.as_array().map(|l| l.iter().filter_map(|m| m.as_str().map(str::to_owned)).collect()))
                        .collect::<Option<Vec<Vec<String>>>>()
                        .ok_or("mirrors must be an array of arrays of strings")?,
                    _ => return Err("mirrors must be an array of arrays of strings".into()),
                };
                let headers = match args.get("headers") {
                    None | Some(Value::Null) => Vec::new(),
                    Some(Value::Object(o)) => o
                        .iter()
                        .map(|(name, v)| v.as_str().map(|value| HttpHeader { name: name.clone(), value: value.to_owned() }))
                        .collect::<Option<Vec<_>>>()
                        .ok_or("headers must be an object of strings")?,
                    _ => return Err("headers must be an object of strings".into()),
                };
                Ok(Request::Add { urls, queue: queue_arg(args)?, best_time: args.get("best_time").and_then(Value::as_bool).unwrap_or(false), sha256, mirrors, headers })
            })
            .and_then(|req| reply_text(ask(&req))),
        "speed_test" => {
            let force = args.get("force").and_then(Value::as_bool).unwrap_or(false);
            reply_text(ask(&Request::SpeedTest { force }))
        }
        "relink" => match (args.get("id").and_then(Value::as_u64), args.get("url").and_then(Value::as_str)) {
            (Some(id), Some(url)) => reply_text(ask(&Request::Relink { id, url: url.to_owned(), restart: args.get("restart").and_then(Value::as_bool).unwrap_or(false) })),
            _ => Err("id and url are required".into()),
        },
        "best_time" => reply_text(ask(&Request::Speed)),
        "stats" => reply_text(ask(&Request::Stats { days: args.get("days").and_then(Value::as_u64).map_or(30, |d| d.clamp(1, 3650) as u32) })),
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
        "grab_links" => match args.get("url").and_then(Value::as_str) {
            Some(url) => reply_text(ask(&Request::Grab { url: url.to_owned() })),
            None => Err("url is required".into()),
        },
        "browse_bucket" => browse(args).and_then(|req| reply_text(ask(&req))),
        "pause_download" => id_arg(args).and_then(|id| reply_text(ask(&Request::Pause { id }))),
        "resume_download" => id_arg(args).and_then(|id| reply_text(ask(&Request::Resume { id }))),
        "remove_download" => id_arg(args).and_then(|id| {
            let delete_partial = args.get("delete_partial").and_then(Value::as_bool).unwrap_or(false);
            reply_text(ask(&Request::Remove { id, delete_partial }))
        }),
        "search_models" => match args.get("query").and_then(Value::as_str).filter(|q| !q.trim().is_empty()) {
            Some(q) => reply_text(ask(&Request::HfSearch { query: q.to_owned() })),
            None => Err("query is required".into()),
        },
        "model_files" => repo_arg(args).and_then(|repo| reply_text(ask(&Request::HfModel { repo }))),
        "download_model" => repo_arg(args).and_then(|repo| {
            let files = match args.get("files") {
                None | Some(Value::Null) => Vec::new(),
                Some(Value::Array(a)) => a.iter().map(|v| v.as_str().map(str::to_owned)).collect::<Option<_>>().ok_or("files must be an array of strings")?,
                _ => return Err("files must be an array of strings".into()),
            };
            let dir = match args.get("dir").and_then(Value::as_str) {
                Some(d) if !d.starts_with('/') => return Err("dir must be an absolute path".into()),
                d => d.map(str::to_owned),
            };
            reply_text(ask(&Request::HfAdd { repo, files, dir, queue: queue_arg(args)? }))
        }),
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

fn id_arg(args: &Value) -> Result<u64, String> {
    args.get("id").and_then(Value::as_u64).ok_or_else(|| "id must be a download id from list_downloads".into())
}

fn repo_arg(args: &Value) -> Result<String, String> {
    match args.get("repo").and_then(Value::as_str) {
        Some(r) if r.split('/').count() == 2 && !r.contains("..") && !r.starts_with('/') => Ok(r.to_owned()),
        _ => Err("repo must be a Hugging Face model id like owner/name".into()),
    }
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
    use dl_engine::protocol::{Added, GrabLine, JobLine, ListingLine, ObjectLine};

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
            Request::Grab { url } => Response { ok: true, grabbed: vec![GrabLine { url: format!("{url}a.zip"), name: "a.zip".into(), kind: "zip".into() }], ..Default::default() },
            Request::Pause { id } | Request::Resume { id } | Request::Remove { id, .. } => Response { ok: true, summary: Some(format!("{req:?} {id}")), ..Default::default() },
            Request::HfAdd { repo, files, dir, .. } => Response { ok: true, summary: Some(format!("{repo} {files:?} {dir:?}")), ..Default::default() },
            other => panic!("unexpected request {other:?}"),
        })
    }

    fn ask(line: &str) -> Option<Value> {
        handle_line(line, &mut fake)
    }

    fn call_tool(name: &str, args: &str) -> Value {
        let line = format!(r#"{{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{{"name":"{name}","arguments":{args}}}}}"#);
        ask(&line).unwrap()["result"].clone()
    }

    #[test]
    fn every_tool_declares_a_title_and_all_four_hints() {
        for tool in tools().as_array().unwrap() {
            let a = &tool["annotations"];
            assert!(a["title"].is_string(), "{}", tool["name"]);
            for hint in ["readOnlyHint", "destructiveHint", "idempotentHint", "openWorldHint"] {
                assert!(a[hint].is_boolean(), "{} lacks {hint}", tool["name"]);
            }
            assert!(!(a["readOnlyHint"] == true && a["destructiveHint"] == true), "{}", tool["name"]);
        }
    }

    #[test]
    fn download_tools_need_an_id_and_remove_keeps_the_partial_by_default() {
        assert_eq!(call_tool("pause_download", "{}")["isError"], true);
        let r = call_tool("remove_download", r#"{"id":4}"#);
        assert!(r["content"][0]["text"].as_str().unwrap().contains("delete_partial: false"), "{r}");
    }

    #[test]
    fn download_model_checks_repo_and_dir() {
        assert_eq!(call_tool("download_model", r#"{"repo":"../x"}"#)["isError"], true);
        assert_eq!(call_tool("download_model", r#"{"repo":"a/b","dir":"rel"}"#)["isError"], true);
        let r = call_tool("download_model", r#"{"repo":"a/b","files":["m.gguf"]}"#);
        assert!(r["content"][0]["text"].as_str().unwrap().contains(r#"a/b [\"m.gguf\"] None"#), "{r}");
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
    fn grab_links_returns_the_list_and_needs_a_url() {
        let r = ask(r#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"grab_links","arguments":{"url":"https://x/"}}}"#).unwrap();
        assert!(r["result"]["content"][0]["text"].as_str().unwrap().contains("https://x/a.zip"));
        let r = ask(r#"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"grab_links","arguments":{}}}"#).unwrap();
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
                "relink",
                "list_queues",
                "start_queue",
                "stop_queue",
                "run_queue_now",
                "verify_model",
                "list_downloads",
                "list_buckets",
                "browse_bucket",
                "grab_links",
                "pause_download",
                "resume_download",
                "remove_download",
                "search_models",
                "model_files",
                "download_model",
                "sorter_status",
                "sort_folder",
                "speed_test",
                "stats",
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
        assert_eq!(call_tool("add_downloads", json!({"urls": ["https://a/z"], "headers": {"Cookie": "s=1"}})), false);
        assert_eq!(call_tool("add_downloads", json!({"urls": ["https://a/z"], "headers": {"Cookie": 1}})), true);
        assert_eq!(
            seen,
            [
                r#"QueueStop { queue: Name("Night") }"#,
                "QueueRunNow { queue: Id(3) }",
                r#"Add { urls: ["https://a/x"], queue: Some(Name("Night")), best_time: false, sha256: [], mirrors: [], headers: [] }"#,
                r#"VerifyModel { dir: "/m" }"#,
                "Queues",
                "SpeedTest { force: true }",
                "Speed",
                r#"Add { urls: ["https://a/y"], queue: None, best_time: true, sha256: [], mirrors: [], headers: [] }"#,
                r#"Add { urls: ["https://a/z"], queue: None, best_time: false, sha256: [], mirrors: [], headers: [HttpHeader { name: "Cookie", .. }] }"#,
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
