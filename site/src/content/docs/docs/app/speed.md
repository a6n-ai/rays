---
title: "Speed test and best time"
description: "Test your download speed, see the hours when your connection is fastest, and send downloads to the best time of night."
---

**Speed test** measures how fast your connection is, and **Best time** finds the hours when it is usually fastest. Both live in the sidebar. Under **Tools**, between **Queues** and **Folders**, the **Speed test** row shows the last result, like "84 Mb/s". While a test runs, the row shows a spinner and the live speed.

Right-click the row for **Run Speed Test** or **Stop Speed Test**.

## The Speed page

Click **Speed test** to open the page. Its toolbar has three tabs, **Overview**, **History** and **Settings**, and a play button for **Run test**. The button becomes **Stop** while a test runs.

### Overview

The header shows the last result, for example "84.5 Mb/s · 161 ms latency · Wi-Fi · 3 min ago".

While a test runs, a progress bar and a live chart of the speed over the 10 seconds show here.

**Best time** sits below the header. It reads "Usually fastest 01:00–05:00 · 14 days" and shows a chart of the typical speed for each hour. Until Rays has enough data, it shows "Not enough data yet" with "3 of 7 days. Rays learns from your downloads and speed tests."

### History

**History** lists speed tests and download samples. Use **Filter** to show **All**, **Speed tests** or **Downloads**, and sort by **Newest** or **Fastest**. Rays keeps 60 days of history.

### Settings

- **Test automatically every 3 hours.** Off by default. Each test uses about 50 to 200 MB. Rays runs it only on Wi-Fi or Ethernet, and only when nothing is downloading.
- **Night tests.** Shows "On until <date>" with **Stop night tests**, which ends the week at once, or **Test at night for a week** to start it. See [Best time queue](/docs/app/queues/#best-time-queue) for the first-time question.
- **Clear speed history…** removes every speed test and sample. The best time starts again from nothing.

The page says "Speed data stays on this Mac." Nothing about your speed is uploaded.

## Run a test

A test takes about 10 seconds and uses Cloudflare's speed test server.

- On a hotspot, a metered connection or a network Rays can't identify yet, Rays asks before it starts.
- On a hotspot, a metered link or a network Rays can't identify yet, a test is not saved, and without your go-ahead it does not run.
- If downloads were running during the test, Rays shows the result but does not save it, because other traffic would skew it.
- While an automatic test runs, the Overview header says "Automatic test". It can't be stopped.

## How Rays learns the best time

- Rays records your real download speed once a minute. It makes no extra traffic for this. Minutes with a speed limit, or on a hotspot, are skipped.
- Speed test results are added to those samples.
- Best time needs 7 days with data, and at least 3 samples in each hour of the window, before it shows a window.

## Best time downloads

When you add downloads, the **Download** button's menu has **At best time** with the window, for example **At best time (01:00–05:00)**. Until Rays has 7 days of speed data it reads **At best time (01:00–06:00, default)**. This puts them in the **Best time** queue, which Rays creates the first time you use it. Its schedule follows the best window. See [Queues and schedules](/docs/app/queues/#best-time-queue).

A large download (1 GB or more) that is running much slower than the best window shows "Usually N× faster at 01:00", with a **Move to Best time** button.

## Command line and MCP

- `dl speed` prints the last test and the best time. `dl speed test` runs a test now, and `dl speed test --force` also runs it on a metered link or a network Rays can't identify, for example while the app is closed. A forced test on those is not saved.
- `dl add --best-time <url…>` adds downloads to the Best time queue.
- The MCP tools are `speed_test` (with `force`), `best_time`, and `add_downloads` with `best_time`. See [MCP](/docs/mcp/) and [The dl command](/docs/dl/).

Clearing history and changing settings are app-only.
