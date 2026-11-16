//! Pure file-naming rules. See design doc "Naming and safety rules".
use std::path::{Path, PathBuf};

/// File name from a `Content-Disposition` header. Prefers RFC 5987 `filename*=UTF-8''<pct-encoded>`,
/// falls back to `filename="..."` / `filename=...`. Result is passed through `sanitize`; None if empty.
pub fn from_disposition(header: &str) -> Option<String> {
    let params = disposition_params(header);
    let find = |key: &str| params.iter().find(|(n, _)| n == key).map(|(_, v)| v.as_str());
    let name = find("filename*")
        .and_then(decode_ext_value)
        .filter(|s| !s.trim().is_empty())
        .or_else(|| find("filename").map(str::to_owned).filter(|s| !s.trim().is_empty()))?;
    Some(sanitize(&name))
}

/// Last path segment after the host, percent-decoded, without query/fragment; `download` if empty.
/// Result is passed through `sanitize`.
pub fn from_url(url: &str) -> String {
    let Ok(parsed) = reqwest::Url::parse(url) else {
        return "download".to_owned();
    };
    match parsed.path_segments().and_then(|mut s| s.next_back()).filter(|s| !s.is_empty()) {
        Some(seg) => sanitize(&pct_decode(seg)),
        None => "download".to_owned(),
    }
}

/// Final component only; removes `/`, `\`, `:` and control chars; `.`/`..`/empty become `download`;
/// trimmed to at most 255 bytes on a char boundary.
pub fn sanitize(name: &str) -> String {
    let base = name.rsplit(['/', '\\']).next().unwrap_or("");
    let cleaned: String = base.chars().filter(|c| *c != ':' && !c.is_control()).collect();
    let trimmed = cleaned.trim();
    if trimmed.chars().all(|c| c == '.') {
        return "download".to_owned();
    }
    let mut end = trimmed.len().min(255);
    while !trimmed.is_char_boundary(end) {
        end -= 1;
    }
    trimmed[..end].to_owned()
}

/// `<dir>/<name>.<id>.part`
pub fn part_path(dir: &Path, name: &str, id: u64) -> PathBuf {
    dir.join(format!("{name}.{id}.part"))
}

/// First path that does not exist: `name.ext`, `name (1).ext`, `name (2).ext`, ...
pub fn unique_final(dir: &Path, name: &str) -> PathBuf {
    let first = dir.join(name);
    if !is_taken(&first) {
        return first;
    }
    let (stem, ext) = match name.rfind('.') {
        Some(i) if i > 0 && i + 1 < name.len() => (&name[..i], Some(&name[i + 1..])),
        _ => (name, None),
    };
    (1u64..)
        .map(|n| match ext {
            Some(e) => dir.join(format!("{stem} ({n}).{e}")),
            None => dir.join(format!("{stem} ({n})")),
        })
        .find(|p| !is_taken(p))
        .unwrap_or(first)
}

// symlink_metadata also sees dangling symlinks, so rename cannot land on them.
fn is_taken(p: &Path) -> bool {
    std::fs::symlink_metadata(p).is_ok()
}

/// Splits `name=value` pairs. Names are lowercased; quoted values unescape `\x` to `x`.
fn disposition_params(header: &str) -> Vec<(String, String)> {
    let mut out = Vec::new();
    let Some((_, mut rest)) = header.split_once(';') else {
        return out;
    };
    loop {
        let s = rest.trim_start();
        let Some(eq) = s.find(['=', ';']) else {
            break;
        };
        if s.as_bytes()[eq] == b';' {
            rest = &s[eq + 1..];
            continue;
        }
        let name = s[..eq].trim().to_ascii_lowercase();
        let after = s[eq + 1..].trim_start();
        let (value, tail) = match after.strip_prefix('"') {
            Some(q) => {
                let mut val = String::new();
                let mut chars = q.char_indices();
                let mut close = q.len();
                while let Some((i, c)) = chars.next() {
                    match c {
                        '\\' => {
                            if let Some((_, n)) = chars.next() {
                                val.push(n);
                            }
                        }
                        '"' => {
                            close = i + 1;
                            break;
                        }
                        _ => val.push(c),
                    }
                }
                (val, &q[close..])
            }
            None => {
                let end = after.find(';').unwrap_or(after.len());
                (after[..end].trim().to_owned(), &after[end..])
            }
        };
        out.push((name, value));
        match tail.find(';') {
            Some(i) => rest = &tail[i + 1..],
            None => break,
        }
    }
    out
}

/// `charset'lang'pct-encoded`. Unknown charsets return None so the caller can fall back.
fn decode_ext_value(v: &str) -> Option<String> {
    let mut parts = v.splitn(3, '\'');
    let charset = parts.next()?.trim().to_ascii_lowercase();
    let _lang = parts.next()?;
    let bytes = pct_bytes(parts.next()?);
    match charset.as_str() {
        "utf-8" | "utf8" => Some(String::from_utf8_lossy(&bytes).into_owned()),
        "iso-8859-1" | "iso8859-1" | "latin1" => Some(bytes.iter().map(|&b| b as char).collect()),
        _ => None,
    }
}

fn pct_decode(s: &str) -> String {
    String::from_utf8_lossy(&pct_bytes(s)).into_owned()
}

