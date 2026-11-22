---
title: "Download files faster on Mac"
description: "How Rays speeds up downloads on Mac: parallel connections, automatic retries, resume after quitting, speed limits, and pasting many links at once."
---

## Add links

- **Paste:** press **⌘L**, paste, and press **Return**. Paste as many links as you like, one per line, separated by commas or spaces, or a whole CSV. Rays picks out every `http://` and `https://` link and ignores the text around them. The bar shows how many it found, or **No link found**.
- **Drop:** drag links, text that contains links, or `.webloc` files onto the window.
- **Browser:** right-click a link and choose **Download with Rays** ([Browser extension](/docs/app/browser/)).
- **Terminal:** `dl https://github.com/a6n-ai/rays/releases/latest/download/Rays.dmg` ([The dl command](/docs/dl/)).

Downloads go to `~/Downloads` unless you choose another folder in **Settings > General**.

## How Rays downloads

- **Smart splitting.** A download starts on one connection. For files of 4 MB or more, Rays adds connections, up to 16, only while each one makes the file faster, and a finished part takes over half of the largest part left. See [How the engine works](/docs/engine/).
- **Slow servers.** When a server pushes back or drops connections, Rays remembers it and uses fewer connections next time. A server that cannot send parts gets one connection.
- **Retries.** Up to 5 automatic retries, waiting 2 seconds at first and up to a minute.
- **Resume.** Pause a download, or quit Rays, and it continues later from the bytes already saved. While a file is downloading it is named `<name>.<id>.part` and renamed only when it is complete.
- **Safe names.** Rays takes the name the server suggests and cleans it, so a file can never land outside your folder.

## Speed and limits

- The toolbar's **Speed Limit** menu caps bandwidth for all downloads.
- **Settings > Downloads** sets how many files download at once (1 to 10) and how many parts each file uses (1 to 16).

## In the Dock and menu bar

- While files download, the Rays icon in the Dock shows a progress bar and a badge with how many are downloading.
- The Rays icon in the menu bar shows the overall percent. Click it to see your downloads, pause or resume them, download a link you copied, or open Rays.
- Closing the window keeps Rays running in the menu bar, so downloads carry on. To quit, choose **Quit Rays** in the menu bar panel, or right-click Rays in the Dock and choose **Quit**. **Settings > General > Show in menu bar** turns the menu bar icon off; then closing the window quits Rays.
- While anything downloads, Rays keeps macOS from slowing it in the background (App Nap) and keeps the Mac from going to sleep on its own. The display can still turn off.

## Finished files

Drag a finished download out of the window to copy it somewhere else. If the [sorter](/docs/app/sorter/) watches your download folder, finished files are moved into category folders a few seconds after they complete.
