# Rays performance audit

Scope: read-only review of engine, app and build config. Line numbers refer to the tree as audited.
"Confirmed" = visible in code or measured. "Suspected" = plausible from code, not profiled.

## Measurement

`cargo build --release -p dl-engine --example bench` built. Running `bench https://speed.cloudflare.com/__down?bytes=104857600 {1,8}`
reached the network but failed both times with `HTTP 403` (Cloudflare rejects requests with no User-Agent, see finding 5).
No throughput numbers were taken. Nothing else was retried. The bench uses a temp dir, not `~/Library/Application Support/Rays`.

## Ranked findings

### 1. Two blocking-pool round trips per network chunk (CONFIRMED by code)
- Where: download.rs:848-870 (segment path), :297 (single stream path).
- What: `tokio::fs::File` runs each `write_all` and each `flush` on `spawn_blocking`. Segment path does `write_all` then `flush().await` per chunk.
  Chunks are one hyper/TLS read (about 16 KB with native-tls), so a 100 MB/s link means about 6k chunks/s and about 12k blocking-pool hops/s.
  Each hop is a thread wakeup and a pwrite of 16 KB.
- Also: the file is opened and `seek`ed per attempt (:848-849), fine, but writes are seek+write on a tokio File (internal cursor), not pwrite.
- Change: accumulate up to 256 KB to 1 MB per segment in a `Vec`/`BytesMut` and write once per batch (flush on segment end, cancel, or every ~250 ms),
  calling `record()` only after the batch lands so `seg.done` stays crash-safe. Better: one `std::fs::File` per segment and `FileExt::write_all_at`
  inside a single `spawn_blocking` per batch, which drops the seek and the per-chunk flush. Remove `file.flush()` (:870).
- Impact: high on fast links (>200 MB/s, many small chunks, 2 worker threads). Effort: low-med. Risk: low. Keep the `done` counter semantic (bytes on disk) and the pause path flushing the buffer.

### 2. SQLite save under the job mutex, default synchronous=FULL (CONFIRMED by code)
- Where: scheduler.rs:377-386 (`flush_progress`, every 2 s, per active job), store.rs:38 (WAL set, no `synchronous` pragma).
- What: `flush_progress` holds `live.job` while calling `store.save`. The same mutex is taken by `record()` (download.rs:558), `seg_pos` (:853, :862) on every chunk of every segment.
  WAL + default `synchronous=FULL` fsyncs the WAL per commit, so each tick can stall all segments of that job for the length of an fsync, plus JSON-encoding the segments (store.rs:230) and a full-row UPDATE (store.rs:124).
- Change: (a) `PRAGMA synchronous=NORMAL` (WAL stays durable across app crashes; only OS crash can lose the last commit, which the resume logic already tolerates since progress is advisory and `.part` size is re-checked).
  (b) clone the `Job` under the lock, drop the lock, then save. (c) optionally a narrow `UPDATE jobs SET done=?, segments=?` for progress ticks.
- Impact: med (latency spikes and lock stalls every 2 s; more with several jobs). Effort: low. Risk: low.

### 3. Slow connection ramp and wasted probe connection (CONFIRMED by code)
- Where: download.rs:33-39 (TICK 1 s, WARM 2, WINDOW 2), :395-428, :258-275.
- Ramp: start with 2 segments (`plan`, :313). Each added connection needs 2 warm + 2 measure ticks = 4 s, and must beat the best by 10%.
  Reaching 8 connections takes about 24 s, 16 takes about 56 s. Files that finish in under 10 s (most files on a fast link) never get past 2-3 connections.
- Probe waste: the plain GET that discovered size/ranges is dropped (:259) without reading the body, so its TCP+TLS connection is thrown away,
  then two new connections each pay DNS-pool lookup, TCP, TLS and request RTT. Segment 0 could continue on the probe response (it already streams from byte 0).
