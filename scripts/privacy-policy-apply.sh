#!/usr/bin/env bash
#
# privacy-policy-apply.sh - enable a privacy tier for one vendor's TVs.
#
#   sudo scripts/privacy-policy-apply.sh manufacturer-lockdown
#   sudo scripts/privacy-policy-apply.sh samsung standard-no-voice
#   sudo scripts/privacy-policy-apply.sh lg manufacturer-lockdown
#
# The vendor defaults to samsung (legacy one-argument form, fully
# backward-compatible). Vendors come from config/privacy-instances.yaml; each
# vendor has its OWN config files, Pi-hole group, nftables sets
# (tv_privacy_<vendor> / tv_privacy_blocked_<vendor> / tv_doh_blocked_<vendor>)
# and state line (PRIVACY-<vendor>=<tier>). Applying one vendor never touches
# the other vendor's policy, state or Pi-hole group.
#
# Testability overrides (documented, default to production values):
#   PRIVACY_GROUP   Pi-hole group name for the apply (default: the vendor's
#                   group from config/privacy-instances.yaml)
#   PRIVACY_TARGETS space-separated client IPs to scope the policy to
#                   (default: the vendor's `applies_to` list from its policy)
#
# What it does (all reversible via privacy-policy-disable.sh [vendor]):
#   1. Re-resolves ALL vendor policies -> data/privacy-policy/resolved.json
#      (external resolver; keep-list overlap excluded per vendor).
#   2. Writes/updates ONLY this vendor's state line in
#      /var/lib/tvguard/privacy-state and re-runs tvguard-apply.sh, which
#      re-renders ONLY table ip tvguard: the TVGuard mode (monitor),
#      NAT/masquerade and the other vendors' privacy sets are untouched; this
#      vendor's DROP sets (tv_privacy_blocked_<vendor>), DoT:853 drop and
#      external :53 forcing DNAT are added for the vendor's target TVs only.
#   3. Pushes the tier's exact-domain denies AND regex (suffix) denies (and,
#      for manufacturer-lockdown, the vendor's essential-allow rows) into the
#      vendor's dedicated Pi-hole group, scoped to the applies_to clients.
#
# It NEVER: flushes nftables/iptables, touches UFW or Docker, changes TVGuard
# monitor mode, enables DHCP, or blocks anything outside the target TVs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
STATE_DIR=/var/lib/tvguard
STATE_FILE="$STATE_DIR/privacy-state"

# --- argument parsing (vendor-aware, samsung is the default) -----------------
if [ "$(id -u)" -ne 0 ]; then echo "run with sudo" >&2; exit 3; fi

VENDOR=""
TIER=""
if [ "$#" -ge 2 ]; then
  VENDOR="$1"; TIER="$2"
elif [ "$#" -eq 1 ]; then
  # single arg: samsung tier (legacy) OR a vendor name (then ask for a tier)
  case "$1" in
    standard|standard-no-voice|strict|manufacturer-lockdown) VENDOR="samsung"; TIER="$1" ;;
    *) echo "usage: privacy-policy-apply.sh <tier> | <vendor> <tier>" >&2;
       echo "  vendors: samsung lg (from config/privacy-instances.yaml)" >&2; exit 4 ;;
  esac
fi

VENDOR="${VENDOR:-samsung}"
case "$TIER" in
  standard|standard-no-voice|strict|manufacturer-lockdown) ;;
  *) echo "usage: privacy-policy-apply.sh <vendor> <standard|standard-no-voice|strict|manufacturer-lockdown>" >&2; exit 4 ;;
esac

# vendor metadata from the registry (tab-separated: vendor, group, applies_to csv)
VENDOR_META="$(VENDOR="$VENDOR" python3 - "$ROOT/config/privacy-instances.yaml" <<'PYEOF'
import os, sys
import yaml
inst = (yaml.safe_load(open(sys.argv[1])).get("instances") or {})
v = os.environ["VENDOR"]
if v not in inst:
    sys.exit("unknown vendor %s (known: %s)" % (v, ", ".join(inst)))
