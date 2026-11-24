//! Hugging Face repo input parsing and file grouping. Pure logic; the HTTP client lives elsewhere.
use std::collections::BTreeMap;

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct HfFile {
    pub path: String,
    pub size: u64,
    pub sha256: Option<String>,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct HfVersion {
    pub label: String,
    pub files: Vec<String>,
    /// Includes the attached mmproj.
    pub size: u64,
    pub recommended: bool,
}

const PREFERRED: [&str; 9] = ["Q4_K_M", "Q4_K_S", "Q5_K_M", "Q4_0", "Q5_K_S", "Q5_0", "Q6_K", "Q8_0", "IQ4_XS"];
const WEIGHT_EXTS: [&str; 8] = ["safetensors", "bin", "pt", "pth", "ckpt", "onnx", "msgpack", "h5"];
const SKIPPED_DIRS: [&str; 4] = ["onnx/", "coreml/", "openvino/", "original/"];

#[uniffi::export]
pub fn hf_repo_from_input(input: String) -> Option<String> {
    let input = input.trim();
    if input.chars().any(char::is_whitespace) {
        return None;
    }
    let prefixes = [
        "https://huggingface.co/",
        "http://huggingface.co/",
        "https://hf.co/",
        "http://hf.co/",
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
    if org.is_empty() || repo.is_empty() || (!from_url && segs.next().is_some()) {
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
        if basename(&f.path).to_ascii_lowercase().starts_with("mmproj") {
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

/// Non-GGUF repos: root configs plus weights. Safetensors win over other weight formats, and
/// subfolder weights (onnx/, original/, ...) count only when no other weights exist.
fn default_checkpoint(files: &[HfFile]) -> Vec<String> {
    let primary = |f: &HfFile| ext_is(&f.path, &WEIGHT_EXTS) && !SKIPPED_DIRS.iter().any(|d| f.path.starts_with(d));
    let any_primary = files.iter().any(primary);
    let in_pool = |f: &HfFile| ext_is(&f.path, &WEIGHT_EXTS) && (!any_primary || primary(f));
    let any_safetensors = files.iter().any(|f| in_pool(f) && ext_is(&f.path, &["safetensors"]));
    files
        .iter()
        .filter(|f| {
            is_config(&f.path) || (in_pool(f) && (!any_safetensors || ext_is(&f.path, &["safetensors"])))
        })
        .map(|f| f.path.clone())
        .collect()
}

fn is_config(path: &str) -> bool {
    if path.contains('/') {
        return false;
    }
    let n = path.to_ascii_lowercase();
    n.starts_with("tokenizer")
        || n == "merges.txt"
        || n == "vocab.txt"
        || (n.ends_with(".json") && (n.contains("config") || n.ends_with(".index.json")))
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

/// Last `-` or `.` token that is a quant label, uppercased; FP16 is reported as F16.
fn quant_label(stem: &str) -> Option<String> {
    stem.split(['-', '.']).rev().find_map(|t| {
        let u = t.to_ascii_uppercase();
        is_quant(&u).then(|| if u == "FP16" { "F16".to_owned() } else { u })
    })
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
        assert_eq!(picked(&[("x-Q8_0.gguf", 8), ("x-IQ4_XS.gguf", 3), ("x-Q5_K_M.gguf", 5)]), "Q5_K_M");
        assert_eq!(picked(&[("x-Q2_K.gguf", 2), ("x-Q3_K_M.gguf", 3)]), "Q2_K");
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
}
