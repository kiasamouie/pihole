#!/usr/bin/env bash
# tvguard-watchdog.sh - periodic (systemd timer) regression guard, run as root.
#
#   1. docker-lan-heal: re-attach any intended-up container that Docker left
#      without a network after a LAN-address bind failure (all projects).
#   2. Pi-hole must answer DNS through the LAN endpoint (UDP and TCP); if not,
#      restart the container once per run.
#   3. If TVGuard is enabled (/var/lib/tvguard/active + unit enabled), the
#      service must be active, `table ip tvguard` must exist, and every DNS
#      DNAT target must equal Pi-hole's current tvguard_default IP. Otherwise
#      re-apply via `systemctl restart tvguard.service` (idempotent: re-renders
#      the recorded mode and privacy state; never flushes other tables).
#
# Each run prints one OK line or explicit FAIL/REPAIR lines (journalctl -u
# tvguard-watchdog). Exits non-zero only if something is still broken after
# repair, so `systemctl --failed` surfaces it.
set -uo pipefail
export PATH="/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

HELPER_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
HEAL="$HELPER_DIR/docker-lan-heal"
[ -x "$HEAL" ] || HEAL="$HELPER_DIR/docker-lan-heal.sh"
LAN_IP="${TVGUARD_LAN_IP:?TVGUARD_LAN_IP not set}"
STATE_DIR="${TVGUARD_STATE_DIR:-/var/lib/tvguard}"

problems=0
actions=()

log() { echo "tvguard-watchdog: $*"; }

lan_dns_ok() {
    local cip u t
    cip=$(docker inspect -f '{{with index .NetworkSettings.Networks "tvguard_default"}}{{.IPAddress}}{{end}}' pihole 2>/dev/null)
    [ -n "$cip" ] || return 1
    u=$(dig +time=2 +tries=1 +short "@$LAN_IP" pi.hole A 2>/dev/null | sed -n 1p)
    t=$(dig +tcp +time=2 +tries=1 +short "@$LAN_IP" pi.hole A 2>/dev/null | sed -n 1p)
    [ "$u" = "$cip" ] && [ "$t" = "$cip" ]
}

# 1. detached containers
if ! "$HEAL" --check >/dev/null 2>&1; then
    log "REPAIR: detached container(s) found"
    "$HEAL" || problems=$((problems + 1))
    actions+=("healed")
fi

# 2. Pi-hole LAN DNS
if docker inspect pihole >/dev/null 2>&1; then
    if ! lan_dns_ok; then
        sleep 5
        if ! lan_dns_ok; then
            log "REPAIR: Pi-hole not answering DNS on $LAN_IP:53 (udp+tcp); restarting container"
            docker restart -t 10 pihole >/dev/null 2>&1
            actions+=("pihole-restart")
            for _ in $(seq 1 30); do lan_dns_ok && break; sleep 2; done
            if lan_dns_ok; then log "Pi-hole DNS restored"; else log "FAIL: Pi-hole DNS still down on $LAN_IP:53"; problems=$((problems + 1)); fi
        fi
    fi
fi

# 3. TVGuard
if [ -e "$STATE_DIR/active" ] && systemctl is-enabled --quiet tvguard.service 2>/dev/null; then
    reason=""
    cip=$(docker inspect -f '{{with index .NetworkSettings.Networks "tvguard_default"}}{{.IPAddress}}{{end}}' pihole 2>/dev/null)
    if ! systemctl is-active --quiet tvguard.service; then
        reason="tvguard.service is $(systemctl is-active tvguard.service 2>/dev/null)"
    elif ! nft list table ip tvguard >/dev/null 2>&1; then
        reason="table ip tvguard missing"
    elif [ -n "$cip" ]; then
        stale=$(nft list table ip tvguard 2>/dev/null | grep -oE 'dport 53 dnat (ip )?to [0-9.]+' | awk '{print $NF}' | sort -u | grep -vFx "$cip" || true)
        [ -n "$stale" ] && reason="DNS DNAT targets stale Pi-hole IP $(echo $stale) (current $cip)"
    fi
    if [ -n "$reason" ]; then
        log "REPAIR: $reason; re-applying tvguard.service"
        actions+=("tvguard-reapply")
        if systemctl restart tvguard.service; then
            log "tvguard.service re-applied"
        else
            log "FAIL: tvguard.service re-apply failed (journalctl -u tvguard.service)"
            problems=$((problems + 1))
        fi
    fi
fi

if [ "$problems" -eq 0 ]; then
    log "OK${actions[*]:+ (actions: ${actions[*]})}"
    exit 0
fi
log "FAIL: $problems unresolved problem(s); see lines above. Recovery: docs/BOOT_RESILIENCE.md"
exit 1
