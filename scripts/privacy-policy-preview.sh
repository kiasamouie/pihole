#!/usr/bin/env bash
#
# privacy-policy-preview.sh - show what a tier WOULD block without applying.
#
#   scripts/privacy-policy-preview.sh            # use existing resolved.json
#   scripts/privacy-policy-preview.sh --resolve  # re-resolve first (slow, uses internet)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
RES="$ROOT/data/privacy-policy/resolved.json"

if [ "${1:-}" = "--resolve" ]; then
  python3 "$SCRIPT_DIR/privacy-policy-build.py"
fi
if [ ! -f "$RES" ]; then
  echo "no resolved.json yet - run with --resolve first" >&2; exit 4
fi
echo "### resolved $RES (generated $(python3 -c "import json;print(json.load(open('$RES'))['generated_at'])"))"
echo
cat "$ROOT/data/privacy-policy/preview.md"
