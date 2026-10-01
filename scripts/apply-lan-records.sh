#!/usr/bin/env bash
#
# apply-lan-records.sh - idempotently apply config/lan-dns-records.txt to the
# live Pi-hole's [dns] hosts array (etc-pihole/pihole.toml), reload FTL, and
# verify each record resolves through the Pi-hole.
#
# Usage:
#   apply-lan-records.sh
#
# Safety invariants:
#   * Only rewrites the single 'hosts = [ ... ]' array in pihole.toml, after
#     backing it up to pihole.toml.bak-apply-lan-records.
#   * Never touches other pihole.toml keys, gravity, DHCP, or the database.
#   * Idempotent: safe to run repeatedly.
set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${SCRIPT_PATH}")" && pwd)"
ROOT="$(dirname "${SCRIPT_DIR}")"

. "${SCRIPT_DIR}/_tvguard_env.sh" || exit 4
[ -n "${PIHOLE_IP:-}" ] || { echo "ERROR: PIHOLE_IP not set in machine config" >&2; exit 4; }

RECORDS_FILE="${ROOT}/config/lan-dns-records.txt"
TOML="${ROOT}/etc-pihole/pihole.toml"

[ -r "${RECORDS_FILE}" ] || { echo "ERROR: ${RECORDS_FILE} not found" >&2; exit 1; }
[ -r "${TOML}" ] || { echo "ERROR: ${TOML} not found" >&2; exit 1; }
command -v docker >/dev/null || { echo "ERROR: docker not available" >&2; exit 1; }

cp -a "${TOML}" "${TOML}.bak-apply-lan-records"

RECORDS_FILE="${RECORDS_FILE}" TOML="${TOML}" python3 - <<'PY'
import os, re, sys
records = [l.strip() for l in open(os.environ["RECORDS_FILE"])
           if l.strip() and not l.strip().startswith("#")]
if not records:
    sys.exit("ERROR: no records in lan-dns-records.txt")
src = open(os.environ["TOML"]).read()
block = "  hosts = [\n" + "".join('    "' + r + '",\n' for r in records) + "  ]"
new, n = re.subn(r'^[ \t]*hosts[ \t]*=[ \t]*\[[^\]]*\]', block, src, count=1, flags=re.M)
if n != 1:
    sys.exit("ERROR: no 'hosts = [...]' array found in pihole.toml")
open(os.environ["TOML"], "w").write(new)
print("applied " + str(len(records)) + " LAN records to pihole.toml")
PY

docker exec pihole pkill -HUP pihole-FTL || true
sleep 2

echo "verifying records via ${PIHOLE_IP}:"
fail=0
while read -r ip name _; do
  case "${ip}" in ''|\#*) continue ;; esac
  got="$(dig @"${PIHOLE_IP}" "${name}" +short +time=2 +tries=2 2>/dev/null | grep -E '^192\.168\.' | head -n1 || true)"
  if [ "${got}" = "${ip}" ]; then
    echo "  OK   ${name} -> ${got}"
  else
    echo "  FAIL ${name} expected ${ip} got '${got:-NXDOMAIN}'"
    fail=1
  fi
done < "${RECORDS_FILE}"
[ "${fail}" -eq 0 ] || exit 2
echo "all LAN records verified"
