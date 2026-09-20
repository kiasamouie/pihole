#!/usr/bin/env python3
"""Probe candidate Pi-hole v6 API paths and report status codes."""
import json
import urllib.request
import urllib.error

BASE = "http://127.0.0.1:3001"
pw = next(l.strip().split("=", 1)[1] for l in open("/home/kia/dns/.env")
          if l.startswith("ADMIN_PASSWORD="))

r = urllib.request.Request(BASE + "/api/auth", method="POST",
                            data=json.dumps({"password": pw}).encode(),
                            headers={"Content-Type": "application/json"})
with urllib.request.urlopen(r) as resp:
    body = json.loads(resp.read().decode())
sid = body["session"]["sid"]

paths = [
    "/api/status", "/api/info/status", "/api/info/version", "/api/info/ftl",
    "/api/info/messages", "/api/info/debug",
    "/api/dns/denylist", "/api/dns/allowlist", "/api/dns/restrict",
    "/api/denylist", "/api/allowlist",
    "/api/groups", "/api/clients", "/api/clients/192.168.0.197",
    "/api/logs/queries", "/api/dns/queries", "/api/history",
    "/api/history/clients", "/api/stats/summary", "/api/stats/top_domains",
    "/api/stats/top_clients", "/api/stats/upstreams", "/api/stats/query_types",
    "/api/settings", "/api/settings/blockingmode",
    "/api/dns/blocking", "/api/gravity", "/api/gravity/domainlist",
    "/api/dns/upstreams", "/api/upstreams",
    "/api/telemetry", "/api/privacy", "/api/audit",
]
for p in paths:
    req = urllib.request.Request(BASE + p)
    req.add_header("X-FTL-SID", sid)
    try:
        with urllib.request.urlopen(req) as resp:
            raw = resp.read()
            print(f"{resp.status}  {p}  ({len(raw)} bytes)")
            if len(raw) < 400:
                print("      ", raw.decode(errors="replace")[:380])
    except urllib.error.HTTPError as e:
        print(f"{e.code}  {p}")
    except Exception as e:
        print(f"ERR  {p}  {e}")
