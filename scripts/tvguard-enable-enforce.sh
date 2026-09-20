#!/usr/bin/env bash
#
# tvguard-enable-enforce.sh  -  enable TVGuard in ENFORCE mode.
#
# ENFORCE: everything in MONITOR, plus the tested privacy controls for the
# selected TVs:
#   - block TV -> direct DoT (tcp/853)
#   - block TV -> any destination in config/destinations.yaml with class: blocked
# The DNS-bypass redirect (external :53 -> local Pi-hole) remains active in both
# modes. ONLY destinations explicitly marked `blocked` in destinations.yaml are
# dropped. Transition is explicit and reversible (run tvguard-disable.sh or
# tvguard-enable-monitor.sh).
#
# Run this only AFTER you have evidence from the monitor phase.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="/var/lib/tvguard"

"$DIR/tvguard-apply.sh" enforce

mkdir -p "$STATE_DIR"; touch "$STATE_DIR/active"

if [ -f /etc/systemd/system/tvguard.service ]; then
  systemctl enable tvguard.service >/dev/null 2>&1 || true
  # Start (idempotent oneshot): guarantees the unit reflects the applied state.
  systemctl start tvguard.service >/dev/null 2>&1 || true
fi

echo
echo "TVGuard is now in ENFORCE mode."
echo "  Review: scripts/gen-policies.sh  (what is currently blocked and why)"
echo "  Revert: scripts/tvguard-enable-monitor.sh  (or tvguard-disable.sh)"