cfg = inst[v]
pol = yaml.safe_load(open(os.path.join(os.path.dirname(os.path.dirname(sys.argv[1])), cfg["policy"])))
targets = [str(x) for x in (pol.get("applies_to") or [])]
print("\t".join([v, cfg.get("pihole_group", "TVGuard-Privacy-%s" % v.upper()), ",".join(targets)]))
PYEOF
)" || exit 4
IFS=$'\t' read -r VENDOR META_GROUP META_TARGETS <<< "$VENDOR_META"
# documented test override: PRIVACY_GROUP env wins (mock cycles use throwaway groups)
PRIVACY_GROUP="${PRIVACY_GROUP:-$META_GROUP}"
VENDOR_TARGETS="$META_TARGETS"

[ -n "$VENDOR_TARGETS" ] || {
  echo "ERROR: vendor '$VENDOR' has an empty applies_to list in its policy file." >&2
  echo "The vendor is inactive: no client has been assigned. Add the TV's IP to" >&2
  echo "the vendor's policy file (applies_to) AND to TVS in config/tvguard.conf first." >&2
  exit 5
}
PRIVACY_TARGETS="${PRIVACY_TARGETS:-${VENDOR_TARGETS//,/ }}"

# 1. fresh resolution (all vendors; uses 8.8.8.8, never the local Pi-hole)
echo "== resolving policy via external resolver (vendor: $VENDOR, tier: $TIER) =="
python3 "$SCRIPT_DIR/privacy-policy-build.py" || { echo "build failed; nothing applied." >&2; exit 5; }

# 2. firewall part (re-renders only table ip tvguard; per-vendor state line)
echo
echo "== writing privacy state: $VENDOR=$TIER =="
mkdir -p "$STATE_DIR"
VENDOR="$VENDOR" TIER="$TIER" python3 - "$STATE_FILE" <<'PYEOF'
import os, sys, time
vendor, tier = os.environ["VENDOR"], os.environ["TIER"]
path = sys.argv[1]
keep, seen = [], False
for line in open(path):
    s = line.strip()
    if not s:
        continue
    if vendor == "samsung" and (s.startswith("PRIVACY=") or s.startswith("PRIVACY-samsung=")):
        continue
    if s.startswith(("APPLIED_AT=", "SOURCE=", "DISABLED_AT=")):
        continue
    if s.startswith("PRIVACY-%s=" % vendor):
        continue
    keep.append(s)
with open(path, "w") as fh:
    for s in keep:
        fh.write(s + "\n")
    fh.write("PRIVACY-%s=%s\n" % (vendor, tier))
    fh.write("APPLIED_AT_%s=%s\n" % (vendor.upper(), time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())))
PYEOF
chmod 600 "$STATE_FILE"

bash "$SCRIPT_DIR/tvguard-apply.sh" || {
  echo "tvguard-apply failed; reverting $VENDOR privacy state to off" >&2
  sed -i "/^PRIVACY-$VENDOR=/d;/^APPLIED_AT_$(echo "$VENDOR" | tr a-z A-Z)=/d" "$STATE_FILE"
  exit 6
}

# 3. Pi-hole part (vendor's dedicated group, scoped to applies_to clients)
echo
echo "== pushing domains to Pi-hole group $PRIVACY_GROUP (vendor $VENDOR) =="
PRIVACY_ROOT="$ROOT" PRIVACY_VENDOR="$VENDOR" PRIVACY_TIER="$TIER" PRIVACY_GROUP="$PRIVACY_GROUP" PRIVACY_TARGETS="$PRIVACY_TARGETS" python3 - <<'PYEOF'
import json, os, re, sys, time, urllib.request, urllib.error, yaml

ROOT = os.environ["PRIVACY_ROOT"]
VENDOR = os.environ["PRIVACY_VENDOR"]
TIER = os.environ["PRIVACY_TIER"]
BASE = "http://127.0.0.1:3001"
GROUP_NAME = os.environ.get("PRIVACY_GROUP", "TVGuard-Privacy")

pw = ""
for line in open(os.path.join(ROOT, ".env")):
    if line.startswith("ADMIN_PASSWORD="):
        pw = line.strip().split("=", 1)[1]

resolved = json.load(open(os.path.join(ROOT, "data", "privacy-policy", "resolved.json")))
vendor = (resolved.get("vendors") or {}).get(VENDOR)
if vendor is None:
    sys.exit("resolved.json has no vendor section for %s (run the build first)" % VENDOR)
