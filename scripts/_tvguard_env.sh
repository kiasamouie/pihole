#
# _tvguard_env.sh - load the machine configuration (sourced by every script).
#
# The repo root's .env is the ONE machine-specific file (host facts, TV/vendor
# target lists, Pi-hole admin password, template: .env.example). It is
# git-ignored and holds secrets, so scripts source it rather than re-parsing
# it themselves.
#
# Resolution order:
#   1. $TVGUARD_ENV           (test override: point at a throwaway fixture)
#   2. $TVGUARD_ROOT/.env     (the normal single-file location)
#   3. $TVGUARD_ROOT/config/tvguard.conf   (legacy location, read-only fallback
#      for pre-.env machines; values there are ignored if .env exists)
#
# After sourcing: MODE, LAN_INTERFACE, LAN_SUBNET, GATEWAY_IP, PIHOLE_IP,
# UPSTREAM_ROUTER, WAN_INTERFACE, TVS, SAMSUNG_TVS/LG_TVS/GOOGLE_TVS (or the
# legacy SAMSUNG_IP/LG_IP/GOOGLE_TV_IP), ADMIN_PASSWORD, TZ, PIHOLE_BIND_IP.
#
# The runtime state directory is a fixed architecture constant, not config:
STATE_DIR=/var/lib/tvguard

if [ -z "${TVGUARD_ROOT:-}" ]; then
  TVGUARD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

TVGUARD_ENV="${TVGUARD_ENV:-$TVGUARD_ROOT/.env}"
if [ ! -f "$TVGUARD_ENV" ] && [ -f "$TVGUARD_ROOT/config/tvguard.conf" ]; then
  TVGUARD_ENV="$TVGUARD_ROOT/config/tvguard.conf"
fi

[ -f "$TVGUARD_ENV" ] || {
  echo "ERROR: no machine config found." >&2
  echo "  create $TVGUARD_ROOT/.env from .env.example (or run bootstrap.sh)" >&2
  exit 4
}
# shellcheck source=/dev/null
. "$TVGUARD_ENV"
