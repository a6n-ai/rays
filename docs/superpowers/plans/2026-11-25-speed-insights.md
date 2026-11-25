# Speed Insights Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rays logs connection speed from real downloads and an on-demand speed test, recommends the fastest daily window, and can download at that time through a self-scheduling Best time queue.

**Architecture:** Everything that decides lives in the Rust engine (`dl-engine`):
- the speed log (SQLite)
- the recommender (a pure function)
- the download sampler
- the speed test (reqwest)
- the Best time queue follower

The SwiftUI app, `dl` and MCP only read and trigger it.

**Tech Stack:** Rust (tokio, reqwest 0.13, rusqlite, jiff 1.0.2, UniFFI) and SwiftUI on macOS 26 (Liquid Glass, Swift Charts).

**Spec:** `docs/superpowers/specs/2026-11-25-speed-insights-design.md`. Read the whole spec, including "Decisions after the builder check".

## Global Constraints

- **Migrations** are append-only: add entries to the end of `MIGRATIONS` in `engine/src/store.rs`. Never edit an existing entry.
- **Time:** use jiff 1.0.2 and local time. The API is `DateTime::to_zoned_datetime` / `ZonedDateTime::now()`, not `to_zoned` / `Zoned`. Use the scheduler's injected `Clock` (`scheduler.rs:31`) for "now", so tests control time.
- **Retention:**
  - Samples older than **60 days** are deleted.
  - The recommender reads the last **28 days**.
- **Enough data** means at least **7** distinct local days, and at least **3** samples in every hour of the window.
- **Confidence:**
  - High: at least **14** days and at least **5** samples in each hour of the window.
  - Medium: otherwise, once there is enough data.
- **Speed test:**
  - **4** parallel connections, **10 s** max.
  - Server: `https://speed.cloudflare.com/__down?bytes=N`.
  - Latency is the median of **5** requests with `bytes=0`.
- **Download samples:**
  - One sample per minute: the total bytes/s across all running jobs.
  - Record it only when all of these hold: at least one job ran for the whole minute, no global or queue speed limit is active, the total is above **50 kB/s** (50_000 B/s), and the network is not Expensive or Unknown.
- **Automatic tests:**
  - Off by default. When on, one runs every **3 h**, at a random minute within each 3 h slot.
  - The night week runs one test in each of the slots **00–02, 02–04 and 04–06**, at a random minute, for **7** days.
  - All automatic tests run only on Wifi or Wired, and only when no download is running.
- **Best time queue:**
  - Name "Best time", symbol `moon.stars`, colour indigo.
  - Its schedule is Every day, from the window's start to its end. It is refreshed once a day, and only when the window moves by at least **30** minutes.
  - With no data, it uses the default **01:00–06:00**.
  - The Wi-Fi, power and idle conditions all start off.
- **Window length:** 4 hours by default.
- **Slow hint:** shown when the job is at least **1 GB**, has run at least **60 s**, the window speed is at least **2×** the job's speed, the current time is outside the window, and confidence is Medium or High.
- **Copy:**
  - No em dashes, no exclamation marks. Use the Mac's own words.
  - These strings are exact:
    - "Let Rays test your speed a few times each night for a week? About 1 GB in total."
    - "Default night window until Rays has 7 days of speed data"
    - "You're on a hotspot or metered connection. A test uses about 50 to 200 MB."
    - "Downloads were running, so this result wasn't saved"
    - "Uses about 50 to 200 MB per test"
- **Liquid Glass** goes only on floating or interactive chrome. Row selection uses the grey `RowHighlight`.
- **Privacy:** no speed data leaves the Mac. Over IPC, MCP and `dl`, reading speed data and running a test are allowed. Clearing history and changing settings are not, matching the queue-editing rule in `engine/src/protocol.rs`.

## Review Focus

