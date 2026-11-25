---
title: "dl: command-line download manager for Mac"
description: "Download files and sort folders from Terminal with dl, the command that ships with Rays: every command, its output, exit codes, environment and scripts."
---

`dl` is optional: Rays downloads and sorts without it. Install it when you want to use Rays from Terminal, scripts or AI agents over [MCP](/docs/mcp/). It comes inside Rays.app, talks to the running app, and runs the sorter that ships with it.

## Install

Homebrew puts `dl` on your PATH:

```sh
brew trust a6n-ai/tap
brew install --cask a6n-ai/tap/rays
```

With a DMG install, open **Settings > General** and click **Install** next to **Command line tool**.

## Commands

```text
dl URL...                     download links with Rays
dl s3://BUCKET/KEY            download an object from a bucket added to Rays
dl list                       list downloads (also: dl --list)
dl add [--queue NAME|ID] URL...   download links into a queue
dl queues [--json]            list queues
dl queue start|stop|run NAME|ID
dl verify FOLDER              check a downloaded model folder
dl bucket providers|list|add|remove
dl ls s3://BUCKET/[PREFIX/]   list one level of a bucket
dl sort [FOLDER] [--all] [--dry-run] [--projects]
dl watch FOLDER | dl unwatch FOLDER
dl status [--json]            sorter settings, watched folders, recent moves
dl config ...                 change sorter settings
dl mcp                        MCP server on stdio
dl --help
```

## Download files

```sh
dl https://github.com/a6n-ai/rays/releases/latest/download/Rays.dmg https://github.com/a6n-ai/rays/archive/refs/heads/main.zip
```

Each link is added to Rays and starts when a slot is free. One line per link:

```text
added 12 https://github.com/a6n-ai/rays/releases/latest/download/Rays.dmg
added 13 https://github.com/a6n-ai/rays/archive/refs/heads/main.zip
rejected file:///etc/hosts: only http, https and s3 links
```

## List downloads

```sh
dl list
```

One line per download: id, state, bytes done / total, file name, separated by tabs (shown as spaces here):

```text
12  running  6291456/12582912  Rays.dmg
11  done     7340032/7340032     report.pdf
```

The state is one of `queued`, `running`, `paused`, `retrying`, `done` or `failed`. The total is `?` when the server does not say how big the file is.

## Queues

```sh
dl add --queue Night https://example.com/a.zip https://example.com/b.zip
dl queues
dl queue stop Night
dl queue start Night
dl queue run Night
```

`dl add` without `--queue` uses the Main queue. A queue is a name, in any case, or an id. `dl queues` prints one line per queue: id, name, state, counts of queued and running downloads, and the next start in unix seconds for a scheduled queue. `--json` prints the same as JSON.

The state is `open`, `waiting for time`, `waiting for condition`, `stopped` or `off`. `dl queue start` lifts a stop; on a scheduled queue it is the same as `dl queue run`, which opens the queue until its run finishes, whatever its schedule says.

`dl` does not edit or delete queues: set schedules, finish actions and the Run command in the app. A Run command executes shell commands, so no client of the socket can set one.

## Verify a model

```sh
dl verify ~/Models/some-model
```

Checks a folder that Rays downloaded from Hugging Face against the `.rays-model.json` it saved there. One line per file with its status, then a summary:

```text
ok            model-00001-of-00002.safetensors
size-checked  config.json
missing       tokenizer.json
3 files, 2 ok, 1 with problems (1 missing), 1 checked by size only
```

The status is `ok`, `size-checked` (no checksum was recorded, so only the size was compared), `missing`, `wrong-size` or `wrong-checksum`. The command exits with `1` if any file has a problem, and with an error if the folder has no record. Hashing large files can take a while.

## S3 buckets

```sh
dl bucket providers
dl bucket add NAME --provider ID --key-id KEY [--region R] [--account-id A | --namespace N |
              --project-ref P] [--endpoint URL] [--path-style | --virtual-host]
dl bucket list
dl bucket remove NAME
dl ls s3://BUCKET/[PREFIX/]
```

`dl bucket add` reads the secret key from standard input: typed with echo off in a terminal, or piped in a script. Rays lists the bucket once to check the keys, then saves the secret to your Keychain. `--provider` takes an id from `dl bucket providers`; with `--endpoint` and no provider it uses Generic S3.

`dl bucket providers` prints each id, its name, and the endpoint it fills in. `dl ls` prints one line per folder (`DIR`) and per object (size in bytes, modified time, link), and pages through large folders. Download an object with `dl s3://BUCKET/KEY`. More in [S3 buckets](/docs/s3/).

## Sort a folder

```sh
dl sort [FOLDER] [--all] [--dry-run] [--projects]
```

Moves files into category folders such as Work, Images, Installers and Archives, inside FOLDER. Without a folder it sorts `~/Downloads`; `.` is the current folder.

| Option | Effect |
|---|---|
| `--dry-run` | Print what would move and change nothing. |
| `--all` | Also sort files that were there before the first run. |
| `--projects` | Move code-project folders whole into Code/Projects. |

Files changed in the last 10 seconds are skipped, so nothing moves while it is still being written.

```text
$ dl sort ~/Desktop --dry-run
[dry] setup.dmg -> ~/Desktop/Installers/Apps/Setup.dmg (Installers/Apps rule)
```

## Watch a folder

```sh
dl watch ~/Downloads
dl unwatch ~/Downloads
```

Rays sorts the folder by itself whenever a new file lands in it, even when the app is closed.

## Status and settings

```sh
dl status
dl status --json
```

```sh
dl config set-wait 30
dl config set-rename off
dl config set-dest ~/Downloads Work ~/Documents/Work
dl config clear-dest ~/Downloads Work
dl config add ~/Desktop
dl config remove ~/Desktop
```

`set-wait` is in seconds. `set-dest` sends one category somewhere else instead of a folder inside the sorted folder.

## When Rays is not open

`dl` opens Rays for you and waits up to 5 seconds for it to start. Set `DL_NO_LAUNCH=1` to stop it opening the app.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | The command worked. |
| `1` | At least one link was rejected, or Rays returned an error. |
| `2` | Wrong usage, or Rays or the sorter could not be reached. |

## Environment

| Variable | Effect |
|---|---|
| `DL_NO_LAUNCH` | Do not open Rays when it is not running. |
| `DL_SORTER` | Path of the sorter to run, instead of the one inside Rays.app. |
| `DL_SOCKET` | Socket to talk to, instead of `~/Library/Application Support/Rays/dl.sock`. Never opens the app. |

## Scripts

```sh
xargs dl < links.txt                         # download every link in a file
dl "$URL" || echo "Rays did not take $URL"   # react to a rejected link
```
