# LG TV Manual Test Checklist (after enabling an LG privacy profile)

For: the LG webOS TV (address assigned after network discovery; gateway + DNS =
`192.168.0.128`).

**Target profile: `manufacturer-lockdown` (LG).** Expected results: everything
EXCEPT **cloud voice** and **ThinQ cloud** must work. Alphonso ACR, LG ads and
high-confidence telemetry are blocked. Any unclassified hostname inside one of
the 7 LG deny-default zones is denied + logged — if a test fails, run
`sudo scripts/show-unknown-samsung.sh lg 24` (newly-denied LG hosts) and, if it
is essential, `sudo scripts/manufacturer-review.sh lg keep <domain> "reason"`.

Run these tests in order **after** `sudo scripts/privacy-live-check.sh lg`
passes. For each test: what you do, what is PASS, what is FAIL, and the server
diagnostic. Replace `<LGIP>` with the TV's confirmed address.

Useful server diagnostics (from kiaserver):

```bash
python3 scripts/show-dns-activity.py <LGIP>      # recent DNS queries from the LG (with results)
sudo scripts/privacy-policy-status.sh             # per-vendor state + Pi-hole groups
sudo dmesg | grep -E 'TVGUARD-(PRIVACY-LG|DOT-LG)' | tail -30   # LG firewall block events
sudo conntrack -L | grep <LGIP> | head            # live NATed connections
sudo scripts/tvguard-status.sh                    # TVGuard mode + counters + NAT health
sudo scripts/privacy-watch.sh 30                  # 30-minute safety watch (both vendors)
```

---

## 1. Home screen

- **Do:** power the TV on, leave it on the home screen for 2 minutes.
- **PASS:** home screen loads, recently-used apps visible, no stuck spinners,
  no repeated network-error banners.
- **FAIL:** apps fail to open, endless spinners, error banners.
- **Diagnose:** `show-dns-activity.py <LGIP>` — which app domains are failing;
  `dmesg | grep TVGUARD-PRIVACY-LG` — which destination was dropped.

## 2. TV Plus / EPG (if used)

- **Do:** open LG Channels / TV Plus, wait for the channel list.
- **PASS:** channel list appears, a channel plays.
- **FAIL:** list never loads.
- **Diagnose:** `show-dns-activity.py <LGIP>` — the LG broadcast/EPG hosts must
  resolve; if an LG host is denied, check the unknown-host report and add a keep
  if it is genuinely essential (see LG_BLOCKING_PLAN.md non-zones).

## 3. YouTube

- **Do:** open YouTube, play a video, seek once, close.
- **PASS:** playback within ~5 s, seeking works.
- **FAIL:** buffering loop, immediate stop, "can't play video".
- **Diagnose:** `conntrack -L | grep <LGIP>` should show UDP/443 (QUIC) and/or
  TCP/443 to Google video IPs; `dmesg | grep TVGUARD-PRIVACY-LG` must NOT show a
  googlevideo/YouTube IP being dropped.

## 4. Plex

- **Do:** open Plex, play something from your server.
- **PASS:** plays. Most of this traffic is LAN-local (direct L2, does not
  traverse the server); a few plex.tv metadata connections may go out — normal.
- **FAIL:** app won't connect or playback never starts.
- **Diagnose:** first confirm the Plex server is reachable on the LAN (outside
  this policy's scope); then `show-dns-activity.py <LGIP>` for plex.tv/plexapp.

## 5. Prime Video (if used)

- **Do:** open Prime Video, play a title.
- **PASS:** playback works (Amazon/CloudFront infra is never touched).
- **FAIL:** won't start.
- **Diagnose:** `conntrack -L | grep <LGIP>` for amazonvideo/cloudfront flows;
  a denied cloudfront IP would be a policy bug — report it.

## 6. Netflix (if used)

- **Do:** open Netflix, play a title.
- **PASS:** playback works.
- **FAIL:** won't start.
- **Diagnose:** as above (nflxvideo.net / netflix.com must resolve and connect).

## 7. Casting (Chromecast built-in / AirPlay where supported)

- **Do:** cast a video from your phone to the LG.
- **PASS:** cast starts and plays.
- **FAIL:** TV not found or cast fails.
- **Diagnose:** casting is mostly LAN-local; confirm the phone and LG are on the
  same LAN segment (both behind the hub) and that the TV is reachable. The
  privacy policy does not filter LAN traffic.

## 8. LG Content Store

- **Do:** open the Content Store, browse an app's detail page, (optionally)
  install or update an app.
- **PASS:** store loads, app pages render, install/update works.
- **FAIL:** store empty or apps won't install.
- **Diagnose:** `lgappstv.com` (store CDN) and the Content Store API hosts must
  resolve (`show-dns-activity.py`); if a store-related LG host is denied,
  review the unknown-host report and add a keep if essential.

## 9. Firmware / update check

- **Do:** Settings → General → About this TV (or check-for-updates if offered).
- **PASS:** firmware info displays; an update check completes or reports
  "up to date" without hanging.
- **FAIL:** update check hangs/fails.
- **Diagnose:** firmware hosts (su/snu/ngfts/gfts on lge.com + wiselg twins)
  are keep-protected; if denied, that is a policy bug — report it.

## 10. LG account / home services

- **Do:** sign in / open Settings where your LG account is shown.
- **PASS:** account screens work.
- **FAIL:** sign-in fails.
- **Diagnose:** lgauth/account hosts must resolve (keep-protected).

## 11. Cloud voice / voice search — EXPECTED TO DEGRADE OR FAIL

- **Do:** use the voice remote (or voice search) and ask:
  * "What is the weather in Tokyo right now?" (decline location if prompted)
  * "What is the current price of Bitcoin?"
- **PASS (intended):** the TV cannot fetch a fresh cloud answer — it errors,
  stalls, or only answers from what it has locally.
- **FAIL (policy regression):** a fresh cloud answer comes back. Then run
  `sudo scripts/privacy-proof-capture.sh voice-lg lg` around the test, and
  inspect `captures/voice-discovery/` for the allowed voice path — it will
  either be an unlisted standalone voice host (add it) or the multiplexed
  `nextlgsdp.com` sdp_nlp channel (documented network-layer limitation, see
  LG_BLOCKING_PLAN.md "Voice").
- **Note:** local wake word and simple on-device recognition may still work —
  that is expected and not a failure.

## 12. ThinQ — EXPECTED CLOUD FUNCTIONALITY LOSS (intended)

- **Do:** open the ThinQ app on your phone and try to view/control the TV.
- **PASS (intended):** the ThinQ cloud functions fail (the lgtviot.com /
  lgthinq.com zones are deny-default).
- **FAIL (policy regression):** if the TV's NORMAL apps or home screen are
  affected by this, something is wrong — report it.
- Ordinary TV remote control (the physical remote) is unaffected by design.

---

If everything above holds: the LG policy is working as designed. Keep
`privacy-watch.sh` running for the first 30–60 minutes, then review
`sudo scripts/show-unknown-samsung.sh lg 24` for anything new that appeared.
