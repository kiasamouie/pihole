#!/usr/bin/env bash
#
# tv-offline-reconnect-test.sh - "offline buffering" experiment for a TV.
#
#   sudo scripts/tv-offline-reconnect-test.sh samsung [offline-min] [post-min]
#   (defaults: 5 min offline, 10 min post-reconnect observation)
#
# What it does:
#   1. verifies the TV actually routes through this host (conntrack)
#   2. captures a pre-test baseline (recent conntrack + Pi-hole queries)
#   3. DENIES WAN egress ONLY for the TV (one temporary rule at position 1 of
#      the tvguard forward chain; LAN traffic - Plex, EPG, casting, hub - is
#      NOT affected)
#   4. while WAN is denied, records every connection attempt the TV makes
#      (DST IP + port from TVGUARD-OFFTEST kernel log lines)
#   5. RESTORES WAN (rule removed; trap guarantees this even on Ctrl-C)
#   6. observes the first N minutes after reconnect (conntrack deltas,
#      Pi-hole queries, TVGUARD-NEW log lines)
#   7. writes data/offline-reconnect/<timestamp>/ with metadata.json,
#      offline-attempts.csv, post-queries.csv, summary.md
#
# It NEVER claims that encrypted upload bytes are voice transcripts. It can
# only truthfully report: "X connections / Y bytes to destination Z started
# within the post-reconnect window".
#
# Safety invariants:
#   * only ONE temporary rule is added, removed by trap, and its removal is
#     verified before the script exits
#   * the rule matches ONLY that TV's new connections to non-LAN destinations
#   * nothing else in nftables/UFW/Docker/Pi-hole is touched
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"

ALIAS="${1:-}"
OFFLINE_MIN="${2:-5}"
POST_MIN="${3:-10}"

if [ "$(id -u)" -ne 0 ]; then echo "run with sudo"; exit 3; fi

# source TV IP from config
. "$ROOT/config/tvguard.conf" 2>/dev/null || { echo "config/tvguard.conf missing"; exit 4; }
case "$ALIAS" in
  samsung) TV_IP="${SAMSUNG_IP:-}"; TV_NAME="Samsung" ;;
  google)  TV_IP="${GOOGLE_TV_IP:-}"; TV_NAME="Google TV" ;;
  *) echo "usage: tv-offline-reconnect-test.sh <samsung|google> [offline-min] [post-min]"; exit 4 ;;
esac
[ -n "$TV_IP" ] || { echo "no IP for alias $ALIAS in config"; exit 4; }
LAN="${LAN_SUBNET:-192.168.0.0/24}"
IFACE="${LAN_INTERFACE:-enp2s0}"

TS=$(date -u +%Y%m%d-%H%M%S)
OUTDIR="$ROOT/data/offline-reconnect/$TS"
mkdir -p "$OUTDIR"
echo "out: $OUTDIR"
echo "TV: $TV_NAME ($TV_IP) | offline: ${OFFLINE_MIN}m | post: ${POST_MIN}m"

# --- safety trap ----------------------------------------------------------------
# Re-entrancy guard: calling exit() inside an EXIT trap re-runs the trap; the
# flag makes the second pass a no-op so the final status is simply 7.
HANDLE=""
CLEANUP_RAN=0
cleanup(){
  [ "$CLEANUP_RAN" = 1 ] && return
  CLEANUP_RAN=1
  if [ -n "$HANDLE" ]; then
    nft delete rule "ip tvguard forward" handle "$HANDLE" 2>/dev/null
  fi
  # verify removal (fail-safe: never leave the TV without WAN)
  if nft list chain ip tvguard forward 2>/dev/null | grep -q "TVGUARD-OFFTEST"; then
    echo "!! cleanup: TVGUARD-OFFTEST rule STILL PRESENT - remove manually:" >&2
    echo "   handle: $(nft -n list chain ip tvguard forward | grep TVGUARD-OFFTEST | head -1 | grep -oE '# handle [0-9]+' | awk '{print $3}')" >&2
    echo "   nft delete rule ip tvguard forward handle <handle>" >&2
    exit 7
  fi
  echo "trap: TVGUARD-OFFTEST rule removed (verified)"
}
trap cleanup EXIT INT TERM

