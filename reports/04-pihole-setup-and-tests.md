# 04 — Pi-hole v6 setup and validation

Date: 2026-09-20 · Container `pihole` (image `pihole/pihole:2026.09.0`, FTL 6.7.1)

## Installation decisions

- **Pinned image**: `pihole/pihole:2026.09.0` — latest *stable* tag from the Docker
  registry (tags are date-based; `prerelease:false`). Not `latest`, not `nightly`.
- **Ports**: 53/tcp+udp and 3001/tcp (UI). Both were free and already permitted by
  UFW from `192.168.0.0/24` (leftover AdGuard plan) → zero firewall changes.
  67/udp (DHCP), 123/udp (NTP), 443/tcp deliberately **not** published.
- **No DHCP**: no `67/udp`, no `NET_ADMIN` capability.
- **Upstreams**: `1.1.1.1;9.9.9.9`.
- **Gravity**: default StevenBlack/hosts (80,170 entries) — one conservative
  maintained list; no aggressive mega-lists (see REPORT.md §15/16 for why).
- **Config**: `etc-pihole/` (git-ignored). One change made to `pihole.toml` inside
  it: `webserver.api.max_sessions = 16 → 64` (session slots were being exhausted by
  API scripts; 64 gives headroom for tooling).

## v6 API differences that matter (verified live + from FTL source)

| v5 (tutorials) | v6 (this install) |
|---|---|
| `POST /api/login` → token | `POST /api/auth` → **session SID** (`X-FTL-SID` header) |
| `GET /api/status` | `GET /api/info/ftl` + `/api/info/database` (no single /status) |
| `POST /api/denylist` `{"domains":[...]}` | `POST /api/domains/deny/exact` `{"domain":[...]}` (regex: `/deny/regex`) |
| `GET /api/logs/queries` | `GET /api/queries` (filters: `client=`, `domain=`, `status=`, `perPage=`) |
| Web UI at `/` | Web UI at **`/admin/`** |
| client POST `{"ip":...}` | client POST `{"client": "...", "comment": ...}` (no name column; `name` is derived) |
| blocking → NXDOMAIN (assumed) | default mode answers **`0.0.0.0` with NOERROR** (ip_addr mode) |
| query status "blocked" | query status **`DENYLIST`** (for list blocks) |
| — | `GET /api/endpoints` + `/api/docs` self-document the API |

Source checked: `src/api/api.c` (route table) and `src/api/list.c` (payload parsing)
from `pi-hole/FTL` (copies in `reports/raw/ftl-*.c`).

## Test results (`scripts/pihole-selftest.py`)

```
[PASS] login (http 200)
[PASS] ftl info reachable (uptime ...)
[PASS] gravity DB loaded (domains: 80170)
[PASS] denylist add (http 201)
[PASS] blocked query -> blackholed (got NOERROR (blackhole IP))
[PASS] denylist entry visible (id=...)
[PASS] denylist remove (http 204)
[PASS] allowed query -> resolves (got NOERROR)
[PASS] query log captured test queries (... denied-status row seen: True)
ALL PASS
```

Notes learned while testing:
- The first run used `example.com` and "failed" only because dnsmasq's cache
  (long TTL) answered from cache — blocked domains are chosen fresh (`iana.org`).
- Two 429s were hit: `PASSWORD_RATE_LIMITED` (brief, cools off) and
  `api_seats_exceeded` (fixed via `max_sessions=64` + a single-session script design).

## Persistence test

- `docker restart pihole` → container healthy in ~45 s; `dig @127.0.0.1` → NOERROR
  (UDP + TCP) immediately.
- Deny entry `iana.org` added **before** restart survived the restart (present in
  `gravity.db` `domainlist` table and still blackholed), then removed cleanly.
- Groups/clients (created in Phase 6) also survive restarts (same DB file).

## Groups/clients created (Phase 6, idempotent via scripts/setup-pihole-groups.py)

| Group | id | Purpose |
|---|---|---|
| Default | 0 | built-in |
| TV-Monitor | 1 | TVs under observation (logging + default gravity) |
| TV-Strict | 2 | for stricter policy after evidence-based tuning |
| IoT | 3 | IoT devices |
| Trusted | 4 | minimal/no filtering |
| Testing | 5 | experimental |

Clients: `192.168.0.197` (Samsung QE65Q75A) → TV-Monitor; `192.168.0.90`
(Google TV Streamer) → TV-Monitor; `192.168.0.225` (dgiot) → IoT.

No block lists beyond the default gravity are active for any group yet —
**nothing is being blocked** beyond what the default gravity list blocks for any
client that (later) uses this resolver, and **no client uses it yet**.
