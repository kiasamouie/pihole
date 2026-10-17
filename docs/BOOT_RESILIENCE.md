# Boot resilience — 2026-10-17 incident, root cause, and permanent fix

## Architecture (as actually deployed on kiaserver)

```
Samsung TV 192.168.0.197 (static: gateway + DNS = 192.168.0.128)
   -> kiaserver 192.168.0.128 (enp2s0, DHCP from the router; reservation required)
        Pi-hole  (Docker, project "tvguard", network tvguard_default 172.21.0.0/16)
                 publishes 192.168.0.128:53 tcp+udp, :3001, :3443 ; 127.0.0.1:3001
        TVGuard  tvguard.service -> nft "table ip tvguard" (monitor mode,
                 masquerade for @tvs, Samsung privacy: DNS DNAT -> Pi-hole container IP)
   -> Virgin Hub 3 192.168.0.1 (router + only DHCP server; hands out 194.168.4.100/8.100)

Kia Platform: kiaplatform-platform-tls (nginx SNI edge) publishes 192.168.0.128:443
              -> kiaplatform-caddy (Let's Encrypt for kiaserver.ddns.net)
              /pihole/admin/* is proxied by Caddy to https://192.168.0.128:3443
```

DNS scope: **only the TVs** use Pi-hole (configured statically on the TV).
The router keeps handing out Virgin DNS to everyone else. KiaPC and every other
client must stay on router DHCP DNS. Otherwise any kiaserver reboot or Pi-hole
fault takes their DNS down too, which is what happened to KiaPC on 2026-10-17.

## What broke on 2026-10-17

After the 15:36 reboot:

* `pihole` was **running and "healthy"** but had `NetworkSettings.Networks = {}`
  and no published ports, so `192.168.0.128:53` refused connections. The
  Docker healthcheck runs *inside* the container, so it hid the fault.
* `kiaplatform-platform-tls` was `Exited (128)` with
  `failed to bind host port 192.168.0.128:443/tcp: cannot assign requested address`,
  so https://kiaserver.ddns.net/platform and /pihole/admin/ were unreachable.
  No-IP was fine; the DNS name pointed at the correct public IP.
* `tvguard.service` failed. Its boot gate correctly refused to load rules
  without a working Pi-hole, so the Samsung TV rules were not loaded.
* KiaPC lost DNS. It had been sending its DNS to Pi-hole since 2026-09-30 21:41
  (160,165 queries in the FTL database, the last one at 14:39 just before the
  shutdown).

## Root cause (evidence)

1. `/etc/network/interfaces` uses `allow-hotplug enp2s0`. ifupdown brings it up
   asynchronously via `ifup@enp2s0`, so `network-online.target` does **not** wait
   for the DHCP lease.

   | time (BST) | event | evidence |
   |---|---|---|
   | 15:36:10.20 | network-online.target reached | systemd monotonic timestamps |
   | 15:36:10.40 | dhcpcd launched | `/run/dhcpcd/enp2s0.pid` mtime |
   | 15:36:11.11 | dockerd starts, restores containers | `docker.service` ExecMainStart |
   | 15:36:21.17 | lease written, 192.168.0.128 assigned | `/var/lib/dhcpcd/enp2s0.lease` mtime |
   | 15:36:21.92 | pihole started by the TVGuard gate, comes up detached | container StartedAt, logs "Could not contact DNS servers" |
   | 15:38:19 | gate deadline, tvguard.service failed | systemctl status |

2. Docker restored containers that publish on `192.168.0.128` about 10 s before
   that address existed, and the binds failed (`cannot assign requested address`).
3. **Docker 29.4.1 behaviour (reproduced here with throwaway containers):**
   after a failed start at port binding, the container's network attachment is
   dropped. Every later `docker start`, `stop`/`start` or `restart` then gives a
   *running* container with no network and no ports. It never recovers by
   itself. Only `docker network connect` (or recreating the container) fixes it.

Why earlier reboots were fine: it is a race. On 2026-09-27 and 2026-09-30 the
DHCP lease happened to arrive before dockerd restored the containers.

## What the previous repair (2026-09-28, commit 7ec5753, plus uncommitted work) missed

* It added a boot gate that *validates* Pi-hole (fail-closed). That is correct,
  but it could not *repair* anything: `docker start` on the detached container
  is a no-op.
* The later "wait for the LAN address" improvement lived only in the gate, which
  runs *after* Docker has already lost the race. It was also never committed.
* Nothing ordered Docker itself after the DHCP address, and nothing covered
  other projects that bind to the LAN IP (the Kia Platform TLS edge).
