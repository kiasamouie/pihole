# ROUTER_NEXT_STEPS — staged rollout (perform when you're present at the Hub)

**Nothing below is done yet.** This is the manual sequence for the Virgin Hub 3.
Each step is independent and reversible; stop at any step if something looks
wrong. The goal is to move **one device at a time** so you never have the
"whole family's internet is broken" problem.

**Prerequisites (already true on kiaserver):**
- Pi-hole up at `192.168.0.128`, DNS on `53`, UI at `http://192.168.0.128:3001/admin/`.
- Groups exist: `TV-Monitor`, `TV-Strict`, `IoT`, `Trusted`, `Testing`.
- TVs already registered as clients in `TV-Monitor`.

---

## STEP 1 — Reserve the server's IP in the Virgin Hub
- **Why**: Pi-hole's IP must not change or DHCP must not hand it to another device.
- **Where**: Hub 3 admin (usually `http://192.168.0.1`, log in) → *LAN / Network →
  DHCP → IP reservation* (wording varies).
- **Values**:
  - MAC: `68:1D:EF:32:4F:56` (kiaserver, `enp2s0`)
  - Reserve: `192.168.0.128`
- **Result**: server keeps `.128` forever. Reboot the server to confirm it renews `.128`.
- **Revert**: delete the reservation.

## STEP 2 — Point ONE test device at Pi-hole (NOT a TV yet)
- Use **KiaPC** (`192.168.0.206`, Windows) or your phone.
- On that device: set DNS to `192.168.0.128` (static/override DNS, leave gateway as-is).
- On Windows: `Settings → Network → (Wi‑Fi/Eth) → IP assign → Edit → DNS` → `192.168.0.128`.
- **Do not** change the Hub's global DNS yet.

## STEP 3 — Verify queries appear in Pi-hole
- On the test device open a normal site.
- Check the UI (`http://192.168.0.128:3001/admin/` → Queries) or:
  `python3 scripts/show-dns-activity.py 192.168.0.206`
- **Success**: you see the device's queries and the device is tagged. If nothing
  appears, the device isn't using us (check its DNS setting / flush its resolver).

## STEP 4 — Move ONE TV onto Pi-hole DNS
- **Samsung TV (`.197`)**: *Settings → General → Network → Network Status* → set DNS
  to **Manual** and enter `192.168.0.128`. (Some Tizen builds only let you set DNS in
  advanced network settings; the path may vary by firmware.)
- Test on the TV: **YouTube, Plex, casting from your phone**, and the home screen.
- Watch Pi-hole: `python3 scripts/show-dns-activity.py 192.168.0.197` — you should now
  see the TV's domain lookups (this is the data that makes everything else possible).
- **If a function breaks** (e.g. YouTube): note the failing domain, add it to the
  TV's allowlist in Pi-hole, retest. This is the start of the allowlist-tuning loop.

## STEP 5 — Observe 24 hours (block nothing new)
- Let the TV (and the test device) run normally.
- In Pi-hole inspect: **Top Domains**, **Top Clients**, and the per-client query log.
- Build the evidence table (which domains appear during idle vs YouTube vs Plex vs
  voice). This is raw material for classification — **do not block yet**.

## STEP 6 — Apply the TV-Monitor profile
- `TV-Monitor` already exists and the TVs are already in it. "Applying" it means:
  keep **logging** on, keep the **default gravity list** active for the TV, and add
  nothing aggressive. This is the safe baseline policy.

## STEP 7 — Test ONE known telemetry candidate
- Pick **one** domain from the 24 h data that is clearly telemetry (appears only on
  idle/background, not during video, not needed for a function).
- Block it **for the TV group only** (Pi-hole → Groups → TV-Monitor → add to the
  group's denylist, or use the API), **not** globally.
- Confirm the TV still works (YouTube/Plex/cast). If it still works → keep it blocked.
  If a function breaks → allowlist it instead and pick a different candidate.

## STEP 8 — Only then consider network-wide DNS
- **Option A (recommended first)**: leave DNS per-device (you control exactly who is
  filtered). Most home setups stop here — it's already strong.
- **Option B**: set the **Hub's global DNS** to `192.168.0.128` so every device uses
  it. Do this **after** the TV + one PC are proven stable. Watch the Trusted devices
  (PCs/phones) for breakage and allowlist as needed.

## STEP 9 — Later: gateway/firewall (the dedicated box)
- When you buy the dedicated box (Section 19 of the report), the Hub moves toward
  **modem mode** and the box takes over: routing/NAT, **forced** DNS (block egress
  53/853/DoH so clients *can't* bypass Pi-hole), per-device egress, and the TV/IoT
  VLAN. This is when ntopng/Zeek become worthwhile and the real per-IP block rules
  (Layer 3) go in.

---

### DNS-bypass test (do this once a TV is on our DNS, before declaring it secure)
To detect a TV trying to **skip** our resolver:
1. In Pi-hole, watch the query log for lookups of public resolvers:
   `1.1.1.1`, `8.8.8.8`, `dns.google`, `one.one.one.one`, `quad9.net`, etc. A query
   *for* one of these names from the TV's IP is a bypass signal.
2. On the gateway (later), you can then **block egress** to those resolvers' IPs on
   UDP/TCP 53 and 853, and block DoH, forcing all DNS through us.
3. **Do not block these now** — logging first, blocking only after you've seen the
   behaviour and confirmed the TV still functions.

### How to revert any step
- Undo the DNS setting on the device (set it back to automatic / the Hub's DNS).
- Pi-hole changes: `scripts/` or the UI (Groups → remove client; denylist → remove).
- Full teardown: `ROLLBACK.md`.
