#!/usr/bin/env bash
#
# privacy-watch.sh - safety watch after enabling privacy policies (per vendor).
#
#   sudo scripts/privacy-watch.sh [minutes] [--auto-rollback]
#
# Works with every profile and every vendor (samsung + lg simultaneously).
#
# Samples every 60s:
#   * Pi-hole: queries seen, blocked count, health
#   * each active vendor's TV(s): active conntrack entries (NAT path alive?)
#   * nftables: TVGUARD-NEW / TVGUARD-PRIVACY-<VENDOR> / TVGUARD-DOT-<VENDOR>
#     counters (summed across active vendors)
#   * host: SSH/Plex/Samba/Transmission/Docker listeners
#   * manufacturer-lockdown vendors: periodic unknown-egress digest
#
# It NEVER auto-allowlists anything - it reports candidates for review.
# With --auto-rollback it disables ONLY the privacy layer of the vendor whose
# TV path clearly died (or whose Pi-hole/host health collapsed) - one command
# per vendor (privacy-policy-disable.sh <vendor>). It never touches UFW,
# Docker, TVGuard monitor state, the other vendor's policy, or other devices.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
STATE_DIR=/var/lib/tvguard
# Machine config (TVGUARD_ENV > $ROOT/.env > legacy config/tvguard.conf).
# shellcheck source=/dev/null
. "$SCRIPT_DIR/_tvguard_env.sh" || exit 4
DUR="${1:-30}"
AUTO=""
[ "${2:-}" = "--auto-rollback" ] && AUTO=1

# active vendor state (vendor<TAB>tier lines)
STATE_ROWS=$(STATE_FILE="$STATE_DIR/privacy-state" python3 - <<'PYEOF' 2>/dev/null
import os
states = {}
p = os.environ["STATE_FILE"]
if os.path.exists(p):
    for line in open(p):
        s = line.strip()
        if not s or s.startswith("#"): continue
        k, _, v = s.partition("=")
        k, v = k.strip(), v.strip()
        if k == "PRIVACY":
            states.setdefault("samsung", v)
        elif k.startswith("PRIVACY-"):
            states[k[len("PRIVACY-"):].strip().lower()] = v
tiers = ("standard", "standard-no-voice", "strict", "manufacturer-lockdown")
for v, t in sorted(states.items()):
    if t in tiers:
        print("\t".join([v, t]))
PYEOF
)
ACTIVE_VENDORS=$(awk '{print $1}' <<< "$STATE_ROWS")
echo "privacy-watch: ${DUR} min | active vendors: ${ACTIVE_VENDORS:-none} | auto-rollback: ${AUTO:-no}"
echo "start: $(date -u +%H:%M:%S) UTC"

