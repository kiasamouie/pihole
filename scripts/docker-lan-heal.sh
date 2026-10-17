#!/usr/bin/env bash
# docker-lan-heal.sh - repair containers that Docker left without a network
# after a boot-time host-port bind failure.
#
# Failure mode (reproduced on Docker 29.4.1, 2026-10-17): if the daemon
# restores a container whose ports are published on a specific host address
# (e.g. 192.168.0.128:53) before DHCP has assigned that address, the start
# fails with "cannot assign requested address" AND Docker drops the
# container's network attachment. Every later `docker start`/`restart` then
# yields a RUNNING container with NetworkSettings.Networks == {} and no
# published ports, while its internal healthcheck still reports "healthy".
# It never recovers on its own; only re-connecting the network does.
#
# This script repairs exactly that state and nothing else:
#   * restart policy is always/unless-stopped (an intended-up container)
#   * HostConfig.NetworkMode is a user-defined network that exists
#   * NetworkSettings.Networks is empty
#   * the container is running, or stopped with a port-bind/networking error
# It reconnects the network (with the Compose service alias), then starts the
# container. Containers stopped on purpose (no error) are left alone.
#
# Usage: docker-lan-heal.sh [--check]   (--check: report only, exit 1 if broken)
# Idempotent; safe to run any time. Requires docker access (root or docker group).
set -uo pipefail
export PATH="/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

CHECK_ONLY=0
case "${1:-}" in
    "") ;;
    --check) CHECK_ONLY=1 ;;
    *) echo "Usage: $0 [--check]" >&2; exit 2 ;;
esac

log() { echo "docker-lan-heal: $*"; }

broken=0
healed=0
failed=0

while IFS='|' read -r name status restart mode service err; do
    [ -n "$name" ] || continue
    case "$restart" in always|unless-stopped) ;; *) continue ;; esac
    case "$mode" in ""|default|bridge|host|none|container:*) continue ;; esac
    nets=$(docker inspect -f '{{len .NetworkSettings.Networks}}' "$name" 2>/dev/null || echo 1)
    [ "$nets" = "0" ] || continue
    if [ "$status" != "running" ]; then
        case "$err" in
            *"cannot assign requested address"*|*"failed to set up container networking"*|*"programming external connectivity"*) ;;
            *) continue ;;
        esac
    fi
    broken=$((broken + 1))
    log "DETACHED: $name (status=$status, network=$mode${err:+, last error: $err})"
    [ "$CHECK_ONLY" -eq 1 ] && continue

    if ! docker network inspect "$mode" >/dev/null 2>&1; then
        log "FAIL: $name: network $mode does not exist; recreate it with its compose project"
        failed=$((failed + 1)); continue
    fi
    if [ "$status" = "running" ]; then
        docker stop -t 10 "$name" >/dev/null || { log "FAIL: could not stop $name"; failed=$((failed + 1)); continue; }
    fi
    alias_args=()
    [ -n "$service" ] && alias_args=(--alias "$service")
    if ! out=$(docker network connect "${alias_args[@]}" "$mode" "$name" 2>&1); then
        log "FAIL: $name: network connect: $out"; failed=$((failed + 1)); continue
    fi
    if ! out=$(docker start "$name" 2>&1); then
        log "FAIL: $name: start: $out"; failed=$((failed + 1)); continue
    fi
    nets=$(docker inspect -f '{{len .NetworkSettings.Networks}}' "$name" 2>/dev/null || echo 0)
    if [ "$nets" = "0" ]; then
        log "FAIL: $name started but is still detached"; failed=$((failed + 1)); continue
    fi
    log "HEALED: $name -> $mode ($(docker inspect -f '{{json .NetworkSettings.Ports}}' "$name"))"
    healed=$((healed + 1))
done < <(docker ps -aq | xargs -r docker inspect -f '{{.Name}}|{{.State.Status}}|{{.HostConfig.RestartPolicy.Name}}|{{.HostConfig.NetworkMode}}|{{index .Config.Labels "com.docker.compose.service"}}|{{.State.Error}}' | sed 's|^/||')

if [ "$CHECK_ONLY" -eq 1 ]; then
    [ "$broken" -eq 0 ] && { log "OK: no detached containers"; exit 0; }
    exit 1
fi
log "summary: detached=$broken healed=$healed failed=$failed"
[ "$failed" -eq 0 ]
