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

# --- Privacy policy state (separate dimension from monitor/enforce) ----------
# Set by scripts/privacy-policy-apply.sh (standard|standard-no-voice|strict|
# manufacturer-lockdown) and privacy-policy-disable.sh (off). When active, the resolved IP list produced by privacy-
# policy-build.py (data/privacy-policy/resolved.json) is rendered as an extra
# DROP set in the forward chain. It never changes NAT, the DNS-bypass DNAT,
# or the TVGuard monitor/enforce mode. When off, the rendered table is
# byte-identical to the pre-privacy ruleset.
# PRIVACY-SCOPE FIX (2026-09-22): the privacy rules (deny-set drop, DoT 853,
# external :53 DNAT) must match ONLY the policy's `applies_to` list from
# config/privacy-policy.yaml (Samsung .197), NOT the full TVS list (which
# also contains e.g. the Google TV .90, explicitly outside applies_to).
# They therefore match a dedicated `tv_privacy` set. TVS-only rules
# (TV->LAN accept, TV->Internet monitor log/accept, masquerade, return traffic)
# are unchanged.
PRIVACY_STATE_FILE="$STATE_DIR/privacy-state"
PRIVACY_RESOLVED="$ROOT/data/privacy-policy/resolved.json"
PRIVACY_MODE="off"
if [ -f "$PRIVACY_STATE_FILE" ]; then
  PRIVACY_MODE="$(sed -n 's/^PRIVACY=//p' "$PRIVACY_STATE_FILE" | tail -1)"
fi
case "$PRIVACY_MODE" in standard|standard-no-voice|strict|manufacturer-lockdown) : ;; *) PRIVACY_MODE="off" ;; esac
PRIVACY_IPS=""
PRIVACY_DOH_IPS=""
PRIVACY_TV_SOURCE=""
PRIVACY_TV_LIST=""
if [ "$PRIVACY_MODE" != "off" ]; then
  PRIVACY_TV_SOURCE="${PRIVACY_TARGETS:-}"
  if [ -z "$PRIVACY_TV_SOURCE" ]; then
    PRIVACY_TV_SOURCE="$(python3 - "$ROOT/config/privacy-policy.yaml" <<'PYEOF' 2>/dev/null
targets, in_list = [], False
for line in open(__import__("sys").argv[1]):
    s = line.strip()
    if s.startswith("applies_to:"):
        in_list = True
        continue
    if in_list:
        if s.startswith("- "):
            item = s[2:].split("#", 1)[0]
            targets.append(item.strip().strip('"').strip("'"))
        elif s and not s.startswith("#"):
            in_list = False
print(" ".join(target for target in targets if target))
PYEOF
)"
  fi
  PRIVACY_TV_SOURCE="${PRIVACY_TV_SOURCE:-$TVS}"
  PRIVACY_TV_LIST=""
  for tv in $PRIVACY_TV_SOURCE; do
    PRIVACY_TV_LIST="${PRIVACY_TV_LIST}${PRIVACY_TV_LIST:+, }$tv"
  done
  if [ -f "$PRIVACY_RESOLVED" ] && command -v python3 >/dev/null 2>&1; then
    PRIVACY_IPS="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(" ".join(sorted(d.get(sys.argv[2],{}).get("ips",[]))))' "$PRIVACY_RESOLVED" "$PRIVACY_MODE" 2>/dev/null)"
    PRIVACY_DOH_IPS="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(" ".join(sorted(d.get("doh",{}).get("ips",[]))))' "$PRIVACY_RESOLVED" 2>/dev/null)"
  fi
fi
PRIVACY_IPS_CSV="${PRIVACY_IPS// /, }"
PRIVACY_DOH_IPS_CSV="${PRIVACY_DOH_IPS// /, }"

