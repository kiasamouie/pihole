#!/usr/bin/env bash
#
# tvguard-apply.sh  -  generate, validate and load the TVGuard ruleset
#
# Core engine. Reads config/tvguard.conf, renders an nftables file that owns
# ONLY the `ip tvguard` table, syntax-checks it, then atomically replaces that
# one table and applies the (restorable) sysctl changes. It never touches the
# existing filter/nat/raw tables, UFW, or Docker rules.
#
# Usage:
#   tvguard-apply.sh [mode]
#     mode = monitor | enforce   (if omitted, the mode in the state file is
#                                  used; if none, monitor)
#
# Safety invariants:
#   * Only `table ip tvguard` is created/deleted.
#   * Never flushes, resets, or edits any other table or UFW.
#   * Sysctl changes are baseline-captured so tvguard-disable.sh restores them.
#   * Idempotent: safe to run repeatedly.
set -euo pipefail

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run with sudo" >&2; exit 3
  fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"

[ -f "$ROOT/config/tvguard.conf" ] || {
  echo "ERROR: $ROOT/config/tvguard.conf not found (copy from .example)" >&2; exit 4
}
# shellcheck source=/dev/null
. "$ROOT/config/tvguard.conf"

: "${LAN_INTERFACE:=}" "${LAN_SUBNET:=}" "${GATEWAY_IP:=}" "${UPSTREAM_ROUTER:=}"
: "${TVS:=}" "${MODE:=}" "${STATE_DIR:=/var/lib/tvguard}" "${WAN_INTERFACE:=}"
[ -n "$LAN_INTERFACE" ] && [ -n "$LAN_SUBNET" ] && [ -n "${TVS:-}" ] || {
  echo "ERROR: LAN_INTERFACE, LAN_SUBNET and TVS must be set in config" >&2; exit 4
}

# Testability override: TGUARD_TVS replaces the TV list in the rendered table
# (used by throwaway-table mock cycles, e.g. TGUARD_TABLE=tvguard-dry).
# When set, the UFW route-allow loop below is SKIPPED as well, so a dry
# table never touches the real UFW state or protects/drops real client IPs.

# Egress interface: one-arm -> the LAN NIC (upstream hub is on the same segment);
# dual-nic  -> the WAN NIC.
if [ "${MODE}" = "dualnic-gateway" ]; then
  EGRESS_IF="${WAN_INTERFACE:-$LAN_INTERFACE}"
  [ -n "$WAN_INTERFACE" ] || { echo "WARN: dualnic-gateway set but WAN_INTERFACE empty; using LAN_INTERFACE" >&2; }
else
  EGRESS_IF="$LAN_INTERFACE"
fi

STATE_DIR="${STATE_DIR:-/var/lib/tvguard}"
STATE_FILE="$STATE_DIR/state"
NFT_FILE="$STATE_DIR/tvguard.nft"
# Table name is overridable for dry-run/CI rendering (TGUARD_TABLE=tvguard-dry);
# production always uses the default name.
TGUARD_TABLE="${TGUARD_TABLE:-tvguard}"

# --- Privacy policy state (multi-vendor; separate dimension from monitor/enforce)
# Per-vendor state lines in $PRIVACY_STATE_FILE: PRIVACY-<vendor>=<tier>
# (legacy: a single line PRIVACY=<tier> is parsed as samsung=<tier> for
# backward compatibility). Vendors come from config/privacy-instances.yaml.
# Each ACTIVE vendor renders its own, DISJOINT objects:
#   * client set   tv_privacy_<vendor>        (the vendor's applies_to only)
#   * deny-IP set  tv_privacy_blocked_<vendor>
#   * DoH-IP set   tv_doh_blocked_<vendor>    (strict only)
#   * log prefixes TVGUARD-PRIVACY-<VENDOR> / TVGUARD-DOH-<VENDOR> /
#                  TVGUARD-DOT-<VENDOR>
# Applying/disabling one vendor never touches the other vendor's sets, rules,
# Pi-hole group or state line. The vendor privacy rules (deny-set drop, DoT
# 853, external :53 DNAT) match ONLY that vendor's applies_to list - never
# the full TVS list (which may contain TVs outside the privacy policy). When
# every vendor is off, the rendered table is identical to the pre-privacy
# ruleset. It never changes NAT, the TVGuard monitor/enforce mode, or UFW.
PRIVACY_STATE_FILE="$STATE_DIR/privacy-state"
PRIVACY_RESOLVED="$ROOT/data/privacy-policy/resolved.json"
PRIVACY_VENDOR_ROWS=""
if [ -f "$PRIVACY_STATE_FILE" ] && [ -f "$PRIVACY_RESOLVED" ] && command -v python3 >/dev/null 2>&1; then
  PRIVACY_VENDOR_ROWS="$(python3 - "$ROOT/config/privacy-instances.yaml" "$PRIVACY_STATE_FILE" "$PRIVACY_RESOLVED" <<'PYEOF' 2>/dev/null
