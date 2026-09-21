# Enabling `standard-no-voice` on the Samsung — exact steps

Starting position: you are sitting at your computer. The Samsung is already
configured with:

```
IP       192.168.0.197
Mask     255.255.255.0
Gateway  192.168.0.128
DNS      192.168.0.128
```

`standard-no-voice` = standard (ACR + advertising + high-confidence telemetry +
DNS/DoT enforcement) **plus** blocking of the two confirmed Samsung/Bixby
voice-cloud hosts. It intentionally breaks cloud voice recognition. It does
**not** include the low-confidence strict telemetry or the DoH-IP set.

Everything is pre-tested (mock netns + throwaway table + temporary Pi-hole
group). Nothing here touches UFW, Docker, Plex, Samba, SSH or the invoice stack
beyond what TVGuard already manages.

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
- a resolution summary: `standard-no-voice: 37 domains -> ~135 IPs` (exact IP
  counts vary day-to-day — they are re-resolved every apply)
- `table ip tvguard` re-rendered with a `tv_privacy_blocked` set and the
  privacy/DoT drop rules (**no** `tv_doh_blocked` set — that is strict-only)
- Pi-hole group `TVGuard-Privacy` created with 37 exact-domain denies, client
  `192.168.0.197` attached

The TV does not need to be touched. From this moment its traffic to the listed
destinations is denied at both the firewall (IP) and Pi-hole (DNS) layer.

## Step 3 — Verify the server-side policy

```bash
sudo scripts/privacy-live-check.sh
```

**PASS looks like:** `tv_privacy_blocked` present, no DoH-IP set (correct for
this profile), privacy drop rule present, DoT drop rule present, **no rule
touches TCP/443 or UDP/443**, masquerade + DNS DNAT intact, all 37 group
domains present, client .197 attached, health-check green. It ends by listing
the physical TV tests only you can do (Step 5).

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

## Step 6 — Confirm the intentional voice failure

Press the voice button and give a command (e.g. "open YouTube").

**Expected:** the cloud voice command **fails** (timeout / "can't reach voice
service"). That is the policy working, not a bug. Everything else (remote,
apps, playback) must continue to work.

If voice unexpectedly still works, or if anything in Step 5 failed, go to
Step 8 first.

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
