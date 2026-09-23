#!/usr/bin/env bash
#
# show-unknown-samsung.sh - surface Samsung-zone egress from the target TV that
# is NOT classified as keep or explicit deny ("unknown Samsung").
#
# Under manufacturer-lockdown those hosts are DENIED by default (Pi-hole group
# zone regexes). This tool lists them with counts and first/last seen so a
# decision can be made deliberately:
#
#   sudo scripts/manufacturer-review.sh keep  <domain> [reason]   # allow it
#   sudo scripts/manufacturer-review.sh block <domain> [reason]   # document the deny
#
# It NEVER auto-allows anything. Data is merged into
# data/manufacturer-unknown/unknown-<vendor>.csv (git-ignored, runtime only).
#
# Usage:
#   sudo scripts/show-unknown-samsung.sh [vendor] [hours]
#     vendor: samsung (default) | lg
#     hours:  default 24
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
# vendor-aware args: [vendor] [hours] with a bare [hours] still working
VENDOR="samsung"; HOURS="24"
case "${1:-}" in
  samsung|lg) VENDOR="$1"; HOURS="${2:-24}" ;;
  "") HOURS="${1:-24}" ;;
  *) HOURS="$1" ;;
esac

PRIVACY_ROOT="$ROOT" HOURS="$HOURS" VENDOR="$VENDOR" python3 - <<'PYEOF'
import json, os, re, sys, time, urllib.request, urllib.error, urllib.parse, yaml, csv

ROOT = os.environ["PRIVACY_ROOT"]
HOURS = int(os.environ.get("HOURS", "24"))
VENDOR = os.environ.get("VENDOR", "samsung")
BASE = "http://127.0.0.1:3001"
OUTDIR = os.path.join(ROOT, "data", "manufacturer-unknown")
CSV = os.path.join(OUTDIR, "unknown-%s.csv" % VENDOR)

pw = ""
for line in open(os.path.join(ROOT, ".env")):
    if line.startswith("ADMIN_PASSWORD="):
        pw = line.strip().split("=", 1)[1]

SID = None
def req(method, path, body=None):
    global SID
    r = urllib.request.Request(BASE + path, method=method)
    r.add_header("Content-Type", "application/json")
    if SID:
        r.add_header("X-FTL-SID", SID)
    data = json.dumps(body).encode() if body is not None else None
    try:
        with urllib.request.urlopen(r, data, timeout=15) as resp:
            raw = resp.read().decode()
            return resp.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read().decode() or "{}")
        except Exception:
            return e.code, {}

code, res = req("POST", "/api/auth", {"password": pw})
if code != 200:
    sys.exit("Pi-hole login failed: %s" % res)
SID = res["session"]["sid"]

# vendor config paths from the registry; target TV: first applies_to entry
inst = (yaml.safe_load(open(os.path.join(ROOT, "config", "privacy-instances.yaml"))).get("instances") or {})[VENDOR]
doc = yaml.safe_load(open(os.path.join(ROOT, inst["policy"])))
TV = str((doc.get("applies_to") or ["192.168.0.197"])[0])

# classification sets
manuf = yaml.safe_load(open(os.path.join(ROOT, inst["manufacturer"])))
zones = [z["domain"].strip().lower() for z in (manuf.get("deny_default_zones") or [])]
mkeepd = yaml.safe_load(open(os.path.join(ROOT, inst["manufacturer_keep"])))
keeps = {k["domain"].strip().lower() for k in (mkeepd.get("keeps") or [])}
explicit = {e["domain"].strip().lower() for e in (manuf.get("explicit_denies") or []) if (e.get("domain") or "")}
resolved = json.load(open(os.path.join(ROOT, "data", "privacy-policy", "resolved.json")))
vs = (resolved.get("vendors") or {}).get(VENDOR) or {}
known_deny = set()
rxs = []
for sec in ("standard", "standard-no-voice", "strict", "manufacturer-lockdown", "voice"):
    s = vs.get(sec) or {}
    known_deny |= set(s.get("domains", []))
    rxs += [r["pattern"] for r in (s.get("regexes") or [])]
try:
    zone_res = {z for z in zones}
    zone_resets = [re.compile(p) for p in rxs]
except re.error as e:
    sys.exit("regex compile error: %s" % e)

def zone_of(dd):
    dl = dd.strip().lower()
    for z in sorted(zone_res, key=len, reverse=True):
        if dl == z or dl.endswith("." + z):
            return z
    return None

