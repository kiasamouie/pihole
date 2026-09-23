#!/usr/bin/env bash
#
# manufacturer-review.sh - review workflow for manufacturer-lockdown (per vendor).
#
# For every unknown vendor destination (listed by show-unknown-samsung.sh <vendor>)
# make an explicit decision. Nothing is ever auto-allowed.
#
#   sudo scripts/manufacturer-review.sh [vendor] list
#       show the vendor's zone list, the essential allowlist and explicit denies
#
#   sudo scripts/manufacturer-review.sh [vendor] keep <domain> [reason...]
#       add <domain> to the vendor's manufacturer-keep file (must sit inside a
#       deny-by-default zone), rebuild, re-apply if a vendor profile is active,
#       and reset stale TV conntrack state.
#
#   sudo scripts/manufacturer-review.sh [vendor] block <domain> [reason...]
#       add <domain> to the explicit deny list in the vendor's manufacturer file
#       (documented deny for manufacturer-lockdown), rebuild, re-apply, reset.
#
# vendor defaults to samsung. The vendor's config files come from
# config/privacy-instances.yaml.
#
# Both mutating commands re-run the full build (which enforces all invariants)
# and fail loudly if the change violates the policy model.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"

if [ "$(id -u)" -ne 0 ]; then echo "run with sudo" >&2; exit 3; fi

# vendor argument (optional, default samsung)
VENDOR="samsung"
case "${1:-}" in
  samsung|lg) VENDOR="$1"; shift ;;
esac
# vendor config paths from the registry
MANUF_PATH="$(VENDOR="$VENDOR" python3 -c 'import os,sys,yaml
inst=(yaml.safe_load(open(sys.argv[1]))["instances"])[os.environ["VENDOR"]]
print(sys.argv[1][:-len("config/privacy-instances.yaml")]+inst["manufacturer"])' "$ROOT/config/privacy-instances.yaml")"
[ -f "$MANUF_PATH" ] || { echo "vendor manufacturer file missing: $MANUF_PATH" >&2; exit 4; }

CMD="${1:-}"
shift 2>/dev/null || true
case "$CMD" in
  list|keep|block) ;;
  *) echo "usage: manufacturer-review.sh [vendor] list | keep <domain> [reason] | block <domain> [reason]" >&2; exit 4 ;;
esac

if [ "$CMD" = "list" ]; then
  VENDOR="$VENDOR" ROOT="$ROOT" python3 - <<'PYEOF'
import os, sys, yaml
root = os.environ["ROOT"]; v = os.environ["VENDOR"]
inst = yaml.safe_load(open(root + "/config/privacy-instances.yaml"))["instances"][v]
m = yaml.safe_load(open(root + "/" + inst["manufacturer"]))
mk = yaml.safe_load(open(root + "/" + inst["manufacturer_keep"]))
print("=== deny-by-default zones (manufacturer-lockdown, vendor %s) ===" % v)
for z in m.get("deny_default_zones") or []:
    print("  deny-default  %-32s %s" % (z["domain"], z.get("service", "")))
print("\n=== non-zones (deliberately NOT deny-by-default) ===")
for z in m.get("non_zones") or []:
    print("  keep-family   %-32s %s" % (z["domain"], z.get("reason", "")))
print("\n=== essential allowlist (keep wins) ===")
for k in mk.get("keeps") or []:
    print("  allow         %-32s %s" % (k["domain"], k.get("feature", "")))
print("\n=== explicit denies (added by review) ===")
ed = m.get("explicit_denies") or []
if ed:
    for e in ed:
        print("  block         %-32s %s" % (e["domain"], e.get("reason", "")))
else:
    print("  (none)")
PYEOF
  exit 0
fi

DOM="${1:-}"
shift 2>/dev/null || true
REASON="${*:-review decision $(date -u +%Y-%m-%dT%H:%M:%SZ)}"
[ -n "$DOM" ] || { echo "a domain is required" >&2; exit 4; }
DOM="$(echo "$DOM" | tr '[:upper:]' '[:lower:]')"

VENDOR="$VENDOR" python3 - "$ROOT" "$CMD" "$DOM" "$REASON" <<'PYEOF'
import sys, yaml, re, os
root, cmd, dom, reason = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
v = os.environ.get("VENDOR", "samsung")
dom = dom.strip().lower()
label = re.sub(r"[^a-z0-9-]", "", dom)
if not label or "." not in dom:
    sys.exit("not a valid domain: %s" % dom)

