# Samsung TV Manual Test Checklist (after enabling a privacy profile)

For: Samsung QE65Q75CATXXU at `192.168.0.197` (gateway + DNS = `192.168.0.128`).

Run these tests in order **after** you have enabled a profile and
`sudo scripts/privacy-live-check.sh` has passed. The server cannot click the TV;
these are the physical steps. For each test: what you do, what counts as PASS,
what counts as FAIL, and the server command to diagnose a failure.

Useful server diagnostics (run from kiaserver):

```bash
python3 scripts/show-dns-activity.py 192.168.0.197     # recent DNS queries from the TV (with results)
sudo scripts/privacy-policy-status.sh                  # current policy state + Pi-hole group
sudo dmesg | grep -E 'TVGUARD-(PRIVACY|DOT|DOH)' | tail -30   # firewall block events (dest IP shown)
sudo conntrack -L | grep 192.168.0.197 | head           # live NATed connections through the server
sudo scripts/tvguard-status.sh                         # TVGuard mode + counters + NAT health
```

---

## 1. Samsung home screen

- **Do:** power the TV on, leave it on the home screen for 2 minutes.
- **PASS:** home screen loads normally, recently-used apps visible, no app stuck
  on a spinner, no repeated "network error" banners.
- **FAIL:** apps fail to open, endless spinners, or error banners.
- **Diagnose:** `show-dns-activity.py` — look for the failing app's domains
  returning blocked/failed; `dmesg | grep TVGUARD-PRIVACY` to see which
  destination was dropped.

## 2. TV Plus / EPG (if you use it)

- **Do:** open TV Plus, wait for the channel list to populate.
- **PASS:** channel list appears and a channel plays.
- **FAIL:** channel list never loads.
- **Diagnose:** `show-dns-activity.py` — the EPG host
  (`tvpnlinupepgpeu.samsungcloud.tv`) is on the keep list and must resolve;
  if it does not, that is an infrastructure bug, not the policy.

## 3. YouTube

- **Do:** open YouTube, play a video, seek forward/back once, close.
- **PASS:** playback starts within ~5 s, seeking works, video completes.
- **FAIL:** buffering loop, immediate stop, or "can't play video".
- **Diagnose:** `conntrack -L | grep 192.168.0.197` should show UDP/443 (QUIC)
  and/or TCP/443 flows to Google video IPs; `dmesg | grep TVGUARD-PRIVACY` must
  NOT show a googlevideo/YouTube IP being dropped.

## 4. Plex

- **Do:** open the Plex app, play something from your server.
- **PASS:** plays. Note: this traffic is mostly **LAN-local** (direct L2, does
  not traverse the server), so the server logs will show little. A few
  Plex-related metadata connections may go out to the Internet — that is normal.
- **FAIL:** app won't connect or playback never starts.
- **Diagnose:** first check the Plex server itself (it must be reachable from
  the TV on the LAN — that is outside this policy's scope); then
  `show-dns-activity.py` for plex.tv/plexapp domains.

## 5. Prime Video (if used)

- **Do:** open Prime Video, start a title.
- **PASS:** streams.
- **FAIL:** login loop or instant stop.
- **Diagnose:** `show-dns-activity.py` — the keep list protects
  `unagi-eu.amazon.com`, `api.amazon.co.uk`, `api.amazonvideo.com`; if any of
  those are blocked it is a bug to report.

## 6. Netflix (if available)

- **Do:** open Netflix, start a title.
- **PASS:** streams. Note: `nrdp.logs.netflix.com` (telemetry) is blocked by
  the policy — playback is not supposed to need it.
- **FAIL:** streams fail or quality is stuck low.
- **Diagnose:** `conntrack -L | grep 192.168.0.197` for Netflix CDN flows;
  `dmesg | grep TVGUARD-PRIVACY` to confirm only the telemetry host is hit.

## 7. Casting from a phone

- **Do:** cast a phone video to the TV (or screen-mirror).
- **PASS:** casting discovers the TV and plays. This is **LAN-local**
  (mDNS/SSDP/direct), not affected by the egress policy; if it fails, check the
  phone and TV are on the same network — not the privacy policy.
- **FAIL:** TV not found, or cast drops.
- **Diagnose:** mostly a LAN issue; on the server, confirm the TV still has a
  healthy path: `sudo scripts/tvguard-status.sh`.

## 8. App store

- **Do:** open the Samsung app store, let it list apps; optionally open one app
  detail page.
- **PASS:** app list and detail pages load.
- **FAIL:** store blank or "network error".
- **Diagnose:** `show-dns-activity.py` — the app-store/Smart Hub hosts are kept;
  check which domain failed.

## 9. Firmware update check

- **Do:** Settings → Support → Software Update → Check for Update.
- **PASS:** it completes the check ("Your TV is up to date" or an offer to
  update). Note: the *notification* hosts
  (`notice*.samsungcloudsolution.com`) are blocked on purpose — the check itself
  uses the kept OTA infrastructure (`otnprd*`, `www.samsungotn.net`,
  `otn.samsungcloudcdn.com`), so updates still work. You may simply stop seeing
  unsolicited "new update available" banners.
- **FAIL:** the check itself fails/times out.
- **Diagnose:** `show-dns-activity.py` during the check; verify an `otn*`
  domain resolved and was not dropped.

## 10. Samsung account / home services

- **Do:** open an app that uses Samsung account (e.g. SmartThings, or your
  account page), confirm you are still signed in and content loads.
- **PASS:** account works, push content (SmartThings) still updates.
- **FAIL:** forced sign-out, or services erroring.
- **Diagnose:** `show-dns-activity.py` — `auth.samsungosp.com` and
  `gld.push.samsungosp.com` are kept; if blocked, it is a bug.

## 11. Voice / Bixby  ← **expected to FAIL under standard-no-voice / strict**

- **Do:** press the voice button (or say the wake phrase) and give a simple
  voice command ("open YouTube").
- **EXPECTED RESULT:** the cloud voice command **fails** (timeout,
  "can't reach the voice service", or no response). This is **intentional** —
  the two confirmed Bixby cloud hosts are blocked. On-device behaviour, the
  remote, and all other functions must still work.
- **If cloud voice still works:** the block is not in place — run
  `sudo scripts/privacy-policy-status.sh` and
  `sudo dmesg | grep TVGUARD-PRIVACY` (you should see drops to the aibixby IPs
  when you try voice).
- **Diagnose:** `show-dns-activity.py` should show the aibixby domains
  returning blocked; `dmesg` should show `TVGUARD-PRIVACY DST=<aibixby IP>`
  events while you are speaking.

---

## If anything genuinely breaks (tests 1–10)

1. `sudo scripts/privacy-policy-disable.sh` (one command — privacy layer off,
   gateway/monitoring stay, TV internet returns immediately).
2. If it works again, the failing domain is visible in
   `python3 scripts/show-dns-activity.py 192.168.0.197` (blocked entries) —
   report it; if the keep decision is right it goes into
   `config/privacy-keep.yaml` and the policy is re-applied.
3. `sudo scripts/privacy-policy-apply.sh standard-no-voice`
   `sudo scripts/privacy-watch.sh 30 --auto-rollback`