# query window (backward cursor - only `until` is honoured by the v6 API)
t1 = time.time()
t0 = t1 - HOURS * 3600
def fetch_until(b):
    url = (BASE + "/api/queries?" +
           urllib.parse.urlencode({"client": TV, "until": b, "limit": 100}))
    r = urllib.request.Request(url)
    r.add_header("X-FTL-SID", SID)
    with urllib.request.urlopen(r, timeout=15) as resp:
        return json.loads(resp.read()).get("queries", [])

seen = {}
b = t1
for _ in range(500):
    qs = fetch_until(b)
    if not qs:
        break
    times = [q["time"] for q in qs if isinstance(q.get("time"), (int, float))]
    if not times:
        break
    for q in qs:
        qid = q.get("id")
        if qid is None or qid not in seen:
            seen[qid] = q
    if len(qs) < 100 or min(times) <= t0:
        break
    b = min(times) - 0.5

qs = [q for q in seen.values() if isinstance(q.get("time"), (int, float)) and q["time"] >= t0]

# classify
rows = {}   # domain -> dict(count, first, last, status, ip, zone)
for q in qs:
    name = (q.get("name") or "").strip().lower()
    z = zone_of(name)
    if z is None:
        continue  # not a Samsung zone - not our concern here
    if name in keeps:
        continue  # allowlisted - expected
    st = q.get("status") or ""
    blocked = st.startswith("blocked")
    if not blocked:
        # not blocked but in a Samsung zone: either a keep-label (regex
        # exemption) or a pre-policy query; record only if it looks like a
        # zone member that is NOT a keep host and NOT a known explicit deny
        if name in known_deny or name in explicit:
            continue
        rows.setdefault(name, {"count": 0, "first": q["time"], "last": q["time"],
                                "status": st + " (NOT blocked!)", "ip": q.get("reply") or "", "zone": z})
        rows[name]["count"] += 1
        rows[name]["last"] = max(rows[name]["last"], q["time"])
        continue
    # blocked: known explicit deny vs unknown (caught by a zone regex)
    if name in known_deny or name in explicit:
        continue
    if any(r.match(name) for r in zone_resets):
        rows.setdefault(name, {"count": 0, "first": q["time"], "last": q["time"],
                                "status": st, "ip": q.get("reply") or "", "zone": z})
        rows[name]["count"] += 1
        rows[name]["last"] = max(rows[name]["last"], q["time"])

os.makedirs(OUTDIR, exist_ok=True)
# merge into the CSV (append new, refresh known)
prev = {}
if os.path.exists(CSV):
    with open(CSV, newline="") as fh:
        for r in csv.DictReader(fh):
            prev[r["domain"]] = r
for name, v in rows.items():
    old = prev.get(name)
    prev[name] = {
        "domain": name, "zone": v["zone"], "status": v["status"], "ip": v["ip"],
        "count": str(int(old["count"]) + v["count"] if old else v["count"]),
        "first_seen": old["first_seen"] if old else time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(v["first"])),
        "last_seen": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(v["last"])),
        "classification": "unknown (deny-by-default)",
    }
if prev:
    with open(CSV, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=["domain", "zone", "status", "ip", "count",
                                           "first_seen", "last_seen", "classification"])
        w.writeheader()
        for name in sorted(prev):
            w.writerow(prev[name])

print("%s-zone queries from %s, last %dh: %d total, %d unknown (denied-by-default), %d allowlisted (skipped)"
      % (VENDOR, TV, HOURS, len(qs), len(rows), len(keeps)))
if not rows:
    print("\nNo unknown %s destinations in the window. Nothing to review." % VENDOR)
else:
    print("\nUNKNOWN %s DESTINATIONS (denied by default - decide: keep | block | leave unknown):" % VENDOR)
    print("%-6s %-45s %-12s %-16s %s" % ("count", "domain", "first_seen", "last_seen", "zone"))
    for name in sorted(rows, key=lambda n: -rows[n]["count"]):
        v = rows[name]
        print("%-6d %-45s %-16s %-16s %s" % (
            v["count"], name,
            time.strftime("%m-%d %H:%M", time.gmtime(v["first"])),
            time.strftime("%m-%d %H:%M", time.gmtime(v["last"])),
            v["zone"]))
    print("\nDecide each one:")
    print("  allow:  sudo scripts/manufacturer-review.sh %s keep  <domain> [reason]" % VENDOR)
    print("  block:  sudo scripts/manufacturer-review.sh %s block <domain> [reason]" % VENDOR)
    print("review CSV: %s" % CSV)
PYEOF
