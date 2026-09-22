#!/usr/bin/env bash
#
# privacy-proof-capture.sh - one-command privacy enforcement proof capture.
#
# Records the target TV (192.168.0.197) at ~1 Hz for 900 seconds:
#   0-180s   pre-baseline (TV idle or normal use)
#  180-780s  ACTIVE WINDOW - perform the TV activity now (e.g. the voice tests)
#  780-900s  post window
#
# Captures METADATA ONLY (flow/DNS/SNI-header level via voice-path-discovery.py):
# no application payload is captured, and nothing here claims encrypted bytes
# are audio or transcripts. It CAN truthfully report things like:
#   "after reconnect, the TV attempted N connections and X bytes to Y".
#
# Output: captures/voice-discovery/<label>-<ts>/  (metadata.json, timeline.csv,
# dns.csv, flows.csv, candidates.csv, summary.md)
#
# Usage:
#   sudo scripts/privacy-proof-capture.sh [label]      (default label: proof-<ts>)
#   sudo scripts/privacy-proof-capture.sh voice-test-1  # then use the remote to
#       ask the TV the cloud-dependent questions during the 180-780s window
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$(id -u)" -ne 0 ]; then echo "run with sudo" >&2; exit 3; fi

LABEL="${1:-proof-$(date -u +%Y%m%d-%H%M%S)}"
echo "privacy proof capture: label=$LABEL total=900s (pre 0-180 | ACTIVE 180-780 | post 780-900)"
echo "Perform the TV activity between t+180s and t+780s."
exec bash "$SCRIPT_DIR/voice-path-discovery.sh" "$LABEL" 900 180 780
