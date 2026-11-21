# Torrent / magnet support for Rays: research

Date: 2026-11-20. Research only, no code changed. "UNVERIFIED" marks anything not confirmed from a fetched source (several pages returned partial content; dates on GitHub release pages had no year).

## 0. How a job is modelled today (engine read)

Read from `engine/src/types.rs`, `api.rs`, `store.rs`, `scheduler.rs`:

- `JobState`: Queued, Running, Paused, Retrying{attempt}, Done{path}, Failed{reason}.
- `JobView` (UniFFI record): id, url, name, done, total, bytes_per_sec, resumable, state, connections, `parts: Vec<PartView>` (byte ranges start/end/done for a segmented bar).
- `Job` (persisted, `jobs` table): url, name, part_path, final_path, done, total, etag, last_modified, resumable, segments (JSON), position, timestamps. HTTP-specific fields (etag, last_modified, segments, part_path) do not fit a torrent.
- `Engine` API: `add(urls)`, `pause`, `resume`, `remove(id, delete_partial)`, `set_speed_limit` (global), `set_max_running`, `set_connections`, `snapshot`, `next_events`. Events are `Upsert{JobView}` / `Removed`.
- `add(urls)` takes strings and returns `AddResult{url,id,error}`; a `magnet:` string could enter here unchanged, which makes CLI/extension hand-off cheap.
- The "sorter on completion" was NOT found in these four files (rg for "sorter" found nothing; only a `parts.sort_by_key` hit). It likely lives elsewhere. UNVERIFIED how it is invoked; torrents would need it to handle a directory, not a single file.

## 1. Cloud / seedbox services

