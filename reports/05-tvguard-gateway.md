# 05 — TVGuard one-arm gateway PoC (nftables egress control on the deployment box)

Date: 2026-09-20 (UTC)
Scope: everything the repo ships for the one-arm gateway role, proven on this
machine **without** changing any TV, the upstream router, or any pre-existing service.

The intended architecture is NOT "Pi-hole now, firewall later on another box".
This is the **complete** privacy/monitoring/firewall PoC: Pi-hole + per-device
DNS policy + one-arm IPv4 gateway + nftables egress control (monitor/enforce)
+ DNS-bypass control + session recording/analysis. The future dedicated box
merely inherits this repository.

---

## 1. Design: one-arm gateway (same-interface routing + masquerade)

```
Samsung <SAMSUNG_TV_IP> / Google TV <GOOGLE_TV_IP>           (TV gateway = DNS = <TVGUARD_IP>)
        |
        |  default route via <TVGUARD_IP>, DNS <TVGUARD_IP>
        v
this box (<LAN_INTERFACE>, <TVGUARD_IP>)     one NIC, one arm
  * ip_forward=1
  * prerouting:  TV -> :53 (except our IP)  DNAT -> 172.18.0.2:53 (Pi-hole)
  * forward:     TV -> non-LAN  accept (+ log NEW)     [tvguard, prio -150]
                 UFW ufw-user-forward: -s <tv> -j ACCEPT   (the real accept)
  * postrouting: TV -> non-LAN  MASQUERADE (out via <LAN_INTERFACE>)
        |
        v   source = <TVGUARD_IP>
the upstream router .1  ->  Internet
        |
        v   reply dst=<TVGUARD_IP> -> conntrack reverse-NATs -> TV
```

Why this is a correct one-arm design (verified, not assumed):

* **Forwarding on the same interface**: Linux routes by FIB, not by "interface
  pairs". A packet from `<SAMSUNG_TV_IP>` to a non-LAN destination is looked up
  in the routing table (`default via <UPSTREAM_ROUTER_IP>`), accepted for forwarding
  because `ip_forward=1`, and goes out the same NIC. Two NICs are NOT required
  for a same-segment gateway.