1. **Clock or time zone change, including DST.** Buckets use the local hour at the moment of the sample. A DST day must not crash, and its doubled or missing hour must not produce a window with an empty hour. Test: `best_window_dst_day` in Task 2.
2. **A window that crosses midnight**, for example 23:00–03:00, is chosen and turned into a valid `QueueSchedule` with `stop_min` < `start_min`. Test: `wrap_window_to_schedule` in Task 2.
3. **The user edits the Best time queue's schedule, then the daily refresh runs.** The refresh must not overwrite the user's schedule. Test: `manual_edit_stops_following` in Task 5.
4. **The speed test is offline, or a proxy returns HTML or a 403.** The result must be an error with a plain message, and no sample is saved. Test: `speed_test_proxy_error_saves_nothing` in Task 4.
5. **Downloads under a speed limit.** No sample may be recorded while a limit caps throughput. Test: `limited_minute_not_sampled` in Task 3.

---

### Task 1: Speed store and settings

**Files:**
- Modify: `engine/src/store.rs` (append to `MIGRATIONS`, add methods)
- Modify: `engine/src/queue.rs` (`QueueConfig.follow_best_time`)
- Test: `store.rs` unit tests (`mod tests`)

**Interfaces:**
- Produces:
  - `pub struct SpeedSample { pub at: i64, pub bps: u64, pub source: SampleSource, pub network: NetworkKind }`, a `uniffi::Record`, in a new file `engine/src/speed.rs`. Declare the module in `lib.rs`.
  - `pub enum SampleSource { Test, Downloads }` (`uniffi::Enum`)
  - `pub enum NetworkKind { Wifi, Wired, Expensive, Other, Unknown }` (`uniffi::Enum`)
  - On `Store`:
    - `add_sample(&self, s: &SpeedSample) -> Result<()>`
    - `samples_since(&self, at: i64) -> Result<Vec<SpeedSample>>` (oldest first)
    - `prune_samples(&self, before: i64) -> Result<usize>`
    - `clear_samples(&self) -> Result<()>`
    - `setting(&self, key: &str) -> Result<Option<String>>`
    - `set_setting(&self, key: &str, value: Option<&str>) -> Result<()>` (`None` deletes the key)
  - `QueueConfig.follow_best_time: bool`, stored in a new `queues.follow_best_time` column, default 0. Update every `QueueConfig { .. }` literal; grep for them.

Migrations to append, in this order:
- `CREATE TABLE speed_samples(id INTEGER PRIMARY KEY, at INTEGER NOT NULL, bps INTEGER NOT NULL, source TEXT NOT NULL, network TEXT NOT NULL)`
- `CREATE INDEX speed_samples_at ON speed_samples(at)`
- `CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT NOT NULL)`
- `ALTER TABLE queues ADD COLUMN follow_best_time INTEGER NOT NULL DEFAULT 0`

Store the `source` and `network` columns as lowercase strings (`test`, `downloads`; `wifi`, `wired`, `other`). An unknown string read back maps to `Other` or `Downloads` and never errors.

- [ ] **Step 1: Write the failing tests** `samples_round_trip`, `prune_removes_old`, `settings_set_get_delete` and `follow_best_time_persists`:
  - `samples_round_trip`: add 3 samples at times 30, 10 and 20. `samples_since(15)` returns the samples at 20 and 30, oldest first, with their fields equal to what was added.
  - `prune_removes_old`: `prune_samples(25)` returns 2 and leaves 1 sample.
  - `settings_set_get_delete`: `set_setting("k", Some("v"))`, then `setting("k") == Some("v")`. `set_setting("k", None)`, then `setting("k") == None`.
  - `follow_best_time_persists`: save a queue with `follow_best_time: true`, and `queues()` returns it as true.
- [ ] **Step 2:** Run `cargo test -q -p dl-engine --lib store`. It should fail to compile, or fail.
- [ ] **Step 3:** Implement the code described above.
- [ ] **Step 4:** `cargo test -q -p dl-engine --lib` passes. `cargo test -q -p dl-engine --test queues` passes, with the literals updated. `cargo build -q -p dl-cli` builds.
- [ ] **Step 5:** Commit `Engine: speed samples, settings table, follow_best_time column`.

### Task 2: Recommender (pure)

**Files:**
- Modify: `engine/src/speed.rs`
- Test: `speed.rs` `mod tests`