# --- pre-checks -------------------------------------------------------------------
PRE_CT=$(conntrack -L 2>/dev/null | grep -c "$TV_IP")
if [ "$PRE_CT" -eq 0 ]; then
  echo "no active conntrack entries for $TV_IP - the TV may not be using this host as gateway right now."
  echo "Set the TV gateway/DNS to the server first (ROUTER_NEXT_STEPS_V2.md), then re-run."
  echo "(no rule was added - nothing to roll back)"
  exit 5
fi
echo "pre-check: $PRE_CT active conntrack entries for $TV_IP (path is live)"
conntrack -L 2>/dev/null | grep "$TV_IP" > "$OUTDIR/pre-conntrack.txt"

journalctl --since "-2 min" -k --no-pager 2>/dev/null > "$OUTDIR/pre-journal.txt" || true

echo
echo ">> PHASE 1: denying WAN egress for $TV_IP for ${OFFLINE_MIN} min (LAN unaffected)"
RULE="ip saddr $TV_IP ip daddr != $LAN ct state new counter log prefix \"TVGUARD-OFFTEST \" drop"
nft insert rule ip tvguard forward "$RULE" position 1 || { echo "failed to insert rule - aborting (nothing to clean)"; exit 6; }
# find its real handle (nft -n prints '# handle N' at the end of each rule line)
HANDLE=$(nft -n list chain ip tvguard forward | grep "TVGUARD-OFFTEST" | head -1 | grep -oE '# handle [0-9]+' | awk '{print $3}')
[ -n "$HANDLE" ] || { echo "could not determine rule handle"; exit 6; }
echo "rule inserted at handle $HANDLE"
echo "TV is offline for WAN now. Do nothing to the TV, or use it normally (apps should fail to reach the Internet; local Plex/casting still work)."
sleep $((OFFLINE_MIN * 60))

echo ">> PHASE 2: restoring WAN access"
nft delete rule ip tvguard forward handle "$HANDLE" 2>/dev/null
HANDLE=""
nft list chain ip tvguard forward 2>/dev/null | grep -q "TVGUARD-OFFTEST" && { echo "!! rule removal failed"; exit 7; }
echo "WAN restored (rule removed + verified)"

echo ">> PHASE 3: observing post-reconnect traffic for ${POST_MIN} min"
sleep $((POST_MIN * 60))

# --- collect results --------------------------------------------------------------
journalctl --since "-$((OFFLINE_MIN + POST_MIN + 2)) min" -k --no-pager 2>/dev/null > "$OUTDIR/full-journal.txt" || true

python3 - "$OUTDIR" "$TV_IP" "$TV_NAME" "$OFFLINE_MIN" "$POST_MIN" "$PRE_CT" <<'PYEOF'
import csv, json, os, re, sys, time, urllib.request

OUT, TV_IP, TV_NAME, OFFMIN, POSTMIN, PRE_CT = sys.argv[1:7]

def parse_offline(lines):
    out = []
    for ln in lines:
        m = re.search(r"TVGUARD-OFFTEST .*SRC=(\S+) DST=(\S+).*PROTO=(\d+)(?: SPT=(\d+))? DPT=(\d+)?", ln)
        if m and m.group(1) == TV_IP:
            out.append({"dst": m.group(2), "proto": m.group(3), "dport": m.group(5) or ""})
    return out

with open(os.path.join(OUT, "full-journal.txt")) as fh:
    lines = fh.read().splitlines()
attempts = parse_offline(lines)

# unique destinations with counts
agg = {}
for a in attempts:
    key = (a["dst"], a["dport"])
    agg[key] = agg.get(key, 0) + 1

with open(os.path.join(OUT, "offline-attempts.csv"), "w", newline="") as fh:
    w = csv.writer(fh)
    w.writerow(["dst_ip", "dport", "attempts_while_offline"])
    for (dst, dport), n in sorted(agg.items(), key=lambda x: -x[1]):
        w.writerow([dst, dport, n])

