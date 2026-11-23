---
title: "Features"
description: "Everything Rays does: adaptive multi-connection downloads, crash-safe resume, on-device AI sorting, S3 buckets, browser extensions for Chrome and Firefox, a dl command and an MCP server. Free and open source."
---

Rays is free, open source (AGPL-3.0) and made for macOS 26. There is no account, no ads and no tracking.

## Numbers

| What | Rays |
|---|---|
| Connections per file | 1 to 16, added only while each one makes the file faster |
| Files at once | 1 to 10 |
| Automatic retries | 5, waiting 2, 5, 15, 30 and 60 seconds |
| A stalled download | Retried after 30 seconds with no data |
| A server that pushes back | Its lower limit is remembered for 7 days |
| Data sent to a6n | None. No analytics, tracking or crash reporting |
| Price | Free |

How Rays tests its engine, with the script to rerun it: [Benchmarks](/docs/engine/#benchmarks).

## Downloads

- **Paste anything.** Links one per line, separated by commas, a whole CSV, or text with links in it. Rays finds every link. Or drop links and `.webloc` files on the window.
- **Smart splitting.** Big files start on 4 connections. Rays doubles them only while they make the file faster, steps back down when they stop helping, and replaces a connection that is far slower than the others. [How it works](/docs/engine/).
- **Pause, resume, quit.** Downloads continue from the bytes already saved, after a pause, a quit or a crash.
- **Filter and sort** the Downloads list by status or type, in pages of 50, with an icon for each file's type. **Remove Missing** clears finished downloads whose file is gone. Double-click a finished download to open it.
- **Copied links.** Copy a download link anywhere on your Mac and Rays offers to download it.
- **Speed limit** and how many files download at once.
- **Safe names.** The server's suggested name is cleaned, so a file can never land outside your folder.
- **Share** finished downloads with AirDrop or the Share menu, or drag them out of the window.
- **Remove from List** or **Move to Trash** from each row, or press Delete.

## Sorting with on-device AI

- Rays watches Downloads and any folder you add, and moves new files into folders that fit, like Installers, Archives, Images or Work.
- It can rename files from what's inside them. Turn that off to keep every original name.
- Sorting runs on your Mac with Apple's on-device model. File contents and names are never uploaded.
- The Downloads list follows the sorter: a sorted file's row shows where it went.

[Sorter](/docs/app/sorter/)

## Cloud buckets

- Download from Amazon S3, Cloudflare R2, Backblaze B2, Wasabi, MinIO and any S3-compatible service.
- Browse providers, buckets and folders like Finder, as icons or a list.
- Use an AWS CLI profile (saved keys, `aws login` or SSO) or your `cf` login, so Rays stores no secret. Keys you add yourself stay in the macOS Keychain.

[S3 buckets](/docs/s3/)

## Browsers

- Extensions for Chrome, Brave, Edge, Firefox and Zen add **Download with Rays** to the right-click menu.
- A popup on the Rays toolbar button shows whether Rays is connected, lets you paste a link, and updates itself with the store.
- Settings > Browsers lists every browser on your Mac and sets up any built on Chromium or Firefox, including Brave. Search, a WebKit browser that runs Chrome extensions, works too.
- Optionally hand every browser download to Rays. The browser's copy is cancelled only after Rays accepts the link.

[Browser extension](/docs/app/browser/)

## Command line and AI

- The `dl` command adds downloads, lists them, and sorts or watches folders.
- `dl mcp` is an MCP server, so AI assistants like Claude can download files and sort folders.

[The dl command](/docs/dl/) · [MCP](/docs/mcp/)

## The app

- The menu bar and Dock icons show the download speed and a badge with the downloads running. Its panel adds links, pauses all, lists the latest four downloads and opens Downloads, Sorter and Cloud.
- Close the window and Rays keeps downloading from the menu bar.
- Updates install themselves: click Update and Rays replaces itself and reopens.
- Install with the DMG or `brew trust a6n-ai/tap && brew install --cask a6n-ai/tap/rays`.
- Uninstall from Settings, which also removes the sorter, browser helpers and `dl`.
- Light, dark or system appearance.

## What Rays doesn't do

- **Torrents.** Not yet.
- **Video grabbing** from sites like YouTube. Rays downloads files from direct links.
- **Scheduling** downloads for a later time.
- **Windows or Linux.** Rays is a Mac app. The engine and `dl` are open source if you want to try them elsewhere.
