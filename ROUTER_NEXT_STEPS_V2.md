# ROUTER NEXT STEPS V2 — Samsung one-arm PoC (your manual steps only)

**Everything else is done and tested on kiaserver.** This file lists ONLY the
actions you must perform, in order. TVGuard is in **MONITOR mode** (logging
only — nothing is blocked). Pi-hole is up. The firewall rules are already
loaded and **dormant** until a device actually uses this box as gateway.

Exact values (from the LAN inventory — not invented):

| Device | IP | MAC |
|---|---|---|
| kiaserver (gateway/DNS/Pi-hole) | 192.168.0.128 | 68:1D:EF:32:4F:56 |
| Samsung QE65Q75CATXXU | 192.168.0.197 | 1C:86:9A:AA:8E:96 |
| Google TV Streamer ("Living Room TV") | 192.168.0.90 | 14:C1:4E:1C:2F:4B |
| Virgin Hub 3 | 192.168.0.1 | D8:33:B7:C5:4D:4B |

---

## STEP 1 — Reserve kiaserver's IP on the Hub

**Why**: the PoC gateway IP must never move or be handed to another device.

- Virgin Hub 3 admin (`http://192.168.0.1` → log in) → *LAN / Network → DHCP →
  IP reservation* (wording varies by firmware).
- Add: MAC `68:1D:EF:32:4F:56` → `192.168.0.128`.

## STEP 2 — Reserve the Samsung's IP on the Hub

**Why**: the Samsung will be on a **static** IP; reserving it stops DHCP from
re-using it for something else.

- Same place. Add: MAC `1C:86:9A:AA:8E:96` → `192.168.0.197`.

## STEP 3 — Leave everything else on the Hub exactly as it is

- Hub stays in **router mode** (NOT modem mode — this PoC does not need it).
- DHCP stays on the Hub. Global DNS stays on the Hub. Hub firewall stays on.
- No other changes.

## STEP 4 — Wait for `READY FOR SAMSUNG TEST: YES`

- The agent's final report ends with that line. Until it says YES, do nothing
  else. If it says NO, it also says exactly what is broken.

## STEP 5 — Configure the Samsung (the only device change in this PoC)

On the Samsung: **Settings → General → Network → Network Status** (or
*Settings → Network and Internet* on newer Tizen builds) → set **static IP**:

```
IP address:      192.168.0.197
Netmask:         255.255.255.0
Gateway:         192.168.0.128     ← this box (was 192.168.0.1)
DNS:             192.168.0.128     ← this box (was automatic)
```

The moment you save this, the following happen automatically on kiaserver
(no further action needed):

- its Internet traffic is routed through kiaserver (masquerade → Hub → Internet)
- its DNS is served by Pi-hole (logged, per-group policy)
- any attempt to use an external resolver (8.8.8.8, 1.1.1.1, …) is
  transparently redirected to Pi-hole and logged
- every new outbound connection is logged (`TVGUARD-NEW`) and counted

## STEP 6 — Run the function + evidence tests on the Samsung

Do each, and run the matching session recorder on kiaserver during it:

```bash
# from /home/kia/dns  (TV action in the brackets is YOUR part)
sudo scripts/tv-session.sh samsung idle 10m      # home screen, touch nothing
sudo scripts/tv-session.sh samsung youtube 10m   # open YouTube, watch briefly
sudo scripts/tv-session.sh samsung plex 10m      # open Plex, play something
sudo scripts/tv-session.sh samsung cast 10m      # cast from your phone
sudo scripts/tv-session.sh samsung voice 5m      # voice remote / voice search
sudo scripts/tv-session.sh samsung standby 5m    # power off, leave standby
```

Function checks while you do this (must all keep working):

- [ ] Home screen loads, apps open
- [ ] YouTube streams (this is the QUIC/443 canary — if it breaks, stop and
      revert, then report the failure)
- [ ] Plex streams
- [ ] Casting from the phone
- [ ] Samsung app store reachable
- [ ] Firmware-check / settings screens open

Verify the server is actually seeing it:

```bash
sudo scripts/tvguard-status.sh          # counters should move, TVGUARD-NEW logs
python3 scripts/show-dns-activity.py 192.168.0.197
sudo journalctl -S -5 --grep TVGUARD-NEW --no-pager | tail
```

**Success = all functions work AND you see the TV's connections in
tvguard-status / Pi-hole.**

## STEP 7 — Observe for 24 h before any blocking

- Leave the Samsung as configured; normal family use is fine.
- Review: Pi-hole UI → Queries/Top Domains for client 192.168.0.197;
  `sudo scripts/tvguard-status.sh` for counter totals.
- **Block nothing yet.** The first block candidates come from comparing the
  session recordings (idle vs voice vs youtube), not from lists.

## STEP 8 (later, optional) — Test ONE telemetry candidate

Only after 24 h of clean monitoring, pick ONE destination that the comparison
reports show is background-only, mark it in `config/destinations.yaml`
(`class: blocked` with evidence), then:

```bash
sudo scripts/tvguard-enable-enforce.sh   # drops: DoT + class:blocked destinations
# watch the TV for a while; if anything breaks:
sudo scripts/tvguard-enable-monitor.sh   # back to logging-only
```

## STEP 9 (later) — Dedicated box

When you buy the dedicated machine, the Hub goes to modem mode and the box
replaces kiaserver for this role. This repo supports that natively
(`MIGRATION_TO_DEDICATED_BOX.md`). Until then the Samsung may stay on this
configuration — but remember kiaserver is also the Plex/backup box.

---

## EMERGENCY REVERT (at any point, in this order)

1. On the Samsung: gateway back to `192.168.0.1`, DNS back to **automatic**.
   (Its traffic immediately returns to the normal path — nothing on the
   server is required for this.)
2. If you also want the server footprint gone:

   ```bash
   cd /home/kia/dns && sudo scripts/tvguard-disable.sh
   ```

   This removes ONLY `table ip tvguard`, the two per-TV `ufw-user-forward`
   rules, the two sysctls we set, our sysctl file, and disables the unit.
   UFW, Docker, Plex, Samba, Transmission, SSH, the invoice stack, and the
   Hub are untouched. Pi-hole is left running (stop it separately via
   `docker compose stop pihole` if you want it off too — see ROLLBACK.md).

3. Confirm: `sudo scripts/tvguard-status.sh` (should show "not loaded"),
   `sudo scripts/health-check.sh` (all pre-existing services OK).
