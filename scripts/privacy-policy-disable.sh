#!/usr/bin/env bash
#
# privacy-policy-disable.sh - remove privacy-policy effects (one command).
#
#   sudo scripts/privacy-policy-disable.sh          # ALL vendors (samsung + lg)
#   sudo scripts/privacy-policy-disable.sh lg        # LG only (Samsung stays live)
#   sudo scripts/privacy-policy-disable.sh samsung   # Samsung only
#
# Per vendor it removes ONLY:
#   * that vendor's nftables sets (tv_privacy_<vendor>, tv_privacy_blocked_<vendor>,
#     tv_doh_blocked_<vendor>) and its drop rules (by re-rendering ONLY table
#     ip tvguard without them - the TVGuard mode, NAT/masquerade, the other
#     vendor's privacy layer and the ufw route rules stay intact),
#   * that vendor's state line in /var/lib/tvguard/privacy-state
#     (legacy single line PRIVACY=<tier> is treated as samsung),
#   * the vendor's dedicated Pi-hole group (TVGuard-Privacy / TVGuard-Privacy-LG),
#     its domain rows, and the group membership on the vendor's target clients
#     (other clients/groups untouched).
#
# It NEVER touches: UFW, Docker, iptables/nftables outside ip tvguard,
# TVGuard monitor mode, Plex, Samba, SSH, other household clients, or the
# other vendor's policy/state/group.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
STATE_DIR=/var/lib/tvguard
STATE_FILE="$STATE_DIR/privacy-state"

if [ "$(id -u)" -ne 0 ]; then echo "run with sudo" >&2; exit 3; fi

# vendor selection (default: all)
REQUESTED="${1:-all}"
case "$REQUESTED" in all|samsung|lg) ;;
  *) echo "usage: privacy-policy-disable.sh [all|samsung|lg]" >&2; exit 4 ;;
esac

# registry: vendor<TAB>group lines
VENDOR_GROUPS="$(python3 - "$ROOT/config/privacy-instances.yaml" <<'PYEOF'
import sys
import yaml
inst = (yaml.safe_load(open(sys.argv[1])).get("instances") or {})
for v, cfg in inst.items():
    print("\t".join([v, cfg.get("pihole_group", "TVGuard-Privacy-%s" % v.upper())]))
PYEOF
)"

# current state (vendor<TAB>tier), legacy PRIVACY= parsed as samsung
STATE_LINES="$(STATE_FILE="$STATE_FILE" python3 - <<'PYEOF'
import os
states = {}
path = os.environ["STATE_FILE"]
import builtins
if os.path.exists(path):
    for line in open(path):
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        k, _, v = s.partition("=")
        k, v = k.strip(), v.strip()
        if k == "PRIVACY":
            states.setdefault("samsung", v)
        elif k.startswith("PRIVACY-"):
            states[k[len("PRIVACY-"):].strip().lower()] = v
for v, t in sorted(states.items()):
    print("%s\t%s" % (v, t))
PYEOF
)"

# which vendors does the user want off?
TARGETS=""
if [ "$REQUESTED" = "all" ]; then
  while IFS=$'\t' read -r v t; do
    [ -n "$v" ] && TARGETS="$TARGETS $v"
  done <<< "$STATE_LINES"
  # even if state is empty, still sweep the registry vendors (no state = nothing to off)
  [ -n "$TARGETS" ] || TARGETS=""
else
  [ -n "$(grep -E "^${REQUESTED}	" <<< "$STATE_LINES" 2>/dev/null || true)" ] || true
  TARGETS="$REQUESTED"
fi

if [ -z "$TARGETS" ]; then
  echo "== no vendor has an active privacy tier (state: ${STATE_LINES:-<empty>}) =="
fi

