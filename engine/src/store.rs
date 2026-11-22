//! SQLite persistence (`<data_dir>/queue.db`, WAL). Uses the system libsqlite3.
use crate::s3::BucketConfig;
use crate::types::{EngineError, HostView, Job, JobId, JobState, Segment, now_secs};
use rusqlite::{Connection, OptionalExtension, Row, named_params, params};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard};

/// Connections per file for a server that never limited us: the most a split may use.
pub const MAX_PARTS: u32 = 16;
/// Remembered host limits expire after this many seconds.
const HOST_TTL_SECS: i64 = 7 * 24 * 3600;

/// Applied in order; entry `i` upgrades `user_version` from `i` to `i + 1`. Append only.
const MIGRATIONS: &[&str] = &[
    r#"
CREATE TABLE jobs(id INTEGER PRIMARY KEY, url TEXT NOT NULL, name TEXT NOT NULL,
     part_path TEXT NOT NULL, final_path TEXT, done INTEGER NOT NULL,
     total INTEGER, etag TEXT, last_modified TEXT, resumable INTEGER NOT NULL,
     state TEXT NOT NULL, error TEXT, position INTEGER NOT NULL,
     created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)
"#,
    "ALTER TABLE jobs ADD COLUMN segments TEXT NOT NULL DEFAULT '[]'",
    "CREATE TABLE hosts(host TEXT PRIMARY KEY, max_parts INTEGER NOT NULL, reason TEXT NOT NULL,
     updated_at INTEGER NOT NULL)",
    // The secret key is in the Keychain, never here.
    "CREATE TABLE buckets(name TEXT PRIMARY KEY, provider TEXT NOT NULL, endpoint TEXT NOT NULL,
     region TEXT NOT NULL, access_key_id TEXT NOT NULL, path_style INTEGER NOT NULL, created_at INTEGER NOT NULL)",
];

const COLUMNS: &str = "id, url, name, part_path, final_path, done, total, etag, last_modified, \
                       resumable, state, error, position, created_at, updated_at, segments";

pub struct Store {
    conn: Mutex<rusqlite::Connection>,
}

impl Store {
    /// Creates `data_dir` if missing, opens `queue.db`, sets WAL, runs migrations (PRAGMA user_version).
    pub fn open(data_dir: &Path) -> Result<Store, EngineError> {
        std::fs::create_dir_all(data_dir)?;
        let mut conn = Connection::open(data_dir.join("queue.db"))?;
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.pragma_update(None, "busy_timeout", 2000)?;
        let version: i64 = conn.pragma_query_value(None, "user_version", |r| r.get(0))?;
        for (i, sql) in MIGRATIONS.iter().enumerate().skip(version as usize) {
            let tx = conn.transaction()?;
            tx.execute_batch(sql)?;
            tx.pragma_update(None, "user_version", (i + 1) as i64)?;
            tx.commit()?;
        }
        Ok(Store { conn: Mutex::new(conn) })
    }

    /// All jobs ordered by `position`, reconciled with disk. Unfinished single-stream jobs take `done` from the
    /// `.part` length. Split jobs take the sum of their segments, since the file is preallocated. A missing
    /// `.part` sets `done = 0` and drops any segments. Running/Queued/Retrying become Paused.
    pub fn load_all(&self) -> Result<Vec<Job>, EngineError> {
        let conn = self.lock()?;
        let mut stmt = conn.prepare(&format!("SELECT {COLUMNS} FROM jobs ORDER BY position, id"))?;
        let mut jobs = stmt.query_map([], job_from_row)?.collect::<rusqlite::Result<Vec<Job>>>()?;
        for job in &mut jobs {
            if matches!(job.state, JobState::Done { .. } | JobState::Failed { .. }) {
                continue;
            }
            let part_len = match std::fs::metadata(&job.part_path) {
                Ok(meta) => Some(meta.len()),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
                Err(e) => return Err(e.into()),
            };
            job.done = match part_len {
                Some(_) if !job.segments.is_empty() => job.segments.iter().map(|s| s.done).sum(),
                Some(len) => len,
                None => {
                    job.segments.clear();
                    0
                }
            };
            job.state = JobState::Paused;
        }
        Ok(jobs)
    }

