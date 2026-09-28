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
MIGRATE_REPOSITORY_PATH=0
err(){ echo "  [FAIL] $*" >&2; FAIL=1; }
ok(){  echo "  [ ok ] $*"; }
warn(){ echo "  [warn] $*"; }
tvguard_compose(){ docker compose --project-name tvguard "$@"; }
gravity_db_ok(){
  PIHOLE_DB="$1" python3 - <<'PY' >/dev/null 2>&1
import os, sqlite3
path = os.environ["PIHOLE_DB"]
con = sqlite3.connect("file:%s?mode=ro" % path, uri=True)
result = con.execute("PRAGMA quick_check").fetchone()[0]
con.close()
if result != "ok":
    raise SystemExit(result)
PY
}

case "${1:-}" in
  "") ;;
  --migrate-repository-path) MIGRATE_REPOSITORY_PATH=1 ;;
  -h|--help)
    echo "Usage: sudo $0 [--migrate-repository-path]"
    echo "  --migrate-repository-path  adopt this clone's existing valid Pi-hole state"
    echo "                             after the same repository was physically moved"
    exit 0
    ;;
  *) echo "Usage: sudo $0 [--migrate-repository-path]" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { echo "Usage: sudo $0 [--migrate-repository-path]" >&2; exit 2; }

if [ -n "${COMPOSE_PROJECT_NAME:-}" ] && [ "$COMPOSE_PROJECT_NAME" != "tvguard" ]; then
  warn "ignoring COMPOSE_PROJECT_NAME=$COMPOSE_PROJECT_NAME; this deployment always uses project 'tvguard'"
fi

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

# --- 2. existing-container + port checks ------------------------------------------
# A named Pi-hole container is managed here only when /etc/pihole is bound to
# this clone. A physical repository move requires an explicit migration flag and
# a valid database in the new location; bootstrap never guesses between states.
EXPECTED_PIHOLE_MOUNT="$(readlink -f "$ROOT/etc-pihole")"
PIHOLE_EXISTS=0
PIHOLE_MANAGED=0
PIHOLE_REPLACE=0
EXISTING_PIHOLE_MOUNT=""
EXISTING_PIHOLE_PROJECT=""
EXISTING_PIHOLE_STATE=""
if docker inspect pihole >/dev/null 2>&1; then
  PIHOLE_EXISTS=1
  EXISTING_PIHOLE_MOUNT="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/etc/pihole"}}{{.Source}}{{end}}{{end}}' pihole 2>/dev/null || true)"
  EXISTING_PIHOLE_PROJECT="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' pihole 2>/dev/null || true)"
  EXISTING_PIHOLE_STATE="$(docker inspect -f '{{.State.Status}}' pihole 2>/dev/null || true)"
  EXISTING_PIHOLE_MOUNT_CANON="$(readlink -f "$EXISTING_PIHOLE_MOUNT" 2>/dev/null || true)"

  if [ -z "$EXISTING_PIHOLE_MOUNT" ]; then
    err "named container 'pihole' does not bind /etc/pihole; bootstrap will not replace it"
  elif [ "$EXISTING_PIHOLE_MOUNT_CANON" = "$EXPECTED_PIHOLE_MOUNT" ]; then
    PIHOLE_MANAGED=1
    ok "existing pihole container uses this clone's persisted state"
  elif [ "$MIGRATE_REPOSITORY_PATH" -eq 1 ]; then
    if [ ! -r "$EXPECTED_PIHOLE_MOUNT/gravity.db" ]; then
      err "repository-path migration requires a readable database at $EXPECTED_PIHOLE_MOUNT/gravity.db"
    elif ! gravity_db_ok "$EXPECTED_PIHOLE_MOUNT/gravity.db"; then
      err "repository-path migration database failed SQLite integrity checking"
    elif [ -e "$EXISTING_PIHOLE_MOUNT/gravity.db" ] \
         && [ ! "$EXISTING_PIHOLE_MOUNT/gravity.db" -ef "$EXPECTED_PIHOLE_MOUNT/gravity.db" ]; then
      err "old mount still contains a different gravity.db; refusing ambiguous migration"
      echo "  current clone: $EXPECTED_PIHOLE_MOUNT/gravity.db" >&2
      echo "  old mount:     $EXISTING_PIHOLE_MOUNT/gravity.db" >&2
    else
      PIHOLE_MANAGED=1
      PIHOLE_REPLACE=1
      warn "approved repository-path migration: $EXISTING_PIHOLE_MOUNT -> $EXPECTED_PIHOLE_MOUNT"
    fi
  else
    err "named container 'pihole' is bound to a different repository path"
    echo "  expected: $EXPECTED_PIHOLE_MOUNT" >&2
    echo "  actual:   $EXISTING_PIHOLE_MOUNT" >&2
    echo "  STOP: if this exact repository was physically moved, verify its state and rerun:" >&2
    echo "        sudo ./bootstrap.sh --migrate-repository-path" >&2
  fi

  if [ "$PIHOLE_MANAGED" -eq 1 ] && [ "$EXISTING_PIHOLE_PROJECT" != "tvguard" ]; then
    PIHOLE_REPLACE=1
    warn "legacy Compose project '${EXISTING_PIHOLE_PROJECT:-unknown}' will be reconciled to 'tvguard' after preflight"
  fi