# rewrite the state file: drop the targeted vendors' lines (incl. legacy +
# their APPLIED_AT_* audit lines); keep the rest
{
VENDOR_LIST="$TARGETS" python3 - "$STATE_FILE" <<'PYEOF'
import os, sys, time
vend = set(os.environ["VENDOR_LIST"].split())
path = sys.argv[1]
keep = []
if os.path.exists(path):
    for line in open(path):
        s = line.strip()
        if not s:
            continue
        if s.startswith("PRIVACY=") and "samsung" in vend:
            continue
        for v in vend:
            if s.startswith("PRIVACY-%s=" % v) or s.startswith("APPLIED_AT_%s=" % v.upper()):
                s = None
                break
        if s is not None:
            keep.append(s)
with open(path, "w") as fh:
    for s in keep:
        fh.write(s + "\n")
    if vend:
        fh.write("DISABLED_AT=%s\n" % time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
PYEOF
}
chmod 600 "$STATE_FILE"

echo "== re-rendering table ip tvguard (vendor privacy sets removed) =="
bash "$SCRIPT_DIR/tvguard-apply.sh" || {
  echo "tvguard-apply failed - manual check needed (state file now updated)" >&2
  exit 6
}

# Pi-hole: per targeted vendor, remove its group rows + membership + group
for v in $TARGETS; do
  GROUP="$(awk -F'\t' -v v="$v" '$1==v {print $2; exit}' <<< "$VENDOR_GROUPS")"
  [ -n "$GROUP" ] || continue
  echo
  echo "== removing Pi-hole group $GROUP (vendor $v) =="
  PRIVACY_ROOT="$ROOT" PRIVACY_GROUP="$GROUP" python3 - <<'PYEOF'
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
    # Only delete rows that belong SOLELY to this group. A row shared with
    # another vendor's group (e.g. a shared ad name kept by both) is kept and
    # the shared group association is preserved; we never delete a row that
    # another vendor still uses (no per-row group update endpoint in this FTL
    # build - deleting the row would drop it from the other vendor too).
    # (FTL here ignores `offset` on /api/domains - fetch with one expanding
    # limit instead of offset paging, which loops forever past one page.)
    to_del = []
    flimit, rows = 1000, []
    while True:
        code, res = req("GET", "/api/domains?limit=%d" % flimit)
        rows = res.get("domains") if isinstance(res, dict) else res
        if not isinstance(rows, list):
            rows = []
        if len(rows) < flimit:
            break
        flimit *= 4
        if flimit > 100000:
            break
    for d in rows:
        gids = set(d.get("groupIDs") or d.get("groups") or [])
        if gid in gids and gids == {gid}:
            to_del.append({"item": d["domain"],
                           "type": d.get("type", "deny"),
                           "kind": d.get("kind", "exact")})
    if to_del:
        req("POST", "/api/domains:batchDelete", to_del)
    print("  removed %d group-exclusive domain(s) from %s (shared rows kept for the other vendors)" % (len(to_del), GROUP_NAME))
    # detach ONLY the clients that were in this group
    code, res = req("GET", "/api/clients")
    for c in res.get("clients", []):
        cur = c.get("groups", [])
        if gid in cur:
            cur = [g for g in cur if g != gid]
            key = c.get("client") or c.get("ip")
            req("PUT", "/api/clients/%s" % key, {"client": key, "groups": cur})
            print("  detached client %s from %s" % (key, GROUP_NAME))
    req("POST", "/api/groups:batchDelete", [{"item": GROUP_NAME}])
    print("  deleted group %s (id %d)" % (GROUP_NAME, gid))
PYEOF
done

echo
echo "== verification =="
NFT_TABLE="${TGUARD_TABLE:-tvguard}"
T=$(nft list table ip "$NFT_TABLE" 2>/dev/null)
STILL=""
for v in $TARGETS; do
  if echo "$T" | grep -q "tv_privacy_${v}\|tv_privacy_blocked_${v}\|tv_doh_blocked_${v}"; then
    STILL="$STILL $v"
  fi
done
if [ -n "$STILL" ]; then
  echo "  WARN: privacy sets still present for:$STILL in table ip $NFT_TABLE" >&2
else
  echo "  OK: no privacy sets for the disabled vendor(s) in table ip $NFT_TABLE"
fi
if echo "$T" | grep -q masquerade; then
  echo "  OK: masquerade (NAT) still present - TV gateway path intact"
else
  echo "  WARN: masquerade missing - check TVGuard state" >&2
fi
echo
echo "Done. TVGuard is back to its pre-privacy behaviour for the disabled vendor(s)."
echo "The TV itself is unchanged - no TV-side revert is needed."
echo "Any vendor still active keeps its policy (see: sudo scripts/privacy-policy-status.sh)."
