#!/usr/bin/env bash
#
# privacy-live-check.sh - verify privacy policies that have been ENABLED (per vendor).
#
# Run AFTER:  sudo scripts/privacy-policy-apply.sh [vendor] <tier>
#
# Checks, per active vendor:
#   * firewall layer: vendor client set + deny-IP set present, vendor-scoped
#     drop rules (TVGUARD-PRIVACY-<VENDOR>), DoT drop, DNS forcing DNAT, no
#     rule touching TCP/443 or UDP/443, scope == applies_to only
#   * Pi-hole layer: vendor group present, tier domains/regexes/allows pushed,
#     attached clients == applies_to
#   * TV path: conntrack entries for the vendor's TVs (NAT path alive)
#   * keep-list sanity: vendor keep names still resolve (host-level)
# plus the full host-services regression (health-check) once.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
STATE_DIR=/var/lib/tvguard
# Machine config (TVGUARD_ENV > $ROOT/.env > legacy config/tvguard.conf).
# shellcheck source=/dev/null
. "$SCRIPT_DIR/_tvguard_env.sh" || exit 4
LAN_PREFIX="${LAN_SUBNET%/*}."
PASS=0; FAIL=0
ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# vendor state (legacy PRIVACY= parsed as samsung)
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
        print(v, t)
PYEOF
)
ACTIVE=$(echo "$STATE_ROWS" | wc -l)
if [ "$ACTIVE" -eq 0 ]; then
  echo "no vendor has an active privacy tier - nothing to verify. (This script is for post-enable checks.)"
  exit 0
fi

T=$(nft list table ip tvguard 2>/dev/null)
# global structural checks (once)
if echo "$T" | grep -Eq '(tcp|udp)[[:space:]]+dport[[:space:]]+443'; then
  no "a rule touches TCP/443 or UDP/443 (would break HTTPS/QUIC)"
else
  ok "no rule touches TCP/443 or UDP/443 (HTTPS + QUIC stay free)"
fi
echo "$T" | grep -q "masquerade" && ok "NAT/masquerade intact" || no "masquerade missing - check TVGuard!"
echo "$T" | grep -q "dport 53 dnat" && ok "DNS-bypass DNAT rules present" || no "DNS DNAT missing - check TVGuard!"

