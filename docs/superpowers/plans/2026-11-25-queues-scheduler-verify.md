# Queues, Scheduler and Model Verify Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Named download queues with per-queue limits and schedules (time windows, conditions, when-finished actions, optional wake), plus offline verification of downloaded Hugging Face models.

**Architecture:** The Rust engine owns queues: a SQLite table, per-queue concurrency and rate limits, a schedule evaluator, and queue events. The Swift app reports conditions and performs OS actions: wake, sleep, shut down, lock, sound, quit, run command. Verification uses a `.rays-model.json` manifest that the engine writes in `add_hf`, and an engine `verify_files` call.

**Tech Stack:** Rust (tokio, rusqlite, UniFFI, sha2, new `chrono` with `clock` for local-time windows), SwiftUI on macOS 26 (Network.framework `NWPathMonitor`, IOKit power sources, CGEventSource idle, AppleScript for admin and shut down).

**Spec:** `docs/superpowers/specs/2026-11-25-queues-scheduler-verify-design.md`. Read its **Design** and **Answers to the builder check** sections; they are binding.

## Global Constraints

- **Main queue:** id `1`, named `Main queue`. It can't be deleted. Every existing and new job defaults to queue 1.
- **Queue `max_running`:** `0` means "Same as Rays" (the global "Downloads at once"). The global value stays the overall cap, and a queue can never exceed it.
- **Windows:** use local time. A stop at or before start means the next day. With On days, the day the window starts owns it.
- **Held jobs:** they are `Queued` with a derived waiting reason. They are never `Paused`, and the UI says "Waiting for schedule", "Waiting for Wi-Fi", "Waiting for charger", "Waiting for idle" or "Queue stopped".
- **QueueFinished:** fires only at the end of a run that started at least one job. Paused jobs count as remaining.
- **Conditions:** they count as not met until the app's first `set_conditions`.
- **Wake permission:** the file `/etc/sudoers.d/rays-wake` contains exactly `<user> ALL=(root) NOPASSWD: /usr/bin/pmset schedule wake *, /usr/bin/pmset schedule cancel wake *`, with mode 0440, owner root:wheel, validated with `visudo -cf` and deleted if invalid. Wake is off by default.
- **Copy:**
  - "Rays starts this queue at HH:MM if your Mac is awake and Rays is running."
  - Run command note: "Runs as your user account".
  - Countdown before Sleep, Shut down and Quit: 30 s, cancellable.
- **Conditions:**
  - Wi-Fi means `.wifi` and not `isExpensive`.
  - Idle means ≥ 300 s since last input, checked every 30 s.
- **Verify:** files without a published sha256 are checked by size only, labelled "size checked".
- **Commands:**
  - `cargo test -q -p dl-engine --lib`
  - `cargo test -q -p dl-engine --test <name>`
  - `cargo clippy -p dl-engine --all-targets -- -D warnings`
  - `scripts/build-engine.sh` after exported-type changes
  - `swift build --package-path macos`, which must print `Build complete!`
  - Use `grep`, not `rg`: a shell hook breaks `rg`.
