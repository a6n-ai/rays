---
title: "How the Rays download engine works"
description: "Inside the Rays download engine: one connection first, more only when they make the file faster, crash-safe resume, and the benchmarks behind each choice."
---

Rays downloads with its own engine, written in Rust. It has one goal: finish each file as fast as your line allows, without wasting requests or leaving a broken file behind. The same engine runs the Mac app, the [`dl` command](/docs/dl/) and the [MCP server](/docs/mcp/).

## What Rays does differently

Most download managers split every file into a fixed number of connections that you set once, often 8 to 16. [aria2](https://aria2.github.io/manual/en/html/aria2c.html), for example, uses `--split` (5 by default) and `--max-connection-per-server`. A fixed count is a guess: too few wastes a fast server, too many slows a line that one connection already fills, and some servers block you for it.

| | Typical download manager | Rays |
|---|---|---|
| Connections per file | Fixed number you set | Measured live: starts at 1, adds one only if it makes the file 10% faster |
| Too many connections | Keeps them | Steps back down while speed stays within 2% |
| First request | Used to read the size, then closed | Keeps downloading on it |
| A server that pushes back | Retries with the same count | Remembers that server's limit for 7 days |
| Speed limit set | Still splits | One connection, since more add requests, not bandwidth |
| Crash mid-download | Depends on the app | Plan saved before the file is reserved; only written bytes count |
| Speed claims | Rarely published | [Benchmarks](#benchmarks) below, with the command to rerun them |

The setting you choose is a ceiling, not a target: Rays never uses more connections than **parts per file** allows, and often uses fewer.

## One connection first

Every download starts with a single request. That request tells Rays the file's size, its name and whether the server can send parts (HTTP `Range`). Rays keeps that same connection open and downloads the file on it, so no request is wasted.

## More connections only when they pay

Splitting a file over several connections helps when a server limits each connection's speed. It hurts on a line that one connection already fills: the connections compete, and the file arrives slower.

So Rays measures instead of guessing. Every second it checks the speed:

1. **Probe up.** After a 1 second warm-up and a 2 second measurement, Rays adds one connection. It keeps it only if the next 2 seconds are at least **10% faster**.
2. **Step down.** If the extra connection did not pay, Rays removes it and tries one fewer. It keeps the lower count while speed stays within **2%**. That is the `speed / 1.02ⁿ` score from download-tuning research (Falcon, FastBioDL): each connection must earn its cost.
3. **Hold and re-check.** Rays then holds the count. It probes again every 15 seconds, and steps down if the speed drops by a quarter.

When a part finishes early, its connection takes half of the largest part that is left, so no connection sits idle at the end. Files under 4 MB, and servers that cannot send parts, always use one connection. The **parts per file** setting (1 to 16) is the most Rays will ever use.

## Servers that push back

- A `429` or `503` answer stops new connections for that download. Rays remembers the lower count for that server for 7 days.
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

### Rays against other tools

No download manager we looked at publishes how it measures its speed claims, so here is ours, with the script:

```sh
scripts/bench-vs.sh https://sin-speed.hetzner.com/100MB.bin 3
```

Each round downloads the same 100 MB file once with every tool, in the same order, after one warm-up round that isn't counted.

| Tool | Median | Slowest to fastest run |
|---|---|---|
| Rays (adaptive, up to 16 connections) | 8.7 MB/s | 4.5 to 9.1 MB/s |
| aria2 1.37, 16 connections (`-x16 -s16`) | 9.4 MB/s | 8.6 to 9.9 MB/s |
| aria2 1.37, default settings | 5.8 MB/s | 2.0 to 10.6 MB/s |
| curl 8.7 | 9.6 MB/s | 1.9 to 11.0 MB/s |
| wget 1.25 | 1.2 MB/s | 1.2 to 4.5 MB/s |

*3 rounds on 22 Nov 2026. Apple M3 Pro, one home line in Asia to Hetzner Singapore.*

What it shows, honestly:

- **This line tops out near 10 MB/s.** Rays, aria2 with 16 connections and curl all reached it. When one connection can fill a line, more connections can't make it faster. That's why Rays starts on one and adds more only when they pay.
- **The line itself swung a lot.** curl's runs ranged from 1.9 to 11 MB/s, and the medians sit inside each other's ranges. Three rounds can't separate the top three. Rays had one slow run (4.5 MB/s) and was otherwise within 10% of aria2's best.
- **aria2's defaults and wget fell behind.** aria2 uses one connection per server unless you raise `-x`, and wget always uses one.

Free Download Manager has no command line, so it isn't in the scripted test. Your line and server will give different numbers. Run the script to see yours.

What we measured and dropped:

- **Batched disk writes.** On a local 1 GB test server, writing each chunk as it arrives already sustains 1.2 to 1.5 GB/s, about 100 times faster than a fast home line. Batching writes into 1 MB blocks added CPU work and no speed, so Rays writes each chunk directly.
- **HTTP/3 (QUIC).** On one connection, HTTP/3 averaged 8.5 MB/s against 8.9 MB/s over TCP. Rays ships with HTTP/3 off. It can be built in with the `http3` feature to test.

Your results depend on your line and the server. Run the benchmark against a server near you to see your own numbers.