fi

PIHOLE_FIRST_INSTALL=0
if [ "$PIHOLE_EXISTS" -eq 1 ]; then
  if [ "$PIHOLE_MANAGED" -eq 1 ] && [ ! -r "$EXPECTED_PIHOLE_MOUNT/gravity.db" ]; then
    err "existing Pi-hole deployment has no readable gravity.db; refusing to initialize replacement state"
  elif [ "$PIHOLE_MANAGED" -eq 1 ] && ! gravity_db_ok "$EXPECTED_PIHOLE_MOUNT/gravity.db"; then
    err "existing Pi-hole gravity.db failed SQLite integrity checking"
  fi
elif [ -r "$EXPECTED_PIHOLE_MOUNT/gravity.db" ]; then
  if gravity_db_ok "$EXPECTED_PIHOLE_MOUNT/gravity.db"; then
    ok "existing container-free Pi-hole database passed SQLite integrity checking"
  else
    err "container-free Pi-hole gravity.db failed SQLite integrity checking"
  fi
elif [ -d "$EXPECTED_PIHOLE_MOUNT" ] \
     && [ -n "$(find "$EXPECTED_PIHOLE_MOUNT" -mindepth 1 -print -quit 2>/dev/null)" ]; then
  err "Pi-hole state directory is non-empty but gravity.db is missing; refusing to treat it as a fresh install"
else
  PIHOLE_FIRST_INSTALL=1
  ok "empty Pi-hole state confirmed for first installation"
fi
[ "$FAIL" -eq 0 ] || exit 1


# --- 3. host facts + .env -----------------------------------------------------------
cd "$ROOT" || exit 1
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
  ok ".env already present"
fi

# Older deployments may have a blank PIHOLE_BIND_IP. Normalize it once to the
# configured Pi-hole/LAN address; compose.yaml requires an explicit safe bind.
PIHOLE_CONFIG_IP="$(sed -n 's/^PIHOLE_IP=//p' .env | tail -1)"
PIHOLE_BIND_VALUE="$(sed -n 's/^PIHOLE_BIND_IP=//p' .env | tail -1)"
if [ -z "$PIHOLE_BIND_VALUE" ]; then
  PIHOLE_BIND_VALUE="${PIHOLE_CONFIG_IP:-$LAN_IP}"
  if [ -n "$PIHOLE_BIND_VALUE" ]; then
    if grep -q '^PIHOLE_BIND_IP=' .env; then
      sed -i "s|^PIHOLE_BIND_IP=.*|PIHOLE_BIND_IP=$PIHOLE_BIND_VALUE|" .env
    else
      printf '\nPIHOLE_BIND_IP=%s\n' "$PIHOLE_BIND_VALUE" >> .env
    fi
    ok "PIHOLE_BIND_IP normalized to $PIHOLE_BIND_VALUE"
  else
    err "PIHOLE_BIND_IP is blank and no host/Pi-hole IP could be discovered"
  fi
