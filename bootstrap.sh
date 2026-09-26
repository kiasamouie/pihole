#!/usr/bin/env bash
#
# bootstrap.sh - deploy this TVGuard + Pi-hole box onto a fresh Linux machine.
#
# Supported host contract:
#   * systemd-based Linux with Docker + Compose v2, nftables, UFW, conntrack,
#     iproute2 available (auto-installed on Debian/Ubuntu-family; on other
#     distros this script VALIDATES the toolset and stops with the exact
#     prerequisites instead of touching unknown package managers)
#   * a single LAN interface that connects to the home network whose router
#     stays router + DHCP (this box never runs DHCP)
#
# What it DOES (idempotent, safe to re-run; run as root:  sudo ./bootstrap.sh):
#   1. check prerequisites (root, OS/toolset, port conflicts on 53/3001/3443)
#   2. install missing packages (Debian/Ubuntu only, Docker via official repo)
#   3. create .env (the ONLY machine-specific file: generated admin password +
#      host facts it can discover) - never overwrites an existing .env
#   4. deploy Pi-hole (pinned image) via docker compose, self-test
#   5. install the tvguard.service unit (disabled by default)
#   6. validate + print what still needs the user (router reservation, TV list)
#
# What it does NOT do:
#   * change the host's default route, enable DHCP, or touch UFW rules
#   * enable the TVGuard firewall (scripts/tvguard-enable-monitor.sh later)
#   * point any device at this box

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAIL=0
err(){ echo "  [FAIL] $*" >&2; FAIL=1; }
ok(){  echo "  [ ok ] $*"; }
warn(){ echo "  [warn] $*"; }

echo "=== TVGuard bootstrap on $(hostname) ==="

# --- 0. prerequisites -----------------------------------------------------------
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 3; }

. /etc/os-release 2>/dev/null || true
DISTRO_ID="${ID:-}"
DISTRO_LIKE="${ID_LIKE:-}"
case "$DISTRO_ID $DISTRO_LIKE" in
  *debian*|*ubuntu*|*linuxmint*|*pop*) APT=1 ;;
  *) APT=0 ;;
esac
echo "  distro: ${DISTRO_ID:-unknown} (ID_LIKE=${DISTRO_LIKE:-none})"

REQUIRED_CMDS="nft ufw conntrack tcpdump dig python3 curl docker ss ip"
if [ "$APT" -eq 0 ]; then
  echo
  echo "  Not a Debian/Ubuntu-family distro: this script will NOT install"
  echo "  packages. It validates the toolset and stops if anything is missing."
  missing=""
  for c in $REQUIRED_CMDS; do
    command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
  done
  if [ -n "$missing" ]; then
    err "missing required tools:$missing"
    echo "  Install them manually (Docker + compose plugin, nftables, ufw,"
    echo "  conntrack, iproute2, tcpdump, dnsutils, python3+python3-yaml, curl)"
    echo "  then re-run ./bootstrap.sh"
    exit 1
  fi
  ok "all required tools present"
else
  ok "Debian/Ubuntu-family: $DISTRO_ID - package installation enabled"
fi

# --- 1. packages (Debian/Ubuntu only) --------------------------------------------
if [ "$APT" -eq 1 ]; then
  export DEBIAN_FRONTEND=noninteractive
  PKGS="nftables ufw conntrack iproute2 tcpdump dnsutils python3 python3-yaml \
        python3-pip curl ca-certificates gpg"
  if ! command -v docker >/dev/null 2>&1; then
    echo "  installing Docker (official Docker apt repository)..."
    # NOTE: never run `install ... /dev/null` - a stale keyring file would be
    # clobbered into /dev/null. Only create the keyring when absent.
    if [ ! -f /etc/apt/keyrings/docker.asc ]; then
      install -d -m 0755 /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/debian/gpg \
        | gpg --dearmor > /etc/apt/keyrings/docker.asc
    fi
    if ! grep -q "download.docker.com" /etc/apt/sources.list.d/docker.list 2>/dev/null; then
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
        > /etc/apt/sources.list.d/docker.list
      apt-get update >/dev/null 2>&1
    fi
    PKGS="$PKGS docker-ce docker-ce-cli docker-buildx-plugin docker-compose-plugin"
  fi
  if ! command -v docker-compose >/dev/null 2>&1 && ! docker compose version >/dev/null 2>&1; then
    PKGS="$PKGS docker-compose-plugin"
  fi
  apt-get install -y $PKGS >/dev/null 2>&1 || err "package installation failed (re-run manually to see output)"
