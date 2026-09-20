#!/usr/bin/env bash
#
# tvguard-status.sh  -  read-only status of the TVGuard ruleset. Safe anytime.
#
#   sudo scripts/tvguard-status.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$DIR")"

LAN_INTERFACE="enp2s0"; STATE_DIR="/var/lib/tvguard"
if [ -f "$ROOT/config/tvguard.conf" ]; then
  # shellcheck source=/dev/null
  . "$ROOT/config/tvguard.conf"
fi
LAN_INTERFACE="${LAN_INTERFACE:-enp2s0}"
STATE_DIR="${STATE_DIR:-/var/lib/tvguard}"

echo "=== TVGuard status (read-only) ==="
echo "Repo:            $ROOT"

if [ -f "$STATE_DIR/state" ]; then
  echo; echo "State file: $STATE_DIR"
  sed 's/^/  /' "$STATE_DIR/state"
else
  echo "  (no state file - TVGuard not currently applied)"
fi

echo; echo "=== nft table ip tvguard ==="
if nft list table ip tvguard >/dev/null 2>&1; then
  nft list table ip tvguard | sed 's/^/  /'
else
  echo "  (not loaded)"
fi

echo; echo "=== counters (TVGUARD) ==="
nft list table ip tvguard 2>/dev/null | grep -E 'counter' | sed 's/^ *//' | awk '{
  for(i=1;i<=NF;i++){ if($i=="packets")p=$(i+1); if($i=="bytes")b=$(i+1) }
  line=$0; sub(/^.*prefix[ \"]+\"?/,"",line); sub(/[ \"]+counter.*$/,"",line); sub(/^[ ]+/,"",line)
  printf "  %-14s %s  pkts=%s bytes=%s\n", (line==""?"<accept>":line), "", p, b
}' 2>/dev/null || echo "  (no counters yet)"

echo; echo "=== ufw route rules (per-TV forward allowance) ==="
UFW_RULES=$(iptables -t filter -S ufw-user-forward 2>/dev/null | grep -F "-j ACCEPT" | sed 's/^ *//')
if [ -n "$UFW_RULES" ]; then echo "$UFW_RULES" | sed 's/^/  /'; else echo "  (none)"; fi

echo; echo "=== relevant sysctls ==="
for k in net.ipv4.ip_forward "net.ipv4.conf.$LAN_INTERFACE.send_redirects" "net.ipv4.conf.$LAN_INTERFACE.rp_filter"; do
  printf "  %-50s %s\n" "$k" "$(sysctl -n "$k" 2>/dev/null || echo n/a)"
done

echo; echo "=== TV-facing services still up? (quick) ==="
echo "  pihole:  $(docker inspect -f '{{.State.Status}}' pihole 2>/dev/null || echo n/a)"
echo "  (run scripts/health-check.sh for the full check)"
