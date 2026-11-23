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
| `add_downloads` | `urls`: list of http, https or `s3://bucket/key` links | Adds them to Rays; returns ids and any rejected links. |
| `list_downloads` | none | Downloads with id, state, bytes done and total, and file name. |
| `list_buckets` | none | The [S3 buckets](/docs/s3/) added to Rays, with provider and endpoint. |
| `browse_bucket` | `bucket`, `prefix`, `next_token` | One level of a bucket: folders, and objects with size and modified time. |
| `sorter_status` | none | Watched folders, categories, settings and recent moves, as JSON. |
| `sort_folder` | `folder`, `dry_run` (default true), `all` | Sorts a folder into category folders. |

`sort_folder` only reports what it would move unless the assistant sets `dry_run` to `false`, so an assistant cannot move your files by accident. Clients that support tool hints also see it marked as destructive.

No tool adds a bucket: you add buckets in Rays or with `dl bucket add`, so your keys never pass through an assistant.

## Try it

Ask your assistant:

- "Download https://github.com/a6n-ai/rays/releases/latest/download/Rays.dmg with Rays."
- "What is downloading right now?"
- "List the videos in my media bucket and download the newest one."
- "Show me how Rays would sort my Desktop." (a dry run)
