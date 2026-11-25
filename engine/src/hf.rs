//! Hugging Face repo input parsing, file grouping, and the API client for search and model info.
use crate::types::{EngineError, JobId};
use serde::Deserialize;
use serde::de::DeserializeOwned;
use std::collections::BTreeMap;
use std::path::{Component, Path, PathBuf};

/// Keychain service and account for the Hugging Face token; the S3 keys live under `ai.a6n.rays.s3`.
pub const KEYCHAIN_SERVICE: &str = "ai.a6n.rays.hf";
pub const TOKEN_ACCOUNT: &str = "token";

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct HfFile {
    pub path: String,
    pub size: u64,
    pub sha256: Option<String>,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct HfModel {
    pub id: String,
    pub downloads: u64,
    pub likes: u64,
    pub gated: bool,
    pub gguf: bool,
    pub pipeline_tag: Option<String>,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct HfRepo {
    pub id: String,
    pub sha: String,
    pub gated: bool,
    pub downloads: u64,
    pub likes: u64,
    pub pipeline_tag: Option<String>,
    pub files: Vec<HfFile>,
}

#[derive(Deserialize)]
struct WireModel {
    id: String,
    #[serde(default)]
    sha: String,
    #[serde(default)]
    gated: serde_json::Value,
    #[serde(default)]
    downloads: u64,
    #[serde(default)]
    likes: u64,
    #[serde(default)]
    tags: Vec<String>,
    #[serde(default)]
    pipeline_tag: Option<String>,
    #[serde(default)]
    siblings: Vec<WireSibling>,
}

#[derive(Deserialize)]
struct WireSibling {
    rfilename: String,
    #[serde(default)]
    size: u64,
    lfs: Option<WireLfs>,
}

#[derive(Deserialize)]
struct WireLfs {
    sha256: String,
}

/// `gated` is `false`, `"auto"` or `"manual"`; only the strings gate.
fn gated(v: &serde_json::Value) -> bool {
    matches!(v.as_str(), Some("auto" | "manual"))
}

/// An empty query lists what is trending, so the Models page never opens on a blank list.
fn search_url(base: &str, query: &str) -> Result<reqwest::Url, EngineError> {
    let query = query.trim();
    let sort = if query.is_empty() { "trendingScore" } else { "downloads" };
    let mut params = vec![("sort", sort), ("direction", "-1"), ("limit", "30"),
        ("expand[]", "gated"), ("expand[]", "downloads"), ("expand[]", "likes"), ("expand[]", "tags"), ("expand[]", "pipeline_tag")];
    if !query.is_empty() {
        params.insert(0, ("search", query));
    }
    reqwest::Url::parse_with_params(&format!("{base}/api/models"), params)
        .map_err(|e| EngineError::InvalidUrl { msg: e.to_string() })
}

pub async fn search(client: &reqwest::Client, base: &str, token: Option<&str>, query: &str) -> Result<Vec<HfModel>, EngineError> {
    let url = search_url(base, query)?;
    let models: Vec<WireModel> = get_json(client, url, token).await?;
    Ok(models
        .into_iter()
        .map(|m| HfModel { gguf: m.tags.iter().any(|t| t == "gguf"), gated: gated(&m.gated), id: m.id, downloads: m.downloads, likes: m.likes, pipeline_tag: m.pipeline_tag })
        .collect())
}

/// `org/name` with only letters, digits, `.`, `_` and `-`: nothing that could change the path or query.
fn valid_repo(repo: &str) -> bool {
    let ok = |s: &str| !matches!(s, "" | "." | "..") && s.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'));
    matches!(repo.split_once('/'), Some((org, name)) if ok(org) && ok(name))
}

/// `<base>/<org>/<name>/resolve/<sha>/<path>`, each part of `path` percent-encoded. None for a bad repo or sha.
pub fn file_url(base: &str, repo: &str, sha: &str, path: &str) -> Option<String> {
    if !valid_repo(repo) || sha.is_empty() || !sha.chars().all(|c| c.is_ascii_alphanumeric()) {
        return None;
    }
    let mut url = reqwest::Url::parse(&format!("{base}/{repo}/resolve/{sha}")).ok()?;
    url.path_segments_mut().ok()?.extend(path.split('/'));
    Some(url.into())
}

/// The parent folder and file name for a repo path under `dest_dir`. None for an absolute path, any `..`, or no name.
pub fn hf_target(dest_dir: &Path, path: &str) -> Option<(PathBuf, String)> {
    let p = Path::new(path);
    // Path would silently drop a trailing or doubled `/` and a `.`, so the target and the URL could disagree.
    let unclean = path.ends_with('/') || path.split('/').any(|s| s.is_empty() || s == ".");
    if unclean || p.is_absolute() || p.components().any(|c| matches!(c, Component::ParentDir)) {
        return None;
    }
    let name = p.file_name()?.to_str()?.to_owned();
    Some((dest_dir.join(p.parent()?), name))
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct HfAdd {
    pub path: String,
    pub status: HfAddStatus,
}

#[derive(uniffi::Enum, Clone, Debug, PartialEq)]
pub enum HfAddStatus {
    Added { id: JobId },
    /// A file of the same name and size is already at the target, so no job was made.
    AlreadyThere,
    /// A job for this file is waiting, running or paused; `id` is that job.
    AlreadyQueued { id: JobId },
    Rejected { error: String },
}

pub async fn model(client: &reqwest::Client, base: &str, token: Option<&str>, repo: &str) -> Result<HfRepo, EngineError> {
    if !valid_repo(repo) {
        return Err(EngineError::InvalidUrl { msg: format!("not a Hugging Face repo: {repo}") });
    }
    let url = reqwest::Url::parse(&format!("{base}/api/models/{repo}?blobs=true")).map_err(|e| EngineError::InvalidUrl { msg: e.to_string() })?;
    let m: WireModel = get_json(client, url, token).await?;
    Ok(HfRepo {
        gated: gated(&m.gated),
        files: m
            .siblings
            .into_iter()
            .map(|s| HfFile { path: s.rfilename, size: s.size, sha256: s.lfs.map(|l| l.sha256) })
            .collect(),
        id: m.id,
        sha: m.sha,
        downloads: m.downloads,
        likes: m.likes,
        pipeline_tag: m.pipeline_tag,
    })
}

async fn get_json<T: DeserializeOwned>(client: &reqwest::Client, url: reqwest::Url, token: Option<&str>) -> Result<T, EngineError> {
    let mut req = client.get(url);
    if let Some(token) = token {
        req = req.bearer_auth(token);
    }
    let resp = req.send().await.map_err(|e| EngineError::Io { msg: format!("hugging face: {e}") })?;
    let status = resp.status();
    if status == reqwest::StatusCode::UNAUTHORIZED && token.is_some() {
        return Err(EngineError::Io { msg: "Hugging Face rejected the saved token. Check it in Settings".into() });
    }
    if !status.is_success() {
        return Err(EngineError::Io { msg: format!("hugging face answered HTTP {}", status.as_u16()) });
    }
    let body = resp.bytes().await.map_err(|e| EngineError::Io { msg: format!("hugging face: {e}") })?;
    serde_json::from_slice(&body).map_err(|e| EngineError::Io { msg: format!("hugging face reply: {e}") })
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct HfVersion {
    pub label: String,
    pub files: Vec<String>,
    /// Includes the attached mmproj.
    pub size: u64,
    pub recommended: bool,
}

/// Closest smaller-or-equal quants first; the smallest version is the fallback.
const PREFERRED: [&str; 13] = ["Q4_K_M", "Q4_K_S", "IQ4_XS", "Q4_0", "Q3_K_L", "Q3_K_M", "IQ3_M", "Q3_K_S", "Q5_K_S", "Q5_K_M", "Q5_0", "Q6_K", "Q8_0"];
/// Checkpoint formats in priority order; pt, pth and ckpt are one tier.
const WEIGHT_TIERS: [&[&str]; 6] = [&["safetensors"], &["bin"], &["pt", "pth", "ckpt"], &["h5"], &["msgpack"], &["onnx"]];
const SKIPPED_DIRS: [&str; 4] = ["onnx/", "coreml/", "openvino/", "original/"];
const NON_MODEL_ROOTS: [&str; 9] = ["datasets", "spaces", "api", "docs", "collections", "papers", "settings", "organizations", "models"];

#[uniffi::export]
pub fn hf_repo_from_input(input: String) -> Option<String> {
    let input = input.split(['?', '#']).next().unwrap_or_default().trim();
    if input.chars().any(char::is_whitespace) {
        return None;
    }
    let prefixes = [
        "https://huggingface.co/",
        "http://huggingface.co/",
        "https://hf.co/",
        "http://hf.co/",
        "https://www.huggingface.co/",
        "http://www.huggingface.co/",
        "www.huggingface.co/",
        "huggingface.co/",
        "hf.co/",
    ];
    let (rest, from_url) = match prefixes.iter().find_map(|p| input.strip_prefix(p)) {
        Some(rest) => (rest, true),
        None => (input, false),
    };
    let mut segs = rest.split('/');
    let org = segs.next()?;
    let repo = segs.next()?;
    if org.is_empty() || repo.is_empty() || NON_MODEL_ROOTS.contains(&org) || (!from_url && segs.any(|s| !s.is_empty())) {
        return None;
    }
    Some(format!("{org}/{repo}"))
}

#[uniffi::export]
pub fn hf_versions(files: Vec<HfFile>) -> Vec<HfVersion> {
    group_versions(&files)
}

#[uniffi::export]
pub fn hf_recommended(files: Vec<HfFile>) -> Vec<String> {
    match group_versions(&files).into_iter().find(|v| v.recommended) {
        Some(v) => v.files,
        None => default_checkpoint(&files),
    }
}

fn group_versions(files: &[HfFile]) -> Vec<HfVersion> {
    let mut mmprojs = Vec::new();
    let mut groups: BTreeMap<String, Vec<(bool, &HfFile)>> = BTreeMap::new();
    for f in files {
        let Some(stem) = gguf_stem(&f.path) else { continue };
        if basename(&f.path).to_ascii_lowercase().contains("mmproj") {
            mmprojs.push(f);
            continue;
        }
        let split = strip_split_suffix(stem).len() != stem.len();
        let label = quant_label(stem).unwrap_or_else(|| strip_split_suffix(stem).to_owned());
        groups.entry(label).or_default().push((split, f));
    }
    let mmproj = mmprojs.into_iter().min_by_key(|f| f.size);

    let mut versions: Vec<HfVersion> = groups
        .into_iter()
        .map(|(label, parts)| {
            let merged: Vec<&HfFile> = parts.iter().filter(|(split, _)| !split).map(|(_, f)| *f).collect();
            let mut chosen = if merged.is_empty() { parts.iter().map(|(_, f)| *f).collect() } else { merged };
            chosen.sort_by(|a, b| a.path.cmp(&b.path));
            let mut paths: Vec<String> = chosen.iter().map(|f| f.path.clone()).collect();
            let mut size: u64 = chosen.iter().map(|f| f.size).sum();
            if let Some(m) = mmproj {
                paths.push(m.path.clone());
                size += m.size;
            }
            HfVersion { label, files: paths, size, recommended: false }
        })
        .collect();

    let pick = PREFERRED
        .iter()
        .find_map(|p| versions.iter().position(|v| v.label == *p))
        .or_else(|| versions.iter().enumerate().min_by_key(|(_, v)| v.size).map(|(i, _)| i));
    if let Some(i) = pick {
        versions[i].recommended = true;
    }
    versions
}

/// Non-GGUF repos: root configs plus one weight format, the highest tier present. Subfolder
/// weights (onnx/, original/, ...) count only when no other weights exist. The index file is
/// included only for the chosen format.
fn default_checkpoint(files: &[HfFile]) -> Vec<String> {
    let is_weight = |f: &HfFile| WEIGHT_TIERS.iter().any(|t| ext_is(&f.path, t)) && !is_training_artifact(&f.path);
    let in_primary = |f: &HfFile| !SKIPPED_DIRS.iter().any(|d| f.path.starts_with(d));
    let any_primary = files.iter().any(|f| is_weight(f) && in_primary(f));
    let in_pool = |f: &HfFile| is_weight(f) && (!any_primary || in_primary(f));
    let tier: &[&str] = WEIGHT_TIERS
        .iter()
        .copied()
        .find(|t| files.iter().any(|f| in_pool(f) && ext_is(&f.path, t)))
        .unwrap_or(&[]);
    let index = match tier {
        ["safetensors"] => "model.safetensors.index.json",
        ["bin"] => "pytorch_model.bin.index.json",
        _ => "",
    };
    // One extension per tier: the one with the most bytes, `pt` on a tie.
    let size_of = |e: &str| files.iter().filter(|f| in_pool(f) && ext_is(&f.path, &[e])).map(|f| f.size).sum::<u64>();
    let ext = tier.iter().copied().max_by_key(|e| (size_of(e), *e == "pt")).unwrap_or("");
    let sharded = matches!(tier, ["safetensors"]) && files.iter().any(|f| f.path == index) && files.iter().any(|f| is_shard(&f.path));
    let nonsharded = matches!(tier, ["safetensors"]) && !sharded && files.iter().any(|f| in_pool(f) && ext_is(&f.path, &[ext]) && !is_shard(&f.path));
    files
        .iter()
        .filter(|f| {
            is_config(&f.path)
                || f.path == index
                || (in_pool(f) && ext_is(&f.path, &[ext]) && (!sharded || is_shard(&f.path)) && (!nonsharded || !is_shard(&f.path)))
        })
        .map(|f| f.path.clone())
        .collect()
}

fn is_training_artifact(path: &str) -> bool {
    let n = basename(path).to_ascii_lowercase();
    matches!(n.as_str(), "training_args.bin" | "optimizer.pt" | "scheduler.pt") || n.starts_with("rng_state")
}

fn is_config(path: &str) -> bool {
    if path.contains('/') {
        return false;
    }
    let n = path.to_ascii_lowercase();
    n.starts_with("tokenizer")
        || matches!(
            n.as_str(),
            "merges.txt"
                | "vocab.txt"
                | "vocab.json"
                | "special_tokens_map.json"
                | "added_tokens.json"
                | "chat_template.json"
                | "chat_template.jinja"
                | "spiece.model"
                | "sentencepiece.bpe.model"
                | "preprocessor_config.json"
                | "processor_config.json"
        )
        || (n.ends_with(".json") && n.contains("config"))
}

fn ext_is(path: &str, exts: &[&str]) -> bool {
    path.rsplit_once('.').is_some_and(|(_, e)| exts.iter().any(|x| e.eq_ignore_ascii_case(x)))
}

fn basename(path: &str) -> &str {
    path.rsplit('/').next().unwrap_or(path)
}

/// File stem without `.gguf`; None for other files.
fn gguf_stem(path: &str) -> Option<&str> {
    let name = basename(path);
    let stem = name.get(..name.len().checked_sub(5)?)?;
    name[stem.len()..].eq_ignore_ascii_case(".gguf").then_some(stem)
}

/// Strips a trailing `-NNNNN-of-NNNNN`.
fn strip_split_suffix(stem: &str) -> &str {
    let b = stem.as_bytes();
    let n = b.len();
    let digits = |r: std::ops::Range<usize>| b[r].iter().all(u8::is_ascii_digit);
    if n >= 15 && b[n - 15] == b'-' && digits(n - 14..n - 9) && b[n - 9..n - 5] == *b"-of-" && digits(n - 5..n) {
        &stem[..n - 15]
    } else {
        stem
    }
}

/// Last `-` or `.` token that is a quant label, or an `_` suffix of it; uppercased, FP16 is reported as F16.
fn quant_label(stem: &str) -> Option<String> {
    stem.split(['-', '.']).rev().find_map(|t| {
        std::iter::once(t).chain(t.match_indices('_').map(|(i, _)| &t[i + 1..])).find_map(|c| {
            let u = c.to_ascii_uppercase();
            is_quant(&u).then(|| if u == "FP16" { "F16".to_owned() } else { u })
        })
    })
}

fn is_shard(path: &str) -> bool {
    path.strip_suffix(".safetensors").is_some_and(|s| strip_split_suffix(s).len() != s.len())
}

/// Uppercase token matching `I?Q\d(_[A-Z0-9]+)*`, or F16, BF16, F32, FP16.
fn is_quant(u: &str) -> bool {
    if matches!(u, "F16" | "BF16" | "F32" | "FP16") {
        return true;
    }
    let Some(rest) = u.strip_prefix("IQ").or_else(|| u.strip_prefix('Q')) else {
        return false;
    };
    let mut parts = rest.split('_');
    matches!(parts.next(), Some(d) if d.len() == 1 && d.bytes().all(|c| c.is_ascii_digit()))
        && parts.all(|p| !p.is_empty() && p.bytes().all(|c| c.is_ascii_alphanumeric()))
}

#[cfg(test)]
mod tests {
    #[test]
    fn empty_query_lists_trending() {
        let url = search_url("https://hf.test", "  ").unwrap();
        let q: Vec<(String, String)> = url.query_pairs().into_owned().collect();
        assert!(q.contains(&("sort".into(), "trendingScore".into())));
        assert!(!q.iter().any(|(k, _)| k == "search"));
        let url = search_url("https://hf.test", "qwen").unwrap();
        let q: Vec<(String, String)> = url.query_pairs().into_owned().collect();
        assert!(q.contains(&("sort".into(), "downloads".into())) && q.contains(&("search".into(), "qwen".into())));
    }

    use super::*;

    fn f(path: &str, size: u64) -> HfFile {
        HfFile { path: path.to_owned(), size, sha256: None }
    }

    fn version<'a>(versions: &'a [HfVersion], label: &str) -> &'a HfVersion {
        versions.iter().find(|v| v.label == label).expect("version present")
    }

    #[test]
    fn input_parsing() {
        assert_eq!(hf_repo_from_input("Qwen/Qwen3-8B".into()), Some("Qwen/Qwen3-8B".into()));
        assert_eq!(
            hf_repo_from_input("https://huggingface.co/Qwen/Qwen3-8B/tree/main".into()),
            Some("Qwen/Qwen3-8B".into())
        );
        assert_eq!(hf_repo_from_input("hf.co/Qwen/Qwen3-8B".into()), Some("Qwen/Qwen3-8B".into()));
        assert_eq!(hf_repo_from_input("qwen 8b".into()), None);
        assert_eq!(hf_repo_from_input("qwen".into()), None);
    }

    #[test]
    fn quant_labels() {
        let label = |name: &str| version_label(&format!("x/{name}"));
        assert_eq!(label("x-Q4_K_M.gguf"), "Q4_K_M");
        assert_eq!(label("x-q4_k_m-00001-of-00002.gguf"), "Q4_K_M");
        assert_eq!(label("x-IQ4_XS.gguf"), "IQ4_XS");
        assert_eq!(label("x-Q8_0.gguf"), "Q8_0");
        assert_eq!(label("x-f16.gguf"), "F16");
        assert_eq!(label("x-BF16.gguf"), "BF16");
    }

    fn version_label(path: &str) -> String {
        hf_versions(vec![f(path, 1)]).remove(0).label
    }

    #[test]
    fn split_set_is_one_version() {
        let versions = hf_versions(vec![
            f("m-Q5_K_M-00001-of-00002.gguf", 100),
            f("m-Q5_K_M-00002-of-00002.gguf", 50),
        ]);
        assert_eq!(versions.len(), 1);
        assert_eq!(versions[0].files, vec!["m-Q5_K_M-00001-of-00002.gguf", "m-Q5_K_M-00002-of-00002.gguf"]);
        assert_eq!(versions[0].size, 150);
    }

    #[test]
    fn merged_beats_split() {
        let versions = hf_versions(vec![
            f("qwen2.5-coder-7b-instruct-q4_k_m.gguf", 4_700),
            f("qwen2.5-coder-7b-instruct-q4_k_m-00001-of-00002.gguf", 2_500),
            f("qwen2.5-coder-7b-instruct-q4_k_m-00002-of-00002.gguf", 2_200),
            f("qwen2.5-coder-7b-instruct-fp16-00001-of-00004.gguf", 5_000),
            f("qwen2.5-coder-7b-instruct-fp16-00002-of-00004.gguf", 5_000),
            f("qwen2.5-coder-7b-instruct-fp16-00003-of-00004.gguf", 5_000),
            f("qwen2.5-coder-7b-instruct-fp16-00004-of-00004.gguf", 5_000),
        ]);
        assert_eq!(version(&versions, "Q4_K_M").files, vec!["qwen2.5-coder-7b-instruct-q4_k_m.gguf"]);
    }

    #[test]
    fn mmproj_attached() {
        let versions = hf_versions(vec![
            f("x-Q4_K_M.gguf", 4_000_000_000),
            f("x-Q8_0.gguf", 8_000_000_000),
            f("mmproj-x-F16.gguf", 888_000_000),
            f("mmproj-x-Q8_0.gguf", 500_000_000),
        ]);
        assert_eq!(versions.len(), 2);
        for v in &versions {
            assert!(v.files.contains(&"mmproj-x-Q8_0.gguf".to_owned()));
            assert!(!v.files.contains(&"mmproj-x-F16.gguf".to_owned()));
        }
        assert_eq!(version(&versions, "Q4_K_M").size, 4_500_000_000);
    }

    #[test]
    fn recommended_q4_k_m() {
        let versions = hf_versions(vec![
            f("x-Q2_K.gguf", 1),
            f("x-Q4_K_M.gguf", 4),
            f("x-Q8_0.gguf", 8),
        ]);
        let rec: Vec<&str> = versions.iter().filter(|v| v.recommended).map(|v| v.label.as_str()).collect();
        assert_eq!(rec, vec!["Q4_K_M"]);
    }

    #[test]
    fn recommended_order_then_smallest() {
        let picked = |names: &[(&str, u64)]| {
            let files = names.iter().map(|(p, s)| f(p, *s)).collect();
            hf_versions(files).into_iter().find(|v| v.recommended).unwrap().label
        };
        assert_eq!(picked(&[("x-Q8_0.gguf", 8), ("x-IQ4_XS.gguf", 3), ("x-Q5_K_M.gguf", 5)]), "IQ4_XS");
        assert_eq!(picked(&[("x-Q2_K.gguf", 2), ("x-Q9_0.gguf", 3)]), "Q2_K");
    }

    #[test]
    fn recommended_closest_smaller_quant() {
        let versions = hf_versions(vec![f("x-Q5_K_M.gguf", 5), f("x-Q4_0.gguf", 4), f("x-Q8_0.gguf", 8)]);
        assert_eq!(versions.iter().find(|v| v.recommended).unwrap().label, "Q4_0");
    }

    #[test]
    fn underscore_quant_names() {
        let label = |name: &str| version_label(&format!("x/{name}"));
        assert_eq!(label("model_Q4_K_M.gguf"), "Q4_K_M");
        assert_eq!(label("Model-7B_q5_k_s.gguf"), "Q5_K_S");
    }

    #[test]
    fn one_pytorch_extension() {
        assert_eq!(hf_recommended(vec![f("model.pt", 1), f("model.ckpt", 1)]), vec!["model.pt"]);
        assert_eq!(hf_recommended(vec![f("model.pt", 1), f("model.ckpt", 5)]), vec!["model.ckpt"]);
    }

    #[test]
    fn sharded_safetensors_with_index() {
        let files = vec![
            f("model-00001-of-00002.safetensors", 1),
            f("model-00002-of-00002.safetensors", 1),
            f("consolidated.safetensors", 1),
            f("model.safetensors.index.json", 1),
        ];
        let mut got = hf_recommended(files);
        got.sort();
        assert_eq!(
            got,
            vec!["model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors", "model.safetensors.index.json"]
        );
    }

    #[test]
    fn nonsharded_safetensors_without_index() {
        let files = vec![f("model.safetensors", 1), f("consolidated.safetensors", 1)];
        let mut got = hf_recommended(files);
        got.sort();
        assert_eq!(got, vec!["consolidated.safetensors", "model.safetensors"]);
    }

    #[test]
    fn target_rejects_unclean_paths() {
        let dir = Path::new("/d");
        for bad in ["a/", "a//b", "a/./b", "./a", "/a"] {
            assert_eq!(hf_target(dir, bad), None, "{bad:?}");
        }
        assert_eq!(hf_target(dir, "a/b.bin"), Some((PathBuf::from("/d/a"), "b.bin".into())));
    }

    #[test]
    fn input_trailing_slash_and_www() {
        assert_eq!(hf_repo_from_input("Qwen/Qwen3-8B/".into()), Some("Qwen/Qwen3-8B".into()));
        assert_eq!(hf_repo_from_input("https://huggingface.co/Qwen/Qwen3-8B/".into()), Some("Qwen/Qwen3-8B".into()));
        assert_eq!(hf_repo_from_input("www.huggingface.co/Qwen/Qwen3-8B".into()), Some("Qwen/Qwen3-8B".into()));
        assert_eq!(hf_repo_from_input("https://www.huggingface.co/Qwen/Qwen3-8B".into()), Some("Qwen/Qwen3-8B".into()));
    }

    #[test]
    fn recommended_gguf_paths() {
        let files = vec![
            f("README.md", 1),
            f(".gitattributes", 1),
            f("x-Q4_K_M.gguf", 4),
            f("x-Q8_0.gguf", 8),
        ];
        let versions = hf_versions(files.clone());
        let expected = versions.iter().find(|v| v.recommended).unwrap().files.clone();
        assert_eq!(hf_recommended(files), expected);
        assert_eq!(expected, vec!["x-Q4_K_M.gguf"]);
    }

    #[test]
    fn recommended_safetensors() {
        let names = [
            "config.json",
            "generation_config.json",
            "tokenizer.json",
            "tokenizer_config.json",
            "tokenizer.model",
            "merges.txt",
            "model-00001-of-00002.safetensors",
            "model-00002-of-00002.safetensors",
            "model.safetensors.index.json",
            "pytorch_model.bin",
            "onnx/model.onnx",
            "original/consolidated.00.pth",
            "README.md",
            "LICENSE",
            ".gitattributes",
        ];
        let files: Vec<HfFile> = names.iter().map(|n| f(n, 1)).collect();
        assert_eq!(hf_recommended(files), names[..9].to_vec());
    }

    #[test]
    fn recommended_bin_when_no_safetensors() {
        let files = vec![f("config.json", 1), f("pytorch_model.bin", 1), f("README.md", 1)];
        assert_eq!(hf_recommended(files), vec!["config.json", "pytorch_model.bin"]);
    }

    #[test]
    fn mmproj_anywhere_in_name() {
        let versions = hf_versions(vec![
            f("model-Q4_K_M.gguf", 4_000),
            f("gemma-3-4b-it-mmproj-F16.gguf", 800),
        ]);
        assert_eq!(versions.len(), 1);
        assert_eq!(versions[0].label, "Q4_K_M");
        assert_eq!(versions[0].files, vec!["model-Q4_K_M.gguf", "gemma-3-4b-it-mmproj-F16.gguf"]);
        assert_eq!(versions[0].size, 4_800);
    }

    #[test]
    fn one_weight_format_only() {
        let files = vec![
            f("pytorch_model.bin", 1),
            f("tf_model.h5", 1),
            f("flax_model.msgpack", 1),
            f("training_args.bin", 1),
            f("config.json", 1),
        ];
        let mut got = hf_recommended(files);
        got.sort();
        assert_eq!(got, vec!["config.json", "pytorch_model.bin"]);
    }

    #[test]
    fn training_artifacts_excluded() {
        let files = vec![
            f("pytorch_model.bin", 1),
            f("optimizer.pt", 1),
            f("scheduler.pt", 1),
            f("rng_state_0.pth", 1),
        ];
        assert_eq!(hf_recommended(files), vec!["pytorch_model.bin"]);
    }

    #[test]
    fn safetensors_skips_bin_index() {
        let files = vec![
            f("model.safetensors", 1),
            f("pytorch_model.bin.index.json", 1),
            f("model.safetensors.index.json", 1),
        ];
        assert_eq!(hf_recommended(files), vec!["model.safetensors", "model.safetensors.index.json"]);
    }

    #[test]
    fn tokenizer_files_included() {
        let files = vec![
            f("config.json", 1),
            f("vocab.json", 1),
            f("merges.txt", 1),
            f("special_tokens_map.json", 1),
            f("model.safetensors", 1),
        ];
        assert_eq!(
            hf_recommended(files),
            vec!["config.json", "vocab.json", "merges.txt", "special_tokens_map.json", "model.safetensors"]
        );
    }

    #[test]
    fn non_model_urls_rejected() {
        assert_eq!(hf_repo_from_input("https://huggingface.co/datasets/org/repo".into()), None);
        assert_eq!(hf_repo_from_input("https://huggingface.co/spaces/org/repo".into()), None);
    }

    #[test]
    fn query_and_fragment_cut() {
        assert_eq!(
            hf_repo_from_input("https://huggingface.co/Qwen/Qwen3-8B?library=gguf".into()),
            Some("Qwen/Qwen3-8B".into())
        );
        assert_eq!(hf_repo_from_input("Qwen/Qwen3-8B#readme".into()), Some("Qwen/Qwen3-8B".into()));
    }
}
