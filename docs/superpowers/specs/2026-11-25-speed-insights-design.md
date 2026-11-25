# Speed insights: speed test, speed log, best-time downloads

Status: approved (2026-11-25)

## Intent

This is a feature for every Rays user. Rays learns when the user's internet is fastest, tells them, and can download big files at that time on its own. Today Rays measures speed only live, while a download runs, and keeps nothing.

Success: a user who has used Rays for a week or two can add a large file, pick **At best time**, and it downloads overnight in the fastest window, with no schedule set up by hand.

## Goals

- **A speed test** the user can run any time, from a card in the sidebar.
- **A speed log** on the Mac, fed by speed tests and by the user's real downloads.
- **Recommendations** drawn from the log. Each shows the best window and how sure Rays is.
- **At best time** when adding a download. It puts the download in a **Best time** queue whose schedule follows the recommendation.
- **Use best time** in any queue's Schedule tab, including Main, which fills in the recommended start and stop.
- **A hint while a big download runs slowly**, when the best window is much faster.
- The same data through the `dl` command line and MCP.

## Non-goals

- Upload speed, jitter, or ISP grading. This is not a full speed test product.
- Sending any speed data anywhere. There is no telemetry and no comparison with other users.
- Per-server recommendations ("huggingface.co is faster at 03:00"). Only one window for the whole connection.
- Changing how Main behaves by default.

## Anti-goals (a failure even if it works)

- Rays using the user's data allowance behind their back. Automatic tests are off by default.
- A confident recommendation from too little data. With too little data, Rays says so.
- A download moved or delayed without the user choosing it.

## Approaches

1. **The log lives in the engine (chosen).** A new SQLite table in the store Rays already has. The engine records samples, runs the speed test, and works out the best window. The app, `dl` and MCP all read the same thing, and it is tested in Rust like the queue work.
2. **The log lives in the app.** It is faster to start, but `dl` and MCP can't see it, and scheduling logic would be split between the app and the engine. Rejected for that reason.

The user chose the **Best time queue** route for automatic downloads, over putting a best-time schedule on Main, so Main keeps downloading straight away.

## Design

### Speed samples (engine)

- **New table** `speed_samples(id, at INTEGER /*unix s*/, bps INTEGER, source TEXT /*'test'|'downloads'*/, network TEXT /*'wifi'|'wired'|'other'*/)`.
  - It is an append-only migration.
  - Rows older than 60 days are deleted on start and once a day.
- **Download samples.** Each minute, the engine adds one `downloads` sample of the total bytes per second across all running jobs. It does so only when all of these hold:
  - at least one job ran for the whole minute
  - no global or queue speed limit was active
  - total speed was above 50 kB/s
  
  Real downloads show what the connection actually delivers. Speed limits would make the number meaningless.
- **Network.** The app tells the engine the network type it already detects for conditions (NWPathMonitor), through the existing `set_conditions` path, extended with the network. Samples from a phone hotspot (expensive path) are not recorded.

### Speed test (engine)

- `Engine::run_speed_test() -> SpeedTestResult { bps, latency_ms, at }`. It is async.
- **Server:** Cloudflare's public speed test, with no account. The engine sends `GET https://speed.cloudflare.com/__down?bytes=N` on 4 parallel connections for up to 10 s, starting at 1 MB and growing. Latency is the median of 5 requests with `bytes=0`.
- The result is saved as a `test` sample. A failure (offline, proxy blocking, timeout) returns an error with a plain message and saves nothing.
- **Automatic tests** are an app setting, **off** by default. When on, the engine runs a test every 3 hours, only on Wi-Fi or wired (not on an expensive path) and only when no download is running. Running downloads already produce samples.

### Recommendation (engine)

- `Engine::best_window(hours: u8 = 4) -> BestWindow { start_minute_of_day, end_minute_of_day, typical_bps, now_bps_estimate, days_of_data, confidence: Low|Medium|High } | NotEnoughData { days_of_data, needed: 7 }`.
- **Method:**
  1. Bucket the samples from the last 28 days by hour of day, in local time.
  2. Take the median of each bucket. Test samples and download samples count the same.
  3. Pick the contiguous `hours` window, wrapping past midnight, with the highest mean of bucket medians. Windows with an empty bucket are skipped.
- **Not enough data:** fewer than 7 distinct days with samples, or fewer than 3 samples in each hour of the chosen window.
- **Confidence:**
  - High: at least 14 days and at least 5 samples per window hour.
  - Medium: at least 7 days.
  - The text always shows the days, for example "Usually fastest 01:00–05:00 · 14 days".
- Weekdays and weekends are not split in v1. That is left to the builder for later, once there is data.

### Best time queue

- **Created** on first use of **At best time** (or of `dl add --best-time`), with the name "Best time" and its own icon (`moon.stars`, indigo). It is a normal queue with a new config field `follow_best_time: bool = true`.
- **Schedule:** while `follow_best_time` is on, the engine sets the queue's schedule to Every day, from the best window's start to its end (it has a stop time). The schedule is refreshed once a day at the start of the scheduler tick, and only when the window moves by 30 minutes or more.
- **Not enough data:** the Best time queue uses Every day 01:00–06:00 and labels it "Default night window until Rays has 7 days of speed data".
- **Editing:** if the user edits the queue's schedule by hand, `follow_best_time` turns off and the queue becomes an ordinary scheduled queue. The Schedule tab shows a **Follow best time** switch to turn it back on.
- It can be deleted like any other queue. The next **At best time** creates it again.

### App

