---
title: "MCP server for downloads and file sorting"
description: "Connect Claude and other MCP clients to Rays to download files and organize folders on your Mac: setup, the four tools, and safe dry-run sorting."
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

`dl` must be on the PATH the client uses. See [Install](/docs/install/).

## Tools

| Tool | Input | What it does |
|---|---|---|
| `add_downloads` | `urls`: list of http/https links | Adds them to Rays; returns ids and any rejected links. |
| `list_downloads` | none | Downloads with id, state, bytes done and total, and file name. |
| `sorter_status` | none | Watched folders, categories, settings and recent moves, as JSON. |
| `sort_folder` | `folder`, `dry_run` (default true), `all` | Sorts a folder into category folders. |

`sort_folder` only reports what it would move unless the assistant sets `dry_run` to `false`, so an assistant cannot move your files by accident. Clients that support tool hints also see it marked as destructive.

## Try it

Ask your assistant:

- "Download https://example.com/file.zip with Rays."
- "What is downloading right now?"
- "Show me how Rays would sort my Desktop." (a dry run)