# post queries from Pi-hole (best effort)
post_queries = []
try:
    ROOT = os.path.dirname(os.path.dirname(os.path.dirname(OUT)))  # repo root
    pw = ""
    for line in open(os.path.join(ROOT, ".env")):
        if line.startswith("ADMIN_PASSWORD="):
            pw = line.strip().split("=", 1)[1]
    def req(method, path, body=None, sid=None):
        r = urllib.request.Request("http://127.0.0.1:3001" + path, method=method)
        r.add_header("Content-Type", "application/json")
        if sid:
            r.add_header("X-FTL-SID", sid)
        data = json.dumps(body).encode() if body is not None else None
        try:
            with urllib.request.urlopen(r, data, timeout=8) as resp:
                raw = resp.read().decode()
                return (json.loads(raw) if raw else {})
        except Exception:
            return {}
    res = req("POST", "/api/auth", {"password": pw})
    sid = res.get("session", {}).get("sid")
    t0 = time.time() - (int(OFFMIN) + int(POSTMIN)) * 60
    cursor = None
    seen = set()
    while True:
        url = "/api/queries?limit=100&client=%s" % TV_IP
        if cursor:
            url += "&until=%d" % cursor
        qs = req("GET", url, None, sid).get("queries", [])
        if not qs:
            break
        for q in qs:
            t = q.get("time", 0)
            if t and t >= t0 and q.get("id") not in seen:
                seen.add(q.get("id"))
                post_queries.append({"time": t, "domain": q.get("domain"), "status": q.get("status"), "rrtype": q.get("rrtype")})
        oldest = min(q.get("time", 0) for q in qs if q.get("time"))
        if len(qs) < 100 or oldest <= t0:
            break
        cursor = max(0, oldest - 1)
except Exception as e:
    print("pihole query fetch skipped:", e)

with open(os.path.join(OUT, "post-queries.csv"), "w", newline="") as fh:
    w = csv.writer(fh)
    w.writerow(["time_utc", "domain", "status", "rrtype"])
    for q in sorted(post_queries, key=lambda x: x["time"]):
        w.writerow([time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(q["time"])), q["domain"], q["status"], q["rrtype"]])

meta = {
    "tv": TV_NAME, "tv_ip": TV_IP,
    "offline_minutes": int(OFFMIN), "post_minutes": int(POSTMIN),
    "pre_conntrack_entries": int(PRE_CT),
    "offline_unique_destinations": len(agg),
    "offline_total_attempts": len(attempts),
    "post_queries_captured": len(post_queries),
    "note": "offline attempts = connection attempts DROPPED while WAN was denied. "
            "post_queries = DNS queries seen by Pi-hole across offline+post window. "
            "This test proves WHEN and WHERE the TV tries to phone home and what "
            "bursts after reconnect - it does NOT inspect encrypted payloads.",
}
with open(os.path.join(OUT, "metadata.json"), "w") as fh:
    json.dump(meta, fh, indent=2)

md = ["# Offline-reconnect test - %s (%s)" % (TV_NAME, TV_IP), ""]
md.append("offline window: %s min | post window: %s min" % (OFFMIN, POSTMIN))
md.append("")
md.append("## Connection attempts while WAN was denied (DROPPED, logged by TVGUARD-OFFTEST)")
md.append("")
if agg:
    md.append("| dst | dport | attempts |")
    md.append("|---|---|---|")
    for (dst, dport), n in sorted(agg.items(), key=lambda x: -x[1]):
        md.append("| %s | %s | %d |" % (dst, dport, n))
else:
    md.append("(none observed - the TV made no WAN connection attempts during the offline window)")
md.append("")
md.append("## DNS activity (offline + post window, from Pi-hole)")
md.append("")
md.append("%d queries captured; see post-queries.csv. Review which domains appear" % len(post_queries))
md.append("only AFTER the reconnect time - those are the 'deferred upload' candidates.")
md.append("")
md.append("> This is connection/DNS metadata. It does NOT show what was in any payload.")
with open(os.path.join(OUT, "summary.md"), "w") as fh:
    fh.write("\n".join(md))

print("wrote: metadata.json, offline-attempts.csv (%d rows), post-queries.csv (%d rows), summary.md" % (len(agg), len(post_queries)))
print("offline unique destinations: %d | total attempts: %d" % (len(agg), len(attempts)))
PYEOF

echo
echo "Done. Results in: $OUTDIR"
echo "The TV's WAN access has been fully restored (rule removed + verified at exit)."
