# Gamers Nexus — "216,000,000 Spy TVs | The LG Smart TV Problem" (September 2026)

Research date: 2026-09-22. Scope: the Gamers Nexus (GN) investigation of LG smart TV
data collection (Sept 2026), what was *demonstrated* vs. merely *reported* vs. *unproven*,
the endpoints named, the model scope, and LG's response (recorded in detail in
`research/lg/lg-official.md` — cross-referenced below, not repeated).

**Verification caveat (read first):** the YouTube video could not be watched in this
environment (YouTube is JS-only and returns no content to a fetcher). Every item labeled
"CONFIRMED / demonstrated" below is *demonstrated in the video per multiple B/D sources
with consistent, mutually-corroborating detail*; it is NOT independently re-verified in
this repo (no second firmware, no second packet capture). GN and the Level1Techs
contributors are source **B** by convention (major outlet investigation with reproducible
methodology: Wireshark captures + firmware analysis + bench-tested retail units).

**Source-quality key** (same convention as `research/github` reports and `lg-official.md`):
- **A** = peer-reviewed / reproducible research (IMC 2024)
- **B** = independent investigation with reproducible methodology (Gamers Nexus, Level1Techs)
- **C** = vendor statement / vendor documentation (LG's own — vendor-confirmed, NOT independent)
- **D** = press summary without primary source

---

## 1. The video and its metadata

| Field | Value | Source |
|---|---|---|
| Title | "216,000,000 Spy TVs \| The LG Smart TV Problem" | — |
| URL | https://www.youtube.com/watch?v=6IFVTcM28KA | — |
| Length | ~135 min | D |
| Publication date | **Discrepancy:** ResetEra thread opened 2026-09-06; explainx.com dated it 2026-09-07; press coverage ran 2026-09-08. Treat as **2026-09-06/07** | D (multiple) |
| Traction by 2026-09-12 | ~5.1M views, ~18k comments | D (press citations) |
| Collaborators | Level1Techs (Wendell Wilson) + security researchers **MrBruh** and **uturn** | D |
| Method | Wireshark packet captures + firmware analysis + bench testing of retail OLED units | B (L1T guide documents the method) |
| Rebuttal video | "LG Says We're Fake News", https://www.youtube.com/watch?v=ToP9xfLDSME (~2026-09-12) — GN's point-by-point rebuttal of LG's statement | B (per D citations) |
| Companion video | RTINGS ACR explainer, https://www.youtube.com/watch?v=IvFu343KNek | D |

Related but distinct: the **July 2026** item in some coverage (e.g., CyberSec Guru's
"LG Smart TV spying investigation" dated July 2026) is the separate **LG Monitor App /
McAfee adware** video — not this investigation. Do not conflate (see `lg-official.md` §1.5).

## 2. Models and firmware in scope

| Item | Detail | Source |
|---|---|---|
| LG G5 OLED (2025 flagship) | Bench unit; the RCE PoC compromise was run against a G5 | D (CyberSec Guru) |
| OLED65G3PUA | The unit Ars Technica described running Wireshark against | D (Ars) |
| **OLED65G5WUA** | webOS 10.2.1, codename "starfish", build "ponytail-paparoa", kernel 5.4.268, LG1214 SoC. This is the unit the Level1Techs block guide targets and the basis of the firmware endpoint map in §5 | B (L1T forum guide) |
| webOS 25 / webOS 26 | webOS 25 referenced in the video; webOS 26 exists for 2026 models | B/D |
| Installed base | 49M US / 216M global — **LG Ad Solutions' own numbers** (C, from lgads.tv) | C |

## 3. Method (as documented by the B sources)

- **Network-level:** Wireshark captures between the TV and a lab network; out-of-box
  behavior (no user setup, no consent) explicitly tested. Level1Techs' guide (post
  2026-09-05, recon 2026-08-24) documents the same telemetry families from its own G5
  unit: https://forum.level1techs.com/t/lg-tv-block-mini-how-to/255178
- **Firmware-level:** inspection of webOS firmware — processes (`/usr/sbin/sdx`,
  `/usr/sbin/acr2`, `/usr/sbin/admanager`, `/usr/sbin/update`, `eula-service`), the sdx
  endpoint map in `/mnt/lg/cmn_data/sdp/sdx/server_addr_version.conf`, `acr.xml` with
  `ACR_On="true"` and the
  Alphonso client token, consent state in
  `/var/luna/preferences/eula` (S_MKT, S_PRG, S_VNG, S_ADG = ACR & viewing, S_TAG = IBA),
  ACR opt-out marker `/mnt/lg/cmn_data/acr/data/eula_disallowed_rebooted`, voice stack
  (`voiceinput*`, `trigger_thinq`, `trigger_alexa`, `voiceconductor`, `performer`; local
  wake word "hiLG", remote NLP), libs `libacrcloud_recognizer.so`,
  `libAdvertisementPlugin.so`, `libTVIS.so` (ACRCloud engine). (B — L1T + fightback notes
  from B/C lists; firmware internals cross-checked against `webosbrew/dev-toolbox-cli`
  shared-object inventories.)