**Interfaces:**
- Consumes: `SpeedSample` (Task 1)
- Produces:
  - `pub enum Confidence { Low, Medium, High }` (`uniffi::Enum`). Low is never returned with a window. It exists only for the app's label.
  - `pub enum BestTime { Window { start_min: u16, end_min: u16, typical_bps: u64, days: u32, confidence: Confidence }, NotEnoughData { days: u32, needed: u32 } }` (`uniffi::Enum`)
  - `pub fn best_window(local: &[(jiff::civil::DateTime, u64)], hours: u8) -> BestTime`. The input is already converted to local time and filtered to 28 days by the caller.
  - `pub fn window_schedule(start_min: u16, end_min: u16) -> QueueSchedule`. It returns `Repeat::Daily`, with `stop_min: Some(end_min)` and every condition false.
  - `pub fn typical_bps_at(local: &[(DateTime, u64)], hour: u8) -> Option<u64>`, the median for that hour, or `None` below 3 samples. The slow hint in Task 7 uses it.

Algorithm (in the spec): put samples into 24 buckets by hour, take each bucket's median, and consider every contiguous `hours`-long window starting at each hour 0–23, wrapping past midnight. Skip any window with a bucket under 3 samples. Pick the window with the highest mean of its bucket medians, and break ties with the earlier start. `start_min = h*60`, and `end_min = ((h+hours)%24)*60`. `typical_bps` is the mean of the window's medians. `days` is the number of distinct local dates.

- [ ] **Step 1: Write the failing tests:**
  - `not_enough_days`: 6 distinct days, with dense samples, gives `NotEnoughData { days: 6, needed: 7 }`.
  - `picks_fastest_window`: 8 days with 5 samples per hour. Hours 1–4 are at 100 MB/s and everything else at 20 MB/s. The result is `Window { start_min: 60, end_min: 300, confidence: Medium, days: 8 }`, with `typical_bps` equal to 100_000_000.
  - `high_confidence`: 14 days and 5 samples per hour gives High.
  - `sparse_hour_skipped`: as `picks_fastest_window`, but hour 2 has only 2 samples. The chosen window avoids hour 2. If no 4 h window is fully covered, the result is `NotEnoughData`.
  - `wrap_window_to_schedule`: hours 22, 23, 0 and 1 are fastest, so the window is `start_min: 1320, end_min: 120`. `window_schedule(1320, 120)` equals `QueueSchedule { repeat: Daily, start_min: 1320, stop_min: Some(120), wifi: false, power: false, idle: false }`.
  - `best_window_dst_day`: the samples include local times on the US or EU fall-back date, with a repeated 01:00 hour. It doesn't panic, and the result is the same as without that day's duplicate hour.
- [ ] **Step 2:** Run `cargo test -q -p dl-engine --lib speed`. It fails.
- [ ] **Step 3:** Implement the functions.
- [ ] **Step 4:** The tests pass, and clippy with `-D warnings` is clean.
- [ ] **Step 5:** Commit `Engine: best-window recommender`.

### Task 3: Network kind and download sampling

**Files:**
- Modify: `engine/src/scheduler.rs` (`set_conditions`, the progress loop at around `:313`, the conditions tuple)
- Modify: `engine/src/api.rs:99` (`set_conditions`)
- Modify: `macos/Sources/Rays/ConditionsMonitor.swift` and its caller in `EngineModel.swift`
- Test: `engine/src/speed.rs` (the `Sampler` unit tests), plus `engine/tests/queues.rs` for the signature change

**Interfaces:**
- Consumes: `NetworkKind` and `Store::add_sample` (Task 1)
- Produces:
  - `Engine::set_conditions(&self, wifi: bool, on_power: bool, idle: bool, network: NetworkKind)`. `wifi` keeps its meaning for queue conditions. The engine starts with `NetworkKind::Unknown`.
  - `pub struct Sampler` in `speed.rs`, with `pub fn observe(&mut self, at: i64, total_bps: u64, any_running: bool, limited: bool, network: NetworkKind) -> Option<SpeedSample>`. It is called once per progress tick. Within each wall-clock minute it averages the `total_bps` values it sees. At the minute boundary it returns `Some` only if `any_running` was true for every tick in that minute, `limited` was false for every tick, the average is above 50_000, and the network is Wifi, Wired or Other.
  - The scheduler owns a `Mutex<Sampler>`. The progress loop feeds it:
    - `total_bps` is the sum of the running jobs' `bytes_per_sec`.
    - `limited` is true when the global limiter rate is above 0, or when any queue with a running job has `speed_limit` above 0.
    
    It stores any returned sample with `store.add_sample`. At start, and when the date changes, it calls `prune_samples(now - 60 days)`.
