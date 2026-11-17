//! Read-only data for the Rays UI: `sorter status --json` (folders, categories, recent moves).
use serde_json::{Value, json};
use std::fs;
use std::path::{Path, PathBuf};

const RECENT: usize = 50;

pub struct Watch {
    pub label: String,
    pub folder: String,
    pub binary: String,
}

pub struct Move {
    pub time: i64,
    pub file: String,
    pub to: PathBuf,
}

/// The first string after `<key>key</key>`, directly or inside an `<array>`. Enough for the plists `watch` writes.
fn value_after_key<'a>(text: &'a str, key: &str) -> Option<&'a str> {
    let tag = format!("<key>{key}</key>");
    let rest = text[text.find(&tag)? + tag.len()..].trim_start();
    let rest = rest.strip_prefix("<array>").map_or(rest, |r| r.trim_start());
    rest.strip_prefix("<string>")?.split_once("</string>").map(|(v, _)| v)
}

fn unescape(s: &str) -> String {
    s.replace("&lt;", "<").replace("&gt;", ">").replace("&amp;", "&")
}

pub fn watches(agents: &Path) -> Vec<Watch> {
    let mut out: Vec<Watch> = fs::read_dir(agents).into_iter().flatten().flatten()
        .filter(|e| {
            let name = e.file_name();
            let name = name.to_string_lossy();
            name.starts_with("local.sorter") && name.ends_with(".plist")
        })
        .filter_map(|e| {
            let text = fs::read_to_string(e.path()).ok()?;
            Some(Watch {
                label: value_after_key(&text, "Label").map(unescape).unwrap_or_default(),
                folder: unescape(value_after_key(&text, "WatchPaths")?),
                binary: unescape(value_after_key(&text, "ProgramArguments")?),
            })
        })
        .collect();
    out.sort_by(|a, b| a.folder.cmp(&b.folder));
    out
}

/// Parses `time name -> target (why)` lines written by the sorter's log. Other lines return None.
pub fn parse_move(line: &str) -> Option<Move> {
    let (ts, rest) = line.split_once(' ')?;
    let time = ts.parse::<f64>().ok()? as i64;
    let (name, target) = rest.split_once(" -> ")?;
    let body = target.strip_suffix(')')?;
    let cut = body.find(" (duplicate of ").or_else(|| body.rfind(" ("))?;
    Some(Move {
        time,
        file: name.trim_end_matches('/').to_string(),
        to: PathBuf::from(&body[..cut]),
    })
}

/// Newest first.
pub fn recent_moves(log: &Path) -> Vec<Move> {
    let mut moves: Vec<Move> = fs::read_to_string(log).unwrap_or_default().lines().filter_map(parse_move).collect();
    moves.reverse();
    moves.truncate(RECENT);
    moves
}

