#!/usr/bin/env bash
#
# privacy-watch.sh - safety watch after enabling a privacy policy.
#
#   sudo scripts/privacy-watch.sh [minutes] [--auto-rollback]
#
# Samples every 60s:
#   * Pi-hole: queries seen, blocked count, health
#   * Samsung: active conntrack entries through this host (NAT path alive?)
#   * nftables: TVGUARD-NEW / TVGUARD-PRIVACY / TVGUARD-DOT / TVGUARD-DOH counters
#   * host: SSH/Plex/Samba/Transmission/Docker listeners
#
# It NEVER auto-allowlists anything - it reports candidates for review.
# With --auto-rollback it disables ONLY the privacy layer (privacy-policy-
# disable.sh) when the TV's NAT path clearly dies or Pi-hole becomes
# unreachable. It never touches UFW, Docker, TVGuard monitor state, or other
# devices.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
STATE_DIR=/var/lib/tvguard
DUR="${1:-30}"
AUTO=""
[ "${2:-}" = "--auto-rollback" ] && AUTO=1

# source the watched TV IP from config (Samsung by default)
if [ -f "$ROOT/config/tvguard.conf" ]; then
  # shellcheck source=/dev/null
  . "$ROOT/config/tvguard.conf"
fi
TV_IP="${SAMSUNG_IP:-192.168.0.197}"
PRIVACY=$(sed -n 's/^PRIVACY=//p' "$STATE_DIR/privacy-state" 2>/dev/null | tail -1)
echo "privacy-watch: ${DUR} min | privacy state: ${PRIVACY:-off} | auto-rollback: ${AUTO:-no}"
echo "start: $(date -u +%H:%M:%S) UTC"

TV_IP=192.168.0.197
dead_streak=0
pihole_dead=0

get_counters(){
  nft -s list chain ip tvguard forward 2>/dev/null | awk '
    /TVGUARD-NEW /     { for(i=1;i<=NF;i++) if ($i=="packets") NEW=$(i+1) }
    /TVGUARD-PRIVACY / { for(i=1;i<=NF;i++) if ($i=="packets") PRIV=$(i+1) }
    /TVGUARD-DOT /     { for(i=1;i<=NF;i++) if ($i=="packets") DOT=$(i+1) }
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

  # Samsung NAT path
  TVCT=$(conntrack -L 2>/dev/null | grep -c "$TV_IP")

  CTR=$(get_counters)
  NEW=$(echo "$CTR" | awk '{print $1}'); PRIVC=$(echo "$CTR" | awk '{print $2}'); DOTC=$(echo "$CTR" | awk '{print $3}')

  HOSTOK=1
  ss -ltn | grep -q ':13567 ' || HOSTOK=0   # SSH
  ss -ltn | grep -q ':32400 ' || HOSTOK=0   # Plex
  ss -ltn | grep -q ':445 ' || HOSTOK=0     # Samba
  ss -ltn | grep -q ':9091 ' || HOSTOK=0    # Transmission
  docker ps 2>/dev/null | grep -q pihole || HOSTOK=0

  printf "%s  pihole=%s q=%s blocked=%s | samsung conntrack=%s | NEW=%s PRIV=%s DOT=%s | host=%s\n" \
    "$(date -u +%H:%M:%S)" "$PH_STATE" "$PH_Q" "$PH_B" "$TVCT" "$NEW" "$PRIVC" "$DOTC" "$( [ $HOSTOK -eq 1 ] && echo OK || echo DEGRADED )"

  if [ "$PH_STATE" = "UNHEALTHY" ]; then pihole_dead=$((pihole_dead+1)); else pihole_dead=0; fi
  if [ "$TVCT" -eq 0 ]; then dead_streak=$((dead_streak+1)); else dead_streak=0; fi

  if [ -n "$AUTO" ] && [ "$PRIVACY" != "off" ]; then
    if [ "$dead_streak" -ge 3 ] || [ "$pihole_dead" -ge 3 ] || [ "$HOSTOK" -eq 0 ]; then
      echo
      echo "!! AUTO-ROLLBACK TRIGGERED (TV path dead / Pi-hole unhealthy / host degraded)"
      echo "!! Disabling PRIVACY layer only (NAT/gateway + monitor mode are preserved)."
      bash "$SCRIPT_DIR/privacy-policy-disable.sh"
      echo "!! Auto-rollback complete. Investigate before re-enabling."
      break
    fi
  fi

  [ "$i" -ge "$DUR" ] && break
  sleep 60
done

echo
echo "watch finished: $(date -u +%H:%M:%S) UTC"
echo
echo "Review candidates (manual, from the Pi-hole UI):"
echo "  * blocked queries per domain:  http://192.168.0.128:3001 (Queries tab)"
echo "  * if a function broke, find the failing domain in the query log and add it to"
echo "    config/privacy-keep.yaml BEFORE re-enabling (keep-list wins over the policy)."
