---
title: "Get started with Rays"
description: "Install Rays, the free download manager for Mac, download your first file, and let it organize your Downloads folder automatically in a few minutes."
---

Rays is a download manager for macOS 26. It downloads each file in several parts at once, and its sorter moves new files into folders that fit them, using Apple's on-device model.

## 1. Install

The quickest way is the DMG:

1. [Download Rays.dmg](https://github.com/a6n-ai/rays/releases/latest/download/Rays.dmg).
2. Open it and drag **Rays** to **Applications**.
3. Open Rays. The first time, macOS may block it: go to **System Settings > Privacy & Security** and choose **Open Anyway**.

Or with Homebrew, which skips step 3:

```sh
brew install --cask a6n-ai/tap/rays
```

The `dl` command comes with the app. With a DMG install, turn it on in **Settings > General > Command line tool**. More options, updating and uninstalling: [Install](/docs/install/).

## 2. Download a file

1. Press **⌘L** to focus the bar at the bottom of the window.
2. Paste one or more links. Rays shows how many links it found, for example **✓ 3 links**.
3. Press **Return** or click the round download button.

You can also drop links, text that contains links, or `.webloc` files on the window. See [Downloads](/docs/app/downloads/).

## 3. Turn on sorting

1. Click **Sorter** in the sidebar.
2. Check that **On-device AI is ready**.
3. Under **Folders**, click **Add Folder…** and pick your Downloads folder (or click **Add Desktop**).

From now on, a few seconds after a file lands in that folder, Rays moves it into a folder like Installers, Archives, Images or Work. See [Sorter](/docs/app/sorter/).

## Next steps

- Send links from your browser: [Browser extension](/docs/app/browser/).
- Download and sort from Terminal: [The dl command](/docs/dl/).
- Let an AI assistant use Rays: [MCP](/docs/mcp/).