- **Sidebar card.** A compact card at the bottom of the sidebar shows:
  - the last result, for example "92 Mb/s · 2 h ago"
  - a round **Run test** button. While running, the button becomes a ring with the live speed.
  
  Clicking the card opens the **Speed** page. The card uses the Downloads-style glass and the type colours already in the app.
- **Speed page:**
  - The last result, large.
  - **Run test**.
  - A 24-hour bar chart of typical speed per hour with the best window highlighted, or a "Not enough data yet: N of 7 days" empty state.
  - The recommendation text.
  - Settings: **Test automatically every 3 hours** (off by default), with the note "Uses about 50 to 200 MB per test", and **Clear speed history**.
- **Add bar.** The split button's menu gains **At best time**, with the window shown, for example "At best time (01:00–05:00)". Choosing it adds the downloads to the Best time queue.
- **Schedule tab:** a **Use best time** button next to Start at fills in the start and stop as a draft. It is disabled with a tooltip when there is not enough data. The Best time queue also shows the **Follow best time** switch.
- **Slow download hint.** It appears on the Downloads row, in the status line, when all of these hold:
  - the job's total size is at least 1 GB
  - it has run for 60 s
  - the best window's `typical_bps` is at least 2× the job's current speed
  - the current time is outside the window
  - confidence is Medium or High
  
  The text reads "Usually 3× faster at 01:00", with a **Move to Best time** button. It is shown once per job and can be dismissed.

### dl and MCP

- `dl speed` shows the last result and the recommendation. `dl speed test` runs a test. `dl add --best-time <url…>`.
- **MCP:**
  - `speed_test`: runs a test and returns the result.
  - `best_time`: returns the recommendation.
  - `add_downloads` gains `best_time: bool`.
- Reading and running a test are allowed. Clearing history and changing settings stay app-only, the same rule as queue editing.

### Docs

- A new `site/src/content/docs/docs/app/speed.md`.
- Updates to `queues.md`, `features.md`, `/features/` and the landing Queues passage, `mcp.md`, `dl.md` and `llms.txt`.
- A CHANGELOG entry.

## Decisions after the builder check

### The user's decision

**Night data: ask once.** The first time someone picks **At best time**, or creates the Best time queue some other way, Rays asks:

> "Let Rays test your speed a few times each night for a week? About 1 GB in total."

- **Allow** turns on night-only automatic tests for 7 days. That means one test in each of the slots 00–02, 02–04 and 04–06, at a random minute inside the slot. The tests run only on Wi-Fi or wired, never on an expensive path, and only when no download is running. After the 7 days, the normal **Test automatically** setting decides whether tests continue. It stays off unless the user turns it on.
- **Not now** uses the default 01:00–06:00 window. The Speed page keeps a **Test at night for a week** button, so the user can say yes later.
- The answer is stored, and the prompt never shows again.

### My calls

1. **Following the best time.**
   - `follow_best_time` is a new `queues` column, added as an append-only migration, default false. It is also a new `QueueConfig` field.
   - The engine refreshes the schedule through an internal path, not through `save_queue`. That path keeps the flag on.
   - When `save_queue` gets a schedule that differs from the stored one, it turns the flag off. The Schedule tab's **Follow best time** switch sets the flag back on, and the engine then rewrites the schedule.
   - The Best time queue is found by `follow_best_time` together with a stored `best_time_queue_id` setting, never by its name. Renaming it keeps it working.
2. **Network type.**
   - `set_conditions` gains `network: NetworkKind { Wifi, Wired, Expensive, Other, Unknown }`. This is a UniFFI change, so the Swift call site in `ConditionsMonitor` is updated too.
   - The engine starts as `Unknown`. While the network is `Unknown`, for example when only `dl` or MCP is running and the app isn't, no samples are recorded and no automatic tests run.
   - Samples are stored only for Wifi, Wired and Other. Expensive samples are never stored.
3. **Where settings live.** The automatic-test setting, the night-week state and its end date, the prompt answer and `best_time_queue_id` live in the engine store, in a small key-value `settings` table, added as a migration. That way they work without the app. The app reads and writes them through new engine calls.
4. **Manual tests.**
   - The app's **Run test** on an expensive network first shows "You're on a hotspot or metered connection. A test uses about 50 to 200 MB." with **Run Test** and **Cancel**.
   - `dl speed test` and MCP `speed_test` refuse on an expensive network unless they are passed `--force` (`force: true` for MCP).
   - A test that runs while downloads are going is shown but not saved, with the note "Downloads were running, so this result wasn't saved".
5. **Weighting.** Test and download samples count the same in each hour's median. Spreading night tests at random inside their slots keeps any one hour from being over-sampled.
6. **The Best time queue's conditions** (Wi-Fi, charging, idle) are all off by default, and the user can turn them on.
7. **No network filter in v1.** The `network` column is stored for later use. `best_window` uses every stored sample.
8. **Coverage.** `best_window` considers only hours with at least 3 samples. If no window of the requested length is fully covered, the result is `NotEnoughData`. The night prompt exists to fill those gaps.

## Constraints

- No em dashes in docs or UI copy, and no exclamation marks. Use the Mac's own words for controls.
- jiff for time, in local time, as the queue scheduler does.
- Liquid Glass only on floating and interactive chrome, as in the queues UI guide.
- The speed test must respect the user's proxy settings, which reqwest already uses.
- Everything stays on the Mac.

## Left to the builder

- The exact ramp of the speed test (sizes and the stop rule), within 10 s and 4 connections.
- The chart's look on the Speed page, which should match the existing Models and Queues visual language.
- Where in the sidebar the card sits exactly: at the bottom, above Folders, or pinned.
