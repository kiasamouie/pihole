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
: "${PIHOLE_IP:=}" "${PIHOLE_BIND_IP:=}" "${UPSTREAM_ROUTER:=}" "${WAN_INTERFACE:=}" "${TVS:=}"

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
for name in MODE LAN_INTERFACE LAN_SUBNET GATEWAY_IP PIHOLE_IP PIHOLE_BIND_IP UPSTREAM_ROUTER TVS; do
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
   CONFIG_BIND="$PIHOLE_BIND_IP" CONFIG_UPSTREAM="$UPSTREAM_ROUTER" \
   CONFIG_TVS="$TVS" python3 - <<'PY' >/dev/null 2>&1
import ipaddress
import os

lan = ipaddress.ip_network(os.environ["CONFIG_LAN"], strict=False)
values = {}
for key in ("CONFIG_GW", "CONFIG_PH", "CONFIG_BIND", "CONFIG_UPSTREAM"):
    values[key] = ipaddress.IPv4Address(os.environ[key])
for value in os.environ["CONFIG_TVS"].split():
    ipaddress.IPv4Address(value)
if not os.environ["CONFIG_TVS"].split():
    raise ValueError("TVS is empty")
if values["CONFIG_GW"] not in lan:
    raise ValueError("GATEWAY_IP is outside LAN_SUBNET")
if values["CONFIG_PH"] not in lan:
    raise ValueError("PIHOLE_IP is outside LAN_SUBNET")
if values["CONFIG_BIND"] != values["CONFIG_PH"]:
    raise ValueError("PIHOLE_BIND_IP must equal PIHOLE_IP")
if values["CONFIG_BIND"] in (lan.network_address, lan.broadcast_address):
    raise ValueError("PIHOLE_BIND_IP is not a usable LAN host address")
if values["CONFIG_BIND"].is_unspecified or values["CONFIG_BIND"].is_loopback \
        or values["CONFIG_BIND"].is_link_local or values["CONFIG_BIND"].is_multicast:
    raise ValueError("PIHOLE_BIND_IP is not a concrete LAN address")
PY
then
    pass "machine config network values" "$LAN_SUBNET via $LAN_INTERFACE"
else
    fail_check "machine config network values" "invalid IPv4 address/subnet or empty TVS"
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
    ip -4 -o addr show dev "$LAN_INTERFACE" | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$PIHOLE_BIND_IP" \
        && pass "configured Pi-hole bind $PIHOLE_BIND_IP" "assigned on $LAN_INTERFACE" \
        || fail_check "configured Pi-hole bind $PIHOLE_BIND_IP" "not assigned on $LAN_INTERFACE"
    if ip -6 route show default 2>/dev/null | grep -q .; then
        fail_check "IPv6 default route" "present; privacy policy has an uncontrolled IPv6 path"
    else
        pass "IPv6 default route" "absent"
    fi
fi

echo
echo "=== Pi-hole ==="
pihole_network_ip=""
if command -v docker >/dev/null 2>&1; then
    pihole_state=$(docker inspect -f '{{.State.Status}}' pihole 2>/dev/null || true)
    pihole_health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' pihole 2>/dev/null || true)
    if [ "$pihole_state" = "running" ] && { [ -z "$pihole_health" ] || [ "$pihole_health" = "healthy" ]; }; then
        pass "pihole container" "${pihole_health:-running}"
    else
        fail_check "pihole container" "state=${pihole_state:-missing}, health=${pihole_health:-n/a}"
    fi

    pihole_project=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' pihole 2>/dev/null || true)
    [ "$pihole_project" = "tvguard" ] \
        && pass "Pi-hole Compose project" "tvguard (path-independent)" \
        || fail_check "Pi-hole Compose project" "${pihole_project:-missing}; rerun sudo ./bootstrap.sh"
    pihole_restart=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' pihole 2>/dev/null || true)
    case "$pihole_restart" in
        always|unless-stopped) pass "Pi-hole restart policy" "$pihole_restart" ;;
        *) fail_check "Pi-hole restart policy" "${pihole_restart:-missing}" ;;
    esac

    pihole_network_ip=$(docker inspect -f '{{with index .NetworkSettings.Networks "tvguard_default"}}{{.IPAddress}}{{end}}' pihole 2>/dev/null || true)
    if [ -n "$pihole_network_ip" ]; then
        pass "Pi-hole tvguard_default attachment" "$pihole_network_ip"
    else
        fail_check "Pi-hole tvguard_default attachment" "missing network or container IP"
    fi

    if docker inspect pihole 2>/dev/null | EXPECTED_BIND="$PIHOLE_BIND_IP" python3 -c '
