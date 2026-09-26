#!/usr/bin/env python3
"""show-dns-activity.py - Summarise DNS activity per client from the Pi-hole API.

Usage:
  scripts/show-dns-activity.py              # top domains + top clients, all time
  scripts/show-dns-activity.py <TV_IP>  # all queries from one client IP
  scripts/show-dns-activity.py --recent      # last 100 queries (all clients)

Reads ADMIN_PASSWORD from .env (never printed). Read-only.
"""
import json
import os
import sys
import time
import urllib.request

BASE = "http://127.0.0.1:3001"
ENV_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".env")


def get_password():
    for line in open(ENV_FILE):
        if line.startswith("ADMIN_PASSWORD="):
            return line.strip().split("=", 1)[1]
    raise SystemExit("ADMIN_PASSWORD missing in .env")


def main():
    r = urllib.request.Request(BASE + "/api/auth", method="POST",
                                data=json.dumps({"password": get_password()}).encode(),
                                headers={"Content-Type": "application/json"})
    sid = json.loads(urllib.request.urlopen(r).read())["session"]["sid"]

    def get(path):
        req = urllib.request.Request(BASE + path)
        req.add_header("X-FTL-SID", sid)
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read().decode())

    arg = sys.argv[1] if len(sys.argv) > 1 else None

    if arg == "--recent":
        d = get("/api/queries?perPage=100")
        print(f"{'time':<20} {'client':<16} {'status':<10} type  domain")
        for q in d.get("queries", []):
            ts = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(q.get("time", 0)))
            c = q.get("client", {})
            print(f"{ts:<20} {c.get('ip','?'):<16} {q.get('status','?'):<10} "
                  f"{q.get('type','?'):<5} {q.get('domain','?')}")
        return

    if arg:
        d = get(f"/api/queries?client={arg}&perPage=200")
        qs = d.get("queries", [])
        counts = {}
        for q in qs:
            dom = q.get("domain", "?")
            counts.setdefault(dom, [0, q.get("status", "?")])
            counts[dom][0] += 1
        print(f"Queries from {arg} (last {len(qs)}):")
        for dom, (n, status) in sorted(counts.items(), key=lambda x: -x[1][0]):
            print(f"  {n:>5}  {status:<10} {dom}")
        return

    td = get("/api/stats/top_domains?perPage=20")
    print("Top domains (all time, in-memory stats):")
    for row in td.get("domains", []):
        print(f"  {row.get('count', 0):>6}  {row.get('domain')}")
    tc = get("/api/stats/top_clients?perPage=20")
    print("Top clients:")
    for row in tc.get("clients", []):
        print(f"  {row.get('count', 0):>6}  {row.get('ip', '?')}  {row.get('name') or ''}")
    up = get("/api/stats/upstreams")
    print("Upstreams:", json.dumps(up.get("upstreams", up)))


if __name__ == "__main__":
    main()