fi

echo
for c in $REQUIRED_CMDS; do
  command -v "$c" >/dev/null 2>&1 && ok "found: $c" || err "missing tool: $c"
done
python3 -c 'import yaml' 2>/dev/null && ok "python3-yaml importable" || err "python3-yaml missing (pip3 install pyyaml or apt python3-yaml)"
docker compose version >/dev/null 2>&1 && ok "docker compose v2" || err "docker compose plugin missing"
[ "$FAIL" -eq 0 ] || { echo; echo "prerequisites failed - fix and re-run"; exit 1; }

# --- 2. port conflict checks -------------------------------------------------------
# Pi-hole needs 53/tcp+udp and 3001/tcp free. 3443/tcp (admin HTTPS) is soft.
echo
echo "=== port checks (existing services win - we adapt, never displace) ==="
port_in_use() {  # $1 = port; matches the local :port column (v4 and v6 forms)
  ss -lntup 2>/dev/null | awk -v port="$1" 'NR>1 { n=split($4, a, ":"); if (a[n]==port) print "  "$0 }'
}
for p in 53 3001 3443; do
  if out="$(port_in_use "$p")" && [ -n "$out" ]; then
    err "port $p is already in use by:"
    echo "$out"
    if [ "$p" = "53" ]; then
      echo "  STOP: something else owns DNS on this box. TVGuard cannot displace it."
    fi
  else
    ok "port $p free"
  fi
done
[ "$FAIL" -eq 0 ] || { echo; echo "port conflicts - STOP. Nothing was deployed."; exit 1; }

# --- 3. host facts + .env -----------------------------------------------------------
cd "$ROOT"
# Discover: LAN interface = interface of the IPv4 default route; subnet from it.
DEF_ROUTE="$(ip -4 route show default 2>/dev/null | head -1)"
LAN_IF="$(echo "$DEF_ROUTE" | awk '{print $5}')"
LAN_IP="$(ip -4 -o addr show "$LAN_IF" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
LAN_SUBNET="$(ip -4 -o addr show "$LAN_IF" 2>/dev/null | awk '{print $4}' | head -1)"
DEFAULT_GW="$(echo "$DEF_ROUTE" | awk '{print $3}')"

if [ ! -f .env ]; then
  echo
  echo "=== creating .env (admin password + discovered host facts) ==="
  scripts/make-env.sh || err "make-env.sh failed"
  # Fill in the discovered facts (leave TV lists blank - discovery is explicit).
  [ -n "$LAN_IF" ]     && sed -i "s|^LAN_INTERFACE=.*|LAN_INTERFACE=$LAN_IF|" .env
  [ -n "$LAN_SUBNET" ] && sed -i "s|^LAN_SUBNET=.*|LAN_SUBNET=$LAN_SUBNET|" .env
  [ -n "$LAN_IP" ]     && sed -i "s|^GATEWAY_IP=.*|GATEWAY_IP=$LAN_IP|" .env
  [ -n "$LAN_IP" ]     && sed -i "s|^PIHOLE_IP=.*|PIHOLE_IP=$LAN_IP|" .env
  [ -n "$LAN_IP" ]     && sed -i "s|^PIHOLE_BIND_IP=.*|PIHOLE_BIND_IP=$LAN_IP|" .env
  [ -n "$DEFAULT_GW" ] && sed -i "s|^UPSTREAM_ROUTER=.*|UPSTREAM_ROUTER=$DEFAULT_GW|" .env
  # Make the non-root user able to read it (scripts read .env for the password).
  if [ -n "${SUDO_USER:-}" ] && id "$SUDO_USER" >/dev/null 2>&1; then
    chown "$SUDO_USER" .env && ok ".env owned by $SUDO_USER (mode 600)"
  else
    ok ".env created (mode 600, root-owned)"
  fi
  echo "  LAN facts filled: interface=$LAN_IF subnet=$LAN_SUBNET box=$LAN_IP upstream=$DEFAULT_GW"
  echo "  TV lists left BLANK - identify your TVs with scripts/discover-lan.sh first"
