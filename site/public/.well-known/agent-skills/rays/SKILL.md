---
name: rays
description: Download files and sort folders on macOS with Rays, through its dl command or MCP server. Use when the user wants to download links, check download progress, or tidy a folder like Downloads into category folders on a Mac.
---

# Rays

Rays is a download manager for macOS 26 with an on-device AI sorter. Everything goes through one command, `dl`.

## Install

- `brew install --cask a6n-ai/tap/rays` puts `dl` on PATH.
- Or download https://github.com/a6n-ai/rays/releases/latest/download/Rays.dmg, drag Rays to Applications, then in Rays open Settings > General > Command line tool > Install.

## Commands

- `dl URL...` adds http/https links to Rays (opens the app if needed). Prints `added ID URL` or `rejected URL: reason`.
- `dl list` prints `id<TAB>state<TAB>done/total<TAB>name`. States: queued, running, paused, retrying, done, failed.
- `dl sort [FOLDER] [--all] [--dry-run] [--projects]` moves files into Work, Personal, Images, Installers, Archives, Media, Code, Other. Default folder ~/Downloads. Run with `--dry-run` first and show the user the plan before moving anything.
- `dl watch FOLDER` / `dl unwatch FOLDER` sort a folder automatically when files land in it.
- `dl status [--json]` shows wait time, renaming, watched folders and recent moves.
- `dl config set-wait SECONDS | set-rename on|off | set-dest FOLDER CATEGORY PATH | clear-dest FOLDER CATEGORY | add|remove FOLDER`.

Exit codes: 0 success, 1 a link was rejected or Rays returned an error, 2 wrong usage or Rays/the sorter not reachable.

## MCP

`dl mcp` serves MCP over stdio. Tools: add_downloads, list_downloads, sorter_status, sort_folder (dry run unless dry_run is false).

Docs: https://rays.a6n.ai/docs/dl/