fi
chmod 600 .env

PIHOLE_CONFIG_IP="$(sed -n 's/^PIHOLE_IP=//p' .env | tail -1)"
PIHOLE_BIND_VALUE="$(sed -n 's/^PIHOLE_BIND_IP=//p' .env | tail -1)"
CONFIG_LAN_INTERFACE="$(sed -n 's/^LAN_INTERFACE=//p' .env | tail -1)"
CONFIG_LAN_SUBNET="$(sed -n 's/^LAN_SUBNET=//p' .env | tail -1)"
if ! CONFIG_PH="$PIHOLE_CONFIG_IP" CONFIG_BIND="$PIHOLE_BIND_VALUE" CONFIG_LAN="$CONFIG_LAN_SUBNET" python3 - <<'PY' >/dev/null 2>&1
import ipaddress
import os

lan = ipaddress.ip_network(os.environ["CONFIG_LAN"], strict=False)
pihole = ipaddress.IPv4Address(os.environ["CONFIG_PH"])
bind = ipaddress.IPv4Address(os.environ["CONFIG_BIND"])
if bind != pihole:
    raise ValueError("PIHOLE_BIND_IP must equal PIHOLE_IP")
if bind not in lan or bind in (lan.network_address, lan.broadcast_address):
    raise ValueError("PIHOLE_BIND_IP must be a usable LAN address")
if bind.is_unspecified or bind.is_loopback or bind.is_link_local or bind.is_multicast:
    raise ValueError("PIHOLE_BIND_IP is not a concrete LAN address")
PY
then
  err "PIHOLE_BIND_IP must equal PIHOLE_IP and be a concrete usable address in LAN_SUBNET"
elif [ -z "$CONFIG_LAN_INTERFACE" ] \
     || ! ip -4 -o addr show dev "$CONFIG_LAN_INTERFACE" 2>/dev/null \
          | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$PIHOLE_BIND_VALUE"; then
  err "PIHOLE_BIND_IP $PIHOLE_BIND_VALUE is not assigned to LAN_INTERFACE ${CONFIG_LAN_INTERFACE:-<blank>}"
else
  ok "Pi-hole LAN bind validated: $PIHOLE_BIND_VALUE on $CONFIG_LAN_INTERFACE"
fi
[ "$FAIL" -eq 0 ] || exit 1

# Check each exact endpoint that the replacement will publish. Endpoints already
# owned by the running managed container are safe because that container is
# removed only after every preflight succeeds; all others must be bindable now.
echo
echo "=== port checks (existing services win - we never displace them) ==="
EXISTING_BINDINGS=""
if [ "$PIHOLE_MANAGED" -eq 1 ] && [ "$EXISTING_PIHOLE_STATE" = "running" ]; then
  EXISTING_BINDINGS="$(docker inspect pihole 2>/dev/null | python3 -c '
import json, sys
container = json.load(sys.stdin)[0]
for container_port, rows in (container.get("HostConfig", {}).get("PortBindings") or {}).items():
    protocol = container_port.rsplit("/", 1)[-1]
    for row in rows or []:
        print("\t".join((protocol, row.get("HostIp", ""), row.get("HostPort", ""))))
' 2>/dev/null || true)"
fi
if PIHOLE_BIND="$PIHOLE_BIND_VALUE" EXISTING_BINDINGS="$EXISTING_BINDINGS" python3 - <<'PY'
import os
import socket
import sys