- Change: for `total >= ~32 MB` plan `min(cap, 4)` segments up front (`plan(total, n)`; MIN_SEGMENT 1 MB still holds); use TICK 500 ms with WARM 1 / WINDOW 2 so a step costs 1.5 s; keep the probe response as segment 0's stream and truncate it at its `end`.
- Impact: high for 50 MB to 2 GB files on fast links, low for tiny/huge files. Effort: med (probe reuse is the fiddly part; the plan change is low). Risk: med (more initial connections may trip per-host limits; note_host/park logic already handles 429/503).

### 4. Per-chunk lock and wakeup fan-out (CONFIRMED by code)
Per chunk, segment path takes: `seg_pos` x2 (download.rs:853, 862, each `live.job` lock), `record` (:558, `live.job`), `limiter.acquire` (limit.rs:49, global Mutex, locked even when rate==0),
`hub.progress` (events.rs:59, hub Mutex + BTreeSet insert) and `notify_one` (events.rs:60). Plus `tokio::time::timeout` timer (:856) on top of the client's own `read_timeout(30s)` (scheduler.rs:78), and a `watch` select (:168).
- `notify_one` on every chunk wakes the consumer of `hub.wait()` (events.rs:88-96), which is parked in `select!{sleep_until, notified}`. It wakes, re-locks, recomputes and sleeps again, up to thousands of times per second for no output (delivery is capped at 250 ms, events.rs:10).
- Change: `progress()` only notifies if the id was newly inserted (`insert()` returned true) or no timer is pending; make `seg_pos` + `record` one lock (`record` already reads `end`; pass back the new end); fast path `AtomicU64 rate` in `RateLimiter` so unlimited runs skip the Mutex; drop the per-chunk `timeout` wrapper (the client `read_timeout` already covers stalls) or keep one and drop the other.
- Impact: med on CPU at high speed, low on throughput. Effort: low. Risk: low.

### 5. No User-Agent on the HTTP client (CONFIRMED by measurement)
- Where: scheduler.rs:76-80. The bench got `HTTP 403` from speed.cloudflare.com on both runs.
- Change: `.user_agent("Rays/<version>")` on the builder. A browser-like UA is not needed for most CDNs; a named UA is enough for Cloudflare's default rule.
- Impact: high for compatibility (such hosts fail outright), none for speed. Effort: trivial. Risk: very low.

### 6. App: whole-list invalidation on every progress event (CONFIRMED by code; cost suspected)
- Where: EngineModel.swift:203-211 (`apply`), ContentView.swift:124-125, :176, :204-205.
- What: engine emits up to 4 events/s per active job (events.rs:10, not 2 s). Each does `jobs.firstIndex(where:)` O(n) and `jobs[index] = job`, which invalidates every view that read `model.jobs`.
  `DownloadsView.body` then runs `visible` (a filter), `visible.map(\.id)` for `.animation`, `subtitle` (two more filters plus a reduce), and `ForEach` diffs all `JobView` values (generated type, not Equatable, carries a `parts` array), so rows likely re-evaluate even when unchanged.
  Cost grows with history size, not with active jobs.
- Change: store `[UInt64: JobView]` plus an ordered id array (O(1) apply); make `JobView` Equatable and rows `.equatable()`, or give each job a small `@Observable` row model so only the changed row re-renders; compute `visible`/`subtitle` once per change; replace `.animation(value: visible.map(\.id))` with a cheap revision counter that bumps only on add/remove/reorder.
- Impact: med (CPU while downloading with a long list). Effort: med. Risk: low.

### 7. App: `locate()` and icon work inside `JobRow.body` (CONFIRMED by code; frequency suspected)
- Where: JobRow.swift:80 (`dragOut(model.locate(job))`), :86 (accessibility label evaluates `statusParts`), :188 (`statusParts` calls `locate` again), :107-108 (`UTType` + `NSWorkspace.icon(for:)` each body).
- What: a Done row calls `locate` up to 3 times per body. `locate` (EngineModel.swift:160-177) goes bookmark resolve (cached 2 s, FileTracker.swift:31), then `fileExists`, then a recursive directory enumeration of the downloads folder, depth 4, on the main thread, when the file moved and has no bookmark.
  With a large finished history, each re-render multiplies this.
