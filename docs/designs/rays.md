# Rays: macOS download manager

*   **Author:** lawbringr
*   **Status:** Proposed
*   **Date:** 2026-11-16

--------------------------------------------------------------------------------

## Overview

`dl` is a small desktop download manager for macOS, Windows, and Linux, built
as one Rust download engine with a separate native UI on each operating
system. Version 1 ships the engine plus a SwiftUI app for macOS. A GTK4 app
for Linux and a WinUI 3 app for Windows follow on the same engine. The user pastes a URL, `dl` downloads the file into the user's
Downloads folder (as reported by the operating system), and shows progress,
speed, and state for each download. Downloads can be paused, resumed after a
network failure, and resumed after the app is closed and reopened.

On macOS, `dl` is the third tool in `~/local-scripts`, next to `extract` (pulls text out
of documents) and `sorter` (files downloads into topic folders using the
on-device model). `dl` does not sort anything itself. It writes each download
under a temporary name and renames it only when the download is complete, so
`sorter watch ~/Downloads` picks up only finished files. On Windows and Linux
there is no `sorter`; the same rename rule still keeps other tools (antivirus
scanners, sync clients) from opening half-written files.

## The Problem

Browsers download files in a way that is hard to control:

*   A large download that fails halfway (Wi-Fi drop, laptop sleep) often has
    to start again from zero, or the browser loses track of it after a
    restart.
*   There is no single place to queue several links, limit how many run at
    once, and see which ones failed and why.
*   Downloads started from a terminal (`curl`, `wget`) have no shared view
    with downloads started from a browser.

`sorter` already assumes files arrive in `~/Downloads` and skips names ending
in `.part`, `.crdownload`, `.download`, `.partial`, and `.tmp`. A download
manager that follows the same naming rule plugs into `sorter` without any
change to `sorter`.

The proposed solution is a Rust download engine with no UI code, called from
a thin native UI on each operating system through generated bindings. Each
app has a small window built from the platform's own controls, a download
queue that survives restarts, and HTTP range requests so an interrupted
download continues from the byte where it stopped.

## Goals

*   **Resume after failure**: if the connection drops, `dl` retries and
    continues from the last byte written, without re-downloading data it
    already has. Verified by cutting the network mid-download and checking the
    final file's SHA-256 against the source.
*   **Resume after restart**: closing and reopening `dl` keeps every unfinished
    download in the list, in a paused state, with its byte count intact.
*   **Queue with a limit**: the user can add many URLs; at most N run at once
    (default 3), the rest wait in order.
*   **Safe hand-off to `sorter`**: a file appears in `~/Downloads` under its
    final name only after every byte is written. `sorter` never sees a partial
    file.
*   **No overwrite, no escape**: `dl` never overwrites an existing file in
    `~/Downloads`, and a server-supplied filename can never place a file
    outside `~/Downloads`.
*   **One engine, three native UIs**: all download logic (HTTP, resume,
    retries, queue, persistence, naming, single-instance channel) lives once
    in a Rust crate with no UI dependency. In version 1 the engine is built,
    tested, and tuned for macOS only (Apple Silicon and Intel). Each UI only
    displays engine state and forwards user actions; it holds no download
    logic.
*   **Native look and behaviour**: each UI uses the platform's own controls
    (SwiftUI on macOS, GTK4 + libadwaita on Linux, WinUI 3 on Windows), so
    keyboard navigation, text fields, menus, dark mode, and screen readers
    (VoiceOver, Orca, Narrator) work the way the platform defines them.
*   **macOS first**: version 1 is the engine plus the SwiftUI app on macOS 14+.
    The Linux app comes second and the Windows app third. Version 1 picks
    the best option for macOS at every engine decision. Changes the engine
    needs for Linux and Windows (paths, IPC, binding support) are decided
    when each port starts, and may change the engine API and the macOS app
    with it. Decided by author 2026-11-16.
*   **Small**: one app per platform, no runtime to install. Target under 10 MB release
    build and under 50 MB memory while idle with 20 finished downloads listed.
*   **CLI entry point**: `dl URL...` adds URLs to the running app's queue (or
    starts the app), so terminal users and scripts share the same queue.

## Non-Goals

*   **Mobile (iOS, Android).** Both suspend an app's own network code soon
    after it leaves the screen. Background downloads must go through
    `URLSession` background sessions on iOS and a foreground service or
    WorkManager on Android, so the shared engine could not do the transfer
    itself. Mobile would be a separate product.
*   **Browser integration** (an extension that captures clicks on download
    links). This needs a browser extension plus native messaging, which is
    larger than the whole download manager.
*   **Torrent, FTP, or streaming video (HLS/DASH) downloads.** Only plain
    HTTP and HTTPS.
*   **Splitting one file across several parallel connections.** It speeds up
    some servers but adds chunk bookkeeping and breaks on servers without
    range support. Revisit only if single-connection speed is a measured
    problem.
*   **Sorting or renaming by content.** That is `sorter`'s job.
*   **io_uring.** macOS has no io_uring, and on Linux `tokio-uring` would only
    speed up file writes, while sockets stay on epoll. Downloads are
    network-bound, so it adds a Linux-only runtime for no measurable gain.
    Decided by author 2026-11-16.