- Commit trailer: a blank line, then `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

- **Window across midnight on a day boundary.** Fri 22:00–06:00 is open Sat 03:00 and closed Sat 22:00. Test in Task 2.
- **DST change night.** A 02:00 start on a spring-forward day must still run once (at the first valid local time) and not crash. Test in Task 2.
- **App restart mid-window.** On engine start, a queue whose window is open resumes its queued jobs, and the run's `started_any` flag resets so a stale QueueFinished never fires. Test in Task 3.
- **Shut down guard.** Pausing every job in a running queue must not emit QueueFinished. Test in Task 3.
- **Sudoers safety.** A file that fails `visudo -cf` is never left in `/etc/sudoers.d`. The script orders write → chmod → validate → delete-on-fail. Tested by a script dry run in Task 7.

---

## Stage A: Queues

### Task 1: Queue storage and types

**Files:**
- Modify:
  - `engine/Cargo.toml`: add `chrono = { version = "0.4", default-features = false, features = ["clock"], optional = true }` under `full`
  - `engine/src/types.rs`
  - `engine/src/store.rs`
- Create: `engine/src/queue.rs` (types, and later schedule logic); declare it in `lib.rs` behind `full`
- Test: `engine/src/store.rs` tests

**Interfaces (Produces):**
- `#[derive(uniffi::Enum)] pub enum Repeat { Once { date: String /* YYYY-MM-DD */ }, Daily, Days { mask: u8 /* bit0 = Mon … bit6 = Sun */ } }`
- `#[derive(uniffi::Enum)] pub enum FinishAction { Nothing, Sound, Quit, Sleep, Lock, ShutDown, Command { command: String } }`
- `#[derive(uniffi::Record)] pub struct QueueSchedule { repeat: Repeat, start_min: u16 /* minutes since midnight */, stop_min: Option<u16>, wifi: bool, power: bool, idle: bool }`
- `#[derive(uniffi::Record)] pub struct QueueConfig { id: Option<u64>, name: String, max_running: u32, speed_limit: u64, enabled: bool, schedule: Option<QueueSchedule>, retry_failed: bool, wake: bool, when_finished: FinishAction }`
- `Store::{queues() -> Vec<QueueConfig + held: bool>, save_queue(&QueueConfig) -> u64, delete_queue(id), set_held(id, bool)}`
- Migrations, appended:
  - a `queues` table holding all `QueueConfig` fields plus `held INTEGER NOT NULL DEFAULT 0`, with schedule and action stored as JSON text
  - `INSERT INTO queues … (1, 'Main queue', …)`
  - `ALTER TABLE jobs ADD COLUMN queue_id INTEGER NOT NULL DEFAULT 1`
- `Job.queue_id: u64`, persisted

- [ ] **Step 1: Failing tests**
  - `main_queue_exists_after_migration`: a fresh store has `queues()[0].id == Some(1)` and the name `Main queue`.
  - `queue_round_trip`: save a queue with `Days{mask: 0b0011111}`, start 120, stop 450, `wifi: true` and `Command{"echo hi"}`, reopen the store, and it is equal. `set_held(id, true)` persists.
  - `jobs_default_to_main`: an old job row loads with `queue_id == 1`.
  - `delete_moves_jobs_to_main`: delete queue 2, and its jobs now have `queue_id == 1`. Deleting 1 returns an error.
- [ ] **Step 2:** `cargo test -q -p dl-engine --lib store::` fails.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** The tests pass and clippy is clean.
- [ ] **Step 5:** Commit `Engine: queue storage, Main queue, job queue_id`.

### Task 2: Schedule evaluation (pure)

**Files:** Modify `engine/src/queue.rs`. Unit tests go in the same file.

**Interfaces (Produces):**
- `pub fn window_open(s: &QueueSchedule, now: chrono::NaiveDateTime) -> bool`
- `pub fn next_start(s: &QueueSchedule, now: chrono::NaiveDateTime) -> Option<chrono::NaiveDateTime>`: the next window opening strictly after `now`. It is `None` for `Once` in the past.
- `pub fn window_end(s: &QueueSchedule, opened: chrono::NaiveDateTime) -> Option<chrono::NaiveDateTime>`
- Callers convert to and from `chrono::Local` and unix seconds. When converting a `NaiveDateTime` that falls in a DST gap, use `Local.from_local_datetime(..).earliest()`, else `latest()`, else add one hour.

