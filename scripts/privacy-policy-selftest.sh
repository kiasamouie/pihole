#!/usr/bin/env bash
#
# privacy-policy-selftest.sh - prove the multi-vendor privacy-policy
# mechanisms WITHOUT touching the live Samsung/LG TVs or the production
# table ip tvguard.
#
# Method (mirrors tvguard-selftest.sh, per vendor):
#   * a throwaway network namespace with a veth "TV" (10.99.99.2)
#   * a THROWAWAY nftables table `ip tvguard-ptest` rendered from the SAME
#     data (data/privacy-policy/resolved.json, vendors.<vendor> sections)
#     with the same rule logic that tvguard-apply.sh renders for the real
#     table (per-vendor client/deny/DoH sets)
#   * one throwaway `ufw route allow` rule for the mock IP (removed at end)
#   * a temporary Pi-hole group per vendor (TVGuard-Privacy-TEST /
#     TVGuard-Privacy-TEST-LG), deleted at end
#
# Usage:
#   sudo scripts/privacy-policy-selftest.sh                 # all vendors, all profiles
#   sudo scripts/privacy-policy-selftest.sh samsung         # samsung only
#   sudo scripts/privacy-policy-selftest.sh lg              # lg only
#   (a vendor's profiles always run as a set: standard, standard-no-voice,
#    strict, manufacturer-lockdown)
#
# What it proves (per vendor):
#   0. content assertions: senv == standard ∪ voice; strict ⊇ senv; strict-only
#      representatives absent from senv; required domains present; DoH strict-only;
#      suffix (regex) entries correct per vendor (samsung: aibixby.com; lg:
#      alphonso.tv + lgsmartad.com); manufacturer-lockdown invariants (zones,
#      allow rows, keep hosts, no lookaround, zone whitelist from the registry);
#      LG time/OTA/store keeps absent from every deny set
#   1. rendered privacy ruleset passes `nft -c`
#   2. no rule touches TCP/443 or UDP/443 (HTTPS + QUIC stay free)
#   3. mock TV -> blocked profile IP : dropped (TVGUARD-PT-PRIV log, DST match)
#   4. mock TV -> :853 tcp : dropped (TVGUARD-PT-DOT log)
#   5. mock TV -> normal host (HTTP) : passes, NAT works
#   6. DNS bypass: dig @8.8.8.8 from mock TV is DNAT'd to Pi-hole
#   7. profile-specific:
#        samsung: standard -> aibixby voice IP allowed; senv/mlock -> dropped;
#                 strict -> 1.1.1.1:443 dropped by the DoH set
#        lg:      standard -> ACR alphonso.tv IP allowed; senv/mlock -> dropped;
#                 strict -> 1.1.1.1:443 dropped; LG keep hosts (time/OTA/store)
#                 must be firewalled-allowed in EVERY profile
#   8. Pi-hole group cycle per vendor: temp group + the profile's exact-domain
#      denies block for the mock client only; per-vendor voice/ACR behaviour;
#      zone-regex probe (unclassified vendor host denied ONLY under mlock);
#      keep hosts still resolve (keep wins); full cleanup
#   9. unrelated state untouched: UFW diff (minus the throwaway rule), docker
#      diff, production table ip tvguard structurally untouched
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/_tvguard_env.sh" || exit 4
RES="$ROOT/data/privacy-policy/resolved.json"
NS=tgpt; VETH_HG=veth-pt-hg; VETH_TV=veth-pt-tv
NSIP=10.99.99.2; HOSTIP=10.99.99.1
MOCK_LAN=10.99.99.0/24   # the throwaway mock network (never the real LAN)
PASS=0; FAIL=0
run_ns(){ ip netns exec "$NS" "$@"; }
ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
info(){ echo "  (info) $1"; }

if [ "$(id -u)" -ne 0 ]; then echo "run with sudo"; exit 3; fi

# --- vendor selection ---------------------------------------------------------
VENDORS=""
case "${1:-}" in
  ""|all)   VENDORS="samsung lg" ;;
  samsung|lg) VENDORS="$1" ;;
  *) echo "usage: privacy-policy-selftest.sh [all|samsung|lg]"; exit 4 ;;
esac

[ -f "$RES" ] || python3 "$SCRIPT_DIR/privacy-policy-build.py" || exit 5
[ -f "$RES" ] || { echo "no resolved.json"; exit 5; }

for v in $VENDORS; do
  RES="$RES" V="$v" python3 - <<'PYEOF' || exit 5
import json, os, sys
d = json.load(open(os.environ["RES"]))
v = os.environ["V"]
if v not in (d.get("vendors") or {}):
    sys.exit("vendor %s missing from resolved.json (registry/build mismatch)" % v)
PYEOF
done

CIP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' pihole 2>/dev/null | awk 'NF' | head -1)
[ -n "$CIP" ] || { echo "cannot resolve pihole container IP"; exit 1; }
echo "pihole container IP: $CIP"
echo "vendors to test: $VENDORS"

