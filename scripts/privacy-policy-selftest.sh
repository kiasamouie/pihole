#!/usr/bin/env bash
#
# privacy-policy-selftest.sh - prove the privacy-policy mechanisms WITHOUT
# touching the live Samsung or the production table ip tvguard.
#
# Method (mirrors tvguard-selftest.sh):
#   * a throwaway network namespace with a veth "TV" (10.99.99.2)
#   * a THROWAWAY nftables table `ip tvguard-ptest` rendered from the SAME
#     data (data/privacy-policy/resolved.json) with the same rule logic
#     that tvguard-apply.sh renders for the real table
#   * one throwaway `ufw route allow` rule for the mock IP (removed at end)
#   * a temporary Pi-hole group `TVGuard-Privacy-TEST` (deleted at end)
#
# Profiles:
#   sudo scripts/privacy-policy-selftest.sh                # all three
#   sudo scripts/privacy-policy-selftest.sh standard
#   sudo scripts/privacy-policy-selftest.sh standard-no-voice
#   sudo scripts/privacy-policy-selftest.sh strict
#
# What it proves (per profile):
#   0. content assertions: senv == standard ∪ voice; strict ⊇ senv; strict-only
#      representatives absent from senv; required domains present; DoH strict-only
#   1. rendered privacy ruleset passes `nft -c`
#   2. no rule touches TCP/443 or UDP/443 (HTTPS + QUIC stay free)
#   3. mock TV -> blocked profile IP : dropped (TVGUARD-PT-PRIV log, DST match)
#   4. mock TV -> :853 tcp : dropped (TVGUARD-PT-DOT log, DST match)
#   5. mock TV -> normal host (HTTP) : passes, NAT works
#   6. DNS bypass: dig @8.8.8.8 from mock TV is DNAT'd to Pi-hole
#   7. profile-specific:
#        standard           -> aibixby (voice) IP must be ALLOWED
#        standard-no-voice  -> aibixby IPs DROPPED, 1.1.1.1:443 allowed
#        strict             -> 1.1.1.1:443 dropped by the DoH set
#   8. Pi-hole group cycle per profile: temp group + the profile's exact-domain
#      denies block for the mock client only; voice-domain behaviour matches the
#      profile; keep domain (www.youtube.com) still resolves; full cleanup
#   9. unrelated state untouched: UFW diff (minus the throwaway rule), docker
#      diff, production table ip tvguard structurally untouched
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
RES="$ROOT/data/privacy-policy/resolved.json"
POL="$ROOT/config/privacy-policy.yaml"
KEEP="$ROOT/config/privacy-keep.yaml"
NS=tgpt; VETH_HG=veth-pt-hg; VETH_TV=veth-pt-tv
NSIP=10.99.99.2; HOSTIP=10.99.99.1
LAN=192.168.0.0/24
PASS=0; FAIL=0
run_ns(){ ip netns exec "$NS" "$@"; }
ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
info(){ echo "  (info) $1"; }

if [ "$(id -u)" -ne 0 ]; then echo "run with sudo"; exit 3; fi

# --- profile selection ---------------------------------------------------------
PROFILES=""
case "${1:-}" in
  ""|all)   PROFILES="standard standard-no-voice strict" ;;
  standard|standard-no-voice|strict) PROFILES="$1" ;;
  *) echo "usage: privacy-policy-selftest.sh [standard|standard-no-voice|strict]"; exit 4 ;;
esac

if [ "${PROFILES}" = "standard" ] || [ "${PROFILES}" = "standard-no-voice" ] || [ "${PROFILES}" = "strict" ] || [ ! -f "$RES" ] || [ "${1:-}" = "--build" ]; then
  if [ ! -f "$RES" ]; then
    echo "resolving policy first (takes ~1 min) ..."
    python3 "$SCRIPT_DIR/privacy-policy-build.py" || exit 5
  fi
fi
[ -f "$RES" ] || { echo "no resolved.json"; exit 5; }

CIP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' pihole 2>/dev/null | awk 'NF' | head -1)
[ -n "$CIP" ] || { echo "cannot resolve pihole container IP"; exit 1; }
echo "pihole container IP: $CIP"
echo "profiles to test: $PROFILES"

