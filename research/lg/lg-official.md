# LG Official Statements & First-Party Material (September 2026)

Research date: 2026-09-22. Scope: LG's own positions on the Gamers Nexus
investigation (Sept 2026), LG Ad Solutions / Alphonso first-party documentation,
LG TV privacy policy pages, and the ACR opt-out mechanism.

**Source-quality key** (same convention as `research/github` reports):
- **A** = peer-reviewed / reproducible research
- **B** = independent investigation with reproducible methodology (Gamers Nexus / Level1Techs)
- **C** = vendor statement / vendor documentation (recorded as vendor-confirmed, NOT independent)
- **D** = press summary without primary source

Access caveats (recorded honestly):
- `www.lg.com/us/*`, `www.lg.com/us/support/*`, `privacy.us.lg.com`, `us.lgappstv.com`
  are JS-heavy or bot-walled (Akamai 403 / JS challenge). The official statement was
  captured via a Wayback Machine snapshot of
  `https://www.lg.com/us/newsroom/corporate/statement-understanding-privacy-on-lg-smart-tvs`.
- The "Smart Media Product Membership Privacy Policy" (the TV-specific policy) is served
  only from the logged-in LG account portal (`lgappstv.com` / `lgemembers.com`); it could
  not be fully scraped. Existence, host, update date, and contact are confirmed via search
  snippets of the official pages.

---

## 1. LG's September 12, 2026 statement (primary vendor source, C)

### 1.1 The official statement — "Understanding Privacy on LG Smart TVs"

- **Publisher:** LG Electronics (US Newsroom, Englewood Cliffs, NJ)
- **Published:** **September 12, 2026**
- **URL:** https://www.lg.com/us/newsroom/corporate/statement-understanding-privacy-on-lg-smart-tvs
  (global mirror: `lg.com/global/newsroom/news/statements/statement-understanding-privacy-on-lg-smart-tvs`;
  SG mirror: `lg.com/sg/press-release/official-company-statement-on-lg-smart-tv-privacy-issue`)
- Captured 2026-09-22 via Wayback Machine (direct fetch is Akamai-bot-walled).
- Reported by Engadget (2026-09-12) as "a much longer response on its website" beyond
  the shorter statement LG gave to news outlets.

Opening (verbatim):

> "Some recent media coverage may have contributed to misconceptions about how LG smart
> TVs work. As an industry leader, LG believes we have a responsibility to provide
> customers with clear and accurate information about how our smart TVs operate and the
> privacy controls available to them."

### 1.2 What LG says it does NOT do (denials)

