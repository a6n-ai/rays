//! SQLite persistence (`<data_dir>/queue.db`, WAL). Uses the system libsqlite3.
use crate::queue::QueueConfig;
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
    "ALTER TABLE buckets ADD COLUMN profile TEXT",
    "ALTER TABLE jobs ADD COLUMN dir TEXT",
    "ALTER TABLE jobs ADD COLUMN fixed_name INTEGER NOT NULL DEFAULT 0",
    "ALTER TABLE jobs ADD COLUMN sha256 TEXT",
    // Schedule and finish action are JSON text.
    "CREATE TABLE queues(id INTEGER PRIMARY KEY, name TEXT NOT NULL, max_running INTEGER NOT NULL,
     speed_limit INTEGER NOT NULL, enabled INTEGER NOT NULL, schedule TEXT, retry_failed INTEGER NOT NULL,
     wake INTEGER NOT NULL, when_finished TEXT NOT NULL, held INTEGER NOT NULL DEFAULT 0)",
    "INSERT INTO queues (id, name, max_running, speed_limit, enabled, schedule, retry_failed, wake, when_finished, held) \
     VALUES (1, 'Main queue', 3, 0, 1, 'null', 0, 0, '\"Nothing\"', 0)",
    "ALTER TABLE jobs ADD COLUMN queue_id INTEGER NOT NULL DEFAULT 1",
];

