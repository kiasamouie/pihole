#!/usr/bin/env bash
#
# bootstrap.sh — deploy this TVGuard PoC onto a fresh Debian machine.
#
# This takes a clean Debian 12/13 x86_64 host and installs everything in this
# repository EXCEPT it does NOT:
#   * change the host's default route or gateway
#   * enable the TVGuard firewall (run scripts/tvguard-enable-monitor.sh later)
#   * point any device at the new box
#
# What it DOES:
#   1. check prerequisites (OS, root, free ports, existing listeners)
#   2. install packages (Docker via the official repo if absent, nftables,
#      ufw, conntrack, iproute2, tcpdump, dnsutils, python3, curl)
#   3. create .env (random admin password) and config/tvguard.conf from examples
#   4. deploy Pi-hole (pinned image) via docker compose
#   5. recreate the per-device groups + run the Pi-hole self-test
#   6. install the tvguard.service unit (disabled by default)
#   7. validate and print the machine-specific values that still need setting
#
# Idempotent: re-running is safe. Run as root:  sudo ./bootstrap.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAIL=0
err(){ echo "  [FAIL] $*" >&2; FAIL=1; }
ok(){  echo "  [ ok ] $*"; }

echo "=== TVGuard bootstrap on $(hostname) ==="

# --- 0. prerequisites -----------------------------------------------------------
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 3; }
. /etc/os-release 2>/dev/null || true
case "${ID:-}" in
  debian) ok "Debian ${VERSION_ID:-?}" ;;
  *) err "expected Debian (ID=${ID:-unknown}) - refusing to continue" ;;
esac
[ "$FAIL" -eq 0 ] || exit 1

# --- 1. packages ------------------------------------------------------------------
PKGS="nftables ufw conntrack iproute2 tcpdump dnsutils python3 curl ca-certificates"
if ! command -v docker >/dev/null 2>&1; then
  echo "  installing Docker (official Docker apt repository)..."
  install -m 0755 /etc/apt/keyrings/docker.asc /dev/null 2>/dev/null || true
  if [ ! -f /etc/apt/keyrings/docker.asc ]; then
    install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor \
      > /etc/apt/keyrings/docker.asc
  fi
  if ! grep -q "download.docker.com" /etc/apt/sources.list.d/docker.list 2>/dev/null; then
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update >/dev/null 2>&1
  fi
  PKGS="$PKGS docker-ce docker-ce-cli docker-buildx-plugin docker-compose-plugin"
fi
echo "  apt-get install: $PKGS"
apt-get install -y $PKGS >/dev/null 2>&1 || err "package installation failed"

for c in nft ufw conntrack tcpdump dig python3 curl; do
  command -v "$c" >/dev/null 2>&1 && ok "found: $c" || err "missing tool: $c"
done
command -v docker >/dev/null 2>&1 && ok "docker: $(docker --version 2>/dev/null)" || err "docker missing"
[ "$FAIL" -eq 0 ] || { echo; echo "prerequisites failed - fix and re-run"; exit 1; }

# --- 2. port conflict checks -------------------------------------------------------
echo
echo "=== port checks (existing services win - we adapt, never displace) ==="
for p in 53 3001 3443 8088; do
  if ss -lntup 2>/dev/null | awk -v p=":$p" '$4==p || $5==p' | grep -q .; then
    err "port $p is already in use:"
    ss -lntup 2>/dev/null | awk -v p=":$p" '$4==p || $5==p' | sed 's/^/       /'
  else
    ok "port $p free"
  fi
done
# UDP 53
if ss -lntup 2>/dev/null | awk '$4 ~ /:53$/ || $5 ~ /:53$/' | grep -q .; then
  err "UDP/TCP 53 already in use (see above); adjust compose.yaml before continuing"
fi
[ "$FAIL" -eq 0 ] || { echo; echo "port conflicts - STOP. Nothing was deployed."; exit 1; }

# --- 3. config from examples ---------------------------------------------------------
cd "$ROOT"
if [ ! -f .env ]; then
  echo
  echo "=== creating .env (admin password) ==="
  scripts/make-env.sh || err "make-env.sh failed"
  chmod 600 .env 2>/dev/null
  echo "  password is stored in .env (mode 600) - record it now"
else
  ok ".env already present"
fi
if [ ! -f config/tvguard.conf ]; then
  echo
  echo "=== creating config/tvguard.conf from example ==="
  cp config/tvguard.conf.example config/tvguard.conf
  ok "created - EDIT IT: interface, subnet, IPs, TV list (see below)"
else
  ok "config/tvguard.conf already present"
fi

# --- 4. Pi-hole -----------------------------------------------------------------------
echo
echo "=== Pi-hole ==="
if [ "$FAIL" -eq 0 ]; then
  docker compose up -d >/dev/null 2>&1 && ok "compose stack up" || err "docker compose up failed"
  sleep 5
  if dig +time=3 +tries=2 @127.0.0.1 example.com 2>/dev/null | grep -q NOERROR; then
    ok "local DNS answering (NOERROR)"
  else
    err "Pi-hole DNS not answering on 127.0.0.1:53 - check: docker logs pihole"
  fi
  if python3 scripts/pihole-selftest.py >/dev/null 2>&1; then
    ok "Pi-hole self-test passed (login, block, allow, query log)"
  else
    err "Pi-hole self-test FAILED - inspect with: python3 scripts/pihole-selftest.py"
  fi
  if python3 scripts/setup-pihole-groups.py >/dev/null 2>&1; then
    ok "per-device groups/clients registered"
  else
    err "group setup failed - inspect with: python3 scripts/setup-pihole-groups.py"
  fi
fi

# --- 5. TVGuard unit (NOT enabled) ----------------------------------------------------
echo
echo "=== TVGuard firewall unit (installed, NOT enabled) ==="
sed -e "s|@ROOT@|$ROOT|g" -e "s|@STATE_DIR@|/var/lib/tvguard|g" \
  deploy/tvguard.service.in > /etc/systemd/system/tvguard.service
systemctl daemon-reload >/dev/null 2>&1
ok "unit installed (inactive). Enable later with:"
echo "      sudo scripts/tvguard-enable-monitor.sh   (monitor = logging only)"
echo "  Revert anytime with:  sudo scripts/tvguard-disable.sh"

# --- 6. summary -----------------------------------------------------------------------
echo
echo "========================================================"
echo " Bootstrap complete. Machine-specific values to review:"
echo "========================================================"
grep -E '^(MODE|LAN_INTERFACE|LAN_SUBNET|GATEWAY_IP|UPSTREAM_ROUTER|TVS|WAN_INTERFACE)=' \
  config/tvguard.conf 2>/dev/null | sed 's/^/  /'
echo
echo "  * LAN_INTERFACE/LAN_SUBNET/GATEWAY_IP must match THIS machine's interface and IP"
echo "  * Reserve this box's IP in the router (see docs/ROUTER_NEXT_STEPS_V2.md)"
echo "  * TVGuard is NOT active: run scripts/tvguard-enable-monitor.sh when ready"
echo "  * Nothing was pointed at this box; no routing/NAT is in effect yet"
[ "$FAIL" -eq 0 ] || echo
[ "$FAIL" -eq 0 ] && echo "  RESULT: BOOTSTRAP OK" || echo "  RESULT: COMPLETED WITH FAILURES (see above)"
exit "$FAIL"
