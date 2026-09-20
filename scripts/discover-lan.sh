#!/usr/bin/env bash
# discover-lan.sh - Re-run passive LAN discovery (no exploit scanning, no aggressive probes).
#
# Usage: sudo scripts/discover-lan.sh
#
# Performs:
#   1. arp-scan (single pass, ARP only)
#   2. Reverse DNS on each IP via the hub's resolver (PTR records)
#   3. avahi-browse (10 s, mDNS only)
#   4. Passive SSDP/UPnP capture (15 s, listens only - no M-SEARCH sent)
#
# Output: reports/raw/lan-refresh-YYYYmmdd-HHMMSS/ + CSV merged into data/lan-inventory.csv
# Safe: read-only network operations, no packets sent except the single arp-scan ARP probe
# and the standard avahi/SSDP discovery the devices themselves already emit.
set -euo pipefail

OUT="reports/raw/lan-refresh-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
LAN="${1:-192.168.0.0/24}"
HUB_RESOLVER="${2:-192.168.0.1}"

echo "== arp-scan $LAN ==" | tee "$OUT/arp-scan.txt"
arp-scan --retry=1 -I enp2s0 "$LAN" 2>/dev/null | tee -a "$OUT/arp-scan.txt" || true

echo "== PTR lookups via $HUB_RESOLVER ==" | tee "$OUT/ptr.txt"
while read -r ip _; do
    [ -z "$ip" ] && continue
    case "$ip" in 192.168.*) ;; *) continue;; esac
    ptr=$(dig +short -x "$ip" @"$HUB_RESOLVER" 2>/dev/null | head -1 | sed 's/\.$//')
    printf '%s %s\n' "$ip" "${ptr:-none}" | tee -a "$OUT/ptr.txt"
done < <(awk '$2=="HW address"' "$OUT/arp-scan.txt" | awk '{print $1, $2}') || true

echo "== avahi (10 s, mDNS) ==" | tee "$OUT/avahi.txt"
timeout 10 avahi-browse -a -r 2>/dev/null | tee "$OUT/avahi.txt" || true

echo "== passive SSDP/UPnP capture (15 s) ==" | tee "$OUT/ssdp.txt"
sudo tcpdump -i enp2s0 -n -l 'udp port 1900' 2>/dev/null > "$OUT/ssdp-pcap.txt" &
TPID=$!
sleep 15
kill "$TPID" 2>/dev/null || true

echo "Done. Raw output in $OUT"
echo "Merge new rows into data/lan-inventory.csv manually (see reports/02-lan-inventory.md)."
