# CDN/server throttling behaviour and multi-source concurrent downloading

Tags: [V] = verified from a fetched or searched source cited inline; [U] = unverified, inference, or community anecdote. Research was capped at about 20 tool calls. Several fetches failed (EURECOM PDFs were binary or 429, RFC 9110 text was truncated), so some items are abstract-level only. Gaps are listed explicitly.

## (a) Per-connection vs per-IP throttling at major hosts: when do more connections help?

### Takeaway
No major host publishes a per-connection rate cap. Documented limits are per-IP or per-account request and connection limits. Only AWS S3 explicitly recommends parallel range GETs for throughput. Evidence for GitHub, Cloudflare, Akamai, Fastly, Dropbox and SourceForge is missing or anecdotal. Mirror operators do cap connections per IP (typically 2 to 6), so 16 connections can trigger bans on volunteer mirrors.

### Cited Findings

#### AWS S3
- [V] AWS recommends concurrent requests for large objects, "by either requesting specific byte ranges of the object or downloading individual parts of a multipart object simultaneously", to "fully use your network interface card (NIC) capacity". It also says to "use multiple connections" to reduce the impact of any single connection issue. — [S3 performance design patterns](https://docs.aws.amazon.com/AmazonS3/latest/userguide/optimizing-performance-design-patterns.html)
- [V] Per-prefix scaling figures are 3,500 PUT/COPY/POST/DELETE and 11,000 GET/HEAD requests per second. During scaling S3 may return HTTP 503 (Slow Down), described as temporary. — same page
- [V] For multipart-uploaded objects, align download ranges to the original part boundaries. — same page
- [V] For large variably sized requests (over 128 MB), track throughput and retry the slowest 5 percent. For small requests (under 512 KB), retry after 2 seconds, then back off (2s, then 4s more). When retrying, use a new connection and a fresh DNS lookup. — same page
- [V] DNS for S3 cycles through many IPs. Callers that reuse one IP do not get address diversity or load balancing. Horizontal scaling "helps distribute the load over multiple paths through the network". — same page
- [U] The well-known "about 85-90 MB/s per connection" S3 figure did not appear in the fetched page text, so it is not confirmed here.

#### CloudFront
- [V] Limits found are account-level: a default of 150 Gbps peak throughput and 250,000 requests per second, and AWS may limit traffic under certain conditions. — [AWS large-scale streaming events article](https://aws.amazon.com/developer/application-security-performance/articles/large-scale-video-streaming-events) (as summarized in search results; page not fetched)
- [U] No per-connection cap found for CloudFront. A Fedora report of aria2c `-x16` on a 133 MiB CloudFront-hosted file shows about 1.5 MiB/s for the first 20 MiB, then about 100 KiB/s. The cause (per-client throttle, origin, or CDN) is not identified. — [Fedora Discussion thread](https://discussion.fedoraproject.org/t/rpm-ostree-upgrade-has-very-slow-download-speeds/122243)

#### GitHub releases (objects.githubusercontent.com / release-assets)
- [V] Search found no source documenting a per-connection or per-IP throttle on release assets, and none showing that multiple connections bypass one.
- [U] Anecdote: a user reported GitHub archive downloads of about 50 KB/s on Linux versus about 6 MB/s on Windows, cause unknown. — [EndeavourOS forum](https://forum.endeavouros.com/t/slow-download-speed-from-github/10190)
- [U] aria2 on a GitHub archive URL was redirected to codeload.github.com and averaged about 2.9 MiB/s. — [git mailing list thread](https://lore.kernel.org/git/YAtwuSoEE68TV4LN@camp.crustytoothpaste.net/)
- Note: release downloads go through a redirect to a signed URL. Range requests must follow the redirect, and each range connection should probably reuse the resolved signed URL rather than re-hit github.com. [U]

#### Hugging Face (Xet / CDN)
- [V] Xet downloads fetch xorb data with multi-range HTTP requests, one HTTP request per xorb, with multiple ranges for the same xorb combined into one URL. — [Xet download protocol](https://huggingface.co/docs/xet/download-protocol)
- [U] Community reports: `HF_XET_NUM_CONCURRENT_RANGE_GETS` defaults to 16 per file (renamed from `XET_NUM_CONCURRENT_RANGE_GETS`). Total GETs are bounded by `HF_XET_MAX_CONCURRENT_DOWNLOADS` times that. One user saw 300-700 MB/s at 50. Unsloth suggests 64 plus `HF_XET_HIGH_PERFORMANCE=1` for stalls and 429s. Legacy hf_transfer used 10 MB concurrent range reads. — [HF forum](https://discuss.huggingface.co/t/model-download-freezing-at-exact-percentage/177785), [Unsloth debugging guide](https://unsloth.ai/docs/basics/troubleshooting-and-faqs/hugging-face-hub-xet-debugging)
- [U] HF's own default of 16 per file matches Rays' MAX_CONNECTIONS 16. This is a reasonable ceiling, not proof of benefit.

#### Google Drive
- [V] Drive enforces a per-file download quota (not per-connection). The error is `downloadQuotaExceeded` / 403, with a typical lock of 24 hours, sometimes 48 hours or longer. The roughly 10 TB/day figure is community-reported and undocumented. — [rclone forum](https://forum.rclone.org/t/googleapi-error-403-the-download-quota-for-this-file-has-been-exceeded-downloadquotaexceeded/22395), [rclone 48h report](https://forum.rclone.org/t/google-drive-403-download-quota-still-active-after-48-hours/25316)
- Implication: more connections do not help once the file-level quota trips, and a quota 403 is not retryable by backoff. [U]

#### Dropbox, Cloudflare, Akamai, Fastly, SourceForge, distro mirrors
- Cloudflare, Akamai, Fastly, Dropbox, SourceForge: no sources found for per-connection or per-IP download rates. Do not claim anything about them. (Gap.)
- [V] Mirror operators (CentOS mirror list, 2009-2011) report per-IP connection caps via fail2ban (example cap 5), Apache `mod_limitipconn` (example `MaxConnPerIP 6`), and "limit to 2 for ISOs" against download accelerators. One operator's daily hits fell from about 700,000 to under 100,000. A shared-IP office was hurt by the cap. — [CentOS mirror list thread](https://lists.centos.org/pipermail/centos-mirror/2010-January/028327.html), [mod_limitipconn patch discussion](https://listman.redhat.com/archives/fedora-infrastructure-list/2009-August/007388.html)
- [V] Metalink/HTTP (RFC 6249) says clients "must not make more than one concurrent request to any single mirror" and "must limit parallel connections, ideally by watching aggregate throughput as connections are added". — [RFC 6249](https://www.rfc-editor.org/rfc/rfc6249.html)
- [V] aria2 defaults: `--max-connection-per-server` default 1, `--split` N, `--min-split-size` default 20M (no splitting if file under 2x that). — [aria2 manual](https://aria2.github.io/manual/en/html/aria2c)

#### Studies measuring CDN per-flow throughput
- None found. Gap.

### Inferences
- Per-IP caps (mirrors) and per-file quotas (Drive) mean the right signal for "more connections help" is empirical: add connections while aggregate throughput rises, stop when it plateaus (which RFC 6249 also prescribes). [U]
- On big cloud/CDN origins (S3, HF), per-connection TCP limits (RTT, loss, small windows) are the likely bottleneck, so parallel ranges help up to the NIC or ISP limit. [U]
- Rays could: keep MAX_CONNECTIONS 16 as a ceiling but ramp up (for example 4, 8, 16) and stop when aggregate bytes/sec stops improving by a set margin (like RFC 6249 section 7). Rays could: cap known mirror/distro hosts lower (2-6) via a per-host connection cap table, and make the cap lower again after any 429/503 via the per-host backoff. Rays could: treat a Drive-style quota 403 as non-retryable rather than backing off.

### Gaps
- No documented per-connection caps for GitHub, Cloudflare, Akamai, Fastly, Dropbox or SourceForge. Empirical testing with `curl -r` and `aria2c -x1` versus `-x16` against real assets would be required.
- No academic study of CDN per-flow throughput was found.
- The S3 "85-90 MB/s per connection" figure was not verified.

## (b) Papers and systems that download one file from several sources or paths at once

### Takeaway
Rodriguez and Biersack's dynamic parallel access (ToN 2002) is the classic: split into small blocks, request from every mirror, faster servers automatically serve more blocks. Metalink/HTTP (RFC 6249) standardises mirror lists. aria2 is the main practical implementation. Numbers beyond the abstracts could not be retrieved.

### Cited Findings
- [V] Rodriguez and Biersack, "Dynamic Parallel Access to Replicated Content in the Internet", IEEE/ACM ToN, Aug 2002: client fetches different portions of one file from several replicas at once, splitting into blocks and adjusting as it goes. Needs no server changes. Shifts load from congested to less loaded paths automatically. Claims "significant speedups" and "very consistent response times". Best for large files (hundreds of KB and up). Outperforms a history-based scheme that predicts server rates in advance. Precursor: Rodriguez, Kirpal, Biersack, "Parallel-access for mirror sites in the Internet", INFOCOM 2000. — [EURECOM publication page](https://www.eurecom.fr/en/node/4906577) (abstract-level; the PDF at [ce-rodrpa-020801.pdf](https://www.eurecom.fr/publication/838/download/ce-rodrpa-020801.pdf) returned 429)
- [V] RFC 6249 Metalink/HTTP: mirrors via `Link: <url>; rel=duplicate; pri=N` (pri 1 to 999999, lower preferred, missing = lowest); also `pref`, `geo`, `depth`. `Digest` (instance digest, SHA-256 required) used to verify the whole file and reject mismatching mirrors. Use `If-Match` with the server ETag to detect stale mirrors. Clients may only use mirrors from the server they first contacted. Clients should abort stalled or very slow range requests and finish the ranges on other mirrors, and should switch if a mirror is unreachable. If a range request returns a full 200 instead of 206 and speed is the goal, close all but the fastest connection. — [RFC 6249](https://www.rfc-editor.org/rfc/rfc6249.html)
- [V] aria2 `--uri-selector` options: `inorder`, `feedback` (default, uses observed speed from previous downloads and skips dead mirrors), `adaptive` (performance profile, picks one of the best mirrors for first and reserved connections). Server profile invalidation timeout default is 86400 s. — [aria2 manual](https://aria2.github.io/manual/en/html/aria2c)
- [V] aria2 `--lowest-speed-limit` closes connections slower than a given rate. — [aria2 manual](https://aria2.github.io/manual/en/html/aria2c)
- [V] S3 guidance (retry slowest 5 percent of large requests) is a similar hedging idea within one source. — [S3 performance design patterns](https://docs.aws.amazon.com/AmazonS3/latest/userguide/optimizing-performance-design-patterns.html)

### Inferences
- Dynamic block assignment (small blocks pulled by whichever connection is free) naturally balances heterogeneous mirrors. Rays' range-connection pool likely already does this per URL, so mirror support may mostly mean adding more URLs to the same pool plus per-mirror stats. [U]
- Rays could: add Metalink/HTTP (`Link: rel=duplicate`, `Digest`) parsing, with one-connection-per-mirror (RFC 6249 rule) or a lower per-mirror cap, and total across mirrors still bounded by MAX_CONNECTIONS 16. Rays could: reuse per-host backoff as the mirror scoreboard (aria2 `feedback` equivalent: rank by observed speed, deprioritise hosts in backoff). Rays could: abort slow ranges and reassign to another mirror, as RFC 6249 recommends.

### Gaps
- Numeric results from the Rodriguez and Biersack paper (number of mirrors tested, speedup factors) were not retrievable (PDF binary or rate-limited).
- Multi-CDN client-side selection papers, Metalink (RFC 5854) adoption data, and mirror-selection algorithm papers were not searched or found.

## (c) Multipath: MPTCP on macOS, Wi-Fi plus Ethernet, MPQUIC

### Takeaway
Network.framework exposes `multipathServiceType` since macOS 10.14, but only the aggregate mode increases bandwidth, it needs an Apple entitlement, and the server must support MPTCP. Rays uses reqwest, which does not use it, and URLSession cannot set it on macOS. Practical multipath for Rays would be application-level (bind connections to different interfaces) instead.

### Cited Findings
- [V] `NWParameters.MultipathServiceType` cases: `disabled`; `handover` (use other interfaces only when the primary is lost); `interactive` (use others when the primary has loss or delay); `aggregate` (maximize bandwidth across interfaces). Available macOS 10.14+, iOS 12+. — [Apple docs](https://developer.apple.com/documentation/network/nwparameters/multipathservicetype-swift.enum.md)
- [V] mptcp.dev: on macOS MPTCP is client-side only. URLSession on macOS cannot set `multipathServiceType`. Network framework `NWParameters` can (macOS 10.14+). Aggregate needs the MPTCP entitlement (otherwise errors). MPTCP is used only if the server supports it. — [mptcp.dev macOS](https://mptcp.dev/macOS.html)
- [V] Apple uses MPTCP for Siri (Wi-Fi primary, cellular backup) and its stated goal is latency, not throughput. iOS 11 IETF slides label aggregation mode as developers-only. — [Apple support 101905](https://support.apple.com/en-ke/101905), [IETF 99 Sessa slides](https://www.ietf.org/proceedings/99/slides/slides-99-mptcp-sessa-ios-linux-implementation-updates-00.pdf), [Apple 2020 IETF interim slides](https://datatracker.ietf.org/meeting/interim-2020-quic-02/materials/slides-interim-2020-quic-02-sessa-multipath-transports-at-apple-00.pdf) (as summarized by search; slides not fetched)
- [V] MPQUIC (De Coninck and Bonaventure, CoNEXT 2017): matches MPTCP aggregation and handover benefits. In loss-free emulation, one slide reports 13 percent speedup over MPTCP for a 20 MB download, and "better in 85 percent of cases" for large files without loss. It is more robust under loss. These are emulation numbers, not field data. — [CoNEXT 2017 paper](https://inl.info.ucl.ac.be/system/files/conext17-deconinck.pdf), [slides](https://inl.info.ucl.ac.be/assets/historical/2017-multipath-quic-design-and/slides.pdf)
- [V] A MASS 2016 MPTCP cellular measurement found aggregation gains are significant only for bandwidth-intensive delay-tolerant flows. It excluded Wi-Fi. — [Niu et al. MASS 2016](https://i.cs.hku.hk/~cwu/papers/zxniu-mass16.pdf)
- [V] MultipathTester compares MPTCP and MPQUIC on phones (focus on handover). Throughput results not retrieved. — [MultipathTester paper](https://inl.info.ucl.ac.be/system/files/multipathtester.pdf)
- [U] No measured macOS Wi-Fi plus Ethernet aggregation benchmark was found.
- [U] A developer-forum report says on iOS 17 enabling handover/interactive breaks peer-to-peer NWConnections (FB13401552). — [Apple forums](https://developer.apple.com/forums/thread/750541)

### Inferences
- MPTCP aggregate gives nothing unless the origin or CDN speaks MPTCP, which most do not. For a Mac with Wi-Fi plus Ethernet, the realistic approach is application-level multipath: open range connections bound to each interface (for example `IP_BOUND_IF` on macOS), distinct from MPTCP. This works with any HTTP server. [U]
- Per-IP limits on the server side may count the two source IPs separately, so interface binding could also dodge per-IP caps (not verified, and it is ethically in the same area as ban evasion). [U]
- Rays could: leave MPTCP aside (needs Network.framework plus an entitlement, and server support). Rays could: if multi-interface is wanted, bind a subset of the 16 connections to each active interface and give each interface its own throughput score, reusing the per-host backoff idea per (host, interface).

### Gaps
- No Apple document confirming aggregate mode availability for non-entitled third-party Mac apps beyond the mptcp.dev statement.
- No field measurements of MPQUIC Wi-Fi plus LTE or Ethernet aggregation gains.

## (d) Retry-After, 429 conventions, politeness, bans on aggressive clients

### Takeaway
`Retry-After` has two forms, delay-seconds and HTTP-date. A client honoring only delta-seconds will mishandle date forms. 429 comes from RFC 6585 and may carry `Retry-After`. Evidence of banning multi-connection clients is limited to mirror-operator anecdotes.

### Cited Findings
- [V] `Retry-After` syntax is either `<http-date>` or a non-negative decimal integer of seconds after the response is received. — [MDN Retry-After](https://developer.mozilla.org/docs/Web/HTTP/Headers/Retry-After)
- [V] RFC 9110 section 10.2.3 defines the field. RFC 6585 says the 429 response may include `Retry-After`. 503 may include it (RFC 9110 section 15.6.4, confirmed in fetched text: "The server MAY send a Retry-After header field"). 413 should include it if the condition is temporary. — [RFC 9110](https://www.rfc-editor.org/rfc/rfc9110.html) (exact 10.2.3 text not retrieved; truncated)
- [V] Per search summaries, HTTP-date values must be parsed as IMF-fixdate plus the two obsolete formats, in UTC. Clock skew on the client can turn a date value into an immediate retry or an excessive delay. — [MDN](https://developer.mozilla.org/docs/Web/HTTP/Headers/Retry-After), [http.dev](https://http.dev/retry-after)
- [V] A local exponential-backoff cap does not permit retrying before a valid server-given time. — [OneUptime article](https://oneuptime.com/blog/post/2026-08-14-retry-after-vs-exponential-backoff/view) (secondary blog)
- [V] S3 uses 503 Slow Down, temporary; back off, retry slowest requests on new connections. — [S3 performance design patterns](https://docs.aws.amazon.com/AmazonS3/latest/userguide/optimizing-performance-design-patterns.html)
- [V] Mirror operators ban or cap per IP (see section a). The Apache/fail2ban examples show that exceeding the cap yields refused connections or an IP block rather than a polite 429. — [CentOS mirror list](https://lists.centos.org/pipermail/centos-mirror/2010-January/028327.html)
- [V] RateLimit header fields are only an IETF draft (not an RFC) as of the retrieved versions. — [draft-ietf-httpapi-ratelimit-headers-03](https://datatracker.ietf.org/doc/html/draft-ietf-httpapi-ratelimit-headers-03)
- [U] HF suggests raising concurrency to cope with 429s (Unsloth guide), which contradicts the usual advice to reduce load on 429. Treat it as a community workaround. — [Unsloth guide](https://unsloth.ai/docs/basics/troubleshooting-and-faqs/hugging-face-hub-xet-debugging)

### Inferences
- A 429 or 503 on one range connection most often means a per-IP or per-client limit that applies to all 16, so the correct response is to shrink the connection count for that host, not retry on the same width. [U]
- Rays could: parse the HTTP-date form of `Retry-After` (IMF-fixdate plus RFC 850 and asctime) and compute the delay against the response's `Date` header rather than the local clock where available, then clamp to a sane maximum. Rays could: on 429/503 reduce that host's connection ceiling (from MAX_CONNECTIONS 16 toward 1 to 4) and regrow slowly after a quiet period, honoring `Retry-After` as a floor for every connection to that host. Rays could: treat 403 `downloadQuotaExceeded` and similar as terminal, not as backoff candidates.

### Gaps
- Exact RFC 9110 section 10.2.3 text not read directly (page truncated); relied on MDN and secondary summaries.
- No data on how often servers ban multi-connection clients beyond mirror-list anecdotes. No documented policies were found from Debian, Arch, kernel.org or SourceForge.
- No statistics on `Retry-After` HTTP-date prevalence in the wild.
