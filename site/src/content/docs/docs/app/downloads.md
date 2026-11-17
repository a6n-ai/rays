---
title: "Download files faster on Mac"
description: "How Rays speeds up downloads on Mac: parallel connections, automatic retries, resume after quitting, speed limits, and pasting many links at once."
---

## Add links

- **Paste:** press **⌘L**, paste, and press **Return**. Paste as many links as you like, one per line, separated by commas or spaces, or a whole CSV. Rays picks out every `http://` and `https://` link and ignores the text around them. The bar shows how many it found, or **No link found**.
- **Drop:** drag links, text that contains links, or `.webloc` files onto the window.
- **Browser:** right-click a link and choose **Download with Rays** ([Browser extension](/docs/app/browser/)).
- **Terminal:** `dl https://example.com/file.zip` ([The dl command](/docs/dl/)).

Downloads go to `~/Downloads` unless you choose another folder in **Settings > General**.

## How Rays downloads

- **Smart splitting.** Files of 4 MB or more come down in parts over up to 16 connections. Rays adds connections while the speed keeps rising, and a finished part takes over half of the slowest part's work.
- **Slow servers.** When a server pushes back or drops connections, Rays remembers it and uses fewer connections next time. A server that cannot send parts gets one connection.
- **Retries.** Up to 5 automatic retries, waiting 2 seconds at first and up to a minute.
- **Resume.** Pause a download, or quit Rays, and it continues later from the bytes already saved. While a file is downloading it is named `<name>.<id>.part` and renamed only when it is complete.
- **Safe names.** Rays takes the name the server suggests and cleans it, so a file can never land outside your folder.

## Speed and limits

- The toolbar's **Speed Limit** menu caps bandwidth for all downloads.
- **Settings > Downloads** sets how many files download at once (1 to 10) and how many parts each file uses (1 to 16).

## Finished files

Drag a finished download out of the window to copy it somewhere else. If the [sorter](/docs/app/sorter/) watches your download folder, finished files are moved into category folders a few seconds after they complete.
