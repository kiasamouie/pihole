# ROLLBACK — TVGuard + Privacy Policy + Pi-hole PoC (v3)

Everything here affects **only** this project's footprint: the `tvguard`
nftables table (including the optional privacy sets it renders), the two
per-TV `ufw-user-forward` rules, two sysctls, the `tvguard` systemd unit, the
Pi-hole compose stack, and the `TVGuard-Privacy` Pi-hole group. It never
touches Plex, Samba, Transmission, SSH, the invoice containers, the upstream router, or
any pre-existing firewall rule. No command below flushes a firewall or resets
UFW.

Rollback ladder (use the narrowest that fits):

| Level | Command | Removes |
|-------|---------|---------|
| Privacy only | `sudo scripts/privacy-policy-disable.sh` | deny sets + DoT rules + Pi-hole group; keeps NAT/gateway/DNS/monitor mode |
| TVGuard only | `sudo scripts/tvguard-disable.sh` | whole one-arm gateway (NAT, DNS DNAT, monitor) incl. privacy layer |
| Pi-hole only | `docker compose stop pihole` | DNS service; keeps TVGuard (falls back to redirect on next apply) |
| Everything | R0 + R4/R5 below | full project footprint |

---

## R0a — Privacy policy: ONE-COMMAND rollback (keep the gateway)

Use this when privacy blocking is ON and you want the TV's Internet path
totally normal again **without** tearing down the gateway:

```bash
cd <repo-root> && sudo scripts/privacy-policy-disable.sh
```

It removes **only**:

| Removed | Mechanism |
|---|---|
| `tv_privacy_blocked` / `tv_doh_blocked` sets + privacy/DoT drop rules | re-render of `table ip tvguard` with privacy state `off` — NAT, masquerade, DNS-bypass DNAT, monitor mode, UFW route rules all verified still present afterwards |
| Pi-hole group `TVGuard-Privacy` + all 70 rows (37 exact denies, 14 regex/zone denies — aibixby + the 13 mlock Samsung zones — and the **19 mlock keep/allow rows**, which are removed too so no manufacturer allow rows survive) + client attachments | `POST /api/groups:batchDelete` + `POST /api/domains:batchDelete` (v6 API; each row is deleted with its own kind, so the suffix/zone regexes are removed too); other groups untouched |
| state file `/var/lib/tvguard/privacy-state` | rewritten to `PRIVACY=off` |

Note: disabling the policy does not by itself kill already-open TV connections
to blocked IPs (the deny rule matches new connections only). If you disabled
mid-session and want the TV's state fully clean, additionally run
`sudo scripts/privacy-reset-tv-voice-state.sh` (voice IPs) or
`sudo scripts/privacy-reset-tv-manufacturer-state.sh` (all denied
manufacturer-lockdown IPs) — both only touch the target TV's conntrack
entries (never the global table, never other clients).

The TV keeps its full Internet path (it never lost it — disabling only
removes the deny rules). No TV-side change needed. The disable script is
idempotent: running it while already off is a no-op that re-verifies state.

Explicitly NOT touched: UFW, Docker, iptables/nftables outside `ip tvguard`,
the Pi-hole stack itself, gravity baseline, other Pi-hole groups, Plex, Samba.

Verify:

```bash
sudo scripts/privacy-policy-status.sh
# expect: PRIVACY=off, "(no privacy sets present)", "(group absent ...)"
```

## R0 — TVGuard firewall/gateway: ONE-COMMAND emergency rollback

```bash
cd <repo-root> && sudo scripts/tvguard-disable.sh
```

This removes **only** the TVGuard footprint:

| Removed | Mechanism |
|---|---|
| nftables table `ip tvguard` (the whole PoC ruleset) | `nft delete table ip tvguard` — never any other table |
| the two `ufw-user-forward` ACCEPT rules (`-s <SAMSUNG_TV_IP>`, `-s <GOOGLE_TV_IP>`) | `ufw route delete allow from <tv> to any`, only if the source is one of our TV IPs |
| `net.ipv4.ip_forward` + `net.ipv4.conf.<LAN_INTERFACE>.send_redirects` values | restored from the baseline captured at first apply |
| `/etc/sysctl.d/99-tvguard.conf` + `/var/lib/tvguard/sysctl.conf` | deleted |
| `tvguard.service` (stopped + disabled) | our own unit only |
| state markers (`/var/lib/tvguard/{active,state}`) | deleted, so boot will not re-apply |

Explicitly **NOT** touched: any other UFW rule/chain, Docker's chains/NAT,
the raw table, `ip6` tables, Pi-hole, Plex, Samba, or anything else.

**After** the one-command rollback, revert the TV(s):

```
Samsung:  gateway = <UPSTREAM_ROUTER_IP>, DNS = automatic
```

That alone restores the normal network path for that TV even *before* you
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
cd <repo-root> && docker compose stop pihole
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
cd <repo-root> && docker compose down        # container + its bridge
docker rmi pihole/pihole:2026.09.0 2>/dev/null # optional image removal
```
`docker compose up -d` brings everything back with all settings intact.

## R5 — Full removal (Pi-hole + TVGuard footprint)

```bash
sudo scripts/tvguard-disable.sh               # R0 first
cd <repo-root> && docker compose down
rm -rf etc-pihole                             # Pi-hole state (config, DB, logs)
rm -f    .env                                 # credentials (keep records elsewhere)
docker rmi pihole/pihole:2026.09.0 2>/dev/null
# optional: remove the diagnostic packages this project added
sudo apt-get remove -y arp-scan nmap avahi-utils conntrack tcpdump
```
Optionally remove `captures/` (session recordings, git-ignored),
`data/privacy-policy/` and `data/offline-reconnect/` (generated runtime data,
git-ignored), and `reports/raw/` artefacts you no longer want. The repo
itself can then be deleted; nothing on the live network depends on it anymore.

## L5 — Revert anything the staged rollout changed on the upstream router

(Only relevant **after** you've followed `ROUTER_NEXT_STEPS_V2.md`.)
- Remove the two IP reservations (Steps 1–2) if you want.
- Reset the Samsung to gateway `<UPSTREAM_ROUTER_IP>` / DNS automatic (Step 6).
- Remove any group-scoped denylist entries you added in Pi-hole.

---

## Confirming a clean full rollback

```bash
sudo scripts/tvguard-status.sh                 # not loaded, no ufw route rules
ss -lntup | grep -E ':53|:3001|:3443'          # should print nothing
docker ps                                      # invoice stack intact, no pihole
scripts/health-check.sh                        # pre-existing service lines all active
```
