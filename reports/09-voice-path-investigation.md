# 09 — Voice-Path Investigation (the Tokyo-weather regression)

Date: 2026-09-21 (UTC)
Samsung: QE65Q75CATXXU, 192.168.0.197, gw/DNS 192.168.0.128
Policy at time of test: `standard-no-voice` v1 (37 exact domains, 2 Bixby hosts)

---

## 1. The failed test (recorded as regression R-001)

| | |
|---|---|
| TEST | Cloud-dependent voice request (fresh external information) |
| SETUP | `standard-no-voice` v1 live (applied 11:41:08Z), TV on home screen |
| INPUT | "What is the weather in Tokyo?" (location prompt declined) |
| EXPECTED | Fail — cloud voice path is blocked by policy |
| ACTUAL | **Success** — TV returned current Tokyo weather |
| RESULT | **FAIL** |

Samsung's own TV documentation confirms the test is meaningful: Bixby on
Samsung TVs answers weather questions and **requires an active Internet
connection**; TVs can be configured with Bixby *or* Amazon Alexa. A fresh
weather answer therefore requires a working cloud path — the policy's
objective (no cloud voice) was **not** met.

## 2. What the evidence showed

Mining of Pi-hole query history (11:25→12:50Z), TVGuard kernel logs, the
30-minute safety-watch log, and conntrack produced:

| Time (UTC) | Event | Layer |
|---|---|---|
| 11:32:15 | `prd-euw1-ucs.aibixby.com` **FORWARDED** (real IP returned) — pre-enablement voice session | DNS |
| 11:41:08 | `standard-no-voice` v1 applied (2 Bixby exact domains + 135 IPs) | policy |
| 11:42:27+ | TV re-queries `prd-euw1-ucs` / `acr-eu-prd.samsungcloud.tv` → **DENYLIST** (TV-side cache expired; retries 11:51–11:54) | DNS |
| **11:57:53** | **`prdcore1-euw1-user.aibixby.com` FORWARDED** — NOT in the v1 block list; TV connected to its 3 AWS eu-west-1 ELB IPs (54.73.238.66 / 54.194.216.100 / 63.33.161.193) in the same second | **DNS + firewall gap** |
| 11:57:58 | `eu-auth2.samsungosp.com` FORWARDED (Samsung account auth — keep family, intentionally not blocked) | DNS |
| 11:58:01 | `bixby-developer-assets.aibixby.com` FORWARDED (CloudFront; 8 s after the user-plane query) | DNS |
| 11:25–13:00 | `TVGUARD-PRIVACY` drops = 1 total; `TVGUARD-DOT` = 0; no alexa/amzn names at any time | firewall |

All evidence files: `research/tmp/` (git-ignored): `voice-analysis-tail.txt`,
`pihole-forwarded-197.txt`, `journal-tvguard.txt`, `watch-log.txt`,
`conntrack-197.txt`, `crtsh-aibixby-names.txt`, `voice-resolve.txt`,
`voice-ip-ownership.txt`, `live-policy-state.txt`.

## 3. Root cause

**The v1 voice tier blocked 2 of the ~20 live hosts of the TV's actual voice
platform.** The TV's live cloud-voice path is the **Bixby EU user plane**,
`prdcore1-euw1-user.aibixby.com` (AWS eu-west-1, k8s-ingress ELB), which was
never in the policy. The two v1 hosts (`prd-euw1-ucs`,
`provisioning-use2.mgmt`) were real but were not the active data path on this
TV/region at the time of the test. Secondary amplifier: the deny rule matches
`ct state new` only, so any pre-existing connection to a voice IP survives a
policy change until it expires (handled by the new
`scripts/privacy-reset-tv-voice-state.sh`).

## 4. ACTIVE VOICE BACKEND: **BIXBY** (Samsung), hosted on AWS eu-west-1

Evidence ranking (local traffic > lists > docs):

- **OBSERVED BY US** (strongest): the 11:57:53 fresh resolution + immediate
  ELB connection of `prdcore1-euw1-user.aibixby.com` inside the voice window;
  retry storms on the two v1-blocked Bixby hosts after their blocks bit.