# baseline snapshots (unrelated-state proof)
docker_norm(){ docker ps --format '{{.Names}} {{.Status}}' | sort | sed -E 's/Up [0-9]+ (second|minute|hour|day|week|month|year)s? (ago )?/Up /'; }
BASE_UFW=$(ufw status verbose 2>/dev/null)
BASE_DOCKER=$(docker_norm)
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
echo "=== TEST 0: policy content assertions (per vendor) ==="
T0_OUT=$(VENDORS="$VENDORS" ROOT="$ROOT" RES="$RES" python3 - <<'PYEOF'
import json, os, re as _re, sys, yaml
ROOT = os.environ["ROOT"]; RES = os.environ["RES"]
inst = yaml.safe_load(open(os.path.join(ROOT, "config", "privacy-instances.yaml"))).get("instances") or {}
d = json.load(open(RES))
sel = os.environ.get("VENDORS", "samsung lg").split()

for v in sel:
    cfg = inst.get(v)
    if cfg is None:
        print("BAD  vendor %s missing from privacy-instances.yaml" % v); continue
    vres = (d.get("vendors") or {}).get(v)
    if vres is None:
        print("BAD  vendor %s missing from resolved.json" % v); continue
    pol = yaml.safe_load(open(os.path.join(ROOT, cfg["policy"])))
    keep = yaml.safe_load(open(os.path.join(ROOT, cfg["keep"])))
    manuf = yaml.safe_load(open(os.path.join(ROOT, cfg["manufacturer"])))
    mkeepd = yaml.safe_load(open(os.path.join(ROOT, cfg["manufacturer_keep"])))
    known = {z.lower() for z in (cfg.get("known_zones") or [])}
    kept_names = {k["domain"].strip().lower() for k in (keep.get("keeps") or [])}
    zones = {z["domain"].strip().lower() for z in (manuf.get("deny_default_zones") or [])}
    mk = {k["domain"].strip().lower() for k in (mkeepd.get("keeps") or [])}

    def yaml_sets(pol):
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

    std, senv, voice, strict, doh, doh_ok = yaml_sets(pol)
    def names_of(sec):
        sec = sec or {}
        return set(sec.get("domains", [])) | {r["name"] for r in (sec.get("regexes") or [])}
    def rx_names(sec):
        return {r["name"] for r in ((sec or {}).get("regexes") or [])}
    def zof(dd, zz):
        for z in sorted(zz, key=len, reverse=True):
            if dd == z or dd.endswith("." + z):
                return z
        return None

    def p(c, a, b):
        print(("OK   " if c else "BAD  ") + ("[%s] " % v) + (a if c else b))
    p(senv == std | voice, "senv == standard ∪ voice (set identity)", "senv != standard ∪ voice")
    p(names_of(vres["standard"]) == std - kept_names, "resolved.json standard == YAML standard (minus keep-overrides)", "resolved.json standard domain mismatch")
    p(names_of(vres["standard-no-voice"]) == senv - kept_names, "resolved.json senv == YAML senv (minus keep-overrides)", "resolved.json senv domain mismatch")
    p(names_of(vres["strict"]) == strict - kept_names, "resolved.json strict == YAML strict (minus keep-overrides)", "resolved.json strict domain mismatch")
    p(names_of(vres.get("voice")) == voice, "resolved.json voice reference == YAML voice entries", "resolved.json voice reference mismatch")
    p(senv <= strict, "strict ⊇ senv", "strict is missing senv domains")
    p(len(vres["doh"]["domains"]) > 0, "DoH set non-empty", "DoH domain set is empty")
    p(doh_ok, "all DoH entries are strict-tier only", "a DoH entry leaks into a lower tier")
    p(zones <= known, "all manufacturer zones are in the vendor's known_zones (registry whitelist)",
      "unknown zone(s) in %s: %s" % (cfg["manufacturer"], sorted(zones - known)))
    for h in sorted(mk):
        p(zof(h, zones) is not None, "manufacturer-keep %s is inside a deny zone" % h,
          "manufacturer-keep host outside any deny zone: %s" % h)
    for k in sorted(kept_names):
        zz = zof(k, zones)
        if zz is not None:
            p(k in mk, "privacy-keep %s (zone %s) is in manufacturer-keep" % (k, zz),
              "privacy-keep %s would be denied by zone %s - add to manufacturer-keep" % (k, zz))
    m = vres.get("manufacturer-lockdown")
    p(m is not None, "resolved.json has a manufacturer-lockdown section", "manufacturer-lockdown section missing")
    if m:
        p(set(m.get("domains", [])) >= set(vres["standard-no-voice"]["domains"]), "mlock domains ⊇ senv domains", "mlock lost senv domains")
        p(set(m.get("ips", [])) >= set(vres["standard-no-voice"]["ips"]), "mlock IPs ⊇ senv IPs (no unrelated firewall change)", "mlock IP set diverged below senv")
        p({r["name"] for r in (m.get("regexes") or [])} >= {r["name"] for r in (vres["standard-no-voice"].get("regexes") or [])}, "mlock regexes ⊇ senv regexes", "mlock missing senv regexes")
        p(set(m.get("allows", [])) == mk, "mlock allows == manufacturer-keep hosts", "mlock allows diverged: %s" % sorted(set(m.get("allows", [])) ^ mk))
        zrx = {r["name"]: r["pattern"] for r in (m.get("regexes") or [])}
        for z in sorted(zones):
            pat = zrx.get(z)
            if pat is None:
                if z in rx_names(vres["standard-no-voice"]):
                    continue  # a policy suffix entry already carries this zone's regex
                p(False, "a zone regex was generated for %s" % z, "no zone regex for %s" % z); continue
            try:
                ok_probe = _re.match(pat, "zz9probe." + z) is not None
                ok_apex = _re.match(pat, z) is not None
            except _re.error as e:
                p(False, "zone regex for %s compiles: %s" % (z, e), "zone regex for %s invalid: %s" % (z, e)); continue
            p(ok_probe and ok_apex, "zone regex %s matches probe + apex (deny works)" % z,
              "zone regex %s fails probe/apex" % z)
            for h in [x for x in sorted(mk) if zof(x, {z}) == z]:
                p(h in m.get("allows", []), "keep host %s protected by an allow row (allow beats the zone deny)" % h,
                  "keep host %s has no allow row - the zone regex would deny it" % h)
        for r in (m.get("regexes") or []):
            p("(?!" not in r["pattern"] and "(?=" not in r["pattern"],
              "regex %s uses no lookaround (this FTL build rejects it)" % r["name"],
              "regex %s uses lookaround - this FTL build rejects it" % r["name"])

    if v == "samsung":
        strict_only_reps = ["2mdn.net", "nmetrics.samsung.com", "smetrics.samsung.com",
                            "samsungdm.com", "syncplusconfig.s3.amazonaws.com"]
        required = ["log-ingestion-eu.samsungacr.com", "log-config.samsungacr.com",
                    "googleads.g.doubleclick.net", "rtb-config.samsungads.com",
                    "prd-euw1-ucs.aibixby.com", "provisioning-use2.mgmt.aibixby.com"]
        p(rx_names(vres["standard-no-voice"]) == {"aibixby.com"},
          "senv carries exactly the aibixby.com suffix regex (voice v2)", "senv suffix-regex set wrong: %s" % sorted(rx_names(vres["standard-no-voice"])))
        p(not rx_names(vres["standard"]), "plain standard carries no suffix regex (voice must stay functional)", "suffix regex leaked into standard: %s" % sorted(rx_names(vres["standard"])))
        p("aibixby.com" in rx_names(vres["strict"]), "strict carries the aibixby.com suffix regex", "strict missing the aibixby.com suffix regex")
        p(rx_names(vres["strict"]) <= {"aibixby.com"}, "strict carries no new family zone regexes (no leak)", "strict regex set changed: %s" % sorted(rx_names(vres["strict"]) - {"aibixby.com"}))
        std_ips = set(vres["standard"]["ips"]); voice_ips = set(vres.get("voice", {}).get("ips", []))
        p(not (voice_ips & std_ips), "no aibixby (voice) IP overlaps the standard IP set", "aibixby IPs overlap standard set")
        p(("1.1.1.1" in vres["doh"]["ips"]) and ("1.1.1.1" not in set(vres["standard-no-voice"]["ips"])),
          "1.1.1.1 in DoH set and NOT in senv set (test preconditions)", "1.1.1.1 precondition failed")
    elif v == "lg":
        p({"alphonso.tv", "lgsmartad.com"} <= rx_names(vres["standard-no-voice"]),
          "senv carries the alphonso.tv + lgsmartad.com suffix regexes (ACR rotation + ad zone)", "senv missing LG suffix regexes: %s" % sorted(rx_names(vres["standard-no-voice"])))
        p(rx_names(vres["standard"]) <= {"alphonso.tv", "lgsmartad.com"},
          "standard carries no unexpected suffix regexes", "unexpected standard suffixes: %s" % sorted(rx_names(vres["standard"]) - {"alphonso.tv", "lgsmartad.com"}))
        p("alphonso.tv" in rx_names(vres["strict"]), "strict carries the alphonso.tv suffix regex", "strict missing alphonso.tv suffix")
        strict_only_reps = ["aic.lgtviot.com", "kic.wiseconfig.lgtvcommon.com", "eic.homeprv.lgtvcommon.com",
                            "aic.lgeapi.com", "kic.lgthinq.com"]
        required = ["eu-acr1.alphonso.tv", "eic.cdpbeacon.lgtvcommon.com",
                    "lgads.tv", "eic.lgtviot.com", "eic.nudge.lgtvcommon.com"]
        critical_keeps = ["gb.lgtvsdp.com", "gb.nextlgsdp.com", "su.lge.com", "snu.lge.com",
                          "ngfts.lge.com", "gfts.lge.com", "api.lgappstv.com", "tv.wiselg.com",
                          "eic-ngfts.tv.wiselg.com", "security.lgtvsdp.com"]
        all_deny = set(vres["strict"]["domains"]) | {r["name"] for r in (vres["strict"].get("regexes") or [])}
        # a critical keep must NOT be in any firewall deny set; if it sits inside
        # a mlock deny zone (tv.wiselg.com) it must have an allow row
        for ck in critical_keeps:
            in_zone = zof(ck, zones)
            p(ck not in all_deny and (in_zone is None or ck in mk),
              "critical LG keep %s is not in any deny set (or allow-row protected)" % ck,
              "critical LG keep %s IS in a deny set - time/OTA/store would break" % ck)
        for ck in ["tv.wiselg.com", "eic-ngfts.tv.wiselg.com"]:
            p(ck in (m.get("allows", []) if m else []), "wiselg keep %s has an allow row in mlock" % ck, "wiselg keep %s lacks an allow row" % ck)
    for r in strict_only_reps:
        p(r in strict and r not in senv, "strict-only representative `%s` in strict but NOT in senv" % r,
          "strict-only representative `%s` misplaced (in senv=%s)" % (r, r in senv))
    for r in required:
        p(r in senv, "required domain `%s` present in senv" % r, "required domain `%s` missing from senv" % r)

s = (d.get("vendors") or {}).get("samsung")
if s:
    p(d.get("standard") == s["standard"] and d.get("manufacturer-lockdown") == s["manufacturer-lockdown"],
      "legacy top-level samsung aliases mirror vendors.samsung", "legacy aliases diverged from vendors.samsung")
sys.exit(0)
PYEOF
)
while IFS= read -r line; do
  case "$line" in
    "OK   "*) ok "${line#OK   }" ;;
    "BAD  "*) no "${line#BAD  }" ;;
  esac