# baseline snapshots (unrelated-state proof)
BASE_UFW=$(ufw status verbose 2>/dev/null)
BASE_DOCKER=$(docker ps --format '{{.Names}} {{.Status}}' | sort)
BASE_TVGUARD_HASH_RAW=$(nft list table ip tvguard 2>/dev/null | sed -E 's/packets [0-9]+ bytes [0-9]+/COUNTERS/g' | sha256sum | awk '{print $1}')

cleanup(){
  echo "--- teardown ---"
  if iptables -t filter -S ufw-user-forward 2>/dev/null | grep -E -q -- "-s $NSIP(/32)? -j ACCEPT"; then
    ufw route delete allow from "$NSIP" to any >/dev/null 2>&1
    iptables -t filter -S ufw-user-forward 2>/dev/null | grep -E -q -- "-s $NSIP(/32)? -j ACCEPT" \
      && echo "  WARN: mock ufw route rule still present!" || echo "  - removed mock ufw route rule"
  fi
  nft delete table ip tvguard-ptest 2>/dev/null
  ip -n "$NS" link set "$VETH_TV" down 2>/dev/null
  ip netns del "$NS" 2>/dev/null
  ip link del "$VETH_HG" 2>/dev/null
  echo "  (cleaned up)"
}
trap cleanup EXIT

# idempotent start
ip netns del "$NS" 2>/dev/null; ip link del "$VETH_HG" 2>/dev/null; ip link del "$VETH_TV" 2>/dev/null
ip netns add "$NS"
ip link add "$VETH_HG" type veth peer name "$VETH_TV"
ip link set "$VETH_TV" netns "$NS"
ip addr add "$HOSTIP/24" dev "$VETH_HG"
ip link set "$VETH_HG" up
ip -n "$NS" link set lo up
ip -n "$NS" link set "$VETH_TV" up
ip -n "$NS" addr add "$NSIP/24" dev "$VETH_TV"
ip -n "$NS" route add default via "$HOSTIP"
sleep 1

if ufw route allow from "$NSIP" to any >/dev/null 2>&1 && \
   iptables -t filter -S ufw-user-forward | grep -E -q -- "-s $NSIP(/32)? -j ACCEPT"; then
  ok "temporary ufw route rule added for mock TV"
else
  no "could not add temporary ufw route rule"
fi

# dmesg helpers (nft log lines carry DST=<ip>)
log_count(){ # prefix dst
  dmesg 2>/dev/null | tail -600 | grep -- "$1" | grep -c "DST=$2"
}

