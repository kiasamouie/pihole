#!/usr/bin/env bash
#
# privacy-reset-tv-voice-state.sh - expire voice state that survives a policy
# change, in a safe, narrow, per-TV way.
#
# Why this exists:
#   The privacy deny rule matches NEW connections only (ct state new). A TV
#   that (a) cached DNS answers for voice hostnames, or (b) holds an
#   already-established TLS/XMPP connection to a voice endpoint from before
#   the deny was applied, keeps working until that state dies naturally.
#   This script expires state (b) for ONE TV and the resolved voice IPs only:
#
#     * deletes conntrack entries matching  TV <-> voice-IP  in BOTH
#       directions (all protocols)
#     * never touches any other client's flows, never flushes the global
#       conntrack table, and never touches UFW, Docker, Pi-hole or TVGuard.
#
#   After the flows are gone the TV must open NEW connections to retry; new
#   connections to a deny-list IP are dropped (logged TVGUARD-PRIVACY) and
#   new DNS lookups are denied by the Pi-hole group - so both layers now
#   actually get a chance to bite.
#
# Usage:
#   sudo scripts/privacy-reset-tv-voice-state.sh                 # Samsung (first configured target)
#   sudo scripts/privacy-reset-tv-voice-state.sh lg               # LG vendor (first configured target)
#   sudo scripts/privacy-reset-tv-voice-state.sh <TV_IP>          # explicit TV IP (samsung vendor)
#   sudo scripts/privacy-reset-tv-voice-state.sh --flush-dns-cache
#       (also flush the Pi-hole DNS cache first; harmless - everything
#       simply re-resolves. Off by default.)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"

if [ "$(id -u)" -ne 0 ]; then echo "run with sudo" >&2; exit 3; fi
command -v conntrack >/dev/null || { echo "conntrack tool not found" >&2; exit 4; }

FLUSH_DNS=0
VENDOR="samsung"
TV=""
for a in "$@"; do
  case "$a" in
    --flush-dns-cache) FLUSH_DNS=1 ;;
    -*) echo "unknown flag: $a" >&2; exit 4 ;;
    samsung|lg) VENDOR="$a" ;;
    *) TV="$a" ;;
  esac
done

# default: first configured target of the vendor from the machine config
if [ -z "$TV" ]; then
  TV=$(VENDOR_ROOT="$ROOT" VENDOR="$VENDOR" python3 -c '
import os, sys, yaml
sys.path.insert(0, os.environ["VENDOR_ROOT"] + "/scripts")
from tvguard_target_config import load_target_config
root = os.environ["VENDOR_ROOT"]; v = os.environ["VENDOR"]
inst = yaml.safe_load(open(root + "/config/privacy-instances.yaml"))["instances"]
tc = load_target_config(inst)
t = tc.vendor_targets.get(v) or []
print(t[0] if t else "")
')
fi
[ -n "$TV" ] || { echo "vendor $VENDOR has no configured TV target - pass the TV IP explicitly" >&2; exit 5; }
echo "target TV: $TV (vendor: $VENDOR)"

if [ "$FLUSH_DNS" = "1" ]; then
  echo "== flushing Pi-hole DNS cache (docker exec pihole 'pihole -f') =="
  docker exec pihole pihole -f 2>/dev/null && echo "  cache flushed" || echo "  WARN: could not flush Pi-hole cache (docker/pihole CLI)"
fi

# voice IPs: the resolved voice tier of the vendor (exact + suffix-host resolutions)
IPS=$(VENDOR="$VENDOR" ROOT="$ROOT" python3 -c '
import os, json
d = json.load(open(os.environ["ROOT"] + "/data/privacy-policy/resolved.json"))
vs = (d.get("vendors") or {}).get(os.environ["VENDOR"]) or {}
v = vs.get("voice") or {}
if not v.get("ips") and os.environ["VENDOR"] == "samsung":
    v = d.get("voice", {})
print(" ".join(sorted(set(v.get("ips", [])))))
' 2>/dev/null)

if [ -z "${IPS// /}" ]; then
  echo "no resolved voice IPs in data/privacy-policy/resolved.json - run privacy-policy-build.py first" >&2
  exit 5
fi

echo "== deleting conntrack entries: $TV <-> voice IPs (both directions) =="
TOTAL=0
for ip in $IPS; do
  N1=$(conntrack -L -s "$TV" -d "$ip" 2>/dev/null | wc -l)
  N2=$(conntrack -L -s "$ip" -d "$TV" 2>/dev/null | wc -l)
  conntrack -D -s "$TV" -d "$ip" 2>/dev/null || true
  conntrack -D -s "$ip" -d "$TV" 2>/dev/null || true
  if [ "$N1" -gt 0 ] || [ "$N2" -gt 0 ]; then
    echo "  $ip: deleted $N1 (tv->ip) / $N2 (ip->tv) flows"
    TOTAL=$((TOTAL + N1 + N2))
  fi
done

LEFT=$(conntrack -L 2>/dev/null | grep -cF " $TV " || true)
echo
echo "done: deleted $TOTAL voice flows for $TV. Remaining $TV flows (all other destinations): $LEFT"
echo "The TV will now need fresh DNS + fresh connections for any voice use; both are"
echo "denied by the active privacy policy. Verify with: sudo scripts/privacy-live-check.sh"
