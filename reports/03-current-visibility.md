# 03 — Current Traffic Visibility (what kiaserver can actually see today)

Basis: 30 s full promiscuous capture on `enp2s0` (snaplen 96, `reports/raw/01-network.txt` context + live captures), a 25 s filtered capture of the TVs' SSDP traffic, and the UFW block log. The server is an ordinary DHCP client on a switched L2 LAN — it is **not** a gateway, **not** a DNS server for anyone, has **no** port mirroring, and is **not** a bridge.

## WHAT WE CAN SEE NOW

| Traffic type | Example observed | Why it reaches us |
|---|---|---|
| Broadcast (255.255.255.255) | dgiot `.225 → :6667` every 5 s; Plex GDM → :32412/32414 | Switches forward broadcasts to all ports |
| Multicast (239/224.x) | SSDP 239.255.255.250:1900 M-SEARCH+responses; Samsung SmartThings 224.0.0.7:8001 "alive" beacon; Chromecast 224.0.0.250/239.255.255.251:10101 | IGMP-joined multicast delivered to all ports (or at least ours) |
| ARP | hub's who-has .128, TV's who-has .128 | Broadcast + unicast reply |
| Unicast **addressed to this server** | KIAPC `.206 → 13567` (SSH); TV `.197` SSDP reply → Plex socket 38270; hub's SSDP reply → 38270 | Destination IP is us |
| **Our own** egress (server-initiated) | Plex → 86.20.94.158:32400 (Plex CDN); transmission tracker; no-ip | Source is us |
| LLDP | From the switch, "Access Point" | LLDP is broadcast |

## WHAT WE CANNOT SEE NOW

- **TV → Internet unicast traffic.** The Samsung TV talking to samsung.com / YouTube / Google: we see **zero** of it. Not the DNS queries (they go to 192.168.0.1), not the HTTPS/QUIC sessions.
- **TV → other-device unicast** (e.g. TV → KiaPC, TV → hub).
- **Any LAN device's** unicast traffic not addressed to us.

## WHY

On a switched Ethernet LAN each frame is delivered only to the port(s) whose MAC it is addressed to (plus broadcast/multicast floods). kiaserver is one more port on the switch:

1. Client traffic to the Internet is forwarded by the switch to the hub (next hop for everything), not to us. We are not in the path.
2. The TVs use the **hub's** DNS (194.168.4.100 via 192.168.0.1) — no query ever reaches us.
3. No switch port mirroring is configured (consumer hub = no TAP/mirror capability at all).
4. We are not a bridge, router, or the default gateway.

This is exactly the expected behaviour for an ordinary switched LAN, and it is proven by the capture: in 30 s we saw the TVs' *discovery* chatter (broadcast/multicast) and **not a single** unicast packet from either TV that was not addressed to us.

**Important corollary:** absence of packets in our capture does *not* prove the TVs are quiet. We simply cannot see them. All "the TV sent X" conclusions must come from (a) broadcast/multicast (visible), (b) traffic addressed to us, or (c) future positions where the TV's traffic must traverse us.

## Additional finding: UFW silently drops unicast discovery replies

The TVs *do* reply to UPnP M-SEARCH on the wire (Samsung: 3× ~20 s cadence; Google + hub too), but every reply to a high local port is logged as `[UFW BLOCK]` (default-deny INPUT; only specific ports are opened). Net effect:

- The server cannot run SSDP/Chromecast **active** discovery today (replies dropped) — only **passive** capture works.
- Plex's own SSDP-based device discovery (socket bound to 192.168.0.128:38270) is broken in the same way today; Plex still works because clients connect *to* it.
- Fix when needed: `ufw allow from 192.168.0.0/24 to any udp port 1900` (host-local INPUT rule, no effect on LAN traffic). Not applied yet.

## WHAT NETWORK CHANGE WOULD BE REQUIRED TO SEE TV→INTERNET TRAFFIC

Ranked by fit for this home network (details in REPORT.md §13/§16):

1. **Make the TV's DNS point at this server** (per-device, then per-VLAN later). Sees *all* domain names the TV resolves — the cheapest, highest-value change. Requires the TV to be stopped from bypassing (later firewall work).
2. **Make this server (or a dedicated box) the TV's gateway** — modem mode on the hub + this box (or a future dedicated firewall box) as router/NAT for a TV/IoT VLAN. Sees **everything**: src → dst → port → bytes, per device.
3. **Port mirroring** — not possible: the Virgin Hub has no managed-switch/TAP capability.
4. **Managed switch + TAP port** — would work on the existing topology but buys a managed switch and still only mirrors (no control). Not recommended vs option 2.

Until (1) or (2) exists, the empirical TV-telemetry programme (Phase 10) can only partially run: DNS-layer experiments need step 1; full per-action destination/byte accounting needs step 2.
