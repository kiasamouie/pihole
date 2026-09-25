# Enabling the privacy policy on the Samsung — exact steps

**Current state (2026-09-22): `manufacturer-lockdown` is ALREADY LIVE** on
192.168.0.197. If you are re-enabling after a rollback, the recommended
profile is `manufacturer-lockdown` (this section); `standard-no-voice`
remains documented below for reference.

## Enabling `manufacturer-lockdown` (recommended — what is live)

From a clean baseline (policy off):

```bash
cd /home/kia/dns
sudo scripts/privacy-policy-apply.sh manufacturer-lockdown   # re-resolves + re-renders + re-pushes (idempotent)
sudo scripts/privacy-reset-tv-manufacturer-state.sh --flush-dns-cache  # expire stale .197 flows to denied mlock IPs + flush Pi-hole DNS cache (per-TV only)
sudo scripts/privacy-live-check.sh                           # must show 10/10 PASS incl. the two scope lines
sudo scripts/privacy-watch.sh 30 --auto-rollback             # 30-minute safety watch (separate terminal)
```

Expected: `tv_privacy` set = {192.168.0.197} only (Google TV unaffected);
group TVGuard-Privacy = 70 rows (37 exact + 14 regex + 19 allow); 166 deny IPs
in the firewall; no rule touches 443/UDP-443; unknown Samsung hosts denied +
logged (review: `sudo scripts/show-unknown-samsung.sh 24`).

---

# Enabling `standard-no-voice` (reference) — exact steps

Starting position: you are sitting at your computer. The Samsung is already
configured with:

```
IP       192.168.0.197
Mask     255.255.255.0
Gateway  192.168.0.128
DNS      192.168.0.128
```

`standard-no-voice` = standard (ACR + advertising + high-confidence telemetry +
DNS/DoT enforcement) **plus** blocking of Samsung's Bixby/AI-assistant cloud
voice plane. Since v2 (2026-09-21, after the Tokyo-weather regression — see
REGRESSIONS.md + reports/09) this means: the two confirmed Bixby exact hosts
**plus the scoped `*.aibixby.com` suffix policy** (the TV's actual live voice
path, `prdcore1-euw1-user.aibixby.com` et al., is inside that family). It
intentionally breaks cloud voice recognition. It does **not** include the
low-confidence strict telemetry or the DoH-IP set.

Everything is pre-tested (mock netns + throwaway table + temporary Pi-hole
group + full selftest 99/0). Nothing here touches UFW, Docker, Plex, Samba,
SSH or the invoice stack beyond what TVGuard already manages.

**If the policy is already live (v1) and you want v2**, the only action is a
re-apply + voice-state reset:

```bash
cd /home/kia/dns
sudo scripts/privacy-policy-apply.sh standard-no-voice   # re-resolves + re-renders + re-pushes (idempotent)
sudo scripts/privacy-reset-tv-voice-state.sh             # expires any open .197<->voice-IP connections (per-TV only)
sudo scripts/privacy-live-check.sh                       # must show 38 group entries (37 exact + 1 regex)
```

---

## Step 1 — Pre-check

```bash
cd /home/kia/dns
sudo scripts/tvguard-status.sh
scripts/health-check.sh
```

**Expected:** TVGuard `MODE=monitor`, `PRIVACY=off`, Pi-hole healthy, and
health-check all green (Plex :32400, Samba :445, Transmission :9091, SSH
:13567, docker pihole + invoice containers running, no DHCP listener, no
privacy sets in nftables).

If anything is not green, stop and fix that first — do not enable blocking on
top of an unhealthy baseline.

## Step 2 — Enable standard-no-voice

```bash
cd /home/kia/dns
sudo scripts/privacy-policy-apply.sh standard-no-voice
```

**Expected output:**
- a resolution summary: `standard-no-voice: 37 domains -> ~164-172 IPs`
  (exact IP counts vary day-to-day — they are re-resolved every apply)
- `table ip tvguard` re-rendered with a `tv_privacy_blocked` set and the
  privacy/DoT drop rules (**no** `tv_doh_blocked` set — that is strict-only)
- Pi-hole group `TVGuard-Privacy` with **38 entries: 37 exact-domain denies +
  1 regex (the aibixby.com voice-family suffix)**, client `192.168.0.197`
  attached
- then run `sudo scripts/privacy-reset-tv-voice-state.sh` once, so no pre-
  existing TV connection to a voice IP survives (it only touches .197's
  conntrack entries toward the resolved voice IPs)

The TV does not need to be touched. From this moment its traffic to the listed
destinations is denied at both the firewall (IP) and Pi-hole (DNS) layer.

## Step 3 — Verify the server-side policy

```bash
sudo scripts/privacy-live-check.sh
```