// Invalid `%` escapes are kept as literal bytes.
fn pct_bytes(s: &str) -> Vec<u8> {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        let hex = (i + 2 < b.len() && b[i] == b'%')
            .then(|| ((b[i + 1] as char).to_digit(16), (b[i + 2] as char).to_digit(16)));
        if let Some((Some(h), Some(l))) = hex {
            out.push((h * 16 + l) as u8);
            i += 3;
            continue;
        }
        out.push(b[i]);
        i += 1;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn traversal_is_stripped() {
        assert_eq!(sanitize("../../evil.sh"), "evil.sh");
        assert_eq!(sanitize(r"C:\temp\..\evil.sh"), "evil.sh");
        assert_eq!(from_disposition(r#"attachment; filename="../../evil.sh""#).as_deref(), Some("evil.sh"));
    }

    #[test]
    fn dot_and_empty_names_become_download() {
        for n in [".", "..", "", "   ", "../", "...", "a/.."] {
            assert_eq!(sanitize(n), "download", "input {n:?}");
        }
    }

    #[test]
    fn control_and_colon_removed() {
        assert_eq!(sanitize("a:b\nc\x07.txt"), "abc.txt");
    }

    #[test]
    fn rfc5987_utf8() {
        assert_eq!(
            from_disposition("attachment; filename*=UTF-8''%E2%82%AC%20rates.pdf").as_deref(),
            Some("€ rates.pdf")
        );
    }

    #[test]
    fn rfc5987_iso_8859_1() {
        assert_eq!(from_disposition("attachment; filename*=iso-8859-1'en'caf%E9.txt").as_deref(), Some("café.txt"));
    }

    #[test]
    fn invalid_percent_kept() {
        assert_eq!(from_disposition("attachment; filename*=UTF-8''100%25%zz.txt").as_deref(), Some("100%%zz.txt"));
    }

    #[test]
    fn filename_star_wins_in_either_order() {
        let a = r#"attachment; filename="plain.pdf"; filename*=UTF-8''%E2%82%AC.pdf"#;
        let b = "attachment; filename*=UTF-8''%E2%82%AC.pdf; filename=\"plain.pdf\"";
        assert_eq!(from_disposition(a).as_deref(), Some("€.pdf"));
        assert_eq!(from_disposition(b).as_deref(), Some("€.pdf"));
    }

    #[test]
    fn param_names_case_insensitive() {
        assert_eq!(from_disposition(r#"ATTACHMENT; FILENAME="a.txt""#).as_deref(), Some("a.txt"));
    }

    #[test]
    fn quoted_escapes_and_semicolons() {
        assert_eq!(from_disposition(r#"attachment; filename="a \"b\".pdf""#).as_deref(), Some(r#"a "b".pdf"#));
        assert_eq!(from_disposition(r#"attachment; filename="x;y.txt"; size=3"#).as_deref(), Some("x;y.txt"));
    }

    #[test]
    fn unquoted_ends_at_semicolon() {
        assert_eq!(from_disposition("inline; filename=report.csv ; x=1").as_deref(), Some("report.csv"));
    }

    #[test]
    fn no_filename_is_none() {
        assert_eq!(from_disposition("attachment"), None);
        assert_eq!(from_disposition(r#"attachment; filename="""#), None);
        assert_eq!(from_disposition("attachment; filename*=bogus'x'a.txt"), None);
    }

    #[test]
    fn url_bare_host_is_download() {
        assert_eq!(from_url("https://x.com/"), "download");
        assert_eq!(from_url("https://x.com"), "download");
        assert_eq!(from_url("https://x.com/a/"), "download");
        assert_eq!(from_url("not a url"), "download");
    }

    #[test]
    fn url_last_segment_decoded_without_query() {
        assert_eq!(from_url("https://x.com/a/b%20c.zip?sig=1#f"), "b c.zip");
        assert_eq!(from_url("https://x.com/a/..%2F..%2Fevil.sh"), "evil.sh");
    }

    #[test]
    fn long_multibyte_name_trimmed_on_boundary() {
        let long = "é".repeat(150); // 300 bytes
        let out = sanitize(&long);
        assert!(out.len() <= 255);
        assert_eq!(out.len(), 254);
        assert!(long.starts_with(&out));
    }

    #[test]
    fn part_path_suffix() {
        let dir = Path::new("/d");
        assert_eq!(part_path(dir, "x.bin", 7), dir.join("x.bin.7.part"));
    }

    #[test]
    fn unique_final_avoids_collisions() {
        let dir = tempfile::tempdir().unwrap();
        let d = dir.path();
        assert_eq!(unique_final(d, "a.zip"), d.join("a.zip"));
        std::fs::write(d.join("a.zip"), b"").unwrap();
        assert_eq!(unique_final(d, "a.zip"), d.join("a (1).zip"));
        std::fs::write(d.join("a (1).zip"), b"").unwrap();
        assert_eq!(unique_final(d, "a.zip"), d.join("a (2).zip"));
    }

    #[test]
    fn unique_final_splits_on_last_dot() {
        let dir = tempfile::tempdir().unwrap();
        let d = dir.path();
        std::fs::write(d.join("a.tar.gz"), b"").unwrap();
        assert_eq!(unique_final(d, "a.tar.gz"), d.join("a.tar (1).gz"));
        std::fs::write(d.join("README"), b"").unwrap();
        assert_eq!(unique_final(d, "README"), d.join("README (1)"));
        std::fs::write(d.join(".rc"), b"").unwrap();
        assert_eq!(unique_final(d, ".rc"), d.join(".rc (1)"));
    }
}
