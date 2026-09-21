#!/usr/bin/env bash
#
# privacy-policy-apply.sh - enable a privacy tier for the target TVs.
#
#   sudo scripts/privacy-policy-apply.sh standard
#   sudo scripts/privacy-policy-apply.sh strict
#
# What it does (all reversible via privacy-policy-disable.sh):
#   1. Re-resolves config/privacy-policy.yaml -> data/privacy-policy/resolved.json
#      (external resolver; keep-list overlap excluded).
#   2. Writes /var/lib/tvguard/privacy-state (PRIVACY=<tier>) and re-runs
#      tvguard-apply.sh, which re-renders ONLY table ip tvguard: the TVGuard
#      mode (monitor), NAT/masquerade and the DNS-bypass DNAT are untouched;
#      new DROP sets (tv_privacy_blocked, tv_doh_blocked) and the DoT:853
#      drop are added for the target TVs only.
#   3. Pushes the tier's domains into the dedicated Pi-hole group
#      "TVGuard-Privacy" (created if missing) scoped to the applies_to
#      clients only (Samsung .197 in the current config).
#
# It NEVER: flushes nftables/iptables, touches UFW or Docker, changes TVGuard
# monitor mode, enables DHCP, or blocks anything outside the target TVs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
STATE_DIR=/var/lib/tvguard
STATE_FILE="$STATE_DIR/privacy-state"

TIER="${1:-}"
case "$TIER" in
  standard|strict) ;;
  *) echo "usage: privacy-policy-apply.sh <standard|strict>" >&2; exit 4 ;;
esac

if [ "$(id -u)" -ne 0 ]; then echo "run with sudo" >&2; exit 3; fi

# 1. fresh resolution (uses 8.8.8.8, never the local Pi-hole)
echo "== resolving policy via external resolver =="
python3 "$SCRIPT_DIR/privacy-policy-build.py" || { echo "build failed; nothing applied." >&2; exit 5; }

# 2. firewall part (re-renders only table ip tvguard)
echo
echo "== writing privacy state: $TIER =="
mkdir -p "$STATE_DIR"
{
  echo "PRIVACY=$TIER"
  echo "APPLIED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "SOURCE=config/privacy-policy.yaml"
} > "$STATE_FILE"
chmod 600 "$STATE_FILE"

bash "$SCRIPT_DIR/tvguard-apply.sh" || {
  echo "tvguard-apply failed; reverting privacy state to off" >&2
  echo "PRIVACY=off" > "$STATE_FILE"
  exit 6
}

# 3. Pi-hole part (dedicated group, scoped to applies_to clients)
echo
echo "== pushing domains to Pi-hole group TVGuard-Privacy =="
PRIVACY_ROOT="$ROOT" PRIVACY_TIER="$TIER" python3 - <<'PYEOF'
import json, os, re, sys, time, urllib.request, urllib.error, yaml

ROOT = os.environ["PRIVACY_ROOT"]
TIER = os.environ["PRIVACY_TIER"]
BASE = "http://127.0.0.1:3001"
GROUP_NAME = "TVGuard-Privacy"

pw = ""
for line in open(os.path.join(ROOT, ".env")):
    if line.startswith("ADMIN_PASSWORD="):
        pw = line.strip().split("=", 1)[1]

doc = yaml.safe_load(open(os.path.join(ROOT, "config", "privacy-policy.yaml")))
targets = [str(x) for x in (doc.get("applies_to") or [])]
resolved = json.load(open(os.path.join(ROOT, "data", "privacy-policy", "resolved.json")))
domains = resolved[TIER]["domains"]
print("  targets (applies_to): %s" % ", ".join(targets))

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
    sys.exit("login failed: %s" % res)
SID = res["session"]["sid"]

code, res = req("GET", "/api/groups")
groups = {g["name"]: g["id"] for g in res.get("groups", [])}
if GROUP_NAME in groups:
    gid = groups[GROUP_NAME]
    print("  group %s exists (id %d)" % (GROUP_NAME, gid))
else:
    code, res = req("POST", "/api/groups", {"name": GROUP_NAME,
        "comment": "TVGuard privacy policy domains (managed by privacy-policy-*.sh)"})
    if code not in (200, 201):
        sys.exit("group creation failed: %s" % res)
    gid = res.get("groups", [{}])[0]["id"]
    print("  group %s created (id %d)" % (GROUP_NAME, gid))

# attach target clients (union of their existing groups + privacy group)
code, res = req("GET", "/api/clients")
clients = {c.get("client") or c.get("ip"): c for c in res.get("clients", [])}
for ip in targets:
    c = clients.get(ip)
    if c is None:
        code, res = req("POST", "/api/clients", {"client": ip, "groups": [gid]})
        print("  client %s created (http %d)" % (ip, code))
        continue
    cur = list(c.get("groups", []))
    if gid not in cur:
        cur.append(gid)
        code, _ = req("PUT", "/api/clients/%s" % ip, {"client": ip, "groups": cur})
        print("  client %s attached to %s (http %d)" % (ip, GROUP_NAME, code))
    else:
        print("  client %s already attached" % ip)

# idempotent push: skip domains already in this group (avoids 400 on re-apply,
# e.g. standard followed by strict)
existing = set()
offset = 0
while True:
    code, res = req("GET", "/api/domains?limit=100&offset=%d" % offset)
    rows = res.get("domains") if isinstance(res, dict) else res
    if not isinstance(rows, list) or not rows:
        break
    existing |= {str(d.get("domain", "")).lower() for d in rows}
    if len(rows) < 100:
        break
    offset += 100
to_push = [d for d in domains if d.lower() not in existing]
skipped = len(domains) - len(to_push)
if to_push:
    code, res = req("POST", "/api/domains/deny/exact", {"domain": to_push, "groups": [gid]})
    if code not in (200, 201):
        sys.exit("domain push failed: %s" % res)
print("  pushed %d exact-domain denies to %s (%d already present)" % (len(to_push), GROUP_NAME, skipped))
PYEOF

echo
echo "== done =="
TARGETS=$(sed -n '/^applies_to:/,/^$/p' "$ROOT/config/privacy-policy.yaml" | grep -E '^[[:space:]]*-[[:space:]]*"' | sed -E 's/^[[:space:]]*-[[:space:]]*"([^"]+)".*/\1/' | paste -sd, -)
echo "Tier $TIER is now ACTIVE for: ${TARGETS:-<applies_to>}"
echo "Verify:  sudo scripts/privacy-policy-status.sh"
echo "Undo:    sudo scripts/privacy-policy-disable.sh"
