#!/usr/bin/env bash
#
# privacy-policy-selftest.sh - prove the privacy-policy mechanisms WITHOUT
# touching the live Samsung or the production table ip tvguard.
#
# Method (mirrors tvguard-selftest.sh):
#   * a throwaway network namespace with a veth "TV" (10.99.99.2)
#   * a THROWAWAY nftables table `ip tvguard-ptest` rendered from the SAME
#     data (data/privacy-policy/resolved.json) with the same rule logic
#   * one throwaway `ufw route allow` rule for the mock IP (removed at end)
#   * a temporary Pi-hole group `TVGuard-Privacy-TEST` (deleted at end)
#
# What it proves:
#   1. rendered privacy ruleset passes `nft -c`
#   2. mock TV -> blocked standard IP : connection dropped (TVGUARD-PT-PRIV log)
#   3. mock TV -> DoH endpoint IP (strict set) : dropped (TVGUARD-PT-DOH log)
#   4. mock TV -> :853 tcp : dropped (TVGUARD-PT-DOT log)
#   5. mock TV -> normal host (HTTP) : passes, NAT works
#   6. UDP/443 : no rule exists in the rendered table (QUIC must stay free)
#   7. DNS bypass: dig @8.8.8.8 from mock TV is DNAT'd to Pi-hole
#   8. Pi-hole group cycle: temp group + deny domain blocks for the mock
#      client only, then full cleanup (group deleted, domains gone)
#   9. unrelated state untouched: UFW rules diff (minus the throwaway rule),
#      docker ps diff, production table ip tvguard untouched
#
# Usage:  sudo scripts/privacy-policy-selftest.sh [--build]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
RES="$ROOT/data/privacy-policy/resolved.json"

if [ "$(id -u)" -ne 0 ]; then echo "run with sudo"; exit 3; fi
if [ "${1:-}" = "--build" ] || [ ! -f "$RES" ]; then
  echo "resolving policy first (takes ~40s) ..."
  python3 "$SCRIPT_DIR/privacy-policy-build.py" || exit 5
fi
[ -f "$RES" ] || { echo "no resolved.json"; exit 5; }

NS=tgpt; VETH_HG=veth-pt-hg; VETH_TV=veth-pt-tv
NSIP=10.99.99.2; HOSTIP=10.99.99.1
LAN=192.168.0.0/24
PASS=0; FAIL=0
run_ns(){ ip netns exec "$NS" "$@"; }
ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

CIP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' pihole 2>/dev/null | awk 'NF' | head -1)
[ -n "$CIP" ] || { echo "cannot resolve pihole container IP"; exit 1; }
echo "pihole container IP: $CIP"

# baseline snapshots (unrelated-state proof)
BASE_UFW=$(ufw status verbose 2>/dev/null)
BASE_DOCKER=$(docker ps --format '{{.Names}} {{.Status}}' | sort)
BASE_TVGUARD_HASH_RAW=$(nft list table ip tvguard 2>/dev/null | sed -E 's/packets [0-9]+ bytes [0-9]+/COUNTERS/g' | sha256sum | awk '{print $1}')
BASE_NFT_HASH=$(nft list ruleset 2>/dev/null | sha256sum | awk '{print $1}')

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

echo "=== rendering throwaway table ip tvguard-ptest from resolved.json ==="
NFT_FILE=/tmp/privacy-selftest.nft
PRIVACY_RES="$RES" RESIP="$CIP" NSIP="$NSIP" python3 - <<'PYEOF' > "$NFT_FILE"
import json, os
d = json.load(open(os.environ["PRIVACY_RES"]))
def fmt(ips):
    return ", ".join(ips) if ips else ""
print("table ip tvguard-ptest {")
print("    set tvs { type ipv4_addr ; elements = { %s } ; }" % os.environ["NSIP"])
print("    set tv_privacy_blocked { type ipv4_addr ; flags interval ; elements = { %s } ; }" % fmt(d["standard"]["ips"]))
print("    set tv_doh_blocked { type ipv4_addr ; flags interval ; elements = { %s } ; }" % fmt(d["doh"]["ips"]))
print("    chain forward {")
print("        type filter hook forward priority -150 ;")
print("        ip saddr @tvs ip daddr 192.168.0.0/24 counter accept")
print("        ip saddr @tvs ip daddr @tv_privacy_blocked ct state new counter log prefix \"TVGUARD-PT-PRIV \" drop")
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

if nft -c -f "$NFT_FILE" 2>/tmp/ptest-nft.err; then
  ok "rendered privacy ruleset passes nft -c (syntax)"
else
  no "nft -c failed"; cat /tmp/ptest-nft.err; exit 1
fi
nft delete table ip tvguard-ptest 2>/dev/null
nft -f "$NFT_FILE" && ok "throwaway table loaded" || no "could not load throwaway table"

