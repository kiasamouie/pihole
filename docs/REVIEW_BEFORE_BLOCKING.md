# REVIEW BEFORE BLOCKING — Samsung QE65Q75CATXXU (192.168.0.197)

**Purpose:** human/ChatGPT review of what the Samsung actually talked to during the 2026-09-20/21 baseline captures.
**These are REVIEW CATEGORIES ONLY. They are NOT firewall rules. They are NOT Pi-hole denylist changes. Nothing has been or will be blocked from this document without a separate, explicit, per-item test phase.**

Method: 6 labelled 10-min sessions captured through the TVGuard one-arm gateway in MONITOR mode (DNS via Pi-hole, all attributed to `.197`, 325 queries / 46 domains, 0 blocked). Cross-session comparison in `reports/06-session-comparison.md`; full evidence in `reports/06-samsung-live-baseline.md`.

**Caveats on the dataset itself:**
- `plex`, `voice`, `standby` sessions had **no real interaction** (TV silent / left on). Their data is "unattended TV on", not those activities.
- `idle` and `youtube` windows: video was actually playing during/around "idle" (178 MB media + QUIC), labels drifted — normal for a real household.
- All classifications below separate: **observed fact** (what the captures show) from **inference** (what it probably is) from **classification** (our working label + confidence). Confidence is honest, not aspirational.

---

## KEEP / PROBABLY ESSENTIAL

Block any of these and the TV or its apps break. Do not touch.

| destination | observed fact | inference | confidence |
|---|---|---|---|
| `www.youtube.com`, `rr*---sn-*.googlevideo.com`, `i.ytimg.com`, `yt3.ggpht.com`, `yt3/lh3.googleusercontent.com`, `www.gstatic.com`, `tools.google.com`, `clients1.google.com` | queries + heavy UDP/443 (QUIC) to 142.251/142.250.x in every media window | YouTube app + video CDN | high |
| `img-resize-cdn-prod.samsungnyc.com` (104.18.x, Cloudflare) | youtube 6, casting 4, voice 2 queries | Samsung app-store/UI image CDN | medium |
| `time.samsungcloudsolution.com` (23.97.174.104, Azure) | casting 4 queries | NTP/time service | medium |
| `lcprd1.samsungcloudsolution.net` (34.160.212.185, Google) | all active sessions; 100k+ pkt persistent flow | Samsung service (purpose unverified but persistent and stable) | low |
| `cdn.samsungcloudsolution.com` (62.252.115.x, NTLI) | youtube 1, casting 1 | Samsung content delivery | low |
| `play.samsungcloud.com`, `api.samsungcloud.com` (AWS) | casting 2+2 queries | Samsung app platform / Play Store | medium |
| `gld.push.samsungosp.com` (AWS) | idle, youtube, casting | Samsung push notifications | medium |
| `tvpnlinupepgpeu.samsungcloud.tv` (99.86.12.x, CloudFront) | 12 queries in the "standby" (unattended) window — heaviest domain there | TV EPG (electronic programme guide) | medium |
| `osb-*.samsungqbe.com`, `gpm.samsungqbe.com` (AWS/CloudFront) | casting 17–41 queries across the family | Samsung QBE service hubs (onboarding, auth, messaging) | low |
| `unagi-eu/na.amazon.com`, `api.amazon.co.uk` (AWS) | idle 6, youtube 2, casting 2, standby 2 | Alexa/Amazon integration on TV | medium |
| `mediaservices.cdn-apple.com` (NTLI) + mDNS `224.0.0.251:5353` + LAN `:32400` flow | casting window | casting/mirroring (Apple or Plex) | medium |
| `d1itljbfuaik2i.cloudfront.net` | casting 2 | generic AWS CDN (app content) | low |
| `:5229` TCP channels (AWS: 52.31.x, 54.89.x, 63.34.x, 108.128.x, 34.x) | persistent, very high reply volume, every active window | Samsung service channels — **unverified purpose, keep until characterised** | low |
| `194.168.4.100:53` (Virgin resolver) | 3× UDP/53 in idle | TV trying to use vendor DNS — **handled by transparent DNAT to Pi-hole, not a block candidate** | high (that it happened) |

## UNKNOWN / NEED MORE DATA