# per-vendor TV IPs (applies_to from resolved.json)
declare -A TV_IPS
declare -A DEAD_STREAK
declare -A TV_MLOCK
for v in $ACTIVE_VENDORS; do
  DEAD_STREAK[$v]=0
  TV_MLOCK[$v]=$(STATE_ROWS="$STATE_ROWS" python3 -c '
import os, sys
rows = [l.split("\t") for l in os.environ["STATE_ROWS"].splitlines() if l.strip()]
tier = next((t for v, t in rows if v == sys.argv[1]), "off")
print("1" if tier == "manufacturer-lockdown" else "0")' "$v")
  TV_IPS[$v]=$(V="$v" RES="$ROOT/data/privacy-policy/resolved.json" python3 -c '
import json, os, sys
try:
    d = json.load(open(os.environ["RES"]))
    print(" ".join((d.get("vendors") or {}).get(os.environ["V"], {}).get("applies_to", [])))
except Exception:
    pass')
done
PIHOLE_DEAD=0

# Host service health is judged RELATIVELY: only services that were
# listening at watch start (SSH, Plex, Samba, Transmission - whichever
# exist on this box) must stay up. Optional services absent at start are
# ignored, so the watch works on any host.
HOST_PORTS=(22 32400 445 9091)
declare -A HOST_WAS_UP
for p in "${HOST_PORTS[@]}"; do
  if ss -ltn 2>/dev/null | grep -q ":$p "; then HOST_WAS_UP[$p]=1; else HOST_WAS_UP[$p]=0; fi
done

get_counters(){
  nft -s list chain ip tvguard forward 2>/dev/null | awk '
    /TVGUARD-NEW /     { for(i=1;i<=NF;i++) if ($i=="packets") NEW=$(i+1) }
    /TVGUARD-PRIVACY-  { for(i=1;i<=NF;i++) if ($i=="packets") PRIV=$(i+1) }
    /TVGUARD-DOT-      { for(i=1;i<=NF;i++) if ($i=="packets") DOT=$(i+1) }
    END { print NEW+0, PRIV+0, DOT+0 }'
}

i=0
while :; do
  i=$((i+1))
  # Pi-hole health
  PHQ=$(PRIVACY_ROOT="$ROOT" python3 - <<'PYEOF' 2>/dev/null
import json, os, urllib.request, urllib.error
ROOT = os.environ["PRIVACY_ROOT"]
BASE = "http://127.0.0.1:3001"
pw = ""
for line in open(os.path.join(ROOT, ".env")):
    if line.startswith("ADMIN_PASSWORD="):
        pw = line.strip().split("=", 1)[1]
def req(method, path, body=None, sid=None):
    r = urllib.request.Request(BASE + path, method=method)
    r.add_header("Content-Type", "application/json")
    if sid: r.add_header("X-FTL-SID", sid)
    data = json.dumps(body).encode() if body is not None else None
    try:
        with urllib.request.urlopen(r, data, timeout=8) as resp:
            raw = resp.read().decode()
            return (json.loads(raw) if raw else {})
    except Exception:
        return None
res = req("POST", "/api/auth", {"password": pw})
sid = res.get("session", {}).get("sid") if res else None
if not sid:
    print("UNHEALTHY,0,0"); raise SystemExit
qs = req("GET", "/api/queries?limit=100", None, sid).get("queries", [])
blocked = sum(1 for q in qs if q.get("status") in ("blocked_regex","blocked_exact","blocked_never_host","blocked_forward","blocked_cnames","blocked_gravity"))
print("OK,%d,%d" % (len(qs), blocked))
PYEOF
)
  PH_STATE=$(echo "$PHQ" | cut -d, -f1)
  PH_Q=$(echo "$PHQ" | cut -d, -f2); PH_B=$(echo "$PHQ" | cut -d, -f3)

  # per-vendor TV conntrack
  TV_STATS=""
  for v in $ACTIVE_VENDORS; do
    CT=0
    for ip in ${TV_IPS[$v]}; do
      N=$(conntrack -L 2>/dev/null | grep -c "$ip")
      CT=$((CT + N))
    done
    TV_STATS="$TV_STATS $v=$CT"
    if [ "$CT" -eq 0 ]; then DEAD_STREAK[$v]=$((DEAD_STREAK[$v] + 1)); else DEAD_STREAK[$v]=0; fi
  done

  CTR=$(get_counters)
  NEW=$(echo "$CTR" | awk '{print $1}'); PRIVC=$(echo "$CTR" | awk '{print $2}'); DOTC=$(echo "$CTR" | awk '{print $3}')

  HOSTOK=1
  for p in "${HOST_PORTS[@]}"; do
    [ "${HOST_WAS_UP[$p]}" = "1" ] || continue   # wasn't running at start: not our problem
    ss -ltn 2>/dev/null | grep -q ":$p " || HOSTOK=0
  done
  docker ps 2>/dev/null | grep -q pihole || HOSTOK=0

  printf "%s  pihole=%s q=%s blocked=%s | tvconntrack:%s | NEW=%s PRIV=%s DOT=%s | host=%s\n" \
    "$(date -u +%H:%M:%S)" "$PH_STATE" "$PH_Q" "$PH_B" "$TV_STATS" "$NEW" "$PRIVC" "$DOTC" "$( [ $HOSTOK -eq 1 ] && echo OK || echo DEGRADED )"

  if [ "$PH_STATE" = "UNHEALTHY" ]; then PIHOLE_DEAD=$((PIHOLE_DEAD + 1)); else PIHOLE_DEAD=0; fi

  if [ -n "$AUTO" ]; then
    for v in $ACTIVE_VENDORS; do
      if [ "${DEAD_STREAK[$v]}" -ge 3 ] || [ "$PIHOLE_DEAD" -ge 3 ] || [ "$HOSTOK" -eq 0 ]; then
        echo
        echo "!! AUTO-ROLLBACK TRIGGERED for vendor $v (TV path dead / Pi-hole unhealthy / host degraded)"
        echo "!! Disabling ONLY the $v privacy layer (NAT/gateway + monitor mode + other vendors preserved)."
        bash "$SCRIPT_DIR/privacy-policy-disable.sh" "$v"
        echo "!! Auto-rollback complete for $v. Investigate before re-enabling."
        # mark rolled back so we don't re-trigger
        DEAD_STREAK[$v]=0; PIHOLE_DEAD=0
      fi
    done
  fi

  if [ "$i" -ge "$DUR" ] && [ "$i" -gt 0 ] && [ $((i % 10)) -eq 0 ]; then
    for v in $ACTIVE_VENDORS; do
      if [ "${TV_MLOCK[$v]}" = "1" ]; then
        echo "--- unknown egress digest (vendor $v, last 2h, denied-by-default) ---"
        bash "$SCRIPT_DIR/show-unknown-samsung.sh" "$v" 2 2>/dev/null || echo "  (show-unknown unavailable this cycle)"
      fi
    done
  fi

  [ "$i" -ge "$DUR" ] && break
  sleep 60
done

echo
echo "watch finished: $(date -u +%H:%M:%S) UTC"
echo
echo "Review candidates (manual, from the Pi-hole UI):"
echo "  * blocked queries per domain:  http://${PIHOLE_IP:-127.0.0.1}:3001 (Queries tab)"
echo "  * unknown vendor egress (manufacturer-lockdown):"
echo "      sudo scripts/show-unknown-samsung.sh samsung 24   |   ... lg 24"
echo "    then: sudo scripts/manufacturer-review.sh <vendor> keep <domain> [reason]   (or: block <domain> [reason])"
echo "  * if a function broke, find the failing domain in the query log and add it to"
echo "    the vendor's keep file BEFORE re-enabling (keep-list wins over the policy)."
