#!/usr/bin/env bash
# Validate and start the persisted Pi-hole instance before TVGuard loads rules.
# This prevents a stale repository path from silently mounting an empty database.
set -euo pipefail
export PATH="/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
EXPECTED_MOUNT="$(readlink -f "$ROOT/etc-pihole")"
ALLOW_INITIALIZE=0

case "${1:-}" in
    "") ;;
    --allow-initialize) ALLOW_INITIALIZE=1 ;;
    *) echo "Usage: $0 [--allow-initialize]" >&2; exit 2 ;;
esac

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

ACTUAL_MOUNT="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/etc/pihole"}}{{.Source}}{{end}}{{end}}' pihole 2>/dev/null)"
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

docker start pihole >/dev/null
for _ in $(seq 1 30); do
    STATE="$(docker inspect -f '{{.State.Status}}' pihole 2>/dev/null || true)"
    HEALTH="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' pihole 2>/dev/null || true)"
    if [ "$STATE" = "running" ] && { [ -z "$HEALTH" ] || [ "$HEALTH" = "healthy" ]; } \
       && [ -r "$EXPECTED_MOUNT/gravity.db" ] \
       && docker exec pihole test -r /etc/pihole/gravity.db; then
        echo "Pi-hole ready: ${HEALTH:-running}, persisted database mounted from $EXPECTED_MOUNT"
        exit 0
    fi
    sleep 2
done

echo "ERROR: Pi-hole did not become healthy with a readable gravity.db within 60 seconds" >&2
docker logs --tail 20 pihole >&2 || true
exit 1
