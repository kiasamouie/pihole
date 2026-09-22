# HaGeZi — LG / webOS Domain Inventory (September 2026 snapshot)

Research date: 2026-09-22. All sources fetched directly (GitHub API / raw files / discussion threads).
Source list: `hagezi/dns-blocklists` → `adblock/native.lgwebos.txt` ("Native Tracker / LG webOS", 5 formats).
Raw (current main): https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/native.lgwebos.txt
List version at time of capture: `2026.0918.2206.12` (221 entries, adblock format).

## Methodology (what hagezi states)

- hagezi (discussion #8697, Jan 2026): "domains originate from tests conducted in the respective regions; the rest were extracted based on domain patterns from top 1M lists." He does **not** own an LG device and said so explicitly on Sep 8, 2026 after the Gamers Nexus fallout: "There are a few issues with the domains here; someone with an LG device would need to test this thoroughly again. I don't own any of these devices."
- Scope statement (hagezi, disc #8697 comment, Sep 10 04:55/10:35, comment id 18384629): the list "blocks native ads and trackers; does NOT block firmware/app updates, IoT, or voice control — it is not a debloat list." He cited the Level1Techs how-to in that comment and recommended disconnecting the TV as the strong option.

## Gamers Nexus trigger event

- Video: "216,000,000 Spy TVs | The LG Smart TV Problem", https://www.youtube.com/watch?v=6IFVTcM28KA (published ~2026-09-07; verified via YouTube oEmbed).
- Companion how-to: Level1Techs "LG TV Block Mini-How-to", https://forum.level1techs.com/t/lg-tv-block-mini-how-to/255178 (created 2026-09-05).

## September 2026 change sequence (the core finding)

Pre-existing list (version `2026.0828.2216.34`, 341 entries, pre-GN) contained: ~150 `*-ad-lgsmartad-com.aws-prd.net` exact hosts, the lge.com NGFTS set (`eic-ngfts.lge.com`, `eic-qt2-ngfts.lge.com`, `kic-ngfts.lge.com`, `kic-qt2-ngfts.lge.com`, `qt2-ngfts.lge.com`, `ruc-ngfts.lge.com` + 4 `.edgekey.net` CDN variants), ~160 `cc.lgsmartad.com`-style hosts, `lgtvcommon.com` subdomains (`ads`, `cdpbeacon`, `homeprv`, `nudge`, `rdl`, `wiseconfig`), `h4g3z1-native.lgwebos.web.app`, `alphonso.tv`, `lgads.tv`.

1. **~Sep 7** — GN video publishes; L1Techs how-to (Sep 5).
2. **Sep 7 19:28** — Timwun requests (post-GN) adding wildcards `*.alphonso.tv, *.lgsmartad.com, *.lgtvcommon.com, *.lgtvsdp.com, *.lgsmartplatform.com, *.nextlgsdp.com, *.ueiwsp.com` → https://github.com/hagezi/dns-blocklists/discussions/8697#discussioncomment-18336219
3. **Sep 8** — hagezi declines blanket changes (no LG device to test with).
4. **Sep 10** — hagezi scope statement + adds: `||*-ad-lgsmartad-com.aws-prd.net^`, `||alphonso.tv^`, `||lgads.tv^`, `||lgsmartad.com^`, `||lgtvcommon.com^`, **`||nextlgsdp.com^`**; suggests OPTIONAL `||lgtviot.com^`, `||lgthinq.com^`; explicitly cites the Level1Techs article.
5. **Sep 11 — issue #11438** (agneevX, https://github.com/hagezi/dns-blocklists/issues/11438): `*.nextlgsdp.com` blocked → TV cannot set system time; YouTube and many apps break. hagezi: "`nextlgsdp.com` is the domain identified in recent spyware investigations as the primary 'call-home' domain" / "SDX telemetry (primary phone-home)" — yet concedes it is mixed functional. Community reports in-thread:
   - vdias (ES): App Store needs `ngfts.nextlgsdp.com` + `eic-gfts.nextlgsdp.com`.
   - AYM958 (IN): `in.nextlgsdp.com` (time), `ngfts.nextlgsdp.com` (store icons), `kic-gfts.nextlgsdp.com` (downloads).
   - L1Techs post #20 (fade, C5/C1 units): blocking `nextlgsdp.com` kills Content Store; exactly `countrycode.nextlgsdp.com` must stay reachable.
   → **Fix in release `37522026.255.32391` (Sep 12):** removed `aic-gfts / eic-gfts / kic-gfts / ngfts / ruc-gfts / ruc-hq-ngfts / ruc-ngfts.nextlgsdp.com` from blocking and **allowed 52 country subdomains**: `aj7, am, at, au, be, bg, br, br7, ca, ch, co, cz, de, dk, ee, eg, es, eu7, fi, fr, gb, gr, hk, hr, hu, id, ie, il, in, it, ja7, jp, lt, me, mx, my, nl, no, nz, ph, pl, pt, ro, ru, se, si, sv, th, tr, us, us7, vn, za`.nextlgsdp.com. Net result: **only `ibs.`, `ibsstat.`, `rdx2.nextlgsdp.com` remain blocked (exact)**; the zone-wide wildcard is gone.
6. **Sep 15 — issue #11474** (jasongodev, https://github.com/hagezi/dns-blocklists/issues/11474): requested blocking of `snu-dev.lge.com, su-dev.lge.com, security.lgtvsdp.com, elastic.lgwebostv.com, www.ueiwsp.com` (citing L1Techs, `hugobatista/lg-tv-ad-block`, `samsapti/LG-webOS-Blocklist`). **hagezi rejected ALL FIVE** with reasoning:
   - `snu-dev / su-dev.lge.com` = OTA *dev* endpoints, not ads/tracking.
   - `ueiwsp.com` = QuickSetAPI, no ad connection.
   - `*.security.lgtvsdp.com` = **DRM/license issuance + device auth — blocking risks breaking DRM playback and Content Store**.
   - `*.elastic.lgwebostv.com` = unclear, possibly an Elasticsearch backend.
   - **KallistoX comment (Sep 15):** 40-min DNS+SNI wire capture on gateway, **OLED55C17LB, webOS 6.0, DE, Sep 2026, all consents declined, ACR/ads/voice off** → observed-and-blocked: `DE.ibs.nextlgsdp.com` (4 DNS + 4 TLS), `EIC.tv.wiselg.com` (2+2); observed-but-kept: `DE.nextlgsdp.com` (11 TLS, "service backbone"), `EIC.wiseconfig.lgtvcommon.com`, `eic.lgtviot.com`; `eic-ngfts.lge.com` + `eic-gfts.nextlgsdp.com` (Akamai) = NGFTS file transfer → a zone-wide `nextlgsdp.com` block breaks firmware updates; region prefixes are **uppercase on the wire** (`DE.`, `EIC.`); the **webOS 6 device never queried `lgtvsdp.com` / `lgsmartad.com` / `lgappstv.com` / `alphonso.tv`** (its traffic went to the `nextlgsdp.com` zone); no DoH/DoT/QUIC observed. Gist: https://gist.github.com/KallistoX/ca0413c63e58799ecdfc516b64d603ff. hagezi: `ibs./ibsstat.` = in-app **billing** infra; `tv.wiselg.com` likely carries NGFTS (functional). KallistoX withdrew the deny request, kept findings as data points.
   - Note the tension (recorded, not resolved): hagezi calls `ibs.*` "billing infrastructure" in #11474 yet the list still blocks `ibs.nextlgsdp.com` + `ibsstat.nextlgsdp.com` exactly.
7. **Sep 11 — issue #11432** (furkan-bayrak, https://github.com/hagezi/dns-blocklists/issues/11432): submitted `ad.lgappstv.com, adsdtvc.com, smart.adtvc.app` (observed on a rooted LG G1, DE, Aug–Sep 2026; 44.8k-packet / 267k-query audit; repo https://github.com/furkan-bayrak/lg-tv-blocklist). **hagezi closed it as dead (verified 2026-09-22, comments 5634133124/5634135626/5634193947):** all three return NXDOMAIN on public resolvers — "Dead domains are not added to my lists." furkan-bayrak confirmed and dropped them. Also mentioned in-thread: `initscr.lge.com` (boot-time setup telemetry, unverified).
8. **Sep 10 — issue #11412** (sertchan, https://github.com/hagezi/dns-blocklists/issues/11412): GN-video-derived list with per-domain annotations: `aic.api.adts.lgtvcommon.com` (300 s ad heartbeat), `aic.cdpbeacon.lgtvcommon.com` (300 s CDP beacon), `aic.cdpsvc.lgtvcommon.com`, `aic.cdplauncher.lgtvcommon.com`, `us.ad.lgsmartad.com` / `us.info.lgsmartad.com` (boot burst), `*.tv.wiselg.com`, `us.emp.lgsmartplatform.com`, `us.lgeapi.com`, `ngfts.lge.com`, `snu.lge.com`, `discovery.meethue.com` (75–90 s; **Philips Hue — third party, not LG**), `ueiwsp.com` (5–10 min UEI QuickSet code DB), plus generic adtech: `pagead2.googlesyndication.com`, `imasdk.googleapis.com`, `static.doubleclick.net`, `cdn-media.brightline.tv`, `na-ssp-pix.adstk.io` (Amazon ads), `cws.conviva.com` (device-fingerprint subdomains), `api.axiom.co`, `api.ipify.org` (public-IP fetch). hagezi replied: see disc #8697 (→ most now covered by the new wildcards).

Older context (pre-2026, relevant to KEEP carve-outs):
- #8696 (Jan 2026): ES/EU coverage gaps.
- #309 (Feb 2023): large LG domain batch. #1123 (Jun 2023): `es/pt.ad.lgsmartad.com`. #995 (May 2023): `aic-gfts.lge.com` breaks app installs. #1216 (Jun 2023): `eic.cdpsvc` / `eic.recommend` needed by store. #1359 (Jul 2023): `gb.lgtvsdp.com` needed for Content Store. #1807 (Nov 2023): `eic.service.lgtvcommon.com` needed.

## Current list (2026.0918) — what is actually blocked now

- **Wildcards:** `||lgsmartad.com^`, `||lgtvcommon.com^`, `||*-ad-lgsmartad-com.aws-prd.net^` (AdBlock `||d^` = apex + all subdomains).
- **Exact (LG-specific):** `alphonso.tv`, `lgads.tv`, `ibs.nextlgsdp.com`, `ibsstat.nextlgsdp.com`, `rdx2.nextlgsdp.com`, `rdx2.lgtvsdp.com`, `h4g3z1-native.lgwebos.web.app` (flagged: name suggests a HaGeZi-own test app on Firebase hosting, possibly not LG telemetry — see notes).
- **Enumerated exact:** ~185 `*.aws-prd.net` LG ad hosts (incl. `-info-lgsmartad-com`, `-rdx2-lgtvsdp-com`, `eu7-info-` variants).
- **NOT blocked** (despite being LG): `*.security.lgtvsdp.com` (DRM), 52 `cc.nextlgsdp.com` (time/store), all `*gfts*` on any zone (firmware/app transfer), `lgtvsdp.com`/`lgappstv.com` (Content Store), the lge.com NGFTS set (removed from list Sep 12 — consistent with "does not block firmware updates"), `*.lgtviot.com` / `*.lgthinq.com` (suggested optional, not in list), `ueiwsp.com`, `elastic.lgwebostv.com`, `snu-dev/su-dev.lge.com`.

## hagezi's other repos

Checked: no separate Samsung-TV / ACR tracker repo. The Samsung list is `adblock/native.samsung.txt` in the same `dns-blocklists` repo (LG overlap not audited — out of scope for this file). Other repos (`dns-servers`, `nrd`, `files`, etc.) contain no LG-specific material.

## Domain inventory with confidence

| Domain / pattern | In current list | Purpose | Confidence | Notes |
|---|---|---|---|---|
| `lgsmartad.com` + wildcard | Yes (`lgsmartad.com^`) | LG ad solutions: ad server, CDP, boot-burst beacons (`us.ad`/`us.info.lgsmartad.com`), `admanager` ~60 s heartbeat | High (multi-source: list + L1T + #11412 + KallistoX) | Wildcard justified — whole zone is ad infra. |
| `*-ad-lgsmartad-com.aws-prd.net` + ~185 exact aws-prd.net hosts | Yes | AWS-hosted LG ad/CDP/ACR backend (`-info-`, `-rdx2-lgtvsdp-com` variants) | High (list + wire captures) | Wildcard `*-ad-lgsmartad-com.aws-prd.net` justified (ad-only suffix); info/rdx2 variants still enumerated exactly. |
| `lgtvcommon.com` + wildcard | Yes (`lgtvcommon.com^`) | Mixed: CDP beacons (`cdpbeacon`, `cdpsvc`, `api.adts` 300 s), `nudge`, `homeprv`, `rdl` (crash-log dir), `netflixvoice` (voice proxy), `qt2-kic.lab` (ThinQ AI lab) — **and functional** `wiseconfig`, `cpauth`, `qcardservice`, `recommend` | Medium-high (list) / contested (KallistoX keeps `wiseconfig` live) | Tension: zone-wide block (HaGeZi/L1T call it "safe") vs KallistoX wire-capture approach of carving out `wiseconfig`. Blocking store-recommendation subdomains is a feature, not a bug. |
| `alphonso.tv` + wildcard | Yes | ACR (Alphonso ad platform). webOS-5-era units still query `prov-lg.alphonso.tv` daily (KallistoX community report); webOS 6 units do not | High (purpose) / Medium (current prevalence) | Wildcard justified. |
| `lgads.tv` | Yes (exact apex) | LG ad network | Medium-high | |
| `ibs.nextlgsdp.com` | Yes (exact) | `ibis_secure` — in-app **billing** per hagezi, though kept blocked (tension recorded) | Medium-high (existence) | Exact-only, deliberately. |
| `ibsstat.nextlgsdp.com` | Yes (exact) | `ibis_stat_secure` — billing stats | Medium-high | |
| `rdx2.nextlgsdp.com` | Yes (exact) | `rdx_secure` — crash-log upload (`rdxd`, `AutoUpload=true`) + ACR | High (list + L1T + KallistoX default tier) | |
| `rdx2.lgtvsdp.com` | Yes (exact) | Legacy (pre-nextlgsdp) ACR/crash path | Medium-high | Predecessor domain; keep for older firmwares. |
| `cc.nextlgsdp.com` (52 country subs) | No — **explicitly allowed** | System time, store icons, app downloads, SDX backbone | High (must keep) | #11438 + L1T #20 (fade, C5/C1). |
| `*gfts.nextlgsdp.com` / `*gfts.lge.com` / gfts on `tv.wiselg.com` | No (carved out Sep 12) | NGFTS firmware/app file transfer | High (must keep) | Zone-wide `nextlgsdp.com` block breaks firmware updates. |
| `*.security.lgtvsdp.com` | No (rejected, #11474) | DRM/license issuance + device auth | High (must keep) | |
| `lgtvsdp.com` / `lgappstv.com` | No | Content Store | Medium-high | Blocking = deliberate trade-off (L1T comments out by default). |
| `*.lgtviot.com`, `*.lgthinq.com` | No (suggested optional) | ThinQ/IoT, push | Medium | hagezi optional; KallistoX keeps `eic.lgtviot.com` reachable. |
| `tv.wiselg.com` | No | Observed in wire capture; hosts NGFTS mirror (app updates/Store) | Medium | "Phones home" ≠ "ad"; aggressive-tier only if TV never uses apps/Store. |
| `ueiwsp.com` | No (rejected) | QuickSetAPI UEI code DB, 5–10 min | Medium | Consent-gated; user opt-in choice. |
| `elastic.lgwebostv.com` | No (rejected) | Unknown; possibly Elasticsearch backend | Low | |
| `snu/su/su-ssl/nsu.lge.com`, `snu-dev/su-dev.lge.com` | No | OTA update notification/download/dev | High (purpose) | Security trade-off if blocked (unpatched RCEs). |
| `h4g3z1-native.lgwebos.web.app` | Yes (exact) | Unknown — Firebase-hosted name suggests HaGeZi's own test app | Low | Flagged, not resolved. |
| `adsdtvc.com`, `smart.adtvc.app`, `ad.lgappstv.com` | No | Observed in rooted G1 captures | Dead | NXDOMAIN on public resolvers as of 2026-09-11 (hagezi verified). |
| `discovery.meethue.com` | No | **Third party** (Philips Hue, 75–90 s poll) | Medium | Not LG infra. |
| `cws.conviva.com`, `api.ipify.org`, `na-ssp-pix.adstk.io`, Google adtech | No | Third-party trackers on TV | Medium | Covered by general ad lists, not LG-specific. |
