# kiaserver TV-privacy PoC (TVGuard)

Proof-of-concept (built like a prod setup) for controlling smart-TV outbound
traffic on a home LAN — **and reproducible on a dedicated machine via git**.

Layers (all proven on kiaserver; the future dedicated box inherits this repo):

1. **Pi-hole v6** (Docker, pinned image) — DNS logging + per-device groups
2. **One-arm IPv4 gateway** — selected TVs use this box as gateway/DNS;
   SNAT/masquerade → Virgin Hub → Internet (return path included)
3. **nftables egress policy** — a separate, removable `tvguard` table with
   `monitor` (log/count, no deliberate blocks) and `enforce` (tested blocks)
   modes; DNS-bypass attempts transparently redirected to Pi-hole
4. **Evidence tooling** — per-session TV activity recording + comparison,
   evidence-ledger destination classification (`config/destinations.yaml`)
5. **Privacy policy (researched, generated, tested — OFF by default)** —
   exact-domain deny policy for the target TV(s) in three profiles
   (`standard` / `standard-no-voice` / `strict`), resolved to IPs by an
   external resolver, applied via a dedicated nftables set **and** a dedicated
   Pi-hole group, with a documented keep-list that overrides everything. One
   command on, one off. See `FINAL_BLOCKING_PLAN.md` before enabling.

**Nothing here changes the live network until you point a TV at this box.**
No DHCP, no router changes, no client redirection, no blanket firewalling of
LAN devices. Existing services (Plex, Samba, Transmission, SSH, invoice stack)
are never touched by TVGuard's enable/rollback paths.

## Layout

```
bootstrap.sh            fresh-Debian deployment (new machine)
compose.yaml            Docker Compose for Pi-hole (pinned image)
.env.example            template; scripts/make-env.sh generates .env
.env                    (git-ignored, 600) admin password
etc-pihole/             (git-ignored) Pi-hole state
config/tvguard.conf.example   TVGuard config template (machine-specific)
config/tvguard.conf   (git-ignored) your live values
config/destinations.yaml      evidence ledger (classification source of truth)
config/privacy-policy.yaml    privacy policy source of truth (deny tiers)
config/privacy-keep.yaml      never-block / keep-list (overrides the policy)
deploy/tvguard.service.in     systemd unit template (installed by bootstrap)
research/                   blocklist snapshots + cross-reference evidence
reports/                audits, inventory, visibility, TVGuard design, raw evidence
data/                   lan-inventory.csv; privacy-policy/ + offline-reconnect/ (git-ignored, generated)
captures/               (git-ignored) tv-session.sh session recordings
scripts/                see below
REPORT.md               full report (read this first)
ROUTER_NEXT_STEPS_V2.md your manual steps only (Hub + Samsung)
ROLLBACK.md             one-command firewall rollback + full removal
REVIEW_BEFORE_BLOCKING.md  human review dataset (destinations by category)
FINAL_BLOCKING_PLAN.md   what standard / standard-no-voice / strict block, keep, force, leave working
TV_MANUAL_TEST_CHECKLIST.md  ordered physical TV tests with PASS/FAIL + diagnostics
ENABLE_STANDARD_NO_VOICE.md  step-by-step enablement guide for the recommended profile
MIGRATION_TO_DEDICATED_BOX.md  move this repo to the dedicated x86 box
```

## Scripts