import json, os, sys
import yaml
inst = yaml.safe_load(open(sys.argv[1])).get("instances") or {}
states = {}
if os.path.exists(sys.argv[2]):
    for line in open(sys.argv[2]):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        k, _, v = line.partition("=")
        k, v = k.strip(), v.strip()
        if k == "PRIVACY":
            states.setdefault("samsung", v)
        elif k.startswith("PRIVACY-"):
            states[k[len("PRIVACY-"):].strip().lower()] = v
res = json.load(open(sys.argv[3]))
tiers = ("standard", "standard-no-voice", "strict", "manufacturer-lockdown")
for v, cfg in inst.items():
    tier = states.get(v, "off")
    if tier not in tiers:
        tier = "off"
    if tier == "off":
        print("\t".join([v, tier, "", "", ""]))
        continue
    vs = (res.get("vendors") or {}).get(v) or {}
    sec = vs.get(tier) or {}
    doh = (vs.get("doh") or {}).get("ips", []) if tier == "strict" else []
    targets = vs.get("applies_to") or []
    # field order: vendor, tier, deny-ips, targets, doh-ips (the optional doh
    # field is LAST so an empty value cannot shift the read() fields)
    print("\t".join([v, tier,
                     ",".join(sorted(sec.get("ips", []))),
                     ",".join(targets),
                     ",".join(sorted(doh))]))
PYEOF
)"
fi
# Render fragments (built after the Pi-hole container IP is known):
#   PRIVACY_SETS       - nft set definitions (all vendors)
#   PRIVACY_FORWARD    - forward-chain drop/DoT rules (all vendors)
#   PRIVACY_PREROUTING - external :53 DNAT rules (all vendors)
PRIVACY_SETS=""
PRIVACY_FORWARD=""
PRIVACY_PREROUTING=""
PRIVACY_SUMMARY=""

# Resolve the Pi-hole container IP for the DNS-bypass DNAT (see prerouting
# comment). Empty => render falls back to `redirect`.
PIHOLE_CONTAINER_IP=""
if command -v docker >/dev/null 2>&1; then
  PIHOLE_CONTAINER_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' pihole 2>/dev/null | awk 'NF' | head -1)
  [ -n "$PIHOLE_CONTAINER_IP" ] || echo "WARN: could not resolve pihole container IP; DNS bypass will use redirect fallback" >&2
fi

# --- Build the per-vendor privacy fragments ---------------------------------
# One line per vendor from the state file (tab-separated):
#   vendor <TAB> tier <TAB> deny-ips (csv) <TAB> doh-ips (csv) <TAB> applies_to (csv)
if [ -n "$PRIVACY_VENDOR_ROWS" ]; then
  while IFS=$'\t' read -r p_vendor p_tier p_ips p_targets p_doh; do
    case "$p_tier" in standard|standard-no-voice|strict|manufacturer-lockdown) : ;; *) continue ;; esac
    [ -n "$p_targets" ] || { echo "WARN: privacy vendor $p_vendor active (tier $p_tier) but has no applies_to targets - skipping its render" >&2; continue; }
    p_upper="${p_vendor^^}"
    p_client="tv_privacy_${p_vendor}"
    p_blk="tv_privacy_blocked_${p_vendor}"
    p_dohset="tv_doh_blocked_${p_vendor}"
    PRIVACY_SETS="${PRIVACY_SETS}    set $p_client {
        type ipv4_addr ;
        elements = { $p_targets } ;
    }
"
    if [ -n "$p_ips" ]; then
      PRIVACY_SETS="${PRIVACY_SETS}    set $p_blk {
        type ipv4_addr ;
        flags interval ;
        elements = { $p_ips } ;
    }
"
      PRIVACY_FORWARD="${PRIVACY_FORWARD}        ip saddr @$p_client ip daddr @$p_blk ct state new counter log prefix \"TVGUARD-PRIVACY-$p_upper \" drop
"
    fi
    if [ "$p_tier" = "strict" ] && [ -n "$p_doh" ]; then
      PRIVACY_SETS="${PRIVACY_SETS}    set $p_dohset {
        type ipv4_addr ;
        flags interval ;
        elements = { $p_doh } ;
    }
