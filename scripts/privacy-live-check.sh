#!/usr/bin/env bash
#
# privacy-live-check.sh - verify a privacy policy that has been ENABLED.
#
# Run AFTER:  sudo scripts/privacy-policy-apply.sh standard|standard-no-voice|strict|manufacturer-lockdown
#
# It checks everything that can be checked from the server side and ends with
# the list of physical TV tests only YOU can perform (it cannot click the TV).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
STATE_DIR=/var/lib/tvguard
PASS=0; FAIL=0
ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

PRIVACY=$(sed -n 's/^PRIVACY=//p' "$STATE_DIR/privacy-state" 2>/dev/null | tail -1)
echo "privacy state: ${PRIVACY:-off}"
[ "$PRIVACY" = "off" ] && { echo "policy is OFF - nothing to verify. (This script is for post-enable checks.)"; exit 0; }

echo
echo "=== 1. firewall layer ==="
T=$(nft list table ip tvguard 2>/dev/null)
echo "$T" | grep -q "tv_privacy_blocked" && ok "tv_privacy_blocked set present" || no "tv_privacy_blocked set missing"
if [ "$PRIVACY" = "strict" ]; then
  echo "$T" | grep -q "tv_doh_blocked" && ok "tv_doh_blocked set present (strict)" || no "tv_doh_blocked missing (strict expected)"
else
  if echo "$T" | grep -q "tv_doh_blocked"; then
    no "tv_doh_blocked present but not expected in $PRIVACY (DoH-IP set is strict-only)"
  else
    ok "no DoH-IP set (correct for $PRIVACY)"
  fi
fi
echo "$T" | grep -q "TVGUARD-PRIVACY " && ok "privacy drop rule present" || no "privacy drop rule missing"
echo "$T" | grep -q "TVGUARD-DOT " && ok "DoT :853 drop rule present" || no "DoT drop rule missing"
if echo "$T" | grep -Eq '(tcp|udp)[[:space:]]+dport[[:space:]]+443'; then
  no "a rule touches TCP/443 or UDP/443 (would break HTTPS/QUIC)"
else
  ok "no rule touches TCP/443 or UDP/443 (HTTPS + QUIC stay free)"
