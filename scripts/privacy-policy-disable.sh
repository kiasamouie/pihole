#!/usr/bin/env bash
#
# privacy-policy-disable.sh - remove ALL privacy-policy effects (one command).
#
#   sudo scripts/privacy-policy-disable.sh
#
# It removes ONLY:
#   * the tv_privacy_blocked / tv_doh_blocked sets and the privacy drop rules
#     (by re-rendering ONLY table ip tvguard without them - the TVGuard mode,
#     NAT/masquerade, DNS-bypass DNAT and ufw route rules stay intact, so the
#     TV keeps its Internet path exactly as in MONITOR mode),
#   * the Pi-hole group "TVGuard-Privacy", its domains, and the group
#     membership on the target clients (other groups untouched).
#
# It NEVER touches: UFW, Docker, iptables/nftables outside ip tvguard,
# TVGuard monitor mode, Plex, Samba, SSH, or any other client's groups.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
STATE_DIR=/var/lib/tvguard
STATE_FILE="$STATE_DIR/privacy-state"
# Testability override (default = production group name):
#   PRIVACY_GROUP  which Pi-hole group to remove (mock cycles use a throwaway)
PRIVACY_GROUP="${PRIVACY_GROUP:-TVGuard-Privacy}"

if [ "$(id -u)" -ne 0 ]; then echo "run with sudo" >&2; exit 3; fi

echo "== writing privacy state: off =="
mkdir -p "$STATE_DIR"
{
  echo "PRIVACY=off"
  echo "DISABLED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$STATE_FILE"
chmod 600 "$STATE_FILE"

echo "== re-rendering table ip tvguard (privacy sets removed) =="
bash "$SCRIPT_DIR/tvguard-apply.sh" || {
  echo "tvguard-apply failed - manual check needed (state file now says off)" >&2
  exit 6
}

echo
echo "== removing Pi-hole group $PRIVACY_GROUP and its domains =="
PRIVACY_ROOT="$ROOT" PRIVACY_GROUP="$PRIVACY_GROUP" python3 - <<'PYEOF'
import json, os, sys, urllib.request, urllib.error

ROOT = os.environ["PRIVACY_ROOT"]
BASE = "http://127.0.0.1:3001"
GROUP_NAME = os.environ.get("PRIVACY_GROUP", "TVGuard-Privacy")

pw = ""
for line in open(os.path.join(ROOT, ".env")):
    if line.startswith("ADMIN_PASSWORD="):
        pw = line.strip().split("=", 1)[1]

SID = None
def req(method, path, body=None):
    global SID
    r = urllib.request.Request(BASE + path, method=method)
    r.add_header("Content-Type", "application/json")
    if SID:
        r.add_header("X-FTL-SID", SID)
    data = json.dumps(body).encode() if body is not None else None
    try:
        with urllib.request.urlopen(r, data) as resp:
            raw = resp.read().decode()
            return resp.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read().decode() or "{}")
        except Exception:
            return e.code, {}

code, res = req("POST", "/api/auth", {"password": pw})
if code != 200:
    print("  WARN: Pi-hole login failed - group cleanup not done, manual step needed")
    sys.exit(0)
SID = res["session"]["sid"]

code, res = req("GET", "/api/groups")
groups = {g["name"]: g["id"] for g in res.get("groups", [])}
if GROUP_NAME not in groups:
    print("  group %s absent - nothing to remove" % GROUP_NAME)
else:
    gid = groups[GROUP_NAME]
    # collect this group's domains (v6: domains carry a groups list)
    to_del = []
    offset, limit = 0, 100
    while True:
        code, res = req("GET", "/api/domains?limit=%d&offset=%d" % (limit, offset))
        rows = res.get("domains", res if isinstance(res, list) else [])
        if not isinstance(rows, list) or not rows:
            break
        for d in rows:
            if gid in (d.get("groupIDs") or d.get("groups") or []):
                to_del.append({"item": d["domain"],
                               "type": d.get("type", "deny"),
                               "kind": d.get("kind", "exact")})
        if len(rows) < limit:
            break
        offset += limit
    if to_del:
        req("POST", "/api/domains:batchDelete", to_del)
    print("  removed %d domain(s) from %s" % (len(to_del), GROUP_NAME))
    # detach clients
    code, res = req("GET", "/api/clients")
    for c in res.get("clients", []):
        cur = c.get("groups", [])
        if gid in cur:
            cur = [g for g in cur if g != gid]
            key = c.get("client") or c.get("ip")
            req("PUT", "/api/clients/%s" % key, {"client": key, "groups": cur})
            print("  detached client %s" % key)
    req("POST", "/api/groups:batchDelete", [{"item": GROUP_NAME}])
    print("  deleted group %s (id %d)" % (GROUP_NAME, gid))
PYEOF

echo
echo "== verification =="
if nft list table ip tvguard 2>/dev/null | grep -q "tv_privacy_blocked\|tv_doh_blocked"; then
  echo "  WARN: privacy set still present in table ip tvguard" >&2
else
  echo "  OK: no privacy sets in table ip tvguard"
fi
if nft list table ip tvguard 2>/dev/null | grep -q masquerade; then
  echo "  OK: masquerade (NAT) still present - TV gateway path intact"
else
  echo "  WARN: masquerade missing - check TVGuard state" >&2
fi
echo
echo "Done. TVGuard is back to its pre-privacy (MONITOR) behaviour. Pi-hole group removed."
echo "The TV itself is unchanged - no TV-side revert is needed."