import json, os, sys
container = json.load(sys.stdin)[0]
bind = os.environ["EXPECTED_BIND"]
actual = {
    port: {(row.get("HostIp", ""), row.get("HostPort", "")) for row in (rows or [])}
    for port, rows in (container.get("HostConfig", {}).get("PortBindings") or {}).items()
}
expected = {
    "53/tcp": {(bind, "53")},
    "53/udp": {(bind, "53")},
    "80/tcp": {(bind, "3001"), ("127.0.0.1", "3001")},
    "443/tcp": {(bind, "3443")},
}
if actual != expected:
    raise SystemExit(1)
' >/dev/null 2>&1; then
        pass "Pi-hole published-port binds" "$PIHOLE_BIND_IP (LAN) + admin loopback"
    else
        fail_check "Pi-hole published-port binds" "unexpected or wildcard bind"
    fi

    if docker inspect pihole 2>/dev/null | EXPECTED_BIND="$PIHOLE_BIND_IP" python3 -c '
import json, os, sys
container = json.load(sys.stdin)[0]
bind = os.environ["EXPECTED_BIND"]
ports = container.get("NetworkSettings", {}).get("Ports") or {}
actual = {
    port: {(row.get("HostIp", ""), row.get("HostPort", "")) for row in (ports.get(port) or [])}
    for port in ("53/tcp", "53/udp")
}
expected = {
    "53/tcp": {(bind, "53")},
    "53/udp": {(bind, "53")},
}
if actual != expected:
    raise SystemExit(1)
' >/dev/null 2>&1; then
        pass "Pi-hole runtime DNS publishes" "$PIHOLE_BIND_IP:53 tcp+udp"
    else
        fail_check "Pi-hole runtime DNS publishes" "missing or wrong-address TCP/UDP endpoint"
    fi

    expected_pihole_mount=$(readlink -f "$ROOT/etc-pihole")
    pihole_mount=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/etc/pihole"}}{{.Source}}{{end}}{{end}}' pihole 2>/dev/null || true)
    pihole_mount_canon=$(readlink -f "$pihole_mount" 2>/dev/null || true)
    if [ -n "$pihole_mount_canon" ] && [ "$pihole_mount_canon" = "$expected_pihole_mount" ]; then
        pass "Pi-hole persisted-data mount" "$expected_pihole_mount"
    else
        fail_check "Pi-hole persisted-data mount" "expected $expected_pihole_mount, got ${pihole_mount:-missing}"
    fi

    if docker exec pihole test -r /etc/pihole/gravity.db 2>/dev/null; then
        pass "Pi-hole gravity database" "mounted and readable"
    else
        fail_check "Pi-hole gravity database" "missing/unreadable inside container"
    fi
fi
if PIHOLE_DB="$ROOT/etc-pihole/gravity.db" python3 - <<'PYEOF' >/dev/null 2>&1
import os, sqlite3
path = os.environ["PIHOLE_DB"]
con = sqlite3.connect("file:%s?mode=ro" % path, uri=True)
result = con.execute("PRAGMA quick_check").fetchone()[0]
con.close()
if result != "ok":
    raise SystemExit(result)
PYEOF
then
    pass "Pi-hole gravity database integrity" "ok"
else
    fail_check "Pi-hole gravity database integrity" "quick_check failed"
fi
if command -v dig >/dev/null 2>&1; then
    udp_answer=$(dig +time=2 +tries=1 +short "@$PIHOLE_BIND_IP" pi.hole A 2>/dev/null | sed -n '1p' || true)
    tcp_answer=$(dig +tcp +time=2 +tries=1 +short "@$PIHOLE_BIND_IP" pi.hole A 2>/dev/null | sed -n '1p' || true)
    if [ -n "$pihole_network_ip" ] \
       && [ "$udp_answer" = "$pihole_network_ip" ] \
       && [ "$tcp_answer" = "$pihole_network_ip" ]; then
        pass "Pi-hole LAN DNS path (UDP + TCP)" "pi.hole -> $pihole_network_ip"
    else
        fail_check "Pi-hole LAN DNS path (UDP + TCP)" "udp=${udp_answer:-none}, tcp=${tcp_answer:-none}, expected=${pihole_network_ip:-none}"
    fi

    external_dns=$(dig +time=3 +tries=2 "@$PIHOLE_BIND_IP" example.com 2>/dev/null || true)
    if printf '%s\n' "$external_dns" | grep -q 'status: NOERROR'; then
        pass "dig @$PIHOLE_BIND_IP example.com" "NOERROR"
    else
        fail_check "dig @$PIHOLE_BIND_IP example.com" "no NOERROR response"
    fi