bind_ip = os.environ["PIHOLE_BIND"]
owned = []
for line in os.environ.get("EXISTING_BINDINGS", "").splitlines():
    parts = line.split("\t")
    if len(parts) != 3 or not parts[2].isdigit():
        continue
    owned.append((parts[0], parts[1], int(parts[2])))

def owned_by_managed(protocol, host_ip, host_port):
    return any(
        row_protocol == protocol
        and row_port == host_port
        and row_ip in ("", "0.0.0.0", host_ip)
        for row_protocol, row_ip, row_port in owned
    )

desired = (
    ("tcp", bind_ip, 53),
    ("udp", bind_ip, 53),
    ("tcp", bind_ip, 3001),
    ("tcp", "127.0.0.1", 3001),
    ("tcp", bind_ip, 3443),
)
failed = False
for protocol, host_ip, host_port in desired:
    if owned_by_managed(protocol, host_ip, host_port):
        continue
    sock_type = socket.SOCK_STREAM if protocol == "tcp" else socket.SOCK_DGRAM
    sock = socket.socket(socket.AF_INET, sock_type)
    try:
        sock.bind((host_ip, host_port))
    except OSError as exc:
        print(f"  required {protocol} endpoint {host_ip}:{host_port} is unavailable: {exc}", file=sys.stderr)
        failed = True
    finally:
        sock.close()
raise SystemExit(1 if failed else 0)
PY
then
  ok "required Pi-hole endpoints are owned by this container or available"
else
  err "one or more required Pi-hole endpoints belong to another service"
fi
[ "$FAIL" -eq 0 ] || { echo; echo "port conflicts - STOP. Nothing was deployed."; exit 1; }

if tvguard_compose config --quiet >/dev/null 2>&1; then
  ok "Compose configuration valid with project 'tvguard'"
  PIHOLE_IMAGE="$(tvguard_compose config --images 2>/dev/null | sed -n '1p')"
  if [ -z "$PIHOLE_IMAGE" ]; then
    err "could not determine the configured Pi-hole image"
  elif docker image inspect "$PIHOLE_IMAGE" >/dev/null 2>&1; then
    ok "Pi-hole image available: $PIHOLE_IMAGE"
  elif tvguard_compose pull pihole; then
    ok "Pi-hole image downloaded: $PIHOLE_IMAGE"
  else
    err "Pi-hole image is unavailable; existing DNS was left untouched"
  fi
else
  err "Compose configuration invalid (run: docker compose --project-name tvguard config)"
fi
[ "$FAIL" -eq 0 ] || exit 1

# IPv6 gate: a usable IPv6 default route means an uncontrolled v6 egress path
# that would bypass the privacy firewall. Report it, never change it.
if ip -6 route show default 2>/dev/null | grep -q .; then
  if grep -Eq '^[[:space:]]*PRIVACY(-[A-Za-z0-9_-]+)?[[:space:]]*=[[:space:]]*(standard|standard-no-voice|strict|manufacturer-lockdown)[[:space:]]*$' \
       /var/lib/tvguard/privacy-state 2>/dev/null; then
    err "active privacy policy plus an IPv6 default route would create an uncontrolled bypass"
    echo "  TVGuard was not restarted. Resolve IPv6 on the router, then rerun bootstrap." >&2
  else
    warn "this host has an IPv6 default route: IPv6 egress from the TVs would"
    warn "bypass the privacy firewall. The privacy phase must not start until"
    warn "this is resolved on the router (disable RA / v6 WAN) - see docs/ROLLBACK.md"
  fi
else
  ok "no IPv6 default route (v6 bypass not applicable)"
fi
[ "$FAIL" -eq 0 ] || exit 1

# --- 4. Pi-hole -----------------------------------------------------------------------
echo
echo "=== Pi-hole ==="
PIHOLE_INITIALIZING="$PIHOLE_FIRST_INSTALL"