### Seedr (seedr.cc)
- Model: Seedr fetches the torrent to its servers; you play in-browser (cloud player, subtitles, casting; Roku/Plex/Jellyfin; WebDAV mount on top tier) or download to your device. Source: [seedr.cc](https://seedr.cc).
- Pricing (page rendered without decimal points, so exact figures UNVERIFIED): Go Lite 10 GB about $3.95; Basic 50 about $7.95; Pro 500 (500 GB) about $12.95; Master 2T (2 TB, 4K, WebDAV) about $19.95; annual = 2 months free. Free tier details not confirmed from the page. Source: [seedr.cc](https://seedr.cc).
- API: REST v1 exists at `https://www.seedr.cc/rest/`: `POST transfer/magnet|url|file`, `GET transfer/{id}`, folder list / ZIP download, `GET file/{id}` (redirects to the file), HLS endpoint, `GET user`. Auth is HTTP basic with account email and password, "only secure for personal use". Restricted to premium account types. v1 is described as being replaced by a v2 REST API and an OAuth API. No rate limits documented. Source: [seedr.cc/docs/api/rest/v1](https://seedr.cc/docs/api/rest/v1) (docs date from 2021).
- Unofficial: the `seedrcc` Python library reverse-engineers the Kodi/Chrome-extension API (device-code flow at seedr.cc/devices, password login) and works for free accounts. Fragile and outside Seedr's terms for apps (UNVERIFIED legally). Source: [github.com/hemantapkh/seedrcc](https://github.com/hemantapkh/seedrcc).
- How it works (from user reports; Seedr publishes no architecture): its servers run the BitTorrent client and join the swarm, so the user's IP never does. When the transfer finishes, the files sit in the user's cloud storage (quota per plan; free about 2 GB, UNVERIFIED) and are served as plain HTTP links, an in-browser player and casting. Torrents another user already fetched are said to appear instantly, which suggests server-side dedup cache (UNVERIFIED belief from a 2020 blog). Sources: [TorrentFreak](https://torrentfreak.com/torrent-from-the-cloud-with-seedr-160117/), [co10 blog](https://co10.github.io/2020/07/20/Seedr-The-best-FREE-cloud-torrenting-service).
- Device login used by Kodi / Chrome extension (community-reverse-engineered, RFC 8628 style): `POST https://www.seedr.cc/api/device/code` with `client_id=seedr_xbmc` returns a device and user code; the user enters the user code at `https://www.seedr.cc/devices`; the client then polls `https://www.seedr.cc/api/device/authorize` for a token. Undocumented and reuses Seedr's own client ID, so not safe to ship. Source: [aioseedrcc login source](https://aioseedrcc.readthedocs.io/en/stable/_modules/aioseedrcc/login.html).
- Legal/ToS: footer links Terms of Use, Privacy, Acceptable Use, Copyright (DMCA). Terms text itself could not be fetched (404 on guessed URLs); posture inferred as DMCA-safe-harbour intermediary. UNVERIFIED.

### Put.io
- OAuth2 API, public Swagger docs ([api.put.io/v2/docs](https://api.put.io/v2/docs/) redirects to swaggerhub). Magnet transfers and file download URLs via API. Details not fetched (redirect). Pricing page showed only a $0.99 one-day trial in the fetched content, no permanent free tier; other plans UNVERIFIED. Source: [put.io/pricing](https://put.io/pricing).

### Premiumize
- Best-documented fit. Auth: API key (Bearer) or OAuth2 (Authorization Code + PKCE recommended; Device Code also). Third-party integrations must use PKCE. `POST /api/transfer/create` (src = magnet/URI), `GET /api/transfer/list` (status incl. seeding), `POST /api/transfer/directdl` returns a `link` per file without storing in cloud, `link` fields in folder list/item details. Rate limit: error code `rate_limit_reached` exists, numbers not documented; fair-use via `limit_used`. Source: [premiumize.me/api](https://www.premiumize.me/api).

### Real-Debrid
- API at api.real-debrid.com: `POST /torrents/addMagnet` (201), `POST /torrents/selectFiles/{id}`, then `POST /unrestrict/link` returns an HTTPS link. Rate limit 250 requests/min (429 counts toward limit). Auth: private token, device flow (opensource apps; do not redistribute credentials), OAuth2. Public opensource client ID is scope-limited. Source: [api.real-debrid.com](https://api.real-debrid.com/).
- Legal: TorrentFreak reports Real-Debrid started filtering cached content after a notice from French film trade body FNEF, positioning itself under EU DSA / French LCEN. Source: [torrentfreak.com](https://torrentfreak.com/real-debrids-renewed-piracy-crackdown-follows-corporate-restructuring/). Paid service, no free tier (UNVERIFIED).

### TorBox
- Docs at [api-docs.torbox.app](https://api-docs.torbox.app/) list auth, create torrent from magnet, `requestdl` endpoint, rate limits, plans, a free tier, but the fetched page had no content. Everything beyond that list is UNVERIFIED.

### Integration fit
Every provider above ends in a plain HTTPS URL (Seedr `file/{id}`, Premiumize `link`/directdl, Real-Debrid `unrestrict/link`, Put.io file link, TorBox `requestdl`). Rays' existing HTTP engine (resume, split connections) already handles those. A "cloud torrent" backend is therefore: submit magnet, poll provider, then call `engine.add([https links])`. Best API quality for a third-party desktop app: Premiumize (PKCE, direct links) and Real-Debrid (device flow). Seedr's API is premium-only with password basic auth, weakest fit.

Costs and risks of the cloud route: user needs a paid account; the provider holds the legal exposure for the download, Rays only fetches HTTPS; tokens must be stored in Keychain; each provider is a separate integration to keep alive; the free/no-servers promise holds (no Rays server), but the feature is not free for the user.

## 2. Native Rust / C++ options

| | librqbit (rqbit) | cratetorrent | libtorrent-rasterbar |
|---|---|---|---|
| Language | Rust, tokio | Rust, tokio | C++ (Boost.Asio) |
| Licence | Apache-2.0 | MIT/Apache-2.0 (badge) | BSD-3-Clause |
| AGPL-3.0 compat | Yes (Apache-2.0 is one-way compatible into GPLv3/AGPLv3) | Yes | Yes |
| Maturity | Full client + library; about 2.0k stars, 2,123 commits; library at 8.1.1 on docs.rs at time of search (rqbit app is 9.x) | Experimental, 84 commits, no releases | Reference-grade; 15,418 commits, 6.1k stars; used by qBittorrent |
| Activity | v9.1.0 on 29 Oct (year not shown; assumed 2026), v9.0.1 Aug, v9.0.0 15 Aug; steady fixes | Last commit date not shown; looks dormant (UNVERIFIED) | 2.0.14 in Debian unstable 2026-08-10; 2.1.x in experimental (Debian tracker; upstream release page not confirmed) |
| Magnet / DHT / PEX | Yes (BEP 9, 5, 11) | Not yet (planned) | Yes |
| uTP | Added v9.0.0, behind a flag, off by default | No | Yes (BEP 29) |
| Encryption (MSE) | Not mentioned (UNVERIFIED) | Planned | Supported in libtorrent generally (UNVERIFIED on this fetch) |
| v2 torrents (BEP 52) | Not mentioned (UNVERIFIED, likely no) | Planned | Yes, since 2.0 |
| Selective files | Yes, regex file selection | n/a | Yes (priority 0) |
| Sequential | "default and only option" per README (so no rarest-first tuning; hurts swarm health slightly) | n/a | Yes, optional |
| Rate limits | Upload and download | Basic | Yes, plus unchoke caps |
| Seeding controls | Torrent creation and seeding exist; ratio/time stop policy not found in README (UNVERIFIED) | n/a | Share ratio / seed time / share mode |
| NAT | UPnP port forwarding; NAT-PMP not mentioned | none | UPnP, NAT-PMP, PCP |
| BEP list (rqbit) | 3, 5, 7, 9, 10, 11, 12, 14, 15, 20, 23, 27, 29, 32, 47, 53 | | see features-ref |
| Binary size | Not measured; README cites tens of MB RAM; added crates likely a few MB (UNVERIFIED) | | libtorrent plus Boost and OpenSSL; larger and slower to build (UNVERIFIED) |
| Tokio embed | Native, in-process `Session`, async API | Native | Needs FFI; Rust bindings `libtorrent-sys` 1.0.0 (June 2022, thin, build against local libtorrent C_2_0) are stale, so you write your own cxx bridge and a polling/alerts thread |

Sources: [github.com/ikatson/rqbit](https://github.com/ikatson/rqbit), [rqbit releases](https://github.com/ikatson/rqbit/releases), [rqbit LICENSE](https://raw.githubusercontent.com/ikatson/rqbit/main/LICENSE), [docs.rs librqbit](https://docs.rs/crate/librqbit/latest), [cratetorrent](https://github.com/mandreyel/cratetorrent), [libtorrent](https://github.com/arvidn/libtorrent), [features-ref](https://www.libtorrent.org/features-ref.html), [Debian tracker](https://tracker.debian.org/pkg/libtorrent-rasterbar/news/), [libtorrent-sys](https://lib.rs/crates/libtorrent-sys).

Notes:
- cratetorrent README says "Requires Linux!" (pwritev/preadv); dead end for macOS and lacks magnet/DHT.
- rqbit v9.1.0 notes list several remote-peer crash fixes (deep bencode, ut_metadata, listener panic). A network-facing parser in a young codebase: pin versions, run it in-process only if you accept that blast radius, or isolate it in the helper process (see 3).
- Licence: all three are compatible with shipping inside an AGPL-3.0 app. Separate concern: AGPL/GPL and Mac App Store terms conflict is a widely cited issue (UNVERIFIED here); direct distribution (notarised) avoids it, and it also avoids sandbox limits.

## 3. What native integration needs

### Job model
- One Rays job per torrent (id = one row), not one per file. Reasons: pause/resume, ratio and seeding are per-torrent; the UI row stays one line.
- Map to `JobView`: `url` = magnet or .torrent path, `name` = torrent name, `total` = sum of selected files, `done` = verified bytes, `connections` = connected peers. `PartView` can be reused for per-file progress by laying files out as contiguous byte ranges in torrent order (start/end/done per file), so the segmented bar becomes a per-file bar with no UI model change.
- Needed additions (design only): a `kind` (http/torrent) on `Job`, a `JobState::Seeding` (Done is not final while seeding), peers/seeds/ratio/uploaded fields on `JobView`, an extra file list for the selection UI, and a store migration for torrent fields (infohash, magnet, selected file indexes, uploaded bytes, rqbit resume state). `part_path`/`etag`/`segments` are unused for torrents. `Done{path}` points at a directory.
- Scheduler: torrent runs need to share `max_running` and the global speed limit (`set_speed_limit` today is HTTP-only; must be passed to rqbit's rate limiter, including an upload limit that does not exist today).
- Pause/resume: rqbit supports pause/unpause; fast resume avoids rehash. Persist rqbit session state in the Rays data dir; reconcile with the `jobs` table on launch. Mid-metadata magnets (no info dict yet) need a "Fetching metadata" state and a timeout.
- Sorter: runs on completion of download; decide whether it moves the torrent directory whole (recommended) and whether it waits for seeding to end (moving files breaks seeding unless the torrent's path is updated). Easiest: sort after seeding stops, or seed from the sorted location via rqbit's output folder change (UNVERIFIED API).

### macOS specifics
- Incoming port: pick a fixed or random port, UPnP via rqbit (NAT-PMP not mentioned). A listening socket triggers the macOS Application Firewall "accept incoming connections" prompt for unsigned or ad-hoc binaries; a signed, notarised build with a stable identity prompts once. Downloads work without inbound (outbound-only, slower).
- Sandbox: if the app (or the helper hosting the engine) is sandboxed, inbound peers require `com.apple.security.network.server` plus `com.apple.security.network.client`. Apple's docs describe the key as for listening to connections initiated by other machines; no source confirmed App Review acceptance for a torrent client. Source: [Apple Developer Forums](https://developer.apple.com/forums/thread/836723). If Rays is not sandboxed (direct distribution), none of this applies.
- Battery/power: pause seeding on battery and in Low Power Mode; cap DHT and peer connections; do not keep awake. Hash-check and many sockets are the main costs. Policy, not API.
- `magnet:` scheme: register `CFBundleURLTypes` for `magnet`, handle in the SwiftUI `onOpenURL`; `.torrent`: declare `CFBundleDocumentTypes` / UTType `org.bittorrent.torrent` (UNVERIFIED exact UTI) and handle open events. The default-handler prompt is user-controlled; do not steal it silently.
- CLI/MCP: `dl add <magnet|file.torrent>` hits the same `add()`; the MCP tool schema needs a file-selection argument and a "confirm" step so an agent cannot start an arbitrary swarm.
- Browser extension: `magnet:` links can be intercepted by the extension or by the OS handler; .torrent downloads can be detected by MIME `application/x-bittorrent`. Hand-off goes through the existing channel to `add()`.

## 4. Risks

- Legal, publisher: shipping a BitTorrent client is itself lawful (qBittorrent, Transmission, etc.). Exposure comes from promotion, bundled indexes/search, or default "piracy" features. Keep Rays indexer-free, no tracker list or search, neutral copy. App Store review of torrent clients is a separate risk (UNVERIFIED). US Supreme Court Cox v. Sony (March 2026) narrowed contributory liability for intermediaries, per press reports; not directly about software publishers. Sources: [americanbazaaronline](https://americanbazaaronline.com/2026/03/26/supreme-court-isps-not-liable-for-users-copyright-infringement-477616/), [musicbusinessworldwide](https://www.musicbusinessworldwide.com/us-supreme-court-sides-with-cox-communications-in-landmark-music-piracy-case-brought-by-record-labels). Not legal advice; get counsel before launch.
- Legal, users: native torrenting exposes the user's IP to swarm monitors and copyright notices; the cloud route exposes the provider instead. Say so in first-run copy. No built-in VPN claims.
- ISP throttling: BitTorrent traffic is commonly shaped. Mitigations: protocol encryption (rqbit not confirmed, libtorrent yes), uTP, SOCKS5 proxy (rqbit supports it, `socks5h://` in 9.1.0), optional "bind to interface" for VPN users (UNVERIFIED in rqbit).
- Seeding etiquette: seeding is the public-good default but also increases exposure. Common client defaults (UNVERIFIED, from memory): Transmission ratio limit 2.0 off by default, qBittorrent unlimited. I could not confirm these; a search found only third-party text. Proposed Rays default: stop seeding at ratio 1.0 or after 24h or when on battery, with per-torrent override, upload cap lower than download.
- Malware: executables inside torrents are the main vector. Defaults: never auto-open or auto-run, keep macOS quarantine (`com.apple.quarantine`) on every extracted file so Gatekeeper still checks, show file list before start and flag `.app`, `.pkg`, `.dmg`, `.command`, `.sh`, archives with executables, and no "open when done". Also disk-fill (huge declared sizes) and zip-bomb-like torrents: check free space against selected size.
- Parser/protocol attack surface: rqbit 9.1.0 shipped fixes for three remote-peer crashes. Consider running the torrent engine in a separate process with its own entitlements.
- Build/ops: more dependencies (Apache-2.0 notices to include in AGPL distribution), larger binary, UniFFI surface growth.

## 5. Recommended approach for Rays

### Option A: Native via librqbit only
- Effort: large. Rough: 3 to 5 weeks for the engine adapter, store migration, Seeding state, UI (file picker, peers, ratio), URL scheme and file association, CLI/MCP.
- Trade-offs: no account, no cost, fits "free, no servers", rqbit is tokio-native and Apache-2.0 so AGPL-safe. Weaker feature set than libtorrent (no v2, encryption unconfirmed, sequential-only, uTP experimental).
- Risks: user IP exposure, ISP throttling, firewall prompt, parser bugs in a young codebase, scope creep into a full torrent client.

### Option B: Cloud torrent via provider API only (Premiumize and/or Real-Debrid first)
- Effort: small to medium. Rough: 1 to 2 weeks per provider; job = "cloud torrent" waiting state, then normal HTTPS jobs via `add()`. No engine protocol changes beyond a "waiting on provider" state.
- Trade-offs: reuses the existing split-HTTP engine and sorter; no port, firewall, battery or seeding issues; user IP not in the swarm. Needs a paid account per provider; the provider can remove content; tokens must live in Keychain; API terms change (Seedr's is premium-only with basic auth, so skip it initially).
- Risks: dependency on third-party uptime and terms, user confusion over paid prerequisites, and the publisher is still the author of a tool that routes magnets to debrid services (legal exposure unclear, UNVERIFIED).

### Option C: Both, staged
- Effort: B first (fast, low risk), then A behind a setting.
- Trade-offs: covers users who want free and users who want privacy; double maintenance.
- Risks: scope and test surface double; ship A only after B proves demand.

### My recommendation
Start with Option B (Premiumize via OAuth PKCE, Real-Debrid via device flow) because it ends in an HTTPS job Rays already handles and avoids every macOS networking issue. Add native librqbit later, with safe defaults (ratio 1.0 stop, quarantine, no auto-open, no bundled search), only if users ask. Choose libtorrent only if v2 torrents, MSE or fine seeding control become requirements; the cost is a hand-written cxx bridge since existing Rust bindings are stale.

## Unverified summary
Seedr exact prices and free tier; Seedr ToS text; Put.io and TorBox plans and rate limits; rqbit v2 and MSE support, seed-ratio controls, binary size; libtorrent upstream latest release; Transmission/qBittorrent default ratios; Mac App Store acceptance of a torrent client; exact UTI for .torrent; where the sorter hooks in.
