# ROLLBACK — stop / disable / remove the Pi-hole PoC

Everything here affects **only** the new Pi-hole stack and the packages this
session installed. It does **not** touch Plex, Samba, backups, the invoice
Docker containers, the Hub, or any pre-existing firewall rules.

**Order of safety**: do the least-destructive thing first. Each level is
reversible up to "remove".

---

## L0 — Check state (no changes)
```bash
scripts/health-check.sh                 # pre-existing services + Pi-hole
docker ps                                # pihole should be the only "new" container
ss -lntup | grep -E ':53|:3001'          # Pi-hole's listeners
```

## L1 — Stop the Pi-hole stack (keeps config/state on disk)
```bash
cd /home/kia/dns
docker compose stop pihole
```
- DNS on `:53` and the UI on `:3001` stop answering. Groups/lists remain in
  `etc-pihole/` (no data loss).
- **Resume**: `docker compose start pihole` (or `docker start pihole`).

## L2 — Inspect logs (while stopped or running)
```bash
docker logs --tail 200 pihole           # container log (FTL + web)
ls etc-pihole/                          # pihole-FTL.log, dnsmasq log, gravity.db, query DB
tail -n 50 etc-pihole/pihole-FTL.log    # FTL engine log
```

## L3 — Remove the container (keeps `etc-pihole/` data for later restore)
```bash
cd /home/kia/dns
docker compose down                      # removes container + its docker network
# (optionally) docker rmi pihole/pihole:2026.09.0   # remove the image
```
- `etc-pihole/` (config, gravity DB, groups/clients, query log) is **kept** —
  `docker compose up -d` will come right back with all settings.

## L4 — Full removal (config + data + packages)
```bash
cd /home/kia/dns
docker compose down
rm -rf etc-pihole                        # Pi-hole state (config, DB, logs)
rm -f    .env                            # credentials (or keep your records separately)
docker rmi pihole/pihole:2026.09.0 2>/dev/null
```
Then, if you also want the diagnostic packages gone:
```bash
sudo apt-get remove -y arp-scan nmap avahi-utils conntrack
sudo apt-get autoremove -y
```
> Note: `tcpdump`, `ethtool`, `procps`, `dnsutils` (dig) were installed/confirmed
> this session but are general-purpose tools you may want to keep — removing them
> is optional. `shellcheck` (if present) predates this work — leave it.

**What is NOT part of rollback** (was pre-existing, do not touch):
- The UFW rules (incl. the `53`/`3001` LAN allowances) — pre-existing from an old
  AdGuard plan.
- The invoice Docker containers and the raw iptables DROP rules shielding them.
- `net.ipv4.ip_forward = 1` (Docker, pre-existing).
- Plex, Samba/Winbind, no-ip, Transmission, SSH (port 13567), translator-docs.

## L5 — Revert anything the staged rollout changed on the Hub
(Only relevant **after** you've followed `ROUTER_NEXT_STEPS.md`.)
- Remove the IP reservation (Step 1).
- Reset per-device DNS back to automatic (Steps 2–4).
- If global DNS was set (Step 8 Option B), reset it to the Hub default.
- Remove any group-scoped denylist entries you added in Pi-hole (UI or API).

---

## Confirming a clean rollback
```bash
ss -lntup | grep -E ':53|:3001'          # should print nothing (no listeners)
docker ps                                # pihole should be gone; invoice stack intact
scripts/health-check.sh                  # note: its Pi-hole checks will now FAIL by
                                          # design (Pi-hole absent) — the pre-existing
                                          # service lines must still be OK
```
If the pre-existing service lines in `health-check.sh` are all `active`, the
rollback is complete and safe.
