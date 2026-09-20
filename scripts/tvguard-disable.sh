#!/usr/bin/env bash
#
# tvguard-disable.sh  -  ONE-COMMAND emergency rollback.
#
#   sudo scripts/tvguard-disable.sh
#
# This removes ONLY the TVGuard footprint:
#   * deletes the nftables table `ip tvguard` (and nothing else)
#   * removes the per-TV `ufw route` rules we added (ufw-user-forward ONLY;
#     no other UFW rule, chain, Docker rule, or UFW state is touched)
#   * restores the sysctls we changed (from the captured baseline)
#   * removes our /etc/sysctl.d/99-tvguard.conf
#   * stops + disables the tvguard.service unit (if present)
# It does NOT flush anything, does NOT touch Pi-hole, Plex, Samba, or any
# other service. After this, reverting a TV to
# gateway=upstream / DNS=automatic restores its original network path.
#
# Deliberately uses `set -u` (not `-e`): a rollback must never abort early.
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

echo "Disabling TVGuard (only the tvguard footprint)..."

# 1. Remove ONLY our nft table.
if nft list table ip tvguard >/dev/null 2>&1; then
  nft delete table ip tvguard && echo "  - removed nft table ip tvguard"
else
  echo "  - nft table ip tvguard not present (nothing to remove)"
fi

# 1b. Remove ONLY our per-TV ufw route rules (added by tvguard-apply.sh).
#     These live in ufw-user-forward as `-s <tv> -j ACCEPT`. Only a rule whose
#     source is one of our configured TV IPs is deleted.
for tv in $TVS; do
  if iptables -t filter -S ufw-user-forward 2>/dev/null | grep -E -q -- "-s $tv(/32)? -j ACCEPT"; then
    if ufw route delete allow from "$tv" to any >/dev/null 2>&1; then
      echo "  - removed ufw route rule for $tv"
    else
      echo "  WARN: failed to remove ufw route rule for $tv - check manually:" >&2
      iptables -t filter -S ufw-user-forward 2>/dev/null | grep -F -- "-s $tv " >&2 || true
    fi
  fi
done

# 2. Restore baseline sysctls (captured at first apply).
if [ -f "$STATE_DIR/sysctl.baseline" ]; then
  while IFS='=' read -r k v; do
    [ -z "$k" ] && continue
    if sysctl -w "$k=$v" >/dev/null 2>&1; then echo "  - restored $k=$v"; fi
  done < "$STATE_DIR/sysctl.baseline"
  rm -f "$STATE_DIR/sysctl.baseline"
else
  # No baseline: safely restore send_redirects if we zeroed it; leave ip_forward alone.
  cur=$(sysctl -n net.ipv4.conf."$LAN_INTERFACE".send_redirects 2>/dev/null || echo 1)
  if [ "$cur" = "0" ]; then
    sysctl -w "net.ipv4.conf.$LAN_INTERFACE.send_redirects=1" >/dev/null 2>&1 && \
      echo "  - restored net.ipv4.conf.$LAN_INTERFACE.send_redirects=1"
  fi
fi

# 3. Remove our sysctl files.
rm -f /etc/sysctl.d/99-tvguard.conf "$STATE_DIR/sysctl.conf" 2>/dev/null
echo "  - removed our sysctl files"

# 4. Stop + disable the unit (if present).
if [ -f /etc/systemd/system/tvguard.service ]; then
  systemctl stop   tvguard.service >/dev/null 2>&1 || true
  systemctl disable tvguard.service >/dev/null 2>&1 || true
  echo "  - stopped/disabled tvguard.service"
fi

# 5. Clear the active marker + state so it does not re-apply at boot.
rm -f "$STATE_DIR/active" "$STATE_DIR/state" 2>/dev/null
echo "  - cleared TVGuard state"

echo
echo "Done. TVGuard is disabled. If you had pointed a TV at this box,"
echo "revert it to: gateway=<upstream, e.g. 192.168.0.1>, DNS=automatic."
