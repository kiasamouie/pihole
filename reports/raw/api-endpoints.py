#!/usr/bin/env python3
"""Discover Pi-hole v6 API endpoint paths.

Logs in via POST /api/auth, then downloads the admin UI JS bundles and greps
for `apiurl + "..."` / fetch/axios URL literals. Prints all candidate paths.
"""
import json
import re
import urllib.request

BASE = "http://127.0.0.1:3001"
pw = next(l.strip().split("=", 1)[1] for l in open("/home/kia/dns/.env")
          if l.startswith("ADMIN_PASSWORD="))

r = urllib.request.Request(BASE + "/api/auth", method="POST",
                            data=json.dumps({"password": pw}).encode(),
                            headers={"Content-Type": "application/json"})
with urllib.request.urlopen(r) as resp:
    body = json.loads(resp.read().decode())
sid = body["session"]["sid"]
print("SID acquired")

def get(path):
    req = urllib.request.Request(BASE + path)
    req.add_header("X-FTL-SID", sid)
    with urllib.request.urlopen(req) as resp:
        return resp.read().decode(errors="replace")

# Candidate JS files referenced by the admin app
candidates = ["/admin/scripts/js/index.js", "/admin/scripts/js/pio.js",
              "/admin/scripts/js/app.js", "/admin/scripts/js/api.js"]
for p in candidates:
    try:
        txt = get(p)
        print(f"== {p} : {len(txt)} bytes")
        found = re.findall(r'["\']?/api/[A-Za-z0-9_\-/{}]+', txt)
        found += re.findall(r'apiurl\s*\+\s*["\'][^"\']+["\']', txt)
        for f in sorted(set(found)):
            print("   ", f)
    except Exception as e:
        print(f"== {p} : error {e}")

# Also try the HTML to find script includes
try:
    html = get("/admin/")
    for s in sorted(set(re.findall(r'src="([^"]+)"', html))):
        print("html-script:", s)
except Exception as e:
    print("html error", e)
