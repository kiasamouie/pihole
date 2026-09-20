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
TV_LIST=""
for tv in $TVS; do
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
  echo "table ip tvguard {"
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

  echo "    chain forward {"
  echo "        type filter hook forward priority -150 ;"
  # TV -> LAN (incl. the hub .1). Accept. NOTE: flat L2 PoC - this is NOT LAN isolation.
  echo "        ip saddr @tvs ip daddr $LAN_SUBNET counter accept"
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
  if [ -n "$PIHOLE_CONTAINER_IP" ]; then
    echo "        ip saddr @tvs ip daddr != $PIHOLE_IP meta l4proto udp th dport 53 dnat to $PIHOLE_CONTAINER_IP:53"
    echo "        ip saddr @tvs ip daddr != $PIHOLE_IP meta l4proto tcp th dport 53 dnat to $PIHOLE_CONTAINER_IP:53"
  else
    echo "        ip saddr @tvs ip daddr != $PIHOLE_IP meta l4proto udp th dport 53 redirect to :53"
    echo "        ip saddr @tvs ip daddr != $PIHOLE_IP meta l4proto tcp th dport 53 redirect to :53"
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
if nft list table ip tvguard >/dev/null 2>&1; then
  nft delete table ip tvguard
fi
nft -f "$NFT_FILE"

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
for tv in $TVS; do
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
{
  echo "MODE=$MODE"
  echo "APPLIED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "EGRESS_IF=$EGRESS_IF"
  echo "TVS=$TVS"
  echo "UFW_ROUTE_RULES=managed per TV via 'ufw route allow from <tv> to any'"
} > "$STATE_FILE"

echo "OK: TVGuard loaded in $MODE mode (table ip tvguard)."
