---
title: "Download files faster on Mac"
description: "How Rays speeds up downloads on Mac: parallel connections, automatic retries, resume after quitting, speed limits, and pasting many links at once."
---

To add links, see [Add downloads](/docs/app/add-links/). For Shortcuts, Siri and the Share menu, see [Shortcuts and the Share menu](/docs/app/shortcuts/).

## How Rays downloads

- **Start now, or queue it.** A download starts at once, in no queue. To run it later, pick a queue in the **Download** button's menu, or use **Move to Queue**. See [Queues and schedules](/docs/app/queues/).
- **Smart splitting.** Files of 32 MB or more start on 4 connections; smaller ones on one. Rays doubles the count, up to 16, only while each step makes the file faster, steps back down when more stop helping, and replaces a connection that is far slower than the others. A finished part takes over half of the largest part left. See [How the engine works](/docs/engine/).
- **Slow servers.** When a server pushes back or drops connections, Rays remembers it and uses fewer connections next time. A server that cannot send parts gets one connection.
- **Retries.** Up to 5 automatic retries, waiting 2 seconds at first and up to a minute.
- **Resume.** Pause a download, or quit Rays, and it continues later from the bytes already saved. While a file is downloading it is named `<name>.<id>.part` and renamed only when it is complete.
- **Safe names.** Rays takes the name the server suggests and cleans it, so a file can never land outside your folder.
- **Same name.** **If a file with the same name exists** in the Downloads page's Settings card sets what happens to a file that is already there. **Keep both** (the default) saves the new file as `name (1).ext`. **Replace** moves the old file to the Trash once the new one finishes, so a failed download never costs you the old file. It replaces files you already had and files Rays downloaded earlier. Only two downloads of the same name that run at the same time keep both. The setting applies to every download. Some apps, like LM Studio, need a model's exact file names, so choose **Replace** if you re-download models into the same folder.

## Speed and limits

The Downloads page starts with a page card, then a folding **Settings** card that holds the settings for downloads: **Save downloads to**, **Offer copied download links**, **Notify when downloads finish**, **Downloads at once**, **Parts per file**, **Speed limit**, **Unpack archives when done** and **If a file with the same name exists**. Click its header to fold or unfold it.

- **Speed limit** in the Downloads page's Settings card caps bandwidth for all downloads. The page's **⋯** menu has the same presets.
- The same card sets **Downloads at once** (1 to 10) and **Parts per file** (1 to 16).

## Activity in the sidebar

While a download is running, retrying, verifying or about to start, a dot appears next to **Downloads** in the sidebar, and a card above **Speed test** shows what is happening: how many files, the combined speed, the time left, and progress for the two newest files. Click the card to open Downloads. Both disappear when nothing is active.

## The Downloads list

- **Filter** by status (All, Active, Finished, Failed) or by type (Documents, Images, Video, Audio, Archives, Apps and installers, Other).
- **Sort** by Newest first, Oldest first, Name or Largest first.
- Every long list has pages, 50 items each by default, with an icon for each file's type. When a list is longer than 25 items, a menu next to the page arrows sets 25, 50, 100 or 200 per page for every list in the app. The Sorter's recent moves, the Cloud downloads list and the other long lists use the same controls.
- **Clear finished** at the top of the page removes finished downloads from the list. Files stay on disk. **Files** under the Settings card browses the Downloads folder.
- Double-click a finished download to open it.
- **Move to Trash** sits next to **Show in Finder** on a finished download.
- **Remove Missing** clears finished downloads whose file was moved or deleted. Files that are still there stay.
- **Undo.** Removing a download or moving it to the Trash shows a pill at the top of the window with **Undo** (or press Command-Z) for six seconds; Undo puts the file back where it was and brings the row back. The pill is coloured by what happened: orange for the Trash, blue for a removed row, green for updates and red for errors.

## Notifications
Rays posts a notification when a download finishes or fails, with **Open**, **Show in Finder** or **Retry** on it. Downloads that end close together come as one summary. Turn this off with **Notify when downloads finish** in the Downloads page's Settings card.
## In the Dock and menu bar

- While files download, the Rays icon in the Dock shows the download speed, a progress bar and a red badge with how many are downloading. The badge needs **Badge application icon** on in **System Settings > Notifications > Rays**.
- The menu bar icon is Rays' stacked pages. A red badge shows how many downloads are running. While downloading, the overall percentage shows next to it, then the speed. Click it to open the panel.
- The panel has a box to paste a link with **Download**, **Add Links from a File**, **Download Link from Clipboard**, **Pause All** and **Resume All**, and the latest four downloads. **See All in Rays** opens the full list. **Clear** hides them from the panel only. It also has **Downloads**, **Sorter** and **Cloud**, **Open Rays**, **Settings…** (which opens the General page) and **Quit Rays**.
- The **+** next to the panel's link box offers **Find links on a page**, **From a cloud bucket**, **Hugging Face model**, **Add a checksum** and **Add a mirror**, and opens Rays at the right place. The panel also links to **Queues**, **Schedules**, **Speed Test** and **Shortcuts**.
- Click a finished download in the panel to open it. Right-click for **Open**, **Show in Finder**, **Remove from Rays** and **Move to Trash**.
- Closing the window, or choosing **Keep Downloading in Menu Bar** from the Dock menu, keeps Rays running in the menu bar without a Dock icon, so downloads carry on. To quit, choose **Quit Rays** in the menu bar panel, which quits fully, or right-click Rays in the Dock and choose **Quit**. **Show in menu bar** on the **General** page turns the menu bar icon off; then closing the window quits Rays.
- While anything downloads, Rays keeps macOS from slowing it in the background (App Nap) and keeps the Mac from going to sleep on its own. The display can still turn off.

## Finished files

Drag a finished download out of the window to copy it somewhere else. If the [sorter](/docs/app/sorter/) watches your download folder, finished files are moved into category folders a few seconds after they complete.
