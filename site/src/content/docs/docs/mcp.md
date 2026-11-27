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

`dl` must be on the PATH the client uses: in Rays, open **General** in the sidebar and click **Install** next to **Command line tool** (Homebrew installs have it already). Or open **AI** in the sidebar: **Connect an AI app** adds Rays to Claude, Cursor or VS Code in one click, and copies the Claude Code command or the JSON for other apps, with the full path to `dl`, so nothing needs installing. ChatGPT connects only to MCP servers on the internet, so it can't reach Rays on this Mac.

### Over HTTP

For apps that connect to an address, turn on **HTTP server** on the **AI** page, or run it in Terminal:

```sh
dl mcp --http             # http://127.0.0.1:7467/mcp; --port N for another port
dl mcp --token            # the bearer token
```

It uses MCP's Streamable HTTP transport: one JSON-RPC message per `POST`, answered as JSON, or as an event stream when the client accepts only `text/event-stream`. It listens on 127.0.0.1 only. Every request needs `Authorization: Bearer <token>`, a `localhost` or `127.0.0.1` Host and, if it sends one, a local Origin, so a web page you visit cannot use it. The token is stored in `~/Library/Application Support/Rays/mcp-token`, readable only by you.

Claude Code:

```sh
claude mcp add --transport http rays http://127.0.0.1:7467/mcp --header "Authorization: Bearer $(dl mcp --token)"
```

## Tools

| Tool | Input | What it does |
|---|---|---|
| `add_downloads` | `urls`: list of http, https or `s3://bucket/key` links; `queue` (optional name or id); `best_time` (boolean); `sha256` (optional list, one expected SHA-256 per URL, `null` to skip one); `mirrors` (optional list of link lists, one per URL, extra links for the same file); `headers` (optional object such as `{"Cookie": "session=abc123"}`, request headers for links that need a login, applied to every URL) | Adds them to Rays. They start now, in no queue, unless `queue` is set. With `best_time` they go to the Best time queue instead, and `queue` is ignored. Returns ids and any rejected links. A download whose file does not match its `sha256` fails. Header values are stored in the Rays database on this Mac and sent only to each link's own site, and deleted when the download finishes. |
| `pause_download` | `id` | Pauses a queued or running download. The partial file is kept. |
| `resume_download` | `id` | Queues a paused or failed download again. |
| `remove_download` | `id`; `delete_partial` (default false) | Takes a download off the list. A finished file stays; `delete_partial` also deletes an unfinished one. |
| `relink` | `id`: download id; `url`: the new link; `restart`: optional, default false | Gives a paused or failed download a new link and queues it. The partial file is kept when the new link reports the same size. A different file is refused with "The new link is a different file" unless `restart` is true, which deletes the partial file and starts over. A link to a web page is refused. |
| `grab_links` | `url`: a web page link | Lists the downloadable files linked from the page, each with url, name and kind (file extension). Fails if the link is itself a file. Download the ones you want with `add_downloads`. |
| `list_downloads` | none | Downloads with id, state, bytes done and total, and file name. |
| `list_queues` | none | Queues with id, name, state (open, waiting for time, waiting for condition, stopped or off), next start and counts of queued and running downloads. |
| `start_queue` | `queue`: name or id | Starts a queue. On a scheduled queue this is the same as `run_queue_now`. |
| `stop_queue` | `queue`: name or id | Stops a queue: its queued downloads wait and its running ones pause. |
| `run_queue_now` | `queue`: name or id | Runs a queue now, whatever its schedule and conditions say. |
| `speed_test` | `force` (optional boolean) | Measures download speed now and saves the result. Refused on a metered link, or on a network Rays has not identified (for example while the app is closed), unless `force` is true. A forced test on those is not saved. |
| `stats` | `days` (optional integer, default 30) | Totals for downloads finished in the last `days` days that are still in the Rays list: bytes and files overall and per local day, the top sites, and average and peak speed. |
| `best_time` | none | The last speed test and the fastest four hours of the day to download, with typical speed, or how many days of data are still needed. |
| `search_models` | `query` | Searches Hugging Face models: id, downloads, likes, gated, GGUF and task. |
| `model_files` | `repo`: owner/name | A model's files with sizes, and the ones Rays recommends. |
| `download_model` | `repo`; `files` (default: recommended); `dir` (absolute, default AI Models/owner/name in the download folder); `queue` | Downloads a model with checksums and the record `verify_model` reads. Files already there or queued are skipped. |
| `verify_model` | `dir`: absolute path of a model folder | Checks a model that Rays downloaded from Hugging Face against its record: one line per file and a summary. |
| `list_buckets` | none | The [S3 buckets](/docs/s3/) added to Rays, with provider and endpoint. |
| `browse_bucket` | `bucket`, `prefix`, `next_token` | One level of a bucket: folders, and objects with size and modified time. |
| `sorter_status` | none | Watched folders, categories, settings and recent moves, as JSON. |
| `sort_folder` | `folder`, `dry_run` (default true), `all` | Sorts a folder into category folders. |

`sort_folder` only reports what it would move unless the assistant sets `dry_run` to `false`, so an assistant cannot move your files by accident.

Every tool has a title and all four MCP hints: `readOnlyHint`, `destructiveHint`, `idempotentHint` and `openWorldHint`. `sort_folder`, `relink` and `remove_download` are marked destructive, so clients that support hints ask before running them.

Queue names match in any case. No tool edits a queue's schedule, settings or Run command, or deletes a queue: a Run command executes shell commands, so it can only be set in the app. Clearing speed history and changing speed test settings are app-only too.

`verify_model` reads the folder's `.rays-model.json` and returns an error if there is none. It checks sizes and, where Rays recorded one, checksums.

No tool adds a bucket: you add buckets in Rays or with `dl bucket add`, so your keys never pass through an assistant.

## Try it

Ask your assistant:

- "Download https://github.com/a6n-ai/rays/releases/latest/download/Rays.dmg with Rays."
- "What is downloading right now?"
- "List the videos in my media bucket and download the newest one."
- "Show me how Rays would sort my Desktop." (a dry run)
