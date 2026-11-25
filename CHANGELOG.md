# Release notes

## 0.1.22 (25 Nov 2026)

- **Direct downloads.** A download goes into a queue only when you pick one in the Download button's menu or use **Move to Queue**. Otherwise it starts now, in no queue, so the Main queue no longer lists every download. **Download Now** in the menu and **Move to Queue › No Queue** take a download out of its queue. Finished downloads that were in Main move out on the first launch.
- Deleting a queue now takes its downloads out of every queue, instead of moving them to Main.
- **Speed test** on a network Rays can't identify yet now asks first, like a hotspot, and the note under the result says why it wasn't saved.
- The speed **History** now shows all 60 days, 50 rows per page.
- The Schedules page shows a plain hint when nothing is scheduled.

## 0.1.21 (25 Nov 2026)

- **Speed test.** A new **Tools** section in the sidebar has **Speed test**, with your last result next to it. Its page shows live speed and progress while a test runs, a **History** of tests and download speeds, and **Settings**. A test takes about 10 seconds. On a hotspot or metered connection Rays asks first, and speed data stays on this Mac.
- **Best time.** Rays learns when your connection is fastest from your real downloads and speed tests, and shows the usual fastest hours once it has 7 days of data.
- **At best time.** The Download button's menu can add downloads to a **Best time** queue that follows your fastest hours. The first time, Rays can test a few times each night for a week to learn faster. **Use best time** fills in any queue's schedule, and **Follow best time** keeps it up to date.
- A large download that is running much slower than usual suggests moving it to the Best time queue.
- Automatic speed tests every 3 hours are available in Settings, off by default.
- `dl speed`, `dl speed test` and `dl add --best-time`, and MCP tools `speed_test` and `best_time`.
- **Add schedule** on the Schedules page is now a round icon button.

## 0.1.20 (25 Nov 2026)

- **Hugging Face models.** Search Hugging Face from the new **Models** page under Downloads, see trending models as cards with a colour and icon for each type, filter by Text, Vision, Image, Audio and Embeddings, and download a model or a single quantization.
- **Verify** a downloaded model on the **Downloaded** tab. Rays checks each file's size and SHA-256 checksum offline, lists files that are missing or changed, and **Re-download** fetches only those.
- **Queues.** A new **Queues** section in the sidebar. **Main** always exists and takes new downloads. Add more queues, each with its own icon and colour, speed limit, number of files at a time, and what your Mac does when the queue finishes: play a sound, quit Rays, sleep, lock the screen, shut down or run a command.
- **Schedules.** Run a queue once, every day or on chosen days, with a start time and an optional stop time. Add conditions: only on Wi-Fi, only while charging, or only when the Mac is idle. **Activity** shows queues running now and the last 200 runs.
- **Command line and MCP.** `dl queues`, `dl add --queue <name>`, `dl queue start|stop|run <name>` and `dl verify <folder>`. AI assistants get the same through new MCP tools: `list_queues`, `start_queue`, `stop_queue`, `run_queue_now`, `verify_model`, and a `queue` option on `add_downloads`.
- **Features page** on the website, with every feature in one place.
- **Wake the Mac** to start a scheduled queue. It's off by default and asks for your administrator password once. **Remove** takes the permission away.

## 0.1.19 (24 Nov 2026)

- Sorter's Recent tab opens files again. Clicking a file the sorter had renamed did nothing; now double-click opens it.
- Recent looks like the Downloads list: a ✓ on each file, a round button that shows the file in Finder, and Move Back, Share and More on hover. **Move Back** returns a file to the folder it came from, under its original name, and the sorter leaves it there.
- Files moved or deleted since they were sorted show as such, with a button to remove them from the list. **Remove Missing** clears them all.
- Right-click a file in Sorter's Files tab for **Open**, **Show in Finder** and **Copy Path**.
- Selected rows in Downloads and Recent are a darker grey, the same shape as the hover highlight, instead of blue.

## 0.1.18 (24 Nov 2026)

- Downloads reach full speed sooner on servers that limit the speed of each connection. Rays now doubles its connections as long as each step pays off, so on a test server that caps each connection at 2 MB/s, a 256 MB file downloads at 24 MB/s instead of 21.5 MB/s, and on a server 150 ms away at 34 MB/s instead of 30 MB/s.

