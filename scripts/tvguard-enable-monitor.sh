#!/usr/bin/env bash
#
# tvguard-enable-monitor.sh  -  enable TVGuard in MONITOR mode (logging only).
#
# MONITOR: TV Internet traffic that routes through us is recorded (new
# connections logged, counters kept) but nothing is deliberately blocked beyond
# the existing Pi-hole baseline. The DNS-bypass redirect and masquerade ARE
# active so we can SEE and CONTROL TV traffic. This is the safe first live mode.
# Idempotent.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="/var/lib/tvguard"

"$DIR/tvguard-apply.sh" monitor

# Mark active so the systemd unit re-applies this mode at boot.
mkdir -p "$STATE_DIR"; touch "$STATE_DIR/active"

# Enable reboot persistence if the unit is installed (bootstrap installs it).
if [ -f /etc/systemd/system/tvguard.service ]; then
  systemctl enable tvguard.service >/dev/null 2>&1 || true
  # Start (idempotent oneshot): guarantees the unit reflects the applied state.
  systemctl start tvguard.service >/dev/null 2>&1 || true
fi

echo
echo "TVGuard is now in MONITOR mode."
echo "  - Revert nothing else; the TV must be pointed at the gateway to be routed."
echo "  - Run scripts/tvguard-status.sh to inspect."
