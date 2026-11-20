# Download performance research for Rays

Compiled 2026-11-20 via web search and page fetches only. Verification tags:
- [V] numbers read in a fetched page or search snippet of the paper or its abstract.
- [S] numbers from a secondary summary (slides, blog, course notes); check the paper.
- [U] could not open the paper or a numeric result; bibliographic data only, or recalled from memory.

Almost no PDF was read in full. Several PDFs (arXiv 1708.05425, 1812.11255) came back as compressed binary and could not be parsed.

## 1. Parallel TCP streams for bulk transfer

1. Hacker, Athey, Noble. "The End-to-End Performance Effects of Parallel TCP Sockets on a Lossy Wide-Area Network." IPDPS 2002, pp. 434-443. https://researchr.org/publication/HackerAN02
   - Finding: parallel flows raise throughput over lossy WAN paths. The paper measures how many flows help before congestion sets in. [U] for numbers: only the abstract-level aim was seen.
2. Hacker, Noble, Athey. "Improving Throughput and Maintaining Fairness using Parallel TCP." IEEE INFOCOM 2004. http://www.ieee-infocom.org/2004/Papers/52_1.PDF
   - Finding: plain parallel TCP gets its gain by taking bandwidth from competing flows when the bottleneck is full. The authors propose a fairer variant. [U] for numbers; abstract text came from an indexing site.
3. Yildirim, Arslan, Kim, Kosar. "Application-Level Optimization of Big Data Transfers through Pipelining, Parallelism and Concurrency." IEEE Trans. Cloud Computing 4(1), 2016, pp. 63-75. https://researchconnect.buffalo.edu/en/publications/application-level-optimization-of-big-data-transfers-through-pipe/ (preprint https://arxiv.org/pdf/1708.05425.pdf, unreadable here)
   - Finding: it models pipelining (small files), parallelism (per-file streams) and concurrency (files in flight) and gives per-dataset guidelines. It tunes by file size and BDP. [U] for numbers.
4. Related: Yildirim et al., Euro-Par 2013, "dynamic protocol tuning". https://cse.buffalo.edu/faculty/tkosar/papers/europar_2013.pdf [U]

Takeaway (consistent across the sources I could read): parallelism helps when a single flow is limited by loss, RTT or a window cap. It is unfair to others when the bottleneck is shared. A single large file over a clean path often gains little past a few streams.

## 2. Dynamic and adaptive tuning

1. Arifuzzaman, Arslan. "Online Optimization of File Transfers in High-Speed Networks" (Falcon). SC '21. https://sc21.supercomputing.org/proceedings/tech_paper/tech_paper_pages/pap476.html Journal version: "Falcon: Fair and Efficient Online File Transfer Optimization," IEEE TPDS 2023. https://par.nsf.gov/biblio/10419638-falcon-fair-efficient-online-file-transfer-optimization
   - Finding [V, abstract-level]: 2-6x higher throughput than prior tools on up to 40 Gbps testbeds. It finds a good concurrency in about 20 s. Online hill climbing, gradient descent or Bayesian search runs on a utility function that penalises overhead, and competing agents converge to a Nash equilibrium (fairness). Authors' own testbeds only.
2. Swargo, Arifuzzaman, Arslan. "Adaptive Parallel Downloader for Large Genomic Datasets" (FastBioDL). arXiv 2508.05511, Aug 2025 (preprint, not peer reviewed). https://arxiv.org/html/2508.05511v1
   - Finding [V]: a plain HTTP/FTP client tunes concurrency online. Utility is throughput / k^concurrency with k=1.02, gradient descent, 3-5 s probe windows. Gradient descent beat Bayesian by about 20% in copy time. It was up to 4x faster than SRA prefetch/pysradb (e.g. 989 vs 518 Mbps) and 1.3-2.1x faster than fixed concurrency at 10-20 Gbps. This is the closest match to Rays's model.
3. Arslan, Kosar. "High-Speed Transfer Optimization Based on Historical Analysis and Real-Time Tuning." IEEE TPDS 2018. Related: "A Two-Phase Dynamic Throughput Optimization Model for Big Data Transfers," https://arxiv.org/pdf/1812.11255 [U]: the PDF was unreadable and I did not confirm the numbers.

Takeaway: all show that a penalty on extra streams in the utility function stops over-parallelising, and that probing windows of a few seconds are enough.

## 3. QUIC/HTTP3 vs TCP+TLS for large downloads