*   **Logins, cookies, or authenticated downloads.** URLs that need a browser
    session are out of scope for the first version.
*   **`sorter` on Windows or Linux.** `sorter` depends on macOS-only tools
    (`mdls`, launchd, the `fm` model). `dl` does not port it.
*   **Windows and Linux in version 1.** Neither the UIs nor the engine are
    built or tested on those platforms in version 1. Accepted risk: the
    ports may need engine changes, found only when each port starts.
*   **One shared UI codebase.** Rejected in favour of a native look; see
    Alternatives Considered.
*   **App Sandbox and the Mac App Store in version 1.** The app ships
    unsandboxed and ad-hoc signed with no entitlements, so it writes to
    `~/Downloads` and binds its socket in `~/Library/Application Support/dl/`
    without extra permissions. An App Group container was planned for the
    socket, but macOS refuses unsigned apps access to `~/Library/Group
    Containers/` (error 513), so it moves there only when the Safari extension
    and a team-signed build arrive. Decided by author 2026-11-16.
*   **Installers and auto-update.** The first version ships a plain `.app`
    bundle on macOS (later a plain `.exe` and a Linux binary).
    Code signing, notarization, MSI/DMG packaging, and update checks come
    later.

## Open Questions

*   None.

## Critical User Journeys (CUJs)

### CUJ 1: Download a file and let `sorter` file it

*   **Given**: macOS, `dl` is open, and `sorter watch ~/Downloads` is running.
*   **When**: the user pastes `https://example.com/report.pdf` and presses
    Enter.
*   **Then**: `~/Downloads/report.pdf.<id>.part` grows while the row shows bytes,
    total, and speed. When complete, it is renamed to `report.pdf` (or
    `report (1).pdf` if that name is taken). `sorter` then moves it into a
    topic folder. At no point does `sorter` touch the `.part` file.

### CUJ 2: Survive a network drop

*   **Given**: a 2 GB download is 40% done.
*   **When**: Wi-Fi drops for 60 seconds, then returns.
*   **Then**: the row shows "Retrying (n/5)" (waits of 2, 5, 15, 30, 60 s, about
    2 minutes in total). After the network returns,
    `dl` sends a `Range` request starting at the current byte count and
    continues from 40%. The final file matches the source byte for byte.

### CUJ 3: Quit and come back later

*   **Given**: three downloads are running and two are queued.
*   **When**: the user quits `dl`, then opens it the next day.
*   **Then**: all five rows are listed as paused with their byte counts.
    Pressing Resume continues each one from where it stopped.

### CUJ 4: Add from the terminal

*   **Given**: `dl` is already open.
*   **When**: the user runs `dl https://a.com/x.zip https://b.com/y.iso`.
*   **Then**: both URLs are added to the existing window's queue. No second
    window opens.

## Technical Plan (Architecture)

### Components

```text
 Terminal               Browser (future)             macOS app (dl.app)
 ┌──────────┐   ┌───────────────────────────┐   ┌──────────────────────────────┐
 │ dl CLI   │   │ Chrome/Firefox ext → dl   │   │ SwiftUI views                │
 │ (Rust)   │   │   CLI as native-msg host  │   │   ContentView, JobRow        │
 └────┬─────┘   │ Safari ext → Swift handler│   │ EngineModel (@Observable)    │
      │         └────────────┬──────────────┘   │   .task { await next_events }│
      │ JSON lines           │ JSON lines       └──────────────┬───────────────┘
      ▼                      ▼                                 │ UniFFI (Swift)
 ┌─────────────────────────────────────────────────────────────▼───────────────┐
 │ dl-engine (Rust staticlib, linked into dl.app)                               │
 │  socket listener ─┐                                                          │
 │  UniFFI API ──────┼─► Scheduler (max 3 running, FIFO queue)                  │
 │                   │      │ spawns                                            │
 │                   │      ▼                                                   │
 │                   │   Download task (tokio + reqwest) ──► <name>.<id>.part   │
 │                   │      │ progress / state                    │ rename     │
 │                   │      ▼                                     ▼             │
 │                   └─ Event hub (coalesce 250 ms) ──►  ~/Downloads/<name>     │
 │                          │                                     │             │
 │                          ▼                                     ▼             │
 │                     Store (SQLite queue.db)           sorter watch picks up  │
 └──────────────────────────────────────────────────────────────────────────────┘
```

