# Report 10 — Manufacturer Lockdown (Samsung deny-by-default)

Date: 2026-09-22 · State: **ACTIVE on <SAMSUNG_TV_IP>** (applied 10:54Z)

## 1. What changed vs. `standard-no-voice`

`standard-no-voice` was a known-bad denylist: it blocked exactly the 37 reviewed
domains + the aibixby family, and every other Samsung hostname it had never
seen got Internet access for free. `manufacturer-lockdown` (mlock) inverts the
default for **Samsung-owned zones only**:

```
Samsung-owned zone + keep-list host        → ALLOW (group-scoped allow row)
Samsung-owned zone + explicit tier deny    → DENY (exact/regex deny)
Samsung-owned zone + anything else (NEW)  → DENY + LOG (zone regex)
Non-Samsung domain                         → UNCHANGED (normal egress)
```

A brand-new Samsung telemetry/ACR/voice hostname introduced tomorrow does not
get Internet access: the zone regex denies it at DNS, it is recorded in
`data/manufacturer-unknown/`, and the owner reviews it with
`scripts/manufacturer-review.sh keep|block|list`.

mlock = `standard-no-voice` (37 exact + aibixby regex) **+ 13 zone regexes +
19 keep rows**. It does **not** inherit strict's low-confidence telemetry or the
DoH-IP set.

## 2. Zones (config/manufacturer.yaml)

| Zone | Ownership (2026-09-21 RDAP/CT/lists) | Disposition |
|------|--------------------------------------|-------------|
| samsungacr.com | Samsung, dedicated ACR | deny-default |
| samsungads.com | Samsung, advertising | deny-default |
| samsungcloud.tv | Samsung (2017 reg, YesNIC Seoul, Route53) | deny-default (EPG + fc kept) |
| samsungcloud.com | Samsung | deny-default (play/api kept) |
| samsungcloudcdn.com | Samsung, OTA CDN | deny-default (otn kept) |
| samsungcloudsolution.com | Samsung TV platform | deny-default (time/cdn kept) |
| samsungcloudsolution.net | Samsung TV platform (.net twin) | deny-default (lcprd1/configprd/otnprd* kept) |
| samsungotn.net | Samsung, OTA | deny-default (www kept) |
| samsungnyc.com | Samsung NY media CDN | deny-default (img-resize-cdn-prod kept) |
| samsung.com | Samsung corporate + TV | deny-default (multiscreen kept) |
| samsungosp.com | Samsung account auth + push | deny-default (auth/eu-auth2/gld.push kept) |
| bixbyllm.com | Samsung, Bixby LLM / Samsung Intelligence | deny-default |
| sbixby.com | Samsung, Bixby voice/AI plane | deny-default |
| **samsungqbe.com** | Samsung, dynamic app infra | **NOT a zone** — Perflyst #82: blocking breaks YouTube/Prime/TV Plus. Family stays allowed. |
| **samsungadhub.com** | **NOT Samsung today** — domain lapsed, drop-captured (Namebright expired NS → DropCatch registrar, RDAP 2026-09-21) | NOT a zone — its names stay explicit ad-tier denies only |
| aibixby.com | Samsung, 100% Bixby (CT analysis) | deny-default via the existing scoped `*.aibixby.com` voice regex |

## 3. Enforcement layers (same source of truth)

| Layer | What | Scope |
|-------|------|-------|
| nftables `table ip tvguard` | `tv_privacy_blocked` (166 resolved deny IPs) + drop rule; DoT 853 drop; external :53 DNAT to Pi-hole — all matching the **`tv_privacy` set = `applies_to` = {<SAMSUNG_TV_IP>} only** | Samsung only (Google TV .90 unaffected — verified 2026-09-22) |
| Pi-hole group `TVGuard-Privacy` (id 13) | 37 exact denies + 14 regex denies (aibixby + 13 zones) + 19 allow rows (keep wins; FTL allow beats deny) | client <SAMSUNG_TV_IP> only |
| keep-list | `config/manufacturer-keep.yaml` (19 documented hosts) + `config/privacy-keep.yaml` (global) | overrides all denies |
| logging | denied zone queries logged by Pi-hole; unknown Samsung hosts tracked in `data/manufacturer-unknown/` (git-ignored) | review via show-unknown-samsung.sh / manufacturer-review.sh |