| destination | observed | why unknown | next step |
|---|---|---|---|
| `fc.samsungcloud.tv` (216.137.53.x) | 30 queries in casting (heaviest Samsung domain) | purpose unverified; burst when apps opened | research + a repeat app-launch session |
| `mobile-data.onetrust.io` (Cloudflare) | 2 queries in casting | OneTrust consent platform, but which app's consent? | more sessions |
| `213.104.27.12/13` (Virgin/NTLI) | idle flows | possibly Hub-adjacent service | identify the requesting domain |
| `global.telemetry.insights.video.a2z.com`, `api.amazonvideo.com`, `qgmg.api.amazonvideo.com`, `avpk-*.zaz.api.amazonvideo.com`, `minerva.devices.a2z.com` (AWS) | live query log 09-21 (Prime Video app was open) — **not in any baseline session** | name suggests Prime Video API + telemetry; unverified | run an `amazonvideo` session |
| `:5229` channels (also listed above) | — | — | see above |

## LIKELY ANALYTICS

| destination | observed | reasoning | confidence |
|---|---|---|---|
| `eligibility-panelresearch.googlevideo.com` (142.251.29.x, Google) | casting 2 queries (FORWARDED) | YouTube research-panel eligibility check; analytics-adjacent, part of the YouTube app | medium |

## LIKELY ADVERTISING

All four families observed only with app/YouTube activity; none is needed for video playback itself.

| destination | owner | observed | confidence |
|---|---|---|---|
| `googleads.g.doubleclick.net` | Google | idle + casting, incl. UDP/443 | high |
| `static.doubleclick.net` | Google | casting | high |
| `catalyst.adgrx.com`, `rtb.adgrx.com`, `tvx.adgrx.com` | adgrx (RTB exchange) | youtube + casting | medium |
| `rtb-config.samsungads.com`, `tvp-ads-log.samsungads.com` | Samsung Ads | casting | medium |

## LIKELY TELEMETRY

| destination | owner | observed | confidence |
|---|---|---|---|
| `log-ingestion-eu.samsungacr.com` | Samsung — **ACR = Automatic Content Recognition** (on-screen content fingerprinting; verified against Samsung support material + security press) | **all 5 active sessions** — the steady heartbeat | high |
| `log-config.samsungacr.com` | Samsung (ACR config; Atos/AWS) | casting | high |
| `qoe.samsungcloud.tv` | Samsung (QoE measurement) | casting | medium |
| `nrdp.logs.netflix.com` | Netflix (remote diagnostics) | idle + youtube (Netflix app context) | medium |

## VOICE-CORRELATED

**Honesty note: no real voice action occurred in the "voice" session, so nothing here is isolated to a voice action.** What we have:

| destination | observed | relationship | confidence |
|---|---|---|---|
| `prd-euw1-ucs.aibixby.com` (AWS) | idle 8q, youtube 4q, casting 4q — **persistent background channel in every active session** | Bixby (Samsung voice assistant) cloud — active with or without microphone use; this is *infrastructure*, not "voice was used" | high (that it's Bixby); unknown (what it sends) |
| `provisioning-use2.mgmt.aibixby.com` (AWS us-east) | casting 4q | Bixby provisioning | medium |

**A real voice session is required before any decision on these.** Do not block them on hostname similarity.

## SAFE CANDIDATE FOR FUTURE BLOCK TEST

Ordered, one at a time, each with a breakage watch (TV function re-checked after each). This is a *proposal for a later phase*, not an approval:

1. `log-ingestion-eu.samsungacr.com` + `log-config.samsungacr.com` (ACR) — highest privacy value, clearly non-essential to playback; alternative: disable ACR in TV settings
2. `googleads.g.doubleclick.net` + `static.doubleclick.net`
3. `catalyst/rtb/tvx.adgrx.com`
4. `rtb-config/tvp-ads-log.samsungads.com`
5. `eligibility-panelresearch.googlevideo.com`
6. `nrdp.logs.netflix.com`
7. `qoe.samsungcloud.tv`

**Not safe yet:** aibixby (needs voice baseline), samsungqbe/osb/5229 (needs characterisation), onetrust/fc.samsungcloud.tv/a2z (unknowns), EPG (needed for TV viewing).

---

### Dataset gaps to fix before the block test

- [ ] real `plex` session (play a title)
- [ ] real `voice` session (use the mic)
- [ ] real `standby` session (power off → wait → power on)
- [ ] optional `amazonvideo` session

Commands: `sudo scripts/tv-session.sh samsung <label> 10m`, then `python3 scripts/compare-tv-sessions.py <dir1> <dir2> --out FILE`.