# Resolve the Pi-hole container IP for the DNS-bypass DNAT (see prerouting
# comment). Empty => render falls back to `redirect`.
PIHOLE_CONTAINER_IP=""
if command -v docker >/dev/null 2>&1; then
  PIHOLE_CONTAINER_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' pihole 2>/dev/null | awk 'NF' | head -1)
  [ -n "$PIHOLE_CONTAINER_IP" ] || echo "WARN: could not resolve pihole container IP; DNS bypass will use redirect fallback" >&2
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

  # Privacy policy sets (present only when a privacy tier is active).
  if [ "$PRIVACY_MODE" != "off" ]; then
    echo "    set tv_privacy {"
    echo "        type ipv4_addr ;"
    echo "        elements = { $PRIVACY_TV_LIST } ;"
    echo "    }"
  fi
  if [ -n "$PRIVACY_IPS" ]; then
    echo "    set tv_privacy_blocked {"
    echo "        type ipv4_addr ;"
    echo "        flags interval ;"
    echo "        elements = { $PRIVACY_IPS_CSV } ;"
    echo "    }"
  fi
  if [ "$PRIVACY_MODE" = "strict" ] && [ -n "$PRIVACY_DOH_IPS" ]; then
    echo "    set tv_doh_blocked {"
    echo "        type ipv4_addr ;"
    echo "        flags interval ;"
    echo "        elements = { $PRIVACY_DOH_IPS_CSV } ;"
    echo "    }"
  fi

  echo "    chain forward {"
  echo "        type filter hook forward priority -150 ;"
  # TV -> LAN (incl. the hub .1). Accept. NOTE: flat L2 PoC - this is NOT LAN isolation.
  echo "        ip saddr @tvs ip daddr $LAN_SUBNET counter accept"
  # Privacy policy drops (new connections from a PRIVACY-SCOPED TV to resolved
  # deny-list IPs / known DoH endpoint IPs). Matches @tv_privacy (applies_to
  # only - never the full tvs list), so TVs outside the policy (e.g. the
  # Google TV) are unaffected. ct state new means established flows keep
  # working until they end; blocked attempts are logged.
  if [ -n "$PRIVACY_IPS" ]; then
    echo "        ip saddr @tv_privacy ip daddr @tv_privacy_blocked ct state new counter log prefix \"TVGUARD-PRIVACY \" drop"
  fi
  if [ "$PRIVACY_MODE" = "strict" ] && [ -n "$PRIVACY_DOH_IPS" ]; then
    echo "        ip saddr @tv_privacy ip daddr @tv_doh_blocked ct state new counter log prefix \"TVGUARD-DOH \" drop"
  fi
  if [ "$PRIVACY_MODE" != "off" ]; then
    echo "        ip saddr @tv_privacy tcp dport 853 ct state new counter log prefix \"TVGUARD-DOT \" drop"
    echo "        ip saddr @tv_privacy udp dport 853 ct state new counter log prefix \"TVGUARD-DOT \" drop"
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
  # DNS-bypass forcing is PRIVACY-SCOPED too (@tv_privacy): external :53 is
  # forced to Pi-hole for the policy's applies_to TVs only. TVs outside the
  # policy (e.g. the Google TV, which uses the Hub as gateway and does not
  # traverse this box) are unaffected.
  if [ "$PRIVACY_MODE" != "off" ]; then
    if [ -n "$PIHOLE_CONTAINER_IP" ]; then
      echo "        ip saddr @tv_privacy ip daddr != $PIHOLE_IP meta l4proto udp th dport 53 dnat to $PIHOLE_CONTAINER_IP:53"
      echo "        ip saddr @tv_privacy ip daddr != $PIHOLE_IP meta l4proto tcp th dport 53 dnat to $PIHOLE_CONTAINER_IP:53"
    else
      echo "        ip saddr @tv_privacy ip daddr != $PIHOLE_IP meta l4proto udp th dport 53 redirect to :53"
      echo "        ip saddr @tv_privacy ip daddr != $PIHOLE_IP meta l4proto tcp th dport 53 redirect to :53"
    fi
  fi
  echo "    }"

  echo "    chain postrouting {"
  echo "        type nat hook postrouting priority srcnat ;"
  # One-arm / gateway masquerade: TV -> Internet (non-LAN) leaves via $EGRESS_IF.
  echo "        ip saddr @tvs ip daddr != $LAN_SUBNET oifname \"$EGRESS_IF\" counter masquerade"
  echo "    }"
  echo "}"
} > "$NFT_FILE"

PRIVACY_IP_COUNT=$(printf '%s' "$PRIVACY_IPS" | awk '{print NF}')
PRIVACY_DOH_COUNT=$(printf '%s' "$PRIVACY_DOH_IPS" | awk '{print NF}')
echo "Mode:        $MODE"
echo "Privacy:     $PRIVACY_MODE (deny-IPs: $PRIVACY_IP_COUNT, doh-IPs: $PRIVACY_DOH_COUNT, scope: ${PRIVACY_TV_LIST:-n/a})"
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

# Refresh the privacy-state file only if it exists (we never enable privacy
# from this script - that is privacy-policy-apply.sh's job). This keeps the
# state consistent if the file was hand-edited.
if [ -f "$PRIVACY_STATE_FILE" ]; then
  echo "  privacy state: $PRIVACY_MODE" >&2
fi

echo "OK: TVGuard loaded in $MODE mode (table ip $TGUARD_TABLE)."
