#!/usr/bin/env python3
"""Idempotent Pi-hole v6 group/client provisioning.

Creates per-device policy groups and registers the TV clients from the
machine config (.env or config/tvguard.conf) that will use them. Safe to
re-run: existing groups/clients are reused, missing ones are added, group
membership is reconciled. Nothing household-specific is hardcoded: the
client list is exactly TVS from the machine config, tagged TV-Monitor.

Groups:
  Default    (id 0, built-in)  - everything not explicitly grouped
  TV-Monitor - TVs under observation: logging, default blocklist, no custom denies
  TV-Strict  - TVs once allow/block tuning is proven: stricter list set
  IoT        - IoT devices (add them manually via the API/UI if needed)
  Trusted    - computers/phones that should get minimal or no filtering
  Testing    - experimental policies / test clients

Reads ADMIN_PASSWORD from the repo's .env (located next to this script; never printed).
"""
import json
import os
import sys
import time
import urllib.request
import urllib.error

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tvguard_target_config import TargetConfigError, load_target_config
import yaml

BASE = "http://127.0.0.1:3001"
HERE = os.path.dirname(os.path.abspath(__file__))
ENV_FILE = os.path.join(HERE, "..", ".env")
INSTANCES = os.path.join(HERE, "..", "config", "privacy-instances.yaml")

GROUPS = {
    "TV-Monitor": "TVs under observation (logging + default blocklist only)",
    "TV-Strict":  "TVs with tuned stricter policy after evidence-based allow/block tuning",
    "IoT":        "IoT devices",
    "Trusted":    "Trusted computers/phones (minimal or no filtering)",
    "Testing":    "Experimental policies and test devices",
}

def get_clients():
    """Every TV in the machine config's TVS -> TV-Monitor (no hardcoding)."""
    try:
        with open(INSTANCES, encoding="utf-8") as fh:
            instances = (yaml.safe_load(fh) or {}).get("instances") or {}
        tc = load_target_config(instances)
    except TargetConfigError as exc:
        print("note: no machine config usable (%s) - registering no clients" % exc)
        return {}
    return {ip: ("TV (TVS entry)", ["TV-Monitor"]) for ip in tc.tvs}

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

    clients = get_clients()
    if not clients:
        print("note: TVS is empty in the machine config - no clients registered")
    # clients: GET /api/clients -> {"clients":[{ip,name,groups:[ids],...}]}
    code, body = req("GET", "/api/clients")
    cmap = {c["client"]: c for c in body.get("clients", [])}
    inames = {v: k for k, v in gmap.items()}
    for ip, (name, gnames) in clients.items():
        groups = [gmap[g] for g in gnames if g in gmap]
        # v6 schema: clients have no name column; label goes in comment
        if ip in cmap:
            # MERGE, never replace: keep the client's existing groups (e.g.
            # TVGuard-Privacy) and only add the missing desired ones.
            # Replacing the group list here would silently detach a TV from
            # its privacy group.
            existing = cmap[ip]
            have = list(existing.get("groups", []))
            want = have + [g for g in groups if g not in have]
            payload = {"client": ip, "comment": name, "groups": want}
            gl = [inames.get(g, str(g)) for g in want]
            if (sorted(have) != sorted(want)
                    or (existing.get("comment") or "") != name):
                code, _ = req("PUT", f"/api/clients/{ip}", payload)
                print(f"client {ip:<16} updated -> {gl} (http {code})")
            else:
                print(f"client {ip:<16} exists, groups OK ({gl})")
        else:
            payload = {"client": ip, "comment": name, "groups": groups}
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