    /// Inserts `job` (its `id` is ignored), sets `job.id` to the new row id, returns it.
    pub fn insert(&self, job: &mut Job) -> Result<JobId, EngineError> {
        let now = now_secs();
        job.created_at = now;
        job.updated_at = now;
        let (state, error) = encode_state(&job.state);
        let final_path = final_path_column(job);
        let part_path = job.part_path.to_string_lossy().into_owned();
        let segments = encode_segments(&job.segments);
        let conn = self.lock()?;
        conn.execute(
            "INSERT INTO jobs (url, name, part_path, final_path, done, total, etag, last_modified, \
             resumable, state, error, position, created_at, updated_at, segments) \
             VALUES (:url, :name, :part_path, :final_path, :done, :total, :etag, :last_modified, \
             :resumable, :state, :error, :position, :created_at, :updated_at, :segments)",
            named_params! {
                ":url": job.url,
                ":name": job.name,
                ":part_path": part_path,
                ":final_path": final_path,
                ":done": job.done as i64,
                ":total": job.total.map(|t| t as i64),
                ":etag": job.etag,
                ":last_modified": job.last_modified,
                ":resumable": job.resumable,
                ":state": state,
                ":error": error,
                ":position": job.position,
                ":created_at": now,
                ":updated_at": now,
                ":segments": segments,
            },
        )?;
        job.id = conn.last_insert_rowid() as JobId;
        Ok(job.id)
    }

    /// Writes every column of `job` to its existing row and bumps `updated_at`.
    pub fn save(&self, job: &Job) -> Result<(), EngineError> {
        let (state, error) = encode_state(&job.state);
        let final_path = final_path_column(job);
        let part_path = job.part_path.to_string_lossy().into_owned();
        let segments = encode_segments(&job.segments);
        let conn = self.lock()?;
        conn.execute(
            "UPDATE jobs SET url = :url, name = :name, part_path = :part_path, final_path = :final_path, \
             done = :done, total = :total, etag = :etag, last_modified = :last_modified, \
             resumable = :resumable, state = :state, error = :error, position = :position, \
             segments = :segments, updated_at = :updated_at WHERE id = :id",
            named_params! {
                ":id": job.id as i64,
                ":url": job.url,
                ":name": job.name,
                ":part_path": part_path,
                ":final_path": final_path,
                ":done": job.done as i64,
                ":total": job.total.map(|t| t as i64),
                ":etag": job.etag,
                ":last_modified": job.last_modified,
                ":resumable": job.resumable,
                ":state": state,
                ":error": error,
                ":position": job.position,
                ":segments": segments,
                ":updated_at": now_secs(),
            },
        )?;
        Ok(())
    }

    pub fn delete(&self, id: JobId) -> Result<(), EngineError> {
        self.lock()?.execute("DELETE FROM jobs WHERE id = ?1", [id as i64])?;
        Ok(())
    }

    /// The remembered connection limit for `host`, ignoring rows older than the TTL.
    pub fn host_limit(&self, host: &str) -> Result<Option<(u32, String)>, EngineError> {
        let row = self
            .lock()?
            .query_row(
                "SELECT max_parts, reason FROM hosts WHERE host = ?1 AND updated_at >= ?2",
                params![host, now_secs() - HOST_TTL_SECS],
                |r| Ok((r.get::<_, i64>(0)? as u32, r.get(1)?)),
            )
            .optional()?;
        Ok(row)
    }