section = vendor[TIER]
targets = [t for t in os.environ.get("PRIVACY_TARGETS", "").split() if t] or vendor["applies_to"]
domains = section["domains"]
regexes = [r["pattern"] for r in (section.get("regexes") or [])]
print("  targets (applies_to): %s" % ", ".join(targets))

SID = None
def req(method, path, body=None):
    global SID
    r = urllib.request.Request(BASE + path, method=method)
    r.add_header("Content-Type", "application/json")
    if SID:
        r.add_header("X-FTL-SID", SID)
    data = json.dumps(body).encode() if body is not None else None
    try:
        with urllib.request.urlopen(r, data) as resp:
            raw = resp.read().decode()
            return resp.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read().decode() or "{}")
        except Exception:
            return e.code, {}

code, res = req("POST", "/api/auth", {"password": pw})
if code != 200:
    sys.exit("login failed: %s" % res)
SID = res["session"]["sid"]

code, res = req("GET", "/api/groups")
groups = {g["name"]: g["id"] for g in res.get("groups", [])}
if GROUP_NAME in groups:
    gid = groups[GROUP_NAME]
    print("  group %s exists (id %d)" % (GROUP_NAME, gid))
else:
    code, res = req("POST", "/api/groups", {"name": GROUP_NAME,
        "comment": "TVGuard privacy policy domains for %s (managed by privacy-policy-*.sh)" % VENDOR})
    if code not in (200, 201):
        sys.exit("group creation failed: %s" % res)
    gid = res.get("groups", [{}])[0]["id"]
    print("  group %s created (id %d)" % (GROUP_NAME, gid))

# attach target clients (union of their existing groups + this vendor's group)
code, res = req("GET", "/api/clients")
clients = {c.get("client") or c.get("ip"): c for c in res.get("clients", [])}
for ip in targets:
    c = clients.get(ip)
    if c is None:
        code, res = req("POST", "/api/clients", {"client": ip, "groups": [gid]})
        print("  client %s created (http %d)" % (ip, code))
        continue
    cur = list(c.get("groups", []))
    if gid not in cur:
        cur.append(gid)
        code, _ = req("PUT", "/api/clients/%s" % ip, {"client": ip, "groups": cur})
        print("  client %s attached to %s (http %d)" % (ip, GROUP_NAME, code))
    else:
        print("  client %s already attached" % ip)

# global name -> row lookup (FTL rows are GLOBAL; groups are associations).
# NOTE: this FTL build IGNORES the `offset` param on /api/domains, so classic
# offset-paging loops forever once the DB exceeds one page. Use a single
# expanding-limit fetch instead.
def all_domain_rows():
    limit = 1000
    while True:
        code, res = req("GET", "/api/domains?limit=%d" % limit)
        rows = res.get("domains") if isinstance(res, dict) else res
        if not isinstance(rows, list):
            rows = []
        if len(rows) < limit:
            return rows
        limit *= 4
        if limit > 100000:
            return rows

global_by_name = {}
for d in all_domain_rows():
    global_by_name.setdefault(str(d.get("domain", "")).lower(), d)
existing = set(global_by_name)

# exact-domain denies. FTL cannot add an existing row to a second group
# directly (no per-row group update endpoint in this build): rows already in
# the global DB but NOT in this vendor's group get deleted+re-added with the
# UNION of their old groups and this vendor's group (no other vendor loses the
# row; the re-add is immediate). Fresh rows are pushed straight into the group.
to_push, to_readd = [], []
for d in domains:
    row = global_by_name.get(d.lower())
    if row is None:
        to_push.append(d)
    else:
        row_groups = set(row.get("groupIDs") or row.get("groups") or [])
        if gid not in row_groups:
            to_readd.append((d, row))
if to_push:
    code, res = req("POST", "/api/domains/deny/exact", {"domain": to_push, "groups": [gid]})
    if code not in (200, 201):
        sys.exit("domain push failed: %s" % res)
print("  pushed %d fresh exact-domain denies to %s (%d already in group, %d re-linked)"
      % (len(to_push), GROUP_NAME, len(domains) - len(to_push) - len(to_readd), len(to_readd)))
