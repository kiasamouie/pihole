# ROLLBACK — TVGuard + Pi-hole PoC (v2)

Everything here affects **only** this project's footprint: the `tvguard`
nftables table, the two per-TV `ufw-user-forward` rules, two sysctls, the
`tvguard` systemd unit, and the Pi-hole compose stack. It never touches
Plex, Samba, Transmission, SSH, the invoice containers, the Hub, or any
pre-existing firewall rule. No command below flushes a firewall or resets UFW.

---

## R0 — TVGuard firewall/gateway: ONE-COMMAND emergency rollback

```bash
cd /home/kia/dns && sudo scripts/tvguard-disable.sh
```

This removes **only** the TVGuard footprint:

| Removed | Mechanism |
|---|---|
| nftables table `ip tvguard` (the whole PoC ruleset) | `nft delete table ip tvguard` — never any other table |
| the two `ufw-user-forward` ACCEPT rules (`-s 192.168.0.197`, `-s 192.168.0.90`) | `ufw route delete allow from <tv> to any`, only if the source is one of our TV IPs |
| `net.ipv4.ip_forward` + `net.ipv4.conf.enp2s0.send_redirects` values | restored from the baseline captured at first apply |
| `/etc/sysctl.d/99-tvguard.conf` + `/var/lib/tvguard/sysctl.conf` | deleted |
| `tvguard.service` (stopped + disabled) | our own unit only |
| state markers (`/var/lib/tvguard/{active,state}`) | deleted, so boot will not re-apply |

Explicitly **NOT** touched: any other UFW rule/chain, Docker's chains/NAT,
the raw table, `ip6` tables, Pi-hole, Plex, Samba, or anything else.

**After** the one-command rollback, revert the TV(s):

```
Samsung:  gateway = 192.168.0.1, DNS = automatic
```

That alone restores the original network path for that TV even *before* you
run the rollback (the TV simply stops using us).

Verify clean:

```bash
sudo scripts/tvguard-status.sh     # "not loaded", no ufw route rules
sudo scripts/health-check.sh       # pre-existing services all active
```

Re-enable later (idempotent): `sudo scripts/tvguard-enable-monitor.sh`.

## R1 — Check state (no changes)

```bash
scripts/health-check.sh            # pre-existing services + Pi-hole + TVGuard
sudo scripts/tvguard-status.sh      # TVGuard mode/table/counters (read-only)
docker ps                          # pihole + invoice stack
ss -lntup | grep -E ':53|:3001|:3443'
```

## R2 — Stop the Pi-hole stack (keeps config/state on disk)

```bash
cd /home/kia/dns && docker compose stop pihole
```
- DNS `:53`, UI `:3001`/`:3443` stop answering. All groups/lists remain in
  `etc-pihole/` (no data loss).
- **Resume**: `docker compose start pihole`.
- Note: while stopped, TVGuard's DNS-bypass DNAT falls back to `redirect` on
  next apply (the apply script re-resolves the container IP).

## R3 — Inspect logs

```bash
docker logs --tail 200 pihole
tail -n 50 etc-pihole/pihole-FTL.log
ls etc-pihole/
sudo journalctl -S -30 --grep 'TVGUARD\|tvguard' --no-pager | tail -40
```

## R4 — Remove the Pi-hole container (keeps `etc-pihole/` for restore)

```bash
cd /home/kia/dns && docker compose down        # container + its bridge
docker rmi pihole/pihole:2026.09.0 2>/dev/null # optional image removal
```
`docker compose up -d` brings everything back with all settings intact.

## R5 — Full removal (Pi-hole + TVGuard footprint)

```bash
sudo scripts/tvguard-disable.sh               # R0 first
cd /home/kia/dns && docker compose down
rm -rf etc-pihole                             # Pi-hole state (config, DB, logs)
rm -f    .env                                 # credentials (keep records elsewhere)
docker rmi pihole/pihole:2026.09.0 2>/dev/null
# optional: remove the diagnostic packages this project added
sudo apt-get remove -y arp-scan nmap avahi-utils conntrack tcpdump
```
Optionally remove `captures/` (session recordings, git-ignored) and
`reports/raw/` artefacts you no longer want. The repo itself can then be
deleted; nothing on the live network depends on it anymore.

## L5 — Revert anything the staged rollout changed on the Hub

(Only relevant **after** you've followed `ROUTER_NEXT_STEPS_V2.md`.)
- Remove the two IP reservations (Steps 1–2) if you want.
- Reset the Samsung to gateway `192.168.0.1` / DNS automatic (Step 6).
- Remove any group-scoped denylist entries you added in Pi-hole.

---

## Confirming a clean full rollback

```bash
sudo scripts/tvguard-status.sh                 # not loaded, no ufw route rules
ss -lntup | grep -E ':53|:3001|:3443'          # should print nothing
docker ps                                      # invoice stack intact, no pihole
scripts/health-check.sh                        # pre-existing service lines all active
```
