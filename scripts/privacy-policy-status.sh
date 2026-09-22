#!/usr/bin/env bash
#
# privacy-policy-status.sh - show the current privacy-policy state.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
STATE_DIR=/var/lib/tvguard
# Testability override (default = production group name)
PRIVACY_GROUP="${PRIVACY_GROUP:-TVGuard-Privacy}"

echo "=== privacy state ==="
if [ -f "$STATE_DIR/privacy-state" ]; then
  cat "$STATE_DIR/privacy-state"
else
  echo "(no state file - privacy OFF)"
fi

echo
echo "=== nftables (privacy part of table ip tvguard) ==="
# capture to a var first: `nft ... | grep -q` SIGPIPEs nft under set -o pipefail
T=$(nft list table ip tvguard 2>/dev/null)
if echo "$T" | grep -q "tv_privacy_blocked\|tv_doh_blocked"; then
  echo "$T" | sed -n '/tv_privacy_blocked/,/}/p;/tv_doh_blocked/,/}/p'
  nft list chain ip tvguard forward 2>/dev/null | grep -E "PRIVACY|DOH|DOT" || true
else
  echo "(no privacy sets present - firewall privacy layer OFF)"
fi

echo
echo "=== Pi-hole group $PRIVACY_GROUP ==="
PRIVACY_ROOT="$ROOT" PRIVACY_GROUP="$PRIVACY_GROUP" python3 - <<'PYEOF' 2>/dev/null || echo "(Pi-hole API unreachable)"
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
    rows = req("GET", "/api/domains?limit=100", None, sid).get("domains", [])
    mine = [d for d in rows if gid in (d.get("groupIDs") or d.get("groups") or [])]
    mine_types = {}
    for d in mine:
        mine_types[(d.get("type", "deny"), d.get("kind", "exact"))] = mine_types.get((d.get("type", "deny"), d.get("kind", "exact")), 0) + 1
    print("group id: %d | rows in group: %d | %s" % (gid, len(mine),
          ", ".join("%d %s-%s" % (n, t, k) for (t, k), n in sorted(mine_types.items()))))
    allows = sorted(d["domain"] for d in mine if d.get("type") == "allow")
    if allows:
        print("  allow rows (keep wins):")
        for a in allows:
            print("    allow %s" % a)
    for c in req("GET", "/api/clients", None, sid).get("clients", []):
        if gid in c.get("groups", []):
            print("  attached client: %s" % (c.get("client") or c.get("ip")))
PYEOF

echo
echo "=== TVGuard base state ==="
grep -E '^MODE=' "$STATE_DIR/state" 2>/dev/null || echo "(no tvguard state)"
echo
echo "Run 'sudo scripts/privacy-policy-apply.sh standard|standard-no-voice|strict|manufacturer-lockdown' to enable,"
echo "'sudo scripts/privacy-policy-disable.sh' to remove the privacy layer."