"
      PRIVACY_FORWARD="${PRIVACY_FORWARD}        ip saddr @$p_client ip daddr @$p_dohset ct state new counter log prefix \"TVGUARD-DOH-$p_upper \" drop
"
    fi
    PRIVACY_FORWARD="${PRIVACY_FORWARD}        ip saddr @$p_client tcp dport 853 ct state new counter log prefix \"TVGUARD-DOT-$p_upper \" drop
        ip saddr @$p_client udp dport 853 ct state new counter log prefix \"TVGUARD-DOT-$p_upper \" drop
"
    if [ -n "$PIHOLE_CONTAINER_IP" ]; then
      PRIVACY_PREROUTING="${PRIVACY_PREROUTING}        ip saddr @$p_client ip daddr != $PIHOLE_IP meta l4proto udp th dport 53 dnat to $PIHOLE_CONTAINER_IP:53
        ip saddr @$p_client ip daddr != $PIHOLE_IP meta l4proto tcp th dport 53 dnat to $PIHOLE_CONTAINER_IP:53
"
    else
      PRIVACY_PREROUTING="${PRIVACY_PREROUTING}        ip saddr @$p_client ip daddr != $PIHOLE_IP meta l4proto udp th dport 53 redirect to :53
        ip saddr @$p_client ip daddr != $PIHOLE_IP meta l4proto tcp th dport 53 redirect to :53
"
    fi
    PRIVACY_SUMMARY="${PRIVACY_SUMMARY}  privacy[$p_vendor]=$p_tier (deny-IPs: $(printf '%s' "$p_ips" | tr ',' ' ' | wc -w), doh-IPs: $(printf '%s' "$p_doh" | tr ',' ' ' | wc -w), scope: $p_targets)\n"
  done <<< "$PRIVACY_VENDOR_ROWS"
fi

# Resolve the operating mode.
if [ "$#" -ge 1 ] && [ -n "${1:-}" ]; then
  MODE="$1"
fi
if [ "$MODE" != "monitor" ] && [ "$MODE" != "enforce" ]; then
  # MODE may still be the deployment mode (onearm-poc) if none was given.
  if [ -f "$STATE_FILE" ] && grep -q '^MODE=' "$STATE_FILE" 2>/dev/null; then
    MODE="$(grep '^MODE=' "$STATE_FILE" | tail -1 | cut -d= -f2)"
  else
    MODE="monitor"
  fi
fi
[ "$MODE" = "monitor" ] || [ "$MODE" = "enforce" ] || {
  echo "ERROR: mode must be monitor or enforce (got: $MODE)" >&2; exit 4
}

need_root

mkdir -p "$STATE_DIR"

# --- Build the TV list (comma-separated for the nft set) --------------------
# TGUARD_TVS (throwaway mock cycles) replaces the configured TV list in the
# rendered table, so a dry table never references real client IPs.
TV_SOURCE="${TGUARD_TVS:-$TVS}"
TV_LIST=""
for tv in $TV_SOURCE; do
  TV_LIST="${TV_LIST}${TV_LIST:+, }$tv"
done

# --- Parse destinations.yaml for class: blocked -----------------------------
parse_blocked_ips() {
  [ -f "$ROOT/config/destinations.yaml" ] || return 0
  awk '
    /^[[:space:]]*-[[:space:]]*domain:/ { if (cls=="blocked" && ip!="") print ip; cls=""; ip="" }
    /^[[:space:]]*class:[[:space:]]*/  { v=$0; sub(/^.*class:[[:space:]]*/,"",v); sub(/[[:space:]].*$/,"",v); cls=v }
    /^[[:space:]]*ip:[[:space:]]*/     { v=$0; sub(/^.*ip:[[:space:]]*/,"",v);   sub(/[[:space:]].*$/,"",v); ip=v  }
    END { if (cls=="blocked" && ip!="") print ip }
  ' "$ROOT/config/destinations.yaml" | tr '\n' ',' | sed 's/,$//'
}
BLOCKED_IPS="$(parse_blocked_ips)"

