#!/usr/bin/env bash
#
# tv-session.sh  -  record one labelled TV activity session.
#
# Usage:
#   sudo scripts/tv-session.sh <tv> <label> <duration>
#     <tv>       samsung | google | <ip-address>
#     <label>    e.g. idle, homescreen, youtube, plex, cast, voice, standby
#     <duration> e.g. 10m, 5m, 1h, 30s, 1h5m
#
# Example (do the TV action by hand during the window):
#   sudo scripts/tv-session.sh samsung idle 10m
#   sudo scripts/tv-session.sh samsung youtube 10m
#   sudo scripts/tv-session.sh samsung voice 5m
#
# Output: captures/<YYYYmmdd-HHMMSS>-<tv>-<label>/
#   metadata.json    session parameters + TVGuard mode + nft counter deltas
#   events.log       raw timestamped conntrack events (NEW/UPDATE/DESTROY)
#   connections.csv  one row per flow: dst, port, proto, timing, bytes
#   dns.csv          Pi-hole query log for the window (domain, status, ...)
#   summary.md       human-readable digest (unique dsts, top talkers, DNS)
#
# Scope: flow/DNS metadata only. No application payload is captured.
# The TV must already be routed through this box (gateway/DNS = our IP),
# otherwise only the TV's local-LAN flows are visible.
set -uo pipefail

if [ "$(id -u)" -ne 0 ]; then echo "run with sudo"; exit 3; fi

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$DIR")"
# shellcheck source=/dev/null
. "$DIR/_tvguard_env.sh" || exit 4

[ $# -eq 3 ] || { echo "usage: tv-session.sh <tv|ip> <label> <duration>" >&2; exit 2; }
TV_NAME="$1"; LABEL="$2"; DUR="$3"

# --- resolve TV name -> IP ----------------------------------------------------
# First address of the vendor list from the machine config (legacy single-IP
# keys honoured as fallback).
first_of(){ echo "$1" | awk 'NR==1'; }
case "$TV_NAME" in
  samsung)  TV_IP=$(first_of "${SAMSUNG_TVS:-${SAMSUNG_IP:-}}") ;;
  lg)       TV_IP=$(first_of "${LG_TVS:-${LG_IP:-}}") ;;
  google)   TV_IP=$(first_of "${GOOGLE_TVS:-${GOOGLE_TV_IP:-}}") ;;
  *)        TV_IP="$TV_NAME" ;;
