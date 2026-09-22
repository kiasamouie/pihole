#!/usr/bin/env bash
#
# privacy-reset-tv-manufacturer-state.sh - expire Samsung egress state that
# survives a privacy-policy change, in a safe, narrow, per-TV way.
#
# Manufacturer-wide generalisation of privacy-reset-tv-voice-state.sh.
# The privacy deny rules match NEW connections only (ct state new). A TV that
# (a) cached DNS answers or (b) holds already-established TLS connections to
# a destination that is now denied keeps that connection alive until it ends.
# This script deletes conntrack entries between ONE TV and the resolved IPs of
# a policy section (default: manufacturer-lockdown) in BOTH directions.
#
# Safety (same guarantees as the voice script):
#   * affects only the one TV IP given (default: first applies_to entry)
#   * never touches other clients' flows
#   * never flushes the global conntrack table
#   * never touches UFW, Docker, Pi-hole, TVGuard mode or the nftables rules
#
# Usage:
#   sudo scripts/privacy-reset-tv-manufacturer-state.sh
#       (Samsung .197 + manufacturer-lockdown IP set)
#   sudo scripts/privacy-reset-tv-manufacturer-state.sh 192.168.0.90
#   sudo scripts/privacy-reset-tv-manufacturer-state.sh 192.168.0.197 strict
#       (any resolved.json section: standard|standard-no-voice|voice|strict|
#        manufacturer-lockdown; default manufacturer-lockdown, falling back to
#        standard-no-voice if the section is absent)
#   add --flush-dns-cache to also flush the Pi-hole DNS cache first
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"

if [ "$(id -u)" -ne 0 ]; then echo "run with sudo" >&2; exit 3; fi
command -v conntrack >/dev/null || { echo "conntrack tool not found" >&2; exit 4; }
[ -f "$ROOT/data/privacy-policy/resolved.json" ] || { echo "no data/privacy-policy/resolved.json - run privacy-policy-build.py first" >&2; exit 5; }

FLUSH_DNS=0
TV=""
SECTION=""
for a in "$@"; do
  case "$a" in
    --flush-dns-cache) FLUSH_DNS=1 ;;
    -*) echo "unknown flag: $a" >&2; exit 4 ;;
    *) if [ -z "$TV" ]; then TV="$a"; else SECTION="$a"; fi ;;
  esac
done

if [ -z "$TV" ]; then
  TV=$(python3 -c '
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1] + "/config/privacy-policy.yaml"))
print((doc.get("applies_to") or ["192.168.0.197"])[0])
' "$ROOT")
fi
if [ -z "$SECTION" ]; then
  SECTION=$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1] + "/data/privacy-policy/resolved.json"))
print("manufacturer-lockdown" if "manufacturer-lockdown" in d else "standard-no-voice")
' "$ROOT")
fi
echo "target TV: $TV | section: $SECTION"

if [ "$FLUSH_DNS" = "1" ]; then
  echo "== flushing Pi-hole DNS cache (docker exec pihole 'pihole -f') =="
  docker exec pihole pihole -f 2>/dev/null && echo "  cache flushed" || echo "  WARN: could not flush Pi-hole cache (docker/pihole CLI)"
fi

IPS=$(python3 -c '
import sys, json
d = json.load(open(sys.argv[1] + "/data/privacy-policy/resolved.json"))
print(" ".join(sorted(set(d.get(sys.argv[2], {}).get("ips", [])))))
' "$ROOT" "$SECTION")

if [ -z "${IPS// /}" ]; then
  echo "no resolved IPs for section $SECTION - nothing to reset" >&2
  exit 5
fi

echo "== deleting conntrack entries: $TV <-> section IPs (both directions) =="
TOTAL=0
for ip in $IPS; do
  N1=$(conntrack -L -s "$TV" -d "$ip" 2>/dev/null | wc -l)
  N2=$(conntrack -L -s "$ip" -d "$TV" 2>/dev/null | wc -l)
  conntrack -D -s "$TV" -d "$ip" 2>/dev/null || true
  conntrack -D -s "$ip" -d "$TV" 2>/dev/null || true
  if [ "$N1" -gt 0 ] || [ "$N2" -gt 0 ]; then
    echo "  $ip: deleted $N1 (tv->ip) / $N2 (ip->tv) flows"
    TOTAL=$((TOTAL + N1 + N2))
  fi
done

LEFT=$(conntrack -L 2>/dev/null | grep -cF " $TV " || true)
echo
echo "done: deleted $TOTAL flows for $TV (section $SECTION). Remaining $TV flows (all other destinations): $LEFT"
echo "The TV now needs fresh DNS + fresh connections; new connections to denied"
echo "destinations are dropped and logged. Verify: sudo scripts/privacy-live-check.sh"