1. Zhang, Jin, He, Hassan, Mao, Qian, Zhang. "QUIC is not Quick Enough over Fast Internet." WWW 2024. https://arxiv.org/html/2310.09423v2
   - Finding [V]: HTTP/3 has up to 45.2% lower data rate than HTTP/2 on fast links. Lightweight clients (curl, quic_client) match HTTP/2 below about 600 Mbps; Chrome falls behind from about 500 Mbps and reaches about 97% CPU. The cause is receiver-side cost: no UDP GRO (about 744K vs 58K packets processed per transfer) and user-space ACK generation (about 3.0 of 8.7 s of reader time in a 1 GB download). Suggested mitigations: UDP GRO, delayed ACKs, recvmmsg, multi-threaded download.
2. Yu, Benson. "Dissecting Performance of Production QUIC." WWW 2021, pp. 1157-1168. https://doi.org/10.1145/3442381.3450103 (PDF: https://cs.brown.edu:443/~tab/papers/QUIC_WWW21.pdf)
   - Finding [V, partial]: Google, Facebook and Cloudflare QUIC differ widely. Most differences come from implementation and configuration, not from QUIC itself. QUIC does not automatically beat TCP. Exact numbers [U].
3. Kakhki, Jero, Choffnes, Nita-Rotaru, Mislove. "Taking a Long Look at QUIC." IMC 2017. https://www.cl.cam.ac.uk/teaching/1011/R02/papers/imc17-final39.pdf
   - Finding [V, abstract-level]: QUIC generally beats TCP, but it has issues with window sizes, reordered packets and many small objects. It does worse on mobile. A QUIC proxy helps large objects under loss. It wins against TCP partly through a more aggressive CUBIC window. Numbers [U].
4. Langley et al. "The QUIC Transport Protocol: Design and Internet-Scale Deployment." SIGCOMM 2017. https://doi.org/10.1145/3098822.3098842
   - Finding [V]: search latency -8.0% desktop and -3.6% mobile; YouTube rebuffer -18.0% desktop and -15.3% mobile. The gains come from handshake savings and faster loss recovery, which are latency and tail effects, not bulk throughput. [S] for the attribution.

Takeaway: QUIC's wins are handshake, loss recovery and mobility. For a single large file on a clean fast link it is neutral or worse because the receiver's CPU is the limit.

## 4. Congestion control (BBR vs CUBIC); what a receiver controls

