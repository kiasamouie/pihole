#!/usr/bin/env bash
#
# voice-proof-capture.sh - ONE-command proof capture for the final voice-block
# verification.
#
# Timeline (7 minutes total, ~1 Hz resolution):
#   T+0   .. T+120   PRE    - get to the TV, remote in hand, home screen
#   T+120 .. T+240   ACTIVE - perform the voice questions NOW (see below)
#   T+240 .. T+420   POST   - leave the TV alone; background telemetry window
#
# It records: DNS queries, new flows, BYTE DELTAS on pre-existing flows
# (a voice request riding an already-open connection is still visible),
# and TVGuard counters (blocked attempts). Metadata only, no payload.
#
# Usage:
#   sudo scripts/voice-proof-capture.sh [label]     # default label: voice-proof
#
# During the ACTIVE window ask, in order (wait ~15-20 s between each):
#   1. "What is the weather in Tokyo right now?"     (decline location if asked)
#   2. "What is the weather in Sydney right now?"
#   3. "What is the current price of Bitcoin?"
# Note the TV time when each question was made - it goes in the report.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"

if [ "$(id -u)" -ne 0 ]; then echo "run with sudo" >&2; exit 3; fi

LABEL="${1:-voice-proof}"
TV="192.168.0.197"
if [ -f "$ROOT/config/privacy-policy.yaml" ]; then
  TV=$(python3 -c '
import sys, yaml
with open(sys.argv[1]) as policy:
    doc = yaml.safe_load(policy)
print((doc.get("applies_to") or ["192.168.0.197"])[0])
' "$ROOT/config/privacy-policy.yaml")
fi

echo "====================================================================="
echo " VOICE-PROOF CAPTURE  (tv=$TV, label=$LABEL)"
echo " 120s PRE | 120s ACTIVE | 180s POST   (7 minutes total)"
echo " When 'ACTIVE' starts: press the mic and ask, in order:"
echo "   1. What is the weather in Tokyo right now?"
echo "   2. What is the weather in Sydney right now?"
echo "   3. What is the current price of Bitcoin?"
echo " (decline location prompts; note the TV time of each question)"
echo "====================================================================="

TOTAL=420; A0=120; A1=240
# countdown
for t in 3 2 1; do echo "  starting in $t..."; sleep 1; done

OUT="$ROOT/captures/voice-discovery/${LABEL}-$(date -u +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
PRIVACY_ROOT="$ROOT" python3 "$SCRIPT_DIR/voice-path-discovery.py" "$LABEL" "$TOTAL" "$A0" "$A1" "$OUT" "$TV"

echo
echo "Capture complete: $OUT"
echo "Review:  $OUT/summary.md  $OUT/candidates.csv  $OUT/timeline.csv"
echo "Then run: sudo scripts/privacy-live-check.sh   (server-side state)"
echo "Blocked attempts: sudo scripts/tvguard-status.sh | grep -E 'PRIVACY|DOT'  and  journalctl -S '-10 min' | grep -E 'TVGUARD-PRIVACY|TVGUARD-DOT'"
