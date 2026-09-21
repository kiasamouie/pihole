# 06 — Samsung Live Baseline (evidence collection only)

- **Date:** 2026-09-20/21 (all times UTC unless noted)
- **TV:** Samsung QE65Q75CATXXU (Tizen), `192.168.0.197`, MAC `1C:86:9A:AA:8E:96`
- **Path under test:** `Samsung → kiaserver .128 (TVGuard NAT, MONITOR mode) → Virgin Hub .1 → Internet`; DNS `Samsung → Pi-hole .128`
- **Mode throughout: MONITOR. No new blocking was added. No Pi-hole denylist entries were added. No TV config was changed.**

## Executive Summary

**The full live path works.** The Samsung is demonstrably routed through kiaserver: kernel `TVGUARD-NEW` logs, conntrack NAT entries (return leg addressed to `192.168.0.128`), and nftables counters all confirm it, and return traffic provably traverses kiaserver (MASQUERADE, not SNAT-to-hub). DNS is fully attributed to `192.168.0.197` in Pi-hole (325 queries across 6 sessions, 46 unique domains, **0 blocked**).

Six labelled sessions were captured. Three of them (youtube, casting, idle) contain genuinely useful data. Three (plex, voice, standby) had **no real user interaction** — the TV was silent or left on — and are recorded honestly as such rather than labelled with the activity that didn't happen. The casting window was the richest: it captured real screen-mirroring traffic, Samsung service hubs, and the full ad/telemetry landscape in one window.

Key findings:

