---
title: "Install Rays on Mac"
description: "Install Rays on macOS 26 with the DMG or Homebrew, add the dl command to Terminal, get automatic updates, and uninstall Rays cleanly."
---

Rays needs **macOS 26 or later**. It is free and open source under the AGPL-3.0 licence.

## DMG

1. [Download Rays.dmg](https://github.com/a6n-ai/rays/releases/latest/download/Rays.dmg). This link always points at the newest version.
2. Open the DMG and drag **Rays** to **Applications**.
3. Open Rays from Applications.

Rays is not notarized yet, so the first time you open it macOS may say it can't verify the app. Open **System Settings > Privacy & Security**, scroll down, and choose **Open Anyway**. You only do this once.

The optional `dl` command, for Terminal and AI agents, comes inside the app. To use it, open **Settings > General** and click **Install** next to **Command line tool**. macOS may ask for your password once, to add it to `/usr/local/bin`.

## Homebrew

```sh
brew install --cask a6n-ai/tap/rays
```

Homebrew clears the download quarantine, so there is no Gatekeeper step, and it puts `dl` on your PATH.

## Update

Rays checks for a new version each time it opens (at most once an hour) and every 6 hours while it is open. When one is out, a small green note appears at the top of the window; click **Download** to get it. You can also check by hand in **Settings > General > Check for Updates**.

With Homebrew:

```sh
brew upgrade --cask rays
```

## Uninstall

With Homebrew:

```sh
brew uninstall --cask rays          # removes the app and stops Rays' sorter helpers
brew uninstall --zap --cask rays    # also deletes settings, history and browser helpers
```

For a DMG install, open **Settings > General** and click **Uninstall Rays…**:

- **Uninstall** stops sorting your folders, removes the browser helpers and the `dl` command, and moves Rays to the Trash.
- **Uninstall and Delete Data** also removes your download history and settings (`~/Library/Application Support/Rays`).

Your downloads and sorted files stay where they are either way.