inst = yaml.safe_load(open(root + "/config/privacy-instances.yaml"))["instances"][v]
manuf_path = root + "/" + inst["manufacturer"]
mkeep_path = root + "/" + inst["manufacturer_keep"]
manuf = yaml.safe_load(open(manuf_path))
zones = [z["domain"].strip().lower() for z in (manuf.get("deny_default_zones") or [])]

def zof(d):
    for z in sorted(zones, key=len, reverse=True):
        if d == z or d.endswith("." + z):
            return z
    return None

if cmd == "keep":
    z = zof(dom)
    if z is None:
        sys.exit("refusing: %s is not inside any deny-by-default zone - "
                 "a manufacturer-keep entry only makes sense inside a zone. "
                 "(If it is not vendor-owned, use the vendor's privacy-keep file instead.)" % dom)
    mk = yaml.safe_load(open(mkeep_path))
    names = {k["domain"].strip().lower() for k in (mk.get("keeps") or [])}
    if dom in names:
        sys.exit("%s is already in manufacturer-keep.yaml" % dom)
    with open(mkeep_path, "a", encoding="utf-8") as fh:
        fh.write("\n  # added by manufacturer-review.sh keep (auto-structured)\n")
        fh.write("  - domain: %s\n" % dom)
        fh.write("    feature: \"review-approved %s endpoint\"\n" % v.upper())
        fh.write("    reason: \"%s\" (zone %s)\n" % (reason, z))
        fh.write("    evidence: \"operator review after show-unknown-samsung.sh\"\n")
        fh.write("    sources: [operator-review]\n")
        fh.write("    date: \"%s\"\n" % __import__("time").strftime("%Y-%m-%d"))
        fh.write("    confidence: medium\n")
    print("added keep: %s (zone %s)" % (dom, z))
else:
    ed = manuf.get("explicit_denies") or []
    names = {e["domain"].strip().lower() for e in ed if isinstance(e, dict)}
    if dom in names:
        sys.exit("%s is already in the explicit deny list" % dom)
    # config/manufacturer.yaml keeps `explicit_denies:` as the LAST section,
    # so a plain end-of-file append is a valid YAML list extension.
    text = open(manuf_path).read()
    if not re.search(r"^explicit_denies:\s*$", text, flags=re.M):
        sys.exit("refusing: no trailing `explicit_denies:` section in manufacturer.yaml - "
                 "fix the file structure first (it must be the last section)")
    with open(manuf_path, "a", encoding="utf-8") as fh:
        fh.write("  - domain: %s\n" % dom)
        fh.write("    reason: \"%s\"\n" % reason)
    print("added block: %s (explicit deny, manufacturer-lockdown)" % dom)
PYEOF
RC=$?
[ $RC -eq 0 ] || exit $RC

echo "== rebuilding policy (invariants enforced) =="
python3 "$SCRIPT_DIR/privacy-policy-build.py" || { echo "build failed - change NOT applied" >&2; exit 5; }

STATE=$(sed -n "s/^PRIVACY-$VENDOR=//p" /var/lib/tvguard/privacy-state 2>/dev/null | tail -1)
if [ -z "$STATE" ]; then
  # legacy single-line state (samsung only)
  if [ "$VENDOR" = "samsung" ]; then
    STATE=$(sed -n 's/^PRIVACY=//p' /var/lib/tvguard/privacy-state 2>/dev/null | tail -1)
  fi
fi
if [ "${STATE:-off}" != "off" ]; then
  echo "== re-applying profile $STATE for vendor $VENDOR (additive) =="
  bash "$SCRIPT_DIR/privacy-policy-apply.sh" "$VENDOR" "$STATE" || { echo "re-apply failed - check manually" >&2; exit 6; }
  echo "== resetting stale TV conntrack state =="
  bash "$SCRIPT_DIR/privacy-reset-tv-manufacturer-state.sh" "$VENDOR" || true
  echo "Done. New classification is live for $VENDOR. Verify: sudo scripts/privacy-policy-status.sh"
else
  echo "No active privacy profile for $VENDOR - classification saved; it takes effect on the next apply."
fi