- On the Swift side, `ConditionsMonitor` derives the network kind from `NWPath`:
  - `isExpensive` → `.expensive`
  - otherwise `usesInterfaceType(.wifi)` → `.wifi`
  - otherwise `.wiredEthernet` → `.wired`
  - otherwise satisfied → `.other`
  - otherwise `.unknown`
  
  Pass it through `report`.

- [ ] **Step 1: Write the failing tests:**
  - `full_minute_sampled`: ticks every 5 s across one minute, all running, unlimited, at 1_000_000, on Wifi. The first tick of the next minute returns a sample with `bps` 1_000_000 and `source: Downloads`.
  - `limited_minute_not_sampled`: the same, but one tick has `limited: true`. Returns `None`.
  - `idle_tick_not_sampled`: one tick has `any_running: false`. Returns `None`.
  - `slow_not_sampled`: 40_000 B/s. Returns `None`.
  - `expensive_not_sampled`: an Expensive or Unknown network. Returns `None`.
- [ ] **Step 2:** Run `cargo test -q -p dl-engine --lib speed`. It fails.
- [ ] **Step 3:** Implement `Sampler`, then wire it into the scheduler, `api.rs`, the test call sites and Swift.
- [ ] **Step 4:** All of these pass:
  - `cargo test -q -p dl-engine --lib`
  - `--test queues`
  - `--test engine`
  - clippy
  - `scripts/build-engine.sh`
  - `swift build --package-path macos`, which prints Build complete!
- [ ] **Step 5:** Commit `Engine: network kind and download speed sampling`.

### Task 4: Speed test

**Files:**
- Create: `engine/src/speedtest.rs`
- Modify: `engine/src/api.rs` (exports) and `engine/src/lib.rs`
- Test: `engine/tests/speed.rs` (new), using a local fake server in the style of `engine/tests/queues.rs:26` `server()`

**Interfaces:**
- Consumes: `Store::add_sample`, `NetworkKind` (Tasks 1 and 3)
- Produces:
  - `pub struct SpeedTestResult { pub bps: u64, pub latency_ms: u32, pub at: i64, pub saved: bool }` (`uniffi::Record`)
  - `Engine::run_speed_test(&self, force: bool) -> Result<SpeedTestResult, EngineError>` (async). It refuses with `EngineError` "You're on a hotspot or metered connection. A test uses about 50 to 200 MB." when the network is Expensive and `force` is false. `saved` is false, and nothing is stored, when any job is Running. In that case the app shows "Downloads were running, so this result wasn't saved".
  - `Engine::set_speed_test_base(&self, base: String)`, for tests, defaulting to `https://speed.cloudflare.com`. The test requests `{base}/__down?bytes=N`.
  - `Engine::last_speed_test(&self) -> Option<SpeedTestResult>`, the newest `Test` sample.

Method: send 5 sequential requests with `bytes=0` and take the median latency. Then run 4 parallel connections. Each loops over requests that start at 1 MB, doubling up to 64 MB, until 10 s have passed. `bps` is the total bytes after the first second divided by the elapsed time after the first second, to skip slow start. An HTTP status other than 2xx, a `content-type` of `text/html`, or fewer than 1 MB received in total is an error: "Couldn't reach the speed test server. Check your connection or proxy." The request goes through the engine's existing reqwest client, so proxy settings apply.