# Recreate only after package, environment, bind, Compose, image and IPv6
# preflight has completed. Persistent state is never removed.
if [ "$PIHOLE_REPLACE" -eq 1 ]; then
  if docker stop pihole >/dev/null 2>&1 && docker rm pihole >/dev/null 2>&1; then
    ok "removed preflighted legacy/stale-path container; persisted state retained"
  else
    err "could not replace the preflighted pihole container; persisted state was not removed"
  fi
fi

PIHOLE_READY=0
if [ "$FAIL" -eq 0 ]; then
  if tvguard_compose up -d >/dev/null 2>&1; then
    ok "compose stack up (project tvguard)"
    if [ "$PIHOLE_INITIALIZING" -eq 1 ]; then
      BOOT_READY_ARGS=(--allow-initialize)
    else
      BOOT_READY_ARGS=()
    fi
    if scripts/pihole-boot-ready.sh "${BOOT_READY_ARGS[@]}" >/dev/null 2>&1; then
      PIHOLE_READY=1
      ok "Pi-hole healthy with persisted gravity database"
    else
      err "Pi-hole failed persisted-state/health gate - inspect: scripts/pihole-boot-ready.sh"
    fi
  else
    err "docker compose up failed (check: docker compose --project-name tvguard logs pihole)"
  fi
fi

if [ "$PIHOLE_READY" -eq 1 ]; then
  # Query the configured LAN bind (DNS is intentionally not published on loopback).
  answered=0
  for _ in $(seq 1 15); do
    if dig +time=2 +tries=1 "@$PIHOLE_BIND_VALUE" example.com 2>/dev/null | grep -q NOERROR; then
      answered=1; break
    fi
    sleep 2
  done
  if [ "$answered" -eq 1 ]; then
    ok "DNS answering on $PIHOLE_BIND_VALUE:53 (NOERROR)"
  else
    err "Pi-hole DNS not answering on $PIHOLE_BIND_VALUE:53 - inspect: docker logs pihole"
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

# --- 5. TVGuard unit ---------------------------------------------------------------
echo
echo "=== TVGuard firewall unit ==="
if [ "$FAIL" -ne 0 ]; then
  warn "Pi-hole checks failed; existing tvguard.service was left untouched"