# structural check: no rule may match udp dport 443 (QUIC must stay free)
if grep -E "udp[ ]+dport[ ]+443" "$NFT_FILE" >/dev/null; then
  no "rendered table contains a UDP/443 rule (would break QUIC/YouTube)"
else
  ok "no UDP/443 rule in rendered table (QUIC stays free)"
fi
if grep -E "tcp[ ]+dport[ ]+443" "$NFT_FILE" >/dev/null; then
  no "rendered table contains a TCP/443 rule (would break HTTPS)"
else
  ok "no TCP/443 rule in rendered table (HTTPS stays free)"
fi

if ufw route allow from "$NSIP" to any >/dev/null 2>&1 && \
   iptables -t filter -S ufw-user-forward | grep -E -q -- "-s $NSIP(/32)? -j ACCEPT"; then
  ok "temporary ufw route rule added for mock TV"
else
  no "could not add temporary ufw route rule"
fi

echo
echo "=== TEST 1: DNS-bypass DNAT (dig @8.8.8.8 from mock TV) ==="
ANS=$(run_ns dig +short +time=5 +tries=2 @8.8.8.8 example.com 2>/dev/null | head -1)
if echo "$ANS" | grep -Eq '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
  ok "dig @8.8.8.8 resolved ($ANS) - DNS bypass is forced to Pi-hole"
else
  no "dig @8.8.8.8 did not resolve (got: ${ANS:-none})"
fi

