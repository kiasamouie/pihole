#!/usr/bin/env bash
#
# manufacturer-review.sh - review workflow for manufacturer-lockdown.
#
# For every unknown Samsung destination (listed by show-unknown-samsung.sh)
# make an explicit decision. Nothing is ever auto-allowed.
#
#   sudo scripts/manufacturer-review.sh list
#       show the current zone list, the essential allowlist and explicit denies
#
#   sudo scripts/manufacturer-review.sh keep <domain> [reason...]
#       add <domain> to config/manufacturer-keep.yaml (must sit inside a
#       deny-by-default zone), rebuild, re-apply if a privacy profile is
#       active, and reset stale TV conntrack state.
#
#   sudo scripts/manufacturer-review.sh block <domain> [reason...]
#       add <domain> to the explicit deny list in config/manufacturer.yaml
#       (documented deny for manufacturer-lockdown), rebuild, re-apply, reset.
#
# Both mutating commands re-run the full build (which enforces all invariants)
# and fail loudly if the change violates the policy model.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"

if [ "$(id -u)" -ne 0 ]; then echo "run with sudo" >&2; exit 3; fi
[ -f "$ROOT/config/manufacturer.yaml" ] || { echo "config/manufacturer.yaml missing" >&2; exit 4; }

CMD="${1:-}"
shift 2>/dev/null || true
case "$CMD" in
  list|keep|block) ;;
  *) echo "usage: manufacturer-review.sh list | keep <domain> [reason] | block <domain> [reason]" >&2; exit 4 ;;
esac

if [ "$CMD" = "list" ]; then
  python3 - "$ROOT" <<'PYEOF'
import sys, yaml
root = sys.argv[1]
m = yaml.safe_load(open(root + "/config/manufacturer.yaml"))
mk = yaml.safe_load(open(root + "/config/manufacturer-keep.yaml"))
print("=== deny-by-default zones (manufacturer-lockdown) ===")
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

python3 - "$ROOT" "$CMD" "$DOM" "$REASON" <<'PYEOF'
import sys, yaml, re, os
root, cmd, dom, reason = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
dom = dom.strip().lower()
label = re.sub(r"[^a-z0-9-]", "", dom)
if not label or "." not in dom:
    sys.exit("not a valid domain: %s" % dom)

manuf_path = root + "/config/manufacturer.yaml"
mkeep_path = root + "/config/manufacturer-keep.yaml"
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
                 "(If it is non-Samsung, use config/privacy-keep.yaml instead.)" % dom)
    mk = yaml.safe_load(open(mkeep_path))
    names = {k["domain"].strip().lower() for k in (mk.get("keeps") or [])}
    if dom in names:
        sys.exit("%s is already in manufacturer-keep.yaml" % dom)
    with open(mkeep_path, "a", encoding="utf-8") as fh:
        fh.write("\n  # added by manufacturer-review.sh keep (auto-structured)\n")
        fh.write("  - domain: %s\n" % dom)
        fh.write("    feature: \"review-approved Samsung endpoint\"\n")
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

STATE=$(sed -n 's/^PRIVACY=//p' /var/lib/tvguard/privacy-state 2>/dev/null | tail -1)
if [ "${STATE:-off}" != "off" ]; then
  echo "== re-applying profile $STATE (additive) =="
  bash "$SCRIPT_DIR/privacy-policy-apply.sh" "$STATE" || { echo "re-apply failed - check manually" >&2; exit 6; }
  echo "== resetting stale TV conntrack state =="
  bash "$SCRIPT_DIR/privacy-reset-tv-manufacturer-state.sh" || true
  echo "Done. New classification is live. Verify: sudo scripts/privacy-policy-status.sh"
else
  echo "No active privacy profile - classification saved; it takes effect on the next apply."
fi