## 0.1.17 (23 Nov 2026)

- Downloads keep their speed when a server drops connections: a dropped connection reconnects at once and keeps every byte it received. On a test server that drops connections at random, a big file now downloads at 41 MB/s instead of 5 MB/s.
- Secure (HTTPS) downloads use less CPU: one connection can now decrypt over 1.7 GB/s, up from under 0.5 GB/s, and connections use TLS 1.3 where the server offers it.
- New [benchmarks](https://github.com/a6n-ai/rays/blob/main/docs/benchmarks.md) against aria2 and curl, with the script to rerun them.

## 0.1.16 (23 Nov 2026)

- Install with Homebrew again: `brew install --cask a6n-ai/tap/rays`. The DMG download stays.
- Rays is signed with a new certificate, so System Settings > General > Login Items lists Sorter as Rays instead of a6n. After this update, macOS asks once more for folder access, and for Keychain access if you saved cloud bucket keys.

## 0.1.15 (23 Nov 2026)

- The Dock icon shows the download speed above its progress bar, and the menu bar shows the speed next to the icon while files download.
- The red badges show: the menu bar badge keeps its red, and Rays asks once to show badges, which macOS needs before the Dock icon can show the number of downloads. If you said no, turn on Badge application icon in System Settings > Notifications > Rays.

## 0.1.14 (23 Nov 2026)

- The menu bar icon shows a red badge with the number of downloads running.
- The menu bar panel lists the latest four downloads, with See All in Rays and Clear, which hides them from the panel only. Click a finished download to open it; right-click for Open, Show in Finder, Remove from Rays and Move to Trash.
- Double-clicking a finished download in the Downloads list opens it again.

## 0.1.13 (23 Nov 2026)

- Brave connects to Rays: Install Helper now also puts the helper in Chrome's folder, which is where Brave looks for it. Every browser built on Chromium gets that copy too.
- Settings > Browsers sets up any browser built on Chromium or Firefox, not only the ones Rays knows by name, and lists every other browser in the same list with the reason. Search is supported.
- Remove Missing in the Downloads list clears finished downloads whose file was moved or deleted.

## 0.1.12 (23 Nov 2026)

- Download lists (Downloads, Sorter's recent moves and Cloud) have Filter and Sort menus, pages of 50, and an icon for each file's type. Each window's toolbar has the same three buttons: recent first, settings last.
- Copy a download link anywhere on your Mac and Rays offers to download it in a notification. Turn this off in Settings.
- Close the window and Rays can keep downloading from the menu bar. Its menu bar panel shows the Rays icon and opens Downloads, Sorter and Cloud, or adds a link or a file of links.
- Settings > Browsers shows the extension as added in browsers whose files macOS keeps private, such as Brave, once you've opened the Rays button there.
- The extension menu has Install helper when the helper is missing, and updates itself as soon as the store has a new version.

## 0.1.11 (23 Nov 2026)

- The browser extension has a menu: click the Rays button to see whether it's connected to Rays and how many downloads are in progress, paste a link to download, or switch Send all browser downloads to Rays on and off.
- Settings > Browsers lists every browser on your Mac, including ones Rays can't add its extension to, with the reason.

## 0.1.10 (23 Nov 2026)

- Faster downloads from servers that limit each connection: big files start on 4 connections and Rays doubles them while they make the file faster. On our test server a 64 MB file took 5.8 s instead of 12.9 s; on a line one connection fills, nothing changes.
- A connection that is far slower than the others is replaced, so one bad route no longer holds up the whole file.
- Servers that allow only a few connections are used fully: Rays keeps the connections they accept and remembers the right number for next time (it remembered one too few before).
- The Dock shows download progress and how many files are downloading, and the menu bar shows the overall percent with your downloads, Pause All and Resume All. Closing the window keeps Rays downloading in the menu bar; switch that off in Settings > General.
- Downloads are no longer slowed by App Nap when Rays is in the background, and the Mac stays awake while a download runs.
- Less CPU while downloading, and progress is saved to disk safely, so a resume after a power cut cannot leave gaps in a file.

## 0.1.9 (22 Nov 2026)

- Cloud Browse works like Finder: your connected providers appear as folders, then their buckets, then each bucket's folders and files, as icons or a list with size, date and kind.
- Buckets show brand icons, and the AWS CLI and Cloudflare R2 lists load once and then open instantly. Refresh looks them up again.

## 0.1.8 (22 Nov 2026)

- Cloud: one page in the sidebar to browse buckets, add them and see cloud downloads. A bucket can use an AWS CLI profile (saved keys, `aws login` or SSO), so Rays keeps no secret for it. Cloudflare R2 buckets come straight from your `cf` login.
- Remove a download from the list, or move its file to the Trash, from each row's menu or with Delete.
- Share finished downloads with AirDrop or the Share menu.
- If the sorter moved or renamed a file, its row still finds it. Missing files show whether they are in the Trash or were deleted.
- Get Extension opens the store page in the browser that needs it.
- Releases are now signed with one stable certificate, so from this version on updates keep folder access and Keychain items (this update may ask once more). Rays opened from the DMG asks to be moved to Applications instead of breaking sorter folders.

## 0.1.7 (22 Nov 2026)

- Updates install themselves: click Update and Rays downloads the new version, checks it, replaces itself and reopens. From this version on, no more dragging to Applications.
- The Downloads list follows the sorter: when a file is sorted into a folder, its row shows where it went, and Show in Finder opens it there.
- Get the browser extension from the Chrome Web Store or Firefox Add-ons. Settings > Browsers opens the right store.

## 0.1.6 (22 Nov 2026)

- Download from S3 buckets: Amazon S3, Cloudflare R2, Backblaze B2, Wasabi, MinIO and any S3-compatible service. Add a bucket in Settings > Cloud, then browse it in the sidebar. `dl` and MCP can download from buckets too. Secret keys stay in your Keychain.
- Faster downloads: big files start on 4 connections, and Rays adds connections only while they make the download faster.
- Works with the Rays extension from the Chrome Web Store. If you loaded the extension by hand before, remove it and load it again, then click Install All Helpers in Settings > Browsers.

## 0.1.5 (18 Nov 2026)

- One command, `dl`, now covers sorting too: `dl list`, `dl sort`, `dl watch`, `dl unwatch`, `dl status` and `dl config`.
- `dl mcp` runs an MCP server, so AI assistants like Claude can download files and sort folders with Rays.
- Settings > General > Command line tool installs the `dl` command that ships inside Rays.
- Settings > General > Uninstall Rays removes the sorter, browser helpers and `dl`, then moves Rays to the Trash.
- New website and docs at [rays.a6n.ai](https://rays.a6n.ai).
- Rays is open source under the AGPL-3.0 licence.

## 0.1.4 (17 Nov 2026)

- Rays checks for updates each time it opens (at most once an hour) and every 6 hours while it is open.
- The DMG window shows a background with an arrow: drag Rays to Applications.

## 0.1.3 (17 Nov 2026)

- New switch to turn AI renaming off. Files keep their original names and are still sorted into folders.

## 0.1.2 (17 Nov 2026)

- Paste many links at once, in any common format: one per line, comma separated, or CSV. The add bar shows how many links it found.
- A small green note appears when a new version of Rays is out, and Settings has a Check for Updates button.
- New welcome screen when there are no downloads, with shortcuts to paste links, drop files or add the browser extension.
- Sorter: choose how long Rays waits before sorting a new file.
- Sorter: Setup, Files and Recent are now tabs in the toolbar.
- Files: browse sorted folders in a Finder-style list or as icons, with Quick Look previews.
- Recent: click a sorted file to open it.
- Settings has a Sorting section for the main sorter settings.
- Rays uses less CPU when idle.

## 0.1.1 (17 Nov 2026)

- Install from a DMG: open it and drag Rays to Applications.
- Download settings mark the recommended number of downloads and parts.

## 0.1.0 (17 Nov 2026)

- First release of Rays: a download manager for macOS 26 that downloads each file in parts at once.
- The sorter moves new files in Downloads, and any folder you add, into folders that fit them, using Apple's on-device model.
- Install with Homebrew: `brew install --cask a6n-ai/tap/rays`.
