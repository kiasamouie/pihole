# kiaserver TV-Telemetry PoC — Full Report

Date: 2026-09-20 · Host: `kiaserver` (Debian 13) · Workdir: `/home/kia/dns`

---

## 1. Executive Summary

- **Pi-hole v6 is installed, tested, and running in isolation** (Docker, image pinned
  to `pihole/pihole:2026.09.0`). It listens on this server's `53/tcp+udp` and
  `3001/tcp` (admin UI). **No LAN device uses it yet.** DHCP is off, no router
  changes were made, and no existing service was touched.
- **kiaserver is vastly powerful enough for Pi-hole and passive monitoring**, but is
  **not suitable as a permanent router/firewall**: it has a single production NIC
  (Realtek 1GbE), already runs Plex + Samba + backups, and would become a single
  point of failure for the whole LAN. It is acceptable as a *temporary* PoC gateway
  only if you accept that risk; a dedicated small x86 box is the right end state
  (Section 19).
- **Two TVs were identified**: a **Samsung 65" QLED QE65Q75A (Q75A, Tizen 2021)**
  at `192.168.0.197` and a **Google TV Streamer** ("Living Room TV", redsonic) at
  `192.168.0.90`. Both are registered in Pi-hole's `TV-Monitor` group.
- **Honest visibility limit (proven, not assumed)**: on the current switched LAN
  this server sees only broadcast/multicast/ARP + traffic addressed to it + its own
  egress. It sees **zero** TV→Internet unicast traffic. Pi-hole gives us visibility
  *only for DNS*, and only for devices we point at us. Everything else (forced DNS,
  per-device egress, telemetry correlation) requires the later gateway/mirror phase.
- **What Pi-hole can do**: log and block domains per device/group. **What it cannot**:
  see or stop traffic that never queries it (hard-coded IPs, DoH/DoT, direct
  connections), inspect encrypted payloads, or see voice transcripts.
- **Staged rollout is ready**: `ROUTER_NEXT_STEPS_V2.md` gives the exact, minimal
  manual sequence (reserve two IPs → Samsung gateway/DNS to `.128` → monitor tests).
  `ROLLBACK.md` covers the one-command TVGuard firewall rollback plus Pi-hole
  removal without touching Plex/backups.
- **The full gateway/firewall PoC now exists on this machine and is proven**
  (not deferred to the future box): one-arm IPv4 gateway (TV → this box → Hub),
  SNAT/masquerade with return path through the box, a dedicated removable
  `tvguard` nftables table in `monitor` mode, DNS-bypass transparent redirection
  to Pi-hole, conntrack-based session recording + comparison tooling, and a
  systemd-persisted, one-command-removable install. A mock-TV selftest passes
  7/7 (DNS redirect attribution, HTTP/HTTPS egress, NAT return path). See
  `reports/05-tvguard-gateway.md`. No real TV is pointed at it yet; the rules
  are dormant until the Samsung's gateway/DNS is changed.

---

## 2. Is kiaserver Suitable?

