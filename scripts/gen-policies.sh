#!/usr/bin/env bash
#
# gen-policies.sh  -  report (and optionally push) the TVGuard policy.
#
# Reads config/destinations.yaml - the single source of truth - and:
#   * prints every destination with its class + evidence (human review)
#   * shows which are currently class:blocked (i.e. what ENFORCE would drop)
#   * --push-pihole : push class:blocked domains into Pi-hole's denylist for the
#                     TV group (enforce phase only; monitor mode is logging-only)
#
# Usage:
#   scripts/gen-policies.sh                 # report
#   scripts/gen-policies.sh --push-pihole   # report + sync Pi-hole deny (enforce)
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$DIR")"
YAML="$ROOT/config/destinations.yaml"
[ -f "$YAML" ] || { echo "no $YAML" >&2; exit 4; }

parse_rows() {
  awk '
    function trim(s){ gsub(/^[[:space:]]+/,"",s); gsub(/[[:space:]]+$/,"",s); return s }
    /^[[:space:]]*-[[:space:]]*domain:/ {
      if (dom!="") print dom"|"ip"|"cls"|"conf"|"ev
      dom=""; ip=""; cls="unknown"; conf=""; ev=""
      d=$0; sub(/^.*domain:[[:space:]]*/,"",d); dom=trim(d); next
    }
    /^[[:space:]]*ip:[[:space:]]*/     { v=$0; sub(/^.*ip:[[:space:]]*/,"",v);   ip=trim(v) }
    /^[[:space:]]*class:[[:space:]]*/  { v=$0; sub(/^.*class:[[:space:]]*/,"",v); cls=trim(v) }
    /^[[:space:]]*confidence:[[:space:]]*/ { v=$0; sub(/^.*confidence:[[:space:]]*/,"",v); conf=trim(v) }
    /^[[:space:]]*evidence:[[:space:]]*/ { v=$0; sub(/^.*evidence:[[:space:]]*/,"",v); ev=trim(v) }
    END { if (dom!="") print dom"|"ip"|"cls"|"conf"|"ev }
  ' "$YAML"
}

echo "=== TVGuard destination policy (from $YAML) ==="
printf "%-45s %-15s %-9s %s\n" "DOMAIN" "CLASS" "CONF" "IP / EVIDENCE"
printf "%-45s %-15s %-9s %s\n" "-----" "-----" "----" "-----------"
parse_rows | while IFS='|' read -r dom ip cls conf ev; do
  marker=""
  [ "$cls" = "blocked" ] && marker="  <== ENFORCE blocks this"
  printf "%-45s %-15s %-9s %s%s\n" "$dom" "$cls" "$conf" "${ip:--}  $ev" "$marker"
done

n_blocked=$(parse_rows | awk -F'|' '$3=="blocked"' | wc -l)
echo
echo "class:blocked count: $n_blocked  (these are dropped in ENFORCE mode; MONITOR is logging-only)"
if [ "$n_blocked" -eq 0 ]; then
  echo "  -> nothing is enforced yet. Add evidence, then mark entries class: blocked to enforce."
fi

if [ "${1:-}" = "--push-pihole" ]; then
  echo
  echo "=== pushing class:blocked domains to Pi-hole (TV group) ==="
  DOMAINS=$(parse_rows | awk -F'|' '$3=="blocked"{print $1}' | grep -v '^$' || true)
  if [ -z "$DOMAINS" ]; then
    echo "  (no blocked domains to push)"
  else
    # Build a JSON array of domains and push to the TV-Monitor group via the v6 API.
    PY="$(mktemp)"
    cat > "$PY" <<'PYEOF'
import json, os, sys, time, urllib.request, urllib.error
BASE = "http://127.0.0.1:3001"
ENV  = os.environ["TVGUARD_ENV"]
PW = ""
for line in open(ENV):
    if line.startswith("ADMIN_PASSWORD="):
        PW = line.strip().split("=",1)[1]
domains = [d.strip() for d in os.environ["TVGUARD_DOMAINS"].splitlines() if d.strip()]
# find TV group id by name (fallback: no group scoping)
sid=None
def req(method, path, body=None, auth=True):
    r=urllib.request.Request(BASE+path, method=method)
    r.add_header("Content-Type","application/json")
    if auth and sid: r.add_header("X-FTL-SID", sid)
    data=json.dumps(body).encode() if body is not None else None
    with urllib.request.urlopen(r, data) as resp:
        if auth and method=="POST" and path=="/api/auth":
            return dict((k.lower(),v) for k,v in resp.headers.items()).get("x-ftl-sid"), resp.read().decode()
        return resp.read().decode()
# login (retry on 429)
for i in range(5):
    try:
        sid,_ = req("POST","/api/auth",{"password":PW}); break
    except urllib.error.HTTPError as e:
        if e.code==429: time.sleep(2); continue
        raise
# find the TV group id
gid=None
try:
    body=req("GET","/api/groups",None)
    for g in json.loads(body):
        if g.get("name","").lower() in ("tv-monitor","tv-strict"):
            gid=g["id"]; break
except Exception as e:
    print("  group lookup failed:", e)
if gid is None:
    print("  WARN: no TV-Monitor/TV-Strict group found; adding to default denylist (all groups)")
    payload={"domain":domains}
else:
    print("  target group id:", gid)
    payload={"domain":domains,"groups":[gid]}
body=req("POST","/api/domains/deny/exact",payload)
print("  pushed", len(domains), "domain(s):", ", ".join(domains))
PYEOF
    TVGUARD_ENV="$ROOT/.env" TVGUARD_DOMAINS="$DOMAINS" python3 "$PY"
    rm -f "$PY"
  fi
fi