# --- Render the ruleset -------------------------------------------------------
{
  echo "table ip $TGUARD_TABLE {"
  echo "    set tvs {"
  echo "        type ipv4_addr ;"
  echo "        elements = { $TV_LIST } ;"
  echo "    }"
  echo "    set tv_blocked {"
  echo "        type ipv4_addr ;"
  if [ -n "$BLOCKED_IPS" ]; then
    echo "        elements = { $BLOCKED_IPS } ;"
  fi
  echo "    }"

  # Privacy policy sets, per active vendor (tv_privacy_<vendor>,
  # tv_privacy_blocked_<vendor>, tv_doh_blocked_<vendor>). Each vendor's rules
  # match ONLY its own applies_to client set, so vendors are fully disjoint.
  if [ -n "$PRIVACY_SETS" ]; then
    printf '%s' "$PRIVACY_SETS"
  fi

  echo "    chain forward {"
  echo "        type filter hook forward priority -150 ;"
  # TV -> LAN (incl. the hub .1). Accept. NOTE: flat L2 PoC - this is NOT LAN isolation.
  echo "        ip saddr @tvs ip daddr $LAN_SUBNET counter accept"
  # Privacy policy drops, per active vendor (deny-set drop + DoT :853 +
  # optional DoH-IP set in strict). Matches @tv_privacy_<vendor> (applies_to
  # only - never the full tvs list), so clients outside a vendor's policy are
  # unaffected. ct state new means established flows keep working until they
  # end; blocked attempts are logged with the vendor-specific prefix.
  if [ -n "$PRIVACY_FORWARD" ]; then
    printf '%s' "$PRIVACY_FORWARD"
  fi
  if [ "$MODE" = "enforce" ]; then
    echo "        ip saddr @tvs tcp dport 853 counter log prefix \"TVGUARD-DOT \" drop"
    if [ -n "$BLOCKED_IPS" ]; then
      echo "        ip saddr @tvs ip daddr @tv_blocked counter log prefix \"TVGUARD-BLK \" drop"
    fi
  fi
  # TV -> Internet, NEW connections: log + count + accept (monitor-friendly)
  echo "        ip saddr @tvs ip daddr != $LAN_SUBNET ct state new counter log prefix \"TVGUARD-NEW \" accept"
  # TV -> Internet, established/related: count + accept
  echo "        ip saddr @tvs ip daddr != $LAN_SUBNET counter accept"
  # Return traffic to TVs (defensive; required once we become a real gateway)
  echo "        ip daddr @tvs ct state established,related counter accept"
  # Everything else: pass to the existing UFW/Docker chains, unchanged
  echo "        counter continue"
  echo "    }"

  echo "    chain prerouting {"
  echo "        type nat hook prerouting priority -150 ;"
  # DNS-bypass control: TV -> any :53 (udp/tcp) EXCEPT our own Pi-hole IP ->
  # DNAT straight to the Pi-hole container.
  #
  # Why DNAT to the container IP instead of `redirect to :53`:
  #   * `redirect` makes the packet locally-deliverable, and Docker's userland
  #     docker-proxy (0.0.0.0:53) then relays it - so Pi-hole sees the client
  #     as 172.18.0.1 (the bridge IP) and we lose per-TV attribution of
  #     bypass attempts.
  #   * an explicit `dnat to <container-ip>` is the only NAT on the connection
  #     (Docker's own DOCKER DNAT is then skipped), the packet crosses the
  #     bridge with the TV's real source IP, and Pi-hole logs the true client.
  #     The reply is reverse-NATed back to the TV from $GATEWAY_IP:53.
  # If the container IP cannot be resolved (docker not running at boot), we
  # fall back to `redirect` - the query still reaches Pi-hole, attribution
  # just shows the bridge IP.
  # DNS-bypass forcing is PRIVACY-SCOPED per vendor: external :53 is forced
  # to Pi-hole for each vendor's applies_to TVs only (per-vendor client sets
  # rendered above). TVs outside every policy are unaffected.
  if [ -n "$PRIVACY_PREROUTING" ]; then
    printf '%s' "$PRIVACY_PREROUTING"
  fi
  echo "    }"

  echo "    chain postrouting {"
  echo "        type nat hook postrouting priority srcnat ;"
  # One-arm / gateway masquerade: TV -> Internet (non-LAN) leaves via $EGRESS_IF.
  echo "        ip saddr @tvs ip daddr != $LAN_SUBNET oifname \"$EGRESS_IF\" counter masquerade"
  echo "    }"
  echo "}"
} > "$NFT_FILE"

echo "Mode:        $MODE"
if [ -n "$PRIVACY_SUMMARY" ]; then
  printf 'Privacy:     %b' "$PRIVACY_SUMMARY"
else
  echo "Privacy:     off"
fi
echo "Egress IF:   $EGRESS_IF"
echo "TVs:         $TV_LIST"
echo "Blocked:     ${BLOCKED_IPS:-<none>}"
echo "Pi-hole:     ${PIHOLE_CONTAINER_IP:-<redirect fallback>}"
echo "Rendered:    $NFT_FILE"

