---
title: "General, AI and Browsers"
description: "The Rays General, AI and Browsers pages: appearance, accent colour, menu bar, command line tool, updates, uninstalling, on-device AI and browser helpers."
---

Rays has no separate Settings window. **General**, **AI** and **Browsers** are pages at the bottom of the sidebar. **⌘,** (or **Settings…** in the Rays menu or menu bar panel) opens **General**. Changes save as you make them.

Every other setting sits on the page it belongs to, in the folding **Settings** card below the page card:

- **Downloads:** save folder, copied links, notifications, downloads at once, parts per file, speed limit, unpack archives and same name. See [Downloads](/docs/app/downloads/).
- **Models:** AI Models folder and Hugging Face token. See [Models](/docs/app/models/).
- **Sorter:** on-device AI status, sort delay and rename from content. See [Sorter](/docs/app/sorter/).
- **Queues:** defaults for new queues and wake permission. See [Queues and schedules](/docs/app/queues/).
- **Schedules:** wake permission.
- **Speed test:** automatic tests, night tests and clearing history. See [Speed test and best time](/docs/app/speed/).
- **Cloud:** adding a bucket. See [S3 buckets](/docs/s3/).

## General

- **Appearance:** **Light**, **Dark** or **Auto**. Auto follows macOS.
- **Colour:** the accent colour. **Multicolour** gives each page's icon its own colour. Blue, purple, pink, red, orange, yellow, green and graphite use one colour for the icons.
- **Sidebar icon size:** small, medium or large.
- **Show in menu bar:** the Rays icon in the menu bar, with download progress and quick actions. While it is on, closing the window keeps Rays running.
- **Command line tool:** **Install** puts the `dl` command that ships inside Rays on your PATH; **Remove** takes it off. It never replaces another program named `dl`.
- **Updates:** your version and **Check for updates**, or **Update to** a new version, and whether Rays checks automatically. An update downloads the new version, checks it, replaces Rays and reopens it. This works without an administrator account: when Rays can't add files to Applications, it replaces its own files in place.
- **Uninstall Rays…:** red text at the bottom of the page. **Uninstall** removes the sorter from every folder, the browser helpers and the `dl` command, then moves Rays to the Trash. **Uninstall and delete data** also removes history and settings. Only available when Rays is in Applications.

## AI

Shows whether Apple Intelligence is ready on this Mac. The [sorter](/docs/app/sorter/) uses it to sort and rename files. If it is off, **Open System Settings** takes you to where you turn it on.

## Browsers

Lists every browser on your Mac. The page card has **Install all helpers** and **Check again**. Install or remove the helper each browser needs for the [extension](/docs/app/browser/), with a status line per browser. Browsers built on Chromium or Firefox that Rays doesn't know by name are set up the same way. Other browsers show why they aren't supported. **How the helper works** explains what the helper does and how to remove it. **Remove all helpers…** is red text at the bottom of the page.
