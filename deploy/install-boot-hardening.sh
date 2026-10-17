#!/usr/bin/env bash
# install-boot-hardening.sh - install the reboot-resilience layer (idempotent).
#
#   sudo deploy/install-boot-hardening.sh              install / update
#   sudo deploy/install-boot-hardening.sh --uninstall  roll back (restores backups)
#
# Installs (all host-level, nothing else touched):
#   /usr/local/libexec/tvguard/{wait-lan-address,docker-lan-heal,watchdog}  (copies)
#   /etc/systemd/system/docker.service.d/10-tvguard-lan-address.conf
#   /etc/systemd/system/tvguard-watchdog.{service,timer}  (timer enabled)
#   /etc/systemd/system/tvguard.service  (re-rendered from deploy/tvguard.service.in)
# then re-applies tvguard.service (only `table ip tvguard`, from the recorded
# mode/privacy state) when it is enabled. Docker is NOT restarted: the drop-in
# takes effect at the next boot / docker restart.
# Every replaced file is backed up to /var/backups/tvguard/<timestamp>/.
set -euo pipefail
export PATH="/usr/sbin:/usr/bin:/sbin:/bin"

[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/scripts/_tvguard_env.sh" || exit 4
: "${LAN_INTERFACE:?}" "${PIHOLE_BIND_IP:?}"

LIBEXEC=/usr/local/libexec/tvguard
UNITDIR=/etc/systemd/system
DROPIN_DIR=$UNITDIR/docker.service.d
DROPIN=$DROPIN_DIR/10-tvguard-lan-address.conf
BACKUP_ROOT=/var/backups/tvguard
MANAGED=("$LIBEXEC/wait-lan-address" "$LIBEXEC/docker-lan-heal" "$LIBEXEC/watchdog"
         "$DROPIN" "$UNITDIR/tvguard-watchdog.service" "$UNITDIR/tvguard-watchdog.timer"
         "$UNITDIR/tvguard.service")

if [ "${1:-}" = "--uninstall" ]; then
    latest=$(ls -1d "$BACKUP_ROOT"/*/ 2>/dev/null | sort | tail -1 || true)
    systemctl disable --now tvguard-watchdog.timer 2>/dev/null || true
    for f in "${MANAGED[@]}"; do
        if [ -n "$latest" ] && [ -e "$latest/files$f" ]; then cp -a "$latest/files$f" "$f"
        elif [ -n "$latest" ] && [ -e "$latest/absent$f" ]; then rm -f "$f"; fi
    done
    systemctl daemon-reload
    echo "rolled back from ${latest:-<no backup found>} (docker drop-in leaves effect at next docker restart/boot)"
    exit 0
fi

render() { sed -e "s|@LAN_INTERFACE@|$LAN_INTERFACE|g" -e "s|@PIHOLE_BIND_IP@|$PIHOLE_BIND_IP|g" "$1"; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
install -m 0755 "$ROOT/scripts/wait-lan-address.sh" "$TMP/wait-lan-address"
install -m 0755 "$ROOT/scripts/docker-lan-heal.sh"  "$TMP/docker-lan-heal"
install -m 0755 "$ROOT/scripts/tvguard-watchdog.sh" "$TMP/watchdog"
render "$ROOT/deploy/docker-lan-address.conf.in"   > "$TMP/dropin.conf"
render "$ROOT/deploy/tvguard-watchdog.service.in"  > "$TMP/tvguard-watchdog.service"
cp "$ROOT/deploy/tvguard-watchdog.timer" "$TMP/tvguard-watchdog.timer"
cp "$ROOT/deploy/tvguard.service.in"     "$TMP/tvguard.service"
for f in wait-lan-address docker-lan-heal watchdog; do bash -n "$TMP/$f"; done
systemd-analyze verify "$TMP/tvguard-watchdog.service" "$TMP/tvguard-watchdog.timer" "$TMP/tvguard.service" 2>&1 \
    | grep -v -E 'libexec/tvguard/(watchdog|apply|pihole-boot-ready).*(No such file|is not executable)' || true

STAMP=$(date +%Y%m%d-%H%M%S); BK="$BACKUP_ROOT/$STAMP"
for f in "${MANAGED[@]}"; do
    if [ -e "$f" ]; then install -d "$BK/files$(dirname "$f")"; cp -a "$f" "$BK/files$f"
    else install -d "$BK/absent$(dirname "$f")"; : > "$BK/absent$f"; fi
done
echo "backup: $BK"

install -d -m 0755 "$LIBEXEC" "$DROPIN_DIR"
install -m 0755 "$TMP/wait-lan-address" "$LIBEXEC/wait-lan-address"
install -m 0755 "$TMP/docker-lan-heal"  "$LIBEXEC/docker-lan-heal"
install -m 0755 "$TMP/watchdog"         "$LIBEXEC/watchdog"
install -m 0644 "$TMP/dropin.conf"      "$DROPIN"
install -m 0644 "$TMP/tvguard-watchdog.service" "$UNITDIR/tvguard-watchdog.service"
install -m 0644 "$TMP/tvguard-watchdog.timer"   "$UNITDIR/tvguard-watchdog.timer"
install -m 0644 "$TMP/tvguard.service"  "$UNITDIR/tvguard.service"
systemctl daemon-reload

systemctl show docker.service -p DropInPaths --value | grep -q 10-tvguard-lan-address \
    && echo "OK docker drop-in loaded" || { echo "FAIL docker drop-in not loaded" >&2; exit 1; }
systemctl enable --now tvguard-watchdog.timer >/dev/null
echo "OK tvguard-watchdog.timer enabled"

if [ -e /var/lib/tvguard/active ] && systemctl is-enabled --quiet tvguard.service; then
    if systemctl restart tvguard.service; then echo "OK tvguard.service re-applied"
    else echo "FAIL tvguard.service (journalctl -u tvguard.service -b)" >&2; exit 1; fi
fi
systemctl start tvguard-watchdog.service || true
journalctl -u tvguard-watchdog.service -n 5 --no-pager -o cat || true
echo "done. Rollback: sudo $ROOT/deploy/install-boot-hardening.sh --uninstall"
