# 01 — Current Machine Audit (kiaserver)

Captured: 2026-09-20 11:18–11:45 BST (read-only). Raw outputs in `reports/raw/`.

## OS

| Item | Value |
|---|---|
| Distro | Debian GNU/Linux 13 (trixie), 13.4 |
| Kernel | 6.12.74+deb13+1-amd64 |
| Arch | x86-64 |
| Hostname | kiaserver |
| Uptime | 28 days 17 h (started ~2026-08-22) |
| Load avg | 0.19 / 0.29 / 0.38 (very light) |
| Pending reboot | No `/var/run/reboot-required` marker |

## Hardware

- **CPU:** 11th Gen Intel Core i5-11320H — 4 cores / 8 threads, up to 4.5 GHz (laptop-class H-series in a mini/NUC chassis; chassis is generic, "Default string").
- **RAM:** 16 GiB total, ~1.3 GiB used, ~14 GiB available. Swap 15 GiB (70 MiB used).
- **Disks:**
  | Device | Size | Mount | Used | Notes |
  |---|---|---|---|---|
  | nvme0n1 (476.9G, NS512GSSD530) | 452G / | 40% (169G) | OS, 261G free |
  | sda (1TB, FIKWOT FN203 — USB NVMe) | /mnt/data | 75% (660G) | Media/data store |
  | sdb (3.6TB, "Expansion") | /mnt/backup-ssd | 17% (614G) | Backup target |
  | sdc | 0B | — | empty slot |

**Conclusion:** vastly oversized for Pi-hole/DNS duties. The box is a media + backup server, not a network appliance.

## Networking

### Physical NICs (2)

| Interface | Chipset | Driver | Speed | State | Role |
|---|---|---|---|---|---|
| `enp2s0` | Realtek RTL8111/8168/8211 PCI-E GbE [10ec:8168 rev 15] | r8169 | 1000 Mb/s full | UP | **Only production NIC** — LAN, 192.168.0.128/24 |
| `wlp3s0` | Realtek RTL8852BE PCIe 802.11ax WiFi | rtw89_8852be | — | DOWN | Unused (disabled) |

**Usable physical Ethernet interfaces: ONE (1GbE, Realtek).**
A Realtek r8169 is fine for low-volume gateway duty at home scale, but for a *permanent* router a dual- or quad-port Intel NIC (i210/i225) is the better buy — this box cannot do proper WAN/LAN segmentation on two physical ports without adding hardware.

### Addresses / routes

- enp2s0: `192.168.0.128/24` (DHCP via dhcpcd), link-local `fe80::c23c:1804:6d08:d906/64`
- Default gateway: `192.168.0.1` (Virgin Hub)
- No static routes beyond kernel-generated Docker networks
- **No bridges, no bonds, no VLANs, no WireGuard/Tailscale/VPN interfaces**

### Virtual interfaces

- `docker0` (172.17.0.1/16, DOWN, unused default bridge)
- `br-1725cc87228d` (172.19.0.1/16, driver "bridge", named `invoice_default`) + 3 veth pairs for the invoice containers

### DNS / forwarding

- `/etc/resolv.conf` (dhcpcd-generated): nameservers `194.168.4.100`, `194.168.8.100` (Virgin), domain `cable.virginm.net`
- `net.ipv4.ip_forward = 1` (required by Docker — **already enabled**, do not disable)
- `net.ipv6.conf.all.forwarding = 0`
- `nf_conntrack` loaded and active (useful later for connection tracking/counters)

## Existing services (MUST REMAIN UNTOUCHED)

| Service | What it does | Listeners |
|---|---|---|
| `plexmediaserver` (Plex 1.41.5.9522) | Media server — **core function** | TCP 32400 (LAN+any), 127.0.0.1:32401, GDM UDP 32410–32414, DIAL/UPnP socket bound to 192.168.0.128:38270 |
| Samba `smbd`/`nmbd`/`winbind` (domain **KIASERVER**) | File sharing / likely AD-DC for the LAN (samba-dcerpcd workers running) | 445, 139, 137/udp, 138/udp |
| `ssh` (OpenSSH) | Remote admin — **keep working** | **13567/tcp** (non-standard port, open to Anywhere) |
| `noip2` | Dynamic DNS client (no-ip) | — (outbound) |
| `transmission-daemon` | BitTorrent | TCP/UDP 51413, Web UI 9091 |
| `translator-docs` (Flask) | Doc translation API | 5050/tcp (LAN + 172.16.0.0/12) |
| Docker 29.4.1 + 3 containers | `invoice-backend` (node, :3001 internal), `invoice-frontend` (nginx, **host 8088**), `invoice-postgres` (postgres:16-alpine, :5432 internal) | 8088/tcp |
| Host `node server.js` (PID 1518) | Invoice-related host process | internal |
| `smartmontools`, `cron`, `systemd-timesyncd` | Standard | — |

**Port 53 (tcp/udp), 80, 443: nothing listening.** Port 3001: nothing listening on host (container-internal only).

## Firewall (UFW) — as found, NOT modified

`ufw status`: active, logging low, **deny in / allow out / deny routed**. Notable existing rules:

```
53/tcp   ALLOW IN 192.168.0.0/24   # AdGuard Home DNS TCP   <- already open for Pi-hole
53/udp   ALLOW IN 192.168.0.0/24   # AdGuard Home DNS UDP   <- already open for Pi-hole
3001/tcp ALLOW IN 192.168.0.0/24   # AdGuard Home web admin <- fits Pi-hole admin UI perfectly
32400/tcp ALLOW IN Anywhere        # Plex
13567/tcp ALLOW IN Anywhere        # SSH
445/139/137/138 LAN-only          # Samba
9091/tcp  ALLOW IN Anywhere       # Transmission
5050/tcp  LAN + docker CIDR       # translator-docs
```

Also present: custom `raw`-table DROP rules shielding the invoice container IPs (172.19.0.2–4) from LAN-initiated traffic. FORWARD policy is DROP with 0 packets seen (box is not routing anything yet).

**Lucky fit:** someone previously opened UFW for an AdGuard Home deployment (ports 53 + 3001). Pi-hole can use exactly those ports with **zero UFW changes**.

## Findings / anomalies

1. **`apt-get update` is broken**: the Plex APT repo now fails signature verification (SHA-1 signing rejected by Debian 13's 2026 policy). Debian repos still update fine. Fix is a Plex repo config change — left alone.
2. **UFW is dropping inbound unicast SSDP responses to the server.** Journal shows 90 `[UFW BLOCK]` entries in 30 min, e.g. the Samsung TV's UPnP responses to Plex's M-SEARCH (DPT=38270) — so Plex's own SSDP discovery currently fails silently. tcpdump sees the packets (capture is pre-netfilter) but no local socket ever receives them. Relevant later when using SSDP for discovery/analysis; **not changed now**.
3. ethtool/sysctl/procps/tcpdump were not installed (installed now, low-risk diagnostic tools).
4. `avahi-browse` appears to leave orphaned child processes when killed with `timeout`; harmless.

## Port conflict check for Pi-hole (required before bind)

| Port | Host state | UFW (LAN src) | Verdict |
|---|---|---|---|
| 53/tcp | FREE | already ALLOW from 192.168.0.0/24 | use for DNS |
| 53/udp | FREE | already ALLOW from 192.168.0.0/24 | use for DNS |
| 3001/tcp | FREE (no host listener) | already ALLOW from 192.168.0.0/24 | use for admin UI |
| 80/tcp | free but UFW would block LAN access | not allowed | not needed |

→ **No existing service displaced; no UFW change required.**