*   **`dl-engine`** (Rust library crate, built as a static library for the
    app and as a normal library for the CLI's tests). Owns its own tokio
    multi-thread runtime. Contains every rule about downloading: HTTP,
    resume, retry, naming, queue order, persistence, and the socket.
*   **`dl` CLI** (Rust binary). Talks to the engine only through the socket.
    It never links the download code, so it stays under 1 MB. Later it doubles
    as the Chrome/Firefox native messaging host (detected by the
    `chrome-extension://` or Firefox extension-id argument the browser
    passes).
*   **`dl.app`** (SwiftUI, macOS 14+). Displays engine state and forwards
    clicks. Holds no download logic. Starts the engine on launch and shuts it
    down on quit.

### Engine API (exported to Swift through UniFFI)

Illustrative, not final code:

```text
record EngineConfig { downloads_dir: String, data_dir: String,
                      socket_path: String, max_running: u32 }
enum   JobState     { Queued, Running, Paused, Retrying{attempt: u8},
                      Done{path: String}, Failed{reason: String} }
record JobView      { id: u64, url: String, name: String, done: u64,
                      total: Option<u64>, bytes_per_sec: u64,
                      resumable: bool, state: JobState }
enum   JobEvent     { Upsert(JobView), Removed{id: u64} }

object Engine {
  constructor(config: EngineConfig) throws     // opens DB, binds socket, restores jobs as Paused
  fn add(urls: Vec<String>) -> Vec<AddResult>  // validates http/https, returns id or reason
  fn pause(id: u64)
  fn resume(id: u64)
  fn remove(id: u64, delete_partial: bool)
  fn snapshot() -> Vec<JobView>                // initial fill of the list
  async fn next_events() -> Vec<JobEvent>      // waits until something changed
  fn shutdown()                                // pauses running jobs, flushes DB
}
```

The UniFFI exports use `async_runtime = "tokio"` so `next_events` runs on the
engine's runtime. `next_events` returns as soon as a state change happens.
Progress-only changes are gathered and returned at most every 250 ms. An
idle engine sends nothing, so the app does not wake up.

### Download task (one per running job)

1.  **Request.** `GET url`. If the `.part` file has bytes, add
    `Range: bytes=<len>-` and `If-Range: <etag or last-modified>`. Redirects
    are followed (limit 10). Timeouts: 15 s to connect, 30 s with no bytes
    received.
2.  **Response.**
    *   `206 Partial Content`: append to `.part`.
    *   `200 OK` when a range was asked for: the server ignored the range,
        or the file changed (`If-Range` failed). Truncate `.part` and start
        from zero; mark the job `resumable = false` if no `Accept-Ranges:
        bytes` was sent.
    *   `416 Range Not Satisfiable`: the `.part` already holds every byte;
        go to step 4.
    *   Other 4xx: fail at once (retrying will not help). 5xx and network
        errors: retry.
3.  **Body.** Stream chunks to the `.part` file and add each chunk's size
    to an atomic counter. Pause and cancel are a `CancellationToken` checked
    with `tokio::select!` against the next chunk, so they take effect
    immediately, even on a stalled connection.
4.  **Finish.** If `Content-Length` was known, check the byte count matches.
    `fsync` the file, then rename it to its final name (see naming).
5.  **Retry.** Up to 5 attempts with waits of 2, 5, 15, 30 and 60 s. Each
    attempt resumes from the current `.part` length. The counter resets after
    any attempt that received data.

### Naming and safety rules

*   **Name source**, in order: `Content-Disposition` (both `filename*=`
    RFC 5987 and `filename=`), then the last URL path segment
    (percent-decoded), then `download`.
*   **Sanitise**: keep only the final path component; strip `/`, `\`, `:`,
    and control characters; reject `.` and `..`; trim to 255 bytes.
*   **Partial name**: `<name>.<id>.part`, so two jobs for the same URL never
    share a partial file (the prototype's bug). `sorter` skips `.part`.
*   **Final name**: chosen at rename time, the first free one of
    `name.ext`, `name (1).ext`, `name (2).ext`, and so on. The rename never
    overwrites an existing file.

### Storage (SQLite, `queue.db`, WAL mode)

```text
jobs(id INTEGER PRIMARY KEY, url TEXT NOT NULL, name TEXT NOT NULL,
     part_path TEXT NOT NULL, final_path TEXT, done INTEGER NOT NULL,
     total INTEGER, etag TEXT, last_modified TEXT, resumable INTEGER NOT NULL,
     state TEXT NOT NULL, error TEXT, position INTEGER NOT NULL,
     created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)
```

*   Written on every state change, and every 2 s for `done` while running.
*   On startup, the `.part` file's real length wins over `done` in the
    database. A missing `.part` resets `done` to 0. Every unfinished job
    restarts as `Paused`.
*   Schema version kept in `PRAGMA user_version`. Migrations are plain SQL
    run in order at startup.

### Socket protocol (`dl.sock`)

*   Path: `~/Library/Application Support/dl/dl.sock`, mode `0600`.
*   On start, the engine tries to connect to an existing socket. "Connection
    refused" means it is stale: delete it and bind. A live socket means
    another engine is running, which cannot happen for a normal app launch
    because LaunchServices keeps one copy.
*   One JSON object per line, request then reply:

```text
→ {"op":"add","urls":["https://a.com/x.zip","ftp://bad"]}
← {"ok":true,"added":[{"url":"https://a.com/x.zip","id":42}],
   "rejected":[{"url":"ftp://bad","reason":"only http and https"}]}
→ {"op":"list"}
← {"ok":true,"jobs":[{"id":42,"name":"x.zip","state":"running","done":1048576,"total":5242880}]}
```

*   CLI behaviour: connect; if there is no socket, run `open -b local.lawbringr.dl`,
    then retry the connection for up to 5 s. It prints one line per URL and
    exits with code 1 if any URL was rejected.

### macOS app

*   `DLApp`: creates one `EngineModel`, one window.
*   `EngineModel` (`@Observable`, `@MainActor`): holds `[JobView]` keyed by
    id. Fills from `snapshot()`, then loops on `await engine.next_events()`
    inside `.task`, applying `Upsert` and `Removed`.
*   `ContentView`: a URL `TextField` (Enter or the Download button adds it;
    pasting several lines adds each line) above a `List` of `JobRow`.
    Dropping a URL from a browser onto the window also adds it.
*   `JobRow`: name, a `ProgressView` (indeterminate when the total is
    unknown), "12.4 MB of 80 MB · 3.1 MB/s", and Pause/Resume, Show in
    Finder (`NSWorkspace.activateFileViewerSelecting`), and Remove buttons.
    Every control has an accessibility label.
*   **Non-resumable jobs** (`resumable = false`): the row shows "Can't
    resume" and the Pause button becomes **Stop**. Clicking it opens a
    confirmation: "Stopping loses <done> of progress. Stop anyway?" Quitting
    while such a job is running shows the same warning, listing those jobs,
    before `shutdown()`. Decided by author 2026-11-16.
*   Quitting calls `engine.shutdown()`.

### Build

*   Cargo workspace with `engine`, `cli`, and `bindgen` crates. `engine` builds as a
    `staticlib` for `aarch64-apple-darwin` and `x86_64-apple-darwin`,
    combined with `lipo`. `uniffi-bindgen` generates the Swift bindings and
    a module map, and both are packaged as an `.xcframework`.
*   The macOS app is a Swift Package Manager executable that links the
    `.xcframework` as a binary target. `scripts/bundle-app.sh` wraps the
    built executable into `dl.app` with its `Info.plist` and signs it ad hoc
    (`codesign -s -`). No `.xcodeproj` is checked in; Xcode can open
    `Package.swift` directly. Bundle ID `local.lawbringr.dl`.
*   Release profile: `strip = true`, `lto = true`, `codegen-units = 1`,
    `opt-level = "s"`, as measured on the prototype.

## Alternatives Considered

Every rejection below was decided by the author on 2026-11-16 during the
design discussion. Figures marked "measured" were taken on this Mac with
blank release builds and the Activity Monitor memory footprint. Other
figures are typical values, not measured.

### UI technology

| Option | Size | Idle memory | Look | Linux | Rust engine bridge |
|---|---|---|---|---|---|
| **Chosen: native UI per OS** (SwiftUI first, then GTK4, WinUI 3) | small each | low each | Real controls | Yes | UniFFI to Swift/C#, direct GTK |
| egui (eframe) | 6.8 MB measured | 33 MB measured | Same on every OS | Yes | Direct |
| Slint | a few MB | low | Imitates Fluent/Cupertino | Yes | Direct |
| Flutter 3.50 + flutter_rust_bridge | 37.9 MB measured (universal) | 54 MB measured | Imitates via `fluent_ui`, `macos_ui` | Yes | Generated FFI with streams |
| Tauri | 3-10 MB | ~80-150 MB (web view) | Web page, native menus | Yes (WebKitGTK) | Commands and events |
| Electron 45.3.3 | 253 MB measured | ~84 MB measured (4 processes) | Web page | Yes | napi-rs add-on |
| React Native (react-native-macos/-windows) | unmeasured | unmeasured | Real AppKit / WinUI | No | Native module |
| Expo | n/a | n/a | n/a | No official desktop target | n/a |
| Kotlin + Compose Multiplatform | 60-100 MB (bundled JRE) | 150-300 MB (JVM) | Material 3 / Jewel | Yes | UniFFI Kotlin |

*   **egui, Slint**: small and cross-platform from one codebase.
    **Reason for rejection**: Rejected by author: neither gives a native look;
    egui draws the same widgets everywhere, and Slint imitates platform
    styles rather than using real controls.
*   **Flutter**: one codebase, polished widgets, all three desktops.
    **Reason for rejection**: Rejected by author: breaks the size and memory
    goals (measured 37.9 MB / 54 MB for an empty app), native look is only
    imitated, `macos_ui` has had no release since October 2025, and it adds
    Dart plus a generated bridge.
*   **Tauri, Electron**: richest UI ecosystems.
    **Reason for rejection**: Rejected by author: web page UI is not native,
    and memory use breaks the 50 MB goal (Electron measured at ~84 MB idle
    and 253 MB on disk).
*   **React Native desktop**: the only one-codebase option with real native
    controls.
    **Reason for rejection**: Rejected by author: no maintained Linux target.
*   **Expo**: no official desktop target; the third-party desktop project
    is not production-ready and has no Linux support.
    **Reason for rejection**: Rejected by author: does not target desktop.
*   **Kotlin + Compose Multiplatform**: easiest Rust bridge (UniFFI Kotlin).
    **Reason for rejection**: Rejected by author: bundled JVM breaks the size
    and memory goals, and the UI is Material, not native.
*   Also surveyed and set aside for maturity, licence, or look: iced,
    Dioxus, Freya, GPUI, Makepad, Floem, wxDragon, Qt via cxx-qt, gtk4-rs,
    fltk-rs, ratatui.

### Engine concurrency and HTTP

*   **OS threads + `ureq`** (the prototype's model).
    *   **Pros**: fewest dependencies, smallest engine, plain stack traces.
    *   **Cons**: pause waits until the current read returns, up to the 30 s
        read timeout on a stalled connection. Multi-connection downloads
        would need manual thread management.
    *   **Reason for rejection**: Rejected by author: tokio + reqwest gives
        immediate pause and an easier path to multi-connection downloads.
*   **OS threads + libcurl**.
    *   **Pros**: well-tested HTTP stack, follows macOS proxy settings.
    *   **Cons**: C dependency that complicates a later Windows build.
    *   **Reason for rejection**: Rejected by author: the C build cost
        outweighs proxy handling for this tool.

### Engine-to-UI updates

*   **UI polls `snapshot()` every 250 ms**: simplest, no calls from Rust
    into Swift. **Reason for rejection**: Rejected by author: wakes the app
    4 times a second during downloads and lags up to 250 ms; an async stream
    matches the tokio engine.
*   **Engine calls a Swift callback**: instant updates. **Reason for
    rejection**: Rejected by author: callbacks arrive on engine threads and
    must be moved to the main thread by hand, with lifetime risk across the
    FFI boundary, and no gain over the async stream.

### Queue storage

*   **One JSON file (temp file + rename)**: no dependency, readable by hand.
    **Reason for rejection**: Rejected by author: SQLite gives single-row
    transactional updates and a queryable history.
*   **Hidden metadata file next to each `.part`**: state cannot drift from
    data. **Reason for rejection**: Rejected by author: puts hidden files in
    the user's Downloads folder, keeps no history, and sync tools may upload
    them.

### How URLs reach the running app

*   **`dl://` URL scheme**: no native code, and the same extension code
    works in every browser. **Reason for rejection**: Rejected by author:
    each URL goes through LaunchServices (~50-300 ms), brings the app to the
    front, triggers browser "Open dl?" prompts, needs an in-app confirmation
    step against web pages, and returns no reply.
*   **Inbox folder watched with FSEvents**: simplest command. **Reason for
    rejection**: Rejected by author: about 1 s delay, no reply, and browser
    extensions cannot write to it.

### io_uring

*   **Pros**: cheaper file I/O syscalls on Linux.
*   **Cons**: does not exist on macOS; on Linux `tokio-uring` only speeds up
    file writes, while sockets stay on epoll; often blocked in containers.
*   **Reason for rejection**: Rejected by author: downloads are network-bound,
    so it adds a Linux-only runtime for no measurable gain.

--------------------------------------------------------------------------------

### Future Improvements

*   **Browser extension.** Chrome and Firefox call the `dl` CLI as a native
    messaging host. Safari ships a Safari Web Extension inside `dl.app`
    whose sandboxed Swift handler reaches the socket, which must then move
    into a team-signed App Group container. Persistent Safari installs need Apple Developer Program signing.
*   **Linux (GTK4) and Windows (WinUI 3) apps.** Revisit engine paths, the
    socket (named pipe on Windows), and `uniffi-bindgen-cs` async support
    when each port starts.
*   **Multi-connection downloads** for servers that limit speed per
    connection, on top of the tokio engine.

## Detailed Implementation Plan

All paths are relative to `~/local-scripts/rays/`, which is converted
in place from the egui prototype into the new workspace. The directory is
not under git, so the prototype's code is permanently removed (author
decision, 2026-11-16).