fi
echo "$T" | grep -q "masquerade" && ok "NAT/masquerade intact" || no "masquerade missing - check TVGuard!"
echo "$T" | grep -q "dport 53 dnat" && ok "DNS-bypass DNAT intact" || no "DNS DNAT missing - check TVGuard!"
N=$(echo "$T" | sed -n '/set tv_privacy_blocked/,/}/p' | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort -u | wc -l)
echo "  deny-IP count in firewall: $N"
# Scope check: privacy/DoT/DNS-forcing rules must match ONLY the policy's
# applies_to list (tv_privacy set), never the full tvs set (which may
# include other TVs like the Google TV .90).
if echo "$T" | grep -q 'set tv_privacy {'; then
  SCOPE_EXPECT=$(python3 -c '
targets, in_list = [], False
for line in open(__import__("sys").argv[1]):
    s = line.strip()
    if s.startswith("applies_to:"):
        in_list = True; continue
    if in_list:
        if s.startswith("- "):
            item = s[2:].split("#", 1)[0].strip().strip(chr(34))
            if item:
                targets.append(item)
        elif s and not s.startswith("#"):
            in_list = False
print(" ".join(sorted(targets)))
' "$ROOT/config/privacy-policy.yaml" 2>/dev/null)
  SCOPE_ACTUAL=$(echo "$T" | sed -n '/set tv_privacy {/,/}/p' | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*//g')
  SCOPE_EXPECT_NORM=$(echo "$SCOPE_EXPECT" | sed 's/[[:space:]]*//g')
  [ "$SCOPE_ACTUAL" = "$SCOPE_EXPECT_NORM" ] \
    && ok "tv_privacy scope = applies_to only ($SCOPE_ACTUAL) - other household clients unaffected by the privacy layer" \
    || no "tv_privacy scope mismatch: set={$SCOPE_ACTUAL} vs applies_to={$SCOPE_EXPECT_NORM}"
else
  no "tv_privacy scope set missing (privacy rules not scoped to applies_to)"
fi
BADSCOPE=$(echo "$T" | grep -E 'ip saddr @tvs' | grep -E 'tv_privacy_blocked|dport 853|dport 53' | wc -l)
[ "$BADSCOPE" -eq 0 ] && ok "no privacy/DoT/DNS-forcing rule matches the full tvs set" \
  || no "$BADSCOPE rule(s) still match @tvs for privacy/DoT/DNS-forcing - other TVs would be affected"

echo
echo "=== 2. Pi-hole layer ==="
PRIVACY_ROOT="$ROOT" PRIVACY_TIER="$PRIVACY" python3 - <<'PYEOF'
import json, os, urllib.request, urllib.error
ROOT = os.environ["PRIVACY_ROOT"]; TIER = os.environ["PRIVACY_TIER"]
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
res = req("POST", "/api/auth", {"password": pw})
sid = res.get("session", {}).get("sid")
groups = {g["name"]: g["id"] for g in req("GET", "/api/groups", None, sid).get("groups", [])}
gid = groups.get("TVGuard-Privacy")
if gid is None:
    print("  FAIL: group TVGuard-Privacy missing"); raise SystemExit
print("  PASS: group TVGuard-Privacy present (id %d)" % gid)
rows = req("GET", "/api/domains?limit=100", None, sid).get("domains", [])
mine = [d["domain"] for d in rows if gid in (d.get("groupIDs") or d.get("groups") or [])]
print("  %d domains in group" % len(mine))
clients = req("GET", "/api/clients", None, sid).get("clients", [])
attached = [c.get("client") for c in clients if gid in c.get("groups", [])]
print("  attached clients: %s" % (", ".join(attached) or "none"))
resolved = json.load(open(os.path.join(ROOT, "data", "privacy-policy", "resolved.json")))
mine_names = set(mine)
missing = [d for d in resolved[TIER]["domains"] if d not in mine_names]
if missing:
    print("  WARN: %d resolved domains not found in group: %s" % (len(missing), ", ".join(missing[:5])))
else:
    print("  PASS: all tier domains present in group")
rx = resolved[TIER].get("regexes") or []
if not rx:
    print("  (no regex/suffix entries in this tier - nothing to check)")
else:
    rx_missing = [r["pattern"] for r in rx if r["pattern"] not in mine_names]
    if rx_missing:
        print("  WARN: %d regex denies not found in group: %s" % (len(rx_missing), ", ".join(rx_missing[:5])))
    else:
        print("  PASS: all %d regex (suffix/zone-family) denies present in group" % len(rx))
allows = resolved[TIER].get("allows") or []
if allows:
    allow_missing = [a for a in allows if a.lower() not in {m.lower() for m in mine_names}]
    if allow_missing:
        print("  WARN: %d allow rows missing from group (may pre-exist globally): %s" % (len(allow_missing), ", ".join(allow_missing[:5])))
    else:
        print("  PASS: all %d allow rows present in group (keep wins)" % len(allows))
else:
    print("  (no allow rows in this tier)")
PYEOF

echo
echo "=== 3. TV path still alive ==="
C=$(conntrack -L 2>/dev/null | grep "192\.168\.0\.197" | grep -v "192\.168\.0\.197.*192\.168\.0\." | head -3)
if [ -n "$C" ]; then
  ok "Samsung .197 has active NATed connections through this host"
  echo "$C" | sed 's/^/    /'
else
  echo "  (no active Samsung conntrack entries right now - normal if the TV is idle; check TVGUARD-NEW counter instead)"
fi
L=$(dmesg 2>/dev/null | tail -2000 | grep -c "TVGUARD-PRIVACY ")
echo "  TVGUARD-PRIVACY drop events in recent kernel log: $L"
D=$(dmesg 2>/dev/null | tail -2000 | grep -c "TVGUARD-DOT ")
echo "  TVGUARD-DOT drop events in recent kernel log: $D"

echo
echo "=== 4. host services regression ==="
$SCRIPT_DIR/health-check.sh >/tmp/priv-live-hc.txt 2>&1 && ok "health-check: ALL CHECKS PASSED" || { no "health-check reported failures"; tail -5 /tmp/priv-live-hc.txt | sed 's/^/    /'; }

echo
echo "==================================="
echo "server-side result: $PASS passed, $FAIL failed"
echo
echo "PHYSICAL TV TESTS (only you can do these, on the Samsung):"
echo "  1. Home screen idle 2 min - apps load, EPG/TV Plus channels list works"
echo "  2. YouTube: open, play a video, seek, close"
echo "  3. Plex: open, play something"
echo "  4. Casting from a phone (if you use it)"
echo "  5. App store opens and lists apps"
if [ "$PRIVACY" = "standard" ]; then
  echo "  6. (standard) voice search: should still work - confirm one command"
else
  echo "  6. ($PRIVACY) voice: expected NOT to work (intended Bixby/voice-cloud block) - confirm everything else works"
fi
if [ "$PRIVACY" = "manufacturer-lockdown" ]; then
  echo "  7. Unknown Samsung denies: sudo scripts/show-unknown-samsung.sh 24"
  echo "     then decide each one: sudo scripts/manufacturer-review.sh keep|block <domain> [reason]"
fi
echo
echo "If anything breaks: sudo scripts/privacy-policy-disable.sh (one command, full privacy rollback)"
echo "Then run: sudo scripts/privacy-watch.sh 30   (safety watch after re-enabling)"
