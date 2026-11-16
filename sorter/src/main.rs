//! Sorts loose files in a folder into <folder>/<Category>/<Subcategory> using Apple's on-device `fm` model.
//! Only files created after the folder's first run are touched unless --all is given.
const USAGE: &str = "usage:
  sorter [FOLDER] [--all] [--dry-run] [--projects]   sort FOLDER (default ~/Downloads; `.` = current folder)
      --all       also sort files that existed before the first run in this folder
      --dry-run   show what would happen, change nothing
      --projects  move code-project folders whole into Code/Projects (default only for ~/Downloads)
  sorter watch FOLDER     sort FOLDER automatically whenever something lands in it (launchd agent)
  sorter unwatch FOLDER   stop watching FOLDER
  sorter status --json    folders, categories and recent moves as JSON (used by Rays)
  sorter config add|remove FOLDER
  sorter config set-dest FOLDER CATEGORY PATH | clear-dest FOLDER CATEGORY";
mod config;
mod status;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const PARTIAL: &[&str] = &["crdownload", "download", "part", "partial", "tmp"];
const TEXT: &[&str] = &["txt", "md", "csv", "json", "yaml", "yml", "xml", "html", "log", "py", "js", "java", "sql", "sh"];
const IMAGE: &[&str] = &["png", "jpg", "jpeg", "heic", "gif", "webp"];
const ZIPS: &[&str] = &["zip", "jar"];
const NO_TEXT: &[&str] = &["dmg", "pkg", "mpkg", "iso", "tar", "gz", "tgz", "7z", "rar", "bz2", "xz", "app"]; // nothing cheap to extract
const TEXTUTIL: &[&str] = &["docx", "doc", "rtf", "odt"]; // fallback when markitdown fails
const MAX_EXTRACT: u64 = 50_000_000; // skip content extraction above 50 MB

/// First ~1500 chars describing the file's content, for any type: zip listing, markitdown (~/.local/bin, from
/// `uv tool install`), textutil, and finally `file -b`.
fn extract_text(p: &Path, e: &str, size: u64) -> Option<String> {
    let run = |cmd: &mut Command| cmd.output().ok().filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).chars().filter(|c| !c.is_control() || c.is_whitespace()).take(CONTENT_CHARS).collect::<String>())
        .filter(|t| !t.trim().is_empty());
    let home = PathBuf::from(std::env::var("HOME").ok()?);
    // Bundled next to sorter in Rays.app; the old checkout is a fallback. ~10 ms per file.
    let extract = std::env::current_exe().ok().map(|e| e.with_file_name("extract")).filter(|p| p.exists())
        .unwrap_or_else(|| home.join("local-scripts/extract/bin/extract"));
    let md = home.join(".local/bin/markitdown"); // fallback for formats extract doesn't handle (~500 ms)
    let skip = NO_TEXT.contains(&e) || IMAGE.contains(&e) || size > MAX_EXTRACT;
    (ZIPS.contains(&e).then(|| run(Command::new("unzip").arg("-l").arg(p))).flatten())
        .or_else(|| (!skip).then(|| run(Command::new(&extract).arg(p).args(["--max", &CONTENT_CHARS.to_string()]))).flatten())
        .or_else(|| (!skip).then(|| run(Command::new(&md).arg(p))).flatten())
        .or_else(|| TEXTUTIL.contains(&e).then(|| run(Command::new("textutil").args(["-convert", "txt", "-stdout"]).arg(p))).flatten())
        .or_else(|| run(Command::new("file").arg("-b").arg(p)))
}

/// Spotlight metadata worth showing the model; WhereFroms holds the download URL for almost every download.
fn metadata(p: &Path) -> String {
    let fields = ["kMDItemKind", "kMDItemWhereFroms", "kMDItemTitle", "kMDItemAuthors", "kMDItemPixelHeight"];
    let mut cmd = Command::new("mdls");
    for f in fields { cmd.args(["-name", f]); }
    cmd.arg(p).output().map(|o| String::from_utf8_lossy(&o.stdout)
        .lines().filter(|l| !l.contains("(null)")).collect::<Vec<_>>().join("\n"))
        .unwrap_or_default()
}
const CONTENT_CHARS: usize = 800; // shorter prompt = faster on-device model
const SETTLE: Duration = Duration::from_secs(10); // skip files still being written
const ARCHIVE: &str = "Duplicates";
const MARKER: &str = ".sorted-by-fm";
// Topic-based, not file-type-based: a billing CSV and a billing PDF belong together.
const CATEGORIES: &[(&str, &str)] = &[
    ("Work", "anything about a business or job, in any format (PDF, spreadsheet, CSV, doc): billing, customers, orders, deliveries, kitchen ops, design docs, specs, reports, data exports"),
    ("Personal", "the user's own life, any format: identity documents (Aadhaar, PAN, passport), bank statements, receipts, medical, education transcripts, certificates"),
    ("Images", "photos, screenshots, GIFs, logos, wallpapers, graphics not tied to a document"),
    ("Installers", "apps, disk images, packages, VPN profiles, device certificates"),
    ("Archives", "zip/tar/rar and other compressed bundles"),
    ("Media", "audio and video"),
    ("Code", "source code and scripts only (not data CSV/JSON exports)"),
    ("Other", "manuals, articles, ebooks, anything that fits nothing above"),
];