### Target Files to Create/Modify/Delete

#### 1. `./src/main.rs` (Delete)

*   **Type / Scope**: egui prototype.
*   **Proposed Changes**: delete. Its naming logic is reimplemented with
    RFC 5987 support in `engine/src/names.rs`, and its download loop is
    replaced by the tokio task in `engine/src/download.rs`.

#### 2. `./bin/dl` (Delete)

*   **Type / Scope**: prototype release binary.
*   **Proposed Changes**: delete. `scripts/bundle-app.sh` writes
    `bin/dl.app` and `bin/dl` (the CLI) instead.

#### 3. `./Cargo.toml` (Modify)

*   **Type / Scope**: build configuration.
*   **Proposed Changes**: replace the `[package]` with a
    `[workspace]` with `members = ["engine", "cli", "bindgen"]`, `resolver = "3"`.
    Add `[profile.release]` with `strip = true`, `lto = true`,
    `codegen-units = 1`, `opt-level = "s"`. Drop the `eframe` and `ureq`
    dependencies.

#### 4. `./Cargo.lock` (Modify)

*   **Type / Scope**: lockfile.
*   **Proposed Changes**: regenerated by Cargo for the new dependency set.

#### 5. `./.gitignore` (Modify)

*   **Type / Scope**: ignore rules.
*   **Proposed Changes**: keep `target/` and `bin/`; add `build/`,
    `macos/.build/`, and `macos/Sources/DL/Generated/`.

