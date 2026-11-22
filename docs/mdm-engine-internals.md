# Mister Download Manager (MDM) engine internals vs Rays

Source: https://github.com/anefzaoui/misterdownloadmanager (shallow clone, GPL-3.0, Rust). Ideas only; no code copied.
Tags: [V] verified in source, [U] inferred. Paths are relative to the MDM repo unless prefixed `rays/`.
Complements `docs/aria2-wget-internals.md`, `docs/download-speed-research.md`, `docs/perf-audit.md` (not repeated).

## TL;DR

- MDM is an IDM clone built from IDM's public docs ([V] README "Not a reverse-engineering project", `planner.rs` header cites "IDM's documented rule"). Its model is the opposite of Rays: start N connections at once (default 8, max 32/128), then cut losers (shed slow, learn host cap from refusals). Rays starts at 1 and probes up.
- Its headline "instantly" (14 ms vs IDM 3.1 s) is mostly IDM's own 3 s startup overhead, not a network trick. Its 1 GiB "5x faster" is also dominated by IDM's 1.8 s transfer + 3 s startup vs MDM's 14 ms + 438 ms [V] (`docs/bench/run5/REPORT.md`). The loopback numbers time the programs, not the network.
- Rays already matches the real start-latency trick: first response is reused as the stream (`rays/engine/src/download.rs` ~L270-295, `run_split(..., Some(resp))`). [V]
- The valuable parts are (a) the fault-injecting lab server and harness method, (b) slow-connection shedding with a share-of-link bar, (c) adaptive flush policy, (d) the IDM "take over the next pending connection" tail rule.

## 1. Connection strategy

Start count
- `Options::default` max_connections = 8, min_split = 12 KiB, max_retries 5, retry_delay 1 s, connect/read timeout 30 s (`crates/engine/src/download.rs` `impl Default for Options`, L270-311). [V]
- `supervise()` (L4107-4195) spawns workers up to `max` immediately (no probe-up ramp). `max = min(user cap, host-learned cap)`, then `min(max, ceil(size / INITIAL_PIECE))` with `INITIAL_PIECE = 64 KiB` (L78, L4132): a 256 KiB file starts with 4 connections, not 8, "opened all at once they would cut it into slivers and fetch some twice (benchmark 2026-10-30: 256 KiB took 13-19 requests)". [V]
- Hard ceilings: `MAX_CONNECTIONS = 32`, `MAX_CONNECTIONS_UNLOCKED = 128` (L84-87). [V]
- Bench shows it really opens many: 1 GiB fast link used 17 connections / 31 requests at default 8 (REPORT.md phases). Shedding and splitting reconnect a lot; they accept the churn. [V]

Per-server limits (the "2 vs 480" claim)
- Not detected by probing. Learned from refusals: `hosts.rs` `HostLimits::refused(host, working)` / `cap` / `working`. When an extra connection is refused (429/503/refused) while others receive data, the cap is the most connections ever seen working at a refusal; it applies after `NEEDED = 2` observations, decays after `DECAY = 10 min`, is raised by `working()` if more are later seen receiving, never lowered. Shared across downloads (`Options::host_limits` is an `Arc`). [V]
- Use site: `worker()` L4303-4328: on refusal with others working, `limits.refused(host, receiving)`; if `working >= cap` the extra connection retires (`ConnStatus::Retired`), else retries as usual because the server may still count a just-closed connection (comment cites a benchmark where retiring early left 50 MiB on one connection for 12 s). Next downloads pre-cap in `supervise` (L4119-4126). [V]
- The "2 vs 480" is therefore: labserver `max_conns` returns 503 to extras (`labserver/src/faults.rs` `max_conns`: "extra requests get 503"), MDM learns cap 2 after two refusals and stops; IDM retries forever (480 connections in 50 MiB). MDM still sends the first refusals, it just stops after two. The 2-connection result also benefits from the server log counting only served connections. [V for MDM logic, U for IDM behaviour]
- Rays comparison: `store.note_host` + `host_limit` (rays/engine/src/download.rs L270, `rate_limit_429_is_remembered...` test) already persists a cap after 429. MDM differs by: cap value = max concurrently receiving (not a fixed step), needs 2 observations, decays in 10 min, is raised again when more are seen working. [V]