    /// Records a limit for `host`. An existing fresh limit is only ever lowered.
    pub fn note_host(&self, host: &str, max_parts: u32, reason: &str) -> Result<(), EngineError> {
        let now = now_secs();
        self.lock()?.execute(
            "INSERT INTO hosts (host, max_parts, reason, updated_at) VALUES (?1, ?2, ?3, ?4) \
             ON CONFLICT(host) DO UPDATE SET \
             max_parts = CASE WHEN updated_at < ?5 THEN excluded.max_parts ELSE MIN(max_parts, excluded.max_parts) END, \
             reason = excluded.reason, updated_at = excluded.updated_at",
            params![host, i64::from(max_parts), reason, now, now - HOST_TTL_SECS],
        )?;
        Ok(())
    }

    /// Raises a remembered limit by one connection; the row goes once it reaches `MAX_PARTS`.
    pub fn relax_host(&self, host: &str) -> Result<(), EngineError> {
        let conn = self.lock()?;
        conn.execute("UPDATE hosts SET max_parts = max_parts + 1 WHERE host = ?1", [host])?;
        conn.execute("DELETE FROM hosts WHERE host = ?1 AND max_parts >= ?2", params![host, i64::from(MAX_PARTS)])?;
        Ok(())
    }

    pub fn forget_host(&self, host: &str) -> Result<(), EngineError> {
        self.lock()?.execute("DELETE FROM hosts WHERE host = ?1", [host])?;
        Ok(())
    }