- The TV maintains a steady background "heartbeat" in every active state: `*.samsungacr.com` (ACR — Samsung's Automatic Content Recognition, i.e. fingerprinting of what is on screen), Bixby (aibixby.com) channels, a persistent TCP/5229 service to AWS (Dublin), and push channels.
- Ad infrastructure (doubleclick, adgrx RTB, samsungads) and QoE telemetry (qoe.samsungcloud.tv, nrdp.logs.netflix.com) were observed.
- One DNS-bypass-relevant behaviour was observed: 3× `UDP/53 → 194.168.4.100` (Virgin's internal resolver — the same one kiaserver itself uses). TVGuard's transparent DNAT redirected it to Pi-hole, so the TV continued working and we retained visibility. This is the exact behaviour the design anticipates.
- No DoT (853), no 8.8.8.8/1.1.1.1, no other resolver was observed — but in a ~1h window this is "not observed", not "does not exist".
- No IPv6 bypass path exists today (no Router Advertisements, no global TV address; verified by capture).
- Heavy QUIC (UDP/443) use by YouTube/Google — **must not be blanket-blocked**.
- Existing Plex, Samba, Transmission, SSH, invoice stack, and all pre-existing firewall state remain untouched; final health check passed.

## Live Path Proof

Independent signals, all agreeing:

1. **Kernel log (TVGUARD-NEW, 23:45–23:46 UTC 2026-09-20):**
   ```
   SRC=192.168.0.197 DST=54.194.205.84:443 ... [SYN]      (TV → Internet, new conn)
   SRC=192.168.0.197 DST=172.18.0.2:53 ...                (DNS, after DNAT)
   SRC=192.168.0.197 DST=52.31.176.228:5229 ...
   SRC=192.168.0.197 DST=63.34.205.144:5229 ...
   ```
   The `TVGUARD-NEW` log rule sits in the `tvguard` forward chain and matches **only** `ip saddr @tvs` → this is TV traffic, not any other client.
2. **Conntrack proves the NAT (return leg via kiaserver):**
   ```
   tcp ESTABLISHED src=192.168.0.197 dst=63.34.205.144 dport=5229
                       src=63.34.205.144 dst=192.168.0.128 dport=5229 [ASSURED] 431732 pkts
   ```
   The reply side of the tuple is addressed to **192.168.0.128**, not the TV — this is only possible if kiaserver performed MASQUERADE and is in the return path.
3. **nftables counters (reconstructed from raw `nft-counters-*.txt` per session, no resets occurred):**

   | window (UTC) | TV→Internet out | Internet→TV reply |
   |---|---|---|
   | idle 21:34–21:44 | +13,809 pkts / +2.01 MB | +140,938 pkts / +177.8 MB |
   | youtube 21:48–21:58 | +2,743 / +296 KB | +7,960 / +11.6 MB |
   | plex 22:00–22:10 | 0 | +42 / +5.2 KB (tail of a closing flow) |
   | casting 22:26–22:36 | +194,980 / +11.6 MB | +410,545 / +812 MB |
   | voice 23:23–23:28 | +266 / +43.7 KB | +177 / +236 KB |
   | standby 23:29–23:39 | +1,439 / +126 KB | +858 / +1.8 MB |

   Note: the postrouting MASQUERADE counter counts **new-connection packets only** (established flows NAT through conntrack without re-matching the rule), which is why it shows ~2,026 pkts in total rather than the full volume. The forward-chain deltas above are the reliable aggregate.
4. **TV→LAN rule counter = 0** — no TV traffic was forwarded LAN-ward; the same-subnet TV↔LAN traffic goes direct at layer 2 (see Local Traffic / Limitations).
5. **Continuous confirmation:** at 08:43 UTC 2026-09-21 three ESTABLISHED TV flows were present (142.251.153.4:443, 63.34.205.144:5229, 34.160.212.185:443); at 08:57 UTC a further flow `192.168.0.197 ↔ 108.128.84.11:5229` was live. The TV keeps working through this path for days.
6. **No spillover:** ordinary LAN devices do not match `@tvs` (the set contains only `.197` and `.90`), so no other client's traffic is forwarded, logged, or NATed. UFW shows exactly the two intended per-TV forward rules.

## DNS Proof

- 325 queries logged across the six sessions, **all attributed to client `192.168.0.197`** (verified with `scripts/show-dns-activity.py 192.168.0.197` and the per-session `dns.csv` files). None were misattributed to `172.18.x` (Docker bridge) or `.128` itself.
- Why attribution is clean: the TV's non-local DNS is DNATed (prerouting, `tvguard`) to the Pi-hole container IP `172.18.0.2:53`. That traffic exits via the Docker bridge, **not** `enp2s0`, so the postrouting MASQUERADE does not rewrite the source — Pi-hole sees the real TV IP.
- Example (live, 08:57 UTC 09-21): `fc.samsungcloud.tv`, `unagi-eu.amazon.com`, `osb-apps-v2.samsungqbe.com`, `time.samsungcloudsolution.com`, `api.amazonvideo.com` — all client `.197`.
- Per-session query counts: idle 71 · youtube 43 · plex 0 · casting 167 · voice 12 · standby 32 (46 unique domains total).

## Functionality

| function | exercised? | what was observed |
|---|---|---|
| Home screen | **YES** | all windows; YouTube home + app browsing visible in DNS/flows |
| YouTube | **YES** (browsing; video clearly played at some point) | the *idle-labelled* window shows ~178 MB of media download and many QUIC video-edge flows — video was active during/around that window; the youtube-labelled window is lighter (11.6 MB) — session labels and actual use didn't perfectly line up, which is normal |
| Plex | **NO — TV was completely silent** (0 flows, 0 DNS). User absent. Nothing was tested |
| Casting | **YES** | genuinely active: mDNS `224.0.0.251:5353`, a direct LAN flow `192.168.0.197 → 192.168.0.128:32400` (Plex), `mediaservices.cdn-apple.com` (Apple mirroring infrastructure), plus Samsung support services |
| Voice | **NO — no voice interaction occurred**; the TV was left on YouTube home. No voice-correlated traffic can be isolated from this session |
| Standby | **NO — the TV was never put to standby**; it stayed on. The "standby" window is actually "left on, unattended" background traffic |

No infrastructure errors were seen in any window: no repeated DNS failure, no TCP resets from the path, no NAT failure, no gateway-unreachable. The TV reported "connected" and every observation above confirms the path end-to-end.

## Sessions Captured

All under `captures/` (git-ignored, root-owned). Each has `metadata.json`, `dns.csv`, `connections.csv`, `summary.md`, `nft-counters-{start,end}.txt`, `pihole-queries.json`, `events.log`.

| session | window (UTC 2026-09-20) | dir | flows | unique out dst | DNS |
|---|---|---|---|---|---|
| idle | 21:34:39–21:44:39 | `20260920-213439-samsung-idle` | 282 | 30 | 71 |
| youtube | 21:48:03–21:58:03 | `20260920-214803-samsung-youtube` | 62 | 26 | 43 |
| plex | 22:00:15–22:10:15 | `20260920-220015-samsung-plex` | **0** | 0 | 0 |
| casting | 22:26:50–22:36:50 | `20260920-222650-samsung-casting` | 354 | 65 | 167 |
| voice | 23:23:59–23:28:59 | `20260920-232359-samsung-voice` | 17 | 7 | 12 |
| standby | 23:29:43–23:39:43 | `20260920-232943-samsung-standby` | 41 | 15 | 32 |

Full cross-session comparison: `reports/06-session-comparison.md` (generated by `scripts/compare-tv-sessions.py`).

## DNS Overview

46 unique domains across the six sessions. Groups:

- **YouTube/Google (core):** `www.youtube.com`, `*.googlevideo.com` (rr1–rr7 edges), `i.ytimg.com`, `yt3.ggpht.com`, `yt3/lh3.googleusercontent.com`, `www.gstatic.com`, `tools.google.com`, `clients1.google.com`, `static/cast-v2.google.com`
- **Samsung platform:** `fc.samsungcloud.tv` (30q in casting), `qoe/tvpnlinupepgpeu.samsungcloud.tv`, `lcprd1.samsungcloudsolution.net`, `time.samsungcloudsolution.com`, `cdn.samsungcloudsolution.com`, `play/api.samsungcloud.com`, `gld.push.samsungosp.com`, `img-resize-cdn-prod.samsungnyc.com`, the `osb-*/gpm.samsungqbe.com` hub family, `*.samsungacr.com`, `provisioning-use2.mgmt.aibixby.com`
- **Ads:** `googleads.g.doubleclick.net`, `static.doubleclick.net`, `catalyst/rtb/tvx.adgrx.com`, `rtb-config/tvp-ads-log.samsungads.com`, `mobile-data.onetrust.io`
- **Third-party apps:** `unagi-eu/na.amazon.com`, `api.amazon.co.uk` (Alexa/Amazon), `nrdp.logs.netflix.com`, `mediaservices.cdn-apple.com` (casting), `d1itljbfuaik2i.cloudfront.net`
- **Reverse lookups** (`*.in-addr.arpa`) make up a visible share — normal Tizen behaviour.

## Internet Destinations

Owner/ASN from RDAP (no whois installed; `rdap.org`):

| range | owner | used by (observed) |
|---|---|---|
| 142.250–142.251.x, 172.217.76.x, 172.217.24.x, 192.178.223.x, 34.160.212.185, 34.240/34.241/34.243/34.247/34.253.x | Google | YouTube video/thumbnails/ads, `lcprd1` Samsung service |
| 18.x/20.x/21.x/3.x/52.x/54.x/99.80–99.86.x/108.x/172.64.x (various) | AWS (incl. Dublin eu-west-1) / CloudFront / Cloudflare | Samsung service hubs, ACR, Bixby, adgrx, samsungads, Netflix nrdp, OneTrust |
| 213.104.27.12/13, 62.253.3.x, 62.252.115.x | Virgin Media / NTLI (UK) | `194.168.4.100` (Virgin resolver — DNATed), `mediaservices.cdn-apple.com`, `cdn.samsungcloudsolution.com` |
| 23.97.174.104 | Microsoft Azure | `time.samsungcloudsolution.com` (NTP/time service) |
| 35.169.253.43, 34.197.82.150, 3.234.95.195 | Atos / AWS | `log-config.samsungacr.com` |
| 2.16.55.209, 2.21.64.170, 2.23.210.x | Akamai | `img-resize-cdn-prod.samsungnyc.com` etc. |
| TCP/5229 hosts (52.31.x, 54.89.x, 63.34.x, 108.128.x, 34.197.x…) | AWS | the persistent Samsung service channels (purpose unknown, see Unknowns) |

## Local Traffic

- **Plex:** one direct LAN flow `192.168.0.197 → 192.168.0.128:32400` during casting (the Plex server on this box). All same-subnet traffic — including this — flows **directly at layer 2** and does not traverse the TVGuard forward chain, so its volume is not in the NAT counters.
- **mDNS/SSDP:** `224.0.0.251:5353` seen in the casting window (mirroring discovery).
- **Limitation (important):** a one-arm gateway on a switched L2 LAN cannot see or control TV→LAN unicast (it never arrives at us). What this PoC controls is **TV→Internet egress**, not intra-LAN communication. LAN isolation comes later with the dedicated box + VLANs. Do not describe this setup as providing LAN isolation.
- The TV→LAN nftables rule exists for completeness but its counter is 0 — nothing was routed that way.

## Idle / Background Behaviour

With the TV on the home screen and no app action:

- `log-ingestion-eu.samsungacr.com` (ACR ingestion) + `prd-euw1-ucs.aibixby.com` (Bixby) + the :5229 channels + push (`gld.push.samsungosp.com`) + QBE hubs run continuously — this is the baseline heartbeat that appears in **every** active window.
- ~178 MB of media was downloaded in this window (YouTube home previews or an active video — video was in fact running around this time).
- 3× UDP/53 to `194.168.4.100` (Virgin resolver) — the only non-local DNS target seen anywhere; transparently DNATed to Pi-hole.
- Ad endpoints (doubleclick UDP/443) are already active on the home screen.

## YouTube Behaviour

- Video edges `rr*---sn-*.googlevideo.com` over **QUIC (UDP/443)** to `142.251.x/142.250.x` in every media window.
- Ad stack: `catalyst.adgrx.com` (youtube window), `rtb/tvx.adgrx.com`, `static.doubleclick.net`, `googleads.g.doubleclick.net` (RTB ad exchange + ad delivery — this is YouTube/TV ads, not Samsung telemetry).
- `eligibility-panelresearch.googlevideo.com` (YouTube research-panel eligibility — analytics-ish).
- `img-resize-cdn-prod.samsungnyc.com` (Samsung image CDN, Cloudflare) present while browsing.

## Plex Behaviour

**None.** The TV made zero outbound connections and zero DNS queries in the plex window — it was off/silent. The single `:32400` LAN flow seen during *casting* shows the TV↔Plex path works when active. A real Plex session (user present) is the first re-run on the list.

## Voice-Correlated Behaviour

**No voice action occurred during the "voice" window** (TV left on YouTube home; 17 small flows). Therefore there is **no isolated voice-action signal** in this dataset.

What *is* known from the other windows: `prd-euw1-ucs.aibixby.com` (Bixby UCS cloud, AWS) is a **persistent background channel in every active session** (idle 8q, youtube 4q, casting 4q) — it is voice-infrastructure-adjacent but active regardless of whether the microphone is used. `provisioning-use2.mgmt.aibixby.com` appeared in casting (Bixby provisioning). **We cannot say what a real voice command adds until a real voice session is captured.** No destination here is labelled "transcript" — that would be an unsupported claim.

## Standby Behaviour

**The TV was never put to standby** — it stayed on. The "standby" window (41 flows, 32 DNS) is "unattended, screen on" traffic. Notable: `tvpnlinupepgpeu.samsungcloud.tv` (EPG — TV programme listings, AWS CloudFront 99.86.12.x, 12 queries, the heaviest domain in that window) plus the standard heartbeat (ACR, Bixby, :5229). True standby/power-cycle behaviour (wake-up bursts are where TVs famously phone home) is **not captured** and must be a re-run.

## Existing Pi-hole Blocks

**Zero.** Across all 325 queries the only statuses were `CACHE`, `CACHE_STALE`, `FORWARDED`, `IN_PROGRESS`. No domain was rejected by any list in any session, and no TV function appeared impaired. (Baseline gravity list remains active; it simply had nothing to match in this traffic.) The TV-Monitor/TV-Strict groups exist but the Samsung is not yet assigned to a per-TV group — it currently sits in Default with the baseline gravity list only.

## DNS Bypass Observations

| mechanism | observed? | notes |
|---|---|---|
| UDP/53 to non-local resolver | **YES — 3× to 194.168.4.100** (Virgin Media's internal resolver, same as kiaserver's own resolv.conf) during idle. TVGuard's prerouting DNAT sent it to Pi-hole, so it was handled, logged, and attributed to .197. This is exactly the "vendor resolver" case the design anticipates. |
| 8.8.8.8 / 1.1.1.1 / other public DNS | not observed | short window — **inconclusive**, not "absent" |
| TCP/53 non-local | not observed | inconclusive |
| DoT (853) | not observed | inconclusive |
| DoH (443) | not specifically identifiable — DoH would be indistinguishable from normal HTTPS by destination metadata alone | **limitation, not proof** |
| IPv6 DNS | N/A — no IPv6 Internet path exists (see IPv6) |

## QUIC

Heavy use of UDP/443: Google video edges (142.251.x/142.250.x), `googleads.g.doubleclick.net` (192.178.223.x), plus assorted AWS/Cloudflare hosts in the casting window. **QUIC must remain allowed** — YouTube and most modern streaming depend on it, and blocking UDP/443 globally is explicitly out of scope. Enforcement, when it comes, must be per-destination, never per-port.

## IPv6

Re-verified with the live path active (2026-09-20 23:45 UTC + 09-21 morning):

- 3-minute Router Advertisement capture on `enp2s0`: **0 packets**.
- 60-second capture of any IPv6 to/from the TV: **0 packets**.
- No RA from the Virgin Hub → no SLAAC → the TV cannot obtain a global IPv6 address or an IPv6 default route through the Hub.
- **Conclusion: there is currently no plausible IPv6 Internet bypass path for the Samsung.** If the Hub's IPv6 mode changes (e.g. the user enables IPv6 in Hub settings, or a new router is introduced), re-run this check — it is one script away (`scripts/capture-device.sh`).

## Potential Telemetry Candidates

Review table only — **nothing here is blocked or scheduled to be blocked without a later, separate, user-approved test phase.**

| Destination | Owner | Seen during | Evidence | Current classification | Confidence | Safe to test block later? |
|---|---|---|---|---|---|---|
| `log-ingestion-eu.samsungacr.com` | Samsung (ACR) | all 5 active sessions | steady heartbeat in every window; ACR = Automatic Content Recognition — Samsung's on-screen content fingerprinting (verified via Samsung support material + security press, Sagar blog) | telemetry | high | **yes** (top candidate) |
| `log-config.samsungacr.com` | Samsung (ACR) | casting | config fetch for ACR (Atos/AWS) | telemetry | high | yes |
| `qoe.samsungcloud.tv` | Samsung | casting | QoE (quality-of-experience) measurement host | telemetry | medium | yes |
| `nrdp.logs.logs.netflix.com` (nrdp.logs.netflix.com) | Netflix | idle, youtube | Netflix remote-diagnostics logging, present whenever Netflix app context active | telemetry | medium | yes (app-scoped) |
| `googleads.g.doubleclick.net` | Google | idle, casting | ad network delivery, incl. UDP/443 | advertising | high | yes |
| `static.doubleclick.net` | Google | casting | ad technology | advertising | high | yes |
| `catalyst/rtb/tvx.adgrx.com` | adgrx (RTB ad exchange used on Samsung TVs) | youtube, casting | RTB exchange + config | advertising | medium | yes |
| `rtb-config.samsungads.com` | Samsung Ads | casting | TV advertising config | advertising | medium | yes |
| `tvp-ads-log.samsungads.com` | Samsung Ads | casting | ad logging | advertising | medium | yes |
| `eligibility-panelresearch.googlevideo.com` | Google | casting | YouTube research-panel eligibility | analytics | medium | yes |
| `prd-euw1-ucs.aibixby.com` | Samsung Bixby | idle, youtube, casting | persistent Bixby UCS background channel | voice-related | high | **caution** — test only with a real voice session baseline first |
| `provisioning-use2.mgmt.aibixby.com` | Samsung Bixby | casting | Bixby provisioning | voice-related | medium | caution |
| `mobile-data.onetrust.io` | OneTrust (consent platform) | casting | consent/cookie-management service | unknown (consent) | low | no, not yet |
| `fc.samsungcloud.tv` | Samsung | casting (30q — heaviest Samsung domain) | purpose not verified; burst when apps opened | unknown | low | no, not yet |
| `global.telemetry.insights.video.a2z.com` | Amazon (Prime Video) | post-session live only | 4 queries 09-21 while Prime Video context active; **not in any baseline session** | unknown (name suggests telemetry) | low | no — run an `amazonvideo` session first |

## Unknowns

- **TCP/5229 channels** (many AWS IPs, some 100k+ packet long-lived flows, reply-heavy): persistent Samsung service hubs (QBE family). They could be media/session infrastructure — blocking them blind would be reckless. A dedicated probe session + Samsung docs research is needed before touching them.
- `fc.samsungcloud.tv` — 30 queries in one window, purpose unverified (firmware/framework update checks are the leading hypothesis).
- `213.104.27.12/13` (Virgin/NTLI) — resolved for some TV queries during idle; possibly Hub-adjacent services (time/updates). Harmless-looking, unverified.
- Individual roles inside the `samsungqbe.com` family (osb-onboarding vs gpm messaging vs auth) — all likely-essential platform services, but not individually characterised.
- `mediaservices.cdn-apple.com` — consistent with Apple screen mirroring (AirPlay-style) or the Apple TV app; the mDNS+Plex flow in the same window supports "casting was happening", but which device did the mirroring is not identifiable from the server side.
- True **standby/wake** behaviour (power-off burst) and **real voice** behaviour — neither was exercised.
- Whether ACR can be turned off in the TV's own settings (Tizen has an ACR/location-information toggle) — a non-technical lever worth checking in person; we do not have a Samsung account to verify the exact menu path from here.

## Recommended Next Review

1. **Re-run three sessions with real interaction:** `plex` (open the Plex app, play something), `voice` (use the Bixby mic on the remote), `standby` (actually power the TV off, wait, power on). Same commands: `sudo scripts/tv-session.sh samsung <label> 10m`.
2. Optionally add an `amazonvideo` session (Prime Video app) to characterise the a2z domains.
3. Review `REVIEW_BEFORE_BLOCKING.md` with ChatGPT.
4. Suggested **future** test-block order (one at a time, each with a breakage watch, TV function re-checked after each): ACR (`log-ingestion-eu` + `log-config.samsungacr.com`) → doubleclick → adgrx → samsungads → panelresearch → nrdp → qoe. Voice-related and unknowns come last or not at all, and only after real voice/standby baselines exist.
5. Alternative/complement: disable ACR in the TV's own settings if the user prefers a TV-side fix over a network block.
6. Keep monitoring in MONITOR mode until the review is done. No blocking until the user says so.

## Final State at Completion (08:57 UTC 2026-09-21)

- `scripts/health-check.sh`: **ALL CHECKS PASSED**
- TVGuard: `MODE=monitor`, table `ip tvguard` present, 2 ufw route rules, no changes made this session
- Pi-hole: `pihole` container healthy (20h), groups Default/TV-Monitor/TV-Strict/IoT/Trusted/Testing present, no denylist additions, 0 blocked queries in all sessions
- Plex / Samba / Transmission / SSH / invoice stack: running, untouched
- No DHCP listener (:67 absent), no new NAT/forwarding rules, no reboots, no router changes
- Samsung: connected, Internet working, live flows observed through kiaserver at report time
