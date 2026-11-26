---
title: "Add downloads"
description: "Everything you can paste into Rays: many links at once, a page to scan for files, a link with its SHA-256, mirrors of one file, cloud and Hugging Face links."
---

## The add bar

The **+** button at the left of the add bar lists everything you can add: paste links, find links on a page, a cloud bucket, a Hugging Face model, and a checksum or mirror for a link. While you type, a line above the bar counts the links, checksums, mirrors and cloud links Rays found. The menu on the **Download** button picks the queue.

- **Paste:** press **⌘L**, paste, and press **Return**. Paste as many links as you like, one per line, separated by commas or spaces, or a whole CSV. Rays picks out every `http://` and `https://` link and ignores the text around them. The bar shows how many it found, or **No link found**. To check a file, see [Links that keep working](#links-that-keep-working).
- **Find links on a page:** paste one web page link, open the menu on the download button and choose **Find links on a page…** (in the **+** menu it is **Find links on a page…**). Rays reads the page and lists the files it links to, all checked. Filter by type, uncheck what you do not want, then choose **Download now** or **Add to queue**. If the link is a file instead of a page, Rays says so.
- **Drop:** drag links, text that contains links, or `.webloc` files onto the window.
- **Browser:** right-click a link and choose **Download with Rays** ([Browser extension](/docs/app/browser/)).
- **Terminal:** `dl https://github.com/a6n-ai/rays/releases/latest/download/Rays.dmg` ([The dl command](/docs/dl/)).

- **Copy:** copy a download link anywhere on your Mac and Rays offers to download it in a notification. Turn this off with **Offer copied download links** in Settings.

Downloads go to `~/Downloads` unless you choose another folder in **Settings > General**.

## Links that keep working
- **Checksums.** Put a SHA-256 (64 hex characters) on the same line as a link, or choose **Add a checksum…** in the **+** menu, with one link per line. When the file finishes, Rays checks it. A file that does not match fails with **Checksum didn't match** and is deleted, and a matching one shows **Checksum matched**. `dl add --sha256` does the same from Terminal.
- **Mirrors.** Paste several links on one line, separated by spaces, with the same file name at the end of each path and a different site (host) for each, and Rays treats them as one file with mirrors. Links on the same site with the same file name, such as `/2023/report.pdf` and `/2024/report.pdf`, stay separate downloads. The bar shows how many mirrors it found, and the download shows **N mirrors**. Rays splits the file across the fastest links and keeps going on the others if one fails. A mirror with a different size or no range support is ignored.
- **Expired links.** If a link stops working partway (HTTP 403, 404 or 410), the download shows **Link expired** with an **Update link…** button. Paste a fresh link for the same file and Rays keeps the part already saved and carries on. If the new link reports a different size, Rays asks before starting the download over. A link to a web page is refused. **Update Link…** is also in the right-click menu of paused and failed downloads, and `dl relink ID URL` does the same from the terminal.

Other ways to send links to Rays, such as the Share menu, Shortcuts and Siri, are on [Shortcuts and the Share menu](/docs/app/shortcuts/).
