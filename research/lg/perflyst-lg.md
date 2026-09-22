# Perflyst/PiHoleBlocklist — LG/webOS section analysis

Research date: 2026-09-22. Source: `SmartTV.txt`, default branch **`master`**, last push **2026-09-09** (≈1k stars, 131 forks).
Verified against the local snapshot `research/github/snapshots/perflyst-smarttv.txt` and a fresh fetch of `raw.githubusercontent.com/Perflyst/PiHoleBlocklist/master/SmartTV.txt` (2026-09-22) — **content identical**.

---

## 1. Repo / list metadata

- File header: `# Version: 13July2023v1` — **stale**: the file has received changes since 2023-07 (the GN/nextlgsdp block was added 2026-09-08/09 via PRs #168/#169), but the version string was never bumped.
- Header instruction: "Make sure to also use the extra RegEx list at `perflyst.github.io/PiHoleBlocklist/regex.list`, which helps remove **regional LG ad domains** among other things" — i.e. the main file deliberately offloads some LG regional ad coverage to a companion regex list.
- LG content location: section `# LG` at line 96 (ends line 377), plus `alphonso.tv` at line 557 under `# Other useless connections from Smart-TV`.
- **No per-domain methodology or provenance** is documented in the file; the only evidence trail is (a) inline `#` comments on commented-out rows, (b) issue references (`#117`, `#134`, `#148`…), (c) PR history.
- Count (verified by line-level inspection 2026-09-22): **276 active LG-related entries** (29 non-cc + 246 two-letter `<cc>.nextlgsdp.com` + `alphonso.tv`) and **2 commented-out** entries. (An earlier manual count of 244 cc / 274 total was corrected to 246 / 276 after re-counting the section lines 130–377: 248 lines = 246 domains + 2 blank.)

## 2. LG section inventory (exact file order)

### 2.1 Block A — lines 97–121 (original list, 2018–2023 era)

| Line | Entry | Status | Purpose / notes |
|---|---|---|---|
| 97 | `ad.lgappstv.com` | active | ad delivery on the `lgappstv.com` app-store CDN family. **Conflict:** furkan-bayrak probed this exact name NXDOMAIN on 2026-09-12 (kept there as decommissioned) — likely stale here |
| 98 | `ibis.lgappstv.com` | active | Ibis Media — LG's ad/ACR vendor |
| 99 | `jp.rdx2.lgtvsdp.com` | active | `rdx2` = unknown/possible ad delivery; **lgtvsdp family = time-sync family** (see §4) — family caveat applies |
| 100 | `jp.lgtvsdp.com` | active | **two-letter cc host inside the time-sync family.** Perflyst comments out `us.lgtvsdp.com` (#117) but actively blocks `jp.` — inconsistent treatment of the same family; would break time sync on JP models that use it |
| 101 | `jp.info.lgsmartad.com` | active | ad-info endpoint, region-scoped (furkan: `info.lgsmartad.<cc>` live in 49/49 country probes) |
| 102 | `lgad.cjpowercast.com.edgesuite.net` | active | **Malformed** (issue #134): should be `lgad.cjpowercast.com` (CJ PowerCast, US ad network) + `edgesuite.net` (Akamai). As written it likely matches nothing |
| 103 | `#ngfts.lge.com # blocks thumbnails from loading in the LG Content Store` | **commented out** | documented breakage — see §4.2 |
| 104 | `smartclip.com` | active | HBBTV ad network — **shared infrastructure** (not LG-specific; also in the HBBTV section as `*.smartclip.net`) |
| 105 | `smartclip.net` | active | same, shared |
| 106 | `smartshare.lgtvsdp.com` | active | name suggests LG SmartShare (screen-share) service on the SDP family; function unproven; lgtvsdp family caveat |
| 107 | `us.ad.lgsmartad.com` | active | ad delivery, US |
| 108 | `us.ibs.lgappstv.com` | active | IBS = in-app billing on the store CDN family → **blocking risks store billing** |
| 109 | `us.info.lgsmartad.com` | active | ad-info endpoint, US |
| 110 | `#us.lgtvsdp.com # #117` | **commented out** | documented breakage — see §4.1 |
| 111 | `us.rdx2.lgtvsdp.com` | active | as line 99, US |
| 112 | `yumenetworks.com` | active | ad network — **shared infrastructure** (general ad tech, not LG-specific) |
| 113 | `aic-ngfts.lge.com` | active | cluster file/update-transfer host (Americas); GN-era addition; also in furkan's 53-entry cluster set |

### 2.2 Block B — lines 122–128 (added 2026-09-08/09, PRs #168/#169, sourced to Gamers Nexus video `youtu.be/6IFVTcM28KA`)

In-file marker: `# Gamers Nexus - LG Smart TV spying`

| Line | Entry | Notes |
|---|---|---|
| 123 | `aic.cdpsvc.lgtvcommon.com` | CDP service (Americas). Stem `cdpsvc` appears **only in Perflyst** — furkan's cluster set has `cdplauncher.`, not `cdpsvc.` |
| 124 | `aic.cdpbeacon.lgtvcommon.com` | ACR beacon (Americas) — **in furkan's 53** (successor of the G1-observed 6-min beacon) |
| 125 | `us.nextlgsdp.com` | US SDP endpoint. `nextlgsdp` family carries time-sync + billing hosts on some models (hagezi#11438; furkan FAQ) — family caveat |
| 126 | `ngfts.nextlgsdp.com` | update transfer on SDP family — in furkan's 53 set (bare form; eic/aic/kic twins enumerated there) |
| 127 | `aic.rdl.lgtvcommon.com` | `rdl` stem appears **only in Perflyst**; function unknown |
| 128 | `aic-gfts.nextlgsdp.com` | file-transfer (Americas) — in furkan's 53 set |

### 2.3 Block C — lines 130–375 (added 2026-09-09, PR #169)

In-file marker: `# Gamers Nexus - LG Smart TV spying - Non-US nextlgsdp.com country codes`

- **246 exact entries** of the form `<cc>.nextlgsdp.com` (not a wildcard row — each host enumerated individually).
- PR #169 claims coverage of all ISO 3166-1 alpha-2 codes **except `ax` (Åland), `bl` (St. Barthélemy), `tl` (Timor-Leste)**; verified 2026-09-22: `ax`/`bl`/`tl` absent, and the set additionally contains the non-standard `xk` (Kosovo) and the retired code `cc` (Cocos Is.). All 246 were live-verified by a Python dnspython+iso3166 script in the PR.
- **Cross-source conflict (important):** furkan's audit + hagezi/dns-blocklists#11438 document that two-letter `<cc>.nextlgsdp.com` hosts carry **TV time-sync and app/billing traffic on some models** (furkan's FAQ explicitly allowlists `de.lgtvsdp.com` and `de.ibs.nextlgsdp.com`; their own `de.nextlgsdp.com` SAFE entry was added with a deliberate refusal to generalise the region pattern). Perflyst's blanket block of all 246 regional SDP hosts contradicts that evidence and is not model-verified.

### 2.4 Outside the LG section

| Line | Entry | Section | Notes |
|---|---|---|---|
| 557 | `alphonso.tv` | `# Other useless connections from Smart-TV` | **LG's ACR + ad vendor** (replaced Gracenote ACR / Unruly ads Jan 2022, US/CA — issue #139). Not LG-named, hence filed in the generic section. **Gap:** absent from the furkan list entirely |

## 3. Commented-out entries (documented breakage)

Perflyst's convention: a row is commented out **because blocking it was documented to break TV functionality** (the file header asks users to report such incidents). Only two LG rows are commented out; everything else LG is actively blocked.

1. `#ngfts.lge.com # blocks thumbnails from loading in the LG Content Store` — blocking `ngfts.lge.com` (firmware/content file-transfer host) breaks Content Store thumbnail loading. Cross-check: furkan's list keeps `ngfts.lge.com` in STRICT precisely because it kills Content-Store-adjacent function by design.
2. `#us.lgtvsdp.com # #117` — see §4.1, the most detailed LG breakage report in the list.

## 4. Issue evidence (LG-specific breakage reports)

16 LG-related issues/PRs identified via issue search (`LG in:title`, 2026-09-22); the ones with substantive content:

### 4.1 #117 (Dec 2021, closed) — the anchor breakage report: time sync

- **Symptom:** "Auto Date & Time" fails after cold boot → TV clock resets to **2019-12-31** → cascade: Plex "network unreachable", HBO Max certificate errors, YouTube stuck on the boot animation.
- **Mechanism:** `us.lgtvsdp.com` is the TV's **time-sync host** (LG queries it twice, ~30–45 s apart, on first boot of the day). It is *not* NTP — consistent with furkan's later finding `systemTimeSource=sdp` (LG SDP session handshake).
- **Outcome:** `us.lgtvsdp.com` commented out (line 110). **YouTube/Prime/HBO breakage in this issue is secondary** — it is the clock cascade, not the app endpoints.
- **Rank C** (user-reported, reproducible mechanism, closed with list change).

### 4.2 #121 (Dec 2021, open) — `us.lgtvsdp.com` is dual-use

On a C1 with `us.lgtvsdp.com` unblocked (post-#117), home-screen ads returned; re-adding the block "fixed" the ads — i.e. the host carries **both** time sync **and** ad/config payloads. List keeps it commented out: time wins, ads leak. This is the canonical dual-use-host case in this space.

### 4.3 #53 (2020, bug) — Content Store needs `<cc>.lgtvsdp.com`

Content Store blocked; `gb.lgtvsdp.com` identified as required → effectively whitelists the region-host part of the family (the reason the file keeps only a few `*.lgtvsdp.com` names and comments out the US one). #43 (2020, "LG content store") is the same thread, empty body.

### 4.4 #148 (2023-07, open) — wildcard `lgtvcommon.com^` broke LG Channels

LG Channels app **error -102** caused by a bare `lgtvcommon.com^` wildcard row (not present in the current file — the current file has only per-service subdomains). Commenting it out fixed Pluto TV channels; Xumo remained broken. Evidence that **whole-zone blocking of `lgtvcommon.com` is not universally safe** (furkan claims the opposite for a G1, live-blocked since 2026-09-09 with no breakage — direct conflict, model-dependent).

### 4.5 #139 (Dec 2022) — vendor change: Gracenote/Unruly → Alphonso

Jan 2022, US/CA: LG switched ACR from Gracenote to **Alphonso** and ad serving from Unruly to **Alphonso** → `alphonso.tv` (line 557). Issue recommends `aic-ngfts.lge.com` + `alphonso.tv` (both present).

### 4.6 #134 (2022) — malformed entry

`lgad.cjpowercast.com.edgesuite.net` is the concatenation of two domains (CJ PowerCast ad host + Akamai CDN domain). Still malformed in the current file; the row as written likely matches nothing.

### 4.7 #95 / #75 / #15 — regional-domain history

`jp.*` entries added over time (#95); `it.*` requested in #75 but **not** in the file; #15 (2018) is the original observation that started the LG entries (region-based `hu.*` etc.). Demonstrates the list's region-by-region accretion without any central audit.

### 4.8 #167 / #168 / #169 (Sep 2026) — the Gamers Nexus import

#167 (open): GN video missing endpoints from the list. Fixed by #168 (GN block B entries, merged 2026-09-08) and #169 (246 regional `nextlgsdp` hosts, merged 2026-09-09, with a live DNS verification script). The GN investigation itself is rank **C** (journalistic, on-camera evidence, not peer-reviewed); #169's live verification upgrades the *existence* of the 246 hosts toward B for that property, but not their *safety*.

### 4.9 #170 (Sep 2026, **open PR by furkan-bayrak**) — ⚠️ contains a bare `lgtvsdp.com`

Verified diff (9 added rows): `de.emp.lgsmartplatform.com`, `de.info.lgsmartad.com`, `eic.api.lgtviot.com`, `eic.lgtviot.com`, `eic.nudge.lgtvcommon.com`, `eic.tv.wiselg.com`, `eic.wiseconfig.lgtvcommon.com`, `lgsmartad.com`, **`lgtvsdp.com`** (bare apex).
**Critical flag:** the PR was opened 2026-09-11, *before* furkan's own repo discovered the SDP time-sync breakage and removed bare `lgtvsdp.com` from its safe list on 2026-09-16 (commit `3ea0f34`, with a build guard `FORBIDDEN_APEX_ENTRIES`). Merging #170 as-is would put a bare `lgtvsdp.com` row into a Pi-hole list whose downstream consumers may apply it in adblock/wildcard form → the exact time-sync breakage documented in #117. The PR has not been updated. `us.lgtvsdp.com` was intentionally *not* re-added (correct).

### 4.10 #171 (Sep 2026, open PR) — `rdth.lgtvcommon.com`

Proposes `rdth.lgtvcommon.com` + `us.rdth.lgtvcommon.com` ("Remote Diagnostics & Telemetry Handler", webOS 22/C-series). Author claims zero impact on store/streaming — **unverified** (rank D–C). Not in the current file.

### 4.11 Negative findings

- **No LG-specific Netflix breakage reports exist** in the list's issues.
- **No LG-specific EPG breakage reports.**
- YouTube/Prime/HBO failures in #117 are all clock-cascade side effects, not app-endpoint blocks.
- App-store breakage: #53 (Content Store via `gb.lgtvsdp.com`) and the `ngfts.lge.com` thumbnail comment are the only store-adjacent breakages; `us.ibs.lgappstv.com` (billing) is *actively blocked* with no issue on file — a potential unreported risk.

## 5. Cross-source conflicts (Perflyst vs furkan-bayrak)

| # | Topic | Perflyst position | Furkan position | Assessment |
|---|---|---|---|---|
| 1 | `<cc>.nextlgsdp.com` (246 hosts) | all blocked (PR #169) | `de.`/`ca.` individually SAFE; region pattern **refused** (hagezi#11438: time-sync breakage on some models); `de.ibs.nextlgsdp.com` allowlisted | Furkan has the stronger evidence; Perflyst's blanket block is model-unverified |
| 2 | `lgtvsdp.com` family | `jp.`, `us.rdx2.`, `jp.rdx2.`, `smartshare.` actively blocked; only `us.` commented out (#117) | family = time channel; bare apex removed from its own list 2026-09-16; `FORBIDDEN_APEX_ENTRIES` guard | Perflyst's family handling is internally inconsistent (US commented, JP active) |
| 3 | `us.*.lgtvcommon.com` forms | 8 `us.` + 2 `aic.` forms (cdpbeacon, cdpsvc, homeprv, nudge, rdl, recommend, service) | the **live** names are `eic./aic./kic.` cluster twins; bare names NXDOMAIN; `us.` forms never verified | Perflyst's `us.` rows may be legacy aliases that match nothing — unverifiable from either source |
| 4 | `lgtvcommon.com` whole zone | #148: wildcard row broke LG Channels (−102) | G1 live-blocked the whole zone since 2026-09-09, no breakage; wildcard-safe per Level1Techs #255178 | Model-dependent; keep exact names, not the zone |
| 5 | `ngfts.lge.com` | commented out (store thumbnails break) | in STRICT as intentional function-kill | Agree; both sources treat it as KEEP |
| 6 | `ad.lgappstv.com` | active | probed NXDOMAIN 2026-09-12 | Perflyst row likely stale |
| 7 | `alphonso.tv` | present | **absent** (gap, noted in furkan analysis) | Perflyst correct; LG ACR vendor since Jan 2022 |
| 8 | `aic.cdpsvc` / `aic.rdl` stems | present | not in the 53-entry cluster set (which has `cdplauncher.`) | stems unverified by furkan; possible additional live names |

## 6. Source-quality rank per claim

Rank key: **A** = peer-reviewed (none exist in this space), **B** = maintained tracker with documented, reproducible methodology, **C** = community source with observations (issue reports, journalistic), **D** = anecdotal.

| Claim | Rank | Why |
|---|---|---|
| `us.lgtvsdp.com` = time-sync host; blocking → clock reset → Plex/HBO/YouTube cascade | **C** | Issue #117: user report with reproducible mechanism and concrete cascade; closed with list change. Later corroborated (mechanism, not the exact host) by furkan's on-device test (B) |
| `ngfts.lge.com` breaks Content Store thumbnails | **C** | Single inline comment, no issue link; but independently consistent with furkan's STRICT design kill |
| `lgtvcommon.com^` wildcard breaks LG Channels (−102) | **C** | Issue #148 with concrete error code; model-specific, conflicting G1 counter-evidence exists |
| `gb.lgtvsdp.com` required for Content Store | **C** | Issue #53 (bug report) |
| Alphonso = LG ACR/ad vendor since Jan 2022 (US/CA) | **C** | Issue #139; consistent with furkan's note (C) and hagezi umbrellas |
| Existence of the 246 `<cc>.nextlgsdp.com` hosts | **B** | PR #169 live DNS verification script (dnspython) — existence only, not safety |
| Purpose of the 246 hosts (telemetry/ad) | **C** | Gamers Nexus investigation (journalistic); no per-host traffic observation |
| `us.*.lgtvcommon.com` rows (8) | **D** | no issue, no verification in either source; `us.` prefix forms never DNS-checked (furkan found `eic./aic./kic.` instead) |
| `aic.cdpsvc`, `aic.rdl` (2 rows) | **D–C** | GN-sourced addition; stems absent from the independently-probed cluster set |
| Original block A (2018–2023, 23 rows) | **C** | long-lived community accumulation; a few rows corroborated by furkan (decommissioned there); no methodology documented |
| `lgad.cjpowercast.com.edgesuite.net` | **D** | malformed (#134); likely matches nothing as written |

Overall list quality: **C** — long-lived, actively triaged, with the best documented breakage annotations in this space (the commented-out rows are its most valuable artifact). Not B: no per-domain methodology, stale version header, a malformed entry, inconsistent family handling, and region entries added without per-model verification.
