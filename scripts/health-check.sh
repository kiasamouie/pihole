#!/usr/bin/env bash
# health-check.sh - Verify TVGuard, Pi-hole, and their host prerequisites.
# Read-only and safe to run at any time.
#
# Usage: scripts/health-check.sh
set -uo pipefail
# sbin tools (nft, ufw, sysctl, conntrack) are needed on any
# PATH flavor this script may be invoked from (cron, agents, CI).
export PATH="/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
STATE_DIR=/var/lib/tvguard

# Machine config (TVGUARD_ENV > $ROOT/.env > legacy config/tvguard.conf).
# shellcheck source=/dev/null
. "$SCRIPT_DIR/_tvguard_env.sh" || exit 4

: "${MODE:=}" "${LAN_INTERFACE:=}" "${LAN_SUBNET:=}" "${GATEWAY_IP:=}"
: "${PIHOLE_IP:=}" "${UPSTREAM_ROUTER:=}" "${WAN_INTERFACE:=}" "${TVS:=}"

fail=0
say(){ printf "%-58s %s\n" "$1" "$2"; }
pass(){ say "$1" "OK${2:+ ($2)}"; }
fail_check(){ say "$1" "FAIL${2:+ ($2)}"; fail=1; }
# WARN = cannot be verified from this privilege level; not a failure
warn(){ say "$1" "WARN${2:+ ($2)}"; }

run_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo -n "$@"
    else
        "$@"
    fi
}

missing=""
for name in MODE LAN_INTERFACE LAN_SUBNET GATEWAY_IP PIHOLE_IP UPSTREAM_ROUTER TVS; do
    [ -n "${!name:-}" ] || missing="$missing${missing:+, }$name"
done
if [ "$MODE" = "dualnic-gateway" ] && [ -z "$WAN_INTERFACE" ]; then
    missing="$missing${missing:+, }WAN_INTERFACE"
fi
if [ -n "$missing" ]; then
    echo "ERROR: required values missing from $TVGUARD_ENV: $missing" >&2
    exit 4
fi
case "$MODE" in
    onearm-poc) EGRESS_IF="$LAN_INTERFACE" ;;
    dualnic-gateway) EGRESS_IF="$WAN_INTERFACE" ;;
    *) echo "ERROR: invalid MODE in $TVGUARD_ENV: $MODE" >&2; exit 4 ;;
esac

if command -v python3 >/dev/null 2>&1 && \
   CONFIG_LAN="$LAN_SUBNET" CONFIG_GW="$GATEWAY_IP" CONFIG_PH="$PIHOLE_IP" \
   CONFIG_UPSTREAM="$UPSTREAM_ROUTER" CONFIG_TVS="$TVS" python3 - <<'PY' >/dev/null 2>&1
import ipaddress
import os

lan = ipaddress.ip_network(os.environ["CONFIG_LAN"], strict=False)
for key in ("CONFIG_GW", "CONFIG_PH", "CONFIG_UPSTREAM"):
    ipaddress.ip_address(os.environ[key])
for value in os.environ["CONFIG_TVS"].split():
    ipaddress.ip_address(value)
if not os.environ["CONFIG_TVS"].split():
    raise ValueError("TVS is empty")
if ipaddress.ip_address(os.environ["CONFIG_GW"]) not in lan:
    raise ValueError("GATEWAY_IP is outside LAN_SUBNET")
if ipaddress.ip_address(os.environ["CONFIG_PH"]) not in lan:
    raise ValueError("PIHOLE_IP is outside LAN_SUBNET")
PY
then
    pass "machine config network values" "$LAN_SUBNET via $LAN_INTERFACE"
else
    fail_check "tvguard.conf network values" "invalid IPv4 address/subnet or empty TVS"
fi

echo "=== prerequisites ==="
for cmd in docker nft iptables ufw ip ss sysctl systemctl python3 dig curl conntrack; do
    if command -v "$cmd" >/dev/null 2>&1; then
        pass "$cmd"
    else
        fail_check "$cmd" "not installed"
    fi
done

if command -v ip >/dev/null 2>&1; then
    ip link show dev "$LAN_INTERFACE" >/dev/null 2>&1 \
        && pass "LAN interface $LAN_INTERFACE" \
        || fail_check "LAN interface $LAN_INTERFACE" "not found"
    if [ "$EGRESS_IF" != "$LAN_INTERFACE" ]; then
        ip link show dev "$EGRESS_IF" >/dev/null 2>&1 \
            && pass "egress interface $EGRESS_IF" \
            || fail_check "egress interface $EGRESS_IF" "not found"
    fi
    ip -4 -o addr show | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$GATEWAY_IP" \
        && pass "configured gateway address $GATEWAY_IP" "assigned on host" \
        || fail_check "configured gateway address $GATEWAY_IP" "not assigned on host"
    ip -4 -o addr show | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$PIHOLE_IP" \
        && pass "configured Pi-hole bind $PIHOLE_IP" "assigned on host" \
        || fail_check "configured Pi-hole bind $PIHOLE_IP" "not assigned on host"
    if ip -6 route show default 2>/dev/null | grep -q .; then
        fail_check "IPv6 default route" "present; privacy policy has an uncontrolled IPv6 path"
    else
        pass "IPv6 default route" "absent"
    fi
fi