pub fn status_json(home: &Path, doc: &Value, state_dir: &Path, categories: &[(&str, &str)]) -> Value {
    let watches = watches(&home.join("Library/LaunchAgents"));
    let configured = doc["folders"].as_array().into_iter().flatten();
    let mut paths: Vec<String> = configured.clone().filter_map(|f| f["path"].as_str().map(str::to_string)).collect();
    for w in &watches {
        if !paths.contains(&w.folder) {
            paths.push(w.folder.clone());
        }
    }

    let folders: Vec<Value> = paths.iter().map(|p| match watches.iter().find(|w| &w.folder == p) {
        Some(w) => json!({"path": p, "watching": true, "label": w.label, "agent_binary": w.binary}),
        None => json!({"path": p, "watching": false, "label": null, "agent_binary": null}),
    }).collect();

    let roots: Vec<(PathBuf, Vec<PathBuf>)> = paths.iter().map(|p| {
        let dests = configured.clone()
            .find(|f| f["path"].as_str() == Some(p.as_str()))
            .and_then(|f| f["destinations"].as_object())
            .into_iter()
            .flatten()
            .filter_map(|(_, d)| d.as_str().map(PathBuf::from))
            .collect();
        (PathBuf::from(p), dests)
    }).collect();

    let recent: Vec<Value> = recent_moves(&state_dir.join("sorter.log")).into_iter().map(|m| {
        // A folder's destination claims its files even when another watched folder contains that destination.
        let from = roots.iter()
            .filter_map(|(r, ds)| {
                let dest = ds.iter().filter(|d| m.to.starts_with(d)).map(|d| d.components().count()).max();
                let own = m.to.starts_with(r).then(|| r.components().count());
                dest.map(|n| (true, n, r)).or(own.map(|n| (false, n, r)))
            })
            .max_by_key(|(by_dest, n, _)| (*by_dest, *n))
            .map(|(.., r)| r.to_string_lossy().into_owned())
            .unwrap_or_default();
        json!({"time": m.time, "file": m.file, "from": from, "to": m.to.to_string_lossy().into_owned()})
    }).collect();

    let categories: Vec<Value> = categories.iter().map(|(n, d)| json!({"name": n, "description": d})).collect();
    json!({"folders": folders, "categories": categories, "recent": recent,
           "wait_seconds": crate::config::wait_secs(doc), "rename_files": crate::config::rename_files(doc)})
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("sorter-status-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn parses_moves_and_skips_other_log_lines() {
        let m = parse_move("1763300000 report.pdf -> /u/Downloads/Work/Invoices/Report (2) (Work/Invoices)").unwrap();
        assert_eq!((m.time, m.file.as_str()), (1763300000, "report.pdf"));
        assert_eq!(m.to, PathBuf::from("/u/Downloads/Work/Invoices/Report (2)"));
        let d = parse_move("1763300001 a.pdf -> /u/Downloads/Duplicates/Work/a (duplicate of /u/Downloads/Work/a (1).pdf)").unwrap();
        assert_eq!(d.to, PathBuf::from("/u/Downloads/Duplicates/Work/a"));
        let p = parse_move("1763300002 myproj/ -> /u/Downloads/Code/Projects/myproj (project)").unwrap();
        assert_eq!(p.file, "myproj");
        assert!(parse_move("1763300003 learned: a -> Work/Y").is_none());
        assert!(parse_move("timing a.pdf: cache 0ms").is_none());
        assert!(parse_move("1763300004 skip a.pdf: no JSON from fm").is_none());
    }

    #[test]
    fn status_lists_watched_and_configured_folders_with_recent_moves() {
        let home = tmp("home");
        let agents = home.join("Library/LaunchAgents");
        fs::create_dir_all(&agents).unwrap();
        fs::write(agents.join("local.sorter.plist"), r#"<?xml version="1.0"?><plist version="1.0"><dict>
  <key>Label</key><string>local.sorter</string>
  <key>ProgramArguments</key><array><string>/Applications/Rays.app/Contents/MacOS/sorter</string><string>/u/Downloads</string></array>
  <key>WatchPaths</key><array><string>/u/Downloads</string></array>
</dict></plist>"#).unwrap();
        let state = tmp("state");
        fs::write(state.join("sorter.log"), "1763300000 a.pdf -> /u/Downloads/Work/Invoices/a (Work/Invoices)\n\
            1763300005 b.pdf -> /u/Documents/Work/b (Work/Invoices)\n").unwrap();
        let doc = json!({"folders": [
            {"path": "/u/Downloads", "destinations": {"Work": "/u/Documents/Work"}},
            {"path": "/u/Documents", "destinations": {}}]});

        let s = status_json(&home, &doc, &state, &[("Work", "business")]);
        let folders = s["folders"].as_array().unwrap();
        assert_eq!(folders.len(), 2);
        assert_eq!(folders[0], json!({"path": "/u/Downloads", "watching": true, "label": "local.sorter",
            "agent_binary": "/Applications/Rays.app/Contents/MacOS/sorter"}));
        assert_eq!(folders[1]["watching"], json!(false));
        assert_eq!(s["categories"], json!([{"name": "Work", "description": "business"}]));
        let recent = s["recent"].as_array().unwrap();
        assert_eq!(recent.len(), 2);
        assert_eq!(recent[0], json!({"time": 1763300005, "file": "b.pdf", "from": "/u/Downloads",
            "to": "/u/Documents/Work/b"}));
        assert_eq!(recent[1]["from"], json!("/u/Downloads"));
    }
}
