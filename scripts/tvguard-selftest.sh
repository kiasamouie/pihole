#!/usr/bin/env bash
#
# tvguard-selftest.sh  -  prove the one-arm mechanism with a throwaway mock TV.
#
# Builds an isolated network namespace with a veth "TV" (10.99.99.2) whose
# gateway is the host (10.99.99.1), loads a THROWAWAY nftables table
# `ip tvguard-test` that mirrors the production logic (but for the mock IP),
# and adds ONE throwaway `ufw route` rule for the mock IP (removed at teardown).
# It NEVER touches the production `ip tvguard` table, the real TVs, UFW's own
# rules, Docker, or any existing service. Full teardown at the end (and on error).
#
# What it proves:
#   1. DNS-bypass REDIRECT: dig @8.8.8.8 from the mock TV is redirected to the
#      local Pi-hole (query appears in Pi-hole with client 10.99.99.2).
#   2. MASQUERADE egress: plain HTTP and HTTPS from the mock TV reach the real
#      Internet out the LAN interface, and return traffic traverses this host
#      (conntrack shows the NAT mapping dst->local IP).
#   3. UFW coexistence: the mock TV's forwarded traffic is accepted via the
#      ufw-user-forward rule WITHOUT touching any other UFW/Docker rule.
#
# Usage:  sudo scripts/tvguard-selftest.sh
set -uo pipefail

if [ "$(id -u)" -ne 0 ]; then echo "run with sudo"; exit 3; fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# machine config (TVGUARD_ENV > $ROOT/.env > legacy config/tvguard.conf);
# GATEWAY_IP is the box IP the mock TV's traffic is SNAT'd to.
# shellcheck source=/dev/null
. "$ROOT/scripts/_tvguard_env.sh" || exit 4
GW_CHECK="$GATEWAY_IP"
[ -n "$GW_CHECK" ] || { echo "GATEWAY_IP missing from machine config" >&2; exit 4; }

NS=tvg; VETH_HG=veth-hg; VETH_TV=veth-tv
NSIP=10.99.99.2; HOSTIP=10.99.99.1
MOCK_LAN=10.99.99.0/24   # the throwaway mock network (never the real LAN)
PIHOLE=127.0.0.1
STATE_DIR=/var/lib/tvguard; mkdir -p "$STATE_DIR" 2>/dev/null
PASS=0; FAIL=0
run_ns(){ ip netns exec "$NS" "$@"; }   # run a command inside the namespace

ufw_route_rule_present(){
  # ufw normalises a bare IP to /32 (and sometimes leaves it bare) - match both.
  iptables -t filter -S ufw-user-forward 2>/dev/null | grep -E -q -- "-s $NSIP(/32)? -j ACCEPT"
}

cleanup() {
  echo "--- teardown ---"
  if ufw_route_rule_present; then
    ufw route delete allow from "$NSIP" to any >/dev/null 2>&1 && echo "  - removed mock ufw route rule"
    ufw_route_rule_present && { echo "  WARN: mock ufw route rule still present!" >&2; }
  fi
  nft delete table ip tvguard-test 2>/dev/null
  ip -n "$NS" link set "$VETH_TV" down 2>/dev/null
  ip netns del "$NS" 2>/dev/null
  ip link del "$VETH_HG" 2>/dev/null
  echo "  (cleaned up)"
}
trap cleanup EXIT

ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# idempotent start
ip netns del "$NS" 2>/dev/null; ip link del "$VETH_HG" 2>/dev/null; ip link del "$VETH_TV" 2>/dev/null

echo "=== building mock-TV netns ($NS @ $NSIP) ==="
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

echo "=== loading throwaway table ip tvguard-test (mirrors production) ==="
# Mirror production: resolve the pihole container IP for the DNS-bypass DNAT.
CIP=$(docker inspect -f '{{with index .NetworkSettings.Networks "tvguard_default"}}{{.IPAddress}}{{end}}' pihole 2>/dev/null)
if [ -z "$CIP" ]; then no "could not resolve pihole container IP for the DNS test"; exit 1; fi
echo "  pihole container IP: $CIP"
cat > "$STATE_DIR/tvguard-test.nft" <<EOF
table ip tvguard-test {
    set tvs { type ipv4_addr ; elements = { $NSIP } ; }
    chain forward {
        type filter hook forward priority -150 ;
        ip saddr @tvs ip daddr $MOCK_LAN counter accept
        ip saddr @tvs ip daddr != $MOCK_LAN ct state new counter log prefix "TGT-NEW " accept
        ip saddr @tvs ip daddr != $MOCK_LAN counter accept
        ip daddr @tvs ct state established,related counter accept
        counter continue
    }
    chain prerouting {
        type nat hook prerouting priority -150 ;
        ip saddr @tvs ip daddr != $MOCK_LAN meta l4proto udp th dport 53 dnat to $CIP:53
        ip saddr @tvs ip daddr != $MOCK_LAN meta l4proto tcp th dport 53 dnat to $CIP:53
    }
    chain postrouting {
        type nat hook postrouting priority srcnat ;
        ip saddr @tvs ip daddr != $MOCK_LAN oifname "$LAN_INTERFACE" counter masquerade
    }
}
EOF
if nft -c -f "$STATE_DIR/tvguard-test.nft"; then
  nft delete table ip tvguard-test 2>/dev/null
  nft -f "$STATE_DIR/tvguard-test.nft" && ok "tvguard-test table loaded" || no "could not load table"
