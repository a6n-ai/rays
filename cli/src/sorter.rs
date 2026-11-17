//! `dl sort` and `dl sorter`: run the sorter that ships next to `dl` inside Rays.app.
use std::path::PathBuf;
use std::process::{Command, ExitCode};

/// `DL_SORTER` overrides; otherwise the `sorter` beside the real `dl` (Homebrew links `dl` from the bundle).
pub fn path() -> Result<PathBuf, String> {
    if let Some(p) = std::env::var_os("DL_SORTER") {
        return Ok(PathBuf::from(p));
    }
    let exe = std::env::current_exe()
        .and_then(std::fs::canonicalize)
        .map_err(|e| format!("cannot locate dl: {e}"))?;
    let sorter = exe.with_file_name("sorter");
    if sorter.is_file() {
        Ok(sorter)
    } else {
        Err(format!("sorter not found next to {}; use the dl inside Rays.app", exe.display()))
    }
}

/// Runs the sorter with the terminal attached and returns its exit code.
pub fn run(args: &[String]) -> ExitCode {
    let sorter = match path() {
        Ok(p) => p,
        Err(e) => {
            eprintln!("dl: {e}");
            return ExitCode::from(2);
        }
    };
    match Command::new(sorter).args(args).status() {
        Ok(status) => ExitCode::from(status.code().map_or(1, |c| c.clamp(0, 255) as u8)),
        Err(e) => {
            eprintln!("dl: cannot run sorter: {e}");
            ExitCode::from(2)
        }
    }
}

/// Runs the sorter and captures stdout; a non-zero exit returns stderr as the error.
pub fn output(args: &[String]) -> Result<String, String> {
    let out = Command::new(path()?).args(args).output().map_err(|e| format!("cannot run sorter: {e}"))?;
    let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
    if out.status.success() {
        Ok(stdout)
    } else {
        let stderr = String::from_utf8_lossy(&out.stderr);
        Err(if stderr.trim().is_empty() { stdout } else { stderr.into_owned() })
    }
}

/// `dl status`: a short summary; `dl status --json` passes the sorter's JSON through.
pub fn status(args: &[String]) -> ExitCode {
    if args.iter().any(|a| a == "--json") {
        return run(&["status".into(), "--json".into()]);
    }
    let parsed = output(&["status".into(), "--json".into()])
        .and_then(|s| serde_json::from_str::<serde_json::Value>(&s).map_err(|e| e.to_string()));
    match parsed {
        Ok(v) => {
            print!("{}", summary(&v, &std::env::var("HOME").unwrap_or_default()));
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("dl: {e}");
            ExitCode::from(2)
        }
    }
}

fn summary(v: &serde_json::Value, home: &str) -> String {
    let short = |p: &str| match p.strip_prefix(home) {
        Some(rest) if !home.is_empty() => format!("~{rest}"),
        _ => p.to_owned(),
    };
    let wait = v["wait_seconds"].as_u64().unwrap_or(10);
    let rename = if v["rename_files"].as_bool().unwrap_or(true) { "on" } else { "off" };
    let mut out = format!("Sort new files after {wait} s. Rename from content: {rename}.\n\nFolders:\n");
    let folders = v["folders"].as_array().cloned().unwrap_or_default();
    if folders.is_empty() {
        out.push_str("  none (add one with: dl watch FOLDER)\n");
    }
    for f in &folders {
        let state = if f["watching"].as_bool().unwrap_or(false) { "watching" } else { "not watching" };
        out.push_str(&format!("  {}  {state}\n", short(f["path"].as_str().unwrap_or("?"))));
    }
    let recent = v["recent"].as_array().cloned().unwrap_or_default();
    if !recent.is_empty() {
        out.push_str("\nRecent moves:\n");
        for m in recent.iter().take(5) {
            out.push_str(&format!("  {} -> {}\n", m["file"].as_str().unwrap_or("?"), short(m["to"].as_str().unwrap_or("?"))));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn summary_shortens_home_and_lists_folders() {
        let v = json!({"wait_seconds": 30, "rename_files": false,
            "folders": [{"path": "/u/Downloads", "watching": true}],
            "recent": [{"file": "a.pdf", "to": "/u/Downloads/Work/a.pdf"}]});
        let s = summary(&v, "/u");
        assert!(s.starts_with("Sort new files after 30 s. Rename from content: off."));
        assert!(s.contains("  ~/Downloads  watching\n"));
        assert!(s.contains("  a.pdf -> ~/Downloads/Work/a.pdf\n"));
        assert!(summary(&json!({}), "/u").contains("none (add one with: dl watch FOLDER)"));
    }
}