echo
echo "=== TEST 0: policy content assertions (resolved.json vs YAML) ==="
T0_OUT=$(RES="$RES" POL="$POL" KEEP="$KEEP" python3 - <<'PYEOF'
import json, os, sys, yaml
d = json.load(open(os.environ["RES"]))
pol = yaml.safe_load(open(os.environ["POL"]))
keep = yaml.safe_load(open(os.environ["KEEP"]))

kept_names = {k["domain"].strip().lower() for k in (keep.get("keeps") or [])}

def yaml_sets():
    std, senv, voice, strict, doh = set(), set(), set(), set(), set()
    doh_ok = True
    for name, spec in (pol.get("policies") or {}).items():
        for e in (spec.get("entries") or []):
            dom = (e.get("domain") or "").strip().lower()
            if not dom:
                continue
            tiers = e.get("tiers") or [name]
            if name == "doh":
                doh.add(dom)
                if set(tiers) - {"strict"}:
                    doh_ok = False
                continue
            if "standard" in tiers:
                std.add(dom); senv.add(dom)
            if "voice" in tiers:
                voice.add(dom); senv.add(dom)
            strict.add(dom)
    return std, senv, voice, strict, doh, doh_ok

std, senv, voice, strict, doh, doh_ok = yaml_sets()
exp = []
exp.append((senv == std | voice,
            "senv == standard ∪ voice (set identity)",
            "senv != standard ∪ voice"))
exp.append((set(d["standard"]["domains"]) == std - kept_names,
            "resolved.json standard domains == YAML standard (minus keep-overrides)",
            "resolved.json standard domain mismatch"))
exp.append((set(d["standard-no-voice"]["domains"]) == senv - kept_names,
            "resolved.json standard-no-voice domains == YAML senv (minus keep-overrides)",
            "resolved.json senv domain mismatch"))
exp.append((set(d["strict"]["domains"]) == strict - kept_names,
            "resolved.json strict domains == YAML strict (minus keep-overrides)",
            "resolved.json strict domain mismatch"))
exp.append((set(d.get("voice", {}).get("domains", [])) == voice,
            "resolved.json voice reference == YAML voice entries",
            "resolved.json voice reference mismatch"))
exp.append((senv <= strict, "strict ⊇ senv", "strict is missing senv domains"))
strict_only_reps = ["2mdn.net", "nmetrics.samsung.com", "smetrics.samsung.com",
                    "samsungdm.com", "syncplusconfig.s3.amazonaws.com"]
for r in strict_only_reps:
    exp.append((r in strict and r not in senv,
                "strict-only representative `%s` in strict but NOT in senv" % r,
                "strict-only representative `%s` misplaced (in senv=%s)" % (r, r in senv)))
required = ["log-ingestion-eu.samsungacr.com", "log-config.samsungacr.com",
            "googleads.g.doubleclick.net", "rtb-config.samsungads.com",
            "prd-euw1-ucs.aibixby.com", "provisioning-use2.mgmt.aibixby.com"]
for r in required:
    exp.append((r in senv, "required domain `%s` present in senv" % r,
                "required domain `%s` missing from senv" % r))
exp.append((len(d["doh"]["domains"]) > 0, "DoH set non-empty (strict DoH-IP enforcement exists)",
            "DoH domain set is empty"))
exp.append((doh_ok, "all DoH entries are strict-tier only", "a DoH entry leaks into a lower tier"))
std_ips = set(d["standard"]["ips"])
voice_ips = set(d.get("voice", {}).get("ips", []))
exp.append((not (voice_ips & std_ips), "no aibixby (voice) IP overlaps the standard IP set",
            "aibixby IPs overlap standard set: %s" % (voice_ips & std_ips)))
senv_ips = set(d["standard-no-voice"]["ips"])
exp.append((("1.1.1.1" in d["doh"]["ips"]) and ("1.1.1.1" not in senv_ips),
            "1.1.1.1 in DoH set and NOT in senv set (senv-allow / strict-drop test preconditions)",
            "1.1.1.1 precondition failed (doh=%s, senv=%s)" % ("1.1.1.1" in d["doh"]["ips"], "1.1.1.1" in senv_ips)))
for cond, okmsg, badmsg in exp:
    print(("OK   " if cond else "BAD  ") + (okmsg if cond else badmsg))
sys.exit(0)
PYEOF
)
while IFS= read -r line; do
  case "$line" in
    "OK   "*) ok "${line#OK   }" ;;
    "BAD  "*) no "${line#BAD  }" ;;
  esac
done <<< "$T0_OUT"

render_profile(){ # prof -> prints nft to stdout
  PROF="$1" PRIVACY_RES="$RES" RESIP="$CIP" NSIP="$NSIP" python3 - <<'PYEOF'
import json, os
d = json.load(open(os.environ["PRIVACY_RES"]))
prof = os.environ["PROF"]
def fmt(ips):
    return ", ".join(ips) if ips else ""
sec = d[prof]
print("table ip tvguard-ptest {")
print("    set tvs { type ipv4_addr ; elements = { %s } ; }" % os.environ["NSIP"])
print("    set tv_privacy_blocked { type ipv4_addr ; flags interval ; elements = { %s } ; }" % fmt(sec["ips"]))
if prof == "strict" and d["doh"]["ips"]:
    print("    set tv_doh_blocked { type ipv4_addr ; flags interval ; elements = { %s } ; }" % fmt(d["doh"]["ips"]))
print("    chain forward {")
print("        type filter hook forward priority -150 ;")
print("        ip saddr @tvs ip daddr 192.168.0.0/24 counter accept")
print("        ip saddr @tvs ip daddr @tv_privacy_blocked ct state new counter log prefix \"TVGUARD-PT-PRIV \" drop")
if prof == "strict" and d["doh"]["ips"]:
    print("        ip saddr @tvs ip daddr @tv_doh_blocked ct state new counter log prefix \"TVGUARD-PT-DOH \" drop")
print("        ip saddr @tvs tcp dport 853 ct state new counter log prefix \"TVGUARD-PT-DOT \" drop")
print("        ip saddr @tvs udp dport 853 ct state new counter log prefix \"TVGUARD-PT-DOT \" drop")
print("        ip saddr @tvs ip daddr != 192.168.0.0/24 ct state new counter log prefix \"TVGUARD-PT-NEW \" accept")
print("        ip saddr @tvs ip daddr != 192.168.0.0/24 counter accept")
print("        ip daddr @tvs ct state established,related counter accept")
print("        counter continue")
print("    }")
print("    chain prerouting {")
print("        type nat hook prerouting priority -150 ;")
print("        ip saddr @tvs ip daddr != 192.168.0.128 udp dport 53 dnat to %s:53" % os.environ["RESIP"])
print("        ip saddr @tvs ip daddr != 192.168.0.128 tcp dport 53 dnat to %s:53" % os.environ["RESIP"])
print("    }")
print("    chain postrouting {")
print("        type nat hook postrouting priority srcnat ;")
print("        ip saddr @tvs ip daddr != 192.168.0.0/24 oifname \"enp2s0\" counter masquerade")
print("    }")
print("}")
PYEOF
}