/// Title Case: "MISSED COMMS" -> "Missed Comms", "kitchen packing sheet" -> "Kitchen Packing Sheet".
/// Keeps short acronyms (PRD, NIIT), mixed case (NeuroSense), words with digits (arm64), and small words mid-name.
fn title_case(s: &str) -> String {
    const SMALL: &[&str] = &["a", "an", "and", "as", "at", "by", "for", "in", "of", "on", "or", "the", "to", "vs", "with"];
    let cap = |w: &str| { let mut c = w.chars(); c.next().map(|f| f.to_uppercase().collect::<String>() + c.as_str()).unwrap_or_default() };
    s.split(' ').enumerate().map(|(i, w)| {
        let alpha = w.chars().any(|c| c.is_alphabetic()) && !w.chars().any(|c| c.is_ascii_digit());
        let all_upper = !w.chars().any(|c| c.is_lowercase());
        let all_lower = !w.chars().any(|c| c.is_uppercase());
        if alpha && all_upper && w.len() > 4 { cap(&w.to_lowercase()) }
        else if alpha && all_lower && !(i > 0 && SMALL.contains(&w)) { cap(w) }
        else { w.to_string() }
    }).collect::<Vec<_>>().join(" ")
}

/// Strips a repeated category prefix and reuses an existing subfolder that differs only by case or a trailing "s".
fn normalize_sub(cat_dir: &Path, cat: &str, sub: &str) -> String {
    let sub = sub.strip_prefix(cat).unwrap_or(sub).trim();
    let sub = if sub.is_empty() || sub.eq_ignore_ascii_case(cat) { "General" } else { sub };
    let key = |s: &str| s.to_lowercase().trim_end_matches('s').to_string();
    fs::read_dir(cat_dir).into_iter().flatten().flatten()
        .filter(|e| e.path().is_dir())
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .find(|existing| key(existing) == key(sub))
        .unwrap_or_else(|| clean(sub))
}

/// Build/package manifest markers that identify a code project folder.
const PROJECT_MARKERS: &[&str] = &["pom.xml", "build.gradle", "build.gradle.kts", "package.json", "Cargo.toml", "go.mod",
    "pyproject.toml", "requirements.txt", "setup.py", "composer.json", "Gemfile", "Package.swift", "pubspec.yaml", ".git"];

fn is_project(dir: &Path) -> bool {
    PROJECT_MARKERS.iter().any(|m| dir.join(m).exists())
}

/// Fixed folders for files the model can't improve on; checked before calling `fm`.
fn rule(p: &Path) -> Option<(&'static str, &'static str)> {
    let name = p.file_name()?.to_string_lossy().to_lowercase();
    if name.starts_with("screenshot") || name.starts_with("screen shot") {
        return Some(("Images", "Screenshots"));
    }
    match ext(p).as_str() {
        "dmg" | "pkg" | "iso" | "mpkg" => Some(("Installers", "Apps")),
        "zip" | "tar" | "gz" | "tgz" | "7z" | "rar" | "bz2" | "xz" => Some(("Archives", "Compressed")),
        _ => None,
    }
}

fn sha256(p: &Path) -> Option<String> {
    let mut f = File::open(p).ok()?;
    let mut h = Sha256::new();
    let mut buf = vec![0u8; 1 << 20];
    loop {
        let n = f.read(&mut buf).ok()?;
        if n == 0 { break; }
        h.update(&buf[..n]);
    }
    Some(h.finalize().iter().map(|b| format!("{b:02x}")).collect())
}

/// Size+hash index of sorted files (outside Archive). Hashes are cached on disk keyed by path/size/mtime,
/// and only computed for files whose size matches a new download.
struct Index {
    files: Vec<(PathBuf, u64, u64)>, // path, size, mtime
    cache: HashMap<String, (u64, u64, String)>,
    cache_file: PathBuf,
}

impl Index {
    fn load(root: &Path, cache_file: PathBuf) -> Self {
        let cache = fs::read_to_string(&cache_file).ok()
            .and_then(|s| serde_json::from_str::<HashMap<String, (u64, u64, String)>>(&s).ok())
            .unwrap_or_default();
        // Sorted files live exactly at <root>/<Category>/<Subcategory>/<file>; don't descend into other folders in Downloads.
        let mut files = vec![];
        for cat in existing_folders(root) {
            for e in fs::read_dir(root.join(&cat)).into_iter().flatten().flatten() {
                let q = e.path();
                if q.is_file() && !e.file_name().to_string_lossy().starts_with('.') && let Ok(m) = e.metadata() {
                    files.push((q, m.len(), m.modified().map(secs).unwrap_or(0.0) as u64));
                }
            }
        }
        Index { files, cache, cache_file }
    }

    fn hash_of(&mut self, p: &Path, size: u64, mtime: u64) -> Option<String> {
        let key = p.to_string_lossy().into_owned();
        if let Some((s, m, h)) = self.cache.get(&key) && *s == size && *m == mtime {
            return Some(h.clone());
        }
        let h = sha256(p)?;
        self.cache.insert(key, (size, mtime, h.clone()));
        Some(h)
    }

    fn find_duplicate(&mut self, p: &Path) -> Option<PathBuf> {
        let size = fs::metadata(p).ok()?.len();
        let candidates: Vec<_> = self.files.iter().filter(|f| f.1 == size).cloned().collect();
        if candidates.is_empty() { return None; }
        let mine = sha256(p)?;
        candidates.into_iter()
            .find(|(q, s, m)| self.hash_of(q, *s, *m).as_deref() == Some(mine.as_str()))
            .map(|(q, ..)| q)
    }