echo
echo "=== Pi-hole ==="
if command -v docker >/dev/null 2>&1; then
    pihole_state=$(docker inspect -f '{{.State.Status}}' pihole 2>/dev/null || true)
    pihole_health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' pihole 2>/dev/null || true)
    if [ "$pihole_state" = "running" ] && { [ -z "$pihole_health" ] || [ "$pihole_health" = "healthy" ]; }; then
        pass "pihole container" "${pihole_health:-running}"
    else
        fail_check "pihole container" "state=${pihole_state:-missing}, health=${pihole_health:-n/a}"
    fi
fi
if command -v dig >/dev/null 2>&1; then
    dig +time=3 +tries=2 "@$PIHOLE_IP" example.com >/dev/null 2>&1 \
        && pass "dig @$PIHOLE_IP example.com" "NOERROR" \
        || fail_check "dig @$PIHOLE_IP example.com" "no DNS answer"
fi
if command -v curl >/dev/null 2>&1; then
    curl -fsS --max-time 5 -o /dev/null "http://$PIHOLE_IP:3001/admin/" \
        && pass "Pi-hole web/API bind" "http://$PIHOLE_IP:3001" \
        || fail_check "Pi-hole web/API bind" "http://$PIHOLE_IP:3001 unavailable"
fi

echo
echo "=== safety checks ==="
if command -v ss >/dev/null 2>&1 && ss -lun 2>/dev/null | awk '{print $5}' | grep -qE '(^|[^0-9])67$'; then
    fail_check "UDP :67 DHCP listener" "present; upstream router must remain the DHCP server"
else
    pass "UDP :67 DHCP listener" "absent"
fi

echo
echo "=== TVGuard ==="
active=0
table_present=0
table_unknown=0
[ -f "$STATE_DIR/active" ] && active=1
# Privileged probes (nft/iptables) need root or cached sudo credentials.
# Without either, the outcome is UNKNOWN: report WARN instead of treating
# "cannot read" as "absent" (false FAIL in non-interactive shells).
root_probe_ok=0
if [ "$(id -u)" -eq 0 ]; then
    root_probe_ok=1
elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    root_probe_ok=1
fi
if [ "$root_probe_ok" -eq 1 ] && command -v nft >/dev/null 2>&1; then
    run_root nft list table ip tvguard >/dev/null 2>&1 && table_present=1
else
    table_unknown=1
fi

if [ "$table_unknown" -eq 1 ]; then
    warn "tvguard active marker and nft table" "run with sudo to verify nft state"
elif [ "$active" -eq 1 ] && [ "$table_present" -eq 1 ]; then
    pass "tvguard active marker and nft table" "consistent"
elif [ "$active" -eq 0 ] && [ "$table_present" -eq 0 ]; then
    pass "tvguard active marker and nft table" "disabled consistently"
elif [ "$active" -eq 1 ]; then
    fail_check "tvguard active marker and nft table" "active marker set but table missing"
else
    fail_check "tvguard active marker and nft table" "table loaded without active marker"
fi

ufw_rules=""
ufw_unknown=0
if [ "$root_probe_ok" -eq 1 ] && command -v iptables >/dev/null 2>&1; then
    ufw_rules=$(run_root iptables -t filter -S ufw-user-forward 2>/dev/null || true)
else
    ufw_unknown=1
fi
for tv in $TVS; do
    tv_re=${tv//./\\.}
    if [ "$ufw_unknown" -eq 1 ]; then
        warn "UFW route allowance for $tv" "run with sudo to verify"
    elif printf '%s\n' "$ufw_rules" | grep -Eq -- "-s $tv_re(/32)? .* -j ACCEPT|-s $tv_re(/32)? -j ACCEPT"; then
        [ "$active" -eq 1 ] \
            && pass "UFW route allowance for $tv" \
            || fail_check "UFW route allowance for $tv" "stale rule while TVGuard is disabled"
    elif [ "$active" -eq 1 ]; then
        fail_check "UFW route allowance for $tv" "missing"
    else
        pass "UFW route allowance for $tv" "absent while disabled"
    fi
done

if [ "$active" -eq 1 ]; then
    [ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || true)" = "1" ] \
        && pass "net.ipv4.ip_forward" "1" \
        || fail_check "net.ipv4.ip_forward" "must be 1 while active"
    [ "$(sysctl -n "net.ipv4.conf.$LAN_INTERFACE.send_redirects" 2>/dev/null || true)" = "0" ] \
        && pass "net.ipv4.conf.$LAN_INTERFACE.send_redirects" "0" \
        || fail_check "net.ipv4.conf.$LAN_INTERFACE.send_redirects" "must be 0 while active"
fi

service_enabled=$(systemctl is-enabled tvguard.service 2>/dev/null || true)
service_active=$(systemctl is-active tvguard.service 2>/dev/null || true)
if [ "$service_enabled" = "enabled" ]; then
    [ "$service_active" = "active" ] \
        && pass "tvguard.service" "enabled and active" \
        || fail_check "tvguard.service" "enabled but ${service_active:-inactive}"
else
    say "tvguard.service" "${service_enabled:-not-installed} (${service_active:-inactive})"
fi

echo
echo "=== resources ==="
free -h 2>/dev/null | sed -n '2p' || true
df -h / 2>/dev/null | sed -n '1,2p' || true
[ -r /proc/loadavg ] && echo "loadavg: $(cut -d' ' -f1-3 /proc/loadavg)"

echo
if [ "$fail" -eq 0 ]; then
    echo "ALL CHECKS PASSED"
else
    echo "SOME CHECKS FAILED (see above)"
    exit 1
fi
