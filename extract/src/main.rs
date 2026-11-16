//! Prints the text of a document to stdout, for feeding into LLM prompts.
//! Usage: extract <file> [--max N]   (default N = 2000 characters)
//! Supports pdf, xlsx/xlsm/xls/ods, docx, pptx, odt/odp, epub, zip/jar (file listing). Exit 2 = unsupported, 1 = failed.
use quick_xml::Reader;
use quick_xml::events::Event;
use std::fs::File;
use std::io::Read;
use std::path::Path;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let Some(path) = args.get(1) else {
        eprintln!("usage: extract <file> [--max N]");
        std::process::exit(2);
    };
    let max = args.iter().position(|a| a == "--max")
        .and_then(|i| args.get(i + 1)).and_then(|n| n.parse().ok()).unwrap_or(2000usize);
    let p = Path::new(path);
    let ext = p.extension().and_then(|e| e.to_str()).unwrap_or("").to_lowercase();

    // pdf-extract panics on some malformed PDFs; treat that as a normal failure.
    let result = std::panic::catch_unwind(|| extract(p, &ext));
    match result {
        Ok(Ok(Some(text))) => {
            if std::env::var("EXTRACT_RAW").is_ok() { print!("{:?}", text.chars().take(max).collect::<String>()); return; }
            let text = join_spaced_letters(&text).split_whitespace().collect::<Vec<_>>().join(" ");
            print!("{}", text.chars().take(max).collect::<String>());
        }
        Ok(Ok(None)) => std::process::exit(2),
        Ok(Err(e)) => { eprintln!("extract: {e}"); std::process::exit(1) }
        Err(_) => { eprintln!("extract: parser panicked"); std::process::exit(1) }
    }
}

fn extract(p: &Path, ext: &str) -> Result<Option<String>, String> {
    let s = |e: &dyn std::fmt::Display| e.to_string();
    Ok(Some(match ext {
        "pdf" => pdf_extract::extract_text(p).map_err(|e| s(&e))?,
        "xlsx" | "xlsm" | "xls" | "xlsb" | "ods" => spreadsheet(p)?,
        "docx" => zip_xml(p, |n| n == "word/document.xml", &["w:p"])?,
        "pptx" => zip_xml(p, |n| n.starts_with("ppt/slides/slide") && n.ends_with(".xml"), &["a:p"])?,
        "odt" | "odp" => zip_xml(p, |n| n == "content.xml", &["text:p", "text:h"])?,
        "epub" => zip_xml(p, |n| n.ends_with(".xhtml") || n.ends_with(".html"), &["p", "h1", "h2", "h3", "div"])?,
        "zip" | "jar" => zip_listing(p)?,
        _ => return Ok(None),
    }))
}

/// Each sheet as "## name" then tab-separated rows, so headers come first.
fn spreadsheet(p: &Path) -> Result<String, String> {
    use calamine::{Reader as _, open_workbook_auto};
    let mut wb = open_workbook_auto(p).map_err(|e| e.to_string())?;
    let mut out = String::new();
    for name in wb.sheet_names().to_owned() {
        let Ok(range) = wb.worksheet_range(&name) else { continue };
        out += &format!("## {name}\n");
        for row in range.rows().take(30) {
            out += &row.iter().map(|c| c.to_string()).collect::<Vec<_>>().join("\t");
            out.push('\n');
        }
    }
    Ok(out)
}

fn open_zip(p: &Path) -> Result<zip::ZipArchive<File>, String> {
    zip::ZipArchive::new(File::open(p).map_err(|e| e.to_string())?).map_err(|e| e.to_string())
}

fn zip_listing(p: &Path) -> Result<String, String> {
    Ok(names(&open_zip(p)?).into_iter().filter(|n| !n.starts_with("__MACOSX")).collect::<Vec<_>>().join("\n"))
}

fn names(z: &zip::ZipArchive<File>) -> Vec<String> {
    z.file_names().flatten().map(String::from).collect()
}

/// Concatenates text nodes of the matching XML members, with a newline after each paragraph tag.
fn zip_xml(p: &Path, want: impl Fn(&str) -> bool, para_tags: &[&str]) -> Result<String, String> {
    let mut z = open_zip(p)?;
    let mut members: Vec<String> = names(&z).into_iter().filter(|n| want(n)).collect();
    members.sort_by_key(|n| (n.len(), n.clone())); // slide2 before slide10
    let mut out = String::new();
    for name in members {
        let mut xml = String::new();
        z.by_name(&name).map_err(|e| e.to_string())?.read_to_string(&mut xml).map_err(|e| e.to_string())?;
        let mut r = Reader::from_str(&xml);
        loop {
            match r.read_event() {
                Ok(Event::Text(t)) => {
                    out += t.as_ref();
                }
                Ok(Event::End(e)) if para_tags.iter().any(|t| e.name().as_ref() == *t) => out.push('\n'),
                Ok(Event::Eof) | Err(_) => break,
                _ => {}
            }
        }
        if out.len() > 20_000 { break; }
    }
    Ok(out)
}

/// PDFs with letter-spaced headings extract as "T I F F I N   G R A B" (1 space between letters, 3+ between words).
/// Within each 2+-space-separated chunk, a chunk made only of 2+ single characters is joined back into a word.
fn join_spaced_letters(text: &str) -> String {
    text.lines().map(|line| {
        line.split("  ").filter(|c| !c.trim().is_empty()).map(|chunk| {
            let toks: Vec<&str> = chunk.trim().split(' ').collect();
            if toks.len() >= 2 && toks.iter().all(|t| t.chars().count() == 1) { toks.concat() } else { chunk.trim().to_string() }
        }).collect::<Vec<_>>().join(" ")
    }).collect::<Vec<_>>().join("\n")
}

#[cfg(test)]
mod tests {
    #[test]
    fn joins_letter_spacing() {
        assert_eq!(super::join_spaced_letters("T I F F I N G R A B   —   B A G   D E S I G N   ·   2 5 0   ×   3 0 0   M M"), "TIFFINGRAB — BAG DESIGN · 250 × 300 MM");
        assert_eq!(super::join_spaced_letters("and a I x here"), "and a I x here");
    }
}