* **Return path**: MASQUERADE rewrites the source to `<TVGUARD_IP>`, so
  Internet replies come back to THIS host; conntrack performs the reverse NAT
  and the reply is delivered to the TV. Proven in the selftest (conntrack shows
  `dst=<TVGUARD_IP>` mappings for the mock TV's traffic).
* **ICMP redirects**: a host that forwards a packet "out the same interface it
  came in, toward a destination on a different network" must NOT send ICMP
  redirects, or the TV would be told ".1 is closer" and abandon our gateway.
  `net.ipv4.conf.<LAN_INTERFACE>.send_redirects=0` is therefore set and persisted
  (`/etc/sysctl.d/99-tvguard.conf`). This is a hard requirement, not hygiene.
* **rp_filter**: strict mode would be satisfied here (route back to the TV is
  via the same interface the packet arrived on); no change was required.
* **UFW/Docker coexistence**: our rules live ONLY in `table ip tvguard` plus
  exactly two `ufw route allow from <tv> to any` rules in `ufw-user-forward`.
  No other table, chain, UFW rule or Docker rule is touched (see §3, §5).
* **Dormant until a TV points at us**: the TV source set contains only the two
  TV IPs. No other LAN device matches, so enabling TVGuard changes nothing for
  the rest of the network. If neither TV uses `.128` as gateway, the rules are
  completely inert.

## 2. Netfilter baseline (captured before any change — read-only)

Raw capture: `reports/raw/05-baseline-netfilter.txt` (895 lines, pre-TVGuard).

| Table | Owner | Key facts |
|---|---|---|
| `ip filter` | UFW + Docker | INPUT policy drop; FORWARD policy drop; ufw-user-input opens 13567 (SSH), 445/139/137/138 (Samba), 9091/32400 (Plex), 5050 (Transmission), 53/3001 LAN; `ufw-user-forward` was EMPTY |
| `ip nat` | Docker | DOCKER DNAT for pihole bridge (172.18.0.2:80/53) and invoice bridge (172.19.0.2:80) |
| `ip6 filter` / `ip6 nat` | UFW + Docker | mirror of the v4 rules |
| `ip raw` | pre-existing | drops direct external access to the Docker bridge IPs (do not touch) |

The UFW FORWARD chain is `priority filter (0), policy drop` and jumps
DOCKER-USER → DOCKER-FORWARD → ufw chains (ufw-user-forward included).

## 3. The critical coexistence finding (base-chain ordering)

**An ACCEPT in our forward chain does NOT stop later same-hook chains on this
kernel** — proven with `nft monitor trace`. The UFW `filter FORWARD` base chain
(priority 0, policy DROP) still evaluates the packet after our accept and kills
it. **DROPS are terminal, accepts are not.**

Consequence (implemented):

* our `tvguard forward` chain (priority -150, runs first) is used for
  **logging, counters, and ENFORCE-mode drops** (drops are final, so they work
  from -150);
* the actual **ACCEPT** that lets TV traffic pass UFW's deny-by-default policy
  is placed inside UFW's own `ufw-user-forward` chain via the ufw API
  (`ufw route allow from <tv> to any`), one rule per TV. Rollback removes
  exactly those rules and nothing else.

The rendered ruleset lives in `/var/lib/tvguard/tvguard.nft` (regenerated,
`nft -c` checked, and atomically replaced — only `table ip tvguard` is ever
deleted/reloaded; the apply script never flushes anything else).

## 4. DNS bypass control

For a TV whose gateway is `.128`, plain DNS to `.128:53` works normally.
Attempts to bypass (TV → 8.8.8.8:53, 1.1.1.1:53, vendor resolvers, any
UDP/TCP 53 to a non-local IP) are **transparently redirected** by
`prerouting: ip saddr @tvs ip daddr != <TVGUARD_IP> {udp|tcp} dport 53
dnat to 172.18.0.2:53`.

* **DNAT, not `redirect`**: an explicit DNAT to the Pi-hole container IP is
  the only NAT on the connection, the packet crosses the bridge with the TV's
  real source IP, and Pi-hole logs the true client. With `redirect`, Docker's
  userland docker-proxy relays the packet and Pi-hole sees `172.18.0.1` —
  per-TV attribution of bypass attempts is lost (verified empirically).
* **Monitor mode behaviour**: redirect is active in BOTH modes so we can see
  and control all TV DNS; blocking other :53 egress outright would be equally
  effective but loses the telemetry. The TV keeps working either way.
* **DoT (tcp/853)**: logged/counted in monitor; dropped in enforce (a TV has
  no legitimate reason to open direct DoT when we serve it DNS).
* **DoH (tcp/443)**: **not blanket-blocked.** DoH rides ordinary HTTPS/443 and
  is indistinguishable from legitimate streaming/API HTTPS using destination
  metadata alone. YouTube/Plex/streaming also use 443 (and QUIC). We record
  443 destinations per session and classify from evidence; known DoH endpoint
  lists can be added to `config/destinations.yaml` per-destination only.
* **QUIC (udp/443)**: never globally blocked — YouTube and most modern
  streaming depend on it.

## 5. What the rules touch (and what they cannot)

| Change | Mechanism | Reversible |
|---|---|---|
| `table ip tvguard` (sets + 3 chains) | `tvguard-apply.sh` renders, `nft -c` validates, deletes+loads ONLY this table | `tvguard-disable.sh` |
| 2× `ufw-user-forward` ACCEPT rules | `ufw route allow from <tv> to any` (ufw API, not hand-edited iptables) | `ufw route delete ...` per TV in `tvguard-disable.sh` |
| `net.ipv4.ip_forward=1` | sysctl + `/etc/sysctl.d/99-tvguard.conf` | baseline-captured, restored on disable |
| `net.ipv4.conf.<LAN_INTERFACE>.send_redirects=0` | same | same |
| `tvguard.service` (oneshot, after network+docker, gated by `active` marker) | installed via `deploy/tvguard.service.in` | `tvguard-disable.sh` stops+disables |

Untouched (verified by diff against `05-baseline-netfilter.txt`): all UFW
chains/rules except the two user-forward adds, all Docker chains/nat, the raw
table, `ip6` tables, Plex/Samba/Transmission/SSH/invoice containers, Hub.

## 6. IPv6 assessment (what the TVs could use to bypass)

Facts established by direct measurement (not assumption):

* this box `<LAN_INTERFACE>`: **link-local only** (`fe80::c23c:1804:6d08:d906`), no
  global unicast address, no IPv6 default route, `net.ipv6.conf.<LAN_INTERFACE>.forwarding=0`.
* Passive capture of **all Router Advertisements on the segment: 60 s and then
  4 continuous minutes — zero RAs observed** (`reports/raw/ra-capture-4min.txt`).
  A 4-minute window is ~12× the typical 200 s RA interval, so the conclusion
  is: **the Hub is not advertising any global IPv6 prefix** (IPv6 effectively
  disabled on this connection).
* `ip -6 neigh`: no neighbour on the segment holds a global address while
  captured; only link-local scope exists.

Conclusion: **the TVs have no IPv6 path to the Internet today** — a TV can at
most talk link-local to other LAN neighbours, which is not exfiltration.
No IPv6 disruption was applied (nothing to disrupt). If the ISP ever enables
IPv6 (RAs with a global prefix), the same TVGuard pattern must be mirrored in
the `ip6` table for the two TV MACs/addresses before that becomes a bypass —
documented, not implemented, because there is currently nothing to block.

## 7. Observability stack (deliberately minimal)

Once a TV is routed through us, the stack is:

| Layer | Tool | Gives |
|---|---|---|
| new-connection log + per-rule counters | nftables `tvguard` table (`log prefix "TVGUARD-NEW "` on NEW only; counters on all TV rules) | who/where/when, rate-limited, no packet spam |
| per-flow bytes + DNS-bypass tuples | `conntrack -E` (session window) + `conntrack -L` | src, dst, port, proto, timing, bytes of closed flows |
| DNS domain correlation | Pi-hole v6 API (`/api/queries` by client+window) | domain, status, reply, upstream |
| deep dive on demand | `tshark` / `tcpdump` (scripts/capture-device.sh) | TLS SNI, QUIC dest, header-level detail |
| per-session artefacts | `scripts/tv-session.sh` → connections.csv, dns.csv, summary.md, metadata.json | reproducible, comparable evidence |
| session comparison | `scripts/compare-tv-sessions.py` | only-in-X / common destinations + ledger classification |

**Decision on Zeek / ntopng: not installed.** With one TV (then two) on a
one-arm PoC, conntrack + nft counters + the Pi-hole API + tshark cover every
question we have (who, where, how much, which DNS name). Zeek/ntopng become
worthwhile when (a) many devices traverse the box, (b) long-term storage
correlation is needed, (c) the dedicated box takes the role. Revisit at
migration; see `docs/MIGRATION_TO_DEDICATED_BOX.md`.

Caveat recorded in every session summary: conntrack reports cumulative bytes
only at flow DESTROY, so flows still open at the end of a short window show
0 bytes; the nft counter deltas in each session are the reliable aggregate.

## 8. Monitor vs enforce (both implemented, monitor is the live default)

* **monitor** (current live state): TV traffic routed through us is logged and
  counted; DNS bypass is redirected (visibility + control); nothing is
  deliberately blocked beyond the existing Pi-hole gravity baseline.
* **enforce**: monitor + `drop` on TV→tcp/853 and on any destination in
  `config/destinations.yaml` with `class: blocked`. Nothing is in that list
  yet — the list is generated from evidence, not from a giant internet
  blocklist. Transition: `scripts/tvguard-enable-enforce.sh` (explicit,
  reversible via `tvguard-enable-monitor.sh` / `tvguard-disable.sh`).

## 9. Proof (selftest, no real TV involved)

`sudo scripts/tvguard-selftest.sh` builds a throwaway network-namespace "TV"
(10.99.99.2), a veth pair, and a throwaway `ip tvguard-test` table mirroring
production logic. Result: **7/7 PASS** —

1. table loads (after `nft -c` validation)
2. `ufw route` rule added for the mock IP (and removed at teardown)
3. `dig @8.8.8.8` from the mock TV resolves **through our Pi-hole**
4. Pi-hole logged the query with client = the mock TV IP (attribution works)
5. plain HTTP egress 200 via masquerade
6. HTTPS egress 301 via masquerade
7. conntrack shows the NATed return path through <TVGUARD_IP>

Teardown removed the mock table, mock ufw rule and netns; production state
verified unchanged afterwards. The two selftest session recordings
(`captures/*-selftest/`) exercised `tv-session.sh` + `session_analyze.py` +
`compare-tv-sessions.py` end-to-end.

## 10. Session workflow (what you will actually run once the Samsung is pointed at us)

```bash
sudo scripts/tv-session.sh samsung idle 10m       # TV idle on home screen
sudo scripts/tv-session.sh samsung youtube 10m    # launch YouTube, leave it
sudo scripts/tv-session.sh samsung plex 10m
sudo scripts/tv-session.sh samsung cast 10m       # cast from your phone
sudo scripts/tv-session.sh samsung voice 5m       # voice assistant / search
sudo scripts/tv-session.sh samsung standby 5m     # power off / standby

python3 scripts/compare-tv-sessions.py \
  captures/<dir>-idle captures/<dir>-voice \
  [--out comparison.md]
```

Each session dir: `metadata.json`, `events.log`, `nft-counters-{start,end}.txt`,
`pihole-queries.json`, `connections.csv`, `dns.csv`, `summary.md`.
Classifications only from `config/destinations.yaml` (evidence ledger); the
comparator separates observed / inference / classification explicitly.

## 11. PoC limitations (stated honestly)

* **No LAN isolation**: all devices stay in <LAN_SUBNET>. `TV → another
  <LAN_PREFIX>.x` traffic stays layer-2 direct and does NOT traverse us (and
  cannot be seen by us). This PoC controls TV→Internet egress only.
* **No TLS inspection**: we see destination IPs, ports, bytes, timing and DNS
  names — never the encrypted payload. "What did the TV say to its voice
  service" is not knowable without MITM, which is explicitly out of scope.
* **DoH vs HTTPS**: indistinguishable from metadata alone (see §4).
* **Bytes of long-lived flows**: see §7 caveat.
* **One arm on a production server**: fine as a PoC; the box is also running
  Plex/backups, so if it dies those and the TV egress control die together.
  That is exactly why the repo is migration-ready for a dedicated box.
