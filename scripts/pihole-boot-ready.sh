#!/usr/bin/env bash
# Validate and start the persisted Pi-hole instance before TVGuard loads rules.
# TVGuard must never install DNS-routing rules until the configured LAN endpoint
# has been proven end to end.
set -euo pipefail
export PATH="/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
EXPECTED_MOUNT="$(readlink -f "$ROOT/etc-pihole")"
PIHOLE_NETWORK=tvguard_default
ALLOW_INITIALIZE=0

case "${1:-}" in
    "") ;;
    --allow-initialize) ALLOW_INITIALIZE=1 ;;
    *) echo "Usage: $0 [--allow-initialize]" >&2; exit 2 ;;
esac

# Machine config (TVGUARD_ENV > $ROOT/.env > legacy config/tvguard.conf).
# shellcheck source=/dev/null
. "$SCRIPT_DIR/_tvguard_env.sh" || exit 4
: "${LAN_INTERFACE:=}" "${PIHOLE_IP:=}" "${PIHOLE_BIND_IP:=}"
if [ -z "$LAN_INTERFACE" ] || [ -z "$PIHOLE_IP" ] || [ -z "$PIHOLE_BIND_IP" ]; then
    echo "ERROR: LAN_INTERFACE, PIHOLE_IP and PIHOLE_BIND_IP are required in $TVGUARD_ENV" >&2
    exit 4
fi
if [ "$PIHOLE_BIND_IP" != "$PIHOLE_IP" ]; then
    echo "ERROR: PIHOLE_BIND_IP must equal PIHOLE_IP" >&2
    exit 4
fi

if ! docker inspect pihole >/dev/null 2>&1; then
    echo "ERROR: Pi-hole container is missing; run sudo $ROOT/bootstrap.sh" >&2
    exit 1
fi

ACTUAL_PROJECT="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' pihole 2>/dev/null || true)"
if [ "$ACTUAL_PROJECT" != "tvguard" ]; then
    echo "ERROR: Pi-hole belongs to Compose project '${ACTUAL_PROJECT:-unknown}', not 'tvguard'" >&2
    echo "Run sudo $ROOT/bootstrap.sh to reconcile the deployment." >&2
    exit 1
fi

ACTUAL_MOUNT="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/etc/pihole"}}{{.Source}}{{end}}{{end}}' pihole 2>/dev/null || true)"
ACTUAL_MOUNT_CANON="$(readlink -f "$ACTUAL_MOUNT" 2>/dev/null || true)"
if [ -z "$ACTUAL_MOUNT_CANON" ] || [ "$ACTUAL_MOUNT_CANON" != "$EXPECTED_MOUNT" ]; then
    echo "ERROR: Pi-hole has a stale /etc/pihole bind mount" >&2
    echo "  expected: $EXPECTED_MOUNT" >&2
    echo "  actual:   ${ACTUAL_MOUNT:-<missing>}" >&2
    echo "If this exact clone moved, run sudo $ROOT/bootstrap.sh --migrate-repository-path." >&2
    exit 1
fi

if [ "$ALLOW_INITIALIZE" -eq 0 ] && [ ! -r "$EXPECTED_MOUNT/gravity.db" ]; then
    echo "ERROR: persisted Pi-hole database is missing or unreadable: $EXPECTED_MOUNT/gravity.db" >&2
    exit 1
fi

# Docker cannot publish a port on a host address that DHCP has not installed.
# network-online.target is not sufficient on every ifupdown/dhcpcd system, so
# retain this bounded check as a second line of defence. One deadline covers
# both the host address and the complete Pi-hole endpoint proof.
READINESS_TIMEOUT=120
READINESS_DEADLINE=$((SECONDS + READINESS_TIMEOUT))
HOST_ADDRESS_READY=0
while (( SECONDS < READINESS_DEADLINE )); do
    if ip -4 -o address show dev "$LAN_INTERFACE" 2>/dev/null \
       | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$PIHOLE_BIND_IP"; then
        HOST_ADDRESS_READY=1
        break
    fi
    sleep 1
done
if [ "$HOST_ADDRESS_READY" -ne 1 ]; then
    echo "ERROR: $PIHOLE_BIND_IP was not assigned to $LAN_INTERFACE before the ${READINESS_TIMEOUT}-second readiness deadline" >&2
    echo "TVGuard rules were not applied; check DHCP and network-online ordering." >&2
    exit 1
