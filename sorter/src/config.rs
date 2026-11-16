//! Destination overrides: a watched folder's categories can be filed into other folders (sorter.json).
use serde_json::{Value, json};
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

pub enum Edit {
    Add(String),
    Remove(String),
    SetDest { folder: String, category: String, dest: String },
    ClearDest { folder: String, category: String },
    SetWait(u64),
}

/// How long a watch run waits before sorting, so a new file has time to finish arriving.
pub const DEFAULT_WAIT_SECS: u64 = 10;
pub const MAX_WAIT_SECS: u64 = 3600;

pub fn wait_secs(doc: &Value) -> u64 {
    doc["wait_seconds"].as_u64().unwrap_or(DEFAULT_WAIT_SECS).min(MAX_WAIT_SECS)
}

/// A missing file means no overrides. An unreadable or invalid file is an error, so an edit never overwrites it.
pub fn load(path: &Path) -> Result<Value, String> {
    let text = match fs::read_to_string(path) {
        Ok(t) => t,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(json!({"folders": []})),
        Err(e) => return Err(format!("{}: {e}", path.display())),
    };
    let doc: Value = serde_json::from_str(&text).map_err(|e| format!("{}: {e}", path.display()))?;
    if !doc["folders"].is_array() {
        return Err(format!("{}: expected a \"folders\" array", path.display()));
    }
    Ok(doc)
}

/// Writes to a temp file first so a crash never leaves a half-written sorter.json.
pub fn save(path: &Path, doc: &Value) -> Result<(), String> {
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    let tmp = path.with_extension("json.tmp");
    let text = serde_json::to_string_pretty(doc).map_err(|e| e.to_string())?;
    fs::write(&tmp, text).map_err(|e| e.to_string())?;
    fs::rename(&tmp, path).map_err(|e| e.to_string())
}

fn find(folders: &[Value], path: &str) -> Option<usize> {
    folders.iter().position(|f| f["path"].as_str() == Some(path))
}

pub fn apply(doc: &mut Value, edit: &Edit) -> Result<(), String> {
    if let Edit::SetWait(secs) = edit {
        doc["wait_seconds"] = json!((*secs).min(MAX_WAIT_SECS));
        return Ok(());
    }
    let folders = doc["folders"].as_array_mut().ok_or("no folders array")?;
    match edit {
        Edit::Add(p) => {
            if find(folders, p).is_none() {
                folders.push(json!({"path": p, "destinations": {}}));
            }
        }
        Edit::Remove(p) => folders.retain(|f| f["path"].as_str() != Some(p.as_str())),
        Edit::SetDest { folder, category, dest } => {
            let i = match find(folders, folder) {
                Some(i) => i,
                None => {
                    folders.push(json!({"path": folder, "destinations": {}}));
                    folders.len() - 1
                }
            };
            let dests = &mut folders[i]["destinations"];
            if !dests.is_object() {
                *dests = json!({});
            }
            dests[category.as_str()] = json!(dest);
        }
        Edit::SetWait(_) => unreachable!("handled above"),
        Edit::ClearDest { folder, category } => {
            if let Some(i) = find(folders, folder)
                && let Some(dests) = folders[i]["destinations"].as_object_mut()
            {
                dests.remove(category.as_str());
            }
        }
    }
    Ok(())
}

pub fn edit_file(path: &Path, edit: &Edit) -> Result<(), String> {
    let mut doc = load(path)?;
    apply(&mut doc, edit)?;
    save(path, &doc)
}

/// Where each category of one watched folder lands. Categories without an override stay under the folder.
pub struct Layout {
    pub root: PathBuf,
    dests: HashMap<String, PathBuf>,
}

impl Layout {
    pub fn new(root: &Path, doc: &Value) -> Self {
        let root_key = root.to_string_lossy().into_owned();
        let dests = doc["folders"].as_array().into_iter().flatten()
            .find(|f| f["path"].as_str() == Some(root_key.as_str()))
            .and_then(|f| f["destinations"].as_object())
            .into_iter()
            .flatten()
            .filter_map(|(cat, dest)| {
                let dest = PathBuf::from(dest.as_str()?);
                // Duplicates always stays in the watched folder.
                (cat.as_str() != crate::ARCHIVE && dest.is_absolute()).then(|| (cat.clone(), dest))
            })
            .collect();
        Layout { root: root.to_path_buf(), dests }
    }

    pub fn cat_dir(&self, cat: &str) -> PathBuf {
        self.dests.get(cat).cloned().unwrap_or_else(|| self.root.join(cat))
    }

    pub fn is_external(&self, cat: &str) -> bool {
        self.dests.contains_key(cat)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("sorter-config-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn edits_round_trip_through_file() {
        let path = tmp("roundtrip").join("sorter.json");
        assert_eq!(load(&path).unwrap(), json!({"folders": []}));
        edit_file(&path, &Edit::Add("/a".into())).unwrap();
        edit_file(&path, &Edit::SetDest { folder: "/a".into(), category: "Work".into(), dest: "/b/Work".into() }).unwrap();
        edit_file(&path, &Edit::Add("/c".into())).unwrap();
        edit_file(&path, &Edit::Remove("/c".into())).unwrap();
        assert_eq!(load(&path).unwrap(), json!({"folders": [{"path": "/a", "destinations": {"Work": "/b/Work"}}]}));
        edit_file(&path, &Edit::ClearDest { folder: "/a".into(), category: "Work".into() }).unwrap();
        assert_eq!(load(&path).unwrap()["folders"][0]["destinations"], json!({}));
        assert!(!path.with_extension("json.tmp").exists());
    }

    #[test]
    fn invalid_file_is_reported_and_not_overwritten() {
        let path = tmp("invalid").join("sorter.json");
        fs::write(&path, "{not json").unwrap();
        assert!(edit_file(&path, &Edit::Add("/x".into())).is_err());
        assert_eq!(fs::read_to_string(&path).unwrap(), "{not json");
    }

    #[test]
    fn layout_maps_categories_to_destinations() {
        let doc = json!({"folders": [{"path": "/u/Downloads", "destinations": {
            "Work": "/u/Documents/Work", "Duplicates": "/nope", "Media": "relative"}}]});
        let l = Layout::new(Path::new("/u/Downloads"), &doc);
        assert_eq!(l.cat_dir("Work"), PathBuf::from("/u/Documents/Work"));
        assert!(l.is_external("Work"));
        assert_eq!(l.cat_dir("Images"), PathBuf::from("/u/Downloads/Images"));
        assert_eq!(l.cat_dir("Media"), PathBuf::from("/u/Downloads/Media"));
        assert!(!l.is_external("Duplicates"));
        let other = Layout::new(Path::new("/elsewhere"), &doc);
        assert_eq!(other.cat_dir("Work"), PathBuf::from("/elsewhere/Work"));
    }

    #[test]
    fn wait_defaults_round_trips_and_caps() {
        let mut doc = json!({"folders": []});
        assert_eq!(wait_secs(&doc), DEFAULT_WAIT_SECS);
        apply(&mut doc, &Edit::SetWait(300)).unwrap();
        assert_eq!(wait_secs(&doc), 300);
        apply(&mut doc, &Edit::SetWait(99_999)).unwrap();
        assert_eq!(wait_secs(&doc), MAX_WAIT_SECS);
        assert!(doc["folders"].is_array());
    }
}
