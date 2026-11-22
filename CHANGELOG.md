# Release notes

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