    /// Unexpired host limits, newest first.
    pub fn hosts(&self) -> Result<Vec<HostView>, EngineError> {
        let conn = self.lock()?;
        let mut stmt = conn.prepare(
            "SELECT host, max_parts, reason, updated_at FROM hosts WHERE updated_at >= ?1 ORDER BY updated_at DESC",
        )?;
        let rows = stmt
            .query_map([now_secs() - HOST_TTL_SECS], |r| {
                Ok(HostView {
                    host: r.get(0)?,
                    max_parts: r.get::<_, i64>(1)? as u32,
                    reason: r.get(2)?,
                    updated_at: r.get(3)?,
                })
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(rows)
    }

    /// Adds a bucket, or replaces the one with the same name.
    pub fn save_bucket(&self, b: &BucketConfig) -> Result<(), EngineError> {
        self.lock()?.execute(
            "INSERT INTO buckets (name, provider, endpoint, region, access_key_id, path_style, created_at) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7) ON CONFLICT(name) DO UPDATE SET provider = excluded.provider, \
             endpoint = excluded.endpoint, region = excluded.region, access_key_id = excluded.access_key_id, \
             path_style = excluded.path_style",
            params![b.name, b.provider, b.endpoint, b.region, b.access_key_id, b.path_style, now_secs()],
        )?;
        Ok(())
    }

    pub fn remove_bucket(&self, name: &str) -> Result<(), EngineError> {
        self.lock()?.execute("DELETE FROM buckets WHERE name = ?1", [name])?;
        Ok(())
    }

    /// Buckets in the order they were added.
    pub fn buckets(&self) -> Result<Vec<BucketConfig>, EngineError> {
        let conn = self.lock()?;
        let mut stmt = conn.prepare(
            "SELECT name, provider, endpoint, region, access_key_id, path_style FROM buckets ORDER BY created_at, name",
        )?;
        let rows = stmt
            .query_map([], |r| {
                Ok(BucketConfig {
                    name: r.get(0)?,
                    provider: r.get(1)?,
                    endpoint: r.get(2)?,
                    region: r.get(3)?,
                    access_key_id: r.get(4)?,
                    path_style: r.get(5)?,
                })
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(rows)
    }

    fn lock(&self) -> Result<MutexGuard<'_, Connection>, EngineError> {
        self.conn.lock().map_err(|_| EngineError::Db { msg: "connection mutex poisoned".into() })
    }
}

/// Returns the `state` column and the `error` column for `state`.
fn encode_state(state: &JobState) -> (&'static str, Option<&str>) {
    match state {
        JobState::Queued => ("queued", None),
        JobState::Running => ("running", None),
        JobState::Paused => ("paused", None),
        JobState::Retrying { .. } => ("retrying", None),
        JobState::Done { .. } => ("done", None),
        JobState::Failed { reason } => ("failed", Some(reason.as_str())),
    }
}

fn encode_segments(segments: &[Segment]) -> String {
    serde_json::to_string(segments).unwrap_or_else(|_| "[]".to_owned())
}

/// A finished job's path lives in `final_path`, so it always comes from the state.
fn final_path_column(job: &Job) -> Option<String> {
    match &job.state {
        JobState::Done { path } => Some(path.clone()),
        _ => job.final_path.as_ref().map(|p| p.to_string_lossy().into_owned()),
    }
}

fn job_from_row(row: &Row) -> rusqlite::Result<Job> {
    let state_name: String = row.get("state")?;
    let final_path: Option<String> = row.get("final_path")?;
    let error: Option<String> = row.get("error")?;
    let state = match state_name.as_str() {
        "queued" => JobState::Queued,
        "running" => JobState::Running,
        "paused" => JobState::Paused,
        // `attempt` is not persisted; reconciliation turns this into Paused anyway.
        "retrying" => JobState::Retrying { attempt: 0 },
        "done" => JobState::Done { path: final_path.clone().unwrap_or_default() },
        "failed" => JobState::Failed { reason: error.unwrap_or_default() },
        other => {
            let idx = row.as_ref().column_index("state")?;
            let msg = format!("unknown job state {other}");
            return Err(rusqlite::Error::FromSqlConversionFailure(idx, rusqlite::types::Type::Text, msg.into()));
        }
    };
    let segments_json: String = row.get("segments")?;
    let segments: Vec<Segment> = serde_json::from_str(&segments_json).map_err(|e| {
        let idx = row.as_ref().column_index("segments").unwrap_or(0);
        rusqlite::Error::FromSqlConversionFailure(idx, rusqlite::types::Type::Text, Box::new(e))
    })?;
    Ok(Job {
        id: row.get::<_, i64>("id")? as JobId,
        url: row.get("url")?,
        name: row.get("name")?,
        part_path: PathBuf::from(row.get::<_, String>("part_path")?),
        final_path: final_path.map(PathBuf::from),
        done: row.get::<_, i64>("done")? as u64,
        total: row.get::<_, Option<i64>>("total")?.map(|t| t as u64),
        etag: row.get("etag")?,
        last_modified: row.get("last_modified")?,
        resumable: row.get::<_, i64>("resumable")? != 0,
        state,
        segments,
        position: row.get("position")?,
        created_at: row.get("created_at")?,
        updated_at: row.get("updated_at")?,
    })
}

#[cfg(test)]
mod tests {
    #[test]
    fn buckets_save_replace_list_and_remove() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        let mut b = BucketConfig {
            name: "media".into(),
            provider: "r2".into(),
            endpoint: "https://x.r2.cloudflarestorage.com".into(),
            region: "auto".into(),
            access_key_id: "AKID".into(),
            path_style: true,
        };
        store.save_bucket(&b).unwrap();
        b.region = "weur".into();
        store.save_bucket(&b).unwrap();
        assert_eq!(store.buckets().unwrap(), vec![b]);
        store.remove_bucket("media").unwrap();
        assert!(store.buckets().unwrap().is_empty());
    }

    use super::*;

    fn sample(part: &Path, state: JobState) -> Job {
        Job {
            id: 0,
            url: "https://example.com/f.bin".into(),
            name: "f.bin".into(),
            part_path: part.to_path_buf(),
            final_path: None,
            done: 0,
            total: Some(100),
            etag: Some("\"abc\"".into()),
            last_modified: None,
            resumable: true,
            state,
            segments: Vec::new(),
            position: 0,
            created_at: 0,
            updated_at: 0,
        }
    }

    fn user_version(store: &Store) -> i64 {
        store.lock().unwrap().pragma_query_value(None, "user_version", |r| r.get(0)).unwrap()
    }

    #[test]
    fn open_twice_migrates_once_and_keeps_data() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        let mut job = sample(&dir.path().join("a.part"), JobState::Paused);
        store.insert(&mut job).unwrap();
        drop(store);

        let store = Store::open(dir.path()).unwrap();
        assert_eq!(user_version(&store), MIGRATIONS.len() as i64);
        let jobs = store.load_all().unwrap();
        assert_eq!(jobs.len(), 1);
        assert_eq!(jobs[0].url, "https://example.com/f.bin");
    }

    #[test]
    fn insert_returns_increasing_ids() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        let part = dir.path().join("x.part");
        let mut ids = Vec::new();
        for _ in 0..3 {
            let mut job = sample(&part, JobState::Queued);
            ids.push(store.insert(&mut job).unwrap());
            assert_eq!(job.id, *ids.last().unwrap());
        }
        assert!(ids.windows(2).all(|w| w[0] < w[1]));
    }