- [ ] **Step 1: Write the failing tests** (in `engine/tests/speed.rs`, with the fake server serving N zero bytes for `/__down?bytes=N`):
  - `speed_test_measures_and_saves`: on Wifi, the result has `bps > 0`, `saved == true`, and `last_speed_test()` returns it.
  - `speed_test_refuses_expensive`: on Expensive with `force` false, it returns an error containing "hotspot". With `force` true, it succeeds.
  - `speed_test_proxy_error_saves_nothing`: the server answers 403 with an HTML body. The error contains "Couldn't reach the speed test server", and no sample is stored.
  - `speed_test_during_download_not_saved`: with one job running against a slow fake route, the result has `saved == false` and no sample is stored.
  - Shorten the 10 s cap in tests through a `#[doc(hidden)] pub fn set_speed_test_duration(&self, ms: u64)` setter.
- [ ] **Step 2:** Run `cargo test -q -p dl-engine --test speed`. It fails.
- [ ] **Step 3:** Implement the speed test.
- [ ] **Step 4:** The tests pass, clippy is clean, and `scripts/build-engine.sh` plus `swift build` succeed.
- [ ] **Step 5:** Commit `Engine: speed test`.

### Task 5: Best time queue, follower and automatic tests

**Files:**
- Modify: `engine/src/scheduler.rs` (`save_queue` at `:1048`, the queue tick, a new automatic-test task)
- Modify: `engine/src/api.rs`
- Test: `engine/tests/speed.rs`

**Interfaces:**
- Consumes: Tasks 1–4. `best_window`, `window_schedule`, the store settings and `run_speed_test`.
- Produces, on `Engine`:
  - `best_time(&self) -> BestTime`. It converts the last 28 days of samples to local time with the scheduler clock's time zone, then calls `best_window(.., 4)`.
  - `best_time_queue(&self) -> Result<u64, EngineError>`. It returns the id stored in setting `best_time_queue_id` if that queue still exists. Otherwise it creates "Best time" with `follow_best_time: true`, the Settings-default fields, and the current window's schedule (or Daily 01:00–06:00 when there is `NotEnoughData`), stores the id, and returns it.
  - `speed_settings(&self) -> SpeedSettings { auto_tests: bool, night_until: Option<i64>, night_prompt_answered: bool }`, and `set_speed_settings(&self, s: SpeedSettings)`. These are stored in the settings keys `auto_tests`, `night_until` and `night_prompt_answered`.
  - `start_night_week(&self)`. It sets `night_until = now + 7 days` and `night_prompt_answered = true`.
  - `clear_speed_history(&self)`.
  - `hourly_typical(&self) -> Vec<Option<u64>>`: 24 entries, `typical_bps_at` for each local hour over the last 28 days. The Speed page chart uses it.
- `save_queue` rule: if the stored queue has `follow_best_time == true`, and the incoming config has a different `schedule` but still says `follow_best_time == true`, save it with `follow_best_time = false`. When the app turns the **Follow best time** switch back on, it saves `follow_best_time: true` with the schedule unchanged. The engine then rewrites the schedule on the next refresh.
- Follower: on each queue tick, once per local date (tracked in setting `best_time_refreshed`, as `YYYY-MM-DD`), for each queue with `follow_best_time`, compute the target schedule. If its start or end differs from the current one by at least 30 minutes, save it through an internal store path that keeps the flag on, and emit `QueueChanged`.
- Automatic tests: a tokio task that wakes every minute.
  - When `night_until > now`, it plans one random minute in each of the 00–02, 02–04 and 04–06 local slots per night.
  - When `auto_tests` is on, it plans one random minute in each 3 h slot.
  - At a planned minute, it runs `run_speed_test(false)`, and only if the network is Wifi or Wired and no job is running. A missed minute is skipped, not caught up.
  - Seed the random choice from the clock, so tests can pin it, or expose `#[doc(hidden)] set_auto_test_plan(Vec<i64>)` for tests.

- [ ] **Step 1: Write the failing tests:**
  - `best_time_queue_created_once`: the first call creates the queue, named "Best time", with `follow_best_time` true. Its schedule is Daily 01:00–06:00 when there is no data. A second call returns the same id. If the user renames the queue, the id is still found.
  - `follower_updates_window`: seed 8 days of samples with hours 1–4 fastest and advance the clock one day. The schedule becomes start 60, stop 300.
  - `follower_ignores_small_moves`: the window moves by 0 minutes, or by under 30, so nothing is saved and no event fires.
  - `manual_edit_stops_following`: the user saves a new schedule, so `follow_best_time` becomes false. After the next day's refresh, the user's schedule is unchanged.
  - `night_week_runs_tests`: `start_night_week`, with the test plan pinned to 3 minutes and the clock advanced past them on Wifi. 3 samples are stored. On Expensive, none are.
