---
title: "How the Rays download engine works"
description: "Inside the Rays download engine: connections that double while they make the file faster, slow connections replaced, crash-safe resume, and the benchmarks behind each choice."
---

Rays downloads with its own engine, written in Rust. It has one goal: finish each file as fast as your line allows, without wasting requests or leaving a broken file behind. The same engine runs the Mac app, the [`dl` command](/docs/dl/) and the [MCP server](/docs/mcp/).

## What Rays does differently

Most download managers split every file into a fixed number of connections that you set once, often 8 to 16. [aria2](https://aria2.github.io/manual/en/html/aria2c.html), for example, uses `--split` (5 by default) and `--max-connection-per-server`. A fixed count is a guess: too few wastes a fast server, too many slows a line that one connection already fills, and some servers block you for it.

| | Typical download manager | Rays |
|---|---|---|
| Connections per file | Fixed number you set | Measured live: doubles while each step makes the file 25% faster, keeps a step only if it is 10% faster |
| Too many connections | Keeps them | Steps back down while speed stays within 2% |
| One slow connection | Waits for it | Reconnects a connection running below a quarter of its fair share |
| First request | Used to read the size, then closed | Keeps downloading on it |
| A server that pushes back | Retries with the same count | Remembers that server's limit for 7 days |
| Speed limit set | Still splits | One connection, since more add requests, not bandwidth |
| Crash mid-download | Depends on the app | Plan saved before the file is reserved; only written bytes count |
| Speed claims | Rarely published | [Benchmarks](#benchmarks) below, with the command to rerun them |

The setting you choose is a ceiling, not a target: Rays never uses more connections than **parts per file** allows, and often uses fewer.

## The first request keeps downloading

Every download starts with a single request. That request tells Rays the file's size, its name and whether the server can send parts (HTTP `Range`). Rays keeps that same connection open and downloads the file on it, so no request is wasted.

## More connections only when they pay

Splitting a file over several connections helps when a server limits each connection's speed. It hurts on a line that one connection already fills: the connections compete, and the file arrives slower.

So Rays measures instead of guessing. Every second it checks the speed:

1. **Start.** Files of 32 MB or more start on 4 connections (or fewer, if your **parts per file** setting is lower); smaller files start on one.
2. **Double while it pays.** Rays doubles the count (4, 8, 16) while each step makes the file at least **25% faster**, judging each step after a second. It keeps a step only if it is at least **10% faster**.
3. **Trim and step down.** When doubling stops, Rays removes connections one at a time while speed stays within **2%**. That is the `speed / 1.02ⁿ` score from download-tuning research (Falcon, FastBioDL): each connection must earn its cost. On a line one connection fills, it settles on one.
4. **Hold and re-check.** Rays then holds the count. It probes one more every 15 seconds, and steps down if the speed drops by a quarter.

When a part finishes early, its connection takes half of the largest part that is left, so no connection sits idle at the end. A connection that runs below a quarter of its fair share for 2 seconds (one bad route, or a slow server behind a load balancer) is reconnected, continuing from its last written byte. Files under 4 MB, and servers that cannot send parts, always use one connection. The **parts per file** setting (1 to 16) is the most Rays will ever use.

## Servers that push back

- A `429` or `503` answer stops Rays adding connections for that download. It keeps as many as the server accepted, splits the rest of the file only within that count, and tries one more after 3 quiet seconds. It remembers the count for that server for 7 days.
- Connections that fail close together on different parts look like a server that blocks extra connections. Rays drops to one connection for that server.
- A part that gets a whole-file answer instead of a part makes Rays fall back to a single stream.
- Under a speed limit, Rays never splits, because more connections add requests, not bandwidth.

## Crash-safe resume

- Rays saves the plan of parts before it reserves the file on disk. A part's progress counts only bytes already written, so a resumed download never trusts bytes it did not save.
- Pausing, quitting or a crash keeps every written byte. Resuming asks the server only for what is missing, and checks the file has not changed (`If-Range` with its `ETag` or date).
- A download with no data for 30 seconds is retried. Up to 5 retries wait 2, 5, 15, 30 and 60 seconds.
- The file is named `<name>.<id>.part` until it is complete, then renamed.

## Benchmarks

We test every engine change with the same A/B benchmark, which ships in the repository:

```sh
cargo run --release -p dl-engine --example bench -- https://sin-speed.hetzner.com/100MB.bin 1,4,8 7
```

It downloads a 100 MB file from a Hetzner speed-test server with a cap of 1, 4 and 8 connections, interleaving the caps in each round and reporting the median of 7 rounds. Internet speed changes from minute to minute, so the table compares each cap with the single connection **in the same run**.

| Engine version | 4 connections | 8 connections |
|---|---|---|
| Before tuning: start on 2 to 4 parts, only probe up | 73% | 61% |
| Step down when more connections don't help | 88% | 85% |
| Start on one connection, add only when it pays | 111% | 148% |

*100% = the speed of one connection on the same run. One wired line in Asia to Hetzner Singapore. The last run was on a congested line, where extra connections helped; on a line one connection fills, Rays now stays near one connection instead of slowing down.*

### On a test server with known faults

A real line changes from minute to minute, and on a line one connection fills, every engine looks the same. So we also test on a local server that injects one fault at a time (`engine/examples/lab.rs`), with the script that runs it:

```sh
scripts/bench-lab.sh 5 64
```

| Scenario, 64 MB file | Before | Now |
|---|---|---|
| Clean 50 MB/s link | 1.40 s | 1.41 s |
| Each connection capped at 2 MB/s | 12.9 s | 5.8 s |
| One connection in three slow (256 KB/s) | 15.7 s | 6.5 s |
| 150 ms before each response, 4 MB/s per connection | 9.2 s | 4.1 s |
| Server allows 2 connections (503 above) | 12.0 s | 10.4 s |
| Connection dropped every 8 MB | 9.8 s | 3.7 s |

*Median of 5 runs after a warm-up, order rotated each run, on 23 Nov 2026. "Before" is the engine that added one connection at a time and never reconnected a slow one.*

What we measured and kept:

- **Batched disk writes.** Each connection gathers 256 KB before writing, instead of writing and flushing every 16 KB chunk, and the app is woken once per update instead of once per chunk. On a local 1 GB test server both versions run at about 3.4 GB/s, far above any home line, and the batched one uses about 20% less CPU (0.35 against 0.44 CPU seconds per GB).

What we measured and dropped:

- **Starting big files on 4 connections, re-probing sooner after a failed probe, and letting a removed connection finish its piece (as aria2 does).** None was faster in A/B tests on a real line, so Rays keeps the simpler engine.
- **A faster build (`opt-level = 3`) and more engine threads (4 instead of 2).** No change in speed or CPU on the local test server, so Rays keeps the smaller app.
- **HTTP/3 (QUIC).** On one connection, HTTP/3 averaged 8.5 MB/s against 8.9 MB/s over TCP. Rays ships with HTTP/3 off. It can be built in with the `http3` feature to test.

Your results depend on your line and the server. Run the benchmark against a server near you to see your own numbers.
