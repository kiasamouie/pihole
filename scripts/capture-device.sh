#!/usr/bin/env bash
# capture-device.sh - Passive per-device packet capture on the LAN interface.
#
# Usage: sudo scripts/capture-device.sh <IP> [seconds] [output.pcap]
#   e.g. sudo scripts/capture-device.sh <TV_IP> 300 data/cap-tv.pcap
#
# Captures all traffic to/from one IP. snaplen 192 bytes: enough for DNS
# question/answer, TLS SNI, QUIC connection-id, TCP/UDP 5-tuple - not full
# payloads (privacy). The pcap stays local with 0600 permissions.
#
# IMPORTANT (switched-LAN limitation): on the current network this only
# captures traffic that actually reaches this NIC - i.e. broadcast/multicast
# (SSDP, mDNS, NTP, SmartThings beacon) and anything addressed to this server.
# TV->Internet unicast will NOT appear until the TV uses this server for DNS
# (then DNS is visible) or this box becomes the gateway (then everything is).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/_tvguard_env.sh" 2>/dev/null || true

IP="${1:?usage: capture-device.sh <IP> [seconds] [output.pcap]}"
SECS="${2:-60}"
OUT="${3:-data/cap-$IP-$SECS.pcap}"
IFACE="${IFACE:-${LAN_INTERFACE:-}}"
[ -n "$IFACE" ] || { echo "IFACE not set (no LAN_INTERFACE in machine config)" >&2; exit 4; }

mkdir -p "$(dirname "$OUT")"
chmod 600 "$OUT" 2>/dev/null || true

echo "Capturing traffic for $IP on $IFACE for $SECS s -> $OUT (snaplen 192, header-focused)"
sudo tcpdump -i "$IFACE" -s 192 -nn "host $IP" -w "$OUT" &
TPID=$!
sleep "$SECS"
kill "$TPID" 2>/dev/null || true
wait "$TPID" 2>/dev/null || true

chmod 600 "$OUT"
echo "Saved: $OUT ($(du -h "$OUT" | cut -f1))"
echo "Inspect metadata with: tshark -r $OUT  (no -x, keep payloads out of the terminal)"