- **Research**: the entire `aibixby.com` zone is Samsung's Bixby/AI-assistant
  cloud. Certificate transparency (crt.sh, 2026-09-21: 456 certs → 83 unique
  names) shows only Bixby infrastructure: regional user planes
  (`bixby2-user-*`, `bixby3-user-*`, `prdcore1-euw1-user`, …), user-command
  services (`*-ucs`), provisioning/management (`mgmt.*`, `ash-*`, `btc-*`,
  `market-*`, `ums-*`), OAuth, partner services (Spotify/Uber integrations),
  LLM gateways (`*.llm.aibixby.com`), and internal tooling (jenkins/vault).
  **No app-store, OTA, EPG, or content infrastructure lives in the zone.**
  All 25 probed hosts resolve to AWS (EC2/ELB eu-west-1, us-east-2,
  ap-northeast-2) or AWS CloudFront — no Samsung-owned infrastructure.
- **Alexa: rejected.** Zero `alexa`/`amzn`/AVS names from this TV in the whole
  window; the only Amazon traffic was the keep-list Prime Video hosts
  (30-minute-interval beacons). This TV's assistant backend is Samsung's, not
  Amazon's.

## 5. Candidate table (ranked)

| Destination | Seen during voice | Seen idle | Byte spike | DNS/SNI evidence | Owner | Role | Confidence | Block candidate |
|---|---:|---:|---:|---|---|---|---|---|
| prdcore1-euw1-user.aibixby.com → 54.73.238.66 / 54.194.216.100 / 63.33.161.193 (AWS eu-west-1 ELB) | YES (11:57:53, post-enablement) | no fresh DNS | new connection in-voice | fresh FORWARDED + 3 ELB SYN packets, journal 11:57:53 | Samsung (Bixby) | **CONFIRMED VOICE PATH** (Bixby EU user plane) | HIGH | **BLOCKED in v2** (regex + IP set) |
| bixby-developer-assets.aibixby.com (CloudFront) | YES (11:58:01, +8 s) | no | n/a (no pcap) | fresh FORWARDED in-voice | Samsung (Bixby) | STRONGLY CORRELATED (Bixby platform assets) | MEDIUM-HIGH | **BLOCKED in v2** (regex) |
| prd-euw1-ucs.aibixby.com (AWS eu-west-1) | YES (11:32:15 pre-enable; retry storm post-block) | YES | n/a | FORWARDED pre, DENYLIST post | Samsung (Bixby) | CONFIRMED VOICE PATH (user-command service) | HIGH | BLOCKED (v1, unchanged) |
| provisioning-use2.mgmt.aibixby.com (AWS us-east-2) | retry storm 11:51–11:54 post-block | YES | n/a | DENYLIST hits | Samsung (Bixby) | CONFIRMED (voice service provisioning) | HIGH | BLOCKED (v1, unchanged) |
| eu-auth2.samsungosp.com (AWS) | YES (11:57:58) | YES (account auth throughout) | n/a | FORWARDED | Samsung | POSSIBLE SUPPORT (account auth used before voice calls) — shared with essential account functionality | MEDIUM | **NOT blocked** (keep family, §keep) |
| 108.128.84.11:5229 (AWS eu-west-1 EC2, pre-existing long-lived TCP) | not attributable | YES (established before 11:25) | not measurable (flow predates window; conntrack build lacks per-flow bytes) | no DNS tie in our window | Samsung-hosted (inferred) | **UNKNOWN** — persistent channel (XMPP-style port); possibly push/assistant keep-alive | LOW | NOT blocked (unknown ≠ deny); watch via discovery tool |
| bixbyllm.com (scs-use2, scs-config-use2, scs-gatekeeper-use2 — GCP) | NO local evidence | NO | — | resolves (GCP); HaGeZi 2026 issue attributes it to "Samsung Intelligence Service" on **Galaxy** devices | Samsung | UNKNOWN (real zone, no observed use by this TV) | LOW | NOT blocked; re-test if voice still works after v2 |
| sbixby.com (rb.*, bixby-cloud-cp.* — CT only) | NO local evidence | NO | — | CT-only names, apex NODATA | Samsung | UNKNOWN | LOW | NOT blocked; watch |
| unagi-eu.amazon.com / qgmg.api.amazonvideo.com / api.amazon.co.uk | no (30-min beacons) | YES | n/a | keep-list Prime Video infrastructure | Amazon/Infinitive | ESSENTIAL APP INFRASTRUCTURE | HIGH | NEVER block (keep) |

## 6. The v2 policy (what changed and why)

`standard-no-voice` v2 = v1 **+ one scoped suffix policy: `aibixby.com`**
(`kind: suffix` entry in `config/privacy-policy.yaml`).

Justification against the project's own suffix rule (all four conditions met):