const COLUMNS: &str = "id, url, name, part_path, final_path, done, total, etag, last_modified, \
                       resumable, state, error, position, created_at, updated_at, segments, dir, fixed_name, sha256, queue_id";

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
        let dir = job.dir.as_ref().map(|d| d.to_string_lossy().into_owned());
        let conn = self.lock()?;
        conn.execute(
            "INSERT INTO jobs (url, name, part_path, final_path, done, total, etag, last_modified, \
             resumable, state, error, position, created_at, updated_at, segments, dir, fixed_name, sha256, queue_id) \
             VALUES (:url, :name, :part_path, :final_path, :done, :total, :etag, :last_modified, \
             :resumable, :state, :error, :position, :created_at, :updated_at, :segments, :dir, :fixed_name, :sha256, :queue_id)",
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
                ":dir": dir,
                ":fixed_name": job.fixed_name,
                ":sha256": job.sha256,
                ":queue_id": job.queue_id as i64,
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
        let dir = job.dir.as_ref().map(|d| d.to_string_lossy().into_owned());
        let conn = self.lock()?;
        conn.execute(
            "UPDATE jobs SET url = :url, name = :name, part_path = :part_path, final_path = :final_path, \
             done = :done, total = :total, etag = :etag, last_modified = :last_modified, \
             resumable = :resumable, state = :state, error = :error, position = :position, \
             segments = :segments, dir = :dir, fixed_name = :fixed_name, sha256 = :sha256, queue_id = :queue_id, \
             updated_at = :updated_at WHERE id = :id",
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
                ":dir": dir,
                ":fixed_name": job.fixed_name,
                ":sha256": job.sha256,
                ":queue_id": job.queue_id as i64,
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
            "INSERT INTO buckets (name, provider, endpoint, region, access_key_id, path_style, created_at, profile) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8) ON CONFLICT(name) DO UPDATE SET provider = excluded.provider, \
             endpoint = excluded.endpoint, region = excluded.region, access_key_id = excluded.access_key_id, \
             path_style = excluded.path_style, profile = excluded.profile",
            params![b.name, b.provider, b.endpoint, b.region, b.access_key_id, b.path_style, now_secs(), b.profile],
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
            "SELECT name, provider, endpoint, region, access_key_id, path_style, profile FROM buckets ORDER BY created_at, name",
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
                    profile: r.get(6)?,
                })
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(rows)
    }

    /// Queues by id (Main first), each with its `held` flag.
    pub fn queues(&self) -> Result<Vec<(QueueConfig, bool)>, EngineError> {
        let conn = self.lock()?;
        let mut stmt = conn.prepare(
            "SELECT id, name, max_running, speed_limit, enabled, schedule, retry_failed, wake, when_finished, held \
             FROM queues ORDER BY id",
        )?;
        let rows = stmt
            .query_map([], |r| {
                let config = QueueConfig {
                    id: Some(r.get::<_, i64>(0)? as u64),
                    name: r.get(1)?,
                    max_running: r.get::<_, i64>(2)? as u32,
                    speed_limit: r.get::<_, i64>(3)? as u64,
                    enabled: r.get(4)?,
                    schedule: json_column(&r.get::<_, String>(5)?, 5)?,
                    retry_failed: r.get(6)?,
                    wake: r.get(7)?,
                    when_finished: json_column(&r.get::<_, String>(8)?, 8)?,
                };
                Ok((config, r.get(9)?))
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(rows)
    }

    /// Adds a queue when `config.id` is None, otherwise updates that queue. Returns its id. Keeps `held`.
    pub fn save_queue(&self, config: &QueueConfig) -> Result<u64, EngineError> {
        let schedule = serde_json::to_string(&config.schedule).expect("queue schedule serializes");
        let when_finished = serde_json::to_string(&config.when_finished).expect("finish action serializes");
        let conn = self.lock()?;
        conn.execute(
            "INSERT INTO queues (id, name, max_running, speed_limit, enabled, schedule, retry_failed, wake, when_finished) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9) ON CONFLICT(id) DO UPDATE SET name = excluded.name, \
             max_running = excluded.max_running, speed_limit = excluded.speed_limit, enabled = excluded.enabled, \
             schedule = excluded.schedule, retry_failed = excluded.retry_failed, wake = excluded.wake, \
             when_finished = excluded.when_finished",
            params![
                config.id.map(|id| id as i64),
                config.name,
                i64::from(config.max_running),
                config.speed_limit as i64,
                config.enabled,
                schedule,
                config.retry_failed,
                config.wake,
                when_finished,
            ],
        )?;
        Ok(match config.id {
            Some(id) => id,
            None => conn.last_insert_rowid() as u64,
        })
    }

    /// Deletes a queue and moves its jobs to the Main queue. The Main queue cannot be deleted.
    pub fn delete_queue(&self, id: u64) -> Result<(), EngineError> {
        if id == 1 {
            return Err(EngineError::Db { msg: "the Main queue cannot be deleted".into() });
        }
        let mut conn = self.lock()?;
        let tx = conn.transaction()?;
        tx.execute("UPDATE jobs SET queue_id = 1 WHERE queue_id = ?1", [id as i64])?;
        tx.execute("DELETE FROM queues WHERE id = ?1", [id as i64])?;
        tx.commit()?;
        Ok(())
    }

    pub fn set_held(&self, id: u64, held: bool) -> Result<(), EngineError> {
        self.lock()?.execute("UPDATE queues SET held = ?1 WHERE id = ?2", params![held, id as i64])?;
        Ok(())
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
        JobState::Verifying => ("verifying", None),
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
        // Reloads as Paused: load_all pauses every unfinished job, and the hash restarts on resume.
        "verifying" => JobState::Paused,
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
        dir: row.get::<_, Option<String>>("dir")?.map(PathBuf::from),
        fixed_name: row.get::<_, i64>("fixed_name")? != 0,
        sha256: row.get("sha256")?,
        queue_id: row.get::<_, i64>("queue_id")? as u64,
    })
}

