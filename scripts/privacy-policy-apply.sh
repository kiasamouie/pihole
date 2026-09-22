#!/usr/bin/env bash
#
# privacy-policy-apply.sh - enable a privacy tier for the target TVs.
#
#   sudo scripts/privacy-policy-apply.sh standard
#   sudo scripts/privacy-policy-apply.sh standard-no-voice
#   sudo scripts/privacy-policy-apply.sh strict
#   sudo scripts/privacy-policy-apply.sh manufacturer-lockdown   (recommended)
#
# Testability overrides (documented, default to production values):
#   PRIVACY_GROUP   Pi-hole group name (default: TVGuard-Privacy)
#   PRIVACY_TARGETS space-separated client IPs to scope the policy to
#                   (default: the `applies_to` list in config/privacy-policy.yaml)
# These exist so apply/disable can be exercised against a throwaway group and a
# mock client IP without touching the real Samsung client.
#
# What it does (all reversible via privacy-policy-disable.sh):
#   1. Re-resolves config/privacy-policy.yaml -> data/privacy-policy/resolved.json
#      (external resolver; keep-list overlap excluded).
#   2. Writes /var/lib/tvguard/privacy-state (PRIVACY=<tier>) and re-runs
#      tvguard-apply.sh, which re-renders ONLY table ip tvguard: the TVGuard
#      mode (monitor), NAT/masquerade and the DNS-bypass DNAT are untouched;
#      new DROP sets (tv_privacy_blocked, tv_doh_blocked) and the DoT:853
#      drop are added for the target TVs only.
#   3. Pushes the tier's exact-domain denies AND regex (suffix) denies into
#      the dedicated Pi-hole group "TVGuard-Privacy" (created if missing)
#      scoped to the applies_to clients only (Samsung .197 in the current
#      config). Regex entries come from `kind: suffix` policy entries (see
#      config/privacy-policy.yaml header) and are the primary control for
#      scoped families like the Bixby aibixby.com voice plane.
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
  standard|standard-no-voice|strict|manufacturer-lockdown) ;;
  *) echo "usage: privacy-policy-apply.sh <standard|standard-no-voice|strict|manufacturer-lockdown>" >&2; exit 4 ;;
esac

PRIVACY_GROUP="${PRIVACY_GROUP:-TVGuard-Privacy}"
PRIVACY_TARGETS="${PRIVACY_TARGETS:-}"

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
echo "== pushing domains to Pi-hole group $PRIVACY_GROUP =="
PRIVACY_ROOT="$ROOT" PRIVACY_TIER="$TIER" PRIVACY_GROUP="$PRIVACY_GROUP" PRIVACY_TARGETS="$PRIVACY_TARGETS" python3 - <<'PYEOF'
import json, os, re, sys, time, urllib.request, urllib.error, yaml

ROOT = os.environ["PRIVACY_ROOT"]
TIER = os.environ["PRIVACY_TIER"]
BASE = "http://127.0.0.1:3001"
GROUP_NAME = os.environ.get("PRIVACY_GROUP", "TVGuard-Privacy")

pw = ""
for line in open(os.path.join(ROOT, ".env")):
    if line.startswith("ADMIN_PASSWORD="):
        pw = line.strip().split("=", 1)[1]

doc = yaml.safe_load(open(os.path.join(ROOT, "config", "privacy-policy.yaml")))
_tv = os.environ.get("PRIVACY_TARGETS", "").split()
targets = _tv if _tv else [str(x) for x in (doc.get("applies_to") or [])]
resolved = json.load(open(os.path.join(ROOT, "data", "privacy-policy", "resolved.json")))
domains = resolved[TIER]["domains"]
regexes = [r["pattern"] for r in (resolved[TIER].get("regexes") or [])]
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
# regex (suffix-family) denies - e.g. the aibixby.com Bixby voice plane
# (case-insensitive compare: patterns contain uppercase classes like \S)
rx_push = [p for p in regexes if p.lower() not in existing]
if rx_push:
    code, res = req("POST", "/api/domains/deny/regex", {"domain": rx_push, "groups": [gid]})
    if code not in (200, 201):
        sys.exit("regex push failed: %s" % res)
print("  pushed %d regex denies to %s (%d already present)" % (len(rx_push), GROUP_NAME, len(regexes) - len(rx_push)))
# allow rows (manufacturer-lockdown keep list): keep wins - in FTL an allow
# row for the client beats the group's zone-regex deny for that exact name
# (proven by the selftest), and also shields the name against a
# gravity/baseline block. Names already present in the global Pi-hole DB
# cannot be re-added (4xx); those are skipped with a note.
allows = [a for a in (resolved[TIER].get("allows") or [])]
allow_fresh = [a for a in allows if a.lower() not in existing]
if allow_fresh:
    code, res = req("POST", "/api/domains/allow/exact", {"domain": allow_fresh, "groups": [gid]})
    if code not in (200, 201):
        pushed = 0
        for a in allow_fresh:
            code2, res2 = req("POST", "/api/domains/allow/exact", {"domain": [a], "groups": [gid]})
            if code2 in (200, 201):
                pushed += 1
            else:
                print("  WARN: allow row for %s not pushed: %s" % (a, str(res2)[:100]))
        print("  pushed %d allow rows to %s (one-at-a-time fallback)" % (pushed, GROUP_NAME))
    else:
        print("  pushed %d allow rows to %s" % (len(allow_fresh), GROUP_NAME))
if allows:
    print("  allows total: %d (%d already in Pi-hole DB, skipped)" % (len(allows), len(allows) - len(allow_fresh)))
PYEOF

echo
echo "== done =="
if [ -n "$PRIVACY_TARGETS" ]; then
  TARGETS=$(echo $PRIVACY_TARGETS | paste -sd, -)
else
  TARGETS=$(sed -n '/^applies_to:/,/^$/p' "$ROOT/config/privacy-policy.yaml" | grep -E '^[[:space:]]*-[[:space:]]*"' | sed -E 's/^[[:space:]]*-[[:space:]]*"([^"]+)".*/\1/' | paste -sd, -)
fi
echo "Tier $TIER is now ACTIVE for: ${TARGETS:-<applies_to>}"
echo "Verify:  sudo scripts/privacy-policy-status.sh"
echo "Undo:    sudo scripts/privacy-policy-disable.sh"