- [ ] **Step 1: Failing tests**
  - `daily_window`: 02:00–07:30 is open at 03:00, closed at 08:00, and closed at 01:59.
  - `no_stop_stays_open`: a daily 02:00 window with no stop is open at 23:59 the same day and closed at 01:59 the next day.
  - `cross_midnight_days`: Fri 22:00–06:00 is open Sat 03:00, closed Sat 22:00, and closed Thu 23:00.
  - `once_date`: `Once{"2026-12-01"}` 01:00–02:00 opens only on that date. `next_start` after it is `None`.
  - `next_start_days`: from Fri 08:00, a Mo–Fr 02:00 schedule's next start is Mon 02:00.
  - `dst_gap_does_not_panic`: `next_start` across 2027-03-14 02:30 (US spring forward), converted with the documented helper, returns a valid instant.
- [ ] **Step 2:** `cargo test -q -p dl-engine --lib queue::` fails.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** The tests pass.
- [ ] **Step 5:** Commit `Engine: queue schedule windows`.

### Task 3: Scheduler: queue gating, limits, holds, runs, events

**Files:**
- Modify:
  - `engine/src/scheduler.rs`
  - `engine/src/download.rs` (per-queue limiter)
  - `engine/src/limit.rs`
  - `engine/src/types.rs`
  - `engine/src/api.rs`
  - `engine/src/ipc.rs` and `engine/src/protocol.rs`: `Add { urls, #[serde(default)] queue: Option<u64> }`
- Test: create `engine/tests/queues.rs`, reusing the server helpers pattern from `tests/hf.rs` and `tests/download.rs`

**Interfaces:**
- **Consumes:** Tasks 1 and 2.
- **Produces:**
  - `RateLimiter::with_parent(rate: u64, parent: Arc<RateLimiter>) -> RateLimiter`. Its `acquire` waits on both. `download::run` keeps its single `limiter` parameter and receives the queue's chained limiter.
  - `JobView.queue_id: u64` and `JobView.waiting: Option<String>`. `waiting` is one of the Global Constraints strings when a Queued job is held.
  - `#[derive(uniffi::Enum)] pub enum QueueState { Open, WaitingForTime { next: i64 }, WaitingForCondition { missing: Vec<String> }, Stopped, Off }`
  - `#[derive(uniffi::Record)] pub struct QueueView { config: QueueConfig, state: QueueState, queued: u32, running: u32, total_bytes: u64, next_run: Option<i64> }`
  - `JobEvent::QueueChanged { queue: QueueView }` and `JobEvent::QueueFinished { id: u64 }`
  - `Engine`:
    - `queues()` and `save_queue(config) -> Result<u64, EngineError>`
    - `delete_queue(id)` and `move_to_queue(job: JobId, queue: u64)`
    - `stop_queue(id)` and `start_queue(id)`
    - `run_queue_now(id)`
    - `set_conditions(wifi: bool, on_power: bool, idle: bool)`
  - `add_to(.., queue: Option<u64>)` and `add_hf(.., queue: Option<u64>)`. Update every caller, including the Swift wrappers (pass `nil`).
