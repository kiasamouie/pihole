#!/usr/bin/env bash
#
# voice-path-discovery.sh - record one high-resolution (~1 Hz) traffic capture
# of a target TV through this host. Thin wrapper over voice-path-discovery.py.
#
# Usage:
#   sudo scripts/voice-path-discovery.sh <label> <total> <active-start> <active-end> [tv-ip]
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
TV="${5:-192.168.0.197}"
# default: first applies_to entry
if [ -z "${5:-}" ] && [ -f "$ROOT/config/privacy-policy.yaml" ]; then
  TV=$(python3 -c '
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1] + "/config/privacy-policy.yaml"))
print((doc.get("applies_to") or ["192.168.0.197"])[0])
' "$ROOT")
fi

OUT="$ROOT/captures/voice-discovery/${LABEL}-$(date -u +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

echo "voice-path discovery: tv=$TV label=$LABEL total=${TOTAL}s active=${A0}-${A1}s"
PRIVACY_ROOT="$ROOT" python3 "$SCRIPT_DIR/voice-path-discovery.py" "$LABEL" "$TOTAL" "$A0" "$A1" "$OUT" "$TV"