fi

# If dockerd restored Pi-hole before the address existed, Docker 29 leaves it
# without a network (running or not); `docker start` alone never repairs that.
"$SCRIPT_DIR/docker-lan-heal.sh" || true
if ! START_OUTPUT="$(docker start pihole 2>&1)"; then
    echo "ERROR: Docker could not start Pi-hole after $PIHOLE_BIND_IP became available" >&2
    printf '%s\n' "$START_OUTPUT" >&2
    exit 1
fi

STATE=""
HEALTH=""
CONTAINER_IP=""
TCP_BIND=""
UDP_BIND=""
UDP_ANSWER=""
TCP_ANSWER=""
while (( SECONDS < READINESS_DEADLINE )); do
    STATE="$(docker inspect -f '{{.State.Status}}' pihole 2>/dev/null || true)"
    HEALTH="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' pihole 2>/dev/null || true)"
    CONTAINER_IP="$(docker inspect -f '{{with index .NetworkSettings.Networks "tvguard_default"}}{{.IPAddress}}{{end}}' pihole 2>/dev/null || true)"
    TCP_BIND="$(docker inspect -f '{{with index .NetworkSettings.Ports "53/tcp"}}{{range .}}{{println .HostIp .HostPort}}{{end}}{{end}}' pihole 2>/dev/null || true)"
    UDP_BIND="$(docker inspect -f '{{with index .NetworkSettings.Ports "53/udp"}}{{range .}}{{println .HostIp .HostPort}}{{end}}{{end}}' pihole 2>/dev/null || true)"
    UDP_ANSWER=""
    TCP_ANSWER=""
    if [ "$STATE" = "running" ] && [ -z "$CONTAINER_IP" ]; then
        "$SCRIPT_DIR/docker-lan-heal.sh" || true
    fi

    if [ "$STATE" = "running" ] \
       && { [ -z "$HEALTH" ] || [ "$HEALTH" = "healthy" ]; } \
       && [ -r "$EXPECTED_MOUNT/gravity.db" ] \
       && docker exec pihole test -r /etc/pihole/gravity.db \
       && [ -n "$CONTAINER_IP" ] \
       && [ "$TCP_BIND" = "$PIHOLE_BIND_IP 53" ] \
       && [ "$UDP_BIND" = "$PIHOLE_BIND_IP 53" ]; then
        UDP_ANSWER="$(dig +time=2 +tries=1 +short "@$PIHOLE_BIND_IP" pi.hole A 2>/dev/null | sed -n '1p' || true)"
        TCP_ANSWER="$(dig +tcp +time=2 +tries=1 +short "@$PIHOLE_BIND_IP" pi.hole A 2>/dev/null | sed -n '1p' || true)"
        if [ "$UDP_ANSWER" = "$CONTAINER_IP" ] && [ "$TCP_ANSWER" = "$CONTAINER_IP" ]; then
            echo "Pi-hole ready: ${HEALTH:-running}, $PIHOLE_BIND_IP:53 -> $PIHOLE_NETWORK/$CONTAINER_IP, persisted database mounted from $EXPECTED_MOUNT"
            exit 0
        fi
    fi
    sleep 2
done

cat >&2 <<EOF
ERROR: Pi-hole did not become reachable through its configured LAN DNS endpoint before the ${READINESS_TIMEOUT}-second readiness deadline
  state/health:       ${STATE:-missing}/${HEALTH:-n/a}
  network/IP:         $PIHOLE_NETWORK/${CONTAINER_IP:-missing}
  expected TCP bind:  $PIHOLE_BIND_IP 53
  actual TCP bind:    ${TCP_BIND:-missing}
  expected UDP bind:  $PIHOLE_BIND_IP 53
  actual UDP bind:    ${UDP_BIND:-missing}
  UDP pi.hole answer: ${UDP_ANSWER:-missing}
  TCP pi.hole answer: ${TCP_ANSWER:-missing}
TVGuard rules were not applied. Run sudo $ROOT/bootstrap.sh to reconcile Pi-hole.
EOF
docker logs --tail 20 pihole >&2 || true
exit 1