- **Vendor-side:** LG's own documentation (C) — Alphonso ACR endpoints and cadence were
  independently characterized in **IMC 2024 (A)**: Anselmi et al., *Watching TV with the
  Second-Party*, arXiv:2409.06203 — LG ACR is served by **Alphonso, LG-owned since 2021**;
  `eu-acrX.alphonso.tv` (EU/UK), `tkacrX.alphonso.tv` (US), X rotates; frames sampled every
  10 ms, batched and sent every 15 s, peak every minute; **opt-out stops the traffic**.

## 4. Findings, tiered

### 4.1 CONFIRMED (demonstrated in the video; consistent across B/D sources; not independently re-verified here)

1. **Active LAN enumeration, out of the box.** With the TV fresh from the box and no
   setting toggled, it sweeps the local network and records internal IPs, device names,
   and MAC-derived identifiers of *unpaired* devices — phones, smartwatches, tablets,
   printers, routers, thermostats, air purifiers, a server BMC, PCs. It also captures
   nearby **Wi-Fi SSIDs + signal strength + channel numbers**, with location data tied to
   the network identifiers. Burke (on camera, per the press): *"This is the TV's native
   functionality. This didn't require vulnerabilities."* The Verge: the feed goes to LG
   Ad Solutions. LG's own 2026-09-12 statement **concedes** the Wi-Fi AP harvesting and
   its use for approximate location in ACR ("concession" #7–8 in `lg-official.md` §1.3)
   but says the discovery data is "not used for household profiling, cross-device
   targeting, or advertising segmentation" — a vendor claim (C) directly in tension with
   LG Ad Solutions' own cross-device marketing (C, `lg-official.md` §2.3). (B + C)

2. **Standby microphone capture → plaintext transcripts on device.** With the TV in
   standby (remote-off, **not** power-off) and **voice functionality enabled**, audio
   was captured; **plaintext transcripts** were observed in on-device logs; capture
   window ran 10–15 s past the end of speech. Critical scope note (The Register,
   2026-09-08): the tests were done with voice features *enabled*. This is **not**
   evidence of ambient recording without opt-in — that is precisely the disputed point
   LG denies (`lg-official.md` §1.2 #1–5). LG **concedes** (C): if Hands-free Voice
   Control is enabled, the TV "may continue monitoring only for the wake word while in
   standby" (§1.3 #1), and that nearby speech during an *active* session "may sometimes
   appear in speech-recognition results" (§1.3 #2). The on-disk plaintext transcripts
   themselves are *demonstrated* (B) but **never explained or denied** by LG (see
   §1.4 of `lg-official.md`). (B + C)

3. **Offline store-and-forward of voice audio.** The TV's Ethernet was unplugged, audio
   was generated, the TV was reconnected — then a **burst of outbound traffic** occurred
   (the viral clip). Audio was stored locally while offline and uploaded on reconnect.
   LG **denies this explicitly and specifically** (C, `lg-official.md` §1.2 #5): "Voice
   data is not stored for later upload when the TV is offline and is not transmitted when
   the connection is restored." This is the single most directly contradictory
   B-vs-C pair in the whole controversy: demonstrated (B, per the video) vs. denied
   (C). Neither side has been independently verified. (B vs C)

4. **ACR across all inputs, including HDMI; no full software kill.** ACR (fingerprinting
   of what is on screen) runs while the TV is used as a dumb HDMI display — i.e., it
   fingerprintes *other devices' content* (set-top boxes, streaming sticks, consoles).
   The raised scenario (a surgeon, on camera per press): telemedicine / HIPAA-relevant
   content over HDMI being fingerprinted. No standard user setting fully disables ACR
   (LG's opt-out path is in `lg-official.md` §4; IMC 2024 (A) confirms the opt-out *does
   stop* the alphonso.tv traffic when used). ACR running on "supported content sources
   such as Live TV, HDMI-connected devices" is **conceded by LG** (C, §1.3 #9). (B + C)

5. **webOS RCE in network-facing services; G5 compromised into an externally controlled
   listening device.** PoC compromise of a G5 demonstrated (controlled exploit). As of
   **2026-09-16** (Ecoustics, D): disclosure in progress, **no CVEs assigned, no fix
   published**. LG's response: generic "no connected product is ever completely immune"
   (C) — it did not address the specific flaws. (B; CVE status D)

6. **Consent-UX dark pattern.** Six user agreements shown at setup; the cursor is
   **pre-set to "Select All"** when only two are actually required. Reported by The Verge
   (~2026-09-19). (B video; D reporting)

### 4.2 REPORTED (single source or forum-level; not corroborated)

| Claim | Source tier | Note |
|---|---|---|
| A hidden second microphone not covered by the main mic toggle | D (forum/comment) | Never confirmed by LG either way (absent from the 09-12 statement entirely — `lg-official.md` §1.4) |
| TV auto-reconnects to remembered/open Wi-Fi to "phone home" | D | Plausible; not demonstrated in the cited material |
| "Collection even before any consent" | D (Tom's HW comments) | The LAN-sweep finding (§4.1 #1) is the demonstrated version of this; the specific "no consent at all" framing is a forum paraphrase |
| "363M addressable secondary devices" is output of the network enumeration | D (inference) | The 363M figure is LG Ad Solutions' own marketing number (C, behind a lead form — could not be opened); linking it to the demonstrated enumeration is inference, not proof |

### 4.3 UNPROVEN / open

- **LG's denials are unverified in both directions.** The 09-12 statement (C) denies the
  store-and-forward, ambient recording, and the "216,000,000 spy TVs" framing outright
  ("The claims made in the recently published video are not true.", 09-09). No
  independent replication of the standby-audio or offline-upload results exists as of
  2026-09-22. Do not write either side as settled fact.
- **RCE details withheld** (no CVE, no patch); the "listening device" compromise is a
  *vulnerability*, distinct from the *native* telemetry above — the video and press are
  careful that the enumeration/ACR findings "didn't require vulnerabilities".
- Whether the shipped ACR default (LG says opt-in / off by default, C) matches reality
  on a fresh retail set is unresolved (Pocket-lint D reported Live Plus **on by default**
  on a 2025/26 set — `lg-official.md` §5 open items).

## 5. LG endpoints named by the primary sources

Full machine-readable version with actions: `research/lg/github-lists-d.yaml`.
Source ranks: (A) = IMC 2024; (B) = GN/L1T firmware + network recon; (C) = LG's own
documentation; (D) = press.

| Endpoint family | Named by | Rank | Purpose |
|---|---|---|---|
| `eu-acrX.alphonso.tv` / `tkacrX.alphonso.tv` (X rotates) | IMC 2024; LG docs | A / C | LG first-party ACR via Alphonso (LG-owned since 2021); 10 ms sampling, 15 s batch |
| `choice.alphonso.tv` | LG docs | C | Alphonso opt-out portal |
| `lgads.tv` | LG docs; L1T | C / B | LG Ad Solutions brand + privacy policy; TV does not phone home to it (marketing surface) |
| `nextlgsdp.com` + `us.`, `ibs.`, `ibsstat.`, `rdx2.`, `ngfts.`, `aic-gfts.nextlgsdp.com` | L1T (G5 firmware) | B | sdx telemetry (sdp_logging, sdp_nlp voice NLP, sdp_search, sdp_apps), crash upload, ibis |
| `*.lgtvcommon.com` — netflixvoice, nudge, homeprv, wiseconfig, pnv, recommend, cdpsvc, cpauth, cdpbeacon, rdl, wiseresource, qcardservice, qt2-kic.lab | L1T | B | Telemetry, CDP beacons, recommendations, voice proxy, ThinQ AI lab |
| `*.lgsmartad.com` (~159 `<cc>.` hosts) + `*.aws-prd.net` mirrors (163 `<cc>-ad-lgsmartad-com.aws-prd.net`); `info.lgsmartad.com` polled ~60 s by `admanager` | L1T | B | Advertising |
| `*.lgtviot.com`, `*.lgthinq.com` (api, commonpush, sports, ocp, push, buddy, common, connect-client) | L1T | B | ThinQ / IoT |
| `snu` / `su` / `su-ssl` / `nsu.lge.com` | L1T | B | OTA / firmware |
| `ngfts.lge.com` + `qt2-`, `kic-`, `eic-`, `ruc-`, `aic-ngfts.lge.com` | L1T | B | LLM / AI platform |
| `*.lgtvsdp.com`, `*.lgappstv.com` | L1T | B | Content Store (→ "LG Apps" 2026-04-29), LG Shop, Smart Media Product Membership policy |
| `lgsmartweb.com` | L1T | B | Voice-search / LG web search backend |
| `lggalleryplus.com`, `tv.wiselg.com` | L1T | B | Smart account / Gallery Plus / buddy |
| `*.iot.<region>.amazonaws.com` | L1T | B | AWS IoT MQTT push (per-device certs); shared AWS infra |
| `156.147.69.32:8080` | L1T | B | Hardcoded OTA fallback in `/usr/sbin/update` (IP — firewall-only, not DNS-blockable) |
| `54.186.247.229:443` | L1T | B | Live sdx telemetry (AWS IP — firewall-only) |
| `yumenetworks.com`, `smartclip.com`, `lgad.cjpowercast.com.edgesuite.net` | L1T | B | Third-party ad tech (NOT LG-owned) |

Perflyst added a section headed `# Gamers Nexus - LG Smart TV spying` covering
`aic.cdpsvc.lgtvcommon.com`, `aic.cdpbeacon.lgtvcommon.com`, `us.nextlgsdp.com`,
`ngfts.nextlgsdp.com`, `aic.rdl.lgtvcommon.com`, `aic-gfts.nextlgsdp.com` (B/C list,
via our fightback notes).

## 6. LG's response (cross-reference)

Full text and analysis in `lg-official.md` §1 (statement family published in stages:
**2026-09-09** Tom's Hardware first pub → **2026-09-12** official newsroom
"Understanding Privacy on LG Smart TVs").

- Headline denial (C, 09-09): "The claims made in the recently published video are not
  true."
- Specific denial of the store-and-forward demonstration (C, §1.2 #5) — the sharpest
  B-vs-C contradiction; see §4.1 #3.
- Key concessions (C, §1.3): standby wake-word monitoring (if enabled); ambient bleed
  *within active sessions*; Wi-Fi AP harvesting for location; ACR on HDMI; data flow to
  LG Ad Solutions (majority-owned affiliate) for audience segmentation / cross-device
  advertising where separately consented; 5-year security-update window.
- What LG did **not** address (B/D coverage of the 09-12 statement, `lg-official.md`
  §1.4): the plaintext on-disk transcripts, the specific RCE flaws, the hidden-mic claim,
  the consent dark pattern, and the identities of the ACR "service providers" (the
  Alphonso connection is implied by "majority-owned affiliate" only).
- GN's rebuttal: "LG Says We're Fake News" (B, ~2026-09-12).

## 7. Source table (this file)

| Source | Rank | What it establishes |
|---|---|---|
| GN video "216,000,000 Spy TVs" (youtube.com/watch?v=6IFVTcM28KA, ~2026-09-06/07) | B (per D citations; video not directly viewed) | The demonstrations in §4.1; model in scope (G5); "native functionality" quote |
| Level1Techs forum guide, 2026-09-05 (forum.level1techs.com/t/lg-tv-block-mini-how-to/255178) | B | Firmware endpoint map (§5); sdx/acr processes; consent state paths; G5WUA build details; Perflyst breakage notes |
| IMC 2024 — Anselmi et al., "Watching TV with the Second-Party", arXiv:2409.06203 | A | Alphonso = LG ACR since 2021; `eu-acrX`/`tkacrX.alphonso.tv`; 10 ms / 15 s cadence; opt-out stops traffic |
| Ars Technica, 2026-09-08 (arstechnica.com/gadgets/2026/09/lg-tv-shown-capable-of-tracking-user-activity-even-when-offline/) | D | OLED65G3PUA Wireshark unit; offline tracking framing |
| The Verge, 2026-09-12 (theverge.com/tech/991190/lg-tv-spying-standby-recording-wi-fi-scanning-gamers-nexus) and 2026-09-12 response piece (theverge.com/tech/994333) | D | Standby recording + Wi-Fi scanning summary; LAN feed to LG Ad Solutions; consent dark pattern (~09-19); 5.1M-view figure |
| The Register, 2026-09-08/09 (theregister.com/security/2026-09-08/lg-accused-of-egregious-invasion-of-privacy-over-tv-data-collection/5294956) | D | "Tests done with voice enabled" scope note; LG statement text |
| Tom's Hardware, 2026-09-09 (tomshardware.com/tech-industry/big-tech/lg-strongly-denies-tv-security-claims-…record-audio) | D (report) / C (quoted statement) | "not true" line; full statement; LG did not address plaintext transcripts / RCE |
| Ecoustics (D, 2026-09-16) | D | No CVEs / no fix published as of 2026-09-16 |
| CyberSec Guru (thecybersecguru.com/news/lg-smart-tv-spying-investigation/) | D | G5 as the 2025 flagship unit; misdates the investigation "July 2026" (that's the separate monitor-adware video) |
| GN rebuttal "LG Says We're Fake News" (youtube.com/watch?v=ToP9xfLDSME, ~2026-09-12) | B (per D citations) | Point-by-point rebuttal of the 09-12 statement |
| RTINGS ACR video (youtube.com/watch?v=IvFu343KNek) | D | Companion ACR explainer |
| tbreak.com/lg-smart-tv-privacy-gamers-nexus/, hdtvtest.co.uk/news/lg-strongly-rejects-smart-tv-spying-accusations, pocket-lint.com/lg-tv-turn-off-live-plus/ | D | Secondary summaries; Live Plus default-on observation |
