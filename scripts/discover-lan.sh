#!/usr/bin/env bash
# discover-lan.sh - Re-run passive LAN discovery (no exploit scanning, no aggressive probes).
#
# Usage: sudo scripts/discover-lan.sh
#
# Performs:
#   1. arp-scan (single pass, ARP only)
#   2. Reverse DNS on each LAN IP (PTR records)
#   3. avahi-browse (10 s, mDNS only)
#   4. Passive SSDP/UPnP capture (15 s, listens only - no M-SEARCH sent)
#
# Reads LAN_INTERFACE/LAN_SUBNET/UPSTREAM_ROUTER from the machine config
# (.env or config/tvguard.conf). Output: reports/raw/lan-refresh-<ts>/
# Safe: read-only network operations, no packets sent except the single
# arp-scan ARP probe and the standard avahi/SSDP discovery the devices
# themselves already emit.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
cd "$ROOT"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/_tvguard_env.sh" || exit 4

OUT="reports/raw/lan-refresh-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
LAN="${1:-$LAN_SUBNET}"
RESOLVER="${2:-$UPSTREAM_ROUTER}"
IFACE="$LAN_INTERFACE"

echo "== arp-scan $LAN on $IFACE ==" | tee "$OUT/arp-scan.txt"
arp-scan --retry=1 -I "$IFACE" "$LAN" 2>/dev/null | tee "$OUT/arp-scan.txt" || true

# arp-scan data rows: "IP  MAC  Vendor  ..." - parse them directly (the
# human header line has the same shape only when -N is used, so match IPs).
: > "$OUT/arp-parsed.txt"
awk '$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && $2 ~ /^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/ {print $1, $2}' \
  "$OUT/arp-scan.txt" > "$OUT/arp-parsed.txt" || true

echo "== PTR lookups via $RESOLVER ==" | tee "$OUT/ptr.txt"
LAN_PREFIX="${LAN%%/*}"
while read -r ip mac; do
    [ -z "$ip" ] && continue
    ptr=$(dig +short -x "$ip" @"$RESOLVER" 2>/dev/null | head -1 | sed 's/\.$//')
    printf '%s %-17s %s\n' "$ip" "$mac" "${ptr:-none}" | tee -a "$OUT/ptr.txt"
done < "$OUT/arp-parsed.txt" || true

echo "== avahi (10 s, mDNS) ==" | tee "$OUT/avahi.txt"
timeout 10 avahi-browse -a -r 2>/dev/null | tee "$OUT/avahi.txt" || true

echo "== passive SSDP/UPnP capture (15 s) ==" | tee "$OUT/ssdp.txt"
tcpdump -i "$IFACE" -n -l 'udp port 1900' 2>/dev/null > "$OUT/ssdp-pcap.txt" &
TPID=$!
sleep 15
kill "$TPID" 2>/dev/null || true

echo
echo "Done. Raw output in $OUT"
echo "Review the device list, then fill TVS / SAMSUNG_TVS / LG_TVS / GOOGLE_TVS"
echo "in .env for every TV that will use this box as gateway/DNS."