while read -r V TIER; do
  [ -n "$V" ] || continue
  U=$(printf '%s' "$V" | tr '[:lower:]' '[:upper:]')
  echo
  echo "############################################"
  echo "VENDOR: $V   TIER: $TIER"
  echo "############################################"
  echo "=== firewall layer ($V) ==="
  echo "$T" | grep -q "tv_privacy_blocked_${V}" && ok "tv_privacy_blocked_${V} set present" || no "tv_privacy_blocked_${V} set missing"
  if [ "$TIER" = "strict" ]; then
    echo "$T" | grep -q "tv_doh_blocked_${V}" && ok "tv_doh_blocked_${V} present (strict)" || no "tv_doh_blocked_${V} missing (strict expected)"
  else
    if echo "$T" | grep -q "tv_doh_blocked_${V}"; then
      no "tv_doh_blocked_${V} present but not expected in $TIER (DoH-IP set is strict-only)"
    else
      ok "no DoH-IP set (correct for $TIER)"
    fi
  fi
  echo "$T" | grep -q "TVGUARD-PRIVACY-$U " && ok "privacy drop rule present ($V)" || no "privacy drop rule missing ($V)"
  echo "$T" | grep -q "TVGUARD-DOT-$U " && ok "DoT :853 drop rule present ($V)" || no "DoT drop rule missing ($V)"
  N=$(echo "$T" | sed -n "/set tv_privacy_blocked_${V}/,/}/p" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort -u | wc -l)
  echo "  deny-IP count in firewall: $N"
  # scope check: vendor privacy rules must match ONLY the vendor's applies_to
  SCOPE_EXPECT=$(RES="$ROOT/data/privacy-policy/resolved.json" V="$V" python3 -c '
import json, os, sys
d = json.load(open(os.environ["RES"]))
print(" ".join(sorted((d.get("vendors") or {}).get(os.environ["V"], {}).get("applies_to", []))))')
  SCOPE_ACTUAL=$(echo "$T" | sed -n "/set tv_privacy_${V} {/,/}/p" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*//g')
  SCOPE_EXPECT_NORM=$(echo "$SCOPE_EXPECT" | sed 's/[[:space:]]*//g')
  [ "$SCOPE_ACTUAL" = "$SCOPE_EXPECT_NORM" ] \
    && ok "tv_privacy_${V} scope = applies_to only ($SCOPE_ACTUAL) - other clients unaffected" \
    || no "tv_privacy_${V} scope mismatch: set={$SCOPE_ACTUAL} vs applies_to={$SCOPE_EXPECT_NORM}"
  BADSCOPE=$(echo "$T" | grep -E 'ip saddr @tvs' | grep -E "tv_privacy_blocked_${V}|dport 853|dport 53" | wc -l)
  [ "$BADSCOPE" -eq 0 ] && ok "no $V privacy/DoT/DNS-forcing rule matches the full tvs set" \
    || no "$BADSCOPE rule(s) match @tvs for $V privacy - other TVs would be affected"

  echo
  echo "=== Pi-hole layer ($V) ==="
  PRIVACY_ROOT="$ROOT" PRIVACY_VENDOR="$V" PRIVACY_TIER="$TIER" python3 - <<'PYEOF'
import json, os, urllib.request, urllib.error, yaml
ROOT = os.environ["PRIVACY_ROOT"]; V = os.environ["PRIVACY_VENDOR"]; TIER = os.environ["PRIVACY_TIER"]
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
        with urllib.request.urlopen(r, data) as resp:
            raw = resp.read().decode()
            return (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        try: return json.loads(e.read().decode() or "{}")
        except Exception: return {}
try:
    res = req("POST", "/api/auth", {"password": pw})
    sid = res.get("session", {}).get("sid")
except Exception:
    print("  FAIL: Pi-hole API unreachable"); raise SystemExit
inst = yaml.safe_load(open(os.path.join(ROOT, "config", "privacy-instances.yaml")))["instances"][V]
GNAME = inst.get("pihole_group", "TVGuard-Privacy-%s" % V.upper())
groups = {g["name"]: g["id"] for g in req("GET", "/api/groups", None, sid).get("groups", [])}
gid = groups.get(GNAME)
if gid is None:
    print("  FAIL: group %s missing" % GNAME); raise SystemExit
print("  PASS: group %s present (id %d)" % (GNAME, gid))
# (FTL here ignores `offset` on /api/domains - single expanding-limit fetch)
all_rows, flimit = [], 1000
while True:
    rows = req("GET", "/api/domains?limit=%d" % flimit, None, sid).get("domains", [])
    if not isinstance(rows, list):
        rows = []
    if len(rows) < flimit:
        all_rows.extend(rows)
        break
    flimit *= 4
    if flimit > 100000:
        all_rows.extend(rows)
        break
mine = [d for d in all_rows if gid in (d.get("groupIDs") or d.get("groups") or [])]
print("  %d rows in group" % len(mine))
clients = req("GET", "/api/clients", None, sid).get("clients", [])
attached = [c.get("client") for c in clients if gid in c.get("groups", [])]
print("  attached clients: %s" % (", ".join(attached) or "none"))
resolved = json.load(open(os.path.join(ROOT, "data", "privacy-policy", "resolved.json")))
vs = (resolved.get("vendors") or {}).get(V, {})
sec = vs.get(TIER, {})
mine_names = {str(m["domain"]).lower() for m in mine}
missing = [d for d in sec.get("domains", []) if d.lower() not in mine_names]
if missing:
    print("  WARN: %d resolved domains not found in group: %s" % (len(missing), ", ".join(missing[:5])))
else:
    print("  PASS: all %d tier domains present in group" % len(sec.get("domains", [])))
rx = sec.get("regexes") or []
if rx:
    rx_missing = [r["pattern"] for r in rx if r["pattern"].lower() not in mine_names]
    if rx_missing:
        print("  WARN: %d regex denies not found in group: %s" % (len(rx_missing), ", ".join(rx_missing[:5])))
    else:
        print("  PASS: all %d regex (suffix/zone-family) denies present in group" % len(rx))
allows = sec.get("allows") or []
if allows:
    allow_missing = [a for a in allows if a.lower() not in mine_names]
    if allow_missing:
        print("  WARN: %d allow rows missing from group (may pre-exist globally): %s" % (len(allow_missing), ", ".join(allow_missing[:5])))
    else:
        print("  PASS: all %d allow rows present in group (keep wins)" % len(allows))
PYEOF

  echo
  echo "=== TV path + keeps ($V) ==="
  V="$V" RES="$ROOT/data/privacy-policy/resolved.json" LAN_PREFIX="$LAN_PREFIX" python3 - <<'PYEOF'
import json, os, re, subprocess, sys
ROOT = os.environ["RES"]
d = json.load(open(ROOT))
v = os.environ["V"]
vs = d["vendors"][v]
lan = os.environ.get("LAN_PREFIX", "")
for ip in vs.get("applies_to", []):
    out = subprocess.run(["conntrack", "-L"], capture_output=True, text=True).stdout
    hits = [l for l in out.splitlines() if ip in l and (not lan or lan not in l.replace(ip, ""))][:3]
    if hits:
        print("  PASS: %s has active NATed connections through this host" % ip)
        for h in hits: print("    " + h)
    else:
        print("  (no active %s conntrack entries right now - normal if the TV is idle; check TVGUARD-NEW counter)" % ip)
# vendor keep names must still resolve (host-level sanity; group rules are client-scoped)
import subprocess
keepd = vs.get("keep", {}).get("domains", [])[:6]
for k in keepd:
    out = subprocess.run(["dig", "+short", "+time=5", "+tries=2", "@127.0.0.1", k],
                         capture_output=True, text=True).stdout.strip()
    # scan ALL lines: the first line is often a CNAME, the A record follows it
    ip = next((ln for ln in out.splitlines() if re.match(r"^\d{1,3}(?:\.\d{1,3}){3}$", ln)), "")
    if ip:
        print("  PASS: keep %s resolves (%s)" % (k, ip))
    else:
        print("  WARN: keep %s does not resolve from host (baseline answer: %r)" % (k, out[:40]))
PYEOF
  D=$(dmesg 2>/dev/null | tail -2000 | grep -c "TVGUARD-PRIVACY-$U ")
  echo "  TVGUARD-PRIVACY-$U drop events in recent kernel log: $D"
done <<< "$STATE_ROWS"

echo
echo "=== host services regression ==="
$SCRIPT_DIR/health-check.sh >/tmp/priv-live-hc.txt 2>&1 && ok "health-check: ALL CHECKS PASSED" || { no "health-check reported failures"; tail -5 /tmp/priv-live-hc.txt | sed 's/^/    /'; }

echo
echo "==================================="
echo "server-side result: $PASS passed, $FAIL failed"
echo
echo "PHYSICAL TV TESTS (only you can do these - per active vendor above):"
echo "  Samsung: home screen, YouTube, Plex, casting, app store, account screens;"
echo "  voice: expected NOT to work under standard-no-voice/strict/manufacturer-lockdown."
echo "  LG (once enabled): home screen, LG Channels, YouTube, Plex, Prime, Netflix,"
echo "  casting/AirPlay, Content Store, firmware check, LG account; cloud voice: FAIL is expected."
echo
echo "If anything breaks: sudo scripts/privacy-policy-disable.sh <vendor>  (per-vendor rollback)"
echo "Then run: sudo scripts/privacy-watch.sh 30   (safety watch after re-enabling)"