**Scope fix (2026-09-22):** before today the firewall privacy rules matched the
full `tvs` set, which also contains the Google TV `<GOOGLE_TV_IP>` — i.e. the
Samsung policy was silently being applied to the Google TV. The engine now
renders a dedicated `tv_privacy` set from `applies_to` and all privacy/DoT/
DNS-forcing rules match it. The TVGuard core rules (TV→LAN, monitor log,
masquerade) still match `tvs` (both TVs). UFW route rules for both TVs are
unchanged (hash-verified).

## 4. Destination table (mlock live)

| Destination | Owner | Category | Allowed/Denied | Why | Evidence |
|---|---|---|---|---|---|
| log-ingestion(-eu).samsungacr.com, log-config.samsungacr.com, log-1/2/3.samsungacr.com, acr0.samsungcloudsolution.com, acr-*-prd.samsungcloud.tv | Samsung | ACR | **DENY** | viewing-history collection | SafeNetIoT IMC'24 + local capture + Perflyst |
| *.samsungacr.com (zone) | Samsung | ACR | **DENY+LOG** | unknown ACR hosts get no free pass | mlock zone policy |
| catalyst/rtb/tvx.adgrx.com, rtb-config/tvp-ads-log.samsungads.com, googleads.g.doubleclick.net, static.doubleclick.net, ad/rd.samsungadhub.com, samsungtv-d.openx.net | 3rd/Samsung | Ads | **DENY** | reviewed ad infrastructure | local capture + lists |
| *.samsungads.com (zone) | Samsung | Ads | **DENY+LOG** | new ad hosts get no free pass | mlock zone policy |
| qoe.samsungcloud.tv, nrdp.logs.netflix.com, eligibility-panelresearch.googlevideo.com, fkp/sas/… (standard set) | mixed | Telemetry (high-conf) | **DENY** | reviewed non-essential telemetry | local capture + lists |
| *.aibixby.com, *.bixbyllm.com, *.sbixby.com | Samsung | Voice/Bixby | **DENY** | confirmed voice cloud plane (R-001: prdcore1-euw1-user.aibixby.com) | reports/09 + CT + local capture |
| time.samsungcloudsolution.com | Samsung | Time sync | **ALLOW** | blocking breaks playback apps | Perflyst/fightback + local |
| cdn.samsungcloudsolution.com | Samsung | Content/update checks | **ALLOW** | system update checks | Perflyst + local |
| lcprd1/configprd.samsungcloudsolution.net, otnprd8/9/10/11.samsungcloudsolution.net, www.samsungotn.net, otn.samsungcloudcdn.com | Samsung | OTA/core platform | **ALLOW** | Perflyst #60 + breakage docs | Perflyst + local |
| play/api.samsungcloud.com | Samsung | App platform | **ALLOW** | Smart Hub/app functionality | local capture |
| auth/eu-auth2/gld.push.samsungosp.com | Samsung | Account auth + push | **ALLOW** | sign-in + notifications | Perflyst + local |
| tvpnlinupepgpeu.samsungcloud.tv, fc.samsungcloud.tv | Samsung | TV Plus EPG / workhorse | **ALLOW** | heaviest observed Samsung domains; fc uncharacterised → never block uncharacterised | local capture |
| multiscreen.samsung.com, img-resize-cdn-prod.samsungnyc.com | Samsung | Casting/imaging | **ALLOW** | casting + UI imagery | fightback + local |
| *.samsungqbe.com | Samsung | App infra (dynamic) | **ALLOW (family)** | Perflyst #82 breakage evidence | Perflyst issues |
| any other *.samsungcloud*.com/.net/.tv / *.samsung.com / *.samsungosp.com / *.samsungotn.net / *.samsungnyc.com / *.samsungcloudcdn.com host | Samsung | **UNKNOWN** | **DENY + LOG** | deny-by-default; review via manufacturer-review.sh | mlock zone policy |
| YouTube / Google video CDN, Netflix, Prime/Amazon, Plex, CloudFront/AWS shared infra | 3rd party | Essential app infra | **ALLOW (untouched)** | keep-list + no generic wildcards by design | keep-wins collision checks |

