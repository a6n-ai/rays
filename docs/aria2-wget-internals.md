# aria2 and wget internals vs the Rays engine

Date: 2026-11-22. Tags: [V] = verified by reading source (cloned, read locally), [U] = unverified / inference / model.
Sources read (shallow or full clones):
- aria2 `9e72735` (2026-06-25): https://github.com/aria2/aria2/tree/9e72735/src
- wget2 `43fecef` (2026-11-05): https://github.com/rockdaboot/wget2/tree/43fecef
- GNU wget `3e48e3c` (2026-11-05, 1.25 line): https://git.savannah.gnu.org/cgit/wget.git/tree/?id=3e48e3c
- Rays: `engine/src/download.rs`, `engine/src/scheduler.rs`, `engine/examples/bench.rs`, `scripts/bench-vs.sh`.
Not repeated here: tool default tables, H2 window theory, APFS prealloc (see `download-speed-research.md`, `perf-audit.md`).
Caveat: wget2 is not installed here, so wget2 runtime behaviour was not run [U where noted].

## 1. aria2 internals

Base URL for refs: `https://github.com/aria2/aria2/blob/9e72735/src/<file>#L<line>`.

### 1.1 How many connections, and when
- `-x` (max-connection-per-server) default 1, range 1-16; `-s` (split) default 5; `-k` (min-split-size) default 20M, range 1M-1G; `--piece-length` 1M. `OptionHandlerFactory.cc:439-441, 972, 502, 906` [V].
- The URI list is replicated `min(x, s)` times per URI: `download_helper.cc:394-399` [V]. With one URL and defaults, `min(1,5)` = 1 copy = ONE connection. So "aria2 defaults" in our bench is effectively a single connection (the manual's "-s 5" only matters with several URIs/mirrors). This matches its noisy 2.0-10.6 spread, same as curl.
- Start-up order [V]: `RequestGroup::createInitialCommand` starts one command; file size is unknown until its response header arrives. After the header (and file allocation), `StreamFileAllocationEntry.cc:96` calls `createNextCommandWithAdj(commands, e, -1)`; `RequestGroup.cc:827-844` computes `numCommand = min(numPieces, numConcurrentCommand_) - 1`. So with `-x16 -s16` aria2 opens the other 15 connections right after the first header, about 1 RTT + file-allocation after t=0, not gradually. No probing, no measurement, no ramp.
- `-x16 -s16 -k1M` on a 100 MB file: 100 pieces of 1 MiB, 16 connections [V by arithmetic on the code above].

### 1.2 Piece / segment assignment
- `SegmentMan::getSegment` -> `DefaultPieceStorage::getMissingPiece` -> `streamPieceSelector_->select(...)`: `SegmentMan.cc:203-243`, `DefaultPieceStorage.cc:386-399` [V].
- Selector choice: `DefaultPieceStorage.cc:96-112`. `default` (and empty) -> `DefaultStreamPieceSelector` -> `BitfieldMan::getSparseMissingUnusedIndex`; `inorder` -> `getInorderMissingUnusedIndex`; `random`; `geom` -> `GeomStreamPieceSelector(bitfield, 1.5)` [V]. Note: the default is SPARSE (not inorder, not geom).
- Sparse (default), `BitfieldMan.cc:244-300` [V]: finds the largest run of pieces that are missing and not in use. If a connection already owns the piece just before the run, it starts at the run's MIDPOINT (`currentRange.getMidIndex()`). It returns the run only if the previous piece is finished-and-unused, or the run is at least `minSplitSize` long (`:284-291`). That is "halve the biggest free hole", the same idea as Rays' `split_largest`, but at 1 MiB piece granularity and only for NEW requests (a running request is never shortened).
- Inorder, `BitfieldMan.cc:381-420`: take the first free piece, else the first free run `>= minSplitSize`. Geom (`:324`): exponentially growing offsets (base 1.5), so early pieces come first (streaming/media use).
- `min-split-size` effect [V]: `AbstractCommand::calculateMinSplitSize` (`AbstractCommand.cc:888-895`) returns `--min-split-size` (or the piece length if pipelining). With 20M default, a hole is only split if >= 20 MB, so a 100 MB file yields at most about 5 useful splits even with `-x16`; with `-k1M` any 1 MiB hole can be taken, which is why `-x16 -s16 -k1M` is the "fast" setting and what our bench uses.
- Request range: each request covers one piece, and keeps going into piece i+1 on the same socket only if that piece is free: `DownloadCommand::prepareForNextSegment`, `DownloadCommand.cc:317-381`. Otherwise `prepareForRetry(0)` (new request, line 369/378) [V]. So aria2 does many small (1 MiB) ranged requests per connection, each carrying a request RTT unless the next piece is contiguous.

### 1.3 Slow connections and stealing
- `--lowest-speed-limit` default 0 (off): `OptionHandlerFactory.cc:853-854` [V]. When set, `DownloadCommand::checkLowestDownloadSpeed` (`DownloadCommand.cc:302-315`) throws `DL_ABORT_EX2(... TOO_SLOW_DOWNLOAD_SPEED)` once the connection is past a 10 s `startupIdleTime_` (`DownloadCommand.cc:83`, hidden option `OptionHandlerFactory.cc:982`) and its speed is `<=` the limit [V].
- On abort `AbstractCommand::execute` catch (`AbstractCommand.cc:345-359`) records the URI result, calls `onAbort()` (cancels the segment back into the pool) and `tryReserved()` (`:417-436`) which starts a replacement command that takes a new piece [V]. Whether the same URI is tried again after a "too slow" error depends on URI-selector state (`addURIResult`) [U, not traced].
- `SegmentMan::getCleanSegmentIfOwnerIsIdle` (`SegmentMan.cc:254-283`) is NOT work stealing from slow peers. It is used when a connection wants "the next piece (index+1)" which is owned by another command that has written 0 bytes and whose `PeerStat` is IDLE; it cancels that owner and takes the piece [V]. It never takes a half-downloaded piece.
- Server-level: every 10 s `AbstractCommand` calls `fileEntry_->findFasterRequest(...)` (`AbstractCommand.cc:~236-247`) and may switch to a faster MIRROR; irrelevant for one URL [V].
- No endgame duplication for HTTP: `isEndGame()` is only consulted for BitTorrent (`DownloadCommand.cc:251`) [V].

### 1.4 Keep-alive, pipelining, buffers, loop, disk
- `--enable-http-keep-alive` default true, `--enable-http-pipelining` default false: `OptionHandlerFactory.cc:1069, 1079` [V]. Pipelining is off, so reuse = keep-alive sequential requests.
- Socket buffers: aria2 does NOT set SO_RCVBUF by default; `--socket-recv-buffer-size` default 0 = skip (`OptionHandlerFactory.cc:701-704`, `SocketCore.cc:181-189`) [V]. The OS autotunes. Application read buffer is a fixed 16 KiB per connection: `SocketRecvBuffer.h:72` (`std::array<unsigned char,16_k>`) [V]. TCP_NODELAY is set at `SocketCore.cc:570` [V].
- Event loop: ONE thread, `epoll` (Linux) / `kqueue` (macOS/BSD) / libuv / poll / select, chosen in `DownloadEngineFactory.cc:95-125` [V]. Each connection is a `DownloadCommand` re-queued with `addCommandSelf()`; it reads at most 16 KiB per turn. Thousands of syscalls per second but no thread handoff.
- Disk: `--disk-cache` default 16M (`OptionHandlerFactory.cc:175-182`) [V]; `SinkStreamFilter` writes into `WrDiskCache`, flushed per piece in `completeSegment` -> `flushWrDiskCacheEntry` (`DownloadCommand.cc:115-130, 403-408`) [V]. `--file-allocation` default prealloc.
- Resulting steadiness: 16 independent windows, a replacement connection after abort, and no feedback loop that can lock the count low.

## 2. wget2 and GNU wget 1.25

### 2.1 wget2 (base `https://github.com/rockdaboot/wget2/blob/43fecef/`)
- `--max-threads` default 5 (`src/options.c:1303`); threads are per queued JOB (URL), not per range: the spawn loop is `for (; nthreads < config.max_threads && nthreads < queue_size(); ...)` (`src/wget.c:1559`). One URL = queue size 1 = ONE worker thread [V].
- `--chunk-size` is off by default (`doc/` text: "multithreaded chunks", `docs/wget2.md:848-851`). With it, after the first response `src/wget.c:2088-2114` builds a fake Metalink with one piece per chunk (`npieces = ceil(len/chunk)`) so several workers can fetch parts [V].
- CATCH: `src/options.c:3544-3545`: `if (max_threads < 1 || (max_threads > 1 && chunk_size)) max_threads = 1;` (added 2017-11-29, commit `206093dc` "Prevent --max-threads & --chunk-size flags combination") [V]. Read literally, setting `--chunk-size` forces ONE thread, so chunks are fetched sequentially. I could not run wget2 here, so whether real multi-connection chunking happens in current releases is [U]; the docs claim it, the code at HEAD does not obviously deliver it. Test before relying on wget2 as a "multi-connection" baseline.
- HTTP/2: on by default (`options.c:1333`), ALPN `h2,http/1.1` (`:3875-3877`), `--http2-request-window` default 30 (`:1334`). The window is used only for non-metalink jobs: `src/wget.c:2618-2620` sets `max_pending = 1` for `job->metalink` (chunk jobs) and for non-H2 [V]. So multiplexing helps many small files, not one big file's chunks.
- Net: wget2 multiplexes across files (H2, 5 threads); a single big file is one stream unless `--chunk-size`, and that path is suspect.

### 2.2 GNU wget 1.25 (`https://git.savannah.gnu.org/cgit/wget.git/tree/src/retr.c?id=3e48e3c`)
- Single connection per file: no thread/parallel code in `src/` apart from OS shims (`mswindows.c`, `openssl.c`, `utils.c` mention "thread" only) [V, grep]. Resume uses one `Range: bytes=N-` (`-c`, `--start-pos`). No range splitting [V].
- Buffer: `fd_read_body` uses `dlbufsize = MAX(BUFSIZ, 64*1024)` = 64 KiB (`retr.c:261`) [V]. Not a bottleneck.
- Socket: SO_RCVBUF is set only when `--limit-rate < 8192` (`src/connect.c:321-329`) [V]. Default untouched.
- Progress bar redraws at most every 0.2 s (`progress.c:584 REFRESH_INTERVAL 0.2`) [V]; cost negligible.
- So why 1.2 MB/s on our line [U, inference]: one TCP flow at ~75 ms RTT with loss is loss-bound (Mathis, section 3.3). curl was 1.9 MB/s at its worst run for the same reason. The Homebrew build is OpenSSL-linked (`otool -L`); I found no code-level bug. The 1.2 vs 9.6 gap between wget and curl could also be curl's HTTP/2 or different TLS/IPv6 selection [U, untested].

## 3. Hypothesis check with Rays' real constants

Constants (`download.rs:29-40`): TICK 1 s, WARM_TICKS 1, WINDOW_TICKS 2, HOLD_TICKS 15, MIN_SPLIT 4 MiB, MIN_SEGMENT 1 MiB, PENALTY 1.02, probe threshold `window >= best*1.1` (`:433`). `bench` and the app start with `start = 1` part (`bench-vs.sh:23` passes `16 1`). reqwest is built `default-features=false, features=[native-tls, system-proxy]` and `h2` is absent from `Cargo.lock`, so it is HTTP/1.1 only: every "connection" is a real TCP socket, not a stream on one H2 connection [V].

### 3.1 Ramp timeline [V from code trace]
- t=0 one connection (the probe's own). Tick 1: Warm -> Measure. Tick 2: Measure(1). Tick 3: `judge(Rebase)` -> `advance(probe=true)` -> `Add` (2 connections at t=3).
- Each following probe: Warm (1 tick) + Measure (2 ticks) = 3 ticks, judged at the third. Adds at t = 3, 6, 9, 12, ... so connections(t) = 1 + floor(t/3) if every probe passes.
- A failed probe (`window < best*1.1`) -> Remove -> Warm -> Rebase(shrink) -> by about t+3 it is `Hold(0)`; the next probe waits `HOLD_TICKS = 15` s (`:401-416`). Failed probe at t=6 means next try at about t=24 [V].

### 3.2 How far does a ~100 MB / ~10 MB/s download get? (model: per-connection rate r, line ceiling 10 MB/s)
Python model, all probes pass, ramp every 3 s [model, validated only against our medians]:

| per-conn r (MB/s) | file done at | connections at end | avg MB/s | aria2 16 @ t~0.4 |
|---|---|---|---|---|
| 1.5 | 18.6 s | 7 | 5.4 | 9.7 |
| 2.5 | 14.5 s | 5 | 6.9 | 9.7 |
| 5 | 11.5 s | 4 | 8.7 | 9.8 |
| 10 (one conn fills line) | 10.0 s | 4 if probes pass, but they would fail | 10.0 | 10.0 |

- Answer: yes, the hypothesis holds. By the time the file is done Rays has at most 4-5 connections (7 only on a slow-per-connection line), never 16. At r=5 the model gives 8.7 MB/s, exactly our measured median (8.7).
- The bad tail is a different mechanism: one false-rejected probe. A 2 s window on a noisy line easily varies +/-15%, and `best` is set from a single window (`advance`: `self.best = window`, `:450`), so a lucky baseline rejects a good probe. Then the count sticks for 15 s, which exceeds the whole file. Model: failure at t=6 gives 5.9 MB/s (r=5) or 2.7 MB/s (r=2.5). Our min of 4.5 MB/s fits this [model, U for the actual cause; confirm with a log of probe decisions].
- aria2 `-x16`: no decision to get wrong; once connected it spreads risk over 16 flows (min 8.6 vs Rays 4.5).

### 3.3 TCP effects (RTT 50-100 ms India to Singapore) [U, textbook, not measured here]
- BDP: 10 MB/s x 75 ms = 750 KB in flight. macOS autotunes the receive buffer (up to ~4 MB, existing doc), so the window is OK, but a single flow must grow cwnd from IW10 (14.5 KB): log2(750/14.5) = 5.7 doublings = about 6 RTT = 0.45 s, plus 1-2 RTT of TLS before that. N connections ramp in parallel (aggregate initial window N x IW10), so the aggregate reaches the line rate in the same 0.5 s that one connection reaches only 1/N of it.
- Loss: Mathis rate = 1.22 x MSS / (RTT x sqrt(p)). MSS 1448 B, RTT 75 ms: p=1e-3 -> 0.75 MB/s; p=1e-4 -> 2.4 MB/s; p=1e-5 -> 7.4 MB/s per connection. On a noisy long-RTT path one flow often cannot fill 10 MB/s; N flows can (N x r).
- Steadiness: a loss event halves ONE flow's window, so aggregate drops by 1/(2N) (N=16 -> 3%, N=1 -> 50%). Per-window variance of the sum of N flows falls like 1/sqrt(N), which also makes Rays' 10% probe test less noisy at higher N but useless at N=1-2, where it matters most.
- Cost of many connections: N TLS handshakes (1-2 RTT each, about 75-150 ms) and N slow starts. With a 100 MB / 10 s file this is small relative to the 5-8 s Rays spends at low counts.

## 4. Recommendations (Rays)

`perf-audit.md:39` already suggests `min(cap,4)` segments up front for >= 32 MB. Numbers below quantify it and add items it does not cover (marked NEW).

A/B harness: `scripts/bench-vs.sh <url> <rounds>` (interleaved rounds, warm-up round dropped, medians) and `cargo run --release -p dl-engine --example bench -- <url> 1,4,16 <runs>` (arg 2 = `connections` cap, runs interleaved). `bench.rs` currently has no way to set `start`; add `RAYS_BENCH_START` (default 1) feeding the existing start parameter, and (for 2-4) `RAYS_BENCH_PROBE_*` env overrides read once in `bench.rs` only, so product defaults do not change. Use at least 10 rounds, report median AND min (the min is where the lock-out shows) and a paired sign test per round vs the baseline. Also log each `Grow` decision (tick, window, best, action) to stderr under `RAYS_BENCH_TRACE`.

1. Size-aware start (partly in perf-audit). `start = 4` for total >= 32 MB when the host has no remembered limit (`store.host_limit`) and no 429 yet; `start = 2` for 8-32 MB; `1` below. Expected: t_done 14.5 -> ~10.5 s at r=2.5, 11.5 -> 10.3 s at r=5 (+10-40%); min-of-3 rises. Risk: some servers cap 2-4 connections per IP; 4 is under the browser norm (6), and the existing 429/503 handling (`throttled`, `park`, `note_host`) already backs off. Fairness: on shared links 4 flows take ~4x one flow's share; keep cap lower for LAN/ISP-hostile hosts via the remembered limit. A/B: `RAYS_BENCH_START=1` vs `4` interleaved on the Hetzner file and a second CDN file.
2. NEW: stop the false-reject lock-out. (a) After a failed probe, re-probe after 5 ticks, not 15, while `remaining_bytes / window > 10 s`; keep 15 s only after 2 consecutive failures. (b) Replace `best = window` with a smoothed value (EWMA over the last 3-4 windows, or max over the Hold period) and accept a probe if `window >= 1.05 * best` OR the 2 s window beats the 3 s prior mean. (c) Keep the 1.02^n penalty only for Shrink. Expected: removes the 2.7-5.9 MB/s outcomes; min of rounds 4.5 -> 7+ (model). Risk: more connection churn on lines where extra connections truly do not help (cost: 1 wasted handshake per 5 s). A/B: 10+ rounds; success metric is min and p10, not median.
3. Faster ramp on large files: exponential 1 -> 2 -> 4 -> 8 while each step's gain >= 25% (additive +1 afterwards). Adds at t = 3, 6, 9 -> 2, 4, 8 connections instead of 2, 3, 4. Model at r=2.5: file done about 11.0 s vs 14.5 s. Risk: bursts of 3-4 new connections per step might trip per-IP limits; the existing 429 path catches it. Alternative with less risk: shorten TICK to 500 ms with WARM 1 / WINDOW 2 (1.5 s per step, in perf-audit.md:39) but noisier windows; do 2 first. A/B: flag `RAYS_BENCH_RAMP=exp|add`.
4. Lowest-speed reassignment (aria2's `--lowest-speed-limit` idea, but relative, NEW): per-segment bytes/s over 5 s. If a connection's rate is below 25% of the median of the others (>= 3 running) for 2 consecutive windows, stop that task and put its remaining range at the back of `parked`/split queue so a fresh connection (new TCP flow, fresh cwnd and possibly a better path) takes it. Also an endgame hedge: when remaining unsplittable bytes < 2 x MIN_SEGMENT and a connection is idle, request the slowest segment's tail on the idle connection and cancel whichever finishes second (duplicated bytes <= 2 MiB). aria2 has neither for HTTP (section 1.3), so this goes beyond aria2. Expected: fixes the 1-2 slow flows that stretch the tail on noisy lines; gain a few percent on median, more on min. Risk: churn when speeds are naturally uneven; mitigated by the 25% and 2-window rule. A/B: bench with injected slow connection (tc/pf or a local axum server with one throttled range) plus Hetzner.
5. Reuse connections between ranges and avoid truncating the probe stream: segment 0 reads the probe's open-ended response (`download.rs:855-926`); once a split lowers its `end` the task breaks out mid-body and the socket is dropped (not returned to the H1 pool), costing one TLS + slow start. Issue the probe as a `Range: bytes=0-<first_part-1>` request when `start > 1`, or `0-(total/2)` when ramping, so the first connection ends cleanly and is reused. Expected: saves 1 handshake + slow start (~0.2-0.4 s at 75 ms RTT), small but free; risk: servers that reply 200 to ranged probes (already handled by `Stop::Fallback`). A/B: count new TCP connections per run (`lsof`/`nettop`) and time-to-first-steal.
6. Do NOT chase: SO_RCVBUF (aria2 leaves it 0, macOS autotune already reaches the BDP; setting it disables autotuning, per `download-speed-research.md` section 3), and wget2 `--chunk-size` or H2 multiplexing for one big file (section 2). Larger value from the already-listed per-chunk `flush()` removal (`perf-audit.md:16-23`) only shows above ~200 MB/s.

Priority by expected gain per effort: 2 (low effort, fixes worst-case), 1 (trivial), 3, 4, 5.

## 5. Claim index
- [V] aria2: x1/s5/k20M defaults; URI replicated `min(x,s)`; 1 conn then N-1 after header; sparse default selector; min-split-size check; 16 KiB read buffer; SO_RCVBUF default 0; epoll/kqueue single thread; 16M disk cache; lowest-speed abort + 10 s startup idle; `getCleanSegmentIfOwnerIsIdle` semantics; no HTTP endgame.
- [V] wget2: max-threads 5, per-job threads, chunk-size to metalink pieces, `max_threads=1` override with chunk-size (options.c:3544), H2 window only for non-metalink jobs.
- [V] wget 1.25: 64 KiB buffer, no parallelism, SO_RCVBUF only under tiny `--limit-rate`.
- [V] Rays: HTTP/1.1 only, tick/probe/hold constants, ramp timeline, 15 s lock-out after a failed probe.
- [U] wget2 real runtime behaviour with `--chunk-size`; cause of wget's 1.2 MB/s; aria2 retry of a URI after TOO_SLOW; Mathis numbers on this path; per-connection r; false-reject as the cause of the 4.5 MB/s run (model fits, not traced).

## Result (A/B, 23 Nov 2026)

Recommendations 1 and 2 (start files of 32 MB+ on 4 parts; 5 s hold after a failed probe in the first 30 s) were
built and A/B tested against the previous engine on sin-speed.hetzner.com, 7 rounds interleaved:

| Engine | Cap 4 | Cap 16 |
|---|---|---|
| Before | 8.8 MB/s (6.7-9.9) | 8.5 MB/s (5.2-10.5) |
| With 1 and 2 | 8.5 MB/s (4.5-9.3) | 5.6 MB/s (3.8-6.9) |

Slower at cap 16 in 6 of 7 rounds, so both were reverted. The ramp hypothesis did not hold: the old engine already
reaches the line's ceiling. Batched segment writes (256 KiB) and one event wake-up per pending job were kept:
same speed, about 20% less CPU on a local 1 GB server (`engine/examples/serve.rs`). `opt-level = 3` and 4 worker
threads showed no gain and were not kept.

## Result: graceful removal (A/B, 23 Nov 2026)

Removing a connection the aria2 way (the newest segment ends 1 MiB past its written bytes and the rest is parked,
instead of stopping its request) measured no better: cap 4 9.3 vs 8.6 MB/s, cap 16 9.0 vs 9.4 MB/s (old vs new,
median of 7), with the per-round winner flipping. Reverted.

The A/B script first ran the old engine first in every round. With the order alternated, whichever engine ran
second was faster in 6 of 7 cap-4 rounds, so on this line a gap of about 1.5 MB/s is noise. The "start on 4
parts" result above was measured with the fixed order and should be read with that in mind.
