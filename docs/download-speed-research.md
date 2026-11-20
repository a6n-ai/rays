# Download speed research for Rays

Web research only (no local code read). Date: 2026-11-20. Tags: [V] = verified against a fetched/search-returned source, [U] = unverified / from general knowledge, check before relying on it.

## 1. How other tools pick connections, segments, re-splitting

| Tool | Defaults | Notes |
|---|---|---|
| aria2 | `-x` 1 per server, `-s` 5, `-k` min-split-size 20M (range 1M-1024M), `--piece-length` 1M, `--max-tries` 5, `--retry-wait` 0 (retry on 503 only if >0), `--disk-cache` 16M, `--file-allocation` prealloc, `--lowest-speed-limit` 0, `--stream-piece-selector` default, `--uri-selector` feedback, `-j` 5 [V] | Will not split a range smaller than 2 x `-k`. Server cap `-x` bounds `-s`. Mirrors: `feedback` selector prefers fastest observed server. Many wrappers raise to x16/s16/k1M (a Motrix aria2.conf copy shows min-split-size=1M; its split/-x values not found) [V partial]. |
| IDM | Default 8 connections, user-raisable to 32 [V, vendor + secondary] | Dynamic segmentation: when a connection frees up, find the largest remaining segment and halve it. Finished connections are reused without reconnect/login. Will not split a segment too small for the connection type. Saves file positions several times a minute for resume. [V] |
| axel | Default `-n` not confirmed from man pages (I recall 4) [U] | `-s` is max speed, `-S` mirror search count. |
| wget2 | `--max-threads` 5; `--chunk-size` off by default (e.g. 1M to enable multi-thread chunking); `--http2-request-window` 30 streams per H2 connection (third-party man mirror); Metalink supported [V, partly secondary] | Design leans on HTTP/2 multiplexing, fewer TCP connections. |
| curl | `--parallel-max` 50 (max 65535); `--parallel` prefers multiplexing on an existing connection; `--parallel-immediate` opens new connections instead of waiting to multiplex; `--parallel-max-host` caps connections per host [V] | curl has no built-in single-file range splitting; users script `-r`. |
| Free Download Manager | Not found [U] | Check FDM settings UI. |
| Firefox (reference) | `network.http.max-persistent-connections-per-server` 6 [V] | Browser norm for H1. |

Why: small per-segment overhead (handshake, slow-start) vs. server/IP limits. aria2's conservative `-x 1` default signals server-friendliness; IDM/wrappers push 8-16+ for speed. Re-split by halving the largest remaining segment (IDM) is the same idea as work stealing.

Rays could: keep 16 max but gate growth on measured marginal gain (stop adding connections when aggregate speed stops rising); refuse to split below ~2 x min-segment (aria2 rule, e.g. 2 x 1-4 MiB); steal by halving the largest remaining range; reuse the finished connection for the stolen range with no reconnect; add `lowest-speed-limit`-style kill-and-reconnect for stalled connections.

Sources: https://aria2.github.io/manual/en/html/aria2c.html ; https://cn.internetdownloadmanager.com/support/segmentation.html ; https://github.com/rockdaboot/wget2/wiki ; https://everything.curl.dev/cmdline/urls/parallel ; https://daniel.haxx.se/blog/?p=27936 ; https://man.archlinux.org/man/axel.1.en

## 2. HTTP/2, HTTP/3 for bulk downloads

- HTTP/2 multiplexes streams over one TCP connection: no application-level HOL blocking, but TCP-level HOL remains: one lost packet stalls all streams. Under loss, N independent TCP connections can beat one multiplexed connection [V, secondary/blog + academic (Marx et al.)]. No controlled large-file H1-x-N vs H2 benchmark found.
- HTTP/2 flow control is separate from TCP. Default window is 65,535 bytes for stream and connection; if smaller than the bandwidth-delay product, throughput is capped. A curl issue reports a large download much slower over H2 with the 65k default [V]. Hyper: `SPEC_WINDOW_SIZE = 65_535`; setting an explicit stream window disables hyper's adaptive window [V]. Hyper's own non-spec defaults not confirmed [U].
- Implication: a ranges-over-one-H2-connection design needs big windows (reqwest `http2_adaptive_window(true)` or `http2_initial_stream_window_size`/`http2_initial_connection_window_size` in the MiB range) or it is slower than H1 x N. Many servers/CDNs also cap concurrent streams (often 100) and per-connection bandwidth behaviour is CDN-specific [U].
- HTTP/3: reqwest `http3` feature is unstable (needs `--cfg reqwest_unstable`), built on h3 + quinn; h3 crates were still 0.0.x at last packaging notes [V, older]. Current 2026 status not confirmed [U]. Research shows QUIC bulk transfer costs more CPU and can be up to ~45% slower than TCP+TLS+H2 on fast links (no UDP GRO in implementations); a curl maintainer notes big UDP socket buffers do not help userspace QUIC like they help kernel TCP [V, academic]. macOS-specific: `sendmsg_x/recvmsg_x` multi-message syscalls give ~11% on loopback; quinn-udp uses them [V, one talk].
- CDN-specific (Cloudflare, Akamai, GitHub releases): not verified [U]. S3 has no per-bucket connection limit and recommends many parallel connections with 8-16 MB ranges [V].

