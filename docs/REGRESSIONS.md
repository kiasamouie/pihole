# Regression register

Record of security/functional tests that FAILED and were fixed, so the same
failure cannot silently return. Each entry has a re-verification command.

---

## R-001 — Cloud voice answered with `standard-no-voice` v1 (FAIL → fixed)

| | |
|---|---|
| Date | 2026-09-21 ~11:57 UTC |
| Test | Cloud-dependent voice request: "What is the weather in Tokyo?" (location declined) |
| Policy active | `standard-no-voice` v1 (2 exact Bixby hosts + 35 standard domains) |
| Expected | cloud answer fails (voice path blocked) |
| Actual | TV returned fresh Tokyo weather → cloud path still open |
| Result | **FAIL** |
| Root cause | the policy's voice tier did not cover the TV's active voice plane `prdcore1-euw1-user.aibixby.com` (Bixby EU user plane, AWS eu-west-1) — see reports/09 |
| Fix | `standard-no-voice` v2: scoped `aibixby.com` suffix policy (Pi-hole regex + resolved IP set); re-applied live 2026-09-21 |
| Re-verify | `sudo scripts/voice-proof-capture.sh` → the three cloud questions in VOICE_BLOCK_VERIFICATION.md must all fail to produce a fresh cloud answer |

## R-002 — Post-enablement DNS + connection to the unblocked Bixby user plane (FAIL → fixed)

| | |
|---|---|
| Date | 2026-09-21 11:57:53 UTC |
| Test | Policy coverage check (server-side) |
| Expected | every Bixby voice host denied for 192.168.0.197 |
| Actual | `prdcore1-euw1-user.aibixby.com` FORWARDED (real IPs) and TV connected to all 3 ELB IPs; `bixby-developer-assets.aibixby.com` FORWARDED 8 s later |
| Result | **FAIL** |
| Fix | same as R-001 (suffix policy); live set now contains 54.73.238.66 / 54.194.216.100 / 63.33.161.193 (verified present in `tv_privacy_blocked`) |
| Re-verify | `sudo nft list table ip tvguard \| grep -c '54.73.238.66\|54.194.216.100\|63.33.161.193'` → 3; `scripts/privacy-policy-status.sh` shows 1 regex entry in the group |

## R-003 — (tooling) pre-existing conntrack/TV-DNS-cache state survives a policy change (design limitation, mitigated)

| | |
|---|---|
| Finding | deny rules match `ct state new` only; established voice connections and TV-side cached DNS answers survive an (re-)apply |
| Mitigation | `scripts/privacy-reset-tv-voice-state.sh` after every apply that adds voice denies (per-TV, per-IP, never global) |
| Re-verify | after apply: `sudo conntrack -L \| grep 192.168.0.197 \| grep -E '54.73.238.66\|54.194.216.100\|63.33.161.193'` → empty |
