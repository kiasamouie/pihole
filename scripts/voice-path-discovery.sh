#!/usr/bin/env bash
#
# voice-path-discovery.sh - record one high-resolution (~1 Hz) traffic capture
# of a target TV through this host. Thin wrapper over voice-path-discovery.py.
#
# Usage:
#   sudo scripts/voice-path-discovery.sh <label> <total> <active-start> <active-end> [tv-ip|vendor]
#     durations in seconds (e.g. 420 120 240)
#   Output: captures/voice-discovery/<label>-<ts>/
#
# Example (4 min total, active window = middle 2 min):
#   sudo scripts/voice-path-discovery.sh youtube 240 60 180
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"

if [ "$(id -u)" -ne 0 ]; then echo "run with sudo" >&2; exit 3; fi

LABEL="${1:-capture}"
TOTAL="${2:-300}"
A0="${3:-60}"
A1="${4:-240}"
resolve_vendor_tv() {
python3 - "$ROOT" "$1" <<'PY'
import sys, os, yaml
sys.path.insert(0, sys.argv[1] + "/scripts")
from tvguard_target_config import load_target_config
root, v = sys.argv[1], sys.argv[2]
inst = yaml.safe_load(open(root + "/config/privacy-instances.yaml"))["instances"]
tc = load_target_config(inst)
targets = tc.vendor_targets.get(v) or []
print(targets[0] if targets else "")
PY
}

# 5th arg: explicit TV IP, or a vendor name (samsung|lg) resolved via the
# registry + machine config (first target of that vendor). Empty = samsung.
TV="${5:-}"
case "$TV" in
  samsung|lg) TV=$(resolve_vendor_tv "$TV") ;;
  "") TV=$(resolve_vendor_tv samsung) ;;
esac
[ -n "$TV" ] || { echo "could not resolve the TV address (machine config has no target for this vendor)" >&2; exit 5; }

OUT="$ROOT/captures/voice-discovery/${LABEL}-$(date -u +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

echo "voice-path discovery: tv=$TV label=$LABEL total=${TOTAL}s active=${A0}-${A1}s"
PRIVACY_ROOT="$ROOT" python3 "$SCRIPT_DIR/voice-path-discovery.py" "$LABEL" "$TOTAL" "$A0" "$A1" "$OUT" "$TV"
