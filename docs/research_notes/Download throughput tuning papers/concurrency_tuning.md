# Online concurrency / parallel-stream tuning for bulk transfers (2018-2026)

Tags: [V] = read in fetched source text (WebFetch of HTML/abs; fetch tool summarizes, so figures are as relayed by it); [U] = unverified (search snippet only, or PDF unreadable).
Falcon (SC21/TPDS23, Arifuzzaman & Arslan) and FastBioDL (arXiv 2508.05511) are baseline context: one line each only.
Rays constants: TICK, WARM_TICKS, WINDOW_TICKS (measure), HOLD_TICKS, PENALTY (k in thr/k^n), MAX_CONNECTIONS.

## 1. What do HARP, AutoMDT, Falcon follow-ups, DRL, BO, bandit, gradient approaches report?

### Takeaway
Everyone converges on the same utility shape U = thr / K^n (minus a loss term on WAN), with K = 1.02 almost universally. Gradient/hill-climbing are the robust online baselines; DRL (PPO) reaches the optimum in 3-12 s but needs hours of offline/simulator training, so it does not fit a no-history desktop client. HARP's historical-log approach needs big logs (21K transfers). No bandit paper for connection count was found.

### Cited Findings

**FastBioDL (context, one line)** - closest to Rays: client-side parallel downloader, GD beats BO (BO ~20% slower total copy time), k=1.02 chosen, probe 3 s default (5 s in comparisons). [V] [arXiv 2508.05511](https://arxiv.org/html/2508.05511)
- k sweep (Table 1): k=1.01 -> 701.2 Mbps @ avg cc 6.77; k=1.02 -> 815.8 Mbps @ 6.23; k=1.05 -> 743.9 Mbps @ 4.64. [V] same URL. Only one dataset/link; single data point for the penalty claim.
- Avg concurrency in practice 3.4-4.9 on normal runs, ~6-14 on high-speed tests; no cap stated. [V]
- Beat fixed cc=5 by 44% and fixed cc=3 by 67% (scenario 1). [V]
- Gap: no time-to-convergence reported. [V]

**Falcon (context, one line)** - online HC/GD/BO concurrency search; utility with penalty/regret term; claims Nash-equilibrium fairness among competing transfers and 2-6x throughput vs prior. [U: from search snippet only; PDF at par.nsf.gov/servlets/purl/10283067 was unreadable binary] [SC21 page](https://sc21.supercomputing.org/proceedings/tech_paper/tech_paper_pages/pap476.html)

**HARP (Arslan, Guner, Kosar, SC16; arXiv 1708.03053) - outside 2018 window but the reference for history+probing**
- Tunes concurrency, parallelism, pipelining; one short sample transfer per file-size group (tiny/small/medium/large), then regression model from history picks params. [V] [ar5iv](https://ar5iv.arxiv.org/html/1708.03053)
- Sampling finishes in <15 s with 5% threshold and 3 s monitoring interval; 2-4x faster than fixed-size sampling; ~10% sampling error with <10 s delay, <15% under heavy background traffic in 15 s. [V]
- Up to 50% throughput over existing solutions; e.g. +25% over SC/ProMC small files, +5% large files, +47%/37% medium/high load; online tuning on top of HARP adds 30-40%. [V]
- History: 21K transfers over 12 weeks (~4 MB metadata); similarity threshold starts 0.99, relaxed until >=6K entries remain; >=30 groups needed; polynomial regression until R^2>0.7 (70/30 split); relaxation ratio 0.7 for concurrency/parallelism. [V]
- Validation accuracy "always above 85%"; estimation accuracy 41% (tiny files, WAN, light traffic) to 91%. [V]
- Fit: needs a server-side/history log of thousands of transfers; WAN science.

**Marlin (Arifuzzaman & Arslan, ICS'23, "Use Only What You Need")**
- Independent online gradient descent per stage (read / network / write concurrency). [V via AutoMDT text and search] [AutoMDT](https://arxiv.org/html/2508.05546v1)
- Search snippet: BO variant converges in 10-15 search intervals; high concurrency costs up to +50% energy on DTNs. [U: snippet from par.nsf.gov/servlets/purl/10514952, PDF unreadable]
- AutoMDT says Marlin's three optimizers do not coordinate and converge slowly. [V]

**AutoMDT (Swargo, Arslan, Arifuzzaman, arXiv 2508.05546, 2025)**
- Single PPO agent outputs read/network/write concurrency jointly (continuous, rounded, clamped to [1, n_max]); discrete action space failed to converge. Trained in a simulator. [V] [arXiv](https://arxiv.org/html/2508.05546v1)
- Offline training ~45 min (up to 60), ~20,150 episodes x 10 steps. Full online training estimated ~5-7 days. Online fine-tune 2 h changed concurrency ~1%. [V]
- Ramp-up: concurrency 20 in 7 s (Marlin: 14 after 62 s); 13 streams in 6 s vs Marlin 12 in 29 s; 15 in 3 s vs 14 in 42 s. [V]
- 100x1 GB: 44 s vs Marlin 74 s (68% faster as claimed). 1 TB NCSA-TACC: 23,988 vs Marlin 18,066.8 (1.33x) vs Globus 3,652 (6.57x) (units inferred Mbps). [V]
- Utility = sum over 3 stages of thr/K^n_stage, K=1.02; sweep over 1-25 Gbps links put best K "just above 1"; higher K -> fewer threads. [V]
- No fairness experiment, no stated probe interval (logs 1/s, training waits 3-5 s). Globus baseline (cc4/p8) called "somewhat unfair". [V]
- Fit: HPC/DTN. 5-day-online-training problem rules out in-app learning; would need a pretrained policy shipped blind.

**EDT: Elastic Data Transfer with Hybrid RL (arXiv 2511.06159, 2025)** (Falcon follow-up, same group)
- DRL concurrency + heuristic parallelism + pipelining = infinite. Chunk 512 MB (256 MB ablation). [V] [arXiv](https://arxiv.org/html/2511.06159v3)
- Utility U = thr/K^cc - B*plr, K=1.02, B=10. [V]
- Online start-up to mean throughput: DRL 3 s, EDT 6 s, GD heuristic 40 s, Falcon 46 s. [V] (Strong evidence that 1-step additive GD-like search takes ~40-46 s on 33-45 Gbps WAN.)
- Throughput vs Falcon: NEWY-CERN 40.5 vs 23.7 Gbps (dataset A), 41.8 vs 22.2 (B), 11.5 vs 0.7 (C, small files). Not applicable to large single-file desktop downloads except A. [V]
- Mean EDT concurrency 15.1 (large files), 3.8-8.6 (mixed/small); 1 MB files converge ~8.2 threads. CCmax not stated. [V]
- Probe: logs every 1 s; simulator step 5 s; text says >=3 s of data per utility sample (internal inconsistency noted by fetcher). [V]
- Fairness: 3 competing EDT transfers Jain index typically >0.95; against fixed cc=8 flow, fixed flow held ~8 Gbps, EDT took remainder. [V]
- Simulator training ~156 s mean wall clock (range 33-222 s). [V]
- Fit: WAN science; needs simulator + trained model.

**Jamil, Rodrigues, Goldverg, Kosar - RL for available bandwidth (arXiv 2211.11949, 2022)**
- PPO; state = history of RTT gradient, RTT ratio, packet loss, throughput; 5 actions (+5, +1, 0, -1, -5 streams). Utility T/K^n - T*L*B (K, B unspecified). [V] [arXiv html](https://arxiv.org/html/2211.11949)
- Single throttled 1 Gbps transfer, optimum 20 streams: PPO converged ~12 s, BO ~30 s, GD ~50 s; throughput PPO 837 / BO 807 / GD 780 Mbps. Abstract: 40% faster near-optimal, up to 15% higher throughput, fair sharing vs greedy. [V]
- Training 5,000 episodes (~28 h, 20 s episodes) + 1,000 retrain episodes per testbed. [V]
- Optimum stream counts observed: 15, 18, 20, 19 on uncapped paths. [V]
- Monitoring interval not stated. [V]
- Useful design idea for Rays: asymmetric step (+5/+1/-1/-5) rather than +1 only; and RTT-gradient/loss as extra signal. Not RL-dependent.

**SPARTA (Jamil, Goldverg et al., arXiv 2503.13662, 2025)** - DRL for concurrency+parallelism with energy objective.
- 1 s monitoring interval; 5 discrete actions (hold, +1/+1, -1/-1, +2/+2, -2/-2); start (4,4). [V] [arXiv](https://arxiv.org/html/2503.13662v1)
- Up to 25% more throughput, up to 40% less energy vs baselines (baseline for max unspecified). Offline training 30-94 min depending on algorithm (R_PPO 48.5 min). [V]
- Utility T/K^(cc*p) - T*L*B (K, B unspecified). [V]
- Fit: energy/WAN; offline training. Skip.

**Bayesian optimization / bandit**
- FastBioDL (above) is the only client-side head-to-head: GD > BO, because BO needs random seed trials and early samples during transient spikes skew the surrogate. [V]
- Falcon's BO variant exists [U]. Marlin BO 10-15 intervals [U].
- Searched for multi-armed-bandit connection-count tuning: found only Configanator/ConfigTron (contextual bandits for network/CDN config, not download managers) [U, snippet]. No regret bound for connection-count tuning found.

### Inferences
- All reported near-optimal times (3-12 s DRL, 40-50 s GD/BO) are on high-BDP WAN links with optima at 15-20+ streams; for desktop ISP links the optimum is typically 3-8 streams (FastBioDL avg 3.4-6.8), so +1-step search reaches it in fewer steps.
- A cheaper "DRL-like" win without learning: multiplicative or +2/+5 early steps, then +/-1 refinement.

### Gaps
- Falcon, Marlin, ICS'23 and HARP-journal PDFs returned unreadable binary; their numbers rest on search snippets [U].
- No peer-reviewed regret bound for online connection tuning found.
- None of these papers test seconds-to-minutes single-file HTTP downloads on consumer links.

Rays could:
- PENALTY: keep 1.02 (FastBioDL sweep, AutoMDT sweep, EDT all agree; only 1.01 and 1.05 tested as alternates, 1.02 best on one dataset).
- TICK: 1 s is the logging granularity in AutoMDT/EDT/SPARTA, but utility decisions in all work use >=3 s of data (HARP 3 s, FastBioDL 3-5 s). Consider decision every 3 s, sampling 1 s ticks internally.
- MAX_CONNECTIONS: 16 is within the 15-20 optima seen on WAN; consumer links need far fewer. Keep 16.
- WARM_TICKS/WINDOW_TICKS/HOLD_TICKS: see sections 2-4.

## 2. Which fit a short-lived desktop download vs long WAN science transfers?

### Takeaway
Fits desktop: online GD / hill-climb with utility thr/K^n (Falcon-style, FastBioDL), no training, no history server. Fits WAN science only: HARP (history logs), AutoMDT/EDT/SPARTA/PPO-RL (simulator + offline training, hours-days), multi-stage read/network/write tuning (disk-bound DTNs).

### Cited Findings
- AutoMDT/EDT/RL papers all require offline simulator training (45 min; EDT 156 s sim wall-clock; 28 h for Jamil 2022); online fine-tune gave ~1% change. [V] [AutoMDT](https://arxiv.org/html/2508.05546v1), [EDT](https://arxiv.org/html/2511.06159v3), [Jamil](https://arxiv.org/html/2211.11949)
- Testbeds are 1-45 Gbps links with 33-85 ms RTT (FABRIC, CloudLab, Chameleon); none are consumer broadband. [V] (EDT, AutoMDT, SPARTA)
- FastBioDL is the only client-side downloader paper (HTTP/FTP genomic downloads, avg concurrency 3-7, up to ~14 on high-speed). [V] [arXiv 2508.05511](https://arxiv.org/html/2508.05511)
- HARP 3 s monitoring, <15 s sampling for 10 Gbps WAN. [V]

### Inferences
- For a download of 64 MiB-few GiB on 100 Mbps-1 Gbps, the whole file may finish in 10-60 s, so a 40-46 s GD ramp (EDT table) is comparable to the whole transfer; the cost of search must be small. Rays's current 1 connection/step with 4 initial already starts mid-range, which is the right instinct.
- Big-file-only gating (>=64 MiB) is consistent with no paper tuning small transfers.

### Gaps
- No evidence on files < 1 GB over consumer links.

Rays could:
- MAX_CONNECTIONS: stay 16.
- WARM/WINDOW/HOLD: see section 3.

## 3. Probe interval, utility shape, step size, penalty constant, regret

### Takeaway
Evidence supports: 3-5 s per utility sample, utility thr/1.02^n (add loss term only if observable), start mid-range and step +1 near optimum with larger early steps (+5/+2) as an option, K=1.02.

### Cited Findings
- Probe/monitor interval: HARP 3 s [V]; FastBioDL default 3 s, 5 s in comparisons [V]; AutoMDT waits 3-5 s per config in training [V]; EDT >=3 s of data per utility sample, 5 s simulator step [V]; SPARTA 1 s MI [V].
- K: 1.02 in AutoMDT, EDT, FastBioDL; AutoMDT sweep best "just above 1" for 1-25 Gbps; FastBioDL: 1.01 over-provisions (6.77 cc, lower thr), 1.05 under-provisions (4.64 cc, 743.9 vs 815.8). [V]
- Step size: Jamil uses +/-1 and +/-5; SPARTA uses +/-1, +/-2 (joint); AutoMDT continuous jumps to ~13-15 within 3-6 s. [V]
- Loss term: EDT B=10 on packet loss rate. [V] (Not observable from reqwest; skip.)
- Regret/proof: Falcon claims Nash-equilibrium convergence via regret-like utility [U, snippet]. No regret bound found for single-flow tuning.
- With K=1.02, adding a connection is worth it only if throughput rises by >2% (marginal), this is Rays's current 1.02^n rule. [Inference from formula; not stated by a source.]

### Inferences
- Current Rays timing (1 s tick, 1 warm, 2 measure = 3 s of data per decision) matches the 3 s used by HARP/FastBioDL; good. 15-tick hold is outside any paper's evidence (they re-probe continuously); a shorter hold (e.g. 10) or re-probe on throughput drop >20% would be a design choice, not evidence-based.
- Noise: sub-2% gains are within measurement noise on a 3 s window, so K=1.02 effectively requires a clearly measurable gain.

### Gaps
- No published tuning of HOLD period; no regret bound; K never tested on non-science links beyond one FastBioDL sweep.

Rays could:
- TICK = 1 s (keep) with decision window 3 s: WARM_TICKS=1, WINDOW_TICKS=2 matches the literature; raise WINDOW_TICKS to 3-4 (3-5 s) if measured noise on slow links is high.
- PENALTY = 1.02 (keep).
- HOLD_TICKS: 15 is untested in literature; keep or reduce to ~10; add early exit if speed drops.
- Add an optional larger first step (+2) when the previous add gave >10% gain (Jamil +5/+1 actions idea).
- MAX_CONNECTIONS = 16 (keep).

## 4. Historical per-host logs to warm-start connection count

### Takeaway
Only HARP (2016) uses history seriously and it needs thousands of logged transfers server-side; the newer Falcon-group papers do not warm-start from history in the text I could read. For Rays, a per-host cache of last converged count is a plausible cheap analogue but unsupported by direct evidence.

### Cited Findings
- HARP: 21K transfers/12 weeks, thresholds, regression; sampling still needed (4 samples), <15 s. [V] [ar5iv](https://ar5iv.arxiv.org/html/1708.03053)
- FStream++ (Arslan): uses dynamic tuning + online profiling + historical analysis; a 2020 thesis advised by Arslan stores past online profiling results to greatly cut convergence time of future runs. [U: search snippet only] [scholarwolf.unr.edu](https://scholarwolf.unr.edu/server/api/core/bitstreams/13d39f7a-9a11-43a9-a358-b0c744c6535e/content)
- AutoMDT/EDT: pre-trained policy generalizes; online fine-tuning changed concurrency ~1%, i.e. a pre-trained prior gets nearly the final answer. [V]
- Observed optima vary by path/time (15, 18, 20, 19 streams on repeated tests), so a cached value is a hint, not a constant. [V] Jamil
- FastBioDL: no warm-start discussion found in text I read. [V negative, limited text]

### Inferences
- Store last-stable connection count per (host, ~hour) in app config; start at min(cached, MAX) instead of 4, and still run the hill-climb at +/-1. Expected benefit: save the ~(cached-4) x 3 s ramp.
- Risk: stale cache if the user changes network; key by network interface/SSID or decay after N days.

### Gaps
- No direct measurement of warm-start benefit in the downloader setting; FStream++ thesis unread.

Rays could:
- Add per-host starting count (initial connections), leaving TICK/WARM/WINDOW/HOLD/PENALTY/MAX unchanged; reset HOLD_TICKS after a warm start to allow one confirming probe.

## Source list
- AutoMDT: https://arxiv.org/html/2508.05546v1
- EDT: https://arxiv.org/html/2511.06159v3
- SPARTA: https://arxiv.org/html/2503.13662v1
- Jamil et al.: https://arxiv.org/html/2211.11949 (abs: https://arxiv.org/abs/2211.11949)
- HARP: https://ar5iv.arxiv.org/html/1708.03053
- FastBioDL: https://arxiv.org/html/2508.05511
- Falcon: https://sc21.supercomputing.org/proceedings/tech_paper/tech_paper_pages/pap476.html
- Marlin (ICS'23): https://par.nsf.gov/servlets/purl/10514952
