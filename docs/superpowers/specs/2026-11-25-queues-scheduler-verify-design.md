# Queues, scheduler and model verify

Status: approved (2026-11-25)

## Intent

People who download big files want control over when and how fast they download. Examples: overnight on Wi-Fi, only a few files at a time, and a heavy model batch that doesn't starve everything else. People downloading AI models also want proof the weights on disk are intact. The user provided two reference screenshots, of another download manager's queues view and its scheduler dialog. Rays follows their structure in its own look.

## Goals

- **Queues.** Named queues, each with its own number of simultaneous downloads, speed limit and optional schedule. Every download belongs to exactly one queue. **Main queue** is the default.
- **Scheduler, per queue:**
  - Repeat: Once, Every day, or On days (Mo–Su).
  - Start at, with an optional Stop at. Files still unfinished when it stops pause and continue at the next run.
  - Conditions: Only on Wi-Fi (not a hotspot), Only while charging, Only when the Mac is idle.
  - Retry failed downloads.
  - When finished: Do nothing, Play sound, Quit Rays, Sleep, Lock screen, Shut down, Run command.
  - Next run label, on/off switch, Run now, Delete queue.
- **Wake.** Off by default. When the user turns on "Wake the Mac to start", Rays explains why, asks for the administrator password once, and installs a narrow permission. From then on it schedules wakes silently. A **Remove wake permission** button undoes it.
- **Verify Hugging Face models.** Rays saves a manifest when it downloads a model, and the Downloaded tab can verify every file against it offline.

## Non-goals

- A sidebar like the reference's (categories with counts, Grabber, Trash). Rays keeps its own sidebar and adds a Queues section.
- Per-connection map, speed graph and detail panes from the reference.
- Hibernate. macOS has no separate user-facing hibernate.
- Waking the Mac without the user's one-time approval. Wake through a privileged helper (SMAppService) waits until Rays has a Developer ID.
- Recurring schedules finer than days of the week. Bandwidth limits by time of day, apart from per-queue limits.

## Anti-goals

- Rays must never ask for the password more than once for wake, and must never gain any root ability beyond scheduling or cancelling wakes.
- A queue's schedule must not stall downloads in other queues.
- Stop at must never lose progress. It pauses, which is resumable.
- Run command must never run without the user typing it. Nothing is preset.

## Constraints (from the code today)

- **Global limits.**
  - The scheduler has one global `max_running` (`scheduler.rs:30`) and one global `RateLimiter` (`limit.rs`).
  - Jobs start in `start_next` (`scheduler.rs:641`), which picks the first `Queued` job.
  - States are `Queued`, `Running`, `Paused`, `Retrying`, `Verifying`, `Done` and `Failed`.
  - Events are `Upsert` and `Removed`.
- **Persistence.**
  - SQLite migrations are append-only (`store.rs` `MIGRATIONS`).
  - Jobs have `dir`, `fixed_name` and `sha256` (HF work).
  - Settings like the speed limit and max running live in the app's UserDefaults and are pushed to the engine at start.
- **App.**
  - The sidebar is `Destination` in `Sidebar.swift`, with Models shown as a child row under Downloads.
  - The Downloads list is in `ContentView.swift`.
  - Downloads settings are in `SettingsView.swift` `DownloadsTab`.
- **HF downloads.** These go through `add_hf`, with per-file checksums known at add time (`HfFile.sha256`).

## Approaches

- **A. The engine owns queues and schedules (picked).**
  - New `queues` table.
  - `Job.queue_id`.
  - Per-queue concurrency and rate limiters inside the scheduler, plus a schedule evaluator tick.
  - The app reports conditions (Wi-Fi, charging, idle) to the engine, and performs the OS-level actions: wake, sleep, shut down, lock, sound, quit, run command. It does this when the engine emits a queue-finished event.
  - Upside: schedules survive restarts and work for CLI- and MCP-added jobs. The engine is where concurrency already lives.
- **B. The app owns queues.** It keeps jobs paused and resumes them per its own schedule. That means a smaller engine change, but concurrency and speed per queue can't be enforced without the engine. The CLI and MCP couldn't use queues, and state would be split across two places.
- **C. Queues only as tags, with a global scheduler.** This is simplest, but it fails the reference's core idea that each queue has its own concurrency, speed and schedule.

