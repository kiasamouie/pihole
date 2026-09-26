#!/usr/bin/env bash
#
# tvguard-status.sh - read-only status of the TVGuard ruleset.
#
#   sudo scripts/tvguard-status.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$DIR")"
STATE_DIR=/var/lib/tvguard

# Machine config (TVGUARD_ENV > $ROOT/.env > legacy config/tvguard.conf).
# shellcheck source=/dev/null
. "$DIR/_tvguard_env.sh" || exit 4

missing=""
for name in MODE LAN_INTERFACE LAN_SUBNET GATEWAY_IP UPSTREAM_ROUTER TVS; do
  [ -n "${!name:-}" ] || missing="$missing${missing:+, }$name"
done
if [ "$MODE" = "dualnic-gateway" ] && [ -z "${WAN_INTERFACE:-}" ]; then
  missing="$missing${missing:+, }WAN_INTERFACE"
fi
[ -z "$missing" ] || { echo "ERROR: required values missing from $TVGUARD_ENV: $missing" >&2; exit 4; }
case "$MODE" in
  onearm-poc|dualnic-gateway) : ;;
  *) echo "ERROR: invalid MODE in $TVGUARD_ENV: $MODE" >&2; exit 4 ;;
esac

if ! CONFIG_LAN="$LAN_SUBNET" CONFIG_GW="$GATEWAY_IP" CONFIG_TVS="$TVS" python3 - <<'PY' >/dev/null 2>&1
import ipaddress
import os
lan = ipaddress.ip_network(os.environ["CONFIG_LAN"], strict=False)
for value in (os.environ["CONFIG_GW"], *os.environ["CONFIG_TVS"].split()):
    if ipaddress.ip_address(value) not in lan:
        raise ValueError("address outside LAN_SUBNET")
PY
then
  echo "ERROR: invalid IPv4 address/subnet in $TVGUARD_ENV" >&2
  exit 4
fi

echo "=== TVGuard status (read-only) ==="
echo "Repo:            $ROOT"
echo "Config:          ${TVGUARD_ENV:-$ROOT/.env}"
echo "LAN:             $LAN_SUBNET via $LAN_INTERFACE"
echo "Gateway/Pi-hole: $GATEWAY_IP / $PIHOLE_IP"
echo "Configured TVs:  $TVS"

if [ -f "$STATE_DIR/state" ]; then
  echo; echo "State file: $STATE_DIR/state"
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
  p=""; b=""
  for(i=1;i<=NF;i++){ if($i=="packets")p=$(i+1); if($i=="bytes")b=$(i+1) }
  line=$0; sub(/^.*prefix[ \"]+\"?/,"",line); sub(/[ \"]+counter.*$/,"",line); sub(/^[ ]+/,"",line)
  printf "  %-14s %s  pkts=%s bytes=%s\n", (line==""?"<accept>":line), "", p, b
}' 2>/dev/null || echo "  (no counters yet)"

echo; echo "=== configured per-TV UFW route allowances ==="
UFW_RULES=$(iptables -t filter -S ufw-user-forward 2>/dev/null || true)
for tv in $TVS; do
  tv_re=${tv//./\\.}
  if printf '%s\n' "$UFW_RULES" | grep -Eq -- "-s $tv_re(/32)? .* -j ACCEPT|-s $tv_re(/32)? -j ACCEPT"; then
    echo "  $tv: present"
  else
    echo "  $tv: absent"
  fi
done

echo; echo "=== relevant sysctls ==="
for k in net.ipv4.ip_forward "net.ipv4.conf.$LAN_INTERFACE.send_redirects" "net.ipv4.conf.$LAN_INTERFACE.rp_filter"; do
  printf "  %-50s %s\n" "$k" "$(sysctl -n "$k" 2>/dev/null || echo n/a)"
done

echo; echo "=== configured services ==="
echo "  pihole container: $(docker inspect -f '{{.State.Status}}{{if .State.Health}} ({{.State.Health.Status}}){{end}}' pihole 2>/dev/null || echo n/a)"
echo "  Pi-hole bind:    http://$PIHOLE_IP:3001"
echo "  tvguard.service: $(systemctl is-enabled tvguard.service 2>/dev/null || echo not-installed) / $(systemctl is-active tvguard.service 2>/dev/null || echo inactive)"
echo "  (run scripts/health-check.sh for full prerequisite and consistency checks)"