else
  ok ".env already present (not modified)"
fi

# IPv6 gate: a usable IPv6 default route means an uncontrolled v6 egress path
# that would bypass the privacy firewall. Report it, never change it.
if ip -6 route show 2>/dev/null | grep -q 'default'; then
  warn "this host has an IPv6 default route: IPv6 egress from the TVs would"
  warn "bypass the privacy firewall. The privacy phase must not start until"
  warn "this is resolved on the router (disable RA / v6 WAN) - see docs/ROLLBACK.md"
else
  ok "no IPv6 default route (v6 bypass not applicable)"
fi

# --- 4. Pi-hole -----------------------------------------------------------------------
echo
echo "=== Pi-hole ==="
if [ "$FAIL" -eq 0 ]; then
  docker compose up -d >/dev/null 2>&1 && ok "compose stack up" || err "docker compose up failed (check: docker compose logs pihole)"
  # Wait for FTL to answer (bounded, not a fixed sleep).
  answered=0
  for i in $(seq 1 15); do
    if dig +time=2 +tries=1 @127.0.0.1 example.com 2>/dev/null | grep -q NOERROR; then
      answered=1; break
    fi
    sleep 2
  done
  if [ "$answered" -eq 1 ]; then
    ok "local DNS answering (NOERROR)"
  else
    err "Pi-hole DNS not answering on 127.0.0.1:53 - inspect: docker logs pihole"
  fi
  if python3 scripts/pihole-selftest.py >/dev/null 2>&1; then
    ok "Pi-hole self-test passed (login, block, allow, query log)"
  else
    err "Pi-hole self-test FAILED - inspect with: python3 scripts/pihole-selftest.py"
  fi
  if python3 scripts/setup-pihole-groups.py >/dev/null 2>&1; then
    ok "per-device Pi-hole groups/clients registered"
  else
    err "group setup failed - inspect with: python3 scripts/setup-pihole-groups.py"
  fi
fi

# --- 5. TVGuard unit (NOT enabled) ----------------------------------------------------
echo
echo "=== TVGuard firewall unit (installed, NOT enabled) ==="
if command -v systemctl >/dev/null 2>&1; then
  sed -e "s|@ROOT@|$ROOT|g" -e "s|@STATE_DIR@|/var/lib/tvguard|g" \
    deploy/tvguard.service.in > /etc/systemd/system/tvguard.service
  systemctl daemon-reload >/dev/null 2>&1
  ok "unit installed (inactive). Enable later with:"
  echo "      sudo scripts/tvguard-enable-monitor.sh   (monitor = logging only)"
  echo "  Revert anytime with:  sudo scripts/tvguard-disable.sh"
else
  warn "systemd not found: the tvguard.service unit was NOT installed."
  warn "TVGuard can still be applied manually with sudo scripts/tvguard-apply.sh"
fi

# --- 6. summary -----------------------------------------------------------------------
echo
echo "========================================================"
echo " Bootstrap complete. Machine config in .env (git-ignored):"
echo "========================================================"
grep -E '^(MODE|LAN_INTERFACE|LAN_SUBNET|GATEWAY_IP|PIHOLE_IP|UPSTREAM_ROUTER|TVS|SAMSUNG_TVS|LG_TVS|GOOGLE_TVS|WAN_INTERFACE)=' .env | sed 's/^/  /'
echo
echo "  NEXT STEPS (see AGENTS.md for the full runbook):"
echo "  1. Reserve this box's IP for its MAC in the router (it stays router+DHCP)."
echo "  2. Identify the TVs:  scripts/discover-lan.sh   and fill TVS/*_TVS in .env"
echo "  3. Point each TV's manual IP at this box (gateway + DNS = box IP)."
echo "  4. sudo scripts/tvguard-enable-monitor.sh   (logging only - nothing blocked)"
echo "  5. Privacy blocking: sudo scripts/privacy-policy-apply.sh <vendor> <tier>"
echo
[ "$FAIL" -eq 0 ] && echo "  RESULT: BOOTSTRAP OK" || echo "  RESULT: COMPLETED WITH FAILURES (see above)"
exit "$FAIL"