* Nothing re-checked the system after boot, and Docker's healthy status hid
  the outage.

## Permanent fix (this change)

| layer | file (repo) | installed as | purpose |
|---|---|---|---|
| prevention | `scripts/wait-lan-address.sh`, `deploy/docker-lan-address.conf.in` | `/usr/local/libexec/tvguard/wait-lan-address` (copy), `/etc/systemd/system/docker.service.d/10-tvguard-lan-address.conf` | dockerd waits (max 90 s, never fatal) until 192.168.0.128 is on enp2s0 |
| self-heal | `scripts/docker-lan-heal.sh` | `/usr/local/libexec/tvguard/docker-lan-heal` (copy); docker `ExecStartPost`; called by the TVGuard gate | re-attaches any always/unless-stopped container left detached (keeps its Compose alias), then starts it; containers stopped on purpose are left alone |
| gate | `scripts/pihole-boot-ready.sh` | existing launcher | now heals before and during its wait instead of only failing |
| watchdog | `scripts/tvguard-watchdog.sh`, `deploy/tvguard-watchdog.{service.in,timer}` | `tvguard-watchdog.timer` (90 s after boot, then every 2 min) | heals detached containers; restarts Pi-hole if LAN DNS fails over UDP+TCP; re-applies tvguard.service if it has failed, its table is missing, or its DNS DNAT targets a stale Pi-hole IP |
| checks | `scripts/health-check.sh` | — | new "boot resilience" section |
| installer | `deploy/install-boot-hardening.sh` | — | idempotent install with backups to `/var/backups/tvguard/<ts>/`; `--uninstall` rolls back |

No firewall policy was changed. The watchdog only re-runs the existing,
idempotent `tvguard.service`, which replaces `table ip tvguard` alone.

Not changed on purpose: `/etc/network/interfaces` (changing `allow-hotplug` to
`auto` would also fix the ordering, but risks SSH on a headless box), router
DHCP, KiaPC, and the Kia Platform compose files.

## KiaPC DNS (192.168.0.128 / 192.168.0.214)

Verified:
* KiaPC queried this Pi-hole from 2026-09-30 21:41 until 2026-10-17 14:39.
* The Oct 1 baseline (`~/kiaplatform/spec/evidence/stabilization-20261001/01-baseline-kia-pc-20261001.md`)
  shows the Realtek adapter with DNS 192.168.0.128 while its IP came from DHCP.
* `config/lan-dns-records.txt` (commit 2c3da87, "primary Pi-hole") was written
  so Windows clients could resolve `kiaserver`/`kiarender` through Pi-hole. That
  shows Pi-hole was deliberately serving KiaPC at that time.
* Nothing on kiaserver serves DHCP: Pi-hole `dhcp.active = false`, no :67
  listener, no dhcpd/kea/dnsmasq. kiaserver cannot push DNS settings to clients.
* 192.168.0.214 was kiarender's old address (now .212). Neither .214 nor .212
  answers DNS, so .214 was a dead secondary DNS server.

Not provable from kiaserver: *how* .128/.214 got onto KiaPC. The Oct 1 note
says "router DHCP hands out 192.168.0.128", but `ipconfig /all` does not show
whether DNS came from DHCP or was set statically, and today the router verifiably
hands out 194.168.4.100/8.100. The most likely explanation is a static DNS
entry on the KiaPC adapter set around 2026-09-30 21:41. The Windows event log
(Microsoft-Windows-DNS-Client, NCSI) or the registry
(`HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\{guid}\NameServer`;
non-empty = static) on KiaPC would confirm it.

KiaPC now uses automatic DNS, which is correct. It maps shares by IP, so it
does not need Pi-hole for name resolution. Note:
`~/kiaplatform/scripts/windows/map-home-shares.ps1` still points kiarender at
the stale `192.168.0.214`.

## Rollback

```bash
sudo deploy/install-boot-hardening.sh --uninstall   # restores the latest backup set
sudo scripts/privacy-policy-disable.sh samsung      # privacy layer only
sudo scripts/tvguard-disable.sh                      # all TVGuard rules
```

## Recovery if it breaks again

```bash
scripts/health-check.sh                 # shows which layer failed
scripts/docker-lan-heal.sh              # re-attach detached containers (docker group is enough)
sudo systemctl restart tvguard.service  # re-apply TV rules
journalctl -u tvguard-watchdog -u tvguard -u docker -b
```

The DHCP reservation for kiaserver (192.168.0.128) on the router is required.
If kiaserver ever gets a different IP, the published ports, the TV gateway and
the router port-forwards all break.

## Test results

See the "Test log" section at the end of this file (filled in on 2026-10-17).