# --- Validate (dry-run) before touching anything -----------------------------
if ! nft -c -f "$NFT_FILE" 2> "$STATE_DIR/nft-check.err"; then
  echo "ERROR: nftables syntax check failed; nothing changed." >&2
  cat "$STATE_DIR/nft-check.err" >&2
  exit 5
fi

# --- Replace ONLY our table ---------------------------------------------------
if nft list table ip "$TGUARD_TABLE" >/dev/null 2>&1; then
  nft delete table ip "$TGUARD_TABLE"
fi
nft -f "$NFT_FILE"

UFW_LOOP=1
[ -n "${TGUARD_TVS:-}" ] && UFW_LOOP=0

# --- UFW forward allowance (per TV) -------------------------------------------
# CRITICAL: an ACCEPT verdict in our base chain (priority -150) does NOT stop
# the packet from being evaluated by the later `ip filter FORWARD` base chain
# (UFW, priority 0, policy DROP) on this kernel - proven with `nft monitor
# trace`. Our accept is therefore only meaningful for DROPS (a drop is final);
# the actual ACCEPT that lets TV traffic through UFW's deny-routed policy must
# live inside UFW's own chain. UFW's own API for that is `ufw route allow`,
# which lands in `ufw-user-forward` (evaluated before the policy drop).
# We add exactly one such rule per selected TV and remove exactly those on
# disable. Nothing else in UFW/Docker is touched.
if [ "$UFW_LOOP" = "1" ]; then
for tv in $TV_SOURCE; do
  if iptables -t filter -S ufw-user-forward 2>/dev/null | grep -E -q -- "-s $tv(/32)? -j ACCEPT"; then
    echo "  ufw route rule present: $tv"
  else
    if ufw route allow from "$tv" to any >/dev/null 2>&1; then
      echo "  + ufw route allow from $tv to any"
    else
      echo "  WARN: could not add ufw route rule for $tv (TV traffic will be dropped by UFW)" >&2
    fi
  fi
done
else
  echo "  (TGUARD_TVS set: UFW route-allow loop skipped - dry/test table)"
fi

# --- Sysctls (baseline captured so disable can restore) ----------------------
# Capture baseline once (don't clobber an existing baseline).
if [ ! -f "$STATE_DIR/sysctl.baseline" ]; then
  {
    echo "net.ipv4.ip_forward=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)"
    echo "net.ipv4.conf.$LAN_INTERFACE.send_redirects=$(sysctl -n net.ipv4.conf.$LAN_INTERFACE.send_redirects 2>/dev/null || echo 1)"
  } > "$STATE_DIR/sysctl.baseline"
fi

# Persist the sysctls we require and apply them now.
cat > "$STATE_DIR/sysctl.conf" <<EOF
# TVGuard runtime sysctls (managed; removed by tvguard-disable.sh)
net.ipv4.ip_forward=1
net.ipv4.conf.$LAN_INTERFACE.send_redirects=0
EOF
sysctl -p "$STATE_DIR/sysctl.conf" >/dev/null

# Also drop a /etc/sysctl.d file for reboot persistence (remove on disable).
mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/99-tvguard.conf <<EOF
# TVGuard (one-arm PoC). Managed by scripts/tvguard-apply.sh.
net.ipv4.ip_forward=1
net.ipv4.conf.$LAN_INTERFACE.send_redirects=0
EOF

# --- Persist mode -------------------------------------------------------------
# (skipped for dry/test tables - they must not rewrite the real state file)
if [ -z "${TGUARD_TVS:-}" ]; then
{
  echo "MODE=$MODE"
  echo "APPLIED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "EGRESS_IF=$EGRESS_IF"
  echo "TVS=$TVS"
  echo "UFW_ROUTE_RULES=managed per TV via 'ufw route allow from <tv> to any'"
} > "$STATE_FILE"
else
  echo "  (TGUARD_TVS set: state file not written - dry/test table)"
fi

# Report the per-vendor privacy state (we never enable privacy
# from this script - that is privacy-policy-apply.sh's job). This keeps the
# state consistent if the file was hand-edited.
if [ -f "$PRIVACY_STATE_FILE" ]; then
  echo "  privacy state: $(grep -E '^PRIVACY(-[A-Za-z0-9]+)?=' "$PRIVACY_STATE_FILE" | tr '\n' ' ')" >&2
fi

echo "OK: TVGuard loaded in $MODE mode (table ip $TGUARD_TABLE)."