| Script | What it does | Needs |
|---|---|---|
| `scripts/tvguard-status.sh` | read-only TVGuard state (table, counters, mode) | sudo |
| `scripts/tvguard-enable-monitor.sh` | apply ruleset in MONITOR mode (logging only; idempotent) | sudo |
| `scripts/tvguard-enable-enforce.sh` | apply ruleset in ENFORCE mode (tested blocks only) | sudo |
| `scripts/tvguard-disable.sh` | **one-command rollback**: removes only the tvguard footprint | sudo |
| `scripts/tvguard-apply.sh` | the engine: render → `nft -c` → atomic replace of `table ip tvguard` | sudo |
| `scripts/tvguard-selftest.sh` | mock-TV netns test of DNS-redirect + masquerade + UFW coexistence | sudo |
| `scripts/tv-session.sh` | record one labelled TV session (flows, DNS, counters) → `captures/` | sudo |
| `scripts/session_analyze.py` | builds connections.csv / dns.csv / summary.md per session | internal |
| `scripts/compare-tv-sessions.py` | compare 2+ sessions; separates observed / inference / classification | python3 |
| `scripts/gen-policies.sh` | show/push the destinations.yaml policy (enforce phase) | python3 |
| `scripts/make-env.sh` | create `.env` with a strong random admin password | fresh machine |
| `scripts/setup-pihole-groups.py` | idempotent per-device groups + client registration | python3 |
| `scripts/pihole-selftest.py` | local end-to-end Pi-hole test (login, block, allow, query log) | python3 |
| `scripts/discover-lan.sh` | re-run passive LAN discovery, refresh inventory | sudo |
| `scripts/capture-device.sh` | passive per-device tcpdump (headers, not payloads) | sudo |
| `scripts/show-dns-activity.py` | per-client DNS activity from the Pi-hole API | python3 |
| `scripts/show-device-destinations.sh` | live conntrack view of a device's current connections | sudo |
| `scripts/health-check.sh` | verify existing services + Pi-hole + TVGuard + safety invariants | sudo |
| `scripts/privacy-policy-build.py` | resolve privacy-policy.yaml → resolved.json (external resolver, keep-list collision check) | python3 |
| `scripts/privacy-policy-apply.sh` | **enable** standard/standard-no-voice/strict: firewall sets + Pi-hole group (idempotent, scoped to `applies_to`) | sudo |
| `scripts/privacy-policy-disable.sh` | **one-command privacy rollback**: removes only deny sets + Pi-hole group | sudo |
| `scripts/privacy-policy-status.sh` | read-only privacy state (state file, nft sets, Pi-hole group) | sudo |
| `scripts/privacy-policy-preview.sh` | show what the current resolved policy would block (no changes) | sudo |
| `scripts/privacy-policy-selftest.sh` | netns + throwaway-table + temp-Pi-hole-group test of the whole mechanism | sudo |
| `scripts/privacy-live-check.sh` | post-enable verification (server-side) + the physical TV tests you must run | sudo |
| `scripts/privacy-watch.sh` | N-minute safety watch; `--auto-rollback` disables only the privacy layer on failure | sudo |
| `scripts/tv-offline-reconnect-test.sh` | "store-while-offline → upload-on-reconnect" experiment (failsafe, temporary rule) | sudo |

## Fresh-machine setup (the future dedicated box)

```bash
git clone <repo> && cd dns
sudo ./bootstrap.sh          # installs, deploys Pi-hole, validates, prints TODOs
# then edit config/tvguard.conf for the new NICs/IPs and (when ready):
sudo scripts/tvguard-enable-monitor.sh
sudo scripts/tvguard-selftest.sh
```

## Privacy policy (enable only when you've reviewed FINAL_BLOCKING_PLAN.md)

```
sudo scripts/privacy-policy-apply.sh standard            # ACR + ads + high-conf telemetry + DoT
sudo scripts/privacy-policy-apply.sh standard-no-voice   # + confirmed Bixby/voice (RECOMMENDED; breaks cloud voice only)
sudo scripts/privacy-policy-apply.sh strict              # + low-conf telemetry + DoH-IP set
sudo scripts/privacy-live-check.sh                       # verify (server-side + physical TV checklist)
sudo scripts/privacy-watch.sh 30 --auto-rollback         # safety watch
sudo scripts/privacy-policy-disable.sh                   # full privacy rollback (one command)
```

The policy is EXACT domains only (no Samsung wildcards), resolved via 8.8.8.8
on every apply, with `config/privacy-keep.yaml` overriding all deny candidates
whose IPs collide with essential infrastructure. It is scoped to the TVs in
`applies_to` (currently the Samsung .197 only) and never touches the gateway
path, UFW, Docker, or other clients.

## Security notes

- Admin password lives only in `.env` (mode 600, git-ignored). Never commit it.
- Pi-hole image pinned to `pihole/pihole:2026.09.0` (v6 stable).
- TVGuard never flushes any firewall table; it owns exactly one nftables
  table plus two `ufw route` rules, both removable in one command.
- `etc-pihole/` and `captures/` contain query logs/session metadata (device +
  domain names). Git-ignored; treat as log data. `data/privacy-policy/`
  (resolved ephemeral IPs) and `data/offline-reconnect/` are git-ignored too.
- No TLS interception, no custom CAs, no ARP tricks, no blanket 443/QUIC
  blocks — by design.
