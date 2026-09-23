#!/usr/bin/env bash
#
# privacy-policy-status.sh - show the current per-vendor privacy-policy state.
#
# Shows, for EVERY vendor in config/privacy-instances.yaml:
#   * its state line (PRIVACY-<vendor>=<tier>, legacy PRIVACY= parsed as samsung)
#   * its nftables client/deny/DoH sets in table ip tvguard
#   * its dedicated Pi-hole group (rows, allow rows, attached clients)
# so the simultaneous Samsung + LG state is obvious at a glance.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
STATE_DIR=/var/lib/tvguard

VENDOR_GROUPS="$(python3 - "$ROOT/config/privacy-instances.yaml" <<'PYEOF' 2>/dev/null
import sys
import yaml
inst = (yaml.safe_load(open(sys.argv[1])).get("instances") or {})
for v, cfg in inst.items():
    print("\t".join([v, cfg.get("pihole_group", "TVGuard-Privacy-%s" % v.upper())]))
PYEOF
)"

echo "=== privacy state (per vendor) ==="
if [ -f "$STATE_DIR/privacy-state" ]; then
  cat "$STATE_DIR/privacy-state"
else
  echo "(no state file - privacy OFF for all vendors)"
fi

T=$(nft list table ip tvguard 2>/dev/null)

while IFS=$'\t' read -r v group; do
  [ -n "$v" ] || continue
  echo
  echo "=== vendor: $v (Pi-hole group: $group) ==="
  if echo "$T" | grep -q "tv_privacy_${v}\b"; then
    echo "$T" | sed -n "/set tv_privacy_${v} {/,/}/p;/set tv_privacy_blocked_${v} {/,/}/p;/set tv_doh_blocked_${v} {/,/}/p"
    nft list chain ip tvguard forward 2>/dev/null | grep -E "TVGUARD-(PRIVACY|DOH|DOT)-$(echo "$v" | tr a-z A-Z) " || true
  else
    echo "(no privacy sets present - firewall privacy layer OFF for $v)"
  fi
  echo "---"
  PRIVACY_ROOT="$ROOT" PRIVACY_GROUP="$group" python3 - <<'PYEOF' 2>/dev/null || echo "(Pi-hole API unreachable)"
import json, os, urllib.request, urllib.error
ROOT = os.environ["PRIVACY_ROOT"]
BASE = "http://127.0.0.1:3001"
GROUP_NAME = os.environ.get("PRIVACY_GROUP", "TVGuard-Privacy")
pw = ""
for line in open(os.path.join(ROOT, ".env")):
    if line.startswith("ADMIN_PASSWORD="):
        pw = line.strip().split("=", 1)[1]
def req(method, path, body=None, sid=None):
    r = urllib.request.Request(BASE + path, method=method)
    r.add_header("Content-Type", "application/json")
    if sid:
        r.add_header("X-FTL-SID", sid)
    data = json.dumps(body).encode() if body is not None else None
    with urllib.request.urlopen(r, data) as resp:
        raw = resp.read().decode()
        return (json.loads(raw) if raw else {})
res = req("POST", "/api/auth", {"password": pw})
sid = res["session"]["sid"]
groups = {g["name"]: g["id"] for g in req("GET", "/api/groups", None, sid).get("groups", [])}
if GROUP_NAME not in groups:
    print("(group absent - Pi-hole privacy layer OFF)")
else:
    gid = groups[GROUP_NAME]
    # (FTL here ignores `offset` on /api/domains - single expanding-limit fetch)
    all_rows, flimit = [], 1000
    while True:
        page = req("GET", "/api/domains?limit=%d" % flimit, None, sid).get("domains", [])
        if not isinstance(page, list):
            page = []
        if len(page) < flimit:
            all_rows.extend(page)
            break
        flimit *= 4
        if flimit > 100000:
            all_rows.extend(page)
            break
    mine = [d for d in all_rows if gid in (d.get("groupIDs") or d.get("groups") or [])]
    mine_types = {}
    for d in mine:
        mine_types[(d.get("type", "deny"), d.get("kind", "exact"))] = mine_types.get((d.get("type", "deny"), d.get("kind", "exact")), 0) + 1
    print("group id: %d | rows in group: %d | %s" % (gid, len(mine),
          ", ".join("%d %s-%s" % (n, t, k) for (t, k), n in sorted(mine_types.items()))))
    for c in req("GET", "/api/clients", None, sid).get("clients", []):
        if gid in c.get("groups", []):
            print("  attached client: %s" % (c.get("client") or c.get("ip")))
PYEOF
done <<< "$VENDOR_GROUPS"

echo
echo "=== TVGuard base state ==="
grep -E '^MODE=' "$STATE_DIR/state" 2>/dev/null || echo "(no tvguard state)"
echo
echo "Enable:  sudo scripts/privacy-policy-apply.sh [vendor] <standard|standard-no-voice|strict|manufacturer-lockdown>"
echo "Disable: sudo scripts/privacy-policy-disable.sh [all|samsung|lg]"