done <<< "$T0_OUT"

render_vendor_profile(){ # vendor prof -> prints nft to stdout
  VENDOR="$1" PROF="$2" PRIVACY_RES="$RES" RESIP="$CIP" NSIP="$NSIP" \
  BOXIP="$HOSTIP" MOCK_LAN="$MOCK_LAN" EGRESS_IF="$LAN_INTERFACE" python3 - <<'PYEOF'
import json, os
d = json.load(open(os.environ["PRIVACY_RES"]))
v = os.environ["VENDOR"]; prof = os.environ["PROF"]
vs = d["vendors"][v]
def fmt(ips):
    return ", ".join(ips) if ips else ""
sec = vs[prof]
box = os.environ["BOXIP"]; mlan = os.environ["MOCK_LAN"]; egress = os.environ["EGRESS_IF"]
print("table ip tvguard-ptest {")
print("    set tvs { type ipv4_addr ; elements = { %s } ; }" % os.environ["NSIP"])
print("    set tv_privacy_blocked_%s { type ipv4_addr ; flags interval ; elements = { %s } ; }" % (v, fmt(sec["ips"])))
if prof == "strict" and vs["doh"]["ips"]:
    print("    set tv_doh_blocked_%s { type ipv4_addr ; flags interval ; elements = { %s } ; }" % (v, fmt(vs["doh"]["ips"])))
print("    chain forward {")
print("        type filter hook forward priority -150 ;")
print("        ip saddr @tvs ip daddr %s counter accept" % mlan)
if sec["ips"]:
    print("        ip saddr @tvs ip daddr @tv_privacy_blocked_%s ct state new counter log prefix \"TVGUARD-PT-PRIV-%s \" drop" % (v, v.upper()))
if prof == "strict" and vs["doh"]["ips"]:
    print("        ip saddr @tvs ip daddr @tv_doh_blocked_%s ct state new counter log prefix \"TVGUARD-PT-DOH-%s \" drop" % (v, v.upper()))
print("        ip saddr @tvs tcp dport 853 ct state new counter log prefix \"TVGUARD-PT-DOT-%s \" drop" % v.upper())
print("        ip saddr @tvs udp dport 853 ct state new counter log prefix \"TVGUARD-PT-DOT-%s \" drop" % v.upper())
print("        ip saddr @tvs ip daddr != %s ct state new counter log prefix \"TVGUARD-PT-NEW \" accept" % mlan)
print("        ip saddr @tvs ip daddr != %s counter accept" % mlan)
print("        ip daddr @tvs ct state established,related counter accept")
print("        counter continue")
print("    }")
print("    chain prerouting {")
print("        type nat hook prerouting priority -150 ;")
print("        ip saddr @tvs ip daddr != %s udp dport 53 dnat to %s:53" % (box, os.environ["RESIP"]))
print("        ip saddr @tvs ip daddr != %s tcp dport 53 dnat to %s:53" % (box, os.environ["RESIP"]))
print("    }")
print("    chain postrouting {")
print("        type nat hook postrouting priority srcnat ;")
print("        ip saddr @tvs ip daddr != %s oifname \"%s\" counter masquerade" % (mlan, egress))
print("    }")
print("}")
PYEOF
}