| # | LG's claim (C, 2026-09-12) |
|---|---|
| 1 | "LG smart TVs do not continuously record or transmit users' conversations." |
| 2 | "The TV does not continuously listen to, record, or store conversations in the home." |
| 3 | Wake-word audio: "not converted to text, stored, or transmitted" when no wake word is detected; processed locally, "immediately discarded" / "promptly deleted, and is not transmitted to LG servers". |
| 4 | "Speech-to-text processing begins only after a wake word has been recognized or after a user deliberately activates voice recognition using the microphone button. Before that point, the TV is only checking for the wake word and does not generate transcripts." |
| 5 | **"Voice data is not stored for later upload when the TV is offline and is not transmitted when the connection is restored."** (Direct rebuttal to the store-and-forward demonstration.) |
| 6 | ACR "does not collect screenshots, screen recordings, video recordings, voice recordings, or other audio recordings from the TV." ACR "does not collect or store voice recordings, other audio recordings, screenshots, screen images, or video recordings." |
| 7 | ACR "does not operate within third-party streaming apps such as Netflix or YouTube available through LG Apps." (Vendor claim; not independently verified.) |
| 8 | Device-discovery info "is not used for household profiling, cross-device targeting, or advertising segmentation." (Vendor claim — directly contradicted in tone by LG Ad Solutions' own marketing; see §2.) |
| 9 | "Voice-audio data and ambient-audio data are not provided to LG Ad Solutions as part of its advertising services." |
| 10 | "No connected product is ever completely immune from security vulnerabilities" — i.e., LG concedes vulnerabilities can exist without conceding any specific one. |

### 1.3 What LG says it DOES do (concessions / admissions)

| # | LG's concession (C, 2026-09-12) |
|---|---|
| 1 | **Standby wake-word listening (if enabled):** "If a user has chosen to enable Hands-free Voice Control, the TV may continue monitoring only for the wake word while in standby mode." — Concedes the microphone stays live in standby when Far-Field is on. |
| 2 | **Ambient bleed during active sessions:** "During an active voice recognition session, nearby sounds or speech occurring at the same time as a user's command **may sometimes appear in speech-recognition results**. When voice recognition is actively used, speech may be converted into text as part of the speech-recognition process." — Concedes transcripts can contain non-user speech *within* a session. |
| 3 | **Session duration:** "If no speech is detected, the session automatically ends after approximately 10 seconds. … In all cases, voice recognition sessions are subject to a maximum duration limit of approximately 18 seconds." — Note: GN reported a 10–15 s post-speech capture window (B/D); LG frames 18 s as a hard cap. |
| 4 | **Voice results + technical logs exist:** "Voice-recognition results and related technical logs may be generated as part of processing a voice command. These records are associated with specific voice interactions." |
| 5 | **Hardware mic:** "On supported models, users can disable the TV's built-in microphone using a dedicated hardware microphone switch." (Implies most models have a hardware mic that can be physically disabled; remote-mic voice still works with the button.) |
| 6 | **LAN device discovery:** "LG smart TVs may use device-discovery functions to recognize and communicate with compatible external devices" (set-top boxes, DVD players, game consoles, IoT devices). |
| 7 | **Wi-Fi AP scanning:** "Nearby Wi‑Fi access-point information and signal-strength information are processed separately from device discovery. In markets where ACR is available and enabled, this information may be used to help estimate the TV's approximate location in support of ACR services." — Concedes Wi-Fi AP harvesting is real and used for location estimation (gated on ACR agreements). |
| 8 | **ACR data pipeline:** "LG may process content-identification fingerprints together with device information, content source information (for example, Live TV or HDMI), network information, and consent settings." |
| 9 | **ACR runs on HDMI inputs:** "ACR may operate on supported content sources such as Live TV, HDMI-connected devices, and LG Channels." |
| 10 | **Sharing with the ad unit:** "ACR-related viewing information may be shared with **LG Ad Solutions, which is a majority-owned affiliate**, to support audience segmentation, viewing and audience trend analysis and, where separately consented to, interest-based advertising and cross-device advertising." — Vendor-confirmation of the Alphonso/LG Ad Solutions relationship and of the data flow to it. |
| 11 | **CCPA framing:** "In certain markets and under applicable user agreements, ACR-related information may also be shared in ways that may be considered a 'sale' or 'sharing' of personal information under applicable privacy laws." |
| 12 | **Voice commands use ACR-like state:** "The Viewing Information Agreement may also be required to support certain voice-related functions. … if a user says 'Go to channel 11', the system may need to determine whether the TV is currently using Live TV or an HDMI-connected device." |
| 13 | **Security updates:** "LG currently provides security updates for eligible TV products for up to five years from the initial release of the applicable webOS platform version." Also: LG "operates a Bug Bounty Program and works with external security researchers." |
| 14 | **Opt-in posture (claimed):** "Features such as Automatic Content Recognition (ACR), voice recognition, and interest-based advertising are optional. These features are not enabled by default." Each requires a separate agreement (Voice Information Agreement; Viewing Information Agreement; Interest-Based Cross Device Advertising Agreement), "LG does not use ACR for interest-based advertising unless a user opts in to both agreements." |
| 15 | **Opt-out stops collection (claimed):** "When a user disables ACR, withdraws consent, or exercises applicable opt-out rights, including 'Do Not Sell' requests, ACR data collection stops." Also: "Declining optional agreements does not prevent users from using core smart TV functionality." |

### 1.4 What LG did NOT address (per B/D coverage of the 2026-09-12 statement)

- The plain-text transcript logs on the TV (noted by Tom's Hardware 2026-09-09 re: the
  shorter statement: "The company didn't address some of the other claims and
  vulnerabilities pointed out in the video, such as the storing of transcripts in plain text.").
  The longer website statement addresses *transcript generation during sessions* and
  *offline upload* but never explains what the researchers saw on disk.
- The specific RCE vulnerabilities (only the general "no product is immune" language).
- The possible second/hidden microphone claim (never mentioned).
- The dark-pattern consent UX (six user agreements, cursor pre-set to "Select All") shown
  in the video (reported by The Verge, ~2026-09-19).
- Who the "service providers" are that process ACR/voice data (it says partners process
  it, never names them — the Alphonso connection is only implied by the
  "majority-owned affiliate" line).
- The 363M "addressable secondary devices" marketing figure vs. the demonstrated
  network-enumeration mechanics (LG Ad Solutions marketing, see §2).

### 1.5 Earlier / parallel LG statements (same statement family, C)

- **2026-09-09, to Tom's Hardware (first publication of the statement).**
  URL: https://www.tomshardware.com/tech-industry/big-tech/lg-strongly-denies-tv-security-claims-says-tracking-and-snooping-concerns-not-true-online-investigation-claims-216-000-000-spy-tvs-record-audio
  Adds the headline line: **"The claims made in the recently published video are not true."**
  (Full statement text identical to §1.1 + a "topic by topic breakdown"; the Tom's Hardware
  version is the one quoted by most outlets.)
- **2026-09-09, to The Register** (statement reproduced in The Register, updated 2026-09-09):
  "The claims made in the recently published video are not true. … If a user does not
  consent to the applicable optional agreement, ACR data is not used for advertising purposes."
  URL: https://www.theregister.com/security/2026-09-08/lg-accused-of-egregious-invasion-of-privacy-over-tv-data-collection/5294956
- **2026-09-12, to The Verge / Engadget / Mashable / CEPRO etc.** (same core text; The Verge
  article of record: https://www.theverge.com/tech/994333/lg-responds-to-tv-spying-allegations).
- **2026-07 (prior controversy, monitors):** on the LG Monitor App / McAfee adware matter
  LG told The Register: "LG Electronics reiterates that McAfee is not installed
  automatically and is never installed without the user's explicit consent." (C via D, 2026-09-08.)

---

## 2. LG Ad Solutions / Alphonso — first-party material (C)

**Corporate facts:**
- "LG Ad Solutions, **incorporated as Alphonso Inc.**, is a global leader in advanced
  advertising for Connected TV and cross-screen devices." (footer of every lgads.tv page)
- The LG statement (2026-09-12) calls LG Ad Solutions "a majority-owned affiliate."
- Alphonso Inc., 211 Hope Street, Suite 390905, Mountain View, CA 94041; info@alphonso.tv;
  EU DPO: EUprivacy@alphonso.tv. (from lgads.tv/site-privacy-policy)
- HQ 444 Castro St, Mountain View CA; offices London, Bangalore, LA, Denver, Toronto,
  NY, São Paulo, Australia. CEO Michael Hudes; General Counsel & CPO Tom Cushing.
  (lgads.tv/company/, fetched 2026-09-22)
- Korea Times (2025-08-19, D): "LG Ad Solutions operator Alphonso eyes US listing" —
  Alphonso is a distinct legal entity operating LG Electronics' CTV ad brand.
- **`lgadsolutions.com` does not resolve.** The official domains are **lgads.tv** (brand
  site) and **alphonso.tv** (entity site; the site-privacy-policy text refers to
  "www.alphonso.tv").

### 2.1 What LG Ad Solutions says it collects (lgads.tv/site-privacy-policy/, effective 2023-03-20, C)

Verbatim key claims:

- "Alphonso develops and distributes certain software applications for automatic content
  recognition ('ACR'), which may include applications relating to smart televisions."
- The Service may collect: "browser or device type; make and model of device; operating
  system type; the time of your interaction …; device identifiers, such as **IDFA, IP
  address, MAC address**, or other such identifiers; information about the websites you
  visit over time and across various devices and browsers; and **information about your
  location**."
- **Opt-in claim:** "the Service **only collects data from your device if you have agreed
  to participate**."
- **Mechanism (matches IMC 2024, A):** "the Independent Application receives brief audio
  samples (**about 10 milliseconds**, or 1/100 of a second) directly from the audio
  content of your viewing device (e.g., TVs, video and audio streaming devices, set-top
  boxes, etc.). These audio samples are collected **internally** (i.e., the sample is taken
  from the internal source, not from the use of any external listening device) and are
  encoded (sometimes referred to as 'hashed') into digital 'audio signatures' on your
  device. The audio signatures are then sent to Alphonso's servers where they are compared
  to audio signatures of pre-existing commercial content."
- **Sharing claim:** "Matched audio signatures are used by Alphonso and **shared with
  third parties** for a variety of media recommendations … and for **ad targeting and
  measurement services across associated devices**."
- "The audio signatures are associated with IP address and/or device ID, but not name,
  postal address, or email."
- **Denial re: human speech:** "Importantly, Alphonso's ACR service **can't detect and is
  not designed to recognize human conversation**, ambient sounds, and other non-commercial
  audio or sounds."
- "All data collected by Alphonso is associated with a household, as opposed to an
  individual, and all data is associated with the IP Address of that household."
- IBA opt-out via aboutads.info/choices and a "Do Not Sell" portal at
  **https://choice.alphonso.tv/donotsell**; other CCPA requests at
  https://choice.alphonso.tv/otherccparequests. "If you opt out … we may still collect
  data for other purposes including analytics, reporting, content personalization."
- TV opt-out claim: "you can do so in the **settings menu of your television** where the
  Service is integrated."

### 2.2 LG Ad Solutions' claimed targeting data (lgads.tv/technology/, C, fetched 2026-09-22)

"LG Ad Solutions first-party data, powered by Automatic Content Recognition technology,
informs viewership behaviors across linear TV and OTT on LG Smart TVs, **at the glass
level**." "Deterministic Viewership Data — Sourced from programs, movies, ads, gaming
content and OTT apps as they display on a LG Smart TV across linear and streaming
services."

Targeting categories advertised: Tune-In (show/network/app/service/genre); Devices &
Services; Premium Content; Purchase Habits ("New subscriptions, service activations or
cancellations, purchases, rentals and more"); Ad Exposures ("including competitors, and
manage frequency levels"); **Gamers** ("by usage of specific platforms, studios, brands,
titles and consoles"); Viewing Habits ("light or heavy TV viewers, **cord cutters, ad
skippers** or app loyalists"); **Location** ("region, city, or zip code for activation
with foot traffic attribution").

### 2.3 Cross-device claims (lgads.tv/solutions/ + /, C)

- "Cross-Device: **Own the living room** and surround the connected LG household beyond
  the TV across **mobile, tablet and desktop** devices."
- "Advertisers now have a source for LG CTV inventory with one-stop planning, activation
  and measurement across all viewing platforms."
- "Audiences: Engage viewers at the right moment with **ACR-informed segments**."
- Headline figures on lgads.tv: **49M US** LG Smart TVs, **216M global** LG Smart TVs.
- The **363M "addressable secondary devices" (US)** figure comes from the gated fact
  sheet (behind a lead form; not fetched). It is cited by Ars Technica (2026-09-08:
  "LG's ad business, LG Ad Solutions, has said in recent marketing materials that it can
  reach 363 million 'addressable secondary devices' in the US") and The Register
  (2026-09-08, same). Treat the number as **vendor marketing claim (C) as reported (D)**;
  the primary PDF was not accessible.

### 2.4 "We own the glass" (B2B material quoted on camera in the GN video)

The video description (via ResetEra OP quoting the YouTube description) says LG Ad
Solutions executives said "on camera" that LG "owns the glass" and talked about "knowing
everybody in the household, knowing the secondary devices, moving from TVs to smartphones
and other screens." LG's own lgads.tv uses "own the living room" in the Cross-Device
section (§2.3), so the *phrase family* is vendor-confirmed; the specific on-camera quote
is from the video (B) and I did not view it.

---

## 3. LG TV privacy policy pages (C, vendor-confirmed)

### 3.1 LG Electronics corporate Privacy Policy
- URL: https://www.lg.com/uk/privacy/ (regional copies: lg.com/us/privacy, /global/privacy, etc.)
- **Last updated: 04/29/2026** (Cookie policy 07/24/2026). Full text fetched 2026-09-22.
- Covers: lg.com, LG Account, ThinQ app, linked IoT devices. Explicitly defers TV
  specifics: "For LG Smart TV or Smart Media Product users, please see the separate
  **Smart Media Product Membership Privacy Policy** … in Account management menu or LG
  Account menu from settings of Smart TV / Media Product."
- Stated collections (relevant excerpts, C):
  - Device info: "device name, IMEI, UUID, OS version, country, location, language, IP
    address, mac address, connected modem information, **internet router information** and
    settings of devices."
  - Log info: "URL, redirected URL, performance timing, referrer, network type, network
    info, charge status, ad block info, and cookies."
  - "We may collect **audio, electronic, visual, or similar information**, such as video
    recordings."
  - Biometric: "voiceprints … We collect and process this information only after providing
    you notice and consent … LG will not sell or share your biometric information for use
    by a third party."
  - ThinQ: "Identity data including **speaker's voice and its translated text**"; home/room
    data; geolocation.
  - ThinQ-linked devices: "information on network connection and **surrounding network
    environment**" + "Biometric information, including **voice recordings, voiceprints**."
  - Smart TV linking: "OTA ID, TV os version, device feature set code, content
    recommendation list ID, content ID."
  - Sharing: LG Group, service providers (KR and other countries), third-party IoT
    providers, "Advertising partners", analytics (Google Analytics, Firebase).
  - "We also collect other information … from **third parties, for example marketing
    companies and data brokers**."
  - Joint controllers: local LG entity + LG Electronics Deutschland GmbH for profiling (EU).
  - Contact: dpo-eu@lge.com; rights portal: privacy.lg.com.
- Privacy centers: **privacy.lg.com** (global) and **privacy.us.lg.com** (US) — both JS
  apps; could not be scraped on 2026-09-22 (JS challenge).

### 3.2 Smart Media Product Membership Privacy Policy (TV-specific)
- Hosted on the LG Apps / Content Store platform: **gb.lgappstv.com** (and us.lgappstv.com,
  lgemembers.com). Brave search snippets of the official pages: "Last Updated On: **June
  2026**"; contact "our Data Protection Officer at **tv.privacy@lge.com**".
- Full text is behind the JS account portal (login-gated `retrieveTerms` API); **not
  scraped**. On the TV it is reachable from Settings > (General >) Support > Privacy &
  Terms / LG Account menu. Record as C with partial access.

### 3.3 LG Content Store
- The store runs on **lgappstv.com** (us.lgappstv.com, gb.lgappstv.com, lgshopsvc.lgappstv.com).
- Official notice on us.lgappstv.com (via search snippet): "**Service Name Update: LG
  Content Store → LG Apps [04/29/2026]**". Last updated: April 29, 2026.
- webOS developer-side data rules (for apps):
  https://webostv.developer.lge.com/develop/guides/privacy-guideline and
  https://webostv.developer.lge.com/develop/tools/privacy-policy-for-app (C; URLs found via
  search; content not fetched — developer program docs).

### 3.4 ThinQ / IoT
- ThinQ app is operated by "LG Electronics Inc., LG Twin tower, Seoul" (per the services
  table in §3.1); thinq@lge.com.
- Device plane (from independent firmware work, B — see gamers-nexus-2026.md):
  `*.lgtviot.com` (api, commonpush, sports, ocp, push, buddy), `*.lgthinq.com`
  (common, connect-client), push via AWS IoT MQTT with per-device certificates.

### 3.5 webOS voice assistant — what LG says and what the backend is
- LG's official description (2026-09-12 statement, C): voice recognition is off by
  default; wake word "Hi LG" (hands-free) or mic button on remote; on-device wake-word
  detection; STT only after wake word/button; ~10 s no-speech auto-end, ~18 s max
  session; hardware microphone switch on supported models.
- Marketing names on LG product pages (per The Register, D): "Intelligent Voice
  Recognition", "Clear Voice Pro"; details sit behind a low-page "LG Privacy" link.
- **Backend (independent firmware evidence, B):** the voice stack on webOS is
  `voiceinput*`, `trigger_thinq`, `trigger_alexa`, `voiceconductor`, `performer` with
  local wake word `hiLG`; **NLP/search backends are remote**: `sdp_nlp` on
  `nextlgsdp.com` and `lgsmartweb.com` (LG web search). There is also an **Alexa
  integration** (`trigger_alexa`), a Netflix voice proxy (`netflixvoice.lgtvcommon.com`),
  and an LLM/AI platform on `ngfts.lge.com` family (`com.webos.app.aiplatform`,
  `"llm": {"support": true}` in the TV's profile.json; ThinQ AI lab endpoint
  `qt2-kic.lab.lgtvcommon.com`). (Source: Level1Techs guide, B — see
  gamers-nexus-2026.md.) So: LG's default voice backend is LG's own cloud (webOS NLP),
  not a named third-party LLM; Alexa is an optional integrated assistant. LG's own
  statement does not name the backend.

### 3.6 LG Account
- LG Account data is covered by §3.1 (identity, device UUIDs, advertising ID, IP).
- "If you delete your entire LG Account, your information will be retained for three
  months and immediately destroyed thereafter." (corporate policy, C)

---

## 4. ACR opt-out mechanism on the TV (stated vs. observed)

### 4.1 The setting (vendor UI, C/D)

- The ACR feature in the TV UI is called **Live Plus**. LG's on-TV text (quoted by
  Pocket-lint, D, 2025-12-22, from the TV's settings screen):
  "By turning Live Plus on, you understand that the content displayed on your TV can be
  recognized, and that the viewing information may be used to provide you with an
  enhanced viewing experience and personalized services including content recommendations
  and advertisements."
- **Path (webOS 24/25):** Settings > General > System > Additional Settings > **Live Plus**
  (toggle). (Pocket-lint D; matches the "Tier 0 privacy paths" in our
  `research/github/snapshots/fightback-research-notes.md`, which marks the exact paths
  needs-confirmation.)
- Related toggles (same sources, C/D, needs-confirmation per webOS version/region):
  - User Agreements (viewing info, voice info, IBA): Settings > General > Support >
    Privacy & Terms > User Agreements
  - Limit Ad Tracking / Interest-Based Advertising: Settings > General > Support >
    Privacy & Terms > Advertising (older webOS: General > Additional Settings > Advertising)
  - Voice: Settings > General > AI Service > Voice Recognition
- Per LG's 2026-09-12 statement, the consent objects are: **Viewing Information
  Agreement** (gates ACR), **Voice Information Agreement** (gates voice), **Interest-Based
  Cross Device Advertising Agreement** (gates IBA/cross-device ads); "LG does not use
  ACR for interest-based advertising unless a user opts in to both agreements"; ACR is
  "turned off by default" (vendor claim).

### 4.2 What opting out actually disables (independent evidence, B/A)

- **Firmware-level (B, Level1Techs guide, 2026-09-05; recon on OLED65G5WUA webOS 10.2.1,
  2026-08-24):** consent state lives in `/var/luna/preferences/eula` with groups
  `S_MKT` Marketing, `S_PRG` Privacy, `S_VNG` Voice, `S_ADG` **ACR & Viewing**, `S_TAG`
  IBA ads. The ACR daemon is `/usr/sbin/acr2`; its config `acr.xml` was `ACR_On="true"`
  with an **Alphonso client token** (`LG-webOS25-X-...`) — first-party on-device
  confirmation that Alphonso is the ACR backend. The consent gate + the opt-out marker
  `/mnt/lg/cmn_data/acr/data/eula_disallowed_rebooted` are what actually stop it; on the
  test unit ACR was "currently inert" (empty solution lib, zeroed DB) even with
  `ACR_On="true"` — i.e., the *network* behavior is consent- and event-gated, and blocking
  the egress path (`nextlgsdp.com` family) is the belt-and-braces layer.
- **Network-level (A, IMC 2024):** LG's ACR traffic goes to **Alphonso** endpoints
  (`eu-acrX.alphonso.tv` EU/UK, `tkacrX.alphonso.tv` US; X rotates); frames sampled every
  10 ms, batched every 15 s, peaking every minute; **the paper's experiments show opting
  out STOPS the ACR traffic** (consistent with the vendor opt-out claim).
- **What it does NOT disable (per B firmware work):** LAN device discovery, Wi-Fi AP
  scanning, `sdx` telemetry, `admanager` ad polling, ThinQ/IoT, LLM/AI endpoints — these
  are separate processes; only the router/firewall layer or individual consent declines
  stop them. LG's statement itself says device discovery and Wi-Fi processing are
  "separate functions" (§1.3 #7) — i.e., turning off Live Plus/ACR does not stop the
  device enumeration that LG also concedes.
- **Consent UX shown in the video (B/D):** six user agreements displayed, with the cursor
  pre-placed on "Select All" when only two agreements are required to continue
  (The Verge, ~2026-09-19). LG's statement claims "rejecting deceptive practices (dark
  patterns)" (via the 2026-09-09 statement text) without addressing the specific UX.

---

## 5. Source register (LG-official.md)

| Source | Rank | What it establishes |
|---|---|---|
| LG US Newsroom statement, 2026-09-12 (via Wayback) | C | The official "what LG says" baseline; concessions in §1.3 |
| Tom's Hardware, 2026-09-09 (statement first published) | C (text) / D (report) | "not true" line; full statement; LG didn't address plaintext transcripts/RCE |
| The Register, 2026-09-08/09 | D | 27-country ACR expansion (2022); fact-sheet 49M/363M figures; "own the living room"; monitor/McAfee statement |
| The Verge, 2026-09-12 | D | "misconceptions" line; audio-fingerprinting quote; "not enabled by default"; what LG didn't address |
| Engadget, 2026-09-12 | D | 10 s / 18 s session language; "not uploaded later when offline"; 5-yr context |
| lgads.tv (site-privacy-policy, technology, solutions, company) | C | Alphonso = LG Ad Solutions entity; ACR mechanism claims; opt-out claims; 49M/216M; cross-device claims |
| lg.com/uk/privacy (corporate policy, 2026-04-29) | C | Stated collections incl. voiceprints, router info, network environment, data brokers |
| gb.lgappstv.com / lgemembers.com (Smart Media Product Membership Privacy Policy, June 2026) | C (partial) | Existence/host/contact of the TV-specific policy; full text behind login |
| us.lgappstv.com notices (LG Content Store → LG Apps, 2026-04-29) | C (partial, via snippet) | Store rename; policy update dates |
| Pocket-lint, 2025-12-22 + 2026-07-29 | D | Live Plus on-TV text; toggle path; Live Plus observed on by default (conflicts with LG's "off by default" claim) |
| fightback-research-notes.md (our repo, from B/C lists) | B/C | Alphonso ownership since 2021; endpoint inventory; Tier-0 privacy paths (needs-confirmation) |
| IMC 2024 (Anselmi et al., SafeNetIoT/ACR; arXiv 2409.06203) | A | LG ACR = Alphonso endpoints, 10 ms/15 s cadence, opt-out stops traffic (see gamers-nexus-2026.md) |

### Open items (not resolved this pass)
- Full text of the Smart Media Product Membership Privacy Policy (login-gated).
- Whether LG's "ACR off by default" matches shipped state (Pocket-lint D says on by
  default on a 2025/26 retail set; LG statement C says off by default). Unresolved
  discrepancy — worth testing on an owned set.
- The 27-country ACR rollout press release (2022) original text on lgads.tv/news.
- LG newsroom statement date is 2026-09-12 (published); the shorter Tom's Hardware
  statement was dated 2026-09-09 — treat "the LG statement" as one statement family
  published in stages 09-09 → 09-12.
