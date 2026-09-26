# MIGRATION TO THE DEDICATED BOX

The entire PoC is designed so the dedicated x86 machine **is this repository
on a new Debian host** — no rewriting. This document is the migration runbook.

## 0. What carries over / what doesn't

| Carries over (in git) | Stays on the TVGuard box (not committed) |
|---|---|
| All scripts, compose.yaml, config templates, deploy unit template, reports, docs | `.env` (admin password — you write the file path down separately) |
| `.env.example` (template; bootstrap generates `.env` with discovered values) | `etc-pihole/` (Pi-hole state — optionally move for continuity, see §3) |
| — | `captures/` (session recordings — optionally move to keep your evidence base) |
| — | `/var/lib/tvguard/` runtime state (regenerated on enable) |

## 1. Buy a box that fits (requirements summary)

- **2× GbE minimum** (dual-NIC: WAN + LAN). 2.5GbE preferred on the LAN side
  if budget allows (Plex/HDR streaming + future TV traffic).
- Any modern x86_64 mini (Dell/Lenovo/HP Micro/Tiny/SFF), 8 GB RAM (16 GB
  comfortable if you later add Zeek/ntopng), 256 GB SSD minimum.
- Avoid USB-Ethernet for the WAN/LAN role. Intel NICs (i225/i226 or 82574)
  if you want guaranteed nftables/OFED-free behaviour; onboard realtek works
  too but verify `r8169` on your Debian release.
- The box becomes: router (NAT) + Pi-hole + TVGuard. The TVGuard box keeps
  Plex, backups, Samba, Transmission, invoice stack.

## 2. Day-of migration (on the new box, before touching the upstream router)

```bash
# 1. Fresh Debian 13 netinstall (or clone the disk image of the installer you use)
# 2. Create a user, enable ssh, install docker repo if desired — or just run:
git clone <this repo> /home/<user>/dns && cd /home/<user>/dns
sudo ./bootstrap.sh
```

`bootstrap.sh` will: check the OS + free ports (53/3001/3443/8088), install
packages (Docker via the official apt repo if absent), create `.env` (random
admin password — **record it**), deploy Pi-hole, run the self-test and group setup, install the
`tvguard` unit **disabled**, and print the values you still need to set.

Set in `.env`:

```bash
MODE=dualnic-gateway
LAN_INTERFACE=<LAN_NIC>   # your LAN NIC (name from `ip -br`)
WAN_INTERFACE=<WAN_NIC>   # your WAN NIC
LAN_SUBNET=<LAN_SUBNET>
GATEWAY_IP=<new box LAN IP>
PIHOLE_IP=<same>
UPSTREAM_ROUTER=192.168.100.1   # or whatever the upstream router's LAN IP is in modem mode
TVS="<SAMSUNG_TV_IP> <GOOGLE_TV_IP>"
```

`scripts/tvguard-apply.sh` already supports `MODE=dualnic-gateway`: egress
NAT lands on `WAN_INTERFACE` and the forward chain is unchanged. **Bootstrap
does not enable routing or firewall rules by itself** — the new box is inert
until you run `sudo scripts/tvguard-enable-monitor.sh` and point a device at
it.

## 3. Move state (optional but recommended)

```bash
# Pi-hole continuity (gravity DB, groups, clients, query log):
scp -r <tvguard-box>:etc-pihole ./etc-pihole     # then docker compose up -d
# Session evidence base:
scp -r <tvguard-box>:captures ./captures
```
If you skip this, run `scripts/setup-pihole-groups.py` (bootstrap already did)
and start the evidence fresh — the methodology is identical.

## 4. Cutover (you, at the upstream router — staged, never all-at-once)

1. **Reserve** the new box's WAN + LAN MACs on the upstream router.
2. **Modem mode** on the upstream router (or bridge mode). The box gets the public
   connection on WAN. (This is the first step that changes live internet —
   do it alone, with everything else on the PoC already proven.)
3. Bring up the box: static LAN IP, then
   `sudo ./scripts/tvguard-enable-monitor.sh` (or whatever the repo's enable
   script is) and `sudo scripts/tvguard-selftest.sh` on the new box.
4. Point the **Samsung** at the new box (gateway/DNS = new box LAN IP).
   Run the session suite + function checks exactly as in
   `ROUTER_NEXT_STEPS_V2.md` Step 6.
5. 24 h observation → enforce phase per that document.
6. Then (optionally) migrate the other TV, then other devices, one at a time.

## 5. Decommission the TVGuard box's PoC role (only after 6)

```bash
ssh <user>@<tvguard-box> 'cd <repo-root> && sudo scripts/tvguard-disable.sh'
```
- Samsung/Google TV gateway back to the new box (not to the old router IP).
- The TVGuard box reverts to a plain LAN host: Plex, backups, Samba, invoice
  stack untouched throughout — TVGuard's disable is surgical by design.
- Keep the TVGuard box's Pi-hole stopped (`docker compose stop pihole`) or remove
  per ROLLBACK.md; keep the repo (read-only history + future reference).

## 6. Post-migration verification (same gates as here)

- `sudo scripts/tvguard-selftest.sh` → all pass on the new box
- `sudo scripts/tvguard-status.sh` → table + counters + mode correct
- Samsung: YouTube / Plex / cast / voice all work; TVGUARD-NEW logs appear
- `scripts/health-check.sh` on the TVGuard box → Plex/Samba/SSH all still active
- 24 h of clean monitor logs before any enforce step