Rays could: stay on H1.1 x N for single-file downloads by default (robust to loss, no window tuning); optionally negotiate H2 with large windows (adaptive window on) and benchmark per host, falling back to multiple H2 connections instead of many streams on one; defer H3 (unstable, higher CPU) and make it opt-in.

Sources: https://publib.boulder.ibm.com/httpserv/cookbook/Applications-HTTP2_Standard.html ; https://curl.se/bug/?i=1102 ; https://speeder.edm.uhasselt.be/webist/files/h2bestpractices_RobinMarx_WEBIST2017.pdf ; https://docs.rs/crate/hyper/1.10.1/source/src/proto/h2/mod.rs ; https://github.com/hyperium/hyper/issues/1818 ; https://arxiv.org/html/2310.09423v2 ; https://docs.aws.amazon.com/whitepapers/latest/s3-optimizing-performance-best-practices/horizontal-scaling-and-request-parallelization-for-high-throughput.html

## 3. TCP-level tuning on macOS

- macOS has TCP receive-buffer auto-tuning (since 10.5); `net.inet.tcp.autorcvbufmax` caps it, ~4 MB default in recent versions (ESnet) [V, secondary]. Explicitly setting `SO_RCVBUF` disables auto-sizing (SB_AUTOSIZE) [V, secondary, from a Wasmtime issue]. So: do NOT set SO_RCVBUF unless benchmarks prove gain; the OS autotune is usually better. `kern.ipc.maxsockbuf` semantics not confirmed [U].
- `TCP_NODELAY`: irrelevant for bulk receive; harmless. Large read buffers (64-256 KiB per read) matter more than socket options [U].
- Congestion control: not user-selectable per socket on macOS (no TCP_CONGESTION). macOS uses CUBIC by default, with recent releases having L4S/ECN support [U]. BBR not available from userspace [U]. More parallel connections is the practical lever.
- Connection reuse: hyper/reqwest pool keeps idle connections; reuse finished connections for stolen ranges (saves TCP + TLS handshake RTTs and slow start) [general, U on exact reqwest pool defaults].
- DNS caching / Happy Eyeballs (RFC 8305): hyper-util's connector implements Happy Eyeballs for dual stack; resolve once per host and share across segments [U, not verified in this research]. TLS session resumption: rustls (reqwest default) caches tickets in-process per client; reuse one `Client` for all segments so extra connections do 1-RTT/resumed handshakes [U].

Rays could: one shared `reqwest::Client` per host with pool; leave SO_RCVBUF alone; resolve DNS once and pin addresses; connect_timeout short with fallback to the other IP family.

Sources: https://fasterdata.es.net/host-tuning/osx/ ; https://bytecodealliance.github.io/zulip-archive/stream/225357-git-wasmtime/topic/wasmtime.20.2F.20issue.20.2312561.20.5Bwasi-sockets.5D.20Inconsistency.20with.2E.2E.2E.html

## 4. Disk I/O on APFS for parallel segment writes