- [ ] **Step 2:** Run `cargo test -q -p dl-engine --test speed`. It fails.
- [ ] **Step 3:** Implement the queue, the follower and the automatic tests.
- [ ] **Step 4:** All of these pass:
  - `--test speed`
  - `--test queues`
  - `--lib`
  - clippy
  - `build-engine.sh`
  - `swift build`
- [ ] **Step 5:** Commit `Engine: best time queue, follower, automatic tests`.

### Task 6: IPC, dl and MCP

**Files:**
- Modify: `engine/src/protocol.rs`, `engine/src/ipc.rs`, `cli/src/main.rs` (`USAGE`, the parse arms) and `cli/src/mcp.rs`
- Test: the existing protocol and ipc tests, and `cli` tests (follow the queue-command tests added in commit `f717fa1`)

**Interfaces:**
- Consumes: `best_time`, `best_time_queue`, `run_speed_test` and `last_speed_test` (Tasks 4 and 5)
- Produces:
  - Requests:
    - `Request::Speed`, which returns the last test and the recommendation
    - `Request::SpeedTest { #[serde(default)] force: bool }`
    - `Add` gains `#[serde(default)] best_time: bool`. When true, the queue is `best_time_queue()`, and `queue` is ignored.
  - CLI:
    - `dl speed`, which prints, for example, `last test 92 Mb/s, 14 ms, 2 h ago` and `best time 01:00–05:00, usually 310 Mb/s (14 days, high)`, or `not enough data: 3 of 7 days`
    - `dl speed test [--force]`
    - `dl add --best-time <url…>`
  - MCP:
    - `speed_test` (`force` optional)
    - `best_time`
    - `add_downloads` gains `best_time` (bool)
- Keep the comment in `protocol.rs` that explains why settings and clearing aren't exposed, and extend it to the speed settings.

- [ ] **Step 1:** Write the failing serde round-trip tests for the new requests. Then add an ipc test, `speed_reports_not_enough_data` (a fresh store gives NotEnoughData with days 0), a CLI parse test for `add --best-time`, and an MCP `tools/list` test that includes `speed_test` and `best_time`.
- [ ] **Step 2:** Run `cargo test -q -p dl-cli` and the engine lib tests. They fail.
- [ ] **Step 3:** Implement the requests, CLI commands and MCP tools.
- [ ] **Step 4:** `cargo test -q -p dl-cli` passes, `--lib` passes, and clippy is clean for `dl-engine` and `dl-cli`.
- [ ] **Step 5:** Commit `dl and MCP: speed test, best time`.

### Task 7: App, speed card, Speed page, best-time flows

**Files:**
- Create: `macos/Sources/Rays/SpeedPage.swift` and `macos/Sources/Rays/SpeedCard.swift`
- Modify:
  - `EngineModel.swift` (state and wrappers)
  - `Sidebar.swift` and `ContentView.swift` (`Destination.speed`, routing, `lastFolder = "speed"`)
  - `AddBar.swift` (the split menu item)
  - `QueuePage.swift` / `ScheduleTab.swift` (Use best time, Follow best time)
  - `JobRow.swift` (the slow hint)
  - `Info.plist` (no change expected)

**Interfaces:**
- Consumes: `bestTime()`, `bestTimeQueue()`, `runSpeedTest(force:)`, `lastSpeedTest()`, `speedSettings()`, `setSpeedSettings(_:)`, `startNightWeek()` and `clearSpeedHistory()`, as named by UniFFI. Grep the generated `dl_engine.swift` for the exact Swift names.
- Produces:
  - `EngineModel.bestTime: BestTime?`, refreshed at launch, after each test, and every 30 min.
  - `EngineModel.lastTest: SpeedTestResult?`
  - `EngineModel.testing: Bool`

