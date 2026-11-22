# Segment/chunk scheduling and tail-latency avoidance for multi-connection downloads

Tags: [V] = read in a fetched source or search result this session; [U] = unverified / from memory / inference. Rays constants: MIN_SPLIT 4 MiB, MIN_SEGMENT 1 MiB, SPLIT_ALIGN 64 KiB, STALL 30 s.
Fetch limits: CACM, Google Research, HAL (Anubis), curl docs failed or lacked the target text; the Tail at Scale numbers are from secondary summaries. libtorrent/librqbit endgame source not read.

## 1. Speculative / redundant requests for tail latency (hedging)

### Takeaway
Hedging works when the duplicate is sent only after the primary passes a high-percentile delay (about p95), costing about 2-5% extra load for large tail cuts. Blind full replication only pays below roughly 25-50% server utilization. For a single-file download, duplicate bytes are the cost, so duplicate only the last few MiB of the slowest segment.

### Cited Findings
- [V] The Tail at Scale (Dean and Barroso, CACM 2013): hedged request = send the secondary only after the first has been outstanding longer than the p95 expected latency; limits extra load to about 5% while shortening the tail. Per a secondary summary, not the paper text — [Summary via search](https://blog.acolyer.org/2015/01/15/the-tail-at-scale/); paper PDF: [pdos.csail.mit.edu](https://pdos.csail.mit.edu/6.824/papers/tail-dean.pdf) (not fetched)
- [V] Same paper, BigTable benchmark: reading 1,000 keys across 100 servers, a hedge after 10 ms cut p99.9 from 1,800 ms to 74 ms for 2% more requests. Numbers via secondary summaries, original not read — [Acolyer summary](https://blog.acolyer.org/2015/01/15/the-tail-at-scale/)
- [U] The paper also describes "tied requests" (enqueue on two servers, each cancels the other when one starts); not verified here.
- [V] Vulimiri et al., "Low Latency via Redundancy" (CoNEXT 2013): replicating every operation lowers mean latency below a server-side load threshold; conjectured to lie between 25% and 50% utilization; about 25.82% for deterministic service, 33% for exponential, 30% in a disk-backed DB experiment — [ar5iv](https://ar5iv.labs.arxiv.org/html/1306.3707)
- [V] Same paper empirical: DNS to multiple servers cut queries over 500 ms by 6.5x and over 1.5 s by 50x; memcached got worse at all loads 10-90%; in-network replication gave a 38% median FCT improvement at 40% load, tail 10-20% — [ar5iv](https://ar5iv.labs.arxiv.org/html/1306.3707)
- [V] Cost-benefit: the fetched copy says break-even is 16 ms saved per KB of extra traffic (TCP handshake savings 170-6000 ms/KB, DNS about 23 ms/KB). CONFLICT: a search summary of the companion paper quotes 10 ms/KB — [ar5iv](https://ar5iv.labs.arxiv.org/html/1306.3707); [companion paper, 10 ms/KB per search summary](https://arxiv.org/pdf/1306.3534). The ar5iv page is the CoNEXT paper; verify which figure belongs to which.
- [V] MDTP (2025, arXiv) explicitly does NOT re-request in-flight chunks, so no bytes are downloaded twice, and contrasts itself with Rodriguez et al., who do — [MDTP](https://arxiv.org/html/2505.09597v1)
- [U] I found no download-specific study measuring hedged tail ranges against HTTP origins (CDN throttling per connection or per IP could make a duplicate range free or useless). The Rodriguez et al. paper (parallel access for mirror sites, SIGCOMM 2000) is cited by MDTP but I did not read it.

### Inferences
- Rays has a natural hedge trigger: a segment is "last" when no unassigned range remains and a connection is idle. Then a duplicate of the slowest segment's remaining tail costs at most that tail in wasted bytes, and the first finisher cancels the other.
- Waste is bounded: duplicate at most MIN_SPLIT (4 MiB) of remaining bytes per slow segment, or the remaining bytes below MIN_SPLIT that can no longer be split.
- The p95 rule translates to: hedge only when a segment's projected finish time exceeds about 1.5-2x the median segment finish projection (a tunable, not a sourced number).
- Origins that cap per-IP bandwidth make duplicates cost real throughput; disable hedging when aggregate speed is flat as connections increase.

### Gaps
- Original Tail at Scale text (CACM 403, Google Research page returned only the abstract).
- Real-world numbers for tail hedging in file downloads.

Rays could: when MIN_SPLIT blocks further splitting (remaining < 2x MIN_SPLIT, or < 4 MiB), hedge the remaining bytes with a second range request aligned to SPLIT_ALIGN, cancel the loser, and cap duplicates to bytes <= MIN_SPLIT per segment; trigger only after the segment is past a p95-like delay rather than at STALL (30 s is far too late as a hedge trigger).

## 2. BitTorrent endgame mode

### Takeaway
Endgame = when every block is requested or received, send duplicate requests for the remaining blocks to other peers and cancel the losers when one copy arrives. It is a hedge limited to the final blocks. I did not obtain measured effect sizes; the Legout paper's abstract does not address it.

### Cited Findings
- [V] libtorrent author: end-game starts once every piece has been picked or completed; each peer ready for requests asks for one block another peer already has pending — [writing a fast piece picker](https://blog.libtorrent.org/2011/11/writing-a-fast-piece-picker/)
- [V] libtorrent request timeouts: one generic timer reset on any block arrival; on timeout release the most recently requested block (least likely already sent, most likely to honor a cancel). If the piece has no unrequested blocks left, cancel the block from that peer so another can request it; otherwise postpone by one block's time. Always clearing causes redundant downloads, never clearing lets slow peers stall pieces — [block request time-outs](https://blog.libtorrent.org/2011/11/block-request-time-outs/)
- [V] The same post describes "strict" end-game (only when about to complete) and says in source-limited swarms waiting for it holds a client back, so releasing timed-out blocks earlier helps — [same](https://blog.libtorrent.org/2011/11/block-request-time-outs/)
- [V] libtorrent stats counters exist for end-game waste: `ses.waste_piece_end_game` (wasted bytes by reason), `peer.num_peers_end_game`, `picker.end_game_piece_picks` — [libtorrent manual-ref](https://www.libtorrent.org/manual-ref.html)
- [V] Third-party Rust port notes that in end-game or after timeout re-requests the same block can arrive from several peers, so duplicates must be skipped on write and the tracker must drop the block on arrival — [irontide-engine, not libtorrent](https://docs.rs/crate/irontide-engine/1.2.1/source/src/torrent_verify.rs)
- [V] librqbit v5.4.1 release note: "optimize endgame so peers steal pieces less frequently from each other" (shows rqbit has endgame stealing and that over-stealing was a problem). Mechanism not read — [release listing](https://newreleases.io/project/github/ikatson/rqbit/release/v5.4.1)
- [V] Legout et al. (IMC 2006) abstract: rarest first gives near-ideal piece diversity; choke is fair and robust to free riders. It says nothing on endgame in the abstract; paper claims about the last-pieces problem unverified — [arXiv cs/0609026](https://arxiv.org/abs/cs/0609026)
- [V] Bharambe, Herley, Padmanabhan, "Understanding and Deconstructing BitTorrent Performance" (MSR-TR-2005-03) exists and is simulation-based; endgame findings not retrieved — [MSR](https://www.microsoft.com/en-us/research/publication/understanding-and-deconstructing-bittorrent-performance/)
- [V] Transmission peer-mgr.c and rqbit source were surfaced but not read — [Transmission peer-mgr.c](https://bazaar.launchpad.net/~ubuntu-branches/ubuntu/maverick/transmission/maverick-updates/revision/43/libtransmission/peer-mgr.c)

### Inferences
- The mapping to HTTP: blocks = byte ranges of the last segments; peers = connections (or mirrors). Endgame there is the same hedge as section 1, with the same "cancel the loser" requirement. HTTP cancel = close the connection (loses TLS/H2 state) or RST_STREAM on H2.
- The libtorrent "release the most recently requested block" rule suggests which end of a slow segment to hand out: the tail (highest offset) of the slow segment, which is what Rays' split already takes.

### Gaps
- Measured endgame benefit (percent of download time saved, bandwidth wasted); not found.
- librqbit endgame source (ikatson/rqbit) not read.

Rays could: add an endgame flag when no unassigned bytes remain; let idle connections take duplicate ranges of the largest unfinished segment's tail down to MIN_SEGMENT granularity, aligned to SPLIT_ALIGN; stop worrying about STALL for this case since endgame covers slow-but-alive connections.

## 3. Work stealing vs fixed chunking vs adaptive chunk size; min split vs BDP

### Takeaway
Fixed equal chunks suffer stragglers; work stealing (Rays today, aria2) fixes it at the cost of per-request overhead; throughput-proportional chunk sizing (MDTP) beat aria2 by 10-22% in one recent testbed study. No paper found analyzing min split size against bandwidth-delay product.

### Cited Findings
- [V] aria2 defaults: `--min-split-size` 20M ("aria2 does not split less than 2*SIZE byte range"), `--split` 5, `--max-connection-per-server` 1, `--piece-length` 1M, `--timeout` 60, `--lowest-speed-limit` 0, `--max-tries` 5, `--stream-piece-selector` default ("selects piece so that it reduces the number of establishing connection"), `--uri-selector` feedback — [aria2 manual](https://aria2.github.io/manual/en/html/aria2c.html)
- [V] aria2 source: the code also checks `requestGroup_->getPendingLength() < calculateMinSplitSize() * 2` before assigning new work (exact effect not confirmed); segments obtained via `sm->getSegment(cuid, minSplitSize)`; on retry `cancelSegment(cuid)` returns the segment to the pool — [AbstractCommand.cc](https://raw.githubusercontent.com/aria2/aria2/master/src/AbstractCommand.cc)
- [V] aria2 slow-mirror handling: at most every 10 s, `findFasterRequest` among pooled mirrors; if found, swap the request. Skipped when a max speed limit is set or total length unknown — [AbstractCommand.cc](https://raw.githubusercontent.com/aria2/aria2/master/src/AbstractCommand.cc)
- [V] MDTP: probe each replica with an initial uniform chunk C; round length T = C / throughput of the fastest; each server's chunk C_i = T x throughput_i; recompute every round; each chunk requested once — [arXiv 2505.09597](https://arxiv.org/html/2505.09597v1)
- [V] MDTP vs aria2 (6 FABRIC servers, 64 GB, disk writes included): 445.9 s vs 516.6 s (13.69% faster; 10-22% across sizes); aria2 used 5 of 6 replicas and overloaded the fastest. With the fastest capped to 500 Mbps aria2 slowed 74 s / 121 s vs MDTP 42 s / 48 s. Static chunking +6.24 s when 0.5 s latency added to the fastest. Prototype in Python; multi-server, large files, so not directly a single-origin result — [arXiv 2505.09597](https://arxiv.org/html/2505.09597v1)
- [V] MDTP chunk sizes picked empirically: 1-8 GB files initial 4 MB / large 40 MB; 16-64 GB initial 16 MB / large 160 MB — [arXiv 2505.09597](https://arxiv.org/html/2505.09597v1)
- [V] mHTTP proposal reports per-chunk overhead larger at small chunk sizes, about 5-10% at 1024 KB chunks on one connection (via search snippet, not read in full) — [arXiv 1310.2748](https://arxiv.org/pdf/1310.2748)
- [V] Simula multilink progressive download work: fixed segmentation adds a per-range-request cost, worst with many small segments (snippet only) — [Simula pub](https://web-backend.simula.no/sites/default/files/publications/Simula.simula.178.pdf)
- [U] IDM's dynamic segmentation (splits the largest remaining piece when a connection frees, similar to Rays) is closed source; no citable analysis found.

### Inferences
- BDP arithmetic (unsourced): per-connection TCP window needed = rate x RTT. 1 Gbps x 50 ms = 6.25 MB; 100 Mbps x 50 ms = 625 KB. A segment smaller than a few BDPs spends its life in slow start and request round trip, so min split should be at least a few BDP of per-connection rate (not aggregate). Rays' 4 MiB min split is about 1 BDP at 700 Mbps/50 ms, but a per-connection share is typically a fraction of that, so 4 MiB is roughly 10+ BDPs per connection at 100 Mbps aggregate over 8 connections. Reasonable.
- aria2's 20M min split is conservative (only 2x20M can be split); Rays' 4 MiB is more aggressive and gives finer tails. The extra request cost is one RTT plus possible slow start per split.
- MDTP style sizing could be approximated in Rays by giving a faster connection a larger initial segment share, since splitting the largest segment already shifts work toward faster connections.

### Gaps
- No paper found relating minimum split size to BDP.
- No measurements of Rays-style "split the largest" vs alternatives on single-origin downloads.

Rays could: keep MIN_SPLIT at 4 MiB but scale it by measured per-connection throughput x RTT (e.g. max(MIN_SPLIT, k x BDP_conn), k about 4) so high-latency links do not over-split; keep MIN_SEGMENT 1 MiB as the floor for hedges; keep SPLIT_ALIGN 64 KiB (no source suggests changing it; alignment matters for disk/page writes, not tail latency).

## 4. Slow-connection detection and replacement

### Takeaway
aria2 itself kills only on total inactivity (timeout, default 60 s) and via a periodic faster-mirror swap; the speed-limit option defaults off. No benefit measurements found for relative-speed thresholds. Rays' 30 s stall is detection of dead, not slow, connections.

### Cited Findings
- [V] aria2 `--lowest-speed-limit`: "Close connection if download speed is lower than or equal to this value (bytes per sec)", default 0 (off) — [aria2 manual](https://aria2.github.io/manual/en/html/aria2c.html)
- [V] aria2 source: connection treated stalled when `checkPoint_.difference(wallclock) >= timeout_` (no byte-rate check in that code path), then marks server errored and throws `DL_RETRY_EX2(EX_TIME_OUT)`. Speed-based kill logic was not in this file (likely elsewhere, e.g. low speed check in the download command; not read) — [AbstractCommand.cc](https://raw.githubusercontent.com/aria2/aria2/master/src/AbstractCommand.cc)
- [V] aria2 checks for a faster mirror every 10 s via `findFasterRequest` — [AbstractCommand.cc](https://raw.githubusercontent.com/aria2/aria2/master/src/AbstractCommand.cc)
- [V] libtorrent: generic timer reset by any block arrival; release the most recent block on expiry, cancel if another peer can serve it — [block request time-outs](https://blog.libtorrent.org/2011/11/block-request-time-outs/)
- [U] curl `--speed-limit/--speed-time` (abort when below N B/s for T s) is the classic low-speed kill; the curl doc page fetched did not cover it, so semantics unverified here.
- [V] MDTP's per-round throughput measurement implicitly demotes slow replicas by giving them smaller chunks instead of killing them — [arXiv 2505.09597](https://arxiv.org/html/2505.09597v1)

### Inferences
- A relative rule is cheap in Rays: compute median per-connection speed over a window (e.g. 5-10 s); a connection below about 20-25% of the median for a window, with at least MIN_SEGMENT remaining and an idle or soon-idle peer, gets its segment's tail duplicated (hedge) rather than killed. Kill only if the duplicate wins. The thresholds are not sourced.
- Killing and reconnecting resets TCP slow start and may re-hit a throttled path, so prefer hedging to killing unless the stream is near zero throughput.
- Avoid the aria2 behavior of skipping swaps when a speed cap is set: below-median detection is meaningless under a user speed limit.

### Gaps
- No measured benefit of relative-speed kill/reconnect found.
- aria2 lowest-speed-limit implementation location not read.

Rays could: add a rolling-speed monitor alongside STALL (30 s of no bytes) so that a connection under about a quarter of the median for around 10 s triggers hedge of its remaining tail (never smaller than MIN_SEGMENT, aligned to SPLIT_ALIGN), and only fall back to STALL-based drop when bytes stop entirely; shorten STALL to roughly 10-15 s when other connections are healthy.

## 5. Chunk ordering for streaming/preview

### Takeaway
Not covered by sources found; short inference only.

### Cited Findings
- [V] libtorrent has a streaming mode documented separately (sequential piece picking with deadlines) — [libtorrent streaming](https://libtorrent.org/streaming.html) (title only in search results, contents not read)
- [V] aria2 `--stream-piece-selector` default prefers fewer connection setups; other values exist (geom, inorder, random) per manual, values not re-quoted here — [aria2 manual](https://aria2.github.io/manual/en/html/aria2c.html)

### Inferences
- Sequential split order (lowest offset first) yields a usable prefix early at no throughput cost for range-capable servers; the tail hedge still applies at the end. For preview, prioritize the first few segments and the file trailer (e.g. zip/mp4 index) only if the format needs it.

### Gaps
- No numbers or papers retrieved on sequential vs parallel ordering cost.

Rays could: when preview/streaming is requested, hand out MIN_SEGMENT-sized lowest-offset ranges first (aligned to SPLIT_ALIGN) and keep the largest-segment split for the rest, without changing MIN_SPLIT.