| Role | Verdict | Why |
|---|---|---|
| **A. Pi-hole** | ✅ **Yes** | 4 cores/8 threads, 15 GiB RAM (13 GiB available), 260 GB free NVMe. Measured footprint: **8 MiB RAM, ~0.3 % CPU** while idle. Overkill by ~100×. |
| **B. DNS logging** | ✅ **Yes** | Same as above. Query log is in `etc-pihole/` (git-ignored). Rotate/cap is trivial. |
| **C. LAN discovery** | ✅ **Yes** | arp-scan/nmap/avahi/tshark all installed; 12 devices inventoried (Section 8). |
| **D. Traffic analysis** | ⚠️ **Partially** | Passive capture works for what reaches the NIC (broadcast/multicast/its own traffic). Full flow analysis (ntopng/Zeek) only becomes useful once the box is a gateway or receives mirrored traffic — see Section 11. |
| **E. Temporary PoC firewall/router** | ⚠️ **Proven, short-term only** | The one-arm gateway is now **built and selftest-verified on this box** (see `reports/05-tvguard-gateway.md`): single-interface forwarding + masquerade works, UFW/Docker coexist, rollback is one command. The risk stands: any outage of this box takes down Plex, backups **and** the TV egress control together. Acceptable as a monitored PoC; replace with the dedicated box before trusting it. |
| **F. Permanent firewall/router** | ❌ **No** | Single NIC, Realtek 1GbE (not ideal for 24/7 routing), already hosts Plex + Samba + backups (SPOF for those), no redundancy. Use the dedicated box (Section 19). |
| **G. Plex + backups + DNS together** | ✅ **Yes (as today)** | Resource headroom is large. The concern is operational (a Pi-hole upgrade shouldn't take down Plex), not capacity. Keeping them in separate failure domains (Docker container vs systemd) already holds. |

---

## 3. Hardware

| Component | Detail |
|---|---|
| CPU | Intel Core i5-11320H, 4 cores / 8 threads, up to 4.5 GHz (Tiger Lake, laptop-class but strong) |
| RAM | 16 GiB (15.4 GiB usable; ~13 GiB available at audit) |
| Disk | NVMe 452 GB (`/`, 40 % used, 260 GB free) · SATA 938 GB (`/mnt/data`, 75 % — media/Plex) · SATA 3.6 TB (`/mnt/backup-ssd`, 17 % — backups) |
| NIC | **One** production NIC: `enp2s0`, Realtek RTL8111/8168 (8168 rev 15), driver `r8169`, **1 GbE full-duplex** |
| Other NIC | `wlp3s0` Wi-Fi — **down**, not used |
| Uptime | ~28 days at audit |

**NIC assessment for routing**: a single Realtek 1 GbE is *functionally* adequate for a
home gateway at this throughput (Virgin fibre is well under 1 GbE), but it is a
consumer chip on a laptop board, not a 24/7 routing appliance, and having only one
means no LAN/WAN separation on this box. The dedicated box should use Intel i225/i210
(Section 19).

---

## 4. Current Network

| Item | Value |
|---|---|
| Subnet | `192.168.0.0/24` |
| Default gateway | `192.168.0.1` (Virgin Hub 3, Sagemcom) |
| Server IP | `192.168.0.128/24` (DHCP via `dhcpcd` — **reserve this** in Step 1) |
| Server MAC | `68:1D:EF:32:4F:56` |
| DNS (now) | The Hub (`192.168.0.1`) is the resolver for all clients. `/etc/resolv.conf` on the server points to the Hub. **Nothing has been redirected.** |
| DHCP | The Hub. Pi-hole DHCP is **off** (no `67/udp` publish, no `NET_ADMIN`). |
| IPv4 forwarding | `1` (pre-existing, caused by Docker — not added by this work) |
| IPv6 forwarding | `0` |
| VPN/tunnels | None (no WireGuard/Tailscale). Docker bridge networks only. |
| UFW | Active. Pre-existing allow-rules for Plex/Samba/SSH/Transmission + `53` and `3001` (leftover AdGuard plan, from `192.168.0.0/24`). **No rules were added or removed by this work.** |

IPv6 is present on the LAN (link-local on the NIC, hub-provided) — relevant later for
the DNS-bypass test (Section 12/17).

---

## 5. Existing Services (must remain untouched — all verified running)

| Service | Ports | State |
|---|---|---|
| Plex Media Server | 32400/tcp (LAN), 32401, 32600 (local) | active |
| Samba (SMB/CIFS) | 445/tcp, 139/tcp | active (smbd) |
| NetBIOS (name/datagram) | 137/udp, 138/udp | active (nmbd) |
| Winbind (AD domain `KIASERVER`) | — | active |
| SSH | **13567/tcp** (not 22) | active |
| no-ip (noip2) | — | active (dynamic DNS for the public side) |
| Transmission | 9091/tcp (web), 51413 (peers) | active (`transmission-daemon`) |
| translator-docs (Flask) | 5050/tcp | active |
| Invoice stack (Docker) | 8088/tcp (frontend), internal Postgres 5432 | 3 containers up 4 weeks |

A pre-existing **raw iptables table contains DROP rules** shielding the invoice
container IPs (`172.19.0.2–4`) from the LAN. **These were not touched** and must be
preserved.

---

## 6. Pi-hole Installation (what was actually installed)

- **Image**: `pihole/pihole:2026.09.0` — the current **stable** v6 release
  (FTL 6.7.1, Core 6.4.3, Web 6.6). Pinned by tag, **not** `latest`/`nightly`.
  Chosen per https://docs.pi-hole.net/docker/ .
- **Compose**: `compose.yaml` (in this repo). Volumes: `./etc-pihole:/etc/pihole`.
- **Ports** (checked free first — 53 and 3001 were unoccupied; UFW already allowed both from the LAN, so **no firewall changes were required**):
  - `53/tcp`, `53/udp` → container 53 (DNS)
  - `3001/tcp` → container 80 (admin UI over HTTP; the container's self-signed 443 is **not** published)
  - `67/udp` (DHCP), `123/udp` (NTP), `443` are **not** published → DHCP stays off.
- **Upstreams**: `1.1.1.1` (Cloudflare) + `9.9.9.9` (Quad9, also blocks malware domains).
- **Gravity list**: the default **StevenBlack/hosts** (80,170 domains) — a single,
  well-maintained, conservative list. Deliberately **no** aggressive mega-list.
- **Credentials**: strong random 32-char password in `.env` (mode 600, git-ignored).
- **Known v6 change**: admin UI is at `/admin/`, and the API is session-based
  (`POST /api/auth` → `X-FTL-SID`), not the old token scheme.

**Resource impact (measured, idle)**: `docker stats` → **8 MiB RAM, 0.3 % CPU**.
No measurable change to disk, load, or the pre-existing services (health check green).

---

## 7. Access

```
Pi-hole admin UI : http://192.168.0.128:3001/admin/
Pi-hole IP       : 192.168.0.128   (DNS on 53/tcp+udp, same IP)
Credential file  : /home/kia/dns/.env   (ADMIN_PASSWORD, mode 600)
```

The password is **not** written in this file. Read it with:
`grep ADMIN_PASSWORD= /home/kia/dns/.env` (run on the server, it is not printed in
any report). For scripts, generate an **application password** in the UI
(Settings → API) instead of reusing the main one.

---

## 8. LAN Inventory

12 devices discovered (method + full table in `reports/02-lan-inventory.md`,
machine-readable in `data/lan-inventory.csv`).

| IP | What it is | Category |
|---|---|---|
| .1 | Virgin Hub 3 (Sagemcom) | router |
| .32 | unknown, MAC-randomised | IoT/Android (likely) |
| .83 | Ubiquiti "Access" | UniFi AP/node |
| **.90** | **Google TV Streamer** ("Living Room TV", redsonic) | **TV/streaming** |
| .128 | this server | server |
| .147 | "helix-01", self-firewalled | server-like |
| .181 | unknown | IoT (likely) |
| .187 | Samsung Galaxy Tab S6 Lite (MAC-randomised) | tablet |
| **.197** | **Samsung 65" QLED QE65Q75A (Q75A, Tizen 2021)** | **TV** |
| .206 | KiaPC (Windows) | PC (backup client) |
| .212 | DESKTOP-KSLH164 (Intel NUC, Windows) | PC |
| .225 | dgiot (Shenzhen Bilian) | IoT (camera/hub) |

**TVs (high confidence, from UPnP/SSDP + PTR, not guessed):**
- `192.168.0.197` — **Samsung 65" QLED, model `QE65Q75CATXXU` (Q75A, Tizen, 2021)**.
  Evidence: UPnP `Samsung-Linux/4.1, Samsung_UPnP_SDK/1.0`, DIAL receiver
  "65\" QLED" with that model + serial, DMR `:9197/dmr`, screen-share `:9119`,
  SmartThings "alive" beacon on `224.0.0.7:8001` every 2 s.
- `192.168.0.90` — **Google TV Streamer**. Evidence: UPnP DIAL receiver friendlyName
  "Living Room TV", modelName "Eureka Dongle", `X-User-Agent: redsonic`
  (the Streamer's codename), Chromecast discovery on UDP/10101.

Both TVs are registered as Pi-hole clients in the **TV-Monitor** group; `dgiot`
(`.225`) is in **IoT**.

---

## 9. Current Visibility (what this machine can and cannot see — proven)

Full evidence in `reports/03-current-visibility.md`. Summary:

**CAN see now**
- Broadcast (dgiot `.225→:6667`, Plex GDM), multicast (SSDP `239.255.255.250:1900`,
  SmartThings `224.0.0.7:8001`, Chromecast `:10101`), ARP, unicast **addressed to
  this server** (KIAPC→SSH, the TVs' SSDP replies to Plex's socket), and **its own
  egress** (Plex→CDN, transmission tracker, no-ip).

**CANNOT see now**
- **TV → Internet unicast** (zero). TV→other-device unicast. Any client unicast not
  addressed to us. This is the fundamental switched-LAN limit.

**WHY**: a switch delivers a frame only to the port(s) it is addressed to (plus
broadcast/multicast). kiaserver is one more port, not a gateway, not the resolver,
and not mirrored.

**What network change would make it visible** (choose one, in order of preference):
1. **Point the TVs' (then the LAN's) DNS at this server** → DNS becomes visible.
2. **Put this server (or the future box) in the path as gateway/firewall** → all
   unicast becomes visible + controllable.
3. **Port-mirror a switch port** → passive visibility without being in the path
   (needs a managed switch; the Virgin Hub cannot mirror).

No ARP spoofing or MITM was used or will be.

---

## 10. TV Findings (passive, no contact)

From the captures:
- The **Samsung TV** continuously emits a SmartThings "alive" beacon (every ~2 s)
  and answers SSDP. It exposes a DIAL/DMR receiver (used by casting) and a
  screen-sharing endpoint.
- The **Google TV Streamer** runs Chromecast-style discovery (UDP/10101) and a UPnP
  DIAL receiver.
- Both currently resolve DNS via the **Hub** — so **none of their DNS is visible to
  us yet**. This changes only after the staged rollout.

---

## 11. Traffic Analysis — what is ready now

Tools installed (low-risk, official repos): `tcpdump`, `tshark` (on demand),
`nmap`, `arp-scan`, `avahi-utils`, `dnsutils`, `ethtool`, `conntrack`. Reusable
scripts in `scripts/` (see README table).

**Chosen stack (deliberately minimal):**
- **Now**: `tcpdump`/`tshark` for passive captures (headers, not payloads),
  `conntrack` for live per-device flows, and the **Pi-hole query log** for DNS.
- **Deferred** (documented, not installed): **ntopng** and **Zeek**. They only add
  value *after* the box becomes a gateway or receives mirrored traffic, because they
  analyze flows that must first reach the box. Installing them now would consume
  RAM/CPU for data they cannot yet see. Revisit in the gateway phase.

This matches the "smallest sensible stack" goal: DNS (Pi-hole) + passive capture
(tcpdump) + live flow table (conntrack) cover the PoC; ntopng/Zeek are the natural
next step once traffic is in the path.

---

## 12. Limitations

1. **Switched-LAN visibility** (Section 9): no TV→Internet unicast is visible until
   DNS is pointed here or the box becomes the gateway/mirror.
2. **Encrypted HTTPS/QUIC**: even when a TV talks to us or to the gateway, we can
   see **destination IP, port, SNI (server name), byte counts, and timing** — but not
   the payload. We **cannot** read a voice transcript from an HTTPS body without TLS
   MITM, which is explicitly **not** part of this architecture (Section 13).
3. **DNS is only one signal**: a TV can send telemetry to a domain that *also* serves
   legitimate content (same hostname, different paths), or use hard-coded IPs / DoH /
   DoT to bypass us. Classification is therefore evidence-based and per-action
   (Section 15 methodology), never by hostname alone.
4. **No active scanning** was performed (per your constraint); some device types are
   inferred from OUI/PTR/UPnP and marked as such.

---

## 13. Full Target Architecture

```
                     Internet
                          |
                  Virgin Hub 3
                 (modem / NAT / DHCP)
                          |
        +-----------------+-----------------+
        |                 |                 |
  [Trusted LAN]     [TV / IoT VLAN]    (other as needed)
   PCs, phones,      Samsung TV,         e.g. guests
   Plex server,      Google TV,
   backups           dgiot, ...
        |                 |
        +--------+--------+
                 |
            Pi-hole / DNS
        (forced, per-device policy)
                 |
        [Gateway / egress firewall]
   per-device allow/deny by IP:port
```

**How we get there with a Virgin Hub** (detailed in `ROUTER_NEXT_STEPS.md`):
- The Hub is the modem+router today. The clean end state is **Hub in modem mode**
  (or stays as-is for a while) with a **dedicated x86 box** providing: routing/NAT,
  Pi-hole DNS, forced-DNS, per-device egress, and (optionally) a TV/IoT VLAN.
- The **TV/IoT network** is a separate subnet/VLAN so the firewall can apply a
  *stricter* egress policy to TVs than to PCs, while still allowing: Internet,
  Plex (local), and casting/discovery (mDNS/SSDP) where wanted — and blocking
  TV-initiated connections into trusted computers.

**Gateway platform comparison (for your scenario, not hype):**

| Option | Fit here | Notes |
|---|---|---|
| **Plain Debian + nftables** (on the dedicated box) | **Best** | You already run Debian; full control, no GUI tax, scriptable per-device rules; you own the firewall config. More manual but exactly matches this project's evidence-based tuning. |
| **OPNsense** (on the dedicated box) | Good | Excellent UI, built-in DNS proxy + per-device rules, VLAN support. Slightly heavier, more "appliance" oriented. A strong choice if you prefer GUI + hardening defaults. |
| **OpenWrt x86** | Acceptable | Very light, great for small routers; UI is less rich for complex per-device DNS policies and VLANs than OPNsense/Debian. |

Recommendation: **Debian + nftables on the dedicated box** (matches your skill set
and this repo's scripts), or **OPNsense** if you want a turnkey appliance. Either
way, the box is the gateway; kiaserver keeps Plex/backups and the Pi-hole *can* move
onto the box.

---

## 14. Proposed Security Layers

| Layer | Mechanism | Status |
|---|---|---|
| 1 — DNS logging/filtering | Pi-hole, per-group allow/deny + gravity | **Done** (isolated) |
| 2 — Forced DNS | TV DNS → Pi-hole; external :53 (udp/tcp) transparently redirected to Pi-hole by TVGuard (proven); DoT 853 block in enforce mode | **Done for selected TVs** (active once a TV uses the box as gateway) |
| 3 — Per-device egress firewall | `tvguard` nftables table: per-TV allow/log/counter, enforce-mode drops from the evidence ledger | **Built + selftest-verified** (monitor live; enforce armed) |
| 4 — TV/IoT isolation | Separate VLAN/subnet, stricter egress, no TV→trusted-LAN init | Gateway phase (dedicated box) — **not** provided by the one-arm PoC (L2 caveat) |
| 5 — Monitoring | Pi-hole query log + conntrack session recorder + nft counters + tshark | **Done** (passive + per-session) |
| 6 — Evidence-based tuning | Block only destinations *proven* telemetry per action (`config/destinations.yaml` + compare tool) | Methodology ready, tooling tested |

---

## 15. What Pi-hole CAN protect against

- **Block and log domains** that a *compliant* client resolves through it
  (ad/tracking domains in the gravity list; specific domains you add).
- **Per-device policy** via groups (TV-Monitor, TV-Strict, IoT, Trusted, Testing) —
  different block/allow sets per TV.
- **Detect DNS-based bypass** attempts *if* the client is pointed at us (queries for
  known public resolvers like `dns.google`/`1.1.1.1` appear as lookups).
- **Provide the per-action DNS evidence** used in Section 16.

## 16. What Pi-hole CANNOT protect against

- Traffic that **never queries it**: hard-coded IPs, DNS-over-HTTPS/TLS, vendor
  resolvers, or any app that ignores the system DNS.
- **Payload inspection**: it sees the *name* a client asks for, not the content —
  so it cannot see or stop a voice transcript, and cannot distinguish telemetry from
  legitimate use **on the same domain**.
- **Non-DNS discovery** (mDNS/SSDP/QUIC-to-IP) beyond logging.
- Anything the client can **bypass** until Layer 2 (forced DNS) + Layer 3
  (egress firewall) are in place.

**Honest statement**: *"Pi-hole stops the TV sending transcripts"* is **false**.
Pi-hole can stop the TV from *resolving* a domain it's pointed at. It says nothing
about encrypted content or connections that don't use it.

## 17. What requires a gateway / firewall

- **Forcing** DNS (blocking egress UDP/TCP 53, 853, DoH to non-ours) so clients
  actually *must* use Pi-hole. → **now implemented for the selected TVs** by
  TVGuard (external :53 redirected, 853 blocked in enforce); network-wide
  enforcement comes with the dedicated box.
- **Per-device egress** allow/deny by IP:port (the real "stop TV → telemetry host").
  → **implemented (monitor live / enforce armed)** for the two TVs; the rest of
  the LAN is structurally unaffected (source-IP-scoped rules).
- **Network isolation** (TV/IoT VLAN; block TV→trusted-LAN init). → dedicated box phase.
- **IPv6** egress control (a common bypass: `AAAA`/DoH over v6). → assessed: no
  global IPv6 prefix is advertised on this connection (4-minute RA capture empty),
  so there is currently no v6 bypass path; the pattern would mirror to `ip6` if
  Virgin ever enables it.
- **Visibility** of all unicast (needed before ntopng/Zeek pay off). → TV traffic
  is now visible once routed through the box; whole-LAN visibility still needs
  gateway/mirror (dedicated box).

## 18. What we can realistically determine about TV voice/transcript traffic

Without TLS MITM (which is out of scope), for a TV that is pointed at our DNS and in
our gateway path, we can observe and correlate, **per user action**:

- The **DNS names** the TV looks up (before/during the action).
- The **destination IP + port**, protocol, **bytes sent/received**, **SNI**, and
  **timing** of each new connection.

By running the action matrix below and diffing the sets, we can classify each
destination as `ESSENTIAL / LIKELY ESSENTIAL / UNKNOWN / ANALYTICS / ADVERTISING /
TELEMETRY / CRASH / VOICE-RELATED / SAFE-TO-TEST / DO-NOT-BLOCK` **with evidence and
a confidence level**.

**What we cannot determine without MITM:** the *content* of a transcript, or which
specific sub-request on a shared domain is "voice" vs "video". We can only say a
destination is *correlated with the voice action* and is *safe/unlikely* to block.

**Test matrix (to run after the TV is on our DNS + in the gateway path):**

| Test | Action | Capture |
|---|---|---|
| Baseline | TV on, home screen, 10 min idle | DNS, dst IP:port, bytes, SNI, timing |
| A | Power on, home screen idle | Δ vs baseline |
| B | Launch YouTube | Δ |
| C | Launch Plex | Δ |
| D | Cast from phone | Δ |
| E | Use voice/search on TV | Δ ← voice/assistant candidates |

For each, record new/changed destinations and classify with evidence (what changed,
when, to whom, how much data) — never by hostname appearance alone.

---

## 19. Dedicated Hardware Requirements (for the future box)

Derived from the recommended architecture (Debian/OPNsense gateway + Pi-hole +
optional ntopng/Zeek + TV/IoT VLAN), **not** from a product:

| Requirement | Guidance | Why |
|---|---|---|
| **NIC count** | **Minimum 2** (WAN + LAN). **3–4 preferred** to split TV/IoT VLAN on its own port without a switch. | VLAN isolation + clean LAN/WAN separation. |
| **NIC type** | **Intel i210 (1GbE) or i225 (2.5GbE)**, ideally dual/quad. **Avoid USB Ethernet for permanent routing** (no offload, less stable, driver quirks). | Intel NICs have excellent Linux/DPDK/`i40e`/`igb` support and hardware offloads. |
| **Speed** | 1 GbE is sufficient for this WAN; **2.5 GbE is a nice-to-have** for the LAN side if you stream 4K/Plex heavily. | Headroom for Plex + backups + TV. |
| **CPU** | Any modern 4-core x86 (i3/i5, or Intel N100/N95 for lowest power). | Router + Pi-hole + Zeek is light; CPU is rarely the bottleneck. |
| **RAM** | **8 GB** minimum (covers ntopng/Zeek + Pi-hole + OS); 16 GB if you run heavy flow logging. | Generous headroom. |
| **Storage** | 256 GB SSD is plenty (logs can grow; add a disk if you keep long Zeek logs). | OS + logs. |
| **Power** | Fanless mini/SFF (~10–25 W) preferred for 24/7. | Silent, low draw. |
| **Form factor** | **Mini/SFF (mITX) is appropriate.** Tiny/Micro (e.g. no PCIe) is fine *if* it has the required on-board Intel NICs; avoid boards that rely on USB NICs. | Fit in the rack/closet. |
| **PCIe** | Only needed if the board lacks enough on-board Intel NICs — then add a **dual/quad Intel PCI-E NIC** (e.g. i210/i225 dual-port). | NIC count is the main reason to expand. |

**Shortlist shape**: a low-power mITX mini-PC (Dell/Lenovo/HP or similar) with
**dual or quad Intel i210/i225**, 8–16 GB RAM, 256 GB SSD. Confirm the NICs are
**Intel on-board** (not USB/Realtek) before buying.

---

## 20. What was NOT done (per your safety rules)

- No Virgin Hub change, no DHCP enabled, no DNS redirection of any client, no
  ARP spoofing/MITM, no switch change, no reboot of the host, no Plex/backup
  interruption, no OS upgrade.
- Pi-hole DHCP off; no `67/udp` published.
- The only live network changes made are TVGuard's own, surgically scoped
  footprint: the `tvguard` table (inert until a TV uses the box as gateway),
  two `ufw-user-forward` rules scoped to the two TV IPs, and two sysctls
  (`ip_forward`, `send_redirects`) — all one-command removable (ROLLBACK.md).
  No blanket LAN filtering, no NAT of non-TV traffic, no client redirected.

## 21. Final Verification (2026-09-20)

`scripts/health-check.sh` → **ALL CHECKS PASSED** (re-run after TVGuard work; see
`reports/05-tvguard-gateway.md` §9 for the gateway selftest):
- Plex, Samba, Winbind, no-ip, Transmission, SSH: **active**.
- Docker: 4 containers up (pihole healthy + 3 invoice).
- Local DNS test: NOERROR. Blocking test: blackhole confirmed, then unblocked.
- Persistence across `docker restart`: group + deny entry retained.
- **TVGuard selftest: 7/7 PASS** (mock-TV netns: DNS-bypass redirect with correct
  per-client attribution, HTTP/HTTPS egress via masquerade, conntrack return path
  through .128, UFW coexistence, full teardown).
- **TVGuard state**: `table ip tvguard` loaded in `monitor` mode; counters at 0
  (dormant — no TV uses the box as gateway yet); `ufw-user-forward` holds exactly
  the two TV rules; sysctls set; `tvguard.service` enabled + active (gated by the
  `active` marker).
- **No** DHCP server on `67`; router untouched; no clients redirected; UFW/Docker
  rule sets verified unchanged against the pre-change baseline
  (`reports/raw/05-baseline-netfilter.txt`).

## 22. TVGuard one-arm gateway PoC (added 2026-09-20)

The complete privacy/monitoring/firewall PoC now runs on this machine — the
dedicated box will inherit this repo rather than the project "starting over".

- **Design & proof**: `reports/05-tvguard-gateway.md` (one-arm NAT correctness,
  the base-chain ordering finding, DNS-bypass DNAT, IPv6 assessment, limitations).
- **Your manual steps only**: `ROUTER_NEXT_STEPS_V2.md` (Hub reservations +
  Samsung gateway/DNS change + the monitor test sequence).
- **One-command rollback**: `ROLLBACK.md` R0 → `sudo scripts/tvguard-disable.sh`.
- **Migration**: `MIGRATION_TO_DEDICATED_BOX.md` + `bootstrap.sh` on the new box.
- **Session evidence workflow**: `sudo scripts/tv-session.sh samsung <label> <dur>`
  then `python3 scripts/compare-tv-sessions.py <dir1> <dir2> [--out file]`.