The user asked for queues *and* a scheduler like the reference, and A is the only approach that delivers per-queue limits.

## Design

### Engine

- **Queue record**, stored in a new `queues` table:
  - id and name
  - `max_running` (default 3) and `speed_limit` (0 = none)
  - enabled
  - repeat: once, daily, or days bitmask
  - `start_at` minutes since midnight, optional `stop_at`, and a once-date for "Once"
  - conditions: wifi, power, idle
  - `retry_failed`
  - `when_finished`: an action enum plus an optional command string
  
  **Main queue** has id 1, is created by migration, can't be deleted, and has no schedule by default.
- **Assigning jobs.** `Job.queue_id`, default 1. Existing jobs migrate to 1. `add_to`, `add_hf` and the paste path take an optional queue id, and there's a new `move_to_queue(job, queue)`.
- **Starting jobs.** `start_next` respects the global `max_running` (now an overall cap) and the queue's `max_running`. It only starts jobs whose queue is **open**:
  - The queue is enabled.
  - It has no schedule, or now is inside a run window.
  - All of its conditions are met.
  
  Each queue has its own `RateLimiter`, chained under the global one.
- **Windows.**
  - A run window opens at `start_at` on a matching day and closes at `stop_at` (or never).
  - When a window closes, the queue's running jobs pause. They become `Queued`-but-held, not user-`Paused`, so they resume at the next window.
  - "Once" disables the queue after its window closes or the queue finishes.
  - **Run now** opens the window until the queue finishes.
- **Ticks and conditions.** A 30 s tick re-evaluates windows and conditions. `set_conditions(wifi: bool, on_power: bool, idle: bool)` from the app triggers an immediate re-evaluation. A queue that loses a condition holds its running jobs the same way a closing window does.
- **Retry failed.** When a window opens, the queue's Failed jobs go back to Queued once per run.
- **Events.**
  - `QueueChanged { queue: QueueView }`, where `QueueView` includes counts, state (open, waiting for time, waiting for condition, off) and the next run timestamp.
  - `QueueFinished { id }`, emitted when a queue with work runs out of queued and running jobs during a window.
- **API.** `queues() -> Vec<QueueView>`, `save_queue(QueueConfig) -> QueueId`, `delete_queue(id)` (its jobs move to Main), `run_queue_now(id)` and `stop_queue(id)`. Stop holds all of the queue's jobs until the next window or Run now.

### App

- **Sidebar.** A **Queues** section below Rays. Each row is the queue name with a trailing badge: active count (blue dot) or next start time ("02:00"). There's a **+** for a new queue. Selecting a queue shows the Downloads list filtered to it, with a header: name, "N items · M downloading · size total", **Start queue / Stop queue**, and **Schedule…**.
- **Assigning downloads.**
  - The download row's ⋯ menu gets **Move to Queue ▸**.
  - The paste box's Download button gets a menu for picking a queue.
  - The Models page Download button gets a queue picker in the bottom bar. It defaults to Main, or a queue named "Hugging Face" if one exists. Rays doesn't create that queue automatically.