fi
if command -v curl >/dev/null 2>&1; then
    curl -fsS --max-time 5 -o /dev/null "http://$PIHOLE_BIND_IP:3001/admin/" \
        && pass "Pi-hole web/API bind" "http://$PIHOLE_BIND_IP:3001" \
        || fail_check "Pi-hole web/API bind" "http://$PIHOLE_BIND_IP:3001 unavailable"
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

service_load=$(systemctl show tvguard.service --property=LoadState --value 2>/dev/null || true)
service_enabled=$(systemctl is-enabled tvguard.service 2>/dev/null || true)
service_active=$(systemctl is-active tvguard.service 2>/dev/null || true)
if [ "$service_load" != "loaded" ]; then
    fail_check "tvguard.service" "not installed or not loadable"
elif [ "$active" -eq 1 ]; then
    if [ "$service_enabled" = "enabled" ] && [ "$service_active" = "active" ]; then
        pass "tvguard.service" "enabled and active"
    else
        fail_check "tvguard.service" "TVGuard is active but service is ${service_enabled:-unknown}/${service_active:-unknown}"
    fi
elif [ "$service_active" = "active" ]; then
    fail_check "tvguard.service" "active without TVGuard active marker"
elif [ "$service_active" = "failed" ]; then
    fail_check "tvguard.service" "failed while TVGuard is disabled"
else
    pass "tvguard.service" "installed; TVGuard disabled (${service_enabled:-unknown}/${service_active:-inactive})"
fi

if [ "$service_load" = "loaded" ]; then
    unit_text=$(systemctl cat tvguard.service 2>/dev/null || true)
    unit_start_pre=$(systemctl show tvguard.service --property=ExecStartPre --value 2>/dev/null || true)
    unit_start=$(systemctl show tvguard.service --property=ExecStart --value 2>/dev/null || true)
    boot_ready_target=$(readlink -f /usr/local/libexec/tvguard/pihole-boot-ready 2>/dev/null || true)
    apply_target=$(readlink -f /usr/local/libexec/tvguard/apply 2>/dev/null || true)
    if printf '%s\n' "$unit_start_pre" | grep -Fq "path=/usr/local/libexec/tvguard/pihole-boot-ready ;" \
       && printf '%s\n' "$unit_start" | grep -Fq "path=/usr/local/libexec/tvguard/apply ;" \
       && [ "$boot_ready_target" = "$ROOT/scripts/pihole-boot-ready.sh" ] \
       && [ "$apply_target" = "$ROOT/scripts/tvguard-apply.sh" ] \
       && printf '%s\n' "$unit_text" | grep -Fqx "ConditionPathExists=/var/lib/tvguard/active"; then
        pass "tvguard.service runtime paths" "$ROOT via fixed launchers"
    else
        fail_check "tvguard.service runtime paths" "stale/missing; rerun sudo ./bootstrap.sh"
    fi
fi

echo
echo "=== boot resilience ==="
if command -v docker >/dev/null 2>&1; then
    if detached=$("$SCRIPT_DIR/docker-lan-heal.sh" --check 2>&1); then
        pass "no detached restart-policy containers" "all attached"
    else
        fail_check "no detached restart-policy containers" "$(printf '%s' "$detached" | grep -o 'DETACHED: [^ ]*' | paste -sd' ') - run scripts/docker-lan-heal.sh"
    fi
fi
if command -v systemctl >/dev/null 2>&1; then
    if systemctl show docker.service -p DropInPaths --value 2>/dev/null | grep -q 10-tvguard-lan-address \
       && [ -x /usr/local/libexec/tvguard/wait-lan-address ]; then
        pass "docker waits for LAN address" "10-tvguard-lan-address.conf"
    else
        fail_check "docker waits for LAN address" "missing; run sudo deploy/install-boot-hardening.sh"
    fi
    if systemctl is-enabled --quiet tvguard-watchdog.timer 2>/dev/null \
       && systemctl is-active --quiet tvguard-watchdog.timer; then
        wd_result=$(systemctl show tvguard-watchdog.service -p Result --value 2>/dev/null)
        if [ "$wd_result" = "success" ]; then
            pass "tvguard-watchdog.timer" "enabled, last run success"
        else
            fail_check "tvguard-watchdog.timer" "last run: ${wd_result:-unknown} (journalctl -u tvguard-watchdog)"
        fi
    else
        fail_check "tvguard-watchdog.timer" "not enabled; run sudo deploy/install-boot-hardening.sh"
    fi
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
