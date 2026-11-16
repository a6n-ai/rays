# Rays

Small macOS download manager: a Rust engine (`engine/`) behind a SwiftUI app (`macos/`), plus a
terminal client (`cli/`). Design: [docs/designs/rays.md](docs/designs/rays.md).

## Install

**[Download Rays.dmg](https://github.com/a6n-ai/rays/releases/latest/download/Rays.dmg)**: open it and drag Rays to Applications.

Or with Homebrew (also puts `dl` on your PATH):

```sh
brew install --cask a6n-ai/tap/rays      # install
brew upgrade --cask rays                 # update
brew uninstall --cask rays               # uninstall (stops Rays' sorter helpers)
brew uninstall --zap --cask rays         # uninstall and delete settings, history and browser helpers
```

Requires macOS 26. Rays isn't notarized yet: if macOS says it can't verify Rays on first launch,
right-click Rays in Applications and choose **Open** (Homebrew installs skip this).

## Build

```sh
scripts/bundle-app.sh     # builds engine (universal), Swift bindings, bin/Rays.app, bin/dl
```

`scripts/make-dmg.sh` packs `bin/Rays.app` into a drag-to-install DMG. Pushing a `v*` tag runs
`.github/workflows/release.yml`, which builds, publishes the zip and DMG, and bumps the Homebrew cask.

Needs Xcode 26 command line tools and `rustup` (the script adds the `aarch64`/`x86_64` Apple targets).
The app requires macOS 26.

## Use

```sh
open bin/Rays.app
bin/dl https://example.com/file.zip ...   # adds to the running app (starts it if needed)
bin/dl --list
```

In the app, paste links into the bottom bar (⌘L), or drop links, text containing links, or `.webloc`
files on the window. Drag a finished download out of the window to copy it elsewhere. The toolbar's
Speed Limit menu sets bandwidth, and the [Settings](#settings) section below covers the rest.
View > Appearance chooses System, Light or Dark.

Exit codes: `0` all added, `1` a URL was rejected, `2` app not reachable.

## Browser extension

`extension/` is a Manifest V3 extension for Chrome, Brave, Edge and Firefox. It sends links to Rays
through native messaging, with `bin/dl` as the host (`dl` runs in host mode when a browser launches it).

1. Build with `scripts/bundle-app.sh`, which refreshes `bin/dl`.
2. Register the host: `scripts/install-browser-host.sh`. It writes `ai.a6n.rays.json` into each
   installed browser's NativeMessagingHosts folder. Chrome-family browsers need the extension ID, which
   is stable because `extension/manifest.json` pins a key. The private key is `build/rays-extension-key.pem`
   (gitignored); keep it out of the repo.
3. Chrome: open `chrome://extensions`, turn on Developer mode, choose **Load unpacked**, and pick
   `extension/`. The ID should be `ibcagaikmkbigbllllcihhafjkbobhci`. If it differs, run
   `scripts/install-browser-host.sh <id>`.
4. Firefox: open `about:debugging#/runtime/this-firefox`, choose **Load Temporary Add-on**, and pick
   `extension/manifest.json`. Run step 2 first, since the Firefox host manifest is always written.

Right-click a link and choose **Download with Rays**. The toolbar badge shows `+N` on success and `!`
on error. The extension's options page has **Send all browser downloads to Rays**. When it is on, each
browser download is sent to Rays, and the browser's copy is cancelled only after Rays accepts it.

## Settings

Settings (⌘,) saves every change as you make it. It has three tabs:

- **General**: appearance and the download folder. Downloads in progress finish where they started.
- **Downloads**: simultaneous downloads (1 to 10), connections per download (1 to 16), and the speed limit.
- **Sorting**: runs `sorter` on each finished download. Turning it on adds a launchd agent for the download folder, so it can be turned off from here or with `sorter unwatch`. The tab looks for `sorter` at `~/local-scripts/sorter/bin/sorter` unless you choose another path.

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