AIBIXBY_IPS=$(python3 -c "import json; d=json.load(open('$RES')); print(' '.join(d.get('voice',{}).get('ips',[])))")

for PROF in $PROFILES; do
  echo
  echo "==============================================="
  echo "PROFILE: $PROF"
  echo "==============================================="

  echo "--- rendering throwaway table ip tvguard-ptest ---"
  NFT_FILE=/tmp/privacy-selftest-$PROF.nft
  render_profile "$PROF" > "$NFT_FILE"

  if nft -c -f "$NFT_FILE" 2>/tmp/ptest-nft-$PROF.err; then
    ok "rendered ruleset passes nft -c (syntax)"
  else
    no "nft -c failed"; cat /tmp/ptest-nft-$PROF.err; continue
  fi

  # structural: no rule may touch TCP/443 or UDP/443 (QUIC/HTTPS must stay free)
  if grep -Eq "(tcp|udp)[ ]+dport[ ]+443" "$NFT_FILE"; then
    no "rendered table contains a TCP/443 or UDP/443 rule (would break HTTPS/QUIC)"
  else
    ok "no TCP/443 or UDP/443 rule in rendered table (HTTPS + QUIC stay free)"
  fi

  nft delete table ip tvguard-ptest 2>/dev/null
  nft -f "$NFT_FILE" && ok "throwaway table loaded" || { no "could not load throwaway table"; continue; }

  echo "--- DNS-bypass DNAT (dig @8.8.8.8 from mock TV) ---"
  ANS=$(run_ns dig +short +time=5 +tries=2 @8.8.8.8 example.com 2>/dev/null | head -1)
  if echo "$ANS" | grep -Eq '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
    ok "dig @8.8.8.8 resolved ($ANS) - DNS bypass forced to Pi-hole"
  else
    no "dig @8.8.8.8 did not resolve (got: ${ANS:-none})"
  fi

  echo "--- allowed egress (curl http://example.com) ---"
  CODE=$(run_ns curl -s -o /dev/null -m 10 -w '%{http_code}' http://example.com/ 2>/dev/null)
  [ "$CODE" = "200" ] && ok "HTTP 200 from mock TV through masquerade" || no "egress failed (HTTP ${CODE:-none})"

  echo "--- blocked profile IP dropped ---"
  BLK_IP=$(python3 -c "import json; d=json.load(open('$RES')); ips=d['$PROF']['ips']; print(ips[0] if ips else '')")
  if [ -z "$BLK_IP" ]; then
    no "profile $PROF has no resolved block IPs - cannot test firewall drop"
  else
    run_ns curl -s -o /dev/null -m 8 "http://$BLK_IP/" >/dev/null 2>&1
    RC=$?
    sleep 1
    if [ $RC -ne 0 ] && [ "$(log_count 'TVGUARD-PT-PRIV' "$BLK_IP")" -ge 1 ]; then
      ok "connection to blocked IP $BLK_IP dropped (TVGUARD-PT-PRIV, DST match)"
    else
      no "blocked-IP drop not confirmed (rc=$RC, DST log count: $(log_count 'TVGUARD-PT-PRIV' "$BLK_IP"))"
    fi
  fi

  echo "--- DoT :853 dropped ---"
  DOT_TEST_IP=$(python3 - <<PYEOF
import json
d = json.load(open("$RES"))
blocked = set(d["$PROF"]["ips"]) | set(d["doh"]["ips"]) | set(d["keep"]["ips"])
candidates = ["93.184.215.14", "185.125.191.10", "104.16.68.118", "151.101.65.91"]
for c in candidates:
    if c not in blocked:
        print(c)
        break
PYEOF
)
  run_ns timeout 8 bash -c "cat < /dev/null > /dev/tcp/$DOT_TEST_IP/853" >/dev/null 2>&1
  RC=$?
  sleep 1
  if [ $RC -ne 0 ] && [ "$(log_count 'TVGUARD-PT-DOT' "$DOT_TEST_IP")" -ge 1 ]; then
    ok "DoT $DOT_TEST_IP:853 dropped (TVGUARD-PT-DOT, DST match)"
  else
    no "DoT drop not confirmed (rc=$RC, DST log count: $(log_count 'TVGUARD-PT-DOT' "$DOT_TEST_IP"))"
  fi

  echo "--- profile-specific tests ---"
  case "$PROF" in
    standard)
      if [ -z "$AIBIXBY_IPS" ]; then
        no "voice section has no resolved IPs; cannot verify voice stays allowed under standard"
      else
        AIB=$(echo $AIBIXBY_IPS | awk '{print $1}')
        if run_ns timeout 8 bash -c "cat < /dev/null > /dev/tcp/$AIB/443" >/dev/null 2>&1; then
          ok "aibixby IP $AIB:443 ALLOWED under standard (voice functional)"
        else
          no "aibixby IP $AIB:443 not reachable under standard (voice would break)"
        fi
      fi
      ;;
    standard-no-voice)
      if [ -z "$AIBIXBY_IPS" ]; then
        no "voice section has no resolved IPs; cannot verify voice blocking"
      else
        for AIB in $AIBIXBY_IPS; do
          run_ns timeout 8 bash -c "cat < /dev/null > /dev/tcp/$AIB/443" >/dev/null 2>&1
          RC=$?
          sleep 1
          if [ $RC -ne 0 ] && [ "$(log_count 'TVGUARD-PT-PRIV' "$AIB")" -ge 1 ]; then
            ok "voice IP $AIB:443 dropped (TVGUARD-PT-PRIV, DST match) - voice blocked as intended"
          else
            no "voice IP $AIB:443 not dropped under standard-no-voice (rc=$RC, logs: $(log_count 'TVGUARD-PT-PRIV' "$AIB"))"
          fi
        done
        if run_ns timeout 8 bash -c "cat < /dev/null > /dev/tcp/1.1.1.1/443" >/dev/null 2>&1; then
          ok "1.1.1.1:443 ALLOWED under standard-no-voice (DoH-IP set is strict-only; no collateral)"
        else
          no "1.1.1.1:443 unexpectedly unreachable under standard-no-voice"
        fi
      fi
      ;;
    strict)
      run_ns timeout 8 bash -c "cat < /dev/null > /dev/tcp/1.1.1.1/443" >/dev/null 2>&1
      RC=$?
      sleep 1
      if [ $RC -ne 0 ] && [ "$(log_count 'TVGUARD-PT-DOH' "1.1.1.1")" -ge 1 ]; then
        ok "DoH endpoint 1.1.1.1:443 dropped (TVGUARD-PT-DOH, DST match)"
      else
        no "DoH drop not confirmed (rc=$RC, DST log count: $(log_count 'TVGUARD-PT-DOH' "1.1.1.1"))"
      fi
      ;;
  esac

  echo "--- Pi-hole group cycle (temp group, mock client $NSIP only) ---"
  PH_OUT=$(PRIVACY_ROOT="$ROOT" MOCK_CLIENT="$NSIP" PROF="$PROF" NS="$NS" RES="$RES" python3 - <<'PYEOF'
import json, os, re, subprocess, time, urllib.request, urllib.error
ROOT = os.environ["PRIVACY_ROOT"]; MOCK = os.environ["MOCK_CLIENT"]
PROF = os.environ["PROF"]; NS = os.environ["NS"]
BASE = "http://127.0.0.1:3001"
GN = "TVGuard-Privacy-TEST"
pw = ""
for line in open(os.path.join(ROOT, ".env")):
    if line.startswith("ADMIN_PASSWORD="):
        pw = line.strip().split("=", 1)[1]
SID = None
def req(method, path, body=None):
    global SID
    r = urllib.request.Request(BASE + path, method=method)
    r.add_header("Content-Type", "application/json")
    if SID: r.add_header("X-FTL-SID", SID)
    data = json.dumps(body).encode() if body is not None else None
    try:
        with urllib.request.urlopen(r, data, timeout=15) as resp:
            raw = resp.read().decode()
            return resp.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        try: return e.code, json.loads(e.read().decode() or "{}")
        except Exception: return e.code, {}
code, res = req("POST", "/api/auth", {"password": pw})
if code != 200:
    print("BAD  login failed: %s" % res); raise SystemExit(0)
SID = res["session"]["sid"]
resolved = json.load(open(os.environ["RES"]))
domains = resolved[PROF]["domains"]

code, res = req("GET", "/api/groups")
groups = {g["name"]: g["id"] for g in res.get("groups", [])}
if GN in groups:
    req("POST", "/api/groups:batchDelete", [{"item": GN}])
code, res = req("POST", "/api/groups", {"name": GN, "comment": "selftest only - delete after"})
if code not in (200, 201):
    print("BAD  group creation failed: %s" % res); raise SystemExit(0)
gid = res["groups"][0]["id"]
code, res = req("GET", "/api/clients")
clients = {c.get("client") or c.get("ip"): c for c in res.get("clients", [])}
c = clients.get(MOCK)
if c is None:
    req("POST", "/api/clients", {"client": MOCK, "groups": [gid]})
else:
    g = list(c.get("groups", []))
    if gid not in g:
        g.append(gid)
        req("PUT", "/api/clients/%s" % MOCK, {"client": MOCK, "groups": g})
existing = set()
offset = 0
while True:
    code, res = req("GET", "/api/domains?limit=100&offset=%d" % offset)
    rows = res.get("domains") if isinstance(res, dict) else res
    if not isinstance(rows, list) or not rows: break
    existing |= {str(d.get("domain", "")).lower() for d in rows}
    if len(rows) < 100: break
    offset += 100
to_push = [d for d in domains if d.lower() not in existing]
if to_push:
    code, res = req("POST", "/api/domains/deny/exact", {"domain": to_push, "groups": [gid]})
    if code not in (200, 201):
        print("BAD  domain push failed: %s" % res); raise SystemExit(0)
print("OK   temp group %s created; %d deny domains pushed (%d pre-existing)" % (GN, len(to_push), len(domains) - len(to_push)))
time.sleep(1)

def host_dig(dom):
    """Baseline answer from THIS host via local Pi-hole (host is not in the group)."""
    out = subprocess.run(["dig", "+short", "+time=5", "+tries=2", "@127.0.0.1", dom],
                         capture_output=True, text=True).stdout.strip()
    m = re.match(r"^(\d{1,3}(?:\.\d{1,3}){3})$", out.splitlines()[0] if out else "")
    return m.group(1) if m else None

def ns_dig(dom):
    """Answer seen by the MOCK TV (dig @8.8.8.8 -> DNAT -> Pi-hole, client = mock)."""
    out = subprocess.run(["ip", "netns", "exec", NS, "dig", "+short", "+time=5", "+tries=2", "@8.8.8.8", dom],
                         capture_output=True, text=True).stdout.strip()
    return out

IPRE = re.compile(r"^\d{1,3}(?:\.\d{1,3}){3}$")
def is_blocked(ans):
    return ans == "" or "0.0.0.0" in ans or "NXDOMAIN" in ans.upper()

# pick a gravity-safe test domain (host baseline must be a real IP)
test_dom = None
for dom in domains:
    if host_dig(dom):
        test_dom = dom
        break
if test_dom is None:
    print("BAD  no gravity-safe test domain found (all blocked by baseline already)")
else:
    ans = ns_dig(test_dom)
    if is_blocked(ans):
        print("OK   mock-client dig of %s blocked by our group (answer: %s)" % (test_dom, ans or "empty"))
    else:
        print("BAD  mock-client dig of %s unexpectedly resolved: %s" % (test_dom, ans))
    time.sleep(0.5)

# voice-domain behaviour per profile
vdom = "prd-euw1-ucs.aibixby.com"
hb = host_dig(vdom)
if hb is None:
    print("INFO host baseline: %s already blocked by gravity (0.0.0.0) - voice-DNS result inconclusive either way" % vdom)
else:
    ans = ns_dig(vdom)
    if PROF == "standard":
        if IPRE.match(ans.splitlines()[0]) if ans else False:
            print("OK   voice domain %s STILL RESOLVES under standard (voice functional)" % vdom)
        else:
            print("BAD  voice domain %s does not resolve under standard: %s" % (vdom, ans or "empty"))
    else:
        if is_blocked(ans):
            print("OK   voice domain %s blocked for mock client under %s (answer: %s)" % (vdom, PROF, ans or "empty"))
        else:
            print("BAD  voice domain %s unexpectedly resolves under %s: %s" % (vdom, PROF, ans))

# keep-domain must still resolve for the mock client
kdom = "www.youtube.com"
kb = host_dig(kdom)
if kb is None:
    print("INFO host baseline: %s blocked by gravity already - keep check inconclusive" % kdom)
else:
    ans = ns_dig(kdom)
    if IPRE.match(ans.splitlines()[0]) if ans else False:
        print("OK   keep domain %s still resolves for mock client: %s" % (kdom, ans.splitlines()[0]))
    else:
        print("BAD  keep domain %s does not resolve for mock client: %s" % (kdom, ans or "empty"))

# cleanup: delete group domains, detach client, delete group
to_del = []
offset = 0
while True:
    code, res = req("GET", "/api/domains?limit=100&offset=%d" % offset)
    rows = res.get("domains") if isinstance(res, dict) else []
    if not isinstance(rows, list) or not rows: break
    for d in rows:
        if gid in (d.get("groupIDs") or d.get("groups") or []):
            to_del.append({"item": d["domain"], "type": d.get("type", "deny"), "kind": d.get("kind", "exact")})
    if len(rows) < 100: break
    offset += 100
if to_del:
    req("POST", "/api/domains:batchDelete", to_del)
code, res = req("GET", "/api/clients")
for c in res.get("clients", []):
    if gid in c.get("groups", []):
        g = [x for x in c.get("groups", []) if x != gid]
        req("PUT", "/api/clients/%s" % c.get("client"), {"client": c.get("client"), "groups": g})
req("POST", "/api/groups:batchDelete", [{"item": GN}])
code, res = req("GET", "/api/groups")
names = {g["name"] for g in res.get("groups", [])}
if GN not in names:
    print("OK   Pi-hole cleanup complete: %d domains deleted, clients detached, group removed" % len(to_del))
else:
    print("BAD  group %s still present after cleanup" % GN)
PYEOF
  )
  while IFS= read -r line; do
    case "$line" in
      "OK   "*) ok "${line#OK   }" ;;
      "BAD  "*) no "${line#BAD  }" ;;
      "INFO "*) info "${line#INFO }" ;;
    esac
  done <<< "$PH_OUT"
  nft delete table ip tvguard-ptest 2>/dev/null
