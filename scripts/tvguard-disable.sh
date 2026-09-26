#!/usr/bin/env bash
#
# tvguard-disable.sh - ONE-COMMAND emergency rollback.
#
#   sudo scripts/tvguard-disable.sh
#
# Removes only TVGuard's nftables table, configured per-TV UFW route rules,
# captured sysctl changes/files, service state, and runtime markers. It never
# flushes nftables, conntrack, UFW, or any unrelated service.
#
# Deliberately uses `set -u` (not `-e`): a rollback must not abort midway.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$DIR")"
STATE_DIR=/var/lib/tvguard

if [ "$(id -u)" -ne 0 ]; then echo "ERROR: run with sudo" >&2; exit 3; fi
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
if ! CONFIG_LAN="$LAN_SUBNET" CONFIG_GW="$GATEWAY_IP" CONFIG_UP="$UPSTREAM_ROUTER" CONFIG_TVS="$TVS" python3 - <<'PY' >/dev/null 2>&1
import ipaddress
import os
lan = ipaddress.ip_network(os.environ["CONFIG_LAN"], strict=False)
for key in ("CONFIG_GW", "CONFIG_UP"):
    ipaddress.ip_address(os.environ[key])
for value in os.environ["CONFIG_TVS"].split():
    if ipaddress.ip_address(value) not in lan:
        raise ValueError("TV outside LAN_SUBNET")
PY
then
  echo "ERROR: invalid IPv4 address/subnet in $TVGUARD_ENV" >&2
  exit 4
fi

echo "Disabling TVGuard (only the tvguard footprint)..."

# 1. Remove only the project-owned nftables table.
if nft list table ip tvguard >/dev/null 2>&1; then
  nft delete table ip tvguard && echo "  - removed nft table ip tvguard"
else
  echo "  - nft table ip tvguard not present (nothing to remove)"
fi

# 1b. Remove only route allowances whose source is a configured TV.
for tv in $TVS; do
  tv_re=${tv//./\\.}
  if iptables -t filter -S ufw-user-forward 2>/dev/null | grep -Eq -- "-s $tv_re(/32)? .* -j ACCEPT|-s $tv_re(/32)? -j ACCEPT"; then
    if ufw route delete allow from "$tv" to any >/dev/null 2>&1; then
      echo "  - removed ufw route rule for $tv"
    else
      echo "  WARN: failed to remove ufw route rule for $tv - check manually:" >&2
      iptables -t filter -S ufw-user-forward 2>/dev/null | grep -F -- "-s $tv " >&2 || true
    fi
  fi
done

# 2. Restore the baseline captured by tvguard-apply.sh.
if [ -f "$STATE_DIR/sysctl.baseline" ]; then
  while IFS='=' read -r k v; do
    [ -z "$k" ] && continue
    if sysctl -w "$k=$v" >/dev/null 2>&1; then echo "  - restored $k=$v"; fi
  done < "$STATE_DIR/sysctl.baseline"
  rm -f "$STATE_DIR/sysctl.baseline"
else
  # Without a baseline, restore only the interface redirect setting TVGuard owns.
  cur=$(sysctl -n "net.ipv4.conf.$LAN_INTERFACE.send_redirects" 2>/dev/null || echo 1)
  if [ "$cur" = "0" ]; then
    sysctl -w "net.ipv4.conf.$LAN_INTERFACE.send_redirects=1" >/dev/null 2>&1 && \
      echo "  - restored net.ipv4.conf.$LAN_INTERFACE.send_redirects=1"
  fi
fi

# 3. Remove only TVGuard's sysctl files.
rm -f /etc/sysctl.d/99-tvguard.conf "$STATE_DIR/sysctl.conf" 2>/dev/null
echo "  - removed TVGuard sysctl files"

# 4. Stop and disable only the project unit.
if [ -f /etc/systemd/system/tvguard.service ]; then
  systemctl stop tvguard.service >/dev/null 2>&1 || true
  systemctl disable tvguard.service >/dev/null 2>&1 || true
  echo "  - stopped/disabled tvguard.service"
fi

# 5. Clear runtime markers so boot cannot re-apply the base gateway.
rm -f "$STATE_DIR/active" "$STATE_DIR/state" 2>/dev/null
echo "  - cleared TVGuard state"

echo
echo "Done. TVGuard is disabled. For any TV that used this box, set"
echo "gateway=$UPSTREAM_ROUTER and DNS=automatic to restore its direct path."
