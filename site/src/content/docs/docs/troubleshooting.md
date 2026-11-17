---
title: Troubleshooting
description: Fixes for common problems, and where Rays keeps its files.
---

## macOS says it can't verify Rays

Rays is not notarized yet. Open **System Settings > Privacy & Security**, scroll down, and choose **Open Anyway**. Homebrew installs skip this.

## `dl: app not reachable`

`dl` could not reach the Rays app. Open Rays and try again. If you set `DL_NO_LAUNCH` or `DL_SOCKET`, `dl` does not open the app for you.

## `dl: sorter not found next to ...`

The `dl` you ran is not the one inside Rays.app. Use the Homebrew `dl`, link the one in `/Applications/Rays.app/Contents/MacOS/dl`, or set `DL_SORTER`.

## A file was not sorted

- Files that were in a folder before you added it are left alone. Run `dl sort FOLDER --all` once.
- Rays waits after a file arrives (10 seconds by default) and skips files still being written.
- Check **Sorter > Setup**: the folder must be listed, and **On-device AI** must be ready for content-based sorting.

## Download with Rays does nothing in the browser

Open **Settings > Browsers**. The browser should show **Connected to Rays**. If it says the helper is missing or needs repair, click **Install All Helpers** and reload the extension. Firefox temporary add-ons are removed when Firefox restarts.

## Where Rays keeps files

| What | Where |
|---|---|
| Downloads | `~/Downloads/<name>` (or your chosen folder) |
| In progress | `<name>.<id>.part` next to it, renamed when complete |
| Queue and history | `~/Library/Application Support/Rays/queue.db` |
| `dl` socket | `~/Library/Application Support/Rays/dl.sock` |

## Permissions

Rays is not sandboxed and asks for no special permissions. macOS may ask once for access to the Downloads folder.

## Still stuck?

Open an issue on [GitHub](https://github.com/a6n-ai/rays/issues) or email hi@a6n.ai.
