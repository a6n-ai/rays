# Rays

A free download manager for Mac that sorts your downloads into folders with on-device AI.
Website and docs: [rays.a6n.ai](https://rays.a6n.ai).

## Download

**[Download Rays.dmg](https://github.com/a6n-ai/rays/releases/latest/download/Rays.dmg)**: open it and drag Rays to Applications.
Requires macOS 26. Rays isn't notarized yet: if macOS blocks it on first launch, open
System Settings > Privacy & Security and choose **Open Anyway**.

Rays updates itself: it shows a note when a new version is out. To uninstall, open
Settings > General > Uninstall Rays.

## Use

Paste links into the bar at the bottom (⌘L), or drop links, text containing links, or `.webloc`
files on the window. To sort, open **Sorter** and add your Downloads folder. That's all most people
need; the command line tool below is optional.

In the app, drag a finished download out of the window to copy it elsewhere. The toolbar's
Speed Limit menu sets bandwidth, and the [Settings](#settings) section below covers the rest.
View > Appearance chooses System, Light or Dark.

## Command line and AI agents (optional)

Rays works without it. `dl` ships inside Rays.app for people who want Terminal, scripts or AI agents:
install it from **Settings > General > Command line tool**.

```sh
dl https://github.com/a6n-ai/rays/releases/latest/download/Rays.dmg   # add to the running app (opens it if needed)
dl list                               # id, state, done/total, name (also: dl --list)
dl sort ~/Desktop --dry-run           # sort a folder into category folders; --all, --projects
dl watch ~/Downloads                  # sort automatically whenever a file lands (dl unwatch to stop)
dl status                             # wait time, renaming, watched folders, recent moves (--json)
dl config set-wait 30                 # also set-rename on|off, set-dest, clear-dest, add|remove
dl mcp                                # MCP server on stdio for AI assistants
```

The sorter commands run the `sorter` bundled next to `dl` in Rays.app (`DL_SORTER` overrides).
Full reference: [rays.a6n.ai/docs/dl](https://rays.a6n.ai/docs/dl/).

### MCP

`dl mcp` speaks the Model Context Protocol on stdio. Add it to Claude Code with
`claude mcp add rays -- dl mcp`, or to any client as `{"command": "dl", "args": ["mcp"]}`. Tools:
`add_downloads`, `list_downloads`, `sorter_status`, and `sort_folder` (a dry run unless `dry_run` is false).

Exit codes: `0` success, `1` a URL was rejected or Rays returned an error, `2` wrong usage or Rays/the sorter not reachable.

## Build from source

Only needed to work on Rays itself. Needs Xcode 26 command line tools and `rustup` (the script adds
the `aarch64`/`x86_64` Apple targets).

```sh
scripts/bundle-app.sh     # builds engine (universal), Swift bindings, bin/Rays.app, bin/dl
open bin/Rays.app
```

`scripts/make-dmg.sh` packs `bin/Rays.app` into a drag-to-install DMG. Pushing a `v*` tag runs
`.github/workflows/release.yml`, which builds, publishes the zip and DMG.
The code: a Rust engine (`engine/`) behind a SwiftUI app (`macos/`), the `dl` command (`cli/`), the
sorter (`sorter/`, `extract/`) and the website (`site/`). Design: [docs/designs/rays.md](docs/designs/rays.md).

## Browser extension

`extension/` is a Manifest V3 extension for Chrome, Brave, Edge, Firefox and Zen. It sends links to Rays
through native messaging, with the bundled `dl` as the host.

1. In Rays, open **Settings > Browsers** and click **Install All Helpers**.
2. Install the extension: [Chrome Web Store](https://chromewebstore.google.com/detail/mgepiogdappnhmohefhalmeppkfciail) for Chrome, Brave and Edge, or
   [Firefox Add-ons](https://addons.mozilla.org/firefox/addon/rays@a6n.ai/) for Firefox and Zen.

Developers can load `extension/` unpacked in any Chrome-family browser; the pinned store key gives it the
store's ID. `scripts/package-extension.sh` builds both store zips, and `.github/workflows/extension.yml`
submits every change to `extension/` on main to both stores.

Right-click a link and choose **Download with Rays**. The toolbar badge shows `+N` on success and `!`
on error. The extension's options page has **Send all browser downloads to Rays**; the browser's copy is
cancelled only after Rays accepts it. Developers can also register the host with
`scripts/install-browser-host.sh`.

## Settings

Settings (⌘,) saves every change as you make it:

- **General**: appearance, the download folder, the optional command line tool, updates, and Uninstall Rays.
- **Downloads**: downloads at once (1 to 10), parts per file (1 to 16), and the speed limit.
- **Sorting**: on-device AI status, how long to wait before sorting, renaming from content, and watched folders.
- **Browsers**: install or remove the helper each browser's extension needs.

## Files

| What | Where |
|---|---|
| Downloads | `~/Downloads/<name>` |
| In progress | `~/Downloads/<name>.<id>.part` (renamed only when complete) |
| Queue and history | `~/Library/Application Support/Rays/queue.db` |
| CLI socket | `~/Library/Application Support/Rays/dl.sock` (mode 0600) |

`sorter watch ~/Downloads` skips `.part` files, so it only ever files finished downloads.

## Permissions

The app is unsandboxed and ad-hoc signed, with no entitlements. The only prompt macOS may show is
access to the Downloads folder.

## Test

```sh
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
```

## License

AGPL-3.0. See [LICENSE](LICENSE).