    fn add(&mut self, p: &Path) {
        if let Ok(m) = fs::metadata(p) {
            self.files.push((p.to_path_buf(), m.len(), m.modified().map(secs).unwrap_or(0.0) as u64));
        }
    }

    fn save(&self) {
        let live: HashMap<_, _> = self.cache.iter().filter(|(k, _)| Path::new(k).exists()).collect();
        let _ = fs::write(&self.cache_file, serde_json::to_string(&live).unwrap_or_default());
    }
}

fn now() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs_f64()
}

fn secs(t: SystemTime) -> f64 {
    t.duration_since(UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

fn ext(p: &Path) -> String {
    p.extension().and_then(|e| e.to_str()).unwrap_or("").to_lowercase()
}

fn log(log_file: &Path, dry: bool, msg: &str) {
    println!("{msg}");
    if !dry && let Ok(mut f) = OpenOptions::new().create(true).append(true).open(log_file) {
        let _ = writeln!(f, "{:.0} {msg}", now());
    }
}

/// Local date (YYYY-MM-DD) via `date`, so late-night downloads aren't stamped with the UTC day.
fn local_date() -> String {
    Command::new("date").arg("+%F").output()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_default()
}

/// Appends one compact line per move, `date<TAB>original name<TAB>new path relative to Downloads`, grep-friendly for agents.
fn record_rename(log_file: &Path, root: &Path, from: &Path, to: &Path, date: &str) {
    let new = !log_file.exists();
    if let Ok(mut f) = OpenOptions::new().create(true).append(true).open(log_file) {
        if new { let _ = writeln!(f, "# ~/Downloads sorter moves. date\toriginal_name\tnew_path (relative to ~/Downloads). Last match wins."); }
        let from = from.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        let to = to.strip_prefix(root).unwrap_or(to).display();
        let _ = writeln!(f, "{date}\t{from}\t{to}");
    }
}

/// The sorter's "skill": one Markdown file in ~/Downloads/.sorter/skill.md, read every run and appended to when the
/// user corrects a filing (continuous learning). Sections (by `## ` heading):
/// - Categories: `- Name: description` (the model may only pick these)
/// - Rules: free-text rules appended to the model instructions
/// - Learned examples: `- file name -> Category/Subcategory` (appended automatically; edit or delete freely)
///
/// Other sections (e.g. notes for agents) are ignored by the sorter.
struct Config { cats: Vec<(String, String)>, rules: String, examples: String, cache_key: String }

fn default_skill(root: &Path) -> String {
    let r = root.display();
    format!("# Sorter skill for {r}

How {r} gets sorted. Rays sorter reads this file on every run.
Edit Categories/Rules to change behaviour; Learned examples grows when you move a sorted file to a better folder.

## For agents
- Moves/renames log: {r}/.sorter/renames.tsv (date, original name, new path relative to {r}; last match wins)
- Exact duplicates go to {r}/Duplicates/<same path>; folders that existed before sorting are left untouched

## Categories
{}
## Rules
- Never put business documents (orders, company invoices, delivery labels, menus) under Personal.
- Personal is only for the user's own identity, money, health and education documents.

## Learned examples
", CATEGORIES.iter().map(|(c, d)| format!("- {c}: {d}\n")).collect::<String>())
}

fn section<'a>(text: &'a str, name: &str) -> Vec<&'a str> {
    let mut on = false;
    text.lines().filter(|l| {
        if let Some(h) = l.strip_prefix("## ") { on = h.trim().eq_ignore_ascii_case(name); return false; }
        on && !l.trim().is_empty()
    }).collect()
}

fn load_config(skill: &Path) -> Config {
    if !skill.exists() {
        let _ = fs::create_dir_all(skill.parent().unwrap());
        let _ = fs::write(skill, default_skill(skill.parent().and_then(Path::parent).unwrap_or(skill)));
    }
    let text = fs::read_to_string(skill).unwrap_or_default();
    let mut cats: Vec<(String, String)> = section(&text, "Categories").iter()
        .filter_map(|l| l.trim_start_matches("- ").split_once(':'))
        .map(|(c, d)| (c.trim().to_string(), d.trim().to_string())).collect();
    if cats.is_empty() { cats = CATEGORIES.iter().map(|(c, d)| (c.to_string(), d.to_string())).collect(); }
    let rules = section(&text, "Rules").join("\n");
    let examples: Vec<&str> = section(&text, "Learned examples").into_iter().filter(|l| l.contains("->")).collect();
    let examples = examples[examples.len().saturating_sub(MAX_EXAMPLES)..].join("\n");
    // Editing categories or rules invalidates cached answers; new examples don't (they only add hints).
    let mut h = Sha256::new();
    h.update(format!("{cats:?}{rules}").as_bytes());
    let fp: String = h.finalize().iter().take(4).map(|b| format!("{b:02x}")).collect();
    Config { cats, rules, examples, cache_key: format!("{CACHE_VERSION}-{fp}") }
}

/// Appends learned examples at the end of "## Learned examples" (section added if missing).
fn learn_into_skill(skill: &Path, learned: &[(String, String)]) {
    if learned.is_empty() { return; }
    let text = fs::read_to_string(skill).unwrap_or_default();
    let _ = fs::write(skill, add_examples(&text, learned));
}

fn add_examples(text: &str, learned: &[(String, String)]) -> String {
    let lines: String = learned.iter().map(|(n, f)| format!("- {n} -> {f}\n")).collect();
    let Some(i) = text.find("## Learned examples") else { return format!("{text}\n## Learned examples\n{lines}") };
    let end = text[i..].find("\n## ").map(|n| i + n + 1).unwrap_or(text.len()); // start of next section, or EOF
    let head = text[..end].trim_end_matches('\n');
    format!("{head}\n{lines}{}", if end < text.len() { format!("\n{}", &text[end..]) } else { String::new() })
}

const MAX_EXAMPLES: usize = 25;

/// Finds files the user moved to another sorted folder since we filed them: for each file's latest log entry whose
/// path no longer exists, look for the same file name elsewhere under the sorted categories. Each hit becomes an
/// example, updates the content cache, and gets a fresh log line so it isn't learned twice.
fn learn_corrections(root: &Path, renames_log: &Path, index: &Index, cache: &mut HashMap<String, Classified>, today: &str, cache_key: &str) -> Vec<(String, String)> {
    let Ok(text) = fs::read_to_string(renames_log) else { return vec![] };
    let mut latest: HashMap<String, String> = HashMap::new(); // new file name -> relative path where we last put it
    for line in text.lines().filter(|l| !l.starts_with('#')) {
        let cols: Vec<&str> = line.split('\t').collect();
        if let [_, _, rel] = cols[..] {
            let name = Path::new(rel).file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
            latest.insert(name, rel.to_string());
        }
    }
    let mut learned = vec![];
    for (name, rel) in latest {
        if rel.starts_with(ARCHIVE) || root.join(&rel).exists() { continue; }
        let hits: Vec<&PathBuf> = index.files.iter().map(|f| &f.0)
            .filter(|f| f.file_name().map(|n| n.to_string_lossy() == name.as_str()).unwrap_or(false)).collect();
        let [found] = hits[..] else { continue }; // deleted, renamed, or ambiguous: nothing to learn
        let Ok(new_rel) = found.strip_prefix(root) else { continue };
        let parts: Vec<String> = new_rel.components().map(|c| c.as_os_str().to_string_lossy().into_owned()).collect();
        let [cat, sub, _] = &parts[..] else { continue };
        if let Some(h) = sha256(found) {
            let stem = found.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
            cache.insert(format!("{cache_key}:{h}"), (cat.clone(), sub.clone(), stem.clone()));
        }
        record_rename(renames_log, root, &root.join(&rel), found, today);
        learned.push((name.rsplit_once('.').map(|(s, _)| s.to_string()).unwrap_or(name.clone()), format!("{cat}/{sub}")));
    }
    learned
}

fn existing_folders(root: &Path) -> Vec<String> {
    let dirs = |p: &Path| -> Vec<String> {
        let mut v: Vec<String> = fs::read_dir(p).into_iter().flatten().flatten()
            .filter(|e| e.path().is_dir() && !e.file_name().to_string_lossy().starts_with('.'))
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .collect();
        v.sort();
        v
    };
    // Only folders this tool created (marked) count, so user folders in Downloads are never offered or scanned.
    dirs(root).into_iter().filter(|c| c != ARCHIVE && root.join(c).join(MARKER).exists()).flat_map(|cat| {
        let subs = dirs(&root.join(&cat));
        if subs.is_empty() { vec![cat] } else { subs.into_iter().map(|s| format!("{cat}/{s}")).collect() }
    }).collect()
}

fn clean_n(s: &str, max: usize) -> String {
    let s: String = s.chars().filter(|c| !"/\\:*?\"<>|.".contains(*c)).collect();
    let s = s.split_whitespace().collect::<Vec<_>>().join(" ");
    let s: String = s.chars().take(max).collect();
    if s.is_empty() { "Misc".into() } else { s }
}

fn clean(s: &str) -> String { clean_n(s, 40) }

/// Drops date-like words ("2026-04-14", "2026") the model put in the name; the verified date is appended separately.
fn strip_dates(s: &str) -> String {
    s.split(' ').filter(|w| !(w.len() >= 4 && w.chars().all(|c| c.is_ascii_digit() || c == '-'))).collect::<Vec<_>>().join(" ")
}

/// Accepts the model's YYYY-MM[-DD] only if that year really occurs in the extracted content or original name.
fn verified_date(date: &str, evidence: &str) -> Option<String> {
    let d = date.trim();
    let ok = (d.len() == 7 || d.len() == 10)
        && d.chars().enumerate().all(|(i, c)| if i == 4 || i == 7 { c == '-' } else { c.is_ascii_digit() });
    (ok && evidence.contains(&d[..4])).then(|| d.to_string())
}

/// Installers and opaque archives: the original name is the best info. Tidy it, no date.
fn tidy_name(stem: &str) -> String {
    let s = stem.replace(['_', '+'], " ");
    let s = match s.rfind(" (") { Some(i) if s.ends_with(')') => s[..i].to_string(), _ => s };
    let s: String = s.chars().filter(|c| !"/\\:*?\"<>|".contains(*c)).collect(); // keep dots: versions like 3.9.1
    title_case(s.split_whitespace().collect::<Vec<_>>().join(" ").trim_matches('.'))
}

type Classified = (String, String, String); // category, subcategory, file stem

/// Bump when prompt/schema/naming rules change so cached answers are recomputed.
const CACHE_VERSION: &str = "v2";

/// Same content (by SHA-256) -> same answer, so re-sorts and re-downloads skip extraction and `fm`.
fn classify_cached(p: &Path, layout: &config::Layout, schema: &Path, cache: &mut HashMap<String, Classified>, cfg: &Config) -> Result<(Classified, String), String> {
    let t = Instant::now();
    let key = sha256(p).map(|h| format!("{}:{h}", cfg.cache_key));
    if let Some((cat, sub, name)) = key.as_ref().and_then(|k| cache.get(k)).cloned() {
        let sub = normalize_sub(&layout.cat_dir(&cat), &cat, &sub);
        return Ok(((cat, sub, name), format!("cache {}ms", t.elapsed().as_millis())));
    }
    let hash_ms = t.elapsed().as_millis();
    let (result, timing) = classify(p, layout, schema, cfg)?;
    if let Some(k) = key { cache.insert(k, result.clone()); }
    Ok((result, format!("hash {hash_ms}ms {timing}")))
}

fn classify(p: &Path, layout: &config::Layout, schema: &Path, cfg: &Config) -> Result<(Classified, String), String> {
    let t = Instant::now();
    let size = fs::metadata(p).map_err(|e| e.to_string())?.len();
    let folders = existing_folders(&layout.root);
    let instructions = format!(
        "You file downloaded files into folders. Pick the category from this list:\n{}\nThe subcategory groups similar files inside that category; it must NOT repeat the category name. \
Reuse an existing subcategory only if it truly describes this file's subject (for images: what the picture shows); otherwise invent a fitting new one. Existing folders: {}{}{}",
        cfg.cats.iter().map(|(c, d)| format!("- {c}: {d}")).collect::<Vec<_>>().join("\n"),
        if folders.is_empty() { "(none yet)".into() } else { folders.join(", ") },
        if cfg.rules.is_empty() { String::new() } else { format!("\nRules:\n{}", cfg.rules) },
        if cfg.examples.is_empty() { String::new() } else { format!("\nExamples of correct filing (follow these):\n{}", cfg.examples) }
    );
    let mut prompt = format!("File name: {}\nSize: {} KB\nMetadata:\n{}",
        p.file_name().unwrap().to_string_lossy(), size / 1024, metadata(p));
    let e = ext(p);
    let content = if TEXT.contains(&e.as_str()) {
        let mut buf = vec![0u8; CONTENT_CHARS];
        let n = File::open(p).and_then(|mut f| f.read(&mut buf)).unwrap_or(0);
        String::from_utf8_lossy(&buf[..n]).chars().filter(|c| !c.is_control() || c.is_whitespace()).collect()
    } else {
        extract_text(p, &e, size).unwrap_or_default()
    };
    if !content.is_empty() { prompt += &format!("\nContent start:\n{content}"); }
    let extract_ms = t.elapsed().as_millis();
    let t = Instant::now();
    let mut cmd = Command::new("fm");
    cmd.args(["respond", "--no-stream", "--greedy", "--schema"]).arg(schema).args(["-i", &instructions]);
    if IMAGE.contains(&e.as_str()) && size < 20_000_000 {
        cmd.arg("--image").arg(p);
    }
    let out = cmd.arg(&prompt).output().map_err(|e| format!("fm: {e}"))?;
    let fm_ms = t.elapsed().as_millis();
    let text = String::from_utf8_lossy(&out.stdout);
    let (a, b) = (text.find('{'), text.rfind('}'));
    let (Some(a), Some(b)) = (a, b) else {
        return Err(format!("no JSON from fm: {}", String::from_utf8_lossy(&out.stderr).trim()));
    };
    let v: Value = serde_json::from_str(&text[a..=b]).map_err(|e| e.to_string())?;
    let get = |k: &str| v[k].as_str().map(clean).ok_or(format!("missing {k}"));
    let cat = get("category")?;
    let sub = normalize_sub(&layout.cat_dir(&cat), &cat, &get("subcategory")?);
    let raw_name = v["filename"].as_str().ok_or("missing filename")?;
    let mut name = title_case(&clean_n(&strip_dates(raw_name), 80));
    let evidence = format!("{content}\n{}", p.file_name().unwrap().to_string_lossy());
    if let Some(d) = v["content_date"].as_str().and_then(|d| verified_date(d, &evidence)) {
        name = format!("{name} {d}");
    }
    Ok(((cat, sub, name), format!("extract {extract_ms}ms fm {fm_ms}ms prompt {}ch", prompt.len() + instructions.len())))
}

fn unique_target(dir: &Path, stem: &str, p: &Path) -> PathBuf {
    let e = p.extension().map(|e| format!(".{}", e.to_string_lossy())).unwrap_or_default();
    let mut target = dir.join(format!("{stem}{e}"));
    let mut i = 1;
    while target.exists() {
        target = dir.join(format!("{stem} ({i}){e}"));
        i += 1;
    }
    target
}

/// Installs or removes a launchd agent that runs `sorter FOLDER` whenever FOLDER changes.
/// ~/Downloads keeps its original label `local.sorter`; other folders get `local.sorter.<path-slug>`.
fn watch(home: &Path, state_dir: &Path, dir: &Path, on: bool) -> Result<String, String> {
    if !dir.is_dir() { return Err(format!("not a folder: {}", dir.display())); }
    let slug: String = dir.strip_prefix(home).unwrap_or(dir).to_string_lossy().chars()
        .map(|c| if c.is_ascii_alphanumeric() { c.to_ascii_lowercase() } else { '-' }).collect();
    let label = if dir == home.join("Downloads") { "local.sorter".to_string() } else { format!("local.sorter.{}", slug.trim_matches('-')) };
    let plist = home.join("Library/LaunchAgents").join(format!("{label}.plist"));
    let uid = String::from_utf8_lossy(&Command::new("id").arg("-u").output().map_err(|e| e.to_string())?.stdout).trim().to_string();
    let domain = format!("gui/{uid}");
    let _ = Command::new("launchctl").args(["bootout", &format!("{domain}/{label}")]).output();
    if !on {
        let _ = fs::remove_file(&plist);
        return Ok(format!("stopped watching {} ({label})", dir.display()));
    }
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let exe = fs::canonicalize(&exe).unwrap_or(exe);
    let esc = |s: &str| s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;");
    let d = esc(&dir.to_string_lossy());
    let body = format!(r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>{label}</string>
  <key>ProgramArguments</key><array><string>{}</string><string>{d}</string></array>
  <key>WatchPaths</key><array><string>{d}</string></array>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>/usr/bin:/bin:/usr/sbin</string></dict>
  <key>StandardErrorPath</key><string>{}</string>
  <key>ThrottleInterval</key><integer>15</integer>
</dict></plist>
"#, esc(&exe.to_string_lossy()), esc(&state_dir.join("sorter.err").to_string_lossy()));
    fs::write(&plist, body).map_err(|e| e.to_string())?;
    let out = Command::new("launchctl").args(["bootstrap", &domain]).arg(&plist).output().map_err(|e| e.to_string())?;
    if !out.status.success() { return Err(format!("launchctl: {}", String::from_utf8_lossy(&out.stderr).trim())); }
    Ok(format!("watching {} ({label}); new files there get sorted automatically", dir.display()))
}

/// Copies learned names and caches from the old checkout's data dir into an empty state dir, once. Copies, never moves.
fn migrate_state(old: &Path, new: &Path) -> std::io::Result<()> {
    let empty = fs::read_dir(new).map(|mut d| d.next().is_none()).unwrap_or(true);
    if !old.is_dir() || !empty {
        return Ok(());
    }
    fs::create_dir_all(new)?;
    for name in [".hash-index.json", ".class-cache.json", "names.txt"] {
        let src = old.join(name);
        if src.is_file() {
            fs::copy(&src, new.join(name))?;
        }
    }
    Ok(())
}

fn env_path(name: &str) -> Option<PathBuf> {
    std::env::var_os(name).map(PathBuf::from)
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.iter().any(|a| a == "-h" || a == "--help") { return println!("{USAGE}"); }
    let dry = args.iter().any(|a| a == "--dry-run");
    let all = args.iter().any(|a| a == "--all");
    let home = PathBuf::from(std::env::var("HOME").expect("HOME"));
    // --dir <folder> sorts another folder (e.g. ~/Documents); default ~/Downloads. Each folder keeps its own
    // .sorter/ (skill, renames log, start time). Project folders are only moved when sorting ~/Downloads.
    let positional: Vec<&String> = args.iter().skip(1).filter(|a| !a.starts_with("--")).collect();
    let resolve = |d: &str| -> PathBuf {
        let p = PathBuf::from(d.replacen('~', &home.to_string_lossy(), 1));
        fs::canonicalize(&p).unwrap_or(p)
    };
    let state_dir = env_path("RAYS_SORTER_STATE").unwrap_or_else(|| home.join("Library/Application Support/Rays/Sorter"));
    let config_path = env_path("RAYS_SORTER_CONFIG").unwrap_or_else(|| home.join("Library/Application Support/Rays/sorter.json"));
    let old_state = env_path("RAYS_SORTER_OLD_STATE").unwrap_or_else(|| home.join("local-scripts/sorter/data"));
    if let Err(e) = migrate_state(&old_state, &state_dir) { eprintln!("state migration failed: {e}"); }
    let _ = fs::create_dir_all(&state_dir);
    let words: Vec<&str> = positional.iter().map(|s| s.as_str()).collect();
    let abs = |d: &str| -> String {
        let p = resolve(d);
        if p.is_absolute() { p.to_string_lossy().into_owned() } else { eprintln!("not an absolute path: {d}"); std::process::exit(2) }
    };
    match words.as_slice() {
        ["status"] => {
            if !args.iter().any(|a| a == "--json") { eprintln!("usage: sorter status --json"); std::process::exit(2) }
            let doc = config::load(&config_path).unwrap_or_else(|e| { eprintln!("{e}"); json!({"folders": []}) });
            return println!("{}", status::status_json(&home, &doc, &state_dir, CATEGORIES));
        }
        ["config", rest @ ..] => {
            let edit = match rest {
                ["add", f] => config::Edit::Add(abs(f)),
                ["remove", f] => config::Edit::Remove(abs(f)),
                ["set-dest", f, c, d] => config::Edit::SetDest { folder: abs(f), category: c.to_string(), dest: abs(d) },
                ["clear-dest", f, c] => config::Edit::ClearDest { folder: abs(f), category: c.to_string() },
                _ => { eprintln!("{USAGE}"); std::process::exit(2) }
            };
            return match config::edit_file(&config_path, &edit) { Ok(()) => {}, Err(e) => { eprintln!("{e}"); std::process::exit(1) } };
        }
        [cmd, dir] if *cmd == "watch" || *cmd == "unwatch" => {
            return match watch(&home, &state_dir, &resolve(dir), *cmd == "watch") { Ok(m) => println!("{m}"), Err(e) => { eprintln!("{e}"); std::process::exit(1) } };
        }
        _ => {}
    }
    let downloads = match positional[..] {
        [] => home.join("Downloads"),
        [d] => resolve(d),
        _ => { eprintln!("{USAGE}"); std::process::exit(2) }
    };
    if !downloads.is_dir() { eprintln!("not a folder: {}", downloads.display()); std::process::exit(2); }
    let move_projects = args.iter().any(|a| a == "--projects") || downloads == home.join("Downloads");
    let root = downloads.clone();
    let config_doc = config::load(&config_path).unwrap_or_else(|e| { eprintln!("ignoring destinations: {e}"); json!({"folders": []}) });
    let layout = config::Layout::new(&root, &config_doc);
    let log_file = state_dir.join("sorter.log");
    let sorter_dir = downloads.join(".sorter"); // hidden, so the sorter never sorts it
    let state = sorter_dir.join("since");
    let _ = fs::create_dir_all(&sorter_dir);
    let renames_log = sorter_dir.join("renames.tsv");
    let skill = sorter_dir.join("skill.md");
    let today = local_date();

    if !state.exists() {
        fs::write(&state, now().to_string()).expect("write state");
    }
    let since = if all { 0.0 } else { fs::read_to_string(&state).ok().and_then(|s| s.trim().parse().ok()).unwrap_or(0.0) };
    if !all {
        std::thread::sleep(SETTLE); // let the browser finish renaming the download
    }
    let mut index = Index::load(&root, state_dir.join(".hash-index.json"));
    let cache_file = state_dir.join(".class-cache.json");
    let mut cache: HashMap<String, Classified> = fs::read_to_string(&cache_file).ok()
        .and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_default();
    let run_start = Instant::now();
    let pre = load_config(&skill);
    if !dry {
        let learned = learn_corrections(&root, &renames_log, &index, &mut cache, &today, &pre.cache_key);
        for (name, folder) in &learned { log(&log_file, dry, &format!("learned: {name} -> {folder}")); }
        learn_into_skill(&skill, &learned);
    }
    let cfg = load_config(&skill); // reload so just-learned examples apply this run

    let schema = std::env::temp_dir().join("sorter-schema.json");
    fs::write(&schema, json!({
        "type": "object",
        "properties": {
            "category": {"type": "string", "enum": cfg.cats.iter().map(|(c, _)| c.as_str()).collect::<Vec<_>>()},
            "subcategory": {"type": "string", "description": "Subfolder grouping similar files, 1-3 words, Title Case, e.g. Browsers, Invoices, Billing Reports"},
            "filename": {"type": "string", "description": "New file name WITHOUT extension and WITHOUT any date, 3-8 words, describing what the CONTENT is (who/what), not a copy of the old file name. Title Case. e.g. Unity Billing Email Comms Audit, Vegapay Payslip, NIIT University Transcript"},
            "content_date": {"type": "string", "description": "The date the content is about, as YYYY-MM-DD or YYYY-MM, ONLY if a date is written in the content or file name; otherwise empty string. Never use download or file creation dates."}
        },
        "required": ["category", "subcategory", "filename", "content_date"]
    }).to_string()).expect("write schema");

    let mut entries: Vec<PathBuf> = match fs::read_dir(&downloads) {
        Ok(rd) => rd.flatten().map(|e| e.path()).collect(),
        Err(e) => return log(&log_file, dry, &format!("cannot read Downloads (grant Full Disk Access?): {e}")),
    };
    entries.sort();

    for p in entries {
        let name = p.file_name().unwrap().to_string_lossy().into_owned();
        // Project folders move whole (never split) to Code/Projects; other folders are left alone.
        if move_projects && p.is_dir() && !name.starts_with('.') && is_project(&p) {
            let born = fs::metadata(&p).and_then(|m| m.created()).map(secs).unwrap_or(0.0);
            if born < since { continue; }
            let code_dir = layout.cat_dir("Code");
            let dir = code_dir.join("Projects");
            let target = unique_target(&dir, &name, Path::new(""));
            log(&log_file, dry, &format!("{}{name}/ -> {} (project)", if dry { "[dry] " } else { "" }, target.display()));
            if !dry {
                match fs::create_dir_all(&dir).and_then(|_| fs::write(code_dir.join(MARKER), "")).and_then(|_| fs::rename(&p, &target)) {
                    Ok(()) => record_rename(&renames_log, &root, &p, &target, &today),
                    Err(e) => log(&log_file, dry, &format!("move failed {name}/: {e}")),
                }
            }
            continue;
        }
        if !p.is_file() || name.starts_with('.') || PARTIAL.contains(&ext(&p).as_str()) {
            continue;
        }
        let Ok(md) = fs::metadata(&p) else { continue };
        let born = md.created().map(secs).unwrap_or(0.0);
        let modified = md.modified().map(secs).unwrap_or(0.0);
        if born < since || now() - modified < SETTLE.as_secs_f64() {
            continue;
        }
        // Duplicate of an already-sorted file: mirror its location under Duplicates, keep original name, skip fm.
        let orig_stem = p.file_stem().unwrap().to_string_lossy().into_owned();
        // (target dir, category dir that gets the marker, file stem, reason, indexed)
        let planned = match (index.find_duplicate(&p), rule(&p)) {
            (Some(orig), _) => {
                let rel = orig.parent().unwrap().strip_prefix(&root).unwrap().to_path_buf();
                Ok((root.join(ARCHIVE).join(rel), root.join(ARCHIVE), orig_stem, format!("duplicate of {}", orig.display()), false))
            }
            // Rule fixes the folder; the model still names the file from its content/metadata.
            (None, Some((cat, sub))) => {
                let stem = if NO_TEXT.contains(&ext(&p).as_str()) {
                    tidy_name(&orig_stem)
                } else {
                    match classify_cached(&p, &layout, &schema, &mut cache, &cfg) {
                        Ok(((.., s), timing)) => { log(&log_file, dry, &format!("timing {name}: {timing}")); s }
                        Err(_) => orig_stem,
                    }
                };
                let cat_dir = layout.cat_dir(cat);
                Ok((cat_dir.join(sub), cat_dir, stem, format!("{cat}/{sub} rule"), !layout.is_external(cat)))
            }
            (None, None) => classify_cached(&p, &layout, &schema, &mut cache, &cfg).map(|((cat, sub, stem), timing)| {
                log(&log_file, dry, &format!("timing {name}: {timing}"));
                let cat_dir = layout.cat_dir(&cat);
                let indexed = !layout.is_external(&cat);
                (cat_dir.join(&sub), cat_dir, stem, format!("{cat}/{sub}"), indexed)
            }),
        };
        match planned {
            Ok((dir, cat_dir, stem, why, indexed)) => {
                let target = unique_target(&dir, &stem, &p);
                log(&log_file, dry, &format!("{}{name} -> {} ({why})", if dry { "[dry] " } else { "" }, target.display()));
                if !dry {
                    match fs::create_dir_all(&dir)
                        .and_then(|_| fs::write(cat_dir.join(MARKER), ""))
                        .and_then(|_| fs::rename(&p, &target)) {
                        Ok(()) => {
                            record_rename(&renames_log, &root, &p, &target, &today);
                            if indexed { index.add(&target); }
                        }
                        Err(e) => log(&log_file, dry, &format!("move failed {name}: {e}")),
                    }
                }
            }
            Err(e) => log(&log_file, dry, &format!("skip {name}: {e}")),
        }
    }
    if !dry {
        index.save();
        let _ = fs::write(&cache_file, serde_json::to_string(&cache).unwrap_or_default());
    }
    if run_start.elapsed().as_secs() > 1 {
        log(&log_file, dry, &format!("run took {}s", run_start.elapsed().as_secs()));
    }
}


#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn naming_helpers() {
        assert_eq!(strip_dates("2026-04-14 Unity Billing 2026"), "Unity Billing");
        assert_eq!(verified_date("2026-04-14", "bill for April 14 2026"), Some("2026-04-14".into()));
        assert_eq!(verified_date("2026-11-12", "no year here"), None);
        assert_eq!(verified_date("April 2026", "2026"), None);
        assert_eq!(tidy_name("jetbrains-toolbox-3.9.1_arm64 (1)"), "jetbrains-toolbox-3.9.1 arm64");
        let t = "## Categories\n- Work: biz\n\n## Learned examples\n- a -> Work/X\n\n## Notes\nhi\n";
        let t2 = add_examples(t, &[("b".into(), "Work/Y".into())]);
        assert_eq!(t2, "## Categories\n- Work: biz\n\n## Learned examples\n- a -> Work/X\n- b -> Work/Y\n\n## Notes\nhi\n");
        assert_eq!(section(&t2, "Learned examples"), vec!["- a -> Work/X", "- b -> Work/Y"]);
        assert_eq!(add_examples("x\n", &[("b".into(), "W/Y".into())]), "x\n\n## Learned examples\n- b -> W/Y\n");
        assert_eq!(title_case("kitchen packing sheet of the day"), "Kitchen Packing Sheet of the Day");
        assert_eq!(title_case("niit university NeuroSense PRD"), "Niit University NeuroSense PRD");
        assert_eq!(title_case("MISSED COMMS ACCOUNTS"), "Missed Comms Accounts");
    }

    #[test]
    fn migrate_copies_learned_state_once() {
        let base = std::env::temp_dir().join(format!("sorter-migrate-{}", std::process::id()));
        let _ = fs::remove_dir_all(&base);
        let (old, new) = (base.join("old"), base.join("new"));
        fs::create_dir_all(&old).unwrap();
        fs::write(old.join("names.txt"), "Alpha").unwrap();
        fs::write(old.join("sorter.log"), "x").unwrap();
        migrate_state(&old, &new).unwrap();
        assert_eq!(fs::read_to_string(new.join("names.txt")).unwrap(), "Alpha");
        assert!(!new.join("sorter.log").exists());
        assert!(old.join("names.txt").exists());
        fs::write(old.join("names.txt"), "Beta").unwrap();
        migrate_state(&old, &new).unwrap();
        assert_eq!(fs::read_to_string(new.join("names.txt")).unwrap(), "Alpha");
        let _ = fs::remove_dir_all(&base);
    }
}