- **Rules** (implement them exactly as the spec's Design and Answers say):
  - `start_next` picks the first Queued job whose queue is Open and has a free slot under `min(queue.max_running or global, global)`, and the global cap is still respected.
  - A queue that stops being Open holds its running jobs. Use the same cancel path as pause, but set them to `Queued`, not `Paused`, so their segments are kept.
  - A 30 s tokio interval re-evaluates every queue. So do `set_conditions`, `save_queue`, `start_queue`/`stop_queue` and `run_queue_now`.
  - `run_queue_now` sets an in-memory override that keeps the queue Open until its run finishes.
  - A `Once` queue sets `enabled = false` when its run finishes or its window closes.
  - `retry_failed`: when a window opens, or on Start or Run now, the queue's Failed jobs are set to Queued once per run.
  - Run tracking is in memory. `started_any` is set when a job starts, and QueueFinished is emitted when nothing in the queue is Queued, Running, Retrying, Verifying or held. After an engine restart, a new run begins fresh.

- [ ] **Step 1: Failing tests** (`tests/queues.rs`)
  - `per_queue_concurrency`: with a queue whose `max_running` is 1 and three slow jobs, at most one runs at a time. With global 2 and `max_running` 0, two run.
  - `stopped_queue_holds_and_starts`: `stop_queue` turns a running job into Queued with waiting "Queue stopped". `start_queue` makes it run again and resume from its saved progress, not 0.
  - `conditions_gate`: a queue with `wifi: true` holds until `set_conditions(true, ..)`, then starts. `set_conditions(false, ..)` holds it again, with waiting "Waiting for Wi-Fi".
  - `finished_fires_once`: two jobs finish, and exactly one QueueFinished event arrives.
  - `pausing_all_does_not_finish`: pause every job, and no QueueFinished arrives.
  - `restart_mid_run_no_stale_finish`: start a job, restart the engine, and it finishes with exactly one QueueFinished for that run.
  - `move_to_closed_queue_holds`
  - `per_queue_speed_limit`: a queue limited to 200 KB/s takes at least about 0.9 s for 256 KB. Use generous bounds.
  - `ipc_add_with_queue`: the CLI request JSON with `"queue": 2` lands in queue 2. Old JSON without the field lands in 1.
  
  Time-window behaviour is covered by Task 2. For an integration check, inject a clock: give `Scheduler` a `now: Arc<dyn Fn() -> NaiveDateTime + Send + Sync>`, with `chrono::Local::now().naive_local()` as the default and a test setter, and add a test `window_close_holds_running` that moves the clock past the stop time and ticks.
- [ ] **Step 2:** The tests fail.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:**
  - `cargo test -q -p dl-engine --test queues` passes, and `--test download`, `--test hf` and `--test engine` still pass. A known flaky test is `shared_bandwidth_limit_removes_a_failed_probe`.
  - Clippy is clean.
  - Run `scripts/build-engine.sh`, then `swift build`: fix the Swift call sites only as needed to compile, passing `nil` for the queue.
- [ ] **Step 5:** Commit in 2–3 logical commits.

## Stage B: App

### Task 4: App plumbing: queue API and conditions monitor

**Files:**
- Modify: `macos/Sources/Rays/EngineModel.swift`
- Create: `macos/Sources/Rays/ConditionsMonitor.swift`

**Interfaces:**
- **Produces:**
  - `EngineModel.queues: [QueueView]` (observable), kept current from `QueueChanged` events and loaded at start.
  - `onQueueFinished: ((UInt64) -> Void)?`, a hook used by Task 7.
  - Wrappers: `saveQueue`, `deleteQueue`, `moveToQueue`, `stopQueue`, `startQueue` and `runQueueNow`. `add(_ text:, queue:)` and `addModel(..., queue:)` take a queue id.
- **`ConditionsMonitor`:**
  - It starts with the engine and calls `setConditions` on every change and every 30 s.
  - Wi-Fi comes from `NWPathMonitor`: `usesInterfaceType(.wifi) && !isExpensive`.
  - Power comes from `IOPSCopyPowerSourcesInfo` and `IOPSGetProvidingPowerSourceType == kIOPMACPowerKey`, so a desktop Mac counts as on power.
  - Idle is `CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .null) >= 300`.

- [ ] **Step 1:** Implement.
- [ ] **Step 2:** Build. `swift build` prints `Build complete!`.
- [ ] **Step 3: Manual check.** Bundle and launch, turn Wi-Fi off and on, and confirm in the log that `setConditions` fired. Log with `os_log` at debug level, never the token.
- [ ] **Step 4:** Commit `App: queue API and conditions monitor`.

### Task 5: Queues in the sidebar and lists

**Files:**
- Modify:
  - `Sidebar.swift`: add `Destination.queue(UInt64)`
  - `ContentView.swift`: Downloads page filtered by queue, plus the queue header
  - `JobRow.swift`: waiting text, and the "Move to Queue" submenu
  - the paste box Download button menu
  - `ModelDetailView.swift` bottom bar: queue picker
- Create: `QueueHeader.swift` if it helps.

**Spec items:**
- **Sidebar section "Queues"**, under the Rays section: one row per queue.
  - The icon is `list.bullet` for Main and unscheduled queues, `clock` for scheduled ones.
  - The trailing badge is the running count with a blue dot, or `HH:mm` of the next run when waiting.
  - A `+` button creates "New queue" and opens the scheduler sheet (Task 6).
  - The context menu has Schedule…, Start/Stop queue, Run now, and Delete for non-Main queues, which confirms first.
- **Queue page:** the same list as Downloads, filtered to `queueId`. The header shows the name, then "N items · M downloading · size total", then **Stop queue** or **Start queue**, then **Schedule…**.
- **Rows:** the status line shows `waiting` text when present, in secondary text with `clock` symbol.
- **Moving and picking a queue:**
  - The ⋯ menu and right-click menu get **Move to Queue ▸** with the queues listed; the current one is checked.
  - The paste box's Download button becomes a split: a menu lists the queues, and the default is Main.
  - The Models bottom bar gets a queue `Menu` pill before Download. It defaults to Main, or a queue named "Hugging Face" if one exists.

- [ ] **Step 1:** Implement.
- [ ] **Step 2:** Build.
- [ ] **Step 3: Manual check.** Create a queue, move a download into it, stop and start it, and check the sidebar badge.
- [ ] **Step 4:** Commit `App: queues in the sidebar, queue pages, move to queue`.

### Task 6: Scheduler sheet

**Files:** create `macos/Sources/Rays/SchedulerSheet.swift`. Split it into sibling files if it grows past ~400 lines.

**Spec:** the spec's "Scheduler sheet" bullet, verbatim. Specific choices:
- **Sheet:** 760×560 minimum.
- **Queue list:** the left column is a `List` with selection. "+ New queue" is at the bottom.
- **Editor header:**
  - the name `TextField`, then a Next run pill ("Next run <date time>" in `.callout`, glass capsule, `clock` icon; "Not scheduled" when off), then the enabled `Toggle(.switch)`
  - a segmented `Picker` for **Schedule | Files**; Files lists the queue's downloads using JobRow
- **Repeat:** a segmented Once / Every day / On days. Once shows a `DatePicker(.date)`. On days shows seven glass toggle pills Mo–Su.
- **Times:**
  - Start at is a `DatePicker(.hourAndMinute)`.
  - Stop at is a checkbox plus a picker, with the note "Unfinished files pause and continue next time".
- **Simultaneous:** a stepper from 0 to the global cap. 0 shows "Same as Rays".
- **Speed limit:** a menu of `SpeedPreset.all`.
- **Conditions:** three checkboxes, "Only on Wi-Fi (not a phone hotspot)", "Only while charging" and "Only when the Mac is idle".
- **Options:**
  - "Retry failed downloads".
  - "Wake the Mac to start": toggling it on calls Task 7's `WakePermission.ensure()`, and the toggle stays off if that is declined or fails. When the permission exists, a "Remove wake permission" button sits beside it.
- **When finished:** a 4-column grid of 7 glass tiles (Do nothing `minus`, Play sound `speaker.wave.2`, Quit Rays `xmark`, Sleep `moon.zzz`, Lock screen `lock`, Shut down `power`, Run command `terminal`). The selected tile is accent-tinted. Run command reveals a `TextField` plus the note "Runs as your user account".
- **Awake note:** the note under Start at uses the Global Constraints copy. It is hidden when wake is on and the permission exists.
- **Footer:** Run now, Delete queue in red (not for Main, confirms first), Revert, and **Save schedule** (`.glassProminent`, disabled until something changes).
- **Validation:** Save is disabled when Repeat is On days with no day selected.

- [ ] **Step 1:** Implement.
- [ ] **Step 2:** Build.
- [ ] **Step 3: Manual check.** Create "Night downloads", Mo–Fr 02:00–07:30, and save. The sidebar badge shows `02:00`, and Next run shows the correct date.
- [ ] **Step 4:** Commit `App: scheduler sheet`.

### Task 7: When-finished actions and the wake flow

**Files:** create `macos/Sources/Rays/QueueActions.swift` (finish actions plus countdown) and `macos/Sources/Rays/WakePermission.swift`. Modify `SettingsView.swift` (a Remove wake permission row) and `EngineModel.swift` (hook `onQueueFinished`).

**Interfaces (Produces):**
- `enum WakePermission { static var isInstalled: Bool; static func ensure() async -> Bool; static func remove() async -> Bool; static func schedule(queue: UInt64, at: Date) -> Bool; static func cancel(queue: UInt64) }`
  - `isInstalled` checks `sudo -n /usr/bin/pmset schedule cancel wake "01/01/30 00:00:00"` (exit 0 or 1 both mean it's allowed), or checks the file exists and `sudo -n -l /usr/bin/pmset` succeeds.
  - `ensure()` shows the explainer alert (Not Now / Continue…). On Continue it runs the install script through `NSAppleScript` "do shell script … with administrator privileges".
  - `schedule` and `cancel` use `sudo -n /usr/bin/pmset schedule wake "MM/dd/yy HH:mm:ss"`, 60 s before the run, and record the scheduled dates in UserDefaults `wakeTimes.<queue>` so Rays only cancels its own wakes.
  - `remove()` cancels every recorded wake, then runs `rm -f /etc/sudoers.d/rays-wake` with administrator privileges.
- **Install script:**
  ```
  f=/etc/sudoers.d/rays-wake; t=$(mktemp)
  printf '%s ALL=(root) NOPASSWD: /usr/bin/pmset schedule wake *, /usr/bin/pmset schedule cancel wake *\n' "$USER_NAME" > "$t"
  /usr/sbin/visudo -cf "$t" && /usr/sbin/chown root:wheel "$t" && /bin/chmod 0440 "$t" && /bin/mv "$t" "$f" || { /bin/rm -f "$t"; exit 1; }
  ```
  Here `USER_NAME` is passed safely: a quoted-form literal of `NSUserName()` that has been validated as matching `^[A-Za-z0-9._-]+$`, and refused otherwise.
- **Rescheduling:** after any `saveQueue` or `QueueChanged` for a queue with `wake == true`, Rays reschedules the wake for its `next_run`.
- **`QueueActions.perform(_ action: FinishAction)`:**
  - Sound: `NSSound(named: "Glass")?.play()`.
  - Sleep: `/usr/bin/pmset sleepnow`.
  - Lock: `/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession -suspend` if it exists, else the `SACLockScreenImmediate` fallback through the login framework. Pick the one that works on macOS 26 and say which in the report.
  - Shut down: `NSAppleScript` `tell application "System Events" to shut down`. Before the first use, explain the Automation permission once.
  - Quit: `NSApp.terminate(nil)`.
  - Command: `/bin/zsh -lc <command>`, with output going to the app log.
  - Sleep, Shut down and Quit first post a 30 s countdown: a `UNUserNotification` with a Cancel action, plus an in-app banner with Cancel. The action runs only if it isn't cancelled.
- **Settings > Downloads:** a "Wake permission" row showing Installed or Not set up, with **Remove wake permission** when installed.

- [ ] **Step 1: Install-script dry-run check.** Add a debug-only helper that runs the script with `f` pointed at a temp path and `visudo` replaced by `/usr/bin/false`. Assert the temp target doesn't exist afterwards. Run it once from a scratch Swift script and include the output in the report. Don't ship the helper.
- [ ] **Step 2:** Implement.
- [ ] **Step 3:** Build.
- [ ] **Step 4: Manual check by the controller,** not the implementer: enable wake on a test queue, enter the password once, save twice with no prompt the second time, then Remove.
- [ ] **Step 5:** Commit `App: when-finished actions and one-time wake permission`.

## Stage C: Verify

### Task 8: Engine manifest and verify

**Files:** modify `engine/src/hf.rs`, `engine/src/scheduler.rs` (`add_hf` writes the manifest) and `engine/src/api.rs`. Test in `engine/tests/hf.rs`.

**Interfaces (Produces):**
- **Manifest:** `<dest>/.rays-model.json`, as `{ "repo": String, "sha": String, "files": [{ "path", "size", "sha256": String|null }] }`. `add_hf` merges by path. Write it to a temp file and rename it into place.
- `#[derive(uniffi::Enum)] pub enum VerifyStatus { Ok, SizeChecked, Missing, WrongSize { actual: u64 }, WrongChecksum }`
- `#[derive(uniffi::Record)] pub struct VerifyResult { path: String, status: VerifyStatus }`
- `Engine::read_model_manifest(dir: String) -> Option<HfManifest>` (`HfManifest { repo, sha, files: Vec<HfFile> }`)
- `Engine::verify_files(dir: String, files: Vec<HfFile>) -> Vec<VerifyResult>`: async, hashing on the blocking pool, files in parallel up to 2 at a time.

- [ ] **Step 1: Failing tests**
  - `add_hf_writes_manifest`: the file appears after `add_hf`. A second `add_hf` for another file of the same repo merges into the same manifest.
  - `verify_reports_each_status`: covers Ok, SizeChecked (no hash), Missing, WrongSize and WrongChecksum.
  - `manifest_paths_are_safe`: a manifest entry with `../x` is reported as Missing and nothing outside `dir` is read.
- [ ] **Step 2:** The tests fail.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** The tests pass and clippy is clean. Run `scripts/build-engine.sh` and then `swift build`.
- [ ] **Step 5:** Commit `Engine: model manifest and offline verify`.

### Task 9: Verify in the Downloaded tab

**Files:** modify `macos/Sources/Rays/DownloadedModelsView.swift` (or wherever the Downloaded tab lives) and `EngineModel.swift` (wrappers).

**Spec:** the spec's "Verify Hugging Face models" section. Specific choices:
- **Starting a verify:** a **Verify** button (`checkmark.shield`) appears on row hover and in the ⋯ menu. While it runs, the trailing button becomes a `ProgressView` ring.
- **Results** expand under the row:
  - "✓ All N files match" (green)
  - "N files checked by size only" (secondary)
  - Each problem as `path — Missing | Wrong size | Checksum didn't match` (red), followed by **Re-download N files**. That button calls `addModel(repo:sha:files:to:)` with just those files and the same folder. If the replace setting is off, it first moves the bad files to the Trash so the names stay exact.
- **No manifest:** the row shows "Can't verify: no record of this download". **Look up on Hugging Face** calls `hfModel("<org>/<model>")` and verifies against that file list, with the note "Checked against the latest revision".

- [ ] **Step 1:** Implement.
- [ ] **Step 2:** Build.
- [ ] **Step 3: Manual check.** Download a small model file, verify it (✓). Then corrupt one byte with `printf x | dd of=… bs=1 seek=0 conv=notrunc`, verify again (checksum error), and Re-download.
- [ ] **Step 4:** Commit `App: verify downloaded models`.

### Task 10: Docs

**Files:**
- Create `site/src/content/docs/docs/app/queues.md`, covering:
  - queues
  - the scheduler
  - conditions
  - when finished
  - wake: off by default, the one-time password and Remove permission, and the awake note
- Modify `site/src/content/docs/docs/app/models.md` (Verify) and `site/astro.config.mjs` (sidebar entry after Downloads, with an icon key `queues`), and add `queues` to the docs `ICONS`.

- [ ] **Step 1:** Write the pages in the existing voice, with no em dashes.
- [ ] **Step 2:** `cd site && npm run build` succeeds.
- [ ] **Step 3:** Commit `Docs: queues, scheduler, model verify`.