esac
[[ "$TV_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo "unknown tv: $TV_NAME" >&2; exit 2; }

# --- parse duration (e.g. 10m, 1h5m, 30s) -------------------------------------
SECONDS_TOTAL=0
if [[ "$DUR" =~ ^([0-9]+)h(([0-9]+)m)?(([0-9]+)s)?$ ]]; then
  SECONDS_TOTAL=$(( 10#${BASH_REMATCH[1]}*3600 + 10#${BASH_REMATCH[3]:-0}*60 + 10#${BASH_REMATCH[5]:-0} ))
elif [[ "$DUR" =~ ^([0-9]+)m(([0-9]+)s)?$ ]]; then
  SECONDS_TOTAL=$(( 10#${BASH_REMATCH[1]}*60 + 10#${BASH_REMATCH[3]:-0} ))
elif [[ "$DUR" =~ ^([0-9]+)s$ ]]; then
  SECONDS_TOTAL=$(( 10#${BASH_REMATCH[1]} ))
else
  echo "bad duration: $DUR (use e.g. 10m, 1h, 30s)" >&2; exit 2
fi
[ "$SECONDS_TOTAL" -ge 10 ] || { echo "duration must be >= 10s" >&2; exit 2; }

STAMP="$(date -u +%Y%m%d-%H%M%S)"
OUT="$ROOT/captures/${STAMP}-${TV_NAME}-${LABEL}"
mkdir -p "$OUT"
echo "Recording: $TV_NAME ($TV_IP) label='$LABEL' for ${SECONDS_TOTAL}s -> $OUT"
echo "  Now perform the TV action. Press nothing; the session ends automatically."

# --- nft counter snapshot (start) ----------------------------------------------
nft_counters() {
  # Deterministic rule IDs: "<chain>.<n>" where n is the 1-based position of
  # the counter-bearing rule inside that chain (nftables prints rules in
  # table order, which tvguard-apply.sh renders in a fixed order).
  # The OLD version named every unlabelled rule '<rule>' and sorted lines
  # lexicographically, so when counter values re-ordered between snapshots the
  # per-session delta silently mixed two DIFFERENT rules (e.g. the casting
  # session's "1.4GB" was the reply-to-TV counter, not the TV's outbound).
  nft list table ip tvguard 2>/dev/null | awk '
    /chain / { for (i=1;i<=NF;i++) if ($i == "chain") { ch = $(i+1); n = 0 } next }
    /counter/ {
      n++
      pk = ""; by = ""; pre = ""
      for (i=1;i<=NF;i++) {
        if ($i == "packets") pk = $(i+1)
        if ($i == "bytes") by = $(i+1)
        if ($i == "prefix") { for (j=i+1;j<=NF;j++) if ($j ~ /^"/) { pre = $j; break } }
      }
      gsub(/"/, "", pre)
      if (pk != "" && by != "") printf "%s %s %s.%d%s\n", pk, by, ch, n, (pre != "" ? " " pre : "")
    }'
}
nft_counters > "$OUT/nft-counters-start.txt"

T_START="$(date -u +%s)"

# --- conntrack event capture (the session window) ------------------------------
echo "  capturing conntrack events for ${SECONDS_TOTAL}s ..."
timeout "$SECONDS_TOTAL" conntrack -E 2>/dev/null | while IFS= read -r line; do
  printf '%s %s\n' "$(date -u +%s)" "$line" >> "$OUT/events.log"
done

T_END="$(date -u +%s)"
nft_counters > "$OUT/nft-counters-end.txt"
echo "  window: $T_START -> $T_END (UTC epoch)"

# --- DNS via Pi-hole API --------------------------------------------------------
PH_IP="${PIHOLE_IP:-$GATEWAY_IP}"
PH_PORT=3001
if [ -f "$ROOT/.env" ]; then
  PW=$(grep '^ADMIN_PASSWORD=' "$ROOT/.env" | cut -d= -f2)
  SID=$(curl -sk -m 10 -X POST "http://$PH_IP:$PH_PORT/api/auth" -H "Content-Type: application/json" \
        -d "{\"password\":\"$PW\"}" 2>/dev/null \
        | python3 -c 'import sys,json; print(json.load(sys.stdin)["session"]["sid"])' 2>/dev/null || true)
  if [ -n "${SID:-}" ]; then
    # fetch-pihole-queries.py handles v6 API pagination correctly (the API
    # ignores `page=` and caps responses at 100 rows; it slices by time).
    if ! python3 "$DIR/fetch-pihole-queries.py" --sid "$SID" "$PH_IP" "$PH_PORT" "$TV_IP" "$T_START" "$T_END" "$OUT/pihole-queries.json"; then
      echo "  WARN: Pi-hole query fetch failed; dns.csv will be empty" >&2
      echo "[]" > "$OUT/pihole-queries.json"
    fi
  else
    echo "  WARN: Pi-hole API auth failed; dns.csv will be empty" >&2
    echo "[]" > "$OUT/pihole-queries.json"
  fi
else
  echo "  WARN: no .env found; dns.csv will be empty" >&2
  echo "[]" > "$OUT/pihole-queries.json"
fi

# --- build the session report files --------------------------------------------
python3 "$DIR/session_analyze.py" "$OUT" "$TV_NAME" "$TV_IP" "$LABEL" "$SECONDS_TOTAL" "$T_START" "$T_END" \
  "$(grep '^MODE=' /var/lib/tvguard/state 2>/dev/null | cut -d= -f2)" || echo "  WARN: session_analyze.py failed" >&2

echo
echo "Session saved to: $OUT"
ls -1 "$OUT" | sed 's/^/  /'
