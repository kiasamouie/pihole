# 02 — LAN Inventory

Method (all non-intrusive, no exploit scans, no aggressive scripts):
1. `arp-scan` (ARP probes, full 192.168.0.0/24)
2. Gentle TCP connect scan of 14 common ports (`-sT --max-rate 50`)
3. Passive tcpdump capture (broadcast/multicast/SSDP)
4. UPnP/SSDP M-SEARCH + device description XML fetch
5. Reverse DNS via the hub (`192.168.0.1` has DHCP-derived PTR records)

Machine-readable: `data/lan-inventory.csv`. Raw evidence: `reports/raw/03-*.txt`.

## Devices

| IP | MAC | Vendor (OUI) | PTR name | Category | Evidence |
|---|---|---|---|---|---|
| 192.168.0.1 | D8:33:B7:C5:4D:4B | Sagemcom Broadband | — | **Virgin Hub 3** (router) | Gateway; 53/80/443 open |
| 192.168.0.32 | AA:28:D5:3F:7A:88 | (randomised) | — | Unknown — likely IoT or Android (MAC randomisation) | No SSDP; all 14 ports closed |
| 192.168.0.83 | 60:22:32:4C:D7:AC | Ubiquiti | Access | UniFi device (AP or controller node) | 22 + 8080 open |
| **192.168.0.90** | 14:C1:4E:1C:2F:4B | **Google** | Chromecast | **SMART TV / streaming — Google TV Streamer** | UPnP DIAL receiver: friendlyName **"Living Room TV"**, modelName "Eureka Dongle", `X-User-Agent: redsonic` (the Streamer's codename); Chromecast discovery on UDP/10101; 8443 open |
| 192.168.0.128 | 68:1D:EF:32:4F:56 | (this server) | kiaserver | This server | — |
| 192.168.0.147 | 34:5A:60:36:DC:42 | unknown | **helix-01** | Unknown server-like box with own firewall | 22 + 80 open, everything else filtered |
| 192.168.0.181 | C0:4B:24:49:8C:6C | unknown | — | Unknown — likely IoT | No SSDP; all ports closed |
| 192.168.0.187 | 76:0F:9B:43:64:F1 | (randomised) | **Galaxy-Tab-S6-Lite** | Samsung tablet | Android MAC randomisation confirmed by locally-administered OUI |
| **192.168.0.197** | 1C:86:9A:AA:8E:96 | **Samsung Electronics** | Samsung | **SMART TV — Samsung 65" QLED, model QE65Q75CATXXU (Q75A, Tizen, 2021)** | UPnP `Samsung-Linux/4.1, Samsung_UPnP_SDK/1.0`; DIAL receiver "65\" QLED" (modelName QE65Q75CATXXU, serial 20090804RCR); DMR endpoint `:9197/dmr`; screen-sharing endpoint `:9119/screen_sharing`; SmartThings "alive" beacon on 224.0.0.7:8001 every 2 s; 8080 open |
| 192.168.0.206 | D8:5E:D3:0E:C7:06 | Giga-byte | KiaPC (KIAPC) | Windows PC (backup client) | 445 open; observed SSHing to this server's 13567 during capture |
| 192.168.0.212 | 34:2E:B7:47:05:D1 | Intel (NUC) | DESKTOP-KSLH164 | Windows PC on Intel NUC | Windows firewall active (filtered) |
| 192.168.0.225 | F0:C8:14:40:FB:3F | Shenzhen Bilian Electronic | dgiot | DGIOT IoT device (camera/hub class) | Broadcasts 255.255.255.255:6667 every 5 s |

## TVs — identification summary

Two TVs found, both confirmed by their own UPnP device descriptions (not guessed):

1. **Samsung QE65Q75CATXXU** — 192.168.0.197, Tizen (2021, 1080p Q75A). Actively announces itself: SmartThings beacon every 2 s, three UPnP endpoints (DIAL, DMR casting, screen sharing).
2. **Google TV Streamer** — 192.168.0.90, user-named "Living Room TV". Actively announces itself: DIAL receiver + Chromecast/SSDP discovery.

Both are currently powered on (both beacons/UPnP were observed live during the audit).

No other smart TV or streaming stick was discovered. The .187 tablet and .32/.181 unknowns may have been phones/tablets in standby (no services, no SSDP) — they simply did not announce.

## Notes on discovery

- mDNS (`avahi-browse`): **no mDNS records were observed at all** — neither TV advertises over mDNS. This matters: Chromecast/DIAL discovery for these TVs relies on SSDP + UDP/10101 (Chromecast protocol), not mDNS.
- The TVs' SSDP responses to Plex's M-SEARCH are currently being **dropped by UFW** on the server (see audit §Findings) — the responses exist on the wire (tcpdump) but no local socket receives them. Passive capture remains the reliable discovery path until that rule is revisited.
- OUI lookups for locally-administered MACs (.32, .147, .187) cannot identify vendor by design (Android privacy feature).