1. **Bixby-specific per research** — CT enumeration (83 names) + resolution of
   25 hosts: only Bixby/AI-assistant services in the zone.
2. **No core TV infrastructure** — no app-store/OTA/EPG/content hosts;
   keep-list (privacy-keep.yaml) contains zero aibixby entries → no keep
   collision, so no keep-override was needed.
3. **Locally confirmed** — TV actively queries and connects to user-plane
   hosts on voice use (11:57:53 evidence above).
4. **Structurally safe** — selftest proves: no rule touches TCP/443 or
   UDP/443; the IP set excludes any IP shared with keep-list infrastructure
   (keep wins); the policy still applies only to 192.168.0.197.

Two enforcement layers, by design:

- **DNS layer (primary, complete):** Pi-hole regex deny
  `^(\S+\.)?aibixby\.com\.?$` in the group-scoped `TVGuard-Privacy` group
  (client .197 only). This covers *all* present and future aibixby
  subdomains, including ones Samsung has not deployed yet — because every
  path to external DNS from this TV is forced through Pi-hole (:53 DNAT) and
  DoT (853) is dropped.
- **IP layer (second, best-effort):** the `tv_privacy_blocked` set gains the
  resolved IPs of the 13 enumerated `hosts:` (plus the apex), minus any
  keep-list collision. It protects against TV-side cached DNS answers: a
  *new* connection to a cached voice IP is dropped and logged
  (`TVGUARD-PRIVACY`). IP sets lag dynamic DNS by design; the DNS layer is
  authoritative.

**Not added (deliberately):** `*.bixbyllm.com`, `*.sbixby.com`, any
`*voice/*assistant*` name, any `amazonaws.com`/`cloudfront.net`/`a2z.com`
wildcard, any blanket 443/QUIC rule. If post-v2 testing shows a failover to
another family, the iteration protocol is: discover → research → add exact/
scoped entry → mock-test → re-apply → reset conntrack → re-test.

## 7. Known residual gaps (stated, not hidden)

1. **TV-side DNS cache + open connections at apply time.** A policy change
   does not kill an existing TLS session. Fix applied: run
   `scripts/privacy-reset-tv-voice-state.sh` after (re-)applying — it deletes
   only `.197 ↔ voice-IP` conntrack entries (both directions) and never
   touches any other flow, UFW, Docker or Pi-hole.
2. **Future failover to a different family** (bixbyllm/sbixby/other). Not
   locally evidenced today, so not blocked. The voice-proof capture will show
   it immediately if it happens (fresh DNS + new IP in the active window).
3. **The 108.128.84.11:5229 persistent channel.** Unknown purpose, no DNS
   tie, pre-dates all captures. Not blocked (unknown ≠ deny). If voice still
   works after v2, this is the first thing to correlate with a proof capture.
4. **Shared IP infrastructure.** If Samsung ever points a voice host at an
   IP that also serves a keep-list domain, the build automatically removes
   that IP from the firewall set and relies on the DNS layer (by design —
   never drop a shared CDN IP).
5. **Encrypted content.** Everything above is metadata-level. No statement
   is made about what is *inside* any TLS stream; "voice path" = the
   destination that carries the voice interaction, proven by temporal
   correlation, not by payload inspection.

## 8. Tooling added by this investigation

- `scripts/privacy-reset-tv-voice-state.sh` — per-TV conntrack expiry for
  voice IPs (safe, targeted; optional Pi-hole cache flush).
- `scripts/voice-path-discovery.py` + `voice-path-discovery.sh` — 1 Hz
  recorder: snaplen-128 tcpdump (headers only) parsed offline into per-second
  per-flow byte deltas + conntrack lifecycle + Pi-hole DNS + TVGuard
  counters → `captures/voice-discovery/<label>-<ts>/`.
- `scripts/voice-proof-capture.sh` — one-command 7-minute proof capture
  (120 s pre / 120 s ACTIVE voice window / 180 s post) with on-screen
  countdown instructions.
- Selftest additions: suffix-regex content assertions (senv has exactly the
  aibixby.com suffix; standard has none; strict has it) + regex mock-client
  block test.
- `REGRESSIONS.md` (R-001, R-002) so this failure cannot be forgotten.

## 9. Verification protocol

See `VOICE_BLOCK_VERIFICATION.md` (one command:
`sudo scripts/voice-proof-capture.sh`, then three physical voice questions;
expected: all three cloud answers fail, everything else works).
