# Benchmarks

Rays against aria2 and curl on the same downloads, on a local test server that injects one fault at a time, plus a TLS comparison and a run on a real line. Every finished file is checked against the server's SHA-256 after the clock stops; a wrong byte counts as a failed run.

**Machine:** Mac with Apple M3 Pro (11 cores), macOS 27.2.1. **Tools:** Rays engine at `e04c0f4`, aria2 1.37.0, curl 8.7.1. **Date:** 23 Nov 2026.

## Rerun them

```sh
scripts/bench-lab.sh 3 256                 # every scenario, 3 runs, 256 MiB file
scripts/bench-lab.sh 3 2048 unthrottled    # one scenario, 2 GiB file
scripts/bench-vs.sh <https-url> 5          # a real server over your own line
```

`bench-lab.sh` starts `engine/examples/lab.rs` once per scenario. Each run downloads the file once with every tool, the order rotates every run, and one warm-up run is not counted. Tables show the median of 3 runs.

- **Rays** is the engine's `bench` example, adaptive, up to 16 connections.
- **aria2 -x16** is `aria2c -x16 -s16 -k1M`, 16 connections from the start.
- **aria2** is `aria2c` with its default settings.
- **curl** resumes with `-C -` after each drop.

## On a test server with known faults

All scenarios except `unthrottled` cap the whole link at 50 MB/s.

| Scenario, 256 MiB file | Rays | aria2 -x16 | aria2 | curl |
|---|---|---|---|---|
| Clean link | 49.7 MB/s | 50.4 MB/s | 50.5 MB/s | 50.6 MB/s |
| Each connection capped at 2 MB/s | 21.6 MB/s | 31.7 MB/s | 2.0 MB/s | 2.0 MB/s |
| One connection in three slow (256 KB/s), others 4 MB/s | 18.2 MB/s | 23.4 MB/s | 4.0 MB/s | 4.0 MB/s |
| 150 ms before each response, 4 MB/s per connection | 30.4 MB/s | 47.5 MB/s | 4.0 MB/s | 4.0 MB/s |
| Server allows 2 connections (503 above), 4 MB/s each | 7.6 MB/s | 8.0 MB/s | 4.0 MB/s | 4.0 MB/s |
| Every connection dropped after 8 MB, 8 MB/s each | 41.5 MB/s | 50.2 MB/s | failed | 4.1 MB/s |
| 2% of 64 KB chunks drop the connection, 8 MB/s each | 41.1 MB/s | 48.7 MB/s | failed | 2.5 MB/s |
| Unthrottled localhost | 1074 MB/s | 261 MB/s | 706 MB/s | 1220 MB/s |

| Scenario, 2 GiB file | Rays | aria2 -x16 | aria2 | curl |
|---|---|---|---|---|
| Unthrottled localhost | **1805 MB/s** | 374 MB/s | 598 MB/s | 1471 MB/s |

The random-drop row is from 2 runs.

## Reading the numbers

- **On a clean link, every tool runs at line speed.** Extra connections cannot beat the line itself.
- **When a server throttles each connection, splitting matters most.** Rays is 2 to 11 times faster than aria2's default settings and curl.
- **aria2 with `-x16` is faster on these files** because it opens 16 connections at once. Rays starts files of 32 MB or more on 4 connections and doubles only while each step makes the file faster, so it takes a few seconds to reach full speed, and it never opens connections that do not help. On a 256 MiB file those seconds show. The same rule keeps Rays from slowing down a line one connection already fills, and from getting blocked by servers that limit connections.
- **Dropped connections.** aria2's default settings gave up in both drop scenarios. Rays reconnects at once and keeps every byte it received, re-downloading 0.3 MB of 256 MiB.
- **Unthrottled.** With a 2 GiB file, Rays writes 1.8 GB/s, faster than curl on one stream and almost 5 times aria2 -x16.

## TLS: rustls against the macOS system TLS

The same 2 GiB file over HTTPS from a local server, with the engine's two TLS backends:

| Connections | macOS system TLS (native-tls) | rustls |
|---|---|---|
| 1 | 477 MB/s | **1741 MB/s** |
| 8 | 523 MB/s | **1504 MB/s** |
| 16 | 651 MB/s | **1737 MB/s** |

The macOS system TLS (Secure Transport) has no TLS 1.3, and decrypting limited each connection. Rays now uses rustls, which still checks certificates against the macOS Keychain.

## On a real line

A 2 GiB file over HTTPS from Cloudflare R2 (Asia-Pacific), on a line of about 250 Mbit/s (31 MB/s), 16 connections at most:

Six runs, alternating the two TLS backends, ran at 21.2 to 36.2 MB/s, with no difference between the backends: Rays fills the line. The line's own speed changed from run to run.