#### 6. `./engine/Cargo.toml` (Create)

*   **Type / Scope**: engine crate manifest, package `dl-engine`.
*   **Proposed Changes**: `crate-type = ["staticlib", "lib"]`. Features:
    `default = ["full"]`; `full` enables `tokio`, `reqwest`, `rusqlite`,
    `uniffi`. `serde` and `serde_json` are always on so the CLI can use the
    protocol module alone. Dependencies are kept to the minimum for binary
    size (author decision, 2026-11-16): `tokio` (`rt-multi-thread`, `net`,
    `fs`, `sync`, `time`, `macros`, `io-util`); `reqwest` with
    `default-features = false` and only `native-tls` (macOS
    Security.framework, no bundled crypto) and `system-proxy`, no HTTP/2,
    bodies read with `Response::chunk()`; `rusqlite` linked to the system
    `libsqlite3` (not `bundled`); `uniffi` without its `tokio` feature
    (async exports await a `JoinHandle` from the engine's own runtime).
    Cancellation uses `tokio::sync::watch`; errors implement `Display` by
    hand; percent-decoding is hand-written. Dev-dependencies: `tempfile`,
    `axum`, `tower-http` (`fs`), `sha2`.

#### 7. `./engine/src/lib.rs` (Create)

*   **Type / Scope**: engine public API.
*   **Proposed Changes**: `uniffi::setup_scaffolding!()`. Defines the
    records and enums from the Technical Plan (`EngineConfig`, `JobState`,
    `JobView`, `JobEvent`, `AddResult`) and the `Engine` object with
    `new`, `add`, `pause`, `resume`, `remove`, `snapshot`,
    `next_events` (`#[uniffi::export(async_runtime = "tokio")]`), and
    `shutdown`. `Engine` owns a tokio runtime, the `Scheduler`, the
    `Store`, the `EventHub`, and the IPC listener task. Errors are one
    `EngineError` enum (`Io`, `Db`, `SocketInUse`, `InvalidUrl`) exported to
    Swift as a thrown error. Modules `names`, `download`, `scheduler`,
    `events`, `store`, `ipc` are gated on `full`; `protocol` is always
    built.

#### 8. `./engine/src/names.rs` (Create)

*   **Type / Scope**: pure functions plus unit tests.
*   **Proposed Changes**: `from_disposition(header) -> Option<String>`
    (prefers `filename*=UTF-8''...`, falls back to `filename=`);
    `from_url(url) -> String` (last path segment after the host,
    percent-decoded, query and fragment stripped, else `download`);
    `sanitize(name) -> String` (final component only, strips `/ \ :` and
    control characters, rejects `.`/`..`, trims to 255 bytes on a
    character boundary); `part_path(dir, name, id)` returns
    `<name>.<id>.part`; `unique_final(dir, name) -> PathBuf` (first free
    `name.ext`, `name (1).ext`, ...). Unit tests cover traversal
    (`../../evil.sh`), RFC 5987 UTF-8 names, bare host URLs, a name of 300
    bytes, and collisions.

#### 9. `./engine/src/download.rs` (Create)

*   **Type / Scope**: one download attempt loop.
*   **Proposed Changes**: `async fn run(job: JobHandle, client: &Client,
    cancel: CancellationToken) -> Outcome` implementing Technical Plan
    steps 1-5: `Range` + `If-Range` on resume; 206 append, 200 truncate
    and set `resumable` from `Accept-Ranges`, 416 finish, other 4xx fail
    at once, 5xx and network errors retry with waits of 2, 5, 15, 30,
    60 s (the attempt counter resets after any attempt that received
    bytes); `tokio::select!` between the next body chunk and
    `cancel.cancelled()`; the length check on finish, `sync_all`, then
    rename to `names::unique_final`. Updates an `AtomicU64` byte counter
    and calls `EventHub::progress` per chunk. Records `ETag` and
    `Last-Modified` on the job the first time they're seen.

#### 10. `./engine/src/scheduler.rs` (Create)

*   **Type / Scope**: queue and concurrency control.
*   **Proposed Changes**: holds jobs in insertion order (`position`).
    Starts queued jobs while fewer than `max_running` (default 3) are
    running. `pause(id)` cancels the job's token and marks it `Paused`;
    `resume(id)` sets it to `Queued`; `remove(id, delete_partial)`
    cancels, deletes the row, and deletes the `.part` file if asked.
    Re-checks the queue whenever a job finishes, fails, or pauses. Every
    state change goes to both `Store` and `EventHub`.

#### 11. `./engine/src/events.rs` (Create)

*   **Type / Scope**: event coalescing.
*   **Proposed Changes**: `EventHub` keeps the set of job ids with pending
    changes and a `tokio::sync::Notify`. `state_changed(id)` wakes waiters
    at once; `progress(id)` marks the id dirty and wakes waiters no sooner
    than 250 ms after the last delivery. `next_events()` waits on
    `Notify`, drains the dirty set, and builds a `JobView` for each id
    (`Removed` for ids that no longer exist). Speed is computed per job
    from the byte counter between deliveries.

#### 12. `./engine/src/store.rs` (Create)

*   **Type / Scope**: SQLite persistence.
*   **Proposed Changes**: opens `<data_dir>/queue.db` with `journal_mode
    = WAL`. Migration 1 creates the `jobs` table from the Technical Plan,
    tracked through `PRAGMA user_version`. Functions: `load_all`,
    `insert`, `update_state`, `update_progress` (called every 2 s while
    running), `delete`. `load_all` reconciles with disk: the `.part`
    length replaces `done`; a missing `.part` sets `done = 0`; any job
    that was `Running`, `Queued`, or `Retrying` becomes `Paused`. All
    calls run on `spawn_blocking` behind one `Mutex<Connection>`.

#### 13. `./engine/src/protocol.rs` (Create)

*   **Type / Scope**: socket message types (built without `full`).
*   **Proposed Changes**: serde types `Request::{Add{urls}, List}` tagged by
    `op`, and `Response{ok, added, rejected, jobs, error}` matching the
    JSON examples in the Technical Plan. One message per line, at most
    1 MiB per line.

#### 14. `./engine/src/ipc.rs` (Create)

*   **Type / Scope**: Unix socket listener.
*   **Proposed Changes**: `bind(path)`: create the parent directory with
    mode `0700`; if the socket exists, try to connect; `ConnectionRefused`
    means delete and bind, a successful connect means return
    `EngineError::SocketInUse`. Set the socket file to `0600`. Accept loop:
    each connection reads one JSON line per request (max 1 MiB), calls
    `Scheduler::add` or builds a list, writes one reply line, and closes
    after 10 s idle. The socket file is removed on `shutdown()`.

#### 15. `./bindgen/` (Create)

*   **Type / Scope**: separate workspace crate `uniffi-bindgen` (binary).
*   **Proposed Changes**: `fn main() { uniffi::uniffi_bindgen_main() }` with
    `uniffi`'s `cli` feature. Kept out of `dl-engine` so the bindings
    generator's code is never compiled into the app's static library.

#### 16. `./engine/tests/engine.rs` (Create)

*   **Type / Scope**: integration tests against a local HTTP server.
*   **Proposed Changes**: an `axum` server on `127.0.0.1:0` that serves a
    10 MB file of random bytes through `tower-http` `ServeDir` (real
    `Range`/`ETag` support), plus custom routes: one that cuts the
    connection after 3 MB, one that ignores `Range` (always 200, no
    `Accept-Ranges`), one that changes the ETag between requests, a 404,
    and one with `Content-Disposition: attachment;
    filename="../../evil.sh"`. Tests: full download matches the source
    SHA-256; cut connection resumes and matches; changed ETag restarts
    from zero; ignored Range sets `resumable = false`; 404 fails without
    retry; the evil name lands as `evil.sh` inside the downloads folder;
    two jobs with the same URL produce `x.bin` and `x (1).bin`; restarting
    the `Engine` on the same `data_dir` restores jobs as `Paused` with the
    `.part` length; `max_running = 1` keeps the second job `Queued`; pause
    on a stalled route takes effect in under 100 ms; socket `add` from a
    second connection returns ids.

#### 17. `./cli/Cargo.toml` (Create)

*   **Type / Scope**: CLI crate manifest, binary name `dl`.
*   **Proposed Changes**: depends on `dl-engine` with
    `default-features = false` (protocol types only), plus `serde_json`.
    No tokio, no reqwest, so it stays under 1 MB.

#### 18. `./cli/src/main.rs` (Create)

*   **Type / Scope**: command-line client.
*   **Proposed Changes**: `dl URL...` sends `Add`; `dl --list` sends `List`
    and prints one line per job. Connects to the socket path constant; if
    the socket is missing or refuses the connection, runs `open -b
    local.lawbringr.dl` and retries every 200 ms for up to 5 s. Prints
    `added <id> <url>` or `rejected <url>: <reason>` per URL. Exit codes:
    0 if all added, 1 if any rejected, 2 if the app could not be reached.
    Uses only `std::os::unix::net::UnixStream`.

#### 19. `./macos/Package.swift` (Create)

*   **Type / Scope**: Swift Package Manager manifest.
*   **Proposed Changes**: platform `.macOS(.v14)`; `binaryTarget(name:
    "DLEngineFFI", path: "../build/DLEngineFFI.xcframework")`;
    `executableTarget(name: "DL", dependencies: ["DLEngineFFI"])`.

#### 20. `./macos/Sources/DL/DLApp.swift` (Create)

*   **Type / Scope**: SwiftUI app entry.
*   **Proposed Changes**: `@main struct DLApp: App` with one `Window`
    holding `ContentView`, environment `EngineModel`. An
    `NSApplicationDelegate` adapter implements
    `applicationShouldTerminate`: if any job is running with `resumable
    == false`, show the warning that lists those jobs (Cancel / Quit
    Anyway); then call `engine.shutdown()`.

#### 21. `./macos/Sources/DL/EngineModel.swift` (Create)

*   **Type / Scope**: view model.
*   **Proposed Changes**: `@MainActor @Observable final class EngineModel`.
    Creates `Engine` with `downloads_dir` from
    `FileManager.default.urls(for: .downloadsDirectory, ...)`, `data_dir`
    `~/Library/Application Support/dl`, the group-container socket path,
    and `max_running` 3. On engine start failure, holds an error string
    the view shows instead of the list. `jobs: [JobView]` in queue order,
    filled from `snapshot()`. `func run() async` loops `for` events from
    `await engine.nextEvents()` until cancelled, applying `Upsert` and
    `Removed`. Methods `add(text)` (splits on whitespace and newlines),
    `pause`, `resume`, `remove`, `reveal(path)`.

#### 22. `./macos/Sources/DL/ContentView.swift` (Create)

*   **Type / Scope**: main window view.
*   **Proposed Changes**: a `TextField("Paste URLs", ...)` with a
    Download button (Return also submits), above a `List` of `JobRow`.
    `.task { await model.run() }`. `.dropDestination(for: URL.self)` adds
    dropped URLs. Empty state: "Downloads go to ~/Downloads".

#### 23. `./macos/Sources/DL/JobRow.swift` (Create)

*   **Type / Scope**: one job row.
*   **Proposed Changes**: name; `ProgressView(value:total:)`, indeterminate
    when the total is unknown; status text ("12.4 MB of 80 MB · 3.1 MB/s",
    "Paused", "Retrying (2/5)", "Failed: <reason>", "Done"); a "Can't
    resume" badge when `resumable == false`. Buttons: Pause or Resume,
    **Stop** instead of Pause for non-resumable running jobs, confirmed by
    `.confirmationDialog("Stopping loses <done> of progress. Stop
    anyway?")`; Show in Finder for done jobs; Remove (asks whether to delete
    the partial file when one exists). Each button has an
    `accessibilityLabel` naming the job.

#### 24. `./macos/Resources/Info.plist` (Create)

*   **Type / Scope**: app bundle metadata.
*   **Proposed Changes**: `CFBundleIdentifier` `local.lawbringr.dl`,
    `CFBundleName` `dl`, `CFBundleExecutable` `DL`,
    `LSMinimumSystemVersion` `14.0`, `CFBundlePackageType` `APPL`,
    `NSHighResolutionCapable` true.

#### 25. `./scripts/build-engine.sh` (Create)

*   **Type / Scope**: build script (bash, `set -euo pipefail`).
*   **Proposed Changes**: `cargo build --release -p dl-engine --target
    aarch64-apple-darwin` and `--target x86_64-apple-darwin` (installs the
    targets with `rustup target add` if missing); `lipo -create` into
    `build/libdl_engine.a`; `cargo run -p uniffi-bindgen
    -- generate --library ... --language swift --out-dir build/swift`; copy
    `dl_engine.swift` into `macos/Sources/DL/Generated/`; build
    `build/DLEngineFFI.xcframework` with `xcodebuild -create-xcframework`
    from the static library and the generated headers and module map.

#### 26. `./scripts/bundle-app.sh` (Create)

*   **Type / Scope**: packaging script.
*   **Proposed Changes**: runs `build-engine.sh`, then `swift build -c
    release --package-path macos --arch arm64 --arch x86_64`; assembles
    `bin/dl.app/Contents/{MacOS/DL, Info.plist}`; `codesign --force -s -`
    on the bundle; `cargo build --release -p dl-cli` and copies the binary
    to `bin/dl`. Prints the bundle size.

#### 27. `./README.md` (Create)

*   **Type / Scope**: documentation.
*   **Proposed Changes**: what `dl` is; build (`scripts/bundle-app.sh`); run
    (`open bin/dl.app`, `bin/dl URL...`); file locations (`queue.db`,
    `dl.sock`, `.part` naming); how it works with `sorter watch
    ~/Downloads`; not sandboxed, ad-hoc signed.

No files outside `~/local-scripts/rays/` change. `sorter` already
skips `.part` files, so it needs no change.

### Verification Plan

*   **Compilation/Build**: `cargo build --release --workspace`;
    `scripts/bundle-app.sh` completes and produces `bin/dl.app` and
    `bin/dl`.
*   **Unit Tests**: `cargo test -p dl-engine` (names, store migration and
    reconciliation, event coalescing).
*   **Integration Tests**: `cargo test -p dl-engine --test engine` (all
    cases listed in file 16).
*   **Static Analysis & Linting**: `cargo clippy --workspace -- -D
    warnings`; `cargo fmt --check`.
*   **Size and memory goals**: `du -sh bin/dl.app` under 10 MB; `ls -l
    bin/dl` under 1 MB; with 20 finished jobs listed and the app idle for
    30 s, `footprint -p $(pgrep -x DL)` under 50 MB and `ps -o %cpu` at 0.
*   **E2E (manual, maps to the CUJs)**:
    *   CUJ 1: with `sorter watch ~/Downloads` active, download a PDF;
        confirm `sorter` never logs the `.part` file and moves the final
        file.
    *   CUJ 2: start a large download, turn Wi-Fi off for 60 s, turn it
        on; the row shows "Retrying", then finishes; `shasum -a 256`
        matches the source's published checksum.
    *   CUJ 3: quit with jobs running, reopen; all show as Paused with
        byte counts; Resume continues from there.
    *   CUJ 4: with the app open, `bin/dl URL1 URL2` prints two `added`
        lines and no second window opens; with the app closed, the same
        command launches it and adds both.
    *   Non-resumable: a URL from a server without `Accept-Ranges` shows
        "Can't resume" and Stop asks for confirmation; quitting warns.
    *   VoiceOver: every row's buttons announce the action and job name.

--------------------------------------------------------------------------------

*Drafted with EGM*