## 5. Unknown-Samsung observations

`scripts/show-unknown-samsung.sh 24` (2026-09-22): 3,6xx Samsung-zone queries
from .197 in 24 h → **0 unknown**, 19 allowlisted. Everything the TV tried in
the Samsung zones was either a documented keep or an already-classified deny.

## 6. Bypass-vector status (honest)

| Vector | Status |
|---|---|
| ACR (known + unknown hosts) | **CONTROLLED** (exact + zone regex + resolved-IP firewall deny) |
| Voice/Bixby cloud | **CONTROLLED** (*.aibixby.com + bixbyllm + sbixby zones; R-001 regression covered) |
| Samsung telemetry (known) | **CONTROLLED** |
| Unknown Samsung egress | **CONTROLLED + LOGGED** (deny-by-default; this is the new guarantee) |
| Hard-coded IPv4 DNS | **CONTROLLED** (:53 DNAT to Pi-hole, scoped to .197) |
| DoT 853 | **CONTROLLED** (drop, .197 only) |
| DoH over 443 | **PARTIALLY CONTROLLED** (known dedicated DoH frontends are in the 166-IP deny set when they resolve to non-shared IPs; DoH multiplexed on shared CDN/443 cannot be distinguished at the network layer — no blanket 443 rule, by design) |
| Direct IP (dedicated Samsung infra) | **CONTROLLED** (deny set is IP-based) |
| Direct IP (shared AWS/CloudFront) | **NOT CONTROLLED (accepted)** — blocking shared IPs would break Prime/Netflix/YouTube; hostname-level control only |
| IPv6 | **NOT CURRENTLY APPLICABLE** (re-verified 2026-09-22: <LAN_INTERFACE> link-local only, accept_ra=0, no global route) |
| QUIC/UDP-443 | **INTENTIONALLY ALLOWED** (no rule touches it) |
| Shared-CDN telemetry | **PARTIALLY CONTROLLED** (exact-domain DNS denies only; IP collides with keep infra) |
| Offline-buffered uploads | **DETECTABLE, NOT PROVABLE** — tv-offline-reconnect-test.sh can prove "X bytes to Y after reconnect"; it cannot prove content |
| LAN access (TV→LAN) | **NOT CONTROLLED (accepted)** — egress policy only |

## 7. Tests

- Full selftest (4 profiles, netns + throwaway table + throwaway Pi-hole group): **241 passed, 0 failed** (2026-09-22, post scope-fix).
- Throwaway mlock cycle (mock group TVGuard-Privacy-MOCK2 + dry table): apply → verify (172 deny IPs, 14 regexes verbatim, 19 allows, no 443 rules) → disable → clean; real table/UFW/Docker hashes unchanged.
- Live apply 10:54Z: 166 deny IPs, 19 allows, group 13 = 70 rows, client .197 only.
- `privacy-live-check.sh`: **10/10 PASS** incl. the two new scope assertions (tv_privacy = applies_to only; no @tvs privacy rules).
- Rollback: `privacy-policy-disable.sh` mock cycle verified (group deleted, dry table removed, real state hash-identical, UFW hash identical, docker identical). Live disable not exercised (policy intentionally left ACTIVE).

## 8. Rollback

One command: `sudo scripts/privacy-policy-disable.sh`. Removes the deny/DoT
rules (table re-render, privacy state off), deletes group TVGuard-Privacy with
all 70 rows (37 exact + 14 regex + **19 allow rows**) and the client
attachment. NAT, masquerade, DNS DNAT, monitor mode, UFW, Docker, other
Pi-hole groups untouched. See docs/ROLLBACK.md §R0a.