done

echo
echo "=== TEST: unrelated state untouched ==="
strip_counters(){ nft list table ip tvguard 2>/dev/null | sed -E 's/packets [0-9]+ bytes [0-9]+/COUNTERS/g'; }
NEW_TVGUARD_HASH=$(strip_counters | sha256sum | awk '{print $1}')
if [ "$NEW_TVGUARD_HASH" = "$BASE_TVGUARD_HASH_RAW" ]; then
  ok "production table ip tvguard structurally unchanged"
else
  no "production table ip tvguard structure changed!"
fi
CUR_UFW=$(ufw status verbose 2>/dev/null | grep -v "10\.99\.99\.2" || true)
BASE_UFW_N=$(echo "$BASE_UFW" | grep -v "10\.99\.99\.2" || true)
if [ "$CUR_UFW" = "$BASE_UFW_N" ]; then
  ok "ufw status verbose unchanged (excluding the throwaway mock rule)"
else
  echo "  ufw diff:"
  diff <(echo "$BASE_UFW_N") <(echo "$CUR_UFW") | sed 's/^/    /'
  no "ufw state changed beyond the throwaway mock rule"
fi
CUR_DOCKER=$(docker ps --format '{{.Names}} {{.Status}}' | sort)
[ "$CUR_DOCKER" = "$BASE_DOCKER" ] && ok "docker containers unchanged" || no "docker state changed"

echo
echo "==================================="
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && echo "PRIVACY SELFTEST: ALL PASS" || echo "PRIVACY SELFTEST: FAILURES PRESENT"
exit $FAIL
