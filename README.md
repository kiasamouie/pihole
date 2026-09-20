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
deploy/tvguard.service.in     systemd unit template (installed by bootstrap)
reports/                audits, inventory, visibility, TVGuard design, raw evidence
data/                   lan-inventory.csv, pcaps (git-ignored)
captures/               (git-ignored) tv-session.sh session recordings
scripts/                see below
REPORT.md               full report (read this first)
ROUTER_NEXT_STEPS_V2.md your manual steps only (Hub + Samsung)
ROLLBACK.md             one-command firewall rollback + full removal
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

## Fresh-machine setup (the future dedicated box)

```bash
git clone <repo> && cd dns
sudo ./bootstrap.sh          # installs, deploys Pi-hole, validates, prints TODOs
# then edit config/tvguard.conf for the new NICs/IPs and (when ready):
sudo scripts/tvguard-enable-monitor.sh
sudo scripts/tvguard-selftest.sh
```

## Security notes

- Admin password lives only in `.env` (mode 600, git-ignored). Never commit it.
- Pi-hole image pinned to `pihole/pihole:2026.09.0` (v6 stable).
- TVGuard never flushes any firewall table; it owns exactly one nftables
  table plus two `ufw route` rules, both removable in one command.
- `etc-pihole/` and `captures/` contain query logs/session metadata (device +
  domain names). Git-ignored; treat as log data.
- No TLS interception, no custom CAs, no ARP tricks, no blanket 443/QUIC
  blocks — by design.