- Change: resolve the location once when the job becomes Done and on a slow refresh (off the main actor), store it in the model, have rows read the cached value; compute `statusParts` once per body; cache icons by extension in a dictionary; drop the directory-walk fallback from the render path (run it only on Reveal/Open).
- Impact: med with large history, low otherwise. Effort: low-med. Risk: low.

### 8. Runtime has only 2 worker threads (SUSPECTED)
- Where: api.rs:23-27. All TLS decrypt, chunk handling, hub and scheduler timers and the IPC server share 2 threads. At multi-Gbps with several jobs this can be the CPU ceiling (once findings 1 and 4 are fixed). Profile first; try `worker_threads(4)` or `available_parallelism().min(4)`.
- Impact: low-med on gigabit+ links. Effort: trivial. Risk: low (idle CPU stays low, threads park).

### 9. Release profile (CONFIRMED)
- Cargo.toml:3-7: `lto = true`, `codegen-units = 1`, `strip = true`, `opt-level = "s"`. `panic` is default (unwind), which UniFFI needs to turn Rust panics into Swift errors; do not set `abort`.
- `opt-level = "s"` favours size in the chunk loop and parsing. Try `opt-level = 3` for `dl-engine` only (`[profile.release.package.dl-engine]`) and compare bench plus binary size; crypto lives in Security.framework so gain is likely small (low-med). Effort trivial; risk low.
- scripts/bundle-app.sh:9-11 builds Swift `-c release` for arm64 and x86_64 (universal). Engine, CLI, sorter, extract are all built twice and lipo'd (:21-27, scripts/build-engine.sh:9-12). Needed while Intel on macOS 26 is supported; halves app size if arm64-only is acceptable. No extra Swift flags (`-Ounchecked` or exclusivity checks off) are set; gain would be marginal.
- Dependencies: reqwest has `default-features = false`, `native-tls`, no `http2`, no gzip/deflate/brotli (Cargo.toml engine). That is the right shape for multi-connection downloads (HTTP/1.1 gives one TCP stream per segment, no unwanted decompression, `Content-Length` stays raw). Keep it. Switching to rustls would grow the binary for little gain.

### 10. Smaller items
- finish: full `sync_all` of the finished file (download.rs:888) stalls the Done transition on multi-GB files after all dirty pages pile up; consider `sync_data` or periodic `sync_data` in the writer batch (finding 1). Low impact, low risk.
- `find()` (scheduler.rs:297-299) is O(n) with one mutex lock per job, called once per changed id per event via `view()` (api.rs:111). `flush_progress` (:377-386) also walks every job every 2 s. Use a `HashMap<JobId, Arc<Live>>` alongside the ordered Vec. Low now, grows with history.
- Finished jobs keep `segments` in memory and the DB (finish at download.rs:904 does not clear them); `JobView.parts` is cloned and sorted in `view_of` (scheduler.rs:402-408) for rows that never draw it (JobRow.swift:69). Clear segments on Done. Low.
- Connection reuse is already good: one shared `Client` (scheduler.rs:76, cloned per job at :313), pooled keep-alive per host. Segments cut short by a split drop the response mid-body (download.rs:853, 863), which closes that connection; minor.
- Already-fine: no timers or polling in the app (only the 1 s back-off at EngineModel.swift:77 when the event batch is empty), SegmentedProgressBar is a single Canvas (cheap), List is lazy.

## Suggested order
1 (batched writes), 5 (User-Agent), 2 (synchronous + lock scope), 3 (ramp), 4 (lock/wakeup trim), 6 and 7 (SwiftUI), then re-measure with the bench on a host that accepts the request before touching 8 and 9.
