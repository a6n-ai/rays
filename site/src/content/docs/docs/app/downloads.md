---
title: "Download files faster on Mac"
description: "How Rays speeds up downloads on Mac: parallel connections, automatic retries, resume after quitting, speed limits, and pasting many links at once."
---

## Add links

- **Paste:** press **⌘L**, paste, and press **Return**. Paste as many links as you like, one per line, separated by commas or spaces, or a whole CSV. Rays picks out every `http://` and `https://` link and ignores the text around them. The bar shows how many it found, or **No link found**.
- **Drop:** drag links, text that contains links, or `.webloc` files onto the window.
- **Browser:** right-click a link and choose **Download with Rays** ([Browser extension](/docs/app/browser/)).
- **Terminal:** `dl https://github.com/a6n-ai/rays/releases/latest/download/Rays.dmg` ([The dl command](/docs/dl/)).

- **Copy:** copy a download link anywhere on your Mac and Rays offers to download it in a notification. Turn this off with **Offer copied download links** in Settings.

Downloads go to `~/Downloads` unless you choose another folder in **Settings > General**.

## How Rays downloads

- **Smart splitting.** Files of 32 MB or more start on 4 connections; smaller ones on one. Rays doubles the count, up to 16, only while each step makes the file faster, steps back down when more stop helping, and replaces a connection that is far slower than the others. A finished part takes over half of the largest part left. See [How the engine works](/docs/engine/).
- **Slow servers.** When a server pushes back or drops connections, Rays remembers it and uses fewer connections next time. A server that cannot send parts gets one connection.
- **Retries.** Up to 5 automatic retries, waiting 2 seconds at first and up to a minute.
- **Resume.** Pause a download, or quit Rays, and it continues later from the bytes already saved. While a file is downloading it is named `<name>.<id>.part` and renamed only when it is complete.
- **Safe names.** Rays takes the name the server suggests and cleans it, so a file can never land outside your folder.

## Speed and limits

- The toolbar's **Speed Limit** menu caps bandwidth for all downloads.
- **Settings > Downloads** sets how many files download at once (1 to 10) and how many parts each file uses (1 to 16).

## The Downloads list

- **Filter** by status (All, Active, Finished, Failed) or by type (Documents, Images, Video, Audio, Archives, Apps and installers, Other).
- **Sort** by Newest first, Oldest first, Name or Largest first.
- The list shows 50 downloads per page, with an icon for each file's type. The Sorter's recent moves and the Cloud downloads list use the same controls.
- The toolbar has three buttons in the middle on every page: **Recent downloads** first, the folder, and settings last.
- Double-click a finished download to open it.
- **Remove Missing** clears finished downloads whose file was moved or deleted. Files that are still there stay.

## In the Dock and menu bar

- While files download, the Rays icon in the Dock shows a progress bar and a badge with how many are downloading.
- The menu bar icon is Rays' stacked pages. A red badge shows how many downloads are running. Click it to open the panel.
- The panel has a box to paste a link with **Download**, **Add Links from a File**, **Download Link from Clipboard**, **Pause All** and **Resume All**, and the latest four downloads. **See All in Rays** opens the full list. **Clear** hides them from the panel only. It also has **Downloads**, **Sorter** and **Cloud**, **Open Rays**, **Settings** and **Quit Rays**.
- Click a finished download in the panel to open it. Right-click for **Open**, **Show in Finder**, **Remove from Rays** and **Move to Trash**.
- Closing the window, or choosing **Keep Downloading in Menu Bar** from the Dock menu, keeps Rays running in the menu bar without a Dock icon, so downloads carry on. To quit, choose **Quit Rays** in the menu bar panel, which quits fully, or right-click Rays in the Dock and choose **Quit**. **Settings > General > Show in menu bar** turns the menu bar icon off; then closing the window quits Rays.
- While anything downloads, Rays keeps macOS from slowing it in the background (App Nap) and keeps the Mac from going to sleep on its own. The display can still turn off.

## Finished files

Drag a finished download out of the window to copy it somewhere else. If the [sorter](/docs/app/sorter/) watches your download folder, finished files are moved into category folders a few seconds after they complete.