Slow-connection handling ("shed")
- `Options::shed_slow` default true. In `receive()` every 500 ms (L5548-5556) a connection calls `should_shed` -> `too_slow` (L5959-5994): after `SHED_GRACE = 2 s` on the response, speed*4 < bar (`SHED_RATIO = 4`) AND remaining bytes of its segment at its own pace > `SHED_LEFT = 2 s` -> returns `Error::SlowConnection`; the worker reconnects at once for the rest of the segment, not counted as a failure (L4299-4302). [V]
- The bar (`shed_bar`, L5939): `min(best single-connection speed, best link window / receiving connections)`. Link = best 1 s window of all connections' total (`note_link`, `LINK_WINDOW`). This fixed #896: when connections share a line, comparing against the first lone connection's speed shed everyone every few seconds. Single-connection speed (`yardstick`) counts only after 256 KiB and 100 ms. [V]
- Disabled when: speed limit active, `request_cap` set, or the disk is the bottleneck (`disk_held` within 2 s: a connection stood still for disk writes). The disk exclusion exists because bursts after a disk stall inflated the bar and shed everyone at once (#782). [V]
- Their measured motive: "14 s instead of ~2 s for 32 MiB when every third request was slow" (L69-73); bench `slowconn-32m`: MDM 3.4 s vs IDM 7.2 s. [V]

Endgame / tail / work stealing (`planner.rs`, pure logic, random-simulation tested)
- `Planner::assign` (L184-236), when a worker is free, in order: (1) an unassigned unfinished segment (resume, failed worker), preferring the one continuing where it stopped; (2) IDM's reassign rule: take over the next segment `a` if its connection has not received a byte yet and has waited at least `preempt_after = max(2 x probe TTFB, 20 ms)` (`PREEMPT_TTFB`, `PREEMPT_MIN`, L79-82, L2341); the pending worker's claim returns `Lost`; (3) split the largest remaining segment in half, take the upper half, unless half < `min_split` (12 KiB), split point rounded down to 4096. [V]
- Claim/commit protocol: workers `claim` bytes before writing and `commit` after; splits measured from the claimed position so a split never cuts bytes being written (L246-273). [V]
- `absorb_next`: the probe's plain GET keeps reading into the next segment if nothing has arrived there, avoiding a re-request the server may ignore. `make_single`: server ignores ranges -> collapse to one segment, never split again. [V]
- Rays comparison: our `split_largest` / MIN_SPLIT = 4 MiB (rays/engine/src/download.rs L29, L784) is coarse; MDM splits down to 12 KiB, so its tail is tighter, at the cost of many extra requests (31 requests for 1 GiB). Rule (2) (take over a not-yet-receiving neighbour) has no Rays equivalent. [V for both, tail benefit U]

## 2. Start latency

- First request is a plain GET without Range ("as IDM does", L3-4, D-007); that response is connection 0, it keeps streaming from byte 0 while other connections split the file. Size, validators, file name come from its headers. No HEAD. Range support is learned from the first Range answer: 206 confirms, 200 -> back to the probe connection alone (L3-6, `supervise` L4110-4116). [V]
- Optional pre-probe: the add-URL dialog's look can be kept open and handed to the download (`probe_kept` L973 -> `KeptAnswer`, valid `KEEP_ANSWER_FOR = 15 min`, `Download::start_with`), so one-time links work and no second request is needed. [V]
- One shared `reqwest` client per download with keep-alive pool and TLS session resumption (L7-9 doc, L1913-2091). Connection opening is timed by their own connector layer (`server::Timed`) rather than an extra probe. [V]
- DNS: `dns.rs` wraps the resolver (system getaddrinfo or hickory DoT/DoH). When a host has several addresses it races TCP connects staggered per RFC 8305 and caches the winner so later connections skip the race; single address passes straight through. This is Happy Eyeballs applied to a download's connections. [V]
- `preempt_after` and `ttfb`: the TTFB of the first answer is measured (`first_try`, `ttfb`) and used to tune takeover timing. [V]
- Pre-warming: no evidence of speculative sockets or DNS prefetch before the user adds the URL (the app only holds the kept answer). [U, absence of grep hits for prewarm/prefetch]
- The "3.1 s" for IDM is `startup` phase in the bench: 3076 ms (IDM) vs 14 ms (MDM) in fast-1g, same in every scenario (REPORT.md). It is IDM's launch/dialog overhead measured via `IDMan.exe /d ... /n`. The README's "instantly" is a comparison against that, not a protocol innovation. [V]
- Rays status: already reuses the first response (`rays/engine/src/download.rs` ~L295 `run_split(..., Some(resp))`). Nothing to take except optionally keeping the add-dialog probe alive (only matters for one-time links). [V]

## 3. I/O and crash safety

- Positional writes: `write_all_at` (L6068) uses `FileExt::write_at` on unix, `seek_write` on Windows, run in `spawn_blocking`. No mmap. [V]
- Buffering: each connection accumulates `BATCH = 256 KiB` buffers (same as Rays' WRITE_BATCH). Batches are fixed-capacity and never grown (memory test `tests/memory.rs` counts allocations); `WRITE_MAX = 4 MiB` per write call; `SPARE_MAX` spare buffers reused. A shared `HOLD_MAX = 256 MiB` is how much may wait in memory while the disk is busy; after that connections stop reading (TCP backpressure). `FLUSH_EVERY = 1 s` forces partial batches out so slow connections show progress. [V]
- Preallocation: `file.set_len(size)` (L2611), created sparse; on Windows they mark the file sparse first (`sparse.rs`: NTFS zero-fills the gap if you `set_len` then write far ahead). On unix `set_len` is already sparse; no fallocate. [V]
- Resume state: JSON `<name>.mdm.json` beside `<name>.mdm.part` (`state.rs`): `{version, url, final_url, dest, size, validators{etag, last_modified, date, digests}, segments[{start,cursor,end}], content_type, checksum, ...}`. Written with `craft_atomic::atomic_write` (temp + rename). Cookies and Authorization are deliberately not stored. Segments must tile `[0,size)` exactly or `Planner::resume` returns `InvalidState`. [V]
- Fsync policy, the clever part (`Synced`, `sync_bytes`, `save_state`, L3260-3405): `part.sync_data()` then write state, so the state never claims unflushed bytes. Flush is due only when `new >= clamp(size/16, 1 MiB, 64 MiB)` or 30 s since the last, checked at the 2 s save tick, and only if `Synced::fits`: the expected flush time (from the previous flush's cost per byte) must be under 75% of the time the remaining memory hold (`HOLD_MAX - held`) lasts at the current rate. On a disk slower than the network the flushes stop and the OS paces writes. Pause/stop/finish always flush. Cost: after power loss, re-download bytes since the last flush (~2 s worth on a fast disk). [V]
- Why: on NTFS a flush blocks all writes to the file for 3-10 s (#361), and spacing flushes by the previous flush's duration made each longer (#782). [V]
- Finish: size check then rename; `sync_all` after `set_len` in verify path (L3077-3082). [V]
- Rays comparison: scheduler.rs flushes `sync_data` every 2 s of progress. On macOS `sync_data` (fsync) does not force the drive cache (F_FULLFSYNC does), so its cost is small and the stall problem is a Windows/NTFS and slow-disk one. [U] Expect little gain on APFS/SSD; useful if Rays ships on Windows or writes to slow external disks.

## 4. HTTP client stack, timeouts, retries

- `reqwest` (+ `wreq`/BoringSSL "browser-like" connection used only for sites with bot checks, feature `browser-connection`) with rustls (`tls.rs`, `rustls-platform-verifier`, webpki roots). `.http1_only()`, `.tcp_nodelay(true)`, `.pool_max_idle_per_host(connections)`, `.pool_idle_timeout(15 s)` (shorter than server keep-alive so a paused download does not come back to dead sockets), `connect_timeout` 30 s, `read_timeout` 30 s (L2083-2090). [V]
- HTTP/2 is deliberately off: each worker needs its own TCP connection with one request in flight; h2 would multiplex onto one socket and defeat per-connection servers' limits. [U, inferred from `http1_only` plus doc line 7-9]
- Retry (`retry_wait`, L566): first retry immediate (they measured IDM reconnecting in ~12 ms), then `retry_delay` doubling (1,2,4...) cap 30 s; 429/503 with Retry-After uses it, capped at 5 minutes (`retry_after()` parses seconds or HTTP-date, L6103). Failure budget resets when a connection made progress since its last failure. `max_retries = 5` per connection. [V]
- Error taxonomy: `is_fatal`, `link_dead`, `transient`, `refused`, `wants_new_address` (signed CDN links: `refresh_target` re-resolves the original URL at most every 120 s, `REFRESH_EVERY`). [V]
- Resume validation: `If-Range` with validators incl. per-node ETag and digest heuristics (`same_file`, `per_node_etag`, `other_server_copy`, `copy_by_digest`), plus re-fetching the last `verify_overlap = 64` bytes already on disk and comparing before continuing (IDM's overlap check). [V]
- Rays comparison: same reqwest family. Rays has Retry-After (`note_retry_after`). MDM's overlap check is a cheap integrity guard Rays may lack. [U on Rays]

## 5. Benchmark harness (tools/bench) and what to reuse

Method (`tools/bench/bench.py` docstring and `one_run`, `report.py`) [V]
- Server: their own `labserver` crate (`crates/labserver`, axum), generated content (no disk reads), Range support, per-request JSON log (`server.jsonl`), and fault injection through query params: `rate` (per-response cap), `burst`, `link_rate` (one shared link; connections take turns, so one connection alone takes it all, n share it), `latency_ms`, `slow_every` + `slow_rate` (every Nth request crawls), `max_conns` (503 for extras per client IP), `drop_after` + `drop_every` (cut the body), `fail_every`/`fail_first` (503), `no_range`/`no_range_every` (`labserver/src/faults.rs`). [V]
- Scenarios (id, size, faults, runs): fast-1g 1G (7); capped-100m rate=2M (7); latency-100m rate=4M latency_ms=150 (7); slowconn-32m slow_every=3 slow_rate=128K rate=4M (7); maxconns-50m rate=2M max_conns=2 (7); drops-50m rate=4M drop_after=2M drop_every=2 (7); small-256k (15). [V]
- Per run: delete final/part/state files; start CPU and working-set sampler; hand one URL to the client via its CLI; poll the destination size every 1 ms with `perf_counter` until it equals the expected size; end-to-end ms. Then 300 ms settle, read CPU time. From the server log: network phase (first request to last byte), connections, requests, bytes sent over file size (waste), refusals, drops. [V]
- Fairness: clients alternate who goes first (even/odd runs), one discarded warm-up per client and scenario, `settle()` waits for the machine and lingering processes to quiet, both clients at default settings (8 connections). [V]
- Stats: median and IQR per scenario, ratio IDM/MDM with 95% CI, Mann-Whitney p-value (`report.py`). Raw `runs.json`, `server.jsonl`, `environment.json` are committed (`docs/bench/run5`). [V]
- Caveats: Windows only (Win32 sampler), loopback (times programs not networks), `latency_ms` is server-side per-response delay not a real RTT on the TCP path (so it does not affect TCP ramp-up/cwnd), no packet loss emulation (loss is simulated only by connection cuts), single machine, 7 runs. The e2e timer includes client launch, which favors a client with fast startup: the 105x small-file number is startup, not transfer. [V/U]

Reusable concepts for a Rays vs aria2 vs curl benchmark on a local server
1. One generated-content server with fault knobs as URL query params, and a per-request log (time, range, status, bytes sent, connection id). Rays' `rays/engine/tests/download.rs` `Link` (L794) already has per-connection `gap`, a shared budget and an `admit` limit (429); it lacks `latency`, `slow_every`, `drop_after`, `max_conns` as 503, and a request log. Better: promote it to a standalone binary (Rust or a small Node/TS script) so aria2c and curl can hit it too.
2. Time definition identical for all tools: wall clock from process spawn to final file size == expected, polled at 1 ms; do not trust each tool's own timing. Subtract nothing; report startup separately by also timing a 256 KiB file.
3. Per-run server-side metrics: connections, requests, bytes sent / file size, refusals. This shows waste and politeness, which wall time hides.
4. Alternate order, discard first run, 7+ runs, report median and IQR, and a rank test only if comparing claims. Record environment (macOS version, power mode, other load).
5. Equal settings: `aria2c -x N -s N -k 1M`, `curl` single stream (and `curl --parallel` is not segmented, so only a baseline), Rays cap = N. Test N = 1, 4, 8 separately since Rays starts at 1 and probes up.
6. Scenarios that matter for Rays: per-connection cap (multi-connection wins), shared link (should NOT win from more connections), latency (RTT per request), slow_every, max_conns, drop_after (resume cost), small files (startup), no_range.
7. CPU and RSS via `/usr/bin/time -l` (macOS: max resident set, user+sys) instead of Win32 sampling.

## 6. Anything clever Rays lacks

- Shed-and-reconnect for individually slow connections with a share-of-link bar and disk-stall exclusions (see 1). Rays' Grow controller adds/removes by aggregate throughput but does not reconnect one bad TCP path. [V MDM, U Rays; Rays `Grow` removal is by step-down, which was tried as aria2-style removal and reverted]
- Fine-grained splits (12 KiB) plus takeover of pending neighbour: better tail on high-latency/slow-start servers. [V]
- Host cap learned from observed concurrency at refusals, raised when proven wrong, decays. [V]
- Memory accounting bound (HOLD_MAX 256 MiB, fixed-capacity batches, allocation test). Rays buffers per connection 256 KiB; a disk-stall backpressure budget is not needed on a fast SSD. [V/U]
- Disk-aware controller: connection speeds are not trusted when the disk set the pace (`disk_held`). Relevant to Rays' Grow controller if the disk (not the link) ever limits: it would read "no gain from +1 connection" correctly anyway. [U]
- Happy-eyeballs address race with remembered winner (`dns.rs`). Useful only on hosts with a dead first A/AAAA record; hyper/reqwest already do HE across families, not within a family. [V MDM, U on Rays]
- Resume overlap check (64 bytes) and `If-Range` with per-node ETag logic. [V]
- Per-flow `request_cap` mode (sequential capped requests on one connection) for sites like YouTube with per-request throttles. Irrelevant for Rays unless video. [V]
- Not present: throughput-based segment sizing, connection racing of the same range, adaptive buffer size. Segment size is "half of the largest remainder" only. [V]

## 7. Ranked ideas for Rays

Reference setup for A/B: line saturated by one connection, so A/B on the real line is noise. All ideas below are tested on a local server with emulated conditions. Preferred order of tooling: (1) in-process server (extend `rays/engine/tests/download.rs` `Link` with `latency`, `slow_every`, `drop_after`, `max_conns->503`), deterministic and CI-safe; (2) macOS `dnctl`/`pfctl` dummynet for real TCP effects (RTT, loss, shared bandwidth) [U, not tested here]:
```
sudo dnctl pipe 1 config bw 100Mbit/s delay 75 plr 0.005
echo 'dummynet in on lo0 proto tcp from any to any port 8097 pipe 1' | sudo pfctl -f - -E   # or add to a pf anchor
sudo dnctl -q flush; sudo pfctl -d    # undo
```
`delay` is one-way per packet so 75 ms gives about 150 ms RTT on a loop through the pipe applied both ways; per-flow caps need a masked pipe (`mask src-port 0xffff`) [U]. Verify on lo0 first; pf on loopback often needs `set skip on lo0` removed from /etc/pf.conf. Network Link Conditioner is system-wide and slower to script; dummynet is the scriptable one.

Ranked list

1. Standalone fault-injection test server + harness (aria2/curl/Rays comparable)
   - Effect: enabler; nothing else is measurable without it. Gives reproducible scenarios (per-connection cap, shared link, latency, slow_every, drop_after, max_conns).
   - Risk: none (dev tooling). Effort: M (1-2 days; extend the `Link` struct into a bin, add request log + knobs, a TS runner that alternates tools and takes medians).
   - A/B: n/a; validate by reproducing MDM's published relationships (shared link: more connections must not beat one; per-connection cap: N connections ~ N x faster).

2. Shed-and-reconnect for a persistently slow connection (MDM `should_shed`/`shed_bar`)
   - Effect: large only on servers/CDNs where some connections land on slow paths (MDM: 14 s -> 2 s on 32 MiB with every 3rd request slow); zero on a clean line. Real-world value is plausible for CDN edges with uneven nodes. [V MDM numbers, U for real world]
   - Risk: medium. MDM needed fixes #896 (shed storms when connections share a link) and #782 (disk stall bursts). Mitigate by copying the concepts: bar = min(best single, best shared-window / active), 2 s grace, 4x ratio, >2 s of work left, never when rate-limited or after a stall.
   - Effort: M. Only applies when Grow has >= 2 connections; reconnect keeps the same Range remainder.
   - A/B: local server `slow_every=3 slow_rate=128K rate=4M` on a 32-50 MiB file, 7 runs, shed on vs off (feature flag). Also run a shared-link scenario (no per-conn cap) to prove no shed storm (request count must stay near connection count).

3. Tail takeover of a not-yet-receiving neighbour + smaller MIN_SPLIT near the end (MDM `assign` rule 2, `min_split` 12 KiB)
   - Effect: shorter last-seconds tail on high-RTT or throttled servers (the tail is where one slow remainder gates completion). Gain is bounded by tail length, typically 0.2-1 s on 100 MB files with 150 ms RTT. [U]
   - Risk: medium (extra requests, "fetch twice"; MDM added `preempt_after = 2 x TTFB` to avoid duplicate fetches). Our faster-reprobe and 4-part-start experiments measured no gain, so expect modest results.
   - Effort: M (change `split_largest` + a worker preempt path; needs claim/commit-style ownership, which Rays already approximates).
   - A/B: `latency=150ms` (dummynet), 100 MiB, per-connection cap, 3 or more connections; metric: time from 90% to done and total e2e, plus duplicate-bytes ratio from server log.

4. Learned-cap refinement: cap = max concurrently receiving at refusal, needs 2 observations, decays after 10 min, raised when more are seen receiving
   - Effect: avoids permanently under-using a host that rate limited once (hiccup), and avoids hammering a host that really caps. Low on speed, moderate on politeness and stability. [U]
   - Risk: low. Effort: S (store.note_host already persists; add count + timestamp + raise-on-evidence).
   - A/B: test server `max_conns=2` and `fail_first=1` (single hiccup must not cap); assert connection and refusal counts in the server log.

5. Adaptive flush policy (sync_data when 1/16 of size (1-64 MiB) or 30 s, only if the flush fits in the memory budget)
   - Effect: removes periodic stalls on slow or external disks and NTFS; negligible on APFS NVMe. Also less write amplification. [U]
   - Risk: medium (crash window grows; saved plan must keep not claiming unflushed bytes, MDM's invariant "snapshot -> flush -> write state").
   - Effort: S-M (scheduler.rs progress save path ~L528).
   - A/B: 5-10 GiB download to the internal SSD and to a USB HDD/SD card; compare stall histogram (max gap between progress samples) and e2e; run kill -9 mid-download and verify resume correctness.

6. Start-of-download hygiene: 64 KiB-per-connection initial sizing is irrelevant for Rays (starts at 1), but MIN_SPLIT = 4 MiB leaves files under 8 MiB single-connection; lowering to 1 MiB only helps with per-connection caps
   - Effect: small files 1-16 MiB on capped servers get 2-4x; no change on saturated lines. [U]
   - Risk: low. Effort: S (constant plus plan()).
   - A/B: local server `rate=2M` per connection, files 2, 4, 8, 16 MiB, Rays vs aria2 -x4 -k1M; metric e2e.

7. Resume integrity overlap check (re-fetch last 64 bytes, compare) and `If-Range` with validators
   - Effect: correctness (stale-part corruption after file changes); no speed effect. [V MDM]
   - Risk: low. Effort: S-M. A/B: server that changes content between runs (same path, new ETag/length); assert Rays restarts instead of splicing.

8. Happy-eyeballs-like winner cache for multi-address hosts
   - Effect: only for hosts with a dead first address (15 s per new connection in hyper). Rare. [V MDM, U Rays]
   - Risk: low. Effort: M. A/B: unroutable first address in a test resolver (their `tests/dns.rs` approach). Probably skip unless seen in practice.

Skipped by design: HTTP/2 (MDM is http1_only; per-connection servers), debrid/CnL/FTP, browser-like TLS impersonation, torrent.

## Appendix: UI progress model and browser capture (glance)

- Progress is pull, not push: `Download::snapshot()` (L1422) returns a cloned `Snapshot` (state, size, downloaded, segment table, per-connection views, event log last 50) under a mutex; the egui app reads it each frame (`crates/app/src/model.rs` L829, L1322) and repaints on request (`request_repaint`). An engine-side `Event` log (`seq`, `text`) is a ring of 50. [V]
- Browser capture: MV3/Firefox extension (`extension/background.js`) uses `downloads.onCreated` (L2658) and native messaging (`runtime.sendNativeMessage` / `connectNative`) to `crates/nmhost`, which applies the shared capture rules (`crates/ipc/src/capture.rs`, read from the app's saved settings at every hand-off) and answers "not taken" so the browser downloads it itself. IPC to the running app is a token-protected local socket (`crates/ipc`). [V]
- Rays already has `events.rs`; no change implied.
