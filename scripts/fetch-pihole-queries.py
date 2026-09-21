#!/usr/bin/env python3
"""
fetch-pihole-queries.py - Fetch the Pi-hole v6 query log for one client + time window.

Why this exists:
  Verified against the live Pi-hole v6 API on this box:
    - `from=/to=` and `since=` are SILENTLY IGNORED (they return the newest
      100 rows regardless of the window);
    - only `until=` is honoured (upper time bound);
    - `limit` is capped at 100 rows per response (limit=1000 -> 100);
    - `page` is IGNORED (page=1 and page=2 return the identical 100 rows),
      so naive `while len(qs) == 100: page += 1` loops hang forever.
  Robust strategy: BACKWARD CURSOR using only `until`. Fetch the newest 100
  rows with time <= B, keep those with time >= T0, then set B to just below
  the oldest row seen and repeat until we pass T0 or a short batch arrives.
  Rows are de-duplicated by query id, so this is safe to re-run.

Usage:
  fetch-pihole-queries.py <pihole-ip> <port> <client-ip> <t0-utc-epoch> <t1-utc-epoch> <outfile>
  fetch-pihole-queries.py --sid <SID> <pihole-ip> <port> <client-ip> <t0> <t1> <outfile>

Auth:
  Without --sid the password is read from the repo's .env (ADMIN_PASSWORD=)
  and a session is requested from /api/auth.

Only query metadata (domain, status, client, rrtype, replies) is written.
No packet payloads are involved.
"""
import json
import os
import sys
import urllib.parse
import urllib.request


def main():
    args = sys.argv[1:]
    sid = None
    if args and args[0] == "--sid":
        sid, args = args[1], args[2:]
    if len(args) != 6:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    ip, port, client, t0, t1, outfile = args
    t0, t1, port = int(t0), int(t1), int(port)

    if sid is None:
        envpath = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".env")
        pw = None
        with open(envpath) as f:
            for line in f:
                if line.startswith("ADMIN_PASSWORD="):
                    pw = line.strip().split("=", 1)[1]
        if not pw:
            print("no ADMIN_PASSWORD in .env", file=sys.stderr)
            sys.exit(3)
        req = urllib.request.Request(
            f"http://{ip}:{port}/api/auth",
            data=json.dumps({"password": pw}).encode(),
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=10) as r:
            sid = json.loads(r.read())["session"]["sid"]

    def fetch_until(b):
        # Only `until` is honoured by the v6 API; from/since are ignored.
        url = (
            f"http://{ip}:{port}/api/queries?"
            + urllib.parse.urlencode({"client": client, "until": b, "limit": 100})
        )
        req = urllib.request.Request(url)
        req.add_header("X-FTL-SID", sid)
        with urllib.request.urlopen(req, timeout=15) as r:
            return json.loads(r.read()).get("queries", [])

    seen = {}
    b = float(t1)
    max_steps = 500  # safety cap: 500 x 100 rows
    for _ in range(max_steps):
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
            break  # short batch or we have walked back past the window start
        b = min(times) - 0.5  # strictly older than the oldest row seen (sub-second ts)
    # The final (oldest) batch may extend below the window start: filter.
    out = [q for q in seen.values() if isinstance(q.get("time"), (int, float)) and q["time"] >= t0]
    out.sort(key=lambda q: q.get("time") or "")
    with open(outfile, "w") as f:
        json.dump(out, f, indent=1)
    print(f"fetched {len(out)} unique queries for {client} ({t0}->{t1}) -> {outfile}")


if __name__ == "__main__":
    main()