fn json_column<T: serde::de::DeserializeOwned>(text: &str, idx: usize) -> rusqlite::Result<T> {
    serde_json::from_str(text).map_err(|e| rusqlite::Error::FromSqlConversionFailure(idx, rusqlite::types::Type::Text, Box::new(e)))
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
            profile: None,
        };
        store.save_bucket(&b).unwrap();
        b.profile = Some("work".into());
        b.region = "weur".into();
        store.save_bucket(&b).unwrap();
        assert_eq!(store.buckets().unwrap(), vec![b]);
        store.remove_bucket("media").unwrap();
        assert!(store.buckets().unwrap().is_empty());
    }

    use super::*;
    use crate::queue::{FinishAction, QueueSchedule, Repeat};

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
            dir: None,
            fixed_name: false,
            sha256: None,
            queue_id: 1,
        }
    }

    fn sample_queue(name: &str) -> QueueConfig {
        QueueConfig {
            id: None,
            name: name.into(),
            max_running: 2,
            speed_limit: 0,
            enabled: true,
            schedule: None,
            retry_failed: false,
            wake: false,
            when_finished: FinishAction::Nothing,
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
    fn job_dir_name_and_hash_round_trip() {
        let dir = tempfile::tempdir().unwrap();
        let mut job = sample(&dir.path().join("w.part"), JobState::Paused);
        job.dir = Some(PathBuf::from("/x/AI Models/a/b"));
        job.fixed_name = true;
        job.sha256 = Some("ab12".into());
        Store::open(dir.path()).unwrap().insert(&mut job).unwrap();

        let store = Store::open(dir.path()).unwrap();
        assert_eq!(user_version(&store), MIGRATIONS.len() as i64);
        assert_eq!(store.load_all().unwrap(), vec![job]);
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
    fn load_all_pauses_a_verifying_job() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        let part = dir.path().join("a.part");
        std::fs::write(&part, [0u8; 4]).unwrap();
        let mut job = sample(&part, JobState::Verifying);
        store.insert(&mut job).unwrap();

        let jobs = store.load_all().unwrap();
        assert_eq!(jobs[0].state, JobState::Paused);
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

    #[test]
    fn main_queue_exists_after_migration() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        let (main, held) = &store.queues().unwrap()[0];
        assert_eq!(main.id, Some(1));
        assert_eq!(main.name, "Main queue");
        assert!(!held);
    }

    #[test]
    fn queue_round_trip() {
        let dir = tempfile::tempdir().unwrap();
        let config = QueueConfig {
            schedule: Some(QueueSchedule {
                repeat: Repeat::Days { mask: 0b0011111 },
                start_min: 120,
                stop_min: Some(450),
                wifi: true,
                power: false,
                idle: false,
            }),
            wake: true,
            retry_failed: true,
            when_finished: FinishAction::Command { command: "echo hi".into() },
            ..sample_queue("Nightly")
        };
        let store = Store::open(dir.path()).unwrap();
        let id = store.save_queue(&config).unwrap();
        store.set_held(id, true).unwrap();
        drop(store);

        let store = Store::open(dir.path()).unwrap();
        let queues = store.queues().unwrap();
        let (got, held) = queues.iter().find(|(q, _)| q.id == Some(id)).unwrap();
        assert_eq!(got, &QueueConfig { id: Some(id), ..config });
        assert!(held);
    }

    #[test]
    fn jobs_default_to_main() {
        let dir = tempfile::tempdir().unwrap();
        // The schema before the queues migrations, with a job row written the way old builds wrote it.
        let conn = Connection::open(dir.path().join("queue.db")).unwrap();
        for sql in &MIGRATIONS[..8] {
            conn.execute_batch(sql).unwrap();
        }
        conn.execute(
            "INSERT INTO jobs (url, name, part_path, done, resumable, state, position, created_at, updated_at) \
             VALUES ('https://example.com/f.bin', 'f.bin', '/p', 0, 1, 'paused', 0, 0, 0)",
            [],
        )
        .unwrap();
        conn.pragma_update(None, "user_version", 8).unwrap();
        drop(conn);

        let store = Store::open(dir.path()).unwrap();
        assert_eq!(store.load_all().unwrap()[0].queue_id, 1);
    }

    #[test]
    fn delete_moves_jobs_to_main() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        let id = store.save_queue(&sample_queue("Side")).unwrap();
        assert_eq!(id, 2);
        let mut job = sample(&dir.path().join("q.part"), JobState::Paused);
        job.queue_id = id;
        store.insert(&mut job).unwrap();

        store.delete_queue(id).unwrap();

        assert_eq!(store.load_all().unwrap()[0].queue_id, 1);
        assert!(store.delete_queue(1).is_err());
    }
}
