#!/usr/bin/env python3
"""Idempotent Pi-hole v6 group/client provisioning (Phase 6).

Creates per-device policy groups and registers the LAN devices that will
use them. Safe to re-run: existing groups/clients are reused, missing ones
are added, group membership is reconciled.

Groups:
  Default    (id 0, built-in)  - everything not explicitly grouped
  TV-Monitor - TVs under observation: logging, default blocklist, no custom denies
  TV-Strict  - TVs once allow/block tuning is proven: stricter list set
  IoT        - IoT devices (e.g. .225)
  Trusted    - computers/phones that should get minimal or no filtering
  Testing    - experimental policies / test clients

Clients (from reports/02-lan-inventory.md):
  192.168.0.197  Samsung QE65Q75CATXXU (65" Q75A, Tizen)  -> TV-Monitor
  192.168.0.90   Google TV Streamer ("Living Room TV")     -> TV-Monitor
  192.168.0.225  "dgiot" (Shenzhen Bilian IoT)             -> IoT

Reads ADMIN_PASSWORD from the repo's .env (located next to this script; never printed).
"""
import json
import os
import sys
import time
import urllib.request
import urllib.error

BASE = "http://127.0.0.1:3001"
ENV_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".env")

GROUPS = {
    "TV-Monitor": "TVs under observation (logging + default blocklist only)",
    "TV-Strict":  "TVs with tuned stricter policy after evidence-based allow/block tuning",
    "IoT":        "IoT devices",
    "Trusted":    "Trusted computers/phones (minimal or no filtering)",
    "Testing":    "Experimental policies and test devices",
}
CLIENTS = {
    "192.168.0.197": ("Samsung QE65Q75A (Tizen)", ["TV-Monitor"]),
    "192.168.0.90":  ("Google TV Streamer (Living Room)", ["TV-Monitor"]),
    "192.168.0.225": ("dgiot (Bilian IoT)", ["IoT"]),
}

SID = None

def get_password():
    for line in open(ENV_FILE):
        if line.startswith("ADMIN_PASSWORD="):
            return line.strip().split("=", 1)[1]
    raise SystemExit("ADMIN_PASSWORD missing in .env")

def req(method, path, body=None):
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
        return e.code, json.loads(e.read().decode() or "{}")

def login():
    global SID
    pw = get_password()
    for attempt in range(3):
        code, body = req("POST", "/api/auth", {"password": pw})
        if code != 429:
            break
        time.sleep(20)
    if code != 200:
        raise SystemExit(f"login failed (http {code}): {body}")
    SID = body["session"]["sid"]

def main():
    login()
    # groups: GET /api/groups -> {"groups":[{name,id,...}]}
    code, body = req("GET", "/api/groups")
    gmap = {g["name"]: g["id"] for g in body.get("groups", [])}
    for name, comment in GROUPS.items():
        if name in gmap:
            print(f"group  {name:<12} exists (id {gmap[name]})")
            continue
        code, res = req("POST", "/api/groups", {"name": name, "comment": comment})
        if code in (200, 201):
            gid = res.get("groups", [{}])[0].get("id")
            gmap[name] = gid
            print(f"group  {name:<12} created (id {gid})")
        else:
            print(f"group  {name:<12} FAILED (http {code}): {res}")
            return 1

    # clients: GET /api/clients -> {"clients":[{ip,name,groups:[ids],...}]}
    code, body = req("GET", "/api/clients")
    cmap = {c["client"]: c for c in body.get("clients", [])}
    for ip, (name, gnames) in CLIENTS.items():
        groups = [gmap[g] for g in gnames if g in gmap]
        # v6 schema: clients have no name column; label goes in comment
        payload = {"client": ip, "comment": name, "groups": groups}
        if ip in cmap:
            existing = cmap[ip]
            if (sorted(existing.get("groups", [])) != sorted(groups)
                    or (existing.get("comment") or "") != name):
                code, _ = req("PUT", f"/api/clients/{ip}", payload)
                print(f"client {ip:<16} updated -> {gnames} (http {code})")
            else:
                print(f"client {ip:<16} exists, groups OK ({gnames})")
        else:
            code, res = req("POST", "/api/clients", payload)
            if code in (200, 201):
                print(f"client {ip:<16} created -> {gnames} (http {code})")
            else:
                print(f"client {ip:<16} FAILED (http {code}): {res}")
                return 1

    # final state
    code, body = req("GET", "/api/groups")
    print("\n--- final groups ---")
    for g in body.get("groups", []):
        print(f"  {g['id']:>3}  {g['name']:<12} {g.get('comment','')}")
    code, body = req("GET", "/api/clients")
    print("--- final clients ---")
    names = {v: k for k, v in gmap.items()}
    for c in body.get("clients", []):
        gl = [names.get(g, str(g)) for g in c.get("groups", [])]
        cip = c.get("ip") or c.get("client") or "?"
        label = c.get("comment") or c.get("name") or ""
        print(f"  {cip:<16} {label:<40} {gl}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