- **Scheduler sheet**, opened from the queue header or the queue row's context menu. Layout as in the reference: a queue list on the left (Main, user queues, + New queue) and the editor on the right. The editor has:
  - name field, Next run pill and enabled switch
  - a Schedule tab and a Files tab (that queue's downloads)
  - Repeat (segmented: Once, Every day, On days), with day pills
  - Start at and Stop at (each a time picker; Stop at has a checkbox)
  - Simultaneous (stepper)
  - Speed limit (menu of the existing `SpeedPreset`s)
  - Conditions (three checkboxes)
  - Options: Retry failed downloads, Wake the Mac to start
  - When finished: a grid of 7 glass tiles. Run command shows a text field and the note "Runs as your user account".
  - Footer: Run now, Delete queue (not for Main), Revert, Save schedule
  - Below Start at: "Rays starts this queue at 02:00 if your Mac is awake and Rays is running." This hides once wake is set up and on.
- **Wake flow.** Turning on "Wake the Mac to start" without the permission shows the explainer alert (Not Now / Continue…). Continue runs, once, with administrator privileges, through `osascript … with administrator privileges`, a script that:
  - writes `/etc/sudoers.d/rays-wake` with exactly `<user> ALL=(root) NOPASSWD: /usr/bin/pmset schedule wake [0-9][0-9]/[0-9][0-9]/[0-9][0-9] [0-9][0-9]\:[0-9][0-9]\:[0-9][0-9], /usr/bin/pmset schedule cancel wake [0-9][0-9]/[0-9][0-9]/[0-9][0-9] [0-9][0-9]\:[0-9][0-9]\:[0-9][0-9]`
  - sets mode 0440, owner root:wheel
  - validates with `visudo -cf` and deletes the file if validation fails
  
  After that, saving or enabling a queue with Wake on runs `sudo -n /usr/bin/pmset schedule wake "MM/dd/yy HH:mm:ss"` for its next run, 1 minute early, and cancels the previous wake for that queue. Rays records which wake times it scheduled, in UserDefaults keyed by queue, so it only cancels its own.
  
  **Remove wake permission** appears in Settings > Downloads and next to the toggle in the sheet when the permission exists. It cancels Rays' scheduled wakes, then removes the file with one administrator prompt. If `sudo -n` fails (the file was removed outside Rays), the toggle shows "Permission missing — Set Up Again".
- **When-finished actions,** run by the app on `QueueFinished`:
  - Play sound: `NSSound(named: "Glass")`
  - Quit Rays: `NSApp.terminate`
  - Sleep: `pmset sleepnow`, which needs no root
  - Lock screen: `CGSession -suspend`, or the login-window lock call
  - Shut down: AppleScript `tell application "System Events" to shut down`, which needs Automation permission; the first use explains it
  - Run command: `/bin/zsh -lc <command>` as the user, with output logged, not shown
  
  Before Shut down, Sleep, or Quit, Rays shows a cancellable 30-second countdown notification ("Shutting down in 30 s — Cancel").
- **Conditions.** `NWPathMonitor` for Wi-Fi: interface type `.wifi` and not `isExpensive`, so hotspots don't count. `IOPSCopyPowerSourcesInfo` for charging. `CGEventSource.secondsSinceLastEventType` of at least 300 s for idle, checked every 30 s. Any change is pushed to `set_conditions`.
- **Status bar,** at the bottom of the Downloads list, as in the reference: "↓ speed · N active · M queued · <queue> running · Night downloads at 02:00". Kept short.

### Verify Hugging Face models

- **Manifest.** When `add_hf` adds files for a model, the app writes `.rays-model.json` into `<dest>/` with: repo, sha, and for each file its path, size and sha256 (where known). If the file already exists, entries are merged.
- **Downloaded tab.** Each model row gets **Verify**, also in its ⋯ menu. Verify hashes each listed file on a background task, using engine `verify_files(dir, entries) -> Vec<VerifyResult>`. That's the same hashing as the finish-time check, run on the blocking pool. A progress ring sits on the row.
- **Results,** in an inline expandable row section:
  - "✓ All N files match", or
  - a list of missing files, size mismatches and checksum mismatches, with a **Re-download N files** button. That button calls `add_hf` for just those files, into the same folder, with Replace for them.
  - Folders without a manifest (downloaded before this version) show "Can't verify: no record of this download" and a **Look up on Hugging Face** action. That fetches model info for `<org>/<model>` at `main` and verifies against it, with a note that it checks the latest revision.

## Decided by the user

- Queues and a scheduler, following the reference layout.
- Both a start time and conditions.
- No wake by default. The user is told to keep the Mac awake. An optional flow asks for the password once and installs the permission. There's a Remove permission button.
- Verify for downloaded Hugging Face models.

## Calls made in this doc (user can override)

- Main queue is the default and can't be deleted. Deleting a queue moves its jobs to Main.
- Global max running becomes an overall cap on top of per-queue limits.
- Hibernate is dropped. Run command is kept, off by default.
- 30-second cancellable countdown before Sleep, Shut down and Quit.
- Idle means at least 5 minutes without input. Hotspots don't count as Wi-Fi.
- A Hugging Face queue isn't created automatically.
- Verify works offline from the manifest, with an online fallback for older folders.

## Answers to the builder check

1. **The engine runs inside the app.** The `dl` CLI and MCP talk to the running app over IPC (`engine/src/ipc.rs`), so the app is always there. Until the app first reports conditions, a queue that needs a condition treats it as **not met** and holds. The app reports at engine start, so in practice this lasts milliseconds.
2. **Windows may cross midnight.** A Stop at that is at or before Start at means the next day. With On days, the day the window starts on owns it, so Fri 22:00–06:00 runs into Saturday morning.
3. **Stop and Start queue.**
   - **Stop queue** is a persisted hold: a `held` column on `queues`. It survives restarts.
   - On a scheduled queue, the hold lifts at the next window or on Run now.
   - On an unscheduled queue (like Main), only **Start queue** lifts it.
   - **Start queue** on an unscheduled queue clears the hold. On a scheduled queue it is the same as Run now.
4. **When a run is finished.** A run starts when a queue goes from having no running jobs to starting one, either inside an open window or on Run now / Start queue. It ends when the queue has no Queued, Running, Retrying, Verifying or held jobs left.
   - Paused jobs count as left, so pausing the last jobs never fires `QueueFinished`.
   - A window closing with work left is not finished either. Those jobs are held for the next run.
   - `QueueFinished` fires only at the end of a run that started at least one job, and the app acts only if an action other than Do nothing is set.
   - This applies to unscheduled queues too, so Main can "shut down when done". The 30-second countdown guards it.
5. **The engine writes `.rays-model.json` inside `add_hf`,** so CLI- and MCP-added models get a manifest too. Files without a published sha256 are checked by size only, and the result says "size checked".
6. **Moving a running download into a closed queue holds it at once** (back to Queued, held). Verifying counts as running for both the global cap and the queue's cap.
7. **Retry failed on an unscheduled queue** runs when **Start queue** or **Run now** is pressed.
8. **Simultaneous downloads.** A queue's Simultaneous defaults to **Same as Rays**, stored as 0, which uses the global "Downloads at once" setting. The global setting stays the overall cap. A queue can set a lower or equal number, and the stepper never offers more than the global cap, so nothing is throttled silently.

## Left to the builder

- Exact SQLite schema and migration order, and how `QueueView` counts are computed.
- How a held job is represented: a flag on `Queued`, or a new state. It must be clearly distinct from user Pause in the UI ("Waiting for schedule").
- Tick interval details, and the time zone and DST handling of windows (use local time).
- Layout specifics of the sheet within the reference structure. Use Liquid Glass for the tiles and pills.

## Revision (2026-11-25, user direction): one Queues page

This replaces the per-queue sidebar rows and the scheduler sheet.

- **Sidebar.** A single **Queues** item, in the Rays section after Models, with the symbol `list.bullet.rectangle`. It shows no per-queue rows.
- **Queues page toolbar.** The centre group has three tabs: **Queues** (`list.bullet`), **Activity** (`clock.arrow.circlepath`) and **Settings** (`slider.horizontal.3`). On the right are **+ New queue** (`plus`), a **Start all / Stop all** menu (`play.circle`) and the Settings button.
- **Queues tab.** One list of every queue with its schedule summary: repeat and times, conditions, next run, and counts. Each row has an enabled switch, and Start/Stop on hover. Clicking a row pushes the queue's detail view, with a back button. The detail view has the queue's downloads, the editable name, and its Schedule and Options sections inline, plus the save bar, as already built.
- **Activity tab.**
  - **Running now:** queues with running jobs, with live progress.
  - **Upcoming:** the next runs of all enabled scheduled queues, sorted by time.
  - **History:** past runs, newest first, capped at the last 200. Each entry shows the queue, its start and end, files finished, bytes, and the outcome: finished, stopped at the window end, stopped by the user, or Rays quit.
- **Settings tab (app-wide).** The wake permission (status, Set Up, Remove). Defaults for new queues: Simultaneous, Speed limit and When finished.
- **Engine.** Persist queue runs in a `queue_runs` table: id, queue_id, started_at, ended_at (null while running), files_done, bytes_done, outcome. Expose `Engine::queue_runs(limit) -> Vec<QueueRun>` and emit `JobEvent::RunChanged { run }`. A run starts and ends using the existing run-tracking rules. Runs still open when Rays starts are closed with the outcome "Rays quit".
