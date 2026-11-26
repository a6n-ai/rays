---
title: "MCP server for downloads and file sorting"
description: "Connect Claude and other MCP clients to Rays to download files and organize folders on your Mac: setup, the tools, S3 buckets and safe dry-run sorting."
---

`dl mcp` runs a [Model Context Protocol](https://modelcontextprotocol.io) server on stdin and stdout. It runs on your Mac and talks to the Rays app; nothing goes through a server.

## Connect it

Claude Code:

```sh
claude mcp add rays -- dl mcp
```

Any MCP client:

```json
{ "mcpServers": { "rays": { "command": "dl", "args": ["mcp"] } } }
```

`dl` must be on the PATH the client uses: in Rays, open **Settings > General** and click **Install** next to **Command line tool** (Homebrew installs have it already).

## Tools

| Tool | Input | What it does |
|---|---|---|
| `add_downloads` | `urls`: list of http, https or `s3://bucket/key` links; `queue` (optional name or id); `best_time` (boolean); `sha256` (optional list, one expected SHA-256 per URL, `null` to skip one) | Adds them to Rays. They start now, in no queue, unless `queue` is set. With `best_time` they go to the Best time queue instead, and `queue` is ignored. Returns ids and any rejected links. A download whose file does not match its `sha256` fails. |
| `list_downloads` | none | Downloads with id, state, bytes done and total, and file name. |
| `list_queues` | none | Queues with id, name, state (open, waiting for time, waiting for condition, stopped or off), next start and counts of queued and running downloads. |
| `start_queue` | `queue`: name or id | Starts a queue. On a scheduled queue this is the same as `run_queue_now`. |
| `stop_queue` | `queue`: name or id | Stops a queue: its queued downloads wait and its running ones pause. |
| `run_queue_now` | `queue`: name or id | Runs a queue now, whatever its schedule and conditions say. |
| `speed_test` | `force` (optional boolean) | Measures download speed now and saves the result. Refused on a metered link, or on a network Rays has not identified (for example while the app is closed), unless `force` is true. A forced test on those is not saved. |
| `best_time` | none | The last speed test and the fastest four hours of the day to download, with typical speed, or how many days of data are still needed. |
| `verify_model` | `dir`: absolute path of a model folder | Checks a model that Rays downloaded from Hugging Face against its record: one line per file and a summary. |
| `list_buckets` | none | The [S3 buckets](/docs/s3/) added to Rays, with provider and endpoint. |
| `browse_bucket` | `bucket`, `prefix`, `next_token` | One level of a bucket: folders, and objects with size and modified time. |
| `sorter_status` | none | Watched folders, categories, settings and recent moves, as JSON. |
| `sort_folder` | `folder`, `dry_run` (default true), `all` | Sorts a folder into category folders. |

`sort_folder` only reports what it would move unless the assistant sets `dry_run` to `false`, so an assistant cannot move your files by accident. Clients that support tool hints also see it marked as destructive.

Queue names match in any case. No tool edits a queue's schedule, settings or Run command, or deletes a queue: a Run command executes shell commands, so it can only be set in the app. Clearing speed history and changing speed test settings are app-only too.

`verify_model` reads the folder's `.rays-model.json` and returns an error if there is none. It checks sizes and, where Rays recorded one, checksums.

No tool adds a bucket: you add buckets in Rays or with `dl bucket add`, so your keys never pass through an assistant.

## Try it

Ask your assistant:

- "Download https://github.com/a6n-ai/rays/releases/latest/download/Rays.dmg with Rays."
- "What is downloading right now?"
- "List the videos in my media bucket and download the newest one."
- "Show me how Rays would sort my Desktop." (a dry run)