    #[test]
    fn save_then_load_round_trips_every_state() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        let cases = [
            (JobState::Queued, JobState::Paused),
            (JobState::Running, JobState::Paused),
            (JobState::Paused, JobState::Paused),
            (JobState::Retrying { attempt: 2 }, JobState::Paused),
            (JobState::Done { path: "/d/f.bin".into() }, JobState::Done { path: "/d/f.bin".into() }),
            (JobState::Failed { reason: "404".into() }, JobState::Failed { reason: "404".into() }),
        ];
        for (i, (state, expected_state)) in cases.into_iter().enumerate() {
            let part = dir.path().join(format!("{i}.part"));
            std::fs::write(&part, [0u8; 7]).unwrap();
            let mut job = sample(&part, JobState::Queued);
            job.position = i as i64;
            store.insert(&mut job).unwrap();

            job.state = state.clone();
            job.done = 7;
            job.total = None;
            job.last_modified = Some("Mon, 01 Jan 2024 00:00:00 GMT".into());
            if let JobState::Done { path } = &state {
                job.final_path = Some(PathBuf::from(path));
            }
            store.save(&job).unwrap();

            let jobs = store.load_all().unwrap();
            let got = jobs.iter().find(|j| j.id == job.id).unwrap();
            let mut expected = job.clone();
            expected.state = expected_state;
            expected.updated_at = got.updated_at;
            assert_eq!(got, &expected, "state {state:?}");
        }
    }

    #[test]
    fn load_all_sets_done_from_part_file_length() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        let part = dir.path().join("a.part");
        std::fs::write(&part, [0u8; 11]).unwrap();
        let mut job = sample(&part, JobState::Running);
        job.done = 3;
        store.insert(&mut job).unwrap();

        let jobs = store.load_all().unwrap();
        assert_eq!(jobs[0].done, 11);
        assert_eq!(jobs[0].state, JobState::Paused);
    }

    #[test]
    fn load_all_resets_done_to_zero_when_part_is_missing_and_does_not_write_back() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        let mut job = sample(&dir.path().join("gone.part"), JobState::Running);
        job.done = 9;
        store.insert(&mut job).unwrap();

        let jobs = store.load_all().unwrap();
        assert_eq!(jobs[0].done, 0);
        assert_eq!(jobs[0].state, JobState::Paused);

        let stored: i64 = store
            .lock()
            .unwrap()
            .query_row("SELECT done FROM jobs WHERE id = ?1", [job.id as i64], |r| r.get(0))
            .unwrap();
        assert_eq!(stored, 9);
    }

    #[test]
    fn done_jobs_keep_their_saved_done() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        let mut job = sample(&dir.path().join("gone.part"), JobState::Done { path: "/d/f.bin".into() });
        job.done = 42;
        store.insert(&mut job).unwrap();

        let jobs = store.load_all().unwrap();
        assert_eq!(jobs[0].done, 42);
        assert_eq!(jobs[0].state, JobState::Done { path: "/d/f.bin".into() });
    }

    #[test]
    fn delete_removes_row() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        let part = dir.path().join("x.part");
        let mut keep = sample(&part, JobState::Paused);
        let mut drop_me = sample(&part, JobState::Paused);
        store.insert(&mut keep).unwrap();
        store.insert(&mut drop_me).unwrap();

        store.delete(drop_me.id).unwrap();

        let jobs = store.load_all().unwrap();
        assert_eq!(jobs.len(), 1);
        assert_eq!(jobs[0].id, keep.id);
    }

    #[test]
    fn load_all_is_ordered_by_position() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        let part = dir.path().join("x.part");
        for (name, position) in [("a", 3), ("b", 1), ("c", 2)] {
            let mut job = sample(&part, JobState::Paused);
            job.name = name.into();
            job.position = position;
            store.insert(&mut job).unwrap();
        }

        let names: Vec<String> = store.load_all().unwrap().into_iter().map(|j| j.name).collect();
        assert_eq!(names, ["b", "c", "a"]);
    }

    #[test]
    fn segments_round_trip() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        let part = dir.path().join("s.part");
        std::fs::write(&part, [0u8; 10]).unwrap();
        let mut job = sample(&part, JobState::Paused);
        job.segments = vec![Segment { start: 0, end: 6, done: 4 }, Segment { start: 6, end: 10, done: 0 }];
        store.insert(&mut job).unwrap();
        store.save(&job).unwrap();

        let jobs = store.load_all().unwrap();
        assert_eq!(jobs[0].segments, job.segments);
    }

    #[test]
    fn load_all_uses_segment_sum_for_done_not_preallocated_length() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        let part = dir.path().join("p.part");
        std::fs::write(&part, [0u8; 10]).unwrap();
        let mut job = sample(&part, JobState::Running);
        job.segments = vec![Segment { start: 0, end: 6, done: 4 }, Segment { start: 6, end: 10, done: 3 }];
        store.insert(&mut job).unwrap();
        store.save(&job).unwrap();

        let jobs = store.load_all().unwrap();
        assert_eq!(jobs[0].done, 7);
        assert_eq!(jobs[0].segments.len(), 2);
        assert_eq!(jobs[0].state, JobState::Paused);
    }

    #[test]
    fn load_all_clears_segments_when_part_is_missing() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        let mut job = sample(&dir.path().join("gone.part"), JobState::Paused);
        job.segments = vec![Segment { start: 0, end: 10, done: 5 }];
        job.done = 5;
        store.insert(&mut job).unwrap();
        store.save(&job).unwrap();

        let jobs = store.load_all().unwrap();
        assert!(jobs[0].segments.is_empty());
        assert_eq!(jobs[0].done, 0);
    }

    #[test]
    fn host_limit_only_lowers_relaxes_and_expires() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        store.note_host("a.example", 4, "rate limited").unwrap();
        store.note_host("a.example", 8, "rate limited").unwrap();
        assert_eq!(store.host_limit("a.example").unwrap(), Some((4, "rate limited".to_string())));
        store.relax_host("a.example").unwrap();
        assert_eq!(store.host_limit("a.example").unwrap().map(|l| l.0), Some(5));

        store.note_host("b.example", 2, "blocked extra connections").unwrap();
        store.relax_host("b.example").unwrap();
        store.conn.lock().unwrap().execute("UPDATE hosts SET updated_at = 0 WHERE host = 'b.example'", []).unwrap();
        assert_eq!(store.host_limit("b.example").unwrap(), None);
        assert_eq!(store.hosts().unwrap().iter().map(|h| h.host.as_str()).collect::<Vec<_>>(), ["a.example"]);

        store.forget_host("a.example").unwrap();
        assert!(store.hosts().unwrap().is_empty());
    }
}
