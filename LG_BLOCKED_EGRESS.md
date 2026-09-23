# What LG CANNOT receive (manufacturer-lockdown)

All entries enforced on the LG client only (Pi-hole group `TVGuard-Privacy-LG`
+ resolved-IP firewall set `tv_privacy_blocked_lg`), current build: 26 exact
domains + 7 deny-default zone regexes + 4 allow rows (allows beat zones).

## ACR / Alphonso — blocked (all profiles)

- `*.alphonso.tv` suffix deny — primary control (rotating eu-acrX/tkacrX names)
- eu-acr1.alphonso.tv, tkacr1.alphonso.tv (exact, redundant with suffix)
- cdpbeacon.lgtvcommon.com (decommissioned, audit record) + eic/aic/kic
  .cdpbeacon.lgtvcommon.com (current 6-minute ACR heartbeat)

## Advertising — blocked (all profiles)

- `*.lgsmartad.com` suffix deny (dedicated LG ad zone)
- lgads.tv, static.doubleclick.net, pagead2.googlesyndication.com,
  yumenetworks.com, smartclip.com, na-ssp-pix.adstk.io, cdn-media.brightline.tv

## High-confidence telemetry — blocked (all profiles)

eic.lgtviot.com, eic.api.lgtviot.com, eic.tv.wiselg.com, eic.nudge.lgtvcommon.com,
eic.wiseconfig.lgtvcommon.com, de.emp.lgsmartplatform.com, rdx2.nextlgsdp.com,
rdx2.lgtvsdp.com (exact only).

## Voice — blocked (standard-no-voice / strict / mlock)

lgsmartweb.com (NXDOMAIN today; kept so a revival stays denied),
netflixvoice.lgtvcommon.com, qt2-kic.lab.lgtvcommon.com.
Limitation: the main NLP channel is multiplexed in `nextlgsdp.com` (inseparable
from time/store) — see LG_BLOCKING_PLAN.md.

## Unknown LG egress — DENIED BY DEFAULT + logged (mlock)

Deny-default zones (unclassified host → deny + log, review via
`show-unknown-samsung.sh lg` + `manufacturer-review.sh lg`):

alphonso.tv, lgsmartad.com, lgtvcommon.com, lgsmartplatform.com, lgtviot.com,
lgthinq.com, wiselg.com.

**Intentional kills included in those zones:** the whole ThinQ/IoT cloud
(lgtviot.com, lgthinq.com) and unclassified lgtvcommon.com telemetry.
Documented residual risk: lgtvcommon.com also carries a few functional
subhosts (cpauth, qcardservice, wiseconfig per KallistoX capture); they are
denied by default and restored via `manufacturer-review.sh lg keep` only if a
TV function breaks.

Explicit mlock exact denies: ibs.nextlgsdp.com (in-app billing),
ibsstat.nextlgsdp.com (billing telemetry).

## Strict-only additions (NOT in mlock)

The 53 DNS-verified (not traffic-verified) cluster hosts (aic-*/eic-*/kic-*
across lge.com, nextlgsdp.com, wiselg.com, lgtviot.com, lgthinq.com,
lgtvcommon.com, lgeapi.com, lgappstv.com, lggalleryplus.com) and the 8 DoH
frontend domains (dns.google, one.one.one.one, dns.cloudflare.com, quad9,
adguard, nextdns) — strict profile only; mlock deliberately does not inherit
them (unknown-host handling comes from the zone model instead).

## DNS bypass / DoT — blocked (scoped to the LG IP, all profiles)

- external UDP/53 + TCP/53 → DNAT to Pi-hole (attributed to the LG)
- TCP/853 + UDP/853 → dropped + logged (`TVGUARD-DOT-LG`)

## What is NOT blocked

No blanket 443/UDP-443, no `*.lge.com`, no generic cloud/CDN/ASN wildcards,
QUIC free. See LG_ALLOWED_EGRESS.md for the complete allowed list.
