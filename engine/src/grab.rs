//! Link grabber: fetches a web page and lists the links on it that point at downloadable files.
use crate::names;
use crate::types::EngineError;
use reqwest::Url;
use std::collections::HashSet;
use std::time::Duration;

const MAX_PAGE: usize = 5 * 1024 * 1024;
const TIMEOUT: Duration = Duration::from_secs(20);

const EXTENSIONS: &[&str] = &[
    "zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "xz", "zst", "dmg", "iso", "img", "pkg", "msi", "exe", "deb", "rpm", "apk", "appimage",
    "mp4", "mkv", "mov", "avi", "webm", "m4v", "flv", "wmv", "mp3", "m4a", "flac", "wav", "ogg", "opus", "aac",
    "jpg", "jpeg", "png", "gif", "webp", "heic", "tif", "tiff", "bmp", "svg", "raw",
    "pdf", "epub", "mobi", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "csv", "txt",
    "gguf", "safetensors", "ckpt", "pt", "pth", "onnx", "bin", "torrent",
];

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct GrabbedLink {
    pub url: String,
    pub name: String,
    /// Lowercase file extension, e.g. `zip`.
    pub kind: String,
}

pub async fn grab(client: &reqwest::Client, page_url: &str) -> Result<Vec<GrabbedLink>, EngineError> {
    let url = Url::parse(page_url.trim()).ok().filter(|u| matches!(u.scheme(), "http" | "https")).ok_or_else(|| EngineError::InvalidUrl { msg: "not an http or https link".into() })?;
    let io = |e: reqwest::Error| EngineError::Io { msg: e.to_string() };
    let mut resp = client.get(url).timeout(TIMEOUT).send().await.map_err(io)?;
    if !resp.status().is_success() {
        return Err(EngineError::Io { msg: format!("the page answered {}", resp.status()) });
    }
    let kind = resp.headers().get(reqwest::header::CONTENT_TYPE).and_then(|v| v.to_str().ok()).map(str::to_ascii_lowercase);
    if kind.is_some_and(|k| !(k.starts_with("text/html") || k.starts_with("application/xhtml"))) {
        return Err(EngineError::InvalidUrl { msg: "That link is a file, not a page".into() });
    }
    let mut base = resp.url().clone();
    let mut body = Vec::new();
    while body.len() < MAX_PAGE {
        match resp.chunk().await.map_err(io)? {
            Some(c) => body.extend_from_slice(&c),
            None => break,
        }
    }
    // shortcut: non-UTF-8 pages are read lossily, which only garbles non-ASCII text, not the links.
    let html = String::from_utf8_lossy(&body);
    let refs = scan(&html);
    if let Some(b) = refs.base.and_then(|b| base.join(&b).ok()) {
        base = b;
    }
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for r in refs.links {
        let Ok(mut u) = base.join(&r) else { continue };
        u.set_fragment(None);
        let name = names::from_url(u.as_str());
        let ext = name.rsplit_once('.').map(|(_, e)| e.to_ascii_lowercase()).unwrap_or_default();
        if matches!(u.scheme(), "http" | "https") && EXTENSIONS.contains(&ext.as_str()) && seen.insert(u.to_string()) {
            out.push(GrabbedLink { url: u.to_string(), name, kind: ext });
        }
    }
    Ok(out)
}

#[derive(Default)]
struct Refs {
    base: Option<String>,
    links: Vec<String>,
}

/// Pulls `<a href>`, `<base href>` and media `src` values out of tags; skips comments and script/style bodies.
fn scan(html: &str) -> Refs {
    let mut refs = Refs::default();
    let mut rest = html;
    let lower = html.to_ascii_lowercase();
    while let Some(i) = rest.find('<') {
        rest = &rest[i + 1..];
        if let Some(r) = rest.strip_prefix("!--") {
            rest = r.split_once("-->").map_or("", |(_, r)| r);
            continue;
        }
        let end = tag_end(rest);
        let (tag, after) = rest.split_at(end);
        rest = after.strip_prefix('>').unwrap_or(after);
        let name_len = tag.find(|c: char| !c.is_ascii_alphanumeric()).unwrap_or(tag.len());
        let name = tag[..name_len].to_ascii_lowercase();
        let attr = match name.as_str() {
            "a" | "base" | "area" => "href",
            "img" | "source" | "video" | "audio" | "embed" => "src",
            "script" | "style" => {
                let close = format!("</{name}");
                rest = lower[html.len() - rest.len()..].find(&close).map_or("", |p| &rest[p..]);
                continue;
            }
            _ => continue,
        };
        let Some(value) = attribute(&tag[name_len..], attr) else { continue };
        let value = value.replace("&amp;", "&");
        match name.as_str() {
            "base" => {
                refs.base.get_or_insert(value);
            }
            _ => refs.links.push(value),
        }
    }
    refs
}

/// Index of the `>` that closes the tag, ignoring any inside quotes.
fn tag_end(s: &str) -> usize {
    let mut quote = None;
    for (i, c) in s.char_indices() {
        match (quote, c) {
            (None, '>') => return i,
            (None, '"' | '\'') => quote = Some(c),
            (Some(q), c) if c == q => quote = None,
            _ => {}
        }
    }
    s.len()
}

fn attribute(attrs: &str, wanted: &str) -> Option<String> {
    let mut s = attrs.trim_start();
    while !s.is_empty() {
        let n = s.find(|c: char| c.is_whitespace() || c == '=' || c == '/').unwrap_or(s.len());
        let (key, after) = s.split_at(n);
        let after = after.trim_start();
        let Some(after) = after.strip_prefix('=') else {
            s = after.trim_start_matches('/').trim_start();
            continue;
        };
        let after = after.trim_start();
        let (value, rest) = match after.chars().next() {
            Some(q @ ('"' | '\'')) => after[1..].split_once(q).unwrap_or((&after[1..], "")),
            _ => after.split_at(after.find(char::is_whitespace).unwrap_or(after.len())),
        };
        if key.eq_ignore_ascii_case(wanted) {
            return Some(value.trim().to_owned());
        }
        s = rest.trim_start();
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scans_quoted_unquoted_and_skips_comments_and_scripts() {
        let r = scan(r#"<!-- <a href="no.zip"> --><A HREF='a.zip'>x</A><a class=c href=b.zip>y</a><script>"<a href='s.zip'>"</script><a href="c.zip?a=1&amp;b=2">z</a><base href="/d/">"#);
        assert_eq!(r.links, ["a.zip", "b.zip", "c.zip?a=1&b=2"]);
        assert_eq!(r.base.as_deref(), Some("/d/"));
    }
}