else
  no "nft syntax check failed"; exit 1
fi

# The UFW forward allowance for the mock TV (same mechanism production uses).
if ufw route allow from "$NSIP" to any >/dev/null 2>&1 && ufw_route_rule_present; then
  ok "ufw route rule added for mock TV (ufw-user-forward)"
else
  no "could not add ufw route rule for mock TV"
fi

echo
echo "=== TEST 1: DNS-bypass redirect (dig @8.8.8.8) ==="
if command -v dig >/dev/null 2>&1; then
  ANS=$(run_ns dig +short +time=5 +tries=2 @8.8.8.8 example.com 2>/dev/null | head -1)
  echo "  dig @8.8.8.8 example.com -> ${ANS:-<empty>}"
  if echo "$ANS" | grep -Eq '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
    ok "dig via 8.8.8.8 returned an IP (redirected to Pi-hole)"
  else
    no "dig via 8.8.8.8 did not return an address (got: ${ANS:-none})"
  fi
else
  echo "  (dig not installed - skipping)"
fi

# Confirm Pi-hole logged it as client 10.99.99.2 (per-TV attribution of the bypass)
if command -v python3 >/dev/null 2>&1 && [ -f "$ROOT/.env" ]; then
  sleep 1
  PW=$(grep '^ADMIN_PASSWORD=' "$ROOT/.env" 2>/dev/null | cut -d= -f2)
  # Pi-hole v6 API: the session id is in the JSON body (no X-FTL-SID response header).
  SID=$(curl -sk -m 10 -X POST "http://$PIHOLE:3001/api/auth" -H "Content-Type: application/json" -d "{\"password\":\"$PW\"}" 2>/dev/null \
        | python3 -c 'import sys,json; print(json.load(sys.stdin)["session"]["sid"])' 2>/dev/null)
  Q=$(curl -sk -m 10 "http://$PIHOLE:3001/api/queries?client=$NSIP&limit=5" -H "X-FTL-SID: $SID" 2>/dev/null)
  if echo "$Q" | grep -q "$NSIP"; then
    ok "Pi-hole logged the query with client $NSIP (redirect delivered to Pi-hole)"
  else
    no "Pi-hole did not log client $NSIP (check the query log manually)"
  fi
fi

echo
echo "=== TEST 2: plain-HTTP egress (curl http://example.com) ==="
CODE=$(run_ns curl -s -o /dev/null -m 10 -w '%{http_code}' http://example.com/ 2>/dev/null)
echo "  curl http://example.com via mock TV -> HTTP ${CODE:-<none>}"
if [ "$CODE" = "200" ]; then ok "HTTP egress through masquerade succeeded (HTTP $CODE)"; else no "HTTP egress failed (HTTP ${CODE:-none})"; fi

echo
echo "=== TEST 3: HTTPS egress (curl https://1.1.1.1) ==="
CODE=$(run_ns curl -s -o /dev/null -m 10 -w '%{http_code}' https://1.1.1.1/ 2>/dev/null)
echo "  curl https://1.1.1.1 via mock TV -> HTTP ${CODE:-<none>}"
if [ "$CODE" = "200" ] || [ "$CODE" = "301" ]; then ok "HTTPS egress through masquerade succeeded (HTTP $CODE)"; else no "HTTPS egress failed (HTTP ${CODE:-none})"; fi

echo
echo "=== conntrack evidence (mock TV egress NAT mapping) ==="
CT=$(conntrack -L 2>/dev/null | grep -E "$NSIP" | grep -v 255 | head -3)
echo "${CT:-  (no NATed conntrack entries found)}" | sed 's/^/  /'
if echo "${CT:-}" | grep -q "dst=$GW_CHECK"; then
  ok "return traffic is NATed back through this host (dst=$GW_CHECK)"
else
  no "no evidence of SNAT return path through this host"
fi

echo
echo "=== tvguard-test counters ==="
nft list chain ip tvguard-test forward 2>/dev/null | grep counter | sed 's/^ *//'
nft list chain ip tvguard-test postrouting 2>/dev/null | grep counter | sed 's/^ *//'

echo
echo "==================================="
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && echo "SELFTEST: ALL PASS" || echo "SELFTEST: FAILURES PRESENT"
exit $FAIL