- Preallocation: `fcntl(F_PREALLOCATE)` with `fstore_t` (`F_ALLOCATEALL`, `F_PEOFPOSMODE`; `fst_length` = bytes of NEW allocation from physical EOF) then `ftruncate` to set logical size. APFS and HFS+ differ: APFS has returned EINVAL in some repeated-call cases [V, Apple filesystem-dev list; Bitcoin Core PR #17887].
- `ftruncate`-only sparse files on APFS: a report of mmap page faults taking ~23 s on first touch after ftruncate [V, Apple list, mmap case; pwrite path not measured]. aria2 warns `trunc` does not allocate space nor prevent fragmentation [V].
- `pwrite` at the segment offset from each task avoids seeks/locks on a shared cursor [general, U]. Batch into 256 KiB-4 MiB writes; aria2 uses a 16M disk cache by default [V].
- `fsync` on macOS only flushes to the drive; `F_FULLFSYNC` flushes the drive cache and is much slower (SQLite and jj report large slowdowns, jj ~5x on test suite) [V]. Use F_FULLFSYNC only at completion / resume-metadata checkpoints, not per segment.
- `F_NOCACHE` avoids polluting page cache for huge files; semantics not confirmed here, test it [U].
- APFS clone/COW write amplification specifics for sequentially filled files: not found [U].

Rays could: F_PREALLOCATE (tolerate EINVAL, fall back to ftruncate) once; `pwrite` per segment with 1-4 MiB coalesced buffers; persist resume state a few times per minute (IDM does); single F_FULLFSYNC at finish; consider F_NOCACHE for multi-GB files after measuring.

Sources: https://lists.apple.com/archives/filesystem-dev/2017/Dec/msg00000.html ; https://mirror.b10c.me/bitcoin-bitcoin/17887/ ; https://lists.apple.com/archives/filesystem-dev/2019/Dec/msg00000.html ; https://eclecticlight.co/2022/02/18/how-can-you-trust-a-disk-to-write-data/ ; https://mjtsai.com/blog/2022/02/17/apple-ssd-benchmarks-and-f_fullsync

## 5. Mirrors, server signals, etiquette

- Multi-source: aria2 takes multiple URIs per file and `--uri-selector feedback` favours the fastest; wget2 supports Metalink RFC 6249/5854 [V]. S3: align ranges to multipart-upload part boundaries or use `?partNumber=N`; 8-16 MB ranges; each GET is billed, so tiny ranges cost money [V].
- Probe: `HEAD` or `Range: bytes=0-0` -> check `Accept-Ranges: bytes`, `Content-Length`, ETag/Last-Modified; send `If-Range` on resume so a changed file restarts rather than corrupts [general, U].
- 429/503: honour `Retry-After` (seconds or HTTP date, RFC 9110 s10.2.3; RFC 6585 for 429); a client that must wait longer should not shorten it; use exponential backoff + jitter [V]. aria2 retries 503 only when `retry-wait` > 0 [V]. Some services cap simultaneous connections per IP at single digits [V, weak source].
- Etiquette: on 429/403/503 shrink connection count (halve) and apply per-host cooldown rather than only retrying; cap per-host connections (Rays already has per-host backoff). Specific CDN/GitHub per-IP limits: not verified [U].

Rays could: remember per-host max-safe connection count (learned from 429/503s) with slow re-probe; always parse Retry-After and apply it to the whole host, not one segment; use `If-Range` + ETag on resume; allow multiple URLs/Metalink per download with feedback-based mirror choice.

Sources: https://docs.aws.amazon.com/AmazonS3/latest/userguide/optimizing-performance-guidelines.html ; https://developer.mozilla.org/docs/Web/HTTP/Headers/Retry-After ; https://http.dev/429 ; https://github.com/rockdaboot/wget2/wiki

## 6. Measuring correctly

- speed.cloudflare.com/__down?bytes=N serves N bytes; Cloudflare's own speed test deliberately does not try to saturate the link (reports realistic throughput); `bytes=0` is used by a third-party CLI for latency [V]. Exact server behaviour (rate limits, caching) not confirmed [U].
- Method (general practice, U): fix URL and size (>=100 MB so ramp-up amortises); discard first run (cold DNS/TLS/CDN cache), then >=5 runs, report median + spread; interleave A/B rather than running all A then all B; record time-to-first-byte separately from steady-state throughput; test CDN-cached vs uncached object, and one slow-origin host; control for Wi-Fi vs wired and time of day; compare against a single-connection `curl -o /dev/null` and `aria2c -x16 -s16 -k1M` baseline on the same URL; write to `/dev/null` as well as to disk to isolate disk cost.
- Beware: S3/CDN edge may throttle per-connection (so more connections help) while others throttle per-IP (more connections hurt); results are host-specific.

Rays could: add a `bench` CLI mode that runs interleaved A/B (connection cap, segment size, H1 vs H2) against a URL list and prints median/p10/p90 plus bytes-in-flight and CPU; keep a fixed test set (Cloudflare `__down`, a GitHub release asset, an S3-hosted file, a throttled mirror).

Sources: https://blog.cloudflare.com/how-does-cloudflares-speed-test-really-work/ ; https://github.com/cloudflare/speedtest

## Top ideas (ranked)

1. Halve-largest-remaining-range work stealing with reuse of the freed connection (IDM); skip splitting below 2 x min segment (aria2).
2. Adaptive growth that stops when aggregate throughput plateaus; learn a per-host safe connection cap from 429/503/403.
3. Preallocate with F_PREALLOCATE (fallback ftruncate), pwrite coalesced 1-4 MiB, F_FULLFSYNC only at completion.
4. Prefer H1.1 x N; if H2, enable large/adaptive windows and benchmark; H3 opt-in only.
5. Build interleaved A/B benchmark mode with warm-up discard and median-of-N.