**PASS looks like:** `tv_privacy_blocked` present, no DoH-IP set (correct for
this profile), privacy drop rule present, DoT drop rule present, **no rule
touches TCP/443 or UDP/443**, masquerade + DNS DNAT intact, all 38 group
entries present (37 exact + 1 regex — the new regex-presence line must say
PASS), client .197 attached, health-check green. It ends by listing the
physical TV tests only you can do (Step 5).

## Step 4 — Start the 30-minute safety watch

```bash
sudo scripts/privacy-watch.sh 30 --auto-rollback
```

Run this in a **separate terminal** (it prints one line per minute for 30
minutes). While it runs, use the TV normally (Step 5). Watch for:
`pihole=OK`, `samsung conntrack` > 0 while the TV is active, `PRIV=` counter
only creeping up when a listed destination is actually attempted, `host=OK`.

`--auto-rollback` disables **only the privacy layer** (never the gateway/NAT)
if the TV path dies, Pi-hole goes unhealthy, or a host service dies — for 3
consecutive minutes.

## Step 5 — Physical TV testing

Follow `TV_MANUAL_TEST_CHECKLIST.md` in order: home screen → TV Plus/EPG →
YouTube → Plex → Prime Video → Netflix → casting → app store → firmware check →
Samsung account → **voice last**. Tests 1–10 must all PASS.

## Step 6 — Confirm the intentional voice failure (scientific version)

Follow `VOICE_BLOCK_VERIFICATION.md`: run `sudo scripts/voice-proof-capture.sh`
(one command, 7 minutes, on-screen countdown), then ask, in order:

1. "What is the weather in Tokyo right now?" (decline location)
2. "What is the weather in Sydney right now?"
3. "What is the current price of Bitcoin?"

**Expected:** all three **fail** to produce a fresh cloud answer (that is the
policy working, not a bug), while remote, apps and playback keep working.
Simple/local commands may still work — expected.

If a cloud answer still succeeds, do NOT disable — report the capture
directory name; the capture shows exactly which destination still got
through and it gets added in the next iteration.

## Step 7 — Inspect blocked attempts

```bash
sudo dmesg | grep -E 'TVGUARD-(PRIVACY|DOT|DOH)' | tail -30
python3 scripts/show-dns-activity.py 192.168.0.197
```

- `TVGUARD-PRIVACY DST=<ip>` = a firewall deny hit (ACR/ad/telemetry/voice IP).
- `TVGUARD-DOT` = the TV tried DoT (853) and was dropped.
- `TVGUARD-DOH` should not appear in this profile (DoH-IP set is strict-only).
- `show-dns-activity.py` shows the DNS layer: blocked domains answer `0.0.0.0`
  for client `192.168.0.197` and are attributed correctly (not the Docker
  bridge IP).

## Step 8 — Emergency rollback (if needed)

```bash
sudo scripts/privacy-policy-disable.sh
```

This removes **only** the privacy layer: the `tv_privacy_blocked` set + privacy
drop rules (the table is re-rendered; masquerade, DNS-bypass DNAT, monitor
mode, UFW route rules all stay) and the Pi-hole group `TVGuard-Privacy` with
its domains and client attachment. Normal TV Internet returns immediately.
The TV itself needs no changes; UFW, Docker, Plex, Samba, SSH and the invoice
stack are untouched. Afterwards, re-run Step 1 to confirm the clean baseline.

## Step 9 — Offline → reconnect experiment (AFTER functionality is proven)

Only once Steps 5–7 have all passed:

```bash
sudo scripts/tv-offline-reconnect-test.sh samsung 10m
```

What the script does: baseline → deny the Samsung's WAN egress only (LAN/Plex
path stays up) → record for 10 minutes → restore WAN → capture the first
minutes after reconnect → compare, and always restore MONITOR mode (traps,
fail-safe; the TV is never left offline).

**While it is offline, use the TV normally** (open YouTube, wait for it to
fail, browse apps) so there is something to "make up" on reconnect.

**What the report CAN prove:** that `X bytes were uploaded to destination Y`
immediately after connectivity returned, when Y is Samsung/Bixby/telemetry
infrastructure — i.e. evidence of a *deferred upload burst* and its destination.

**What it CANNOT prove:** what was in those bytes. Encrypted uploads cannot be
identified as transcripts/audio on the network. The script never claims that.

---

## Commands at a glance

```bash
cd /home/kia/dns
sudo scripts/privacy-policy-apply.sh standard-no-voice   # enable (this is the one action)
sudo scripts/privacy-live-check.sh                       # verify server side
sudo scripts/privacy-watch.sh 30 --auto-rollback         # safety watch
sudo scripts/privacy-policy-disable.sh                   # one-command rollback (privacy layer only)
```
