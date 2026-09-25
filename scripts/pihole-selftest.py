#!/usr/bin/env python3
"""Pi-hole v6 local API self-test (runs on the server itself).

Reads ADMIN_PASSWORD from the repo's .env (located next to this script; never printed). Tests:
  1. login -> session SID (POST /api/auth)
  2. resolver health (upstreams + gravity via /api/info)
  3. add denylist entry for a real domain, verify it blocks (dig -> NXDOMAIN)
  4. remove it, verify it resolves again (dig -> NOERROR)
  5. query log (/api/queries) shows the test queries and blocked status

Pi-hole v6 (FTL >= 6.x) API paths:
  auth:      POST/DELETE /api/auth            (session SID, not token)
  denylist:  POST   /api/domains/deny/exact   {"domain": [...]}  (or .../deny/regex)
             GET    /api/domains/deny/exact
             DELETE /api/domains/deny/exact/{domain}
  allowlist: /api/domains/allow/exact (or .../allow/regex), same shape
  ("/api/domains/deny" and "/api/domains/denylist" are read-only aggregates in v6)
  clients:   POST /api/clients  {"ip","name","groups":[ids]}
  groups:    POST /api/groups   {"name","comment"}
  queries:   GET /api/queries
  status:    GET /api/info/ftl, /api/info/database, /api/stats/summary
Exit code 0 = all passed.
"""
import json
import os
import re
import subprocess
import sys
import time
import urllib.request
import urllib.error

BASE = "http://127.0.0.1:3001"
ENV_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".env")
# Must be a real domain that was NOT resolved recently, so the block test
# is not answered from dnsmasq's cache (cached answers bypass the denylist).
TEST_DOMAIN = "iana.org"

SID = None
CSRF = None

def get_password():
    for line in open(ENV_FILE):
        if line.startswith("ADMIN_PASSWORD="):
            return line.strip().split("=", 1)[1]
    raise SystemExit("ADMIN_PASSWORD missing in .env")

def req(method, path, body=None):
    global SID, CSRF
    r = urllib.request.Request(BASE + path, method=method)
    r.add_header("Content-Type", "application/json")
    if SID:
        r.add_header("X-FTL-SID", SID)
        r.add_header("X-FTL-CSRF", CSRF or "")
    data = json.dumps(body).encode() if body is not None else None
    try:
        with urllib.request.urlopen(r, data) as resp:
            raw = resp.read().decode()
            return resp.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read().decode() or "{}")

def dig_status(domain):
    """Returns (status, blocked, detail).
    Pi-hole's default blocking mode (ip_addr) answers NOERROR + 0.0.0.0/
    :: instead of NXDOMAIN, so 'blocked' is true for both modes."""
    out = subprocess.run(["dig", "+time=3", "+tries=2", "@127.0.0.1", domain],
                         capture_output=True, text=True).stdout
    m = re.search(r"status:\s*(\w+)", out)
    status = m.group(1) if m else "?"
    blocked = status == "NXDOMAIN" or ("0.0.0.0" in out.split("ANSWER SECTION")[-1] if "ANSWER SECTION" in out else False)
    detail = status + (" (blackhole IP)" if blocked and status == "NOERROR" else "")
    return status, blocked, detail

def main():
    ok = True
    def check(name, cond, detail=""):
        nonlocal ok
        print(f"[{'PASS' if cond else 'FAIL'}] {name} {detail}")
        ok = ok and cond

    global SID, CSRF
    pw = get_password()
    code, body = 0, {}
    for attempt in range(3):  # /api/auth is rate-limited (429); back off and retry
        code, body = req("POST", "/api/auth", {"password": pw})
        if code != 429:
            break
        time.sleep(20)
    check("login", code == 200 and body.get("session", {}).get("valid"), f"(http {code})")
    SID = body.get("session", {}).get("sid")
    CSRF = body.get("session", {}).get("csrf")
    if not SID:
        sys.exit(1)

    code, st = req("GET", "/api/info/ftl")
    grav = (st.get("ftl", {}).get("database", {}) or {}).get("gravity")
    check("ftl info reachable", code == 200, f"(uptime {st.get('ftl',{}).get('uptime',0):.0f}s)")
    check("gravity DB loaded", bool(grav) and grav > 10_000, f"(domains: {grav})")

    code, _ = req("POST", "/api/domains/deny/exact", {"domain": [TEST_DOMAIN]})
    check("denylist add", code in (200, 201), f"(http {code})")
    time.sleep(2)
    s1, blocked1, d1 = dig_status(TEST_DOMAIN)
    check("blocked query -> blackholed", blocked1, f"(got {d1})")

    code, dl = req("GET", "/api/domains/deny/exact")
    items = dl.get("domains", [])
    entry = next((i for i in items if i.get("domain") == TEST_DOMAIN), None)
    check("denylist entry visible", entry is not None, f"(id={entry.get('id') if entry else '-'})")
    if entry:
        code, _ = req("DELETE", f"/api/domains/deny/exact/{TEST_DOMAIN}")
        check("denylist remove", code in (200, 204), f"(http {code})")
        time.sleep(1)
        s2, blocked2, d2 = dig_status(TEST_DOMAIN)
        check("allowed query -> resolves", s2 == "NOERROR" and not blocked2, f"(got {d2})")

    # The live query log moves fast on a busy LAN: fetch a wide window and
    # retry briefly so our own test rows are not crowded out by TV traffic.
    ours, blocked_seen = [], False
    for _ in range(5):
        code, q = req("GET", "/api/queries?perPage=100")
        rows = q.get("queries", [])
        mine = [r for r in rows if r.get("domain") == TEST_DOMAIN]
        ours = mine if len(mine) > len(ours) else ours
        # v6 uses status "DENYLIST" for list-blocked queries (v5 used "blocked")
        blocked_seen = blocked_seen or any(r.get("status") in ("blocked", "BLOCKED", "DENYLIST") for r in ours)
        if len(ours) >= 2 and blocked_seen:
            break
        time.sleep(1.5)
    check("query log captured test queries", len(ours) >= 2 and blocked_seen,
          f"(selftest rows {len(ours)} seen, denied-status row seen: {blocked_seen})")

    print("\nALL PASS" if ok else "\nSOME TESTS FAILED")
    sys.exit(0 if ok else 1)

if __name__ == "__main__":
    main()
