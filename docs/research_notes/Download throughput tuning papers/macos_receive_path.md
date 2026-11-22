# macOS client receive path and user-space receive/write costs (Rays: tokio + reqwest/hyper + native-tls)

Tags: [V] = verified from a fetched/seen source, [U] = unverified / inference / from search snippet only.

## 1. TCP receive buffers, autotuning, L4S/ECN, congestion control

### Takeaway
Recent macOS autotunes receive window up to a 4 MB cap by default [V]; at 10 Gbps this limits one stream to roughly 4MB/RTT (e.g. 32 Mbit / 10 ms = ~3.2 Gbps per stream at 10 ms RTT) so multiple streams or a raised cap matter. L4S on macOS covers URLSession HTTP/2/TCP downloads and QUIC only, not BSD sockets/hyper; it is a latency feature, not a throughput feature.

### Cited Findings
- [V] ESnet (Jan 2025): macOS defaults net.inet.tcp.win_scale_factor=3, autorcvbufmax=4MB, autosndbufmax=4MB; suggests 8 / 33554432 (32MB) / 33554432 for >=1 Gbps hosts, not Wi-Fi laptops; values vary by version; SIP means /etc/sysctl.conf may be ignored post-Ventura (use LaunchDaemon plist). Self-tuning TCP since 10.5. — [fasterdata](https://fasterdata.es.net/host-tuning/osx/)
- [U] Old defaults: net.inet.tcp.recvspace 32768 (2003 list post); kern.ipc.maxsockbuf reported 4194304 (2012) or 8388608 (older SO answer), limited to a fraction of mbuf pool. No source found for macOS 14-26 recvspace/maxsockbuf values. — [Apple list 2003](https://lists.apple.com/archives/macnetworkprog/2005/Sep/msg00092.html), [Apple list 2012](https://lists.apple.com/archives/darwin-kernel/2012/Apr/msg00043.html)
- [V] Setting SO_RCVBUF explicitly via setsockopt overrides autotuning (disables it) for that socket in BSD; Apple list says recvspace values are defaults changeable via setsockopt — [Apple list](https://lists.apple.com/archives/macnetworkprog/2005/Sep/msg00092.html). The "disables autotuning" part is [U] (BSD behavior, not confirmed on Darwin here).
- [V] WWDC23 10004 "Reduce network delays with L4S": iOS 17/macOS Sonoma; HTTP/3/QUIC via URLSession or Network.framework gets L4S automatically; HTTP/2 or TCP via URLSession gets built-in L4S for downloads only; rollout to random subset of users; enable manually with `sudo defaults write -g network_enable_l4s -bool true`; custom protocols/sockets must implement scalable CC + ECN validation themselves; server must support L4S too (Linux guide) else legacy fallback. Demo (20 ms min RTT, constrained link): worst-case RTT 45 ms -> <25 ms, loss >40% -> ~0. No throughput-gain claim. — [WWDC23 10004](https://developer.apple.com/videos/play/wwdc2023/10004/)
- [V] macOS adopted CUBIC with OS X Yosemite (2014); xnu has CUBIC as default CC (use_newreno sysctl exists); RFC 9438 lists Apple among CUBIC-default stacks. — [Wikipedia](https://en.wikipedia.org/wiki/CUBIC_TCP), [xnu tcp_cc.c](https://opensource.apple.com/source/xnu/xnu-7195.81.3/bsd/netinet/tcp_cc.c.auto.html), [RFC 9438](https://datatracker.ietf.org/doc/html/rfc9438)
- [U] Wide rollout status of L4S in macOS 15/26 not confirmed; TechSpot community post claims beta in iOS 16/Sonoma (conflicts with Apple's iOS 17). — [TechSpot](https://www.techspot.com/community/topics/a-new-internet-standard-called-l4s-aims-to-lower-latency-bring-more-speed-to-the-web.283496/)

### Inferences
- Per-stream ceiling = window/RTT; with 4 MB cap and 20 ms RTT one stream tops ~1.6 Gbps, so N>=8 parallel streams reach 10 Gbps at 20 ms before CPU limits. Many-stream design already mitigates cap; users cannot be asked to sysctl, but Rays can setsockopt(SO_RCVBUF) per socket (bounded by kern.ipc.maxsockbuf) [U whether this beats autotune].
- L4S irrelevant to hyper/BSD-socket path; only helps if Rays used URLSession/nw_connection with HTTP/2+server L4S support. Expect benefit in bufferbloat/latency, not raw Gbps.

### Gaps
- Exact macOS 14-26 defaults for recvspace, maxsockbuf, delayed_ack (no source found; recommend `sysctl net.inet.tcp kern.ipc.maxsockbuf` dump on test Mac and log it in Rays diagnostics).
- Whether setting SO_RCVBUF on Darwin disables autotune: not verified.

Rays could: (a) in the connector (hyper-util/reqwest custom connector, or socket2) call `socket.set_recv_buffer_size(4<<20)` (or 8 MiB) on each TcpStream before connect and A/B against autotune at known RTT; (b) log `sysctl net.inet.tcp.autorcvbufmax` and `kern.ipc.maxsockbuf` at startup into the benchmark report; (c) document an optional "10G tuning" note (autorcvbufmax=33554432 via LaunchDaemon) rather than automating it.

## 2. Network.framework / URLSession vs BSD sockets from Rust

### Takeaway
Apple positions Network.framework as the user-space stack that URLSession sits on, with optimized data paths, but I found no published TCP/TLS bulk-download throughput numbers vs BSD sockets, and one Apple forum report shows regressions. A Rust app gains little without a custom FFI layer; not recommended before measuring.

### Cited Findings
- [V] WWDC18 715 "Introducing Network.framework": gives direct access to the same user-space networking stack URLSession uses; URLSession handles HTTP and offloads transport to Network.framework; Apple claims optimized path can outperform sockets (example UDP real-time apps). — [WWDC18 715](https://developer.apple.com/videos/play/wwdc2018/715/)
- [V] WWDC20 10111 "Boost performance and security with modern networking": URLSession/Network.framework get IPv6, HTTP/2, TLS 1.3 etc. on the client side automatically; framed as performance/power wins. — [WWDC20 10111](https://developer.apple.com/wwdc20/10111)
- [V] Apple Developer Forums thread 805044: developer reports large throughput drop on Network.framework vs comparison for a web server; Apple engineer suspected user-space stack, asked for bug report. Also a (separate, unisolated) report of slow downloads on Sequoia/Tahoe over built-in ethernet. — [thread 805044](https://developer.apple.com/forums/thread/805044)
- [V] Secure Transport is deprecated since macOS 10.15/iOS 13 era; curl maintainer calls Network.framework its successor. — [Daniel Stenberg blog tag](https://daniel.haxx.se/blog/tag/securetransport/)
- [U] No benchmark found of URLSession vs raw sockets vs hyper for multi-Gbps downloads.

### Inferences
- nw_connection from Rust needs objc2/block2 or C FFI with dispatch queues and callback-per-receive (completion handlers delivering `dispatch_data`), adding copies/hops; unlikely to beat a tuned kqueue loop on a multi-stream bulk download. Value would be TLS offload to Apple's stack (hardware AES, system trust) and L4S/QUIC, not raw speed.

### Gaps
- Measured numbers for Network.framework TCP+TLS bulk receive. Needs a spike.

Rays could: keep hyper/BSD sockets; if a Network.framework path is ever wanted, build a spike behind a cargo feature (`nw_connection_receive` with min=64 KiB/max=1 MiB) in a separate bench binary and compare MB/s and CPU% against the current path on the same 10G link before any integration.

## 3. TLS cost: Security.framework (native-tls) vs rustls

### Takeaway
No public per-core numbers for Secure Transport SSLRead on Apple Silicon. rustls with aws-lc-rs is at rough parity with OpenSSL on AES-GCM and claims thousands of MB/s per core, far above 10 Gbps (1.25 GB/s) per core, so TLS decryption is unlikely the bottleneck on M-series if records are large and hardware AES is used; the risk is native-tls overhead per SSLRead call (16 KB records, one call each).

### Cited Findings
- [V] rustls (aws-lc-rs) vs OpenSSL bulk: send ~parity on AES suites; receive 7-17% lower in older rustls due to API forcing an extra copy (memorysafety). — [memorysafety rustls-performance](https://www.memorysafety.org/blog/rustls-performance/)
- [V] Q1 2026 update: rustls 0.23.37 + aws-lc-rs 1.16.0 vs OpenSSL 3.6.1, rustls first in 14 of 16 placement tests (hardware not stated; bulk numbers only in chart). — [Q1 2026 update](https://www.memorysafety.org/blog/26q1-rustls-performance/)
- [U] InfoQ (Sept 2026) reports 7,333 MB/s received per core rustls vs 6,238 OpenSSL, no methodology; LWN commenter says it mostly measures aws-lc. — [InfoQ](https://www.infoq.com/news/2026/09/rustls-one-decade/), [LWN](https://lwn.net/Articles/1093391/)
- [V] Older bench (rustls 0.22 + aws-lc vs OpenSSL 3.2.0): AES-128-GCM send 1.03x, receive 0.83x; x86 results attribute OpenSSL edge to AVX-512/VAES. Not Apple Silicon. — [rustls-bench-results](https://github.hscsec.cn/aochagavia/rustls-bench-results)
- [V] Benchmark tool for own hardware: [BENCHMARKING.md](https://github.com/rustls/rustls/blob/main/BENCHMARKING.md)
- [U] ARMv8 crypto extensions (AES/PMULL) accelerate AES-GCM in aws-lc/ring on Apple Silicon; no source fetched. TLS record max is 16 KiB (RFC 8446), so ~16 KB reads are record-bound; server controls record size.
- [V] Apple confirms no published SSLRead-vs-OpenSSL throughput; none found. Rust forum thread on tokio-native-tls flush behaviour OpenSSL vs Secure Transport exists. — [users.rust-lang.org](https://users.rust-lang.org/t/need-help-understanding-flush-behavior-in-tokio-native-tls-openssl-vs-secure-transport/133844)

### Inferences
- 10 Gbps = 1.25 GB/s; even native-tls at 1-2 GB/s per core would suffice across 2 workers only if per-call overhead is low. With 16 KB records at 1.25 GB/s that is ~76k reads/s; each costing a syscall + SSLRead callback + tokio wake. Syscall/wakeup overhead more likely limit than AES.
- reqwest `rustls-tls` feature (aws-lc-rs or ring provider) removes Secure Transport; trade-off: system trust store via `rustls-tls-native-roots` / rustls-platform-verifier.

### Gaps
- Apple Silicon-specific per-core TLS numbers for any library; recommend measuring in-repo (single stream, in-memory TLS server, `perf`-style Instruments Time Profiler).

Rays could: add cargo feature `tls-rustls` -> reqwest `default-features=false, features=["rustls-tls-native-roots"]` (or rustls-platform-verifier), run the existing throughput benchmark with each backend on localhost TLS server over loopback to isolate CPU cost, then choose the default.

## 4. User-space costs: tokio::fs, write batching, hyper buffers, zero-copy, F_NOCACHE, kqueue

### Takeaway
Every tokio::fs write is a spawn_blocking round trip; Tokio docs explicitly recommend batching into few spawn_blocking calls. Rays' per-16KB write_all + flush = 2 hops per chunk (~76k chunks/s at 10 Gbps) is the likeliest user-space bottleneck. Fix: accumulate 256 KiB-4 MiB per stream and issue one std pwrite in one spawn_blocking (or a dedicated writer thread via channel).

### Cited Findings
- [V] Tokio docs: tokio fs uses spawn_blocking on all platforms (io_uring only on Linux with tokio_unstable); "recommended to batch your operations into as few spawn_blocking calls as possible"; use BufWriter; writes return before completion, flush waits; max_buf_size controls max bytes per spawn_blocking call, default 2 MiB (subject to change). — [tokio::fs docs](https://docs.rs/tokio/latest/tokio/fs/index.html)
- [V] With BufWriter the actual write + spawn_blocking happens on flush — same docs. Note: flush after every chunk defeats BufWriter and forces a hop each time.
- [U] No measured per-hop overhead numbers found (searches: tokio fs spawn_blocking overhead). Typical cost claimed on forums is a few to tens of microseconds per hop (thread wake + channel), not sourced. — see [tokio::io::copy slower than std](https://users.rust-lang.org/t/tokio-copy-slower-than-std-io-copy/111242)
- [V] hyper HTTP/1: default adaptive read buffer; max_buf_size min 8192 (panics below), default ~400 KB; read_buf_exact_size and max_buf_size are mutually exclusive (setting one unsets the other); buffer grows up to max when transport keeps filling it. — [hyper io.rs 1.6.0](https://docs.rs/crate/hyper/1.6.0/source/src/proto/h1/io.rs), [hyper issue 1708](https://github.com/hyperium/hyper/issues/1708)
- [V] Apple file-system performance docs: one large read/write is usually more efficient than many small; kernel clusters I/O transparently so bypassing cache may not help sequential. F_NOCACHE just disables page-cache retention for the fd and does not purge cached pages. No benchmark found of F_NOCACHE for APFS sequential writes. — [Apple Performance Tips](https://developer.apple.com/library/ios/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/PerformanceTips/PerformanceTips.html), [ronomon/direct-io](https://github.com/ronomon/direct-io)
- [V] Apple forum: file copy faster with larger block size (filecopy block size discussion). — [thread 743561](https://developer.apple.com/forums/thread/743561)
- [U] No io_uring on macOS; sendfile is send-only; no splice. Receive path to file must copy socket -> user buffer -> file (kernel copy_to_user + write). kqueue already used by mio under tokio; batching limited to kevent returning many events per call (mio default events capacity 1024 in tokio's driver is [U]).

### Inferences
- Back-of-envelope: 16 KB chunks at 1.25 GB/s = ~76k chunks/s; two hops each = ~150k thread handoffs/s across the 2 worker + blocking pool; this plausibly burns 1+ cores and adds latency, causing socket buffers to fill and window to shrink. Batching to 1 MiB reduces to ~1.2k hops/s (64x fewer).
- F_NOCACHE: could cut page cache memory pressure and double-copy for multi-GB downloads but may reduce throughput if writes unaligned/small; only test with big aligned (4 KiB multiple, ideally 1 MiB) writes. Treat as experiment, [U].
- Setting hyper `http1_max_buf_size`/reqwest has no direct knob in reqwest; need hyper-util client builder; hyper's body frames come per TLS record (16 KB) regardless, so read size mostly limited by TLS record, so larger hyper buffer helps only the TCP->TLS read side (fewer syscalls).

### Gaps
- Measured spawn_blocking round-trip ns/us on Apple Silicon; do it with a 20-line criterion bench.
- Whether APFS prefers 128 KiB / 1 MiB write sizes: no authoritative source; test.

Rays could: (1) replace per-chunk `file.write_all(chunk).await; file.flush().await` with a per-stream `BytesMut`/`Vec` accumulator (target 1 MiB, flush at 256 KiB min or end-of-range) and write via `std::fs::File` + `FileExt::write_all_at(buf, offset)` inside one `spawn_blocking` (std files need no flush); (2) or send full buffers over a bounded mpsc to a few dedicated OS writer threads to remove spawn_blocking from the hot path and cap in-flight memory (backpressure); (3) drop per-chunk `flush()` entirely; (4) cap in-flight buffer memory = streams x 4 MiB; (5) benchmark F_NOCACHE (`libc::fcntl(fd, F_NOCACHE, 1)`) behind a flag at 1 MiB writes.

## 5. Tokio worker threads and build profile

### Takeaway
No rigorous source shows an optimal worker count for network-heavy tokio; with default = cores, 2 workers is likely fine if the file I/O is off the runtime, but CPU-bound TLS decrypt of 10 Gbps spread over 2 workers may saturate them. Measure with 2/4/N.

### Cited Findings
- [V] Tokio default worker_threads = number of cores; `Builder::worker_threads` / TOKIO_WORKER_THREADS configurable; current_thread vs multi_thread gap often in the noise for real work; one user saw multi-thread lower latency (<100 ms vs <130 ms) for 1,000 tonic connections; another saw worker count 2/10/16 give no throughput change in an Axum case. — [tokio discussion 7091](https://github.com/tokio-rs/tokio/discussions/7091), [users.rust-lang.org 106125](https://users.rust-lang.org/t/choosing-rt-multi-thread-versus-rt-option-in-tokio/106125), [rustio case study](https://www.github.com/pratikgajjar/rustio), [Tokio perf guidance](https://www.mintlify.com/tokio-rs/tokio/advanced/performance)
- [U] Blocking pool size (max_blocking_threads default 512) is separate from worker_threads; spawn_blocking writes run there, not on the 2 workers.
- [U] opt-level "s" vs 3 for crypto/memcpy-heavy code: no source; aws-lc / ring crypto uses hand-written asm and is unaffected, but hyper/h2 parsing, framing and tokio code may be 5-20% slower with "s" (unsourced estimate).

### Inferences
- With 2 workers, each handling ~half of 1.25 GB/s of TLS decrypt + hyper parse + copy: ~625 MB/s per worker, feasible for rustls/aws-lc (thousands MB/s per core) but borderline for per-call-heavy native-tls.
- Fix write hops first, then sweep workers.

### Gaps
- Empirical optimum for Rays; no published macOS-specific data.

Rays could: make worker count configurable (`Builder::new_multi_thread().worker_threads(n)`, default min(cores, 4)); set `[profile.release] opt-level = 3` (or a `[profile.bench]`/`release-fast`) for the engine crate (`[profile.release.package.dl-engine] opt-level = 3`) and compare; add `lto = "thin"`, `codegen-units = 1` experiments; run sweeps n in {2,4,8} x write batch {16 KiB, 256 KiB, 1 MiB, 4 MiB} on a 10G link, recording MB/s and per-thread CPU via Instruments/`top -H`.

## Priority order (by expected payoff, mostly [U] ranking from inference)
1. Batch writes (section 4), drop per-chunk flush.
2. A/B rustls vs native-tls (section 3).
3. Worker count and opt-level (section 5).
4. SO_RCVBUF experiment / per-stream window math (section 1).
5. F_NOCACHE, Network.framework spike only if the above leaves a gap.