elif command -v systemctl >/dev/null 2>&1; then
  unit_was_enabled=0
  systemctl is-enabled --quiet tvguard.service 2>/dev/null && unit_was_enabled=1

  SERVICE_LINK_DIR=/usr/local/libexec/tvguard
  BOOT_READY_LINK="$SERVICE_LINK_DIR/pihole-boot-ready"
  APPLY_LINK="$SERVICE_LINK_DIR/apply"
  UNIT_PATH=/etc/systemd/system/tvguard.service
  UNIT_TMP_DIR="$(mktemp -d)"
  UNIT_CANDIDATE="$UNIT_TMP_DIR/tvguard.service"
  UNIT_BACKUP="$UNIT_TMP_DIR/tvguard.service.previous"
  unit_installed=0
  unit_existed=0
  unit_backup_ready=0
  boot_link_existed=0
  apply_link_existed=0
  old_boot_link=""
  old_apply_link=""

  if [ -e "$UNIT_PATH" ] || [ -L "$UNIT_PATH" ]; then
    unit_existed=1
    if cp -a "$UNIT_PATH" "$UNIT_BACKUP"; then
      unit_backup_ready=1
    else
      err "could not back up existing tvguard.service"
    fi
  fi
  if [ -L "$BOOT_READY_LINK" ]; then
    boot_link_existed=1
    old_boot_link="$(readlink "$BOOT_READY_LINK")"
  elif [ -e "$BOOT_READY_LINK" ]; then
    err "$BOOT_READY_LINK exists and is not a TVGuard symlink"
  fi
  if [ -L "$APPLY_LINK" ]; then
    apply_link_existed=1
    old_apply_link="$(readlink "$APPLY_LINK")"
  elif [ -e "$APPLY_LINK" ]; then
    err "$APPLY_LINK exists and is not a TVGuard symlink"
  fi
  if [ -e "$SERVICE_LINK_DIR" ] && [ ! -d "$SERVICE_LINK_DIR" ]; then
    err "$SERVICE_LINK_DIR exists and is not a directory"
  elif [ "$FAIL" -eq 0 ]; then
    install -d -m 0755 "$SERVICE_LINK_DIR" || err "could not create $SERVICE_LINK_DIR"
  fi

  restore_service_install(){
    if [ "$unit_existed" -eq 1 ] && [ "$unit_backup_ready" -eq 1 ]; then
      rm -f "$UNIT_PATH"
      cp -a "$UNIT_BACKUP" "$UNIT_PATH" || true
    elif [ "$unit_existed" -eq 0 ]; then
      rm -f "$UNIT_PATH"
    fi
    if [ "$boot_link_existed" -eq 1 ]; then
      ln -sfn "$old_boot_link" "$BOOT_READY_LINK" || true
    else
      rm -f "$BOOT_READY_LINK"
    fi
    if [ "$apply_link_existed" -eq 1 ]; then
      ln -sfn "$old_apply_link" "$APPLY_LINK" || true
    else
      rm -f "$APPLY_LINK"
    fi
    systemctl daemon-reload >/dev/null 2>&1 || true
  }

  if [ "$FAIL" -eq 0 ]; then
    cp deploy/tvguard.service.in "$UNIT_CANDIDATE" \
      && ln -s "$ROOT/scripts/pihole-boot-ready.sh" "$UNIT_TMP_DIR/pihole-boot-ready" \
      && ln -s "$ROOT/scripts/tvguard-apply.sh" "$UNIT_TMP_DIR/apply" \
      && mv -Tf "$UNIT_TMP_DIR/pihole-boot-ready" "$BOOT_READY_LINK" \
      && mv -Tf "$UNIT_TMP_DIR/apply" "$APPLY_LINK" \
      || err "could not stage TVGuard service launchers"
  fi
  if [ "$FAIL" -eq 0 ] && command -v systemd-analyze >/dev/null 2>&1 \
     && ! systemd-analyze verify "$UNIT_CANDIDATE" >/dev/null 2>&1; then
    err "tvguard.service failed systemd verification"
  fi
  if [ "$FAIL" -eq 0 ]; then
    UNIT_STAGED="/etc/systemd/system/.tvguard.service.$$"
    if install -m 0644 "$UNIT_CANDIDATE" "$UNIT_STAGED" \
       && mv -Tf "$UNIT_STAGED" "$UNIT_PATH" \
       && systemctl daemon-reload >/dev/null 2>&1; then
      unit_installed=1
    else
      rm -f "$UNIT_STAGED"
      err "could not atomically install/reload tvguard.service"
    fi
  fi
  if [ "$unit_installed" -eq 0 ]; then
    restore_service_install
  fi
  rm -rf "$UNIT_TMP_DIR"

  if [ "$unit_installed" -eq 1 ] && [ "$unit_was_enabled" -eq 1 ]; then
    if systemctl restart tvguard.service >/dev/null 2>&1; then
      ok "enabled unit updated and restarted from $ROOT"
    else
      err "enabled tvguard.service failed after update (inspect: systemctl status tvguard.service)"
    fi
  elif [ "$unit_installed" -eq 1 ]; then
    ok "unit installed (inactive). Enable later with:"
    echo "      sudo scripts/tvguard-enable-monitor.sh   (monitor = logging only)"
  fi
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
grep -E '^(MODE|LAN_INTERFACE|LAN_SUBNET|GATEWAY_IP|PIHOLE_IP|PIHOLE_BIND_IP|UPSTREAM_ROUTER|TVS|SAMSUNG_TVS|LG_TVS|GOOGLE_TVS|WAN_INTERFACE)=' .env | sed 's/^/  /'
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