for VENDOR in $VENDORS; do
  for PROF in standard standard-no-voice strict manufacturer-lockdown; do
    echo
    echo "==============================================="
    echo "VENDOR: $VENDOR  PROFILE: $PROF"
    echo "==============================================="

    echo "--- rendering throwaway table ip tvguard-ptest ---"
    NFT_FILE=/tmp/privacy-selftest-$VENDOR-$PROF.nft
    render_vendor_profile "$VENDOR" "$PROF" > "$NFT_FILE"

    if nft -c -f "$NFT_FILE" 2>/tmp/ptest-nft-$VENDOR-$PROF.err; then
      ok "rendered ruleset passes nft -c (syntax)"
    else
      no "nft -c failed"; cat /tmp/ptest-nft-$VENDOR-$PROF.err; continue
    fi

    # structural: no rule may touch TCP/443 or UDP/443 (QUIC/HTTPS must stay free)
    if grep -Eq "(tcp|udp)[ ]+dport[ ]+443" "$NFT_FILE"; then
      no "rendered table contains a TCP/443 or UDP/443 rule (would break HTTPS/QUIC)"
    else
      ok "no TCP/443 or UDP/443 rule in rendered table (HTTPS + QUIC stay free)"
    fi

    nft delete table ip tvguard-ptest 2>/dev/null
    nft -f "$NFT_FILE" && ok "throwaway table loaded" || { no "could not load throwaway table"; continue; }

    PRIV_LOG="TVGUARD-PT-PRIV-${VENDOR^^}"
    DOT_LOG="TVGUARD-PT-DOT-${VENDOR^^}"

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
    BLK_IP=$(python3 -c "import json,sys; d=json.load(open('$RES')); v=d['vendors']['$VENDOR']; print(v['$PROF']['ips'][0] if v['$PROF']['ips'] else '')")
    if [ -z "$BLK_IP" ]; then
      no "vendor $VENDOR profile $PROF has no resolved block IPs - cannot test firewall drop"
    else
      run_ns curl -s -o /dev/null -m 8 "http://$BLK_IP/" >/dev/null 2>&1
      RC=$?
      sleep 1
      if [ $RC -ne 0 ] && [ "$(log_count "$PRIV_LOG" "$BLK_IP")" -ge 1 ]; then
        ok "connection to blocked IP $BLK_IP dropped ($PRIV_LOG, DST match)"
      else
        no "blocked-IP drop not confirmed (rc=$RC, DST log count: $(log_count "$PRIV_LOG" "$BLK_IP"))"
      fi
    fi

    echo "--- DoT :853 dropped ---"
    DOT_TEST_IP=$(python3 - <<PYEOF
import json
d = json.load(open("$RES"))
v = d["vendors"]["$VENDOR"]
blocked = set(v["$PROF"]["ips"]) | set(v["doh"]["ips"]) | set(v["keep"]["ips"])
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
    if [ $RC -ne 0 ] && [ "$(log_count "$DOT_LOG" "$DOT_TEST_IP")" -ge 1 ]; then
      ok "DoT $DOT_TEST_IP:853 dropped ($DOT_LOG, DST match)"
    else
      no "DoT drop not confirmed (rc=$RC, logs: $(log_count "$DOT_LOG" "$DOT_TEST_IP"))"
    fi

    echo "--- profile-specific tests ---"
    case "$VENDOR" in
      samsung)
        AIBIXBY_IPS=$(python3 -c "import json; d=json.load(open('$RES')); print(' '.join(d['vendors']['samsung'].get('voice',{}).get('ips',[])))")
        if [ "$PROF" = "standard" ]; then
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
        elif [ "$PROF" = "standard-no-voice" ] || [ "$PROF" = "manufacturer-lockdown" ]; then
          if [ -z "$AIBIXBY_IPS" ]; then
            no "voice section has no resolved IPs; cannot verify voice blocking"
          else
            # sample up to 3 IPs (same deny-set membership; full set would take ~minutes)
            for AIB in $(echo $AIBIXBY_IPS | head -c 200 | awk '{for(i=1;i<=3 && i<=NF;i++) print $i}'); do
              run_ns timeout 5 bash -c "cat < /dev/null > /dev/tcp/$AIB/443" >/dev/null 2>&1
              RC=$?
              sleep 0.5
              if [ $RC -ne 0 ] && [ "$(log_count "$PRIV_LOG" "$AIB")" -ge 1 ]; then
                ok "voice IP $AIB:443 dropped - voice blocked as intended"
              else
                no "voice IP $AIB:443 not dropped under $PROF (rc=$RC, logs: $(log_count "$PRIV_LOG" "$AIB"))"
              fi
            done
            if run_ns timeout 8 bash -c "cat < /dev/null > /dev/tcp/1.1.1.1/443" >/dev/null 2>&1; then
              ok "1.1.1.1:443 ALLOWED under $PROF (DoH-IP set is strict-only; no collateral)"
            else
              no "1.1.1.1:443 unexpectedly unreachable under $PROF"
            fi
          fi
        else
          run_ns timeout 8 bash -c "cat < /dev/null > /dev/tcp/1.1.1.1/443" >/dev/null 2>&1
          RC=$?
          sleep 1
          if [ $RC -ne 0 ] && [ "$(log_count "TVGUARD-PT-DOH-${VENDOR^^}" "1.1.1.1")" -ge 1 ]; then
            ok "DoH endpoint 1.1.1.1:443 dropped (DoH set active in strict)"
          else
            no "DoH drop not confirmed (rc=$RC, logs: $(log_count "TVGUARD-PT-DOH-${VENDOR^^}" "1.1.1.1"))"
          fi
        fi
        ;;
      lg)
        # The ACR tier is part of the LG standard profile, so the Alphonso ACR
        # endpoint must be DROPPED in EVERY profile. Test the actual Alphonso
        # endpoint IP (not an arbitrary member of the profile IP set).
        ACRIP=$(dig +short +time=5 +tries=2 eu-acr1.alphonso.tv 2>/dev/null | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | head -1)
        if [ -z "$ACRIP" ]; then
          ACRIP=$(dig +short +time=5 +tries=2 tkacr1.alphonso.tv 2>/dev/null | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | head -1)
        fi
        if [ -z "$ACRIP" ]; then
          no "no Alphonso ACR endpoint resolvable - ACR firewall test inconclusive"
        elif ! python3 -c "import json,sys; sys.exit(0 if '$ACRIP' in json.load(open('$RES'))['vendors']['lg']['$PROF']['ips'] else 1)"; then
          no "Alphonso IP $ACRIP not in the $PROF firewall deny set (compiler bug)"
        else
          run_ns timeout 5 bash -c "cat < /dev/null > /dev/tcp/$ACRIP/443" >/dev/null 2>&1
          RC=$?
          sleep 0.5
          if [ $RC -ne 0 ] && [ "$(log_count "$PRIV_LOG" "$ACRIP")" -ge 1 ]; then
            ok "Alphonso ACR IP $ACRIP:443 dropped under $PROF (ACR denied in ALL profiles)"
          else
            no "Alphonso ACR IP $ACRIP:443 not dropped under $PROF (rc=$RC, logs: $(log_count "$PRIV_LOG" "$ACRIP"))"
          fi
        fi
        if [ "$PROF" = "strict" ]; then
            run_ns timeout 8 bash -c "cat < /dev/null > /dev/tcp/1.1.1.1/443" >/dev/null 2>&1
            RC=$?
            sleep 1
            if [ $RC -ne 0 ] && [ "$(log_count "TVGUARD-PT-DOH-${VENDOR^^}" "1.1.1.1")" -ge 1 ]; then
              ok "DoH endpoint 1.1.1.1:443 dropped (DoH set active in strict)"
            else
              no "DoH drop not confirmed (rc=$RC)"
            fi
          else
            if run_ns timeout 8 bash -c "cat < /dev/null > /dev/tcp/1.1.1.1/443" >/dev/null 2>&1; then
              ok "1.1.1.1:443 ALLOWED under $PROF (DoH-IP set is strict-only; no collateral)"
            else
              no "1.1.1.1:443 unexpectedly unreachable under $PROF"
            fi
          fi
          # LG keep hosts must be firewalled-allowed in EVERY profile
          KEEP_IPS=$(python3 -c "
import json
d = json.load(open('$RES'))
v = d['vendors']['lg']
deny = set(v['$PROF']['ips']) | set(v['doh']['ips'])
keep = set(v['keep']['ips']) - deny
print(' '.join(sorted(keep)[:3]))")
          if [ -n "$KEEP_IPS" ]; then
            KEEP_IP=$(echo $KEEP_IPS | awk '{print $1}')
            if run_ns timeout 8 bash -c "cat < /dev/null > /dev/tcp/$KEEP_IP/443" >/dev/null 2>&1; then
              ok "LG keep-list IP $KEEP_IP:443 ALLOWED under $PROF (keep wins at firewall level)"
            else
              no "LG keep-list IP $KEEP_IP:443 not reachable under $PROF (keep-list broken!)"
            fi
          else
            info "no unshared LG keep IP available for the firewall keep test (all shared with deny sets)"
          fi
        ;;
    esac

    echo "--- Pi-hole group cycle (temp group, mock client $NSIP only) ---"
    PH_OUT=$(PRIVACY_ROOT="$ROOT" MOCK_CLIENT="$NSIP" VENDOR="$VENDOR" PROF="$PROF" NS="$NS" RES="$RES" PIHOLE_DNS="$PIHOLE_IP" python3 - <<'PYEOF'
import json, os, re, subprocess, time, urllib.request, urllib.error
ROOT = os.environ["PRIVACY_ROOT"]; MOCK = os.environ["MOCK_CLIENT"]
VENDOR = os.environ["VENDOR"]; PROF = os.environ["PROF"]; NS = os.environ["NS"]
PIHOLE_DNS = os.environ["PIHOLE_DNS"]
BASE = "http://127.0.0.1:3001"
GN = "TVGuard-Privacy-TEST-%s" % VENDOR.upper()
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
vs = resolved["vendors"][VENDOR]
prof_sec = vs[PROF]
domains = prof_sec["domains"]

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
# FTL stores domain rows GLOBALLY; groups are associations on the row, and
# this FTL build has NO per-id group-update endpoint. A name already in the
# DB (e.g. the real TVGuard-Privacy group is live, or shared with the other
# vendor) cannot be re-added to a second group without delete+re-add (a
# transient deny gap on the LIVE policy - unacceptable in a test). Therefore:
#   * names NOT in the global DB -> pushed into the temp group and block-tested;
#   * names already in the DB -> block test INCONCLUSIVE (reported as such).
def all_domain_rows():
    # FTL here IGNORES the `offset` param on /api/domains, so offset-paging
    # loops forever once the DB exceeds one page. Fetch with a single
    # expanding-limit call instead.
    limit = 1000
    while True:
        code, res = req("GET", "/api/domains?limit=%d" % limit)
        rows = res.get("domains") if isinstance(res, dict) else res
        if not isinstance(rows, list):
            rows = []
        if len(rows) < limit:
            return rows
        limit *= 4
        if limit > 100000:
            return rows

global_by_name = {}
for d in all_domain_rows():
    global_by_name.setdefault(str(d.get("domain", "")).lower(), d)
existing = set(global_by_name)
to_push = [d for d in domains if d.lower() not in existing]
if to_push:
    code, res = req("POST", "/api/domains/deny/exact", {"domain": to_push, "groups": [gid]})
    if code not in (200, 201):
        print("BAD  domain push failed: %s" % res); raise SystemExit(0)
    print("OK   temp group %s: %d new rows pushed (of %d; %d already in global DB -> skipped)" % (GN, len(to_push), len(domains), len(domains) - len(to_push)))
else:
    print("INFO all %d profile domains already exist in the global DB (real groups live?) - mock-client block tests inconclusive for them" % len(domains))
regexes = [r["pattern"] for r in (prof_sec.get("regexes") or [])]
temp_group_rows = [str(d.get("domain", "")).lower()
                   for d in all_domain_rows()
                   if gid in (d.get("groupIDs") or d.get("groups") or [])]
rx_new = [p for p in regexes if p.lower() not in set(temp_group_rows) and p.lower() not in existing]
regex_pushed = bool(rx_new)
if rx_new:
    code, res = req("POST", "/api/domains/deny/regex", {"domain": rx_new, "groups": [gid]})
    if code not in (200, 201):
        print("BAD  regex push failed: %s" % res); raise SystemExit(0)
    print("OK   %d regex (suffix/zone) denies pushed to temp group" % len(rx_new))
rx_global = [p for p in regexes if p.lower() in existing and p.lower() not in set(temp_group_rows)]
if rx_global:
    print("INFO %d regex pattern(s) already in global DB (real groups live) - suffix mock-client test inconclusive for them" % len(rx_global))
# allow rows (manufacturer-lockdown keep list): keep wins, incl. over gravity
allows = [a for a in (prof_sec.get("allows") or [])]
allow_fresh = [a for a in allows if a.lower() not in existing]
if allow_fresh:
    code, res = req("POST", "/api/domains/allow/exact", {"domain": allow_fresh, "groups": [gid]})
    if code in (200, 201):
        print("OK   %d allow rows pushed to temp group (of %d total; %d pre-existing in global DB)" % (len(allow_fresh), len(allows), len(allows) - len(allow_fresh)))
    else:
        okn = 0
        for a in allow_fresh:
            c2, r2 = req("POST", "/api/domains/allow/exact", {"domain": [a], "groups": [gid]})
            if c2 in (200, 201):
                okn += 1
            else:
                print("INFO allow row for %s not pushed (%s) - pre-existing global row is acceptable" % (a, str(r2)[:80]))
        print("OK   %d/%d allow rows pushed (one-at-a-time fallback)" % (okn, len(allow_fresh)))
elif allows:
    print("INFO all %d allow names already in global DB - no fresh allow rows pushed" % len(allows))
time.sleep(1)

def host_dig(dom):
    """Baseline answer from THIS host via local Pi-hole (host is not in the group)."""
    out = subprocess.run(["dig", "+short", "+time=5", "+tries=2", "@" + PIHOLE_DNS, dom],
                         capture_output=True, text=True).stdout.strip()
    # scan all lines: the first may be a CNAME, the A record follows
    for ln in (out.splitlines() if out else []):
        m = re.match(r"^(\d{1,3}(?:\.\d{1,3}){3})$", ln)
        if m:
            return m.group(1)
    return None

def ns_dig(dom):
    """Answer seen by the MOCK TV (dig @8.8.8.8 -> DNAT -> Pi-hole, client = mock)."""
    out = subprocess.run(["ip", "netns", "exec", NS, "dig", "+short", "+time=5", "+tries=2", "@8.8.8.8", dom],
                         capture_output=True, text=True).stdout.strip()
    return out

IPRE = re.compile(r"^\d{1,3}(?:\.\d{1,3}){3}$")
def ans_ip(ans):
    """First IPv4 anywhere in a dig answer (the first line is often a CNAME)."""
    for ln in (ans.splitlines() if ans else []):
        if IPRE.match(ln.strip()):
            return ln.strip()
    return None
def is_blocked(ans):
    return ans == "" or "0.0.0.0" in ans or "NXDOMAIN" in ans.upper()

# pick a gravity-safe test domain that the TEMP group actually holds
test_dom = None
for dom in to_push:
    if host_dig(dom):
        test_dom = dom
        break
if test_dom is None:
    if to_push:
        print("INFO no temp-group domain has a host-resolvable baseline - generic block test skipped")
    else:
        print("INFO temp group holds no fresh rows (all profile domains pre-exist globally) - generic block test inconclusive")
else:
    ans = ns_dig(test_dom)
    if is_blocked(ans):
        print("OK   mock-client dig of %s blocked by our group (answer: %s)" % (test_dom, ans or "empty"))
    else:
        print("BAD  mock-client dig of %s unexpectedly resolved: %s" % (test_dom, ans))
    time.sleep(0.5)

if VENDOR == "samsung":
    # voice-domain behaviour per profile
    vdom = "prd-euw1-ucs.aibixby.com"
    hb = host_dig(vdom)
    if hb is None:
        print("INFO host baseline: %s already blocked by gravity (0.0.0.0) - voice-DNS result inconclusive either way" % vdom)
    elif vdom.lower() in existing:
        print("INFO %s already exists in the global DB (real group live) - temp group holds no copy, mock-client test inconclusive (regex/suffix test below still applies)" % vdom)
    else:
        ans = ns_dig(vdom)
        if PROF == "standard":
            if ans_ip(ans):
                print("OK   voice domain %s STILL RESOLVES under standard (voice functional)" % vdom)
            else:
                print("BAD  voice domain %s does not resolve under standard: %s" % (vdom, ans or "empty"))
        else:
            if is_blocked(ans):
                print("OK   voice domain %s blocked for mock client under %s (answer: %s)" % (vdom, PROF, ans or "empty"))
            else:
                print("BAD  voice domain %s unexpectedly resolves under %s: %s" % (vdom, PROF, ans))
    # suffix-regex behaviour: the user-plane host is covered ONLY by the
    # aibixby.com suffix regex (not by any exact entry)
    rvdom = "prdcore1-euw1-user.aibixby.com"
    rhb = host_dig(rvdom)
    if rhb is None:
        print("INFO host baseline: %s already blocked by gravity - suffix-regex result inconclusive" % rvdom)
    elif not regex_pushed:
        print("INFO suffix-regex test inconclusive (regex not freshly pushed to temp group this run)")
    else:
        ans = ns_dig(rvdom)
        if PROF == "standard":
            if ans_ip(ans):
                print("OK   suffix host %s STILL RESOLVES under standard (voice functional)" % rvdom)
            else:
                print("BAD  suffix host %s does not resolve under standard: %s" % (rvdom, ans or "empty"))
        else:
            if is_blocked(ans):
                print("OK   suffix host %s blocked for mock client under %s via regex (answer: %s)" % (rvdom, PROF, ans or "empty"))
            else:
                print("BAD  suffix host %s unexpectedly resolves under %s: %s" % (rvdom, PROF, ans))
    # keep-domain must still resolve for the mock client
    kdom = "www.youtube.com"
    kbh = host_dig(kdom)
    if kbh is None:
        print("INFO host baseline: %s blocked by gravity already - keep check inconclusive" % kdom)
    else:
        ans = ns_dig(kdom)
        if ans_ip(ans):
            print("OK   keep domain %s still resolves for mock client: %s" % (kdom, ans.splitlines()[0]))
        else:
            print("BAD  keep domain %s does not resolve for mock client: %s" % (kdom, ans or "empty"))
    # unclassified Samsung host: manufacturer-lockdown must DENY it (zone regex in
    # the temp group); all other profiles must still let it resolve (no leak).
    PROBES = ["www.samsung.com", "www.samsungcloud.tv", "www.samsungcloudsolution.com",
              "www.samsungnyc.com", "image.samsungcloudsolution.com"]
    for p in PROBES:
        hb = host_dig(p)
        if hb is None:
            continue
        ans = ns_dig(p)
        if PROF == "manufacturer-lockdown":
            matching = [r["pattern"] for r in (prof_sec.get("regexes") or []) if re.search(r["pattern"], p)]
            fresh = [x for x in matching if x.lower() in {y.lower() for y in rx_new}]
            if not matching:
                if ans_ip(ans):
                    print("OK   Samsung host %s still resolves under manufacturer-lockdown (no zone regex covers it)" % p)
                else:
                    print("BAD  Samsung host %s unexpectedly blocked under manufacturer-lockdown (no zone regex covers it): %s" % (p, ans))
            elif not fresh:
                print("INFO unclassified Samsung host %s: its zone regex pre-exists in the global DB (live vendor group) - mock-client deny test inconclusive (live group verified by privacy-live-check.sh)" % p)
            elif is_blocked(ans):
                print("OK   unclassified Samsung host %s DENIED for mock client under manufacturer-lockdown (zone regex)" % p)
            else:
                print("BAD  unclassified Samsung host %s still resolves under manufacturer-lockdown: %s" % (p, ans))
        else:
            if ans_ip(ans):
                print("OK   unclassified Samsung host %s still resolves under %s (no zone deny there)" % (p, PROF))
            else:
                print("BAD  unclassified Samsung host %s unexpectedly blocked under %s: %s" % (p, PROF, ans or "empty"))
        break
    else:
        print("INFO no resolvable unclassified Samsung probe host found - zone-regex probe test inconclusive")
    if PROF == "manufacturer-lockdown":
        kh = "time.samsungcloudsolution.com"
        kbh = host_dig(kh)
        if kbh is None:
            print("INFO host baseline: %s blocked by gravity - the mock-client allow-row test below is the decisive keep-wins proof" % kh)
        else:
            ans = ns_dig(kh)
            if ans_ip(ans):
                print("OK   keep host %s resolves for mock client under manufacturer-lockdown: %s (keep wins)" % (kh, ans.splitlines()[0]))
            else:
                print("BAD  keep host %s does not resolve under manufacturer-lockdown: %s (keep-list broken!)" % (kh, ans or "empty"))
else:
    # LG: ACR endpoint must be blocked in blocking profiles (exact row)
    # ACR is part of the LG standard tier: Alphonso must be DENIED in every
    # profile (standard included).
    adom = "eu-acr1.alphonso.tv"
    ahb = host_dig(adom)
    if ahb is None:
        print("INFO host baseline: %s does not resolve from the host (NXDOMAIN?) - ACR block test inconclusive" % adom)
    else:
        ans = ns_dig(adom)
        if is_blocked(ans):
            print("OK   ACR domain %s blocked for mock client under %s (answer: %s)" % (adom, PROF, ans or "empty"))
        else:
            print("BAD  ACR domain %s unexpectedly resolves under %s: %s" % (adom, PROF, ans))
    # voice tier names: present in the resolved domain set only for the voice
    # profiles; DNS-denied for the mock client under senv/strict/mlock, and
    # must still resolve under standard (voice is not part of standard).
    prof_domains = {str(d).lower() for d in (prof_sec.get("domains") or [])}
    voice_names = ["lgsmartweb.com", "netflixvoice.lgtvcommon.com", "qt2-kic.lab.lgtvcommon.com"]
    if PROF == "standard":
        leaked = [d for d in voice_names if d in prof_domains]
        if not leaked:
            print("OK   voice tier names absent from the standard domain set")
        else:
            print("BAD  voice tier names leaked into standard: %s" % ", ".join(leaked))
    else:
        missing = [d for d in voice_names if d not in prof_domains]
        if not missing:
            print("OK   all %d voice tier names present in the %s domain set" % (len(voice_names), PROF))
        else:
            print("BAD  voice names missing from %s domain set: %s" % (PROF, ", ".join(missing)))
        for vdom in ("netflixvoice.lgtvcommon.com", "qt2-kic.lab.lgtvcommon.com"):
            hb = host_dig(vdom)
            if hb is None:
                print("INFO host baseline: %s not resolvable - voice-DNS test inconclusive" % vdom)
                continue
            ans = ns_dig(vdom)
            if is_blocked(ans):
                print("OK   voice host %s blocked for mock client under %s (answer: %s)" % (vdom, PROF, ans or "empty"))
            else:
                print("BAD  voice host %s unexpectedly resolves under %s: %s" % (vdom, PROF, ans))
    # ad-zone host: the lgsmartad suffix must block unlisted ad hosts
    adom2 = "de.info.lgsmartad.com"
    ahb2 = host_dig(adom2)
    if ahb2 is None:
        print("INFO host baseline: %s not resolvable - ad-zone block test inconclusive" % adom2)
    else:
        ans = ns_dig(adom2)
        if PROF == "standard":
            if is_blocked(ans):
                print("OK   ad-zone host %s blocked under standard (suffix regex)" % adom2)
            else:
                print("BAD  ad-zone host %s still resolves under standard: %s" % (adom2, ans))
        else:
            if is_blocked(ans):
                print("OK   ad-zone host %s blocked under %s" % (adom2, PROF))
            else:
                print("BAD  ad-zone host %s unexpectedly resolves under %s: %s" % (adom2, PROF, ans))
    # keep-domain must still resolve for the mock client (YouTube)
    kdom = "www.youtube.com"
    kbh = host_dig(kdom)
    if kbh is None:
        print("INFO host baseline: %s blocked by gravity already - keep check inconclusive" % kdom)
    else:
        ans = ns_dig(kdom)
        if ans_ip(ans):
            print("OK   keep domain %s still resolves for mock client: %s" % (kdom, ans.splitlines()[0]))
        else:
            print("BAD  keep domain %s does not resolve for mock client: %s" % (kdom, ans or "empty"))
    # LG time/OTA keeps must resolve in EVERY profile (the critical LG keeps)
    for kh in ["gb.lgtvsdp.com", "gb.nextlgsdp.com", "su.lge.com", "ngfts.lge.com"]:
        khb = host_dig(kh)
        if khb is None:
            print("INFO host baseline: %s not resolvable from host - keep check inconclusive" % kh)
            continue
        ans = ns_dig(kh)
        if ans_ip(ans):
            print("OK   LG keep %s resolves for mock client under %s: %s" % (kh, PROF, ans.splitlines()[0]))
        else:
            print("BAD  LG keep %s does not resolve for mock client under %s: %s (time/OTA would break!)" % (kh, PROF, ans or "empty"))
    # unclassified LG host: mlock must DENY (zone regex); other profiles must not
    PROBES = ["www.lgtvcommon.com", "www.lgtviot.com", "www.wiselg.com",
              "www.lgsmartplatform.com", "www.lgthinq.com"]
    for p in PROBES:
        hb = host_dig(p)
        if hb is None:
            continue
        ans = ns_dig(p)
        if PROF == "manufacturer-lockdown":
            matching = [r["pattern"] for r in (prof_sec.get("regexes") or []) if re.search(r["pattern"], p)]
            fresh = [x for x in matching if x.lower() in {y.lower() for y in rx_new}]
            if not matching:
                if ans_ip(ans):
                    print("OK   LG host %s still resolves under manufacturer-lockdown (no zone regex covers it)" % p)
                else:
                    print("BAD  LG host %s unexpectedly blocked under manufacturer-lockdown (no zone regex covers it): %s" % (p, ans))
            elif not fresh:
                print("INFO unclassified LG host %s: its zone regex pre-exists in the global DB (live vendor group) - mock-client deny test inconclusive (live group verified by privacy-live-check.sh)" % p)
            elif is_blocked(ans):
                print("OK   unclassified LG host %s DENIED for mock client under manufacturer-lockdown (zone regex)" % p)
            else:
                print("BAD  unclassified LG host %s still resolves under manufacturer-lockdown: %s" % (p, ans))
        else:
            if ans_ip(ans):
                print("OK   unclassified LG host %s still resolves under %s (no zone deny there)" % (p, PROF))
            else:
                print("BAD  unclassified LG host %s unexpectedly blocked under %s: %s" % (p, PROF, ans or "empty"))
        break
    else:
        print("INFO no resolvable unclassified LG probe host found - zone-regex probe test inconclusive")
    # wiselg keep host inside a deny zone: allow row must beat the zone regex
    if PROF == "manufacturer-lockdown":
        kh = "tv.wiselg.com"
        khb = host_dig(kh)
        if khb is None:
            print("INFO host baseline: %s not resolvable - allow-row keep test inconclusive" % kh)
        else:
            ans = ns_dig(kh)
            if ans_ip(ans):
                print("OK   wiselg keep host %s resolves under manufacturer-lockdown: %s (allow row beats the zone regex)" % (kh, ans.splitlines()[0]))
            else:
                print("BAD  wiselg keep host %s does not resolve under manufacturer-lockdown: %s (allow row missing!)" % (kh, ans or "empty"))

# cleanup: delete only rows that belong solely to the temp group, then detach
# client and delete group.
to_del = []
for d in all_domain_rows():
    gids = set(d.get("groupIDs") or d.get("groups") or [])
    if gids == {gid}:
        to_del.append({"item": d["domain"], "type": d.get("type", "deny"), "kind": d.get("kind", "exact")})
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
# remove the mock client record itself (selftest is its only user) - only
# when it has no remaining group associations.
code, res = req("GET", "/api/clients")
for c in res.get("clients", []):
    key = c.get("client") or c.get("ip")
    if key == MOCK and not c.get("groups"):
        req("POST", "/api/clients:batchDelete", [{"item": key}])
        print("OK   mock client record %s removed" % key)
if GN not in names:
    print("OK   Pi-hole cleanup complete (%s): %d domains deleted, clients detached, group removed" % (GN, len(to_del)))
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
CUR_DOCKER=$(docker_norm)
[ "$CUR_DOCKER" = "$BASE_DOCKER" ] && ok "docker containers unchanged" || no "docker state changed"

echo
echo "==================================="
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && echo "PRIVACY SELFTEST: ALL PASS" || echo "PRIVACY SELFTEST: FAILURES PRESENT"
exit $FAIL