1. Cardwell, Cheng, Gunn, Yeganeh, Jacobson. "BBR: Congestion-Based Congestion Control." ACM Queue 14(5), 2016. [U]: I only saw a blog summary of it (https://blog.acolyer.org/2017/03/31/bbr-congestion-based-congestion-control/). BBR does not use loss as the signal.
2. Ware, Mukerjee, Seshan, Sherry. "Modeling BBR's Interactions with Loss-Based Congestion Control." IMC 2019, pp. 137-143. https://www.cs.cmu.edu/~srini/papers/2019-Ware-imc
   - Finding [V, via search snippets]: one BBR flow takes a fixed share (about 40%) of the link against up to 16 Cubic/Reno flows, whatever the number of competitors. The model predicts BBR's throughput with 5-8% median error.
3. Scholz et al. "Towards a Deeper Understanding of TCP BBR Congestion Control." IFIP Networking 2018. https://www.net.in.tum.de/fileadmin/bibtex/publications/papers/IFIP-Networking-2018-TCP-BBR.pdf [U]: not opened, and the search did not confirm the exact title.

Receiver-side points:
- The receiver does not pick the sender's congestion control. Server-side CUBIC or BBR is out of Rays's control.
- The receiver controls the advertised window (reading speed, buffer size), the number of connections, and how it reads.
- A BBR server share of about 40% against Cubic flows also means opening more connections to a BBR server may yield no extra share. This is my inference from the paper, [U].
- Mathis et al. 1997 (throughput is roughly MSS/(RTT*sqrt(p))) explains why parallel streams help on lossy paths. [U]: cited from memory, not fetched.

## 5. Multi-source, multi-CDN, mirrors and multipath

1. Raiciu et al. "How Hard Can It Be? Designing and Implementing a Deployable Multipath TCP." NSDI 2012, pp. 399-412. https://www.usenix.org/conference/nsdi12/how-hard-can-it-be-designing-and-implementing-deployable-multipath-tcp
   - Finding [S]: one slow subflow can drag throughput down unless buffer tuning and reordering are handled. A naive design would break on about a third of paths because of middleboxes. Numbers [U].
2. De Coninck, Bonaventure. "Multipath QUIC: Design and Evaluation." CoNEXT 2017. https://inl.info.ucl.ac.be/publications/multipath-quic-design-and-evaluation.html
   - Finding [V, abstract-level]: MPQUIC can beat MPTCP, and is better in lossy scenarios. In a 20 MB Mininet test, two paths gave faster downloads than single-path. Exact times [U].
3. Swargo et al. 2025 (see section 2) uses parallel streams to a single server only. I found no peer-reviewed, measured study of multi-mirror or multi-CDN range-splitting for ordinary downloads. This is a gap: treat it as engineering practice, not an evidence-backed result.

Takeaway: multipath helps when paths are independent (Wi-Fi plus Ethernet/cellular, or different servers). Reordering and slow paths need work stealing, which Rays already has. Mirrors need hash/ETag verification, which I did not research.

## 6. Client receive-path costs

1. Cai, Agarwal et al. "Understanding Host Network Stack Overheads." SIGCOMM 2021. https://cs.cornell.edu/~ragarwal/pubs/network-stack.pdf
   - Finding [V, via snippets]: with offloads, a single Linux core reaches about 42 Gbps. Receiver-side processing becomes the bottleneck far before the sender; the kernel-to-user copy dominates. Throughput per core drops about 43% with many short flows and about 24% when the BDP outgrows the cache. This is Linux with 100 Gbps NICs, not macOS.
2. Fisk, Feng. "Dynamic Right-Sizing in TCP." LANL tech report / OSTI. https://www.osti.gov/servlets/purl/786912 [U]: only fragments seen. It is the basis of receive-buffer autotuning.
3. Practitioner sources (not peer reviewed): Cloudflare on receive-buffer behaviour (https://blog.cloudflare.com/when-the-window-is-not-fully-open-your-tcp-stack-is-doing-more-than-you-think/). Autotuning grows the window up to the tcp_rmem maximum based on how fast the application reads. A slow reader shrinks the window.
4. Zhang et al. 2024 (section 3) is also the key user-space vs kernel cost result: QUIC's missing GRO and user-space ACKs cost about 3x the packets and a lot of CPU.

I found no peer-reviewed study of the macOS receive path. macOS autotuning (net.inet.tcp.autorcvbufmax) and whether Network.framework or quinn/reqwest HTTP/3 benefit from UDP GRO on macOS are unverified. Do not assume Linux numbers apply.

## What this means for Rays

Priority order, highest first.

1. Keep HTTP/3 behind a flag and default it off for large single-file downloads on fast links. The 2024 WWW paper shows up to 45% lower throughput, with a gap above about 500-600 Mbps and receiver CPU saturating. Enable it when the path is lossy, mobile or high-RTT, or when handshake savings matter (many small files). Benchmark on macOS before trusting these numbers.
2. Tune concurrency online with a utility that penalises extra connections (throughput / k^n, k about 1.02), probing in 3-5 s windows, with gradient descent. This matches the "add while aggregate speed rises" design and is supported by Falcon and FastBioDL. Add a back-off step when adding a connection does not raise speed by a margin, and cap at 16.
3. Cap parallelism for fairness and politeness. Parallel TCP wins by taking share from other flows (Hacker 2004). Default to a modest N (e.g. 4-8) per host, and respect 429/503 per-host back-off, which Rays already does. Start low and ramp, since the optimal N on a clean path is small. I could not verify an optimal-N figure.
4. Use pipelining or connection reuse and fewer, longer ranges for many small files, and adapt chunk size to file size and BDP (Yildirim). I did not verify specific chunk sizes.
5. Make the receive path cheap. Read with large buffers, avoid extra copies, and keep disk writes off the network task so a slow reader does not shrink the TCP window. Test any socket-buffer override on macOS rather than assuming Linux autotuning behaviour. If HTTP/3 stays, consider batched UDP receive.
6. Do not rely on choosing a congestion control. It is a server-side decision. A BBR server may hold a fixed share against Cubic flows, so more connections may not give more bandwidth there.
7. Consider multi-interface or multi-mirror ranges only as a later feature. Evidence is thin outside MPTCP/MPQUIC papers. Work stealing already handles slow paths. Verify content hashes across mirrors.

Gaps to follow up if needed: open the PDFs for Hacker 2002/2004 and Yildirim 2016 for their numbers; look for macOS-specific receive-path measurements; look for peer-reviewed multi-mirror download studies.