for d, row in to_readd:
    row_groups = [g for g in (row.get("groupIDs") or row.get("groups") or []) if g != gid]
    old_type = row.get("type", "deny"); old_kind = row.get("kind", "exact")
    req("POST", "/api/domains:batchDelete",
        [{"item": d, "type": old_type, "kind": old_kind}])
    code, res = req("POST", "/api/domains/%s/%s" % (old_type, old_kind),
                    {"domain": [d], "groups": row_groups + [gid]})
    if code not in (200, 201):
        # restore the original row so no vendor loses its row
        req("POST", "/api/domains/%s/%s" % (old_type, old_kind),
            {"domain": [d], "groups": row_groups})
        sys.exit("re-link of shared domain %s into %s failed (row restored to previous groups): %s"
                 % (d, GROUP_NAME, res))
    print("  re-linked shared row %s -> groups %s" % (d, row_groups + [gid]))

# regex (suffix-family) denies - same global-row handling as exact domains
rx_push, rx_readd = [], []
for p in regexes:
    row = global_by_name.get(p.lower())
    if row is None:
        rx_push.append(p)
    else:
        row_groups = set(row.get("groupIDs") or row.get("groups") or [])
        if gid not in row_groups:
            rx_readd.append((p, row))
if rx_push:
    code, res = req("POST", "/api/domains/deny/regex", {"domain": rx_push, "groups": [gid]})
    if code not in (200, 201):
        sys.exit("regex push failed: %s" % res)
print("  pushed %d regex denies to %s (%d already in group, %d re-linked)"
      % (len(rx_push), GROUP_NAME, len(regexes) - len(rx_push) - len(rx_readd), len(rx_readd)))
for p, row in rx_readd:
    row_groups = [g for g in (row.get("groupIDs") or row.get("groups") or []) if g != gid]
    old_type = row.get("type", "deny")
    req("POST", "/api/domains:batchDelete", [{"item": p, "type": old_type, "kind": "regex"}])
    code, res = req("POST", "/api/domains/%s/regex" % old_type,
                    {"domain": [p], "groups": row_groups + [gid]})
    if code not in (200, 201):
        req("POST", "/api/domains/%s/regex" % old_type, {"domain": [p], "groups": row_groups})
        sys.exit("re-link of shared regex %s failed (row restored): %s" % (p, res))
    print("  re-linked shared regex %s -> groups %s" % (p, row_groups + [gid]))

# allow rows (manufacturer-lockdown keep list): keep wins - in FTL an allow
# row for the client beats the group's zone-regex deny for that exact name
# (proven by the selftest), and also shields the name against a
# gravity/baseline block.
allows = [a for a in (section.get("allows") or [])]
allow_fresh = [a for a in allows if a.lower() not in existing]
allow_relinked = 0
if allow_fresh:
    code, res = req("POST", "/api/domains/allow/exact", {"domain": allow_fresh, "groups": [gid]})
    if code not in (200, 201):
        pushed = 0
        for a in allow_fresh:
            code2, res2 = req("POST", "/api/domains/allow/exact", {"domain": [a], "groups": [gid]})
            if code2 in (200, 201):
                pushed += 1
            else:
                print("  WARN: allow row for %s not pushed: %s" % (a, str(res2)[:100]))
        print("  pushed %d allow rows to %s (one-at-a-time fallback)" % (pushed, GROUP_NAME))
    else:
        print("  pushed %d allow rows to %s" % (len(allow_fresh), GROUP_NAME))
# allow rows that exist globally but lack this group (shared with other vendor)
for a in allows:
    row = global_by_name.get(a.lower())
    if row is None:
        continue
    row_groups = set(row.get("groupIDs") or row.get("groups") or [])
    if gid in row_groups:
        continue
    row_groups = [g for g in (row.get("groupIDs") or row.get("groups") or []) if g != gid]
    req("POST", "/api/domains:batchDelete", [{"item": a, "type": "allow", "kind": "exact"}])
    code, res = req("POST", "/api/domains/allow/exact", {"domain": [a], "groups": row_groups + [gid]})
    if code in (200, 201):
        allow_relinked += 1
if allows:
    print("  allows total: %d (%d re-linked)" % (len(allows), allow_relinked))
PYEOF

echo
echo "== done =="
echo "Tier $TIER is now ACTIVE for vendor $VENDOR: ${PRIVACY_TARGETS}"
echo "Verify:  sudo scripts/privacy-policy-status.sh"
echo "Undo:    sudo scripts/privacy-policy-disable.sh $VENDOR"
