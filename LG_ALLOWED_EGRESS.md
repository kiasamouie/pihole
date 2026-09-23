# What LG CAN still receive (manufacturer-lockdown)

Everything LG-owned that is intentionally still allowed, with purpose, why, and
privacy implications. No invisible allow decisions. Client scope: the LG IP
only (group `TVGuard-Privacy-LG` + `tv_privacy_lg` firewall set).

## LG-owned, allowed

| domain / family | purpose | why allowed | privacy implications |
|---|---|---|---|
| `gb.lgtvsdp.com`, `us.lgtvsdp.com`, `gb.nextlgsdp.com`, `cc.nextlgsdp.com`, `security.lgtvsdp.com` | SDP time channel (systemTimeSource=sdp), security notices | Family-wide block leaves the clock stuck at 2021-01-01 → all TLS fails (furkan-bayrak issue #6, HaGeZi #11438). Only `rdx2.*` (telemetry) is denied by exact name. | LG sees the TV's clock-sync handshake (region, model). No viewing data expected; the zone is NOT deny-by-default. |
| `su.lge.com`, `su-ssl.lge.com`, `snu.lge.com`, `nsu.lge.com` | Firmware / software update checks | Essential OTA; blocking breaks updates. | LG learns that an update check happened (model, firmware version). |
| `ngfts.lge.com`, `gfts.lge.com`, `eic-ngfts.lge.com`, `eic-gfts.lge.com`, `eic-gfts.nextlgsdp.com`, `aic-ngfts.tv.wiselg.com`, `kic-ngfts.tv.wiselg.com`, `eic-ngfts.tv.wiselg.com` | Firmware file transfer (NGFTS/FTS, per cluster) | Update downloads must work. | LG serves the firmware files; no telemetry expected from the transfer itself. |
| `tv.wiselg.com` | wiselg-family host that likely carries NGFTS (KallistoX wire capture) | Firmware-adjacent function inside a deny-default zone → allow row (allow beats zone regex). | If it turns out to be telemetry, remove via `manufacturer-review.sh lg` (it will then fall back to the zone deny). |
| `api.lgappstv.com`, `lgappstv.com` | Content Store CDN + API | App install/update must work. | LG sees which app pages/installs occur. |
| LG account / auth hosts (lgauth.lge.com et al., where resolved) | Account, sign-in, some home services | Required for account features. | Standard account telemetry (what every TV does when signed in). |
| non-zone LG families left untouched: `lge.com` (broad), `nextlgsdp.com` (except rdx2./ibs./ibsstat.), `lgappstv.com`, `lgeapi.com`, `lggalleryplus.com`, `ueiwsp.com` (not proven LG-owned) | time sync, store backbone, regional API, Gallery+ | Documented breakage risk (time/store) or insufficient ownership evidence. | **Residual exposure:** unclassified hosts in `nextlgsdp.com` (e.g. `<cc>.` backbone hosts) and `lgeapi.com` remain reachable. This is deliberate (keep-wins / no collateral), and is the main documented limitation of the LG policy. |

## Third-party essentials allowed (keep-list, shared-infrastructure protection)

YouTube/Google video (www.youtube.com, i.ytimg.com, yt3.ggpht.com,
yt3.googleusercontent.com, lh3.googleusercontent.com, www.gstatic.com,
tools.google.com, clients1.google.com), Apple (mediaservices.cdn-apple.com),
Amazon/Prime (api.amazonvideo.com, api.amazon.co.uk, unagi-eu.amazon.com,
global.telemetry.insights.video.a2z.com), mobile-data.onetrust.io.

These exist so shared CDN IPs are never firewall-denied (keep wins at IP
level); they are exact names, never zones.

## Normal internet

Everything else (Google, Netflix, Amazon, Akamai, CloudFront, CDNs, QUIC/443)
is untouched — this is MANUFACTURER deny-by-default, not internet
allow-listing.