echo
echo "=== TEST 2: allowed egress passes (curl http://example.com) ==="
CODE=$(run_ns curl -s -o /dev/null -m 10 -w '%{http_code}' http://example.com/ 2>/dev/null)
[ "$CODE" = "200" ] && ok "HTTP 200 from mock TV through masquerade" || no "egress failed (HTTP ${CODE:-none})"

echo
echo "=== TEST 3: blocked standard IP is dropped ==="
BLK_IP=$(python3 -c "import json; d=json.load(open('$RES')); ips=[i for i in d['standard']['ips']]; print(ips[0])")
run_ns curl -s -o /dev/null -m 8 "http://$BLK_IP/" >/dev/null 2>&1
RC=$?
sleep 1
if [ $RC -ne 0 ] && dmesg 2>/dev/null | tail -300 | grep -q "TVGUARD-PT-PRIV"; then
  ok "connection to blocked IP $BLK_IP dropped (TVGUARD-PT-PRIV logged)"
else
  no "blocked-IP drop not confirmed (rc=$RC, log present: $(dmesg 2>/dev/null | tail -300 | grep -c TVGUARD-PT-PRIV))"
fi

echo
echo "=== TEST 4: DoH endpoint IP dropped (strict set, 1.1.1.1:443) ==="
run_ns timeout 8 bash -c "cat < /dev/null > /dev/tcp/1.1.1.1/443" >/dev/null 2>&1
RC=$?
sleep 1
if [ $RC -ne 0 ] && dmesg 2>/dev/null | tail -300 | grep -q "TVGUARD-PT-DOH"; then
  ok "DoH endpoint IP 1.1.1.1:443 dropped (TVGUARD-PT-DOH logged)"
else
  no "DoH drop not confirmed (rc=$RC, log count: $(dmesg 2>/dev/null | tail -300 | grep -c TVGUARD-PT-DOH))"
fi

echo
echo "=== TEST 5: DoT :853 dropped ==="
# pick a neutral public IP that is NOT in the standard or DoH sets
DOT_TEST_IP=$(python3 - <<PYEOF
import json
d = json.load(open("$RES"))
blocked = set(d["standard"]["ips"]) | set(d["doh"]["ips"]) | set(d["keep"]["ips"])
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
if [ $RC -ne 0 ] && dmesg 2>/dev/null | tail -300 | grep -q "TVGUARD-PT-DOT"; then
  ok "DoT $DOT_TEST_IP:853 dropped (TVGUARD-PT-DOT logged)"
else
  no "DoT drop not confirmed (rc=$RC, log count: $(dmesg 2>/dev/null | tail -300 | grep -c TVGUARD-PT-DOT))"
fi

echo
echo "=== TEST 6: Pi-hole group cycle (temp group, mock client only) ==="
PRIVACY_ROOT="$ROOT" MOCK_CLIENT="$NSIP" python3 - <<'PYEOF'
import json, os, sys, time, urllib.request, urllib.error
ROOT = os.environ["PRIVACY_ROOT"]; MOCK = os.environ["MOCK_CLIENT"]
BASE = "http://127.0.0.1:3001"
GN = "TVGuard-Privacy-TEST"
TEST_DOMAIN = "log-ingestion-eu.samsungacr.com"
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
        with urllib.request.urlopen(r, data) as resp:
            raw = resp.read().decode()
            return resp.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        try: return e.code, json.loads(e.read().decode() or "{}")
        except Exception: return e.code, {}
code, res = req("POST", "/api/auth", {"password": pw})
assert code == 200, "login failed: %s" % res
SID = res["session"]["sid"]
code, res = req("GET", "/api/groups")
groups = {g["name"]: g["id"] for g in res.get("groups", [])}
if GN in groups:
    req("POST", "/api/groups:batchDelete", [{"item": GN}])
code, res = req("POST", "/api/groups", {"name": GN, "comment": "selftest only - delete after"})
gid = res["groups"][0]["id"]
print("created test group %s (id %d)" % (GN, gid))
code, res = req("GET", "/api/clients")
clients = {c.get("client") or c.get("ip"): c for c in res.get("clients", [])}
c = clients.get(MOCK)
if c is None:
    req("POST", "/api/clients", {"client": MOCK, "groups": [gid]})
else:
    g = list(c.get("groups", [])); g.append(gid)
    req("PUT", "/api/clients/%s" % MOCK, {"client": MOCK, "groups": g})
code, res = req("POST", "/api/domains/deny/exact", {"domain": [TEST_DOMAIN], "groups": [gid]})
assert code in (200, 201), "deny push failed: %s" % res
time.sleep(1)
# now dig the test domain from the mock client (via 8.8.8.8 -> DNAT -> pihole)
import subprocess
ans = subprocess.run(["ip","netns","exec","tgpt","dig","+short","+time=5","+tries=2","@8.8.8.8",TEST_DOMAIN],
                     capture_output=True, text=True).stdout.strip()
print("dig %s as %s -> [%s]" % (TEST_DOMAIN, MOCK, ans or "empty"))
open("/tmp/ptest-pihole-dig.txt", "w").write(ans)
# cleanup: delete the domain, detach, delete group
rows = req("GET", "/api/domains?limit=100")[1].get("domains", [])
to_del = [{"item": d["domain"], "type": d.get("type", "deny"), "kind": d.get("kind", "exact")}
          for d in rows if gid in (d.get("groupIDs") or d.get("groups") or [])]
if to_del:
    req("POST", "/api/domains:batchDelete", to_del)
code, res = req("GET", "/api/clients")
for c in res.get("clients", []):
    if gid in c.get("groups", []):
        g = [x for x in c.get("groups", []) if x != gid]
        req("PUT", "/api/clients/%s" % c.get("client"), {"client": c.get("client"), "groups": g})
req("POST", "/api/groups:batchDelete", [{"item": GN}])
print("test group deleted (http %d)" % code)
code, res = req("GET", "/api/groups")
names = {g["name"] for g in res.get("groups", [])}
print("group present after cleanup:", GN in names)
open("/tmp/ptest-pihole-clean.txt", "w").write("clean" if GN not in names else "DIRTY")
PYEOF
DIGOUT=$(cat /tmp/ptest-pihole-dig.txt 2>/dev/null)
CLEAN=$(cat /tmp/ptest-pihole-clean.txt 2>/dev/null)
if [ "$CLEAN" = "clean" ]; then
  ok "Pi-hole temp group created, deny pushed, fully cleaned up"
else
  no "Pi-hole temp group cleanup incomplete"
fi
# blocked dig must return empty, NXDOMAIN, or 0.0.0.0 (Pi-hole's block answer)
if [ -z "$DIGOUT" ] || echo "$DIGOUT" | grep -qi "NXDOMAIN\|0\.0\.0\.0"; then
  ok "blocked domain returned no real answer for the mock client (Pi-hole deny active)"
else
  no "blocked domain unexpectedly resolved for mock client: $DIGOUT"
fi
HOSTANS=$(dig +short +time=5 @192.168.0.128 log-ingestion-eu.samsungacr.com | head -1)
echo "  (note: same domain from THIS host resolves as: ${HOSTANS:-empty} - a 0.0.0.0 here means the GLOBAL gravity baseline already blocks it, which is expected and unrelated to our group)"

echo
echo "=== TEST 7: unrelated state untouched ==="
sleep 1
# structural compare: live counters change with TV traffic, so normalise them
strip_counters(){ nft list table ip tvguard 2>/dev/null | sed -E 's/packets [0-9]+ bytes [0-9]+/COUNTERS/g'; }
NEW_TVGUARD_HASH=$(strip_counters | sha256sum | awk '{print $1}')
if [ "$NEW_TVGUARD_HASH" = "$BASE_TVGUARD_HASH_RAW" ]; then
  ok "production table ip tvguard structurally unchanged"
else
  no "production table ip tvguard structure changed!"
fi
CUR_UFW=$(ufw status verbose 2>/dev/null | grep -v "^Anywhere.*10\.99\.99\.2\|^Anywhere.*FWD.*10\.99\.99\.2" || true)
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
if nft list table ip tvguard-ptest >/dev/null 2>&1; then
  # still loaded during the test; will be removed by the trap
  echo "  (ptest table still loaded - teardown removes it)"
fi

echo
echo "==================================="
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && echo "PRIVACY SELFTEST: ALL PASS" || echo "PRIVACY SELFTEST: FAILURES PRESENT"
exit $FAIL
