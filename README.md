# kiaserver DNS / TV-telemetry PoC

Proof-of-concept (built like a prod setup) for controlling smart-TV telemetry
on a home LAN: Pi-hole v6 (Docker) + per-device policy groups + passive
traffic-analysis tooling + documented path to a proper gateway/firewall.

**Nothing in this repo changes the live network.** No DHCP, no DNS
redirection of clients, no router changes, no firewall enforcement against
LAN clients. Pi-hole is up but nobody points at it until the staged rollout
in `ROUTER_NEXT_STEPS.md` is performed manually.

## Layout

```
compose.yaml            Docker Compose for Pi-hole (pinned image)
.env.example            template; run scripts/make-env.sh on a fresh machine
.env                    (git-ignored, mode 600) holds ADMIN_PASSWORD
etc-pihole/             (git-ignored) Pi-hole state: config, gravity DB, query log
reports/                audit, LAN inventory, visibility analysis, raw evidence
data/                   lan-inventory.csv, pcaps (git-ignored)
scripts/                see below
REPORT.md               full report (read this first)
ROUTER_NEXT_STEPS.md    staged instructions for the Virgin Hub changes
ROLLBACK.md             how to stop/disable/remove everything
```

## Scripts

| Script | What it does | Needs |
|---|---|---|
| `scripts/make-env.sh` | create `.env` with a strong random admin password | fresh machine |
| `scripts/setup-pihole-groups.py` | idempotent per-device groups + client registration (Phase 6) | Python 3 |
| `scripts/pihole-selftest.py` | local end-to-end test: login, block, unblock, query log | Python 3 |
| `scripts/discover-lan.sh` | re-run passive LAN discovery, refresh inventory | sudo |
| `scripts/capture-device.sh` | passive per-device tcpdump (headers, not payloads) | sudo |
| `scripts/show-dns-activity.py` | per-client DNS activity from the Pi-hole API | Python 3 |
| `scripts/show-device-destinations.sh` | live conntrack view of a device's current connections | sudo |
| `scripts/health-check.sh` | verify existing services + Pi-hole + safety invariants | sudo |

## Fresh-machine setup (offload to the future dedicated box)

```bash
git clone <repo> && cd dns
scripts/make-env.sh            # prints the password once - record it
docker compose up -d
python3 scripts/setup-pihole-groups.py   # recreate groups/clients
python3 scripts/pihole-selftest.py       # verify
```

Prerequisites on the new box: Docker + compose plugin, host ports 53 and 3001
free (or adjust `compose.yaml`), UFW/iptables allowing them, and a static IP
reserved in the router for the new box's NIC.

## Security notes

- Admin password lives only in `.env` (mode 600, git-ignored). Never commit it.
- Image is pinned to `pihole/pihole:2026.09.0` (v6 stable). Update by changing
  the tag deliberately, not by tracking `latest`.
- `etc-pihole/` contains the query log (device + domain names). It is local to
  this machine and git-ignored; treat it like log data.