UI, per the spec's App section:
- **SpeedCard** sits at the bottom of the sidebar, below Folders, and is always visible.
  - It shows a `gauge.with.dots.needle.67percent` tile in teal, then "92 Mb/s · 2 h ago" (or "No test yet"), then a round glass **Run test** button (`play.fill`).
  - While a test runs, the button shows a `ProgressView` ring.
  - Clicking the card selects `Destination.speed`.
  - Show Mb/s as `bps*8/1_000_000`, with no decimals at 100 or more and one decimal below that.
- **SpeedPage:**
  - The top shows the last result, with `.largeTitle` monospaced digits and the latency.
  - **Run test** is `.glassProminent`.
  - A Swift Charts `BarMark` per hour, typical speed for hours 0–23, from `hourly_typical()` (Task 5). Bars inside the best window are accent-coloured; the rest are secondary.
  - The recommendation text, for example "Usually fastest 01:00–05:00 · 14 days", or the empty state `EmptyState(symbol: "chart.bar", title: "Not enough data yet", message: "N of 7 days. Rays learns from your downloads and speed tests.")` with a **Test at night for a week** button when the night prompt was answered "Not now".
  - A Settings section:
    - a **Test automatically every 3 hours** switch, captioned "Uses about 50 to 200 MB per test"
    - **Clear speed history…**, which asks for confirmation before clearing
- **Expensive network:** Run test on an Expensive network first shows a confirm with the exact text "You're on a hotspot or metered connection. A test uses about 50 to 200 MB." and the buttons **Run Test** and **Cancel**.
- **Unsaved result:** a result with `saved == false` shows "Downloads were running, so this result wasn't saved".
- **AddBar:** the split menu gains **At best time (01:00–05:00)**, or **At best time (01:00–06:00, default)** without data. Choosing it adds the downloads through `bestTimeQueue()`. The first time, when `night_prompt_answered` is false, it first shows an alert with the exact prompt text and the buttons **Allow** (calls `startNightWeek()`) and **Not Now** (sets `night_prompt_answered`). Either way, the add then goes ahead.
- **Schedule tab:**
  - A **Use best time** button (`sparkles`) next to Start at fills `start_min` and `stop_min` into the draft. When there's `NotEnoughData`, it is disabled, with `.help("Not enough speed data yet")`.
  - When `follow_best_time` is true, a **Follow best time** switch is on, with the caption "Rays moves this schedule to your fastest hours once a day". Turning it off or on saves straight away, like Enabled.
  - The Best time queue's schedule caption shows "Default night window until Rays has 7 days of speed data" when there's `NotEnoughData`.
- **JobRow hint:** when the Global Constraints' slow-hint rule holds (compare the job's `bytesPerSec` against `bestTime.typical_bps`), the status line shows "Usually N× faster at 01:00", with a small **Move to Best time** button. That button calls the existing move-to-queue path with `bestTimeQueue()`. A per-job dismiss (`xmark`) is stored only in memory.

- [ ] **Step 1:** Implement.
- [ ] **Step 2:** `swift build --package-path macos` prints Build complete!.
- [ ] **Step 3:** Commit `App: speed card, Speed page, best time flows`. The controller checks the GUI by hand: the card, the page, a test run, the add menu item, the night prompt, Use best time and the Follow switch.

### Task 8: Docs

**Files:**
- Create: `site/src/content/docs/docs/app/speed.md`
- Modify:
  - `site/astro.config.mjs` (a sidebar entry after Queues, with icon key `speed`, plus an icon added in `site/src/components/docs/icons.ts`)
  - `site/src/content/docs/docs/app/queues.md` (the Best time queue, Use best time, Follow best time)
  - `site/src/content/docs/docs/features.md`
  - `site/src/pages/features.astro` (the Queues & schedules group gains Speed test and Best time)
  - `site/src/pages/index.astro` (one line in the Queues passage)
  - `site/src/content/docs/docs/mcp.md`
  - `site/src/content/docs/docs/dl.md`
  - `site/public/llms.txt`

- [ ] **Step 1:** Write the pages in the existing voice, describing the final UI, and say plainly that the data stays on the Mac.
- [ ] **Step 2:** `cd site && npm run build` succeeds.
- [ ] **Step 3:** Commit `Docs: speed test and best time`.
