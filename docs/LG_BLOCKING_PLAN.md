# LG webOS blocking plan (manufacturer-lockdown)

Status: **engine ready, LG policy built and mock-tested; NOT applied — the LG TV
has not been discovered on the LAN yet** (no LG MAC/IP in arp-scan, neighbour
table, SSDP/mDNS or Pi-hole clients as of 2026-09-22). Apply happens the moment
the LG is on the network and its address is confirmed (see "Activation" below).

The architecture is identical to the accepted Samsung deployment:

```
LG webOS TV  (TBD IP)
     |
     | gateway + DNS (<TVGUARD_IP>)
     v
TVGuard box: Pi-hole (group TVGuard-Privacy-LG) + TVGuard nftables (tv_privacy_lg)
     |
     v
upstream router -> Internet
```

The LG policy is a **separate vendor instance** from Samsung (disjoint config,
resolved section, nftables sets, Pi-hole group, state line). Samsung
`manufacturer-lockdown` on `<SAMSUNG_TV_IP>` is active and untouched; Google TV
`<GOOGLE_TV_IP>` is outside both client scopes.

Profiles (built per vendor by `scripts/privacy-policy-build.py`):

| profile | LG content (current build) |
|---|---|
| `standard` | 21 domains / 53 IPs / 2 zone regexes (ACR + ads + high-confidence telemetry) |
| `standard-no-voice` | 24 domains / 56 IPs (standard + 3 voice entries) |
| `strict` | 72 domains / 163 IPs (superset incl. 53 DNS-verified cluster hosts) |
| `manufacturer-lockdown` | 26 domains / 56 IPs / **7 deny-default zone regexes** / 4 allow rows (RECOMMENDED) |

---

## LG MANUFACTURER-LOCKDOWN WILL BLOCK

### ACR / Alphonso (all profiles, incl. standard)

- `*.alphonso.tv` — **suffix deny (the primary control)**: LG's ACR host is a
  single host per region whose numeric suffix ROTATES (`eu-acrX.alphonso.tv`,
  `tkacrX.alphonso.tv`). Exact-name lists silently stop working at rotation;
  the suffix does not. (SafeNetIoT/ACR IMC 2024 + furkan-bayrak repo + RDAP:
  Alphonso = IONOS-registered, LG's ACR/ad vendor since Jan 2022.)
- Exact: eu-acr1.alphonso.tv, tkacr1.alphonso.tv, cdpbeacon.lgtvcommon.com
  (decommissioned, audit record), eic/aic/kic.cdpbeacon.lgtvcommon.com (the
  current 6-minute ACR heartbeat location).

### Advertising (all profiles)

- `*.lgsmartad.com` suffix deny (dedicated LG ad zone)
- Exact: lgads.tv, static.doubleclick.net, pagead2.googlesyndication.com,
  yumenetworks.com, smartclip.com, na-ssp-pix.adstk.io, cdn-media.brightline.tv

### High-confidence telemetry (all profiles)

eic.lgtviot.com, eic.api.lgtviot.com, eic.tv.wiselg.com, eic.nudge.lgtvcommon.com,
eic.wiseconfig.lgtvcommon.com, de.emp.lgsmartplatform.com, rdx2.nextlgsdp.com,
rdx2.lgtvsdp.com (exact only — see non-zones).

### Voice (standard-no-voice / strict / manufacturer-lockdown)

- lgsmartweb.com (decommissioned/NXDOMAIN; kept so the name stays denied if it revives)
- netflixvoice.lgtvcommon.com (Netflix voice remote channel)
- qt2-kic.lab.lgtvcommon.com (ThinQ AI lab channel)

**Documented limitation (honest):** the main webOS voice NLP channel
(`sdp_nlp`) is multiplexed inside the `nextlgsdp.com` SDX zone, which also
carries the TV's time sync, store comms and DRM. That zone is network-layer
INSEPARABLE from essential function (blocking it = clock stuck at 2021 → all
TLS fails — documented breakage in furkan-bayrak issue #6 and HaGeZi #11438).
So standalone voice hosts are blocked, but if this LG routes cloud speech
through the SDP backbone, destination-level filtering cannot separate voice
from time/store. To be verified empirically against the real TV after apply.

### Unknown LG egress — DENY-BY-DEFAULT + logged (manufacturer-lockdown only)

Seven deny-default zones (every unclassified host in them is denied + logged):

| zone | purpose | note |
|---|---|---|
| `alphonso.tv` | ACR / Alphonso | rotating names; suffix required |
| `lgsmartad.com` | ads | dedicated ad zone |
| `lgtvcommon.com` | mixed telemetry/CDP/ACR/voice-proxy | **residual risk**: carries a few functional subhosts (cpauth, qcardservice, wiseconfig — KallistoX wire capture); if a TV function breaks, `manufacturer-review.sh lg keep <host>` |
| `lgsmartplatform.com` | smart-platform telemetry | de.emp + regional siblings |
| `lgtviot.com` | ThinQ/IoT telemetry | intentional ThinQ cloud kill |
| `lgthinq.com` | ThinQ cloud sync | intentional ThinQ app/voice cloud kill |
| `wiselg.com` | telemetry + update transfer | firmware-transfer keeps are allow-row protected |

Explicit mlock-only exact denies: `ibs.nextlgsdp.com` (in-app billing infra),
`ibsstat.nextlgsdp.com` (billing telemetry).

### DNS bypass / DoT (all profiles, scoped to the LG IP)

- external UDP/53 + TCP/53 → transparently DNAT'd to Pi-hole (attributed to the LG)
- TCP/853 + UDP/853 (DoT) → dropped + logged (`TVGUARD-DOT-LG`)
- DoH frontend IPs → deny set in strict only (shared-IP collisions kept out)

---

## LG MANUFACTURER-LOCKDOWN WILL NOT BLOCK (documented non-zones)

| family | why it stays allowed |
|---|---|
| `lge.com` | OTA (su/snu/su-ssl/nsu), firmware file transfer (ngfts/gfts + eic/aic/kic-ngfts), wide corporate zone |
| `lgtvsdp.com` | SDP **time** channel (systemTimeSource=sdp); family block = clock stuck at 2021; only `rdx2.` denied |
| `nextlgsdp.com` | SDP backbone: `<cc>.` hosts = time sync + store comms (DE.nextlgsdp.com, 11 TLS, KallistoX); voice NLP multiplexed here (inseparable); only rdx2. + ibs/ibsstat denied |
| `lgappstv.com` | Content Store CDN — install/update must work |
| `lgeapi.com` | regional API, store/billing interplay unproven (weak evidence only) |
| `lggalleryplus.com` | Gallery+/SDX — single rooted-device source (L1Techs #255178) |
| `ueiwsp.com` | **not proven LG-owned** (apex A = 1.1.1.1 placeholder; no RDAP match) — left unclassified |

Keep-list (34 entries, `config/lgtv/privacy-keep.yaml`, keep-wins at IP level):
time sync (gb.lgtvsdp.com, gb.nextlgsdp.com), firmware (su/snu/ngfts/gfts +
cluster twins on lge.com and wiselg.com), Content Store (lgappstv.com), LG
account/auth (lgauth.lge.com etc.), 4 wiselg allow rows inside the deny zone
(tv.wiselg.com + eic/aic/kic-ngfts.tv.wiselg.com — allow beats zone regex).

No `*.lge.com`, no `*.amazonaws.com`, no `*.cloudfront.net`, no generic cloud
or CDN wildcards, no blanket 443 or UDP/443 rule (QUIC stays free).

---

## LG MANUFACTURER-LOCKDOWN WILL LEAVE WORKING

YouTube, Plex, Netflix, Prime Video, casting (Chromecast/AirPlay where
supported), LG Content Store, app install/update, LG account, firmware/
security updates, TV Plus/EPG (if used), time sync, ordinary HTTPS + QUIC.

## LG MANUFACTURER-LOCKDOWN WILL INTENTIONALLY BREAK

- Alphonso ACR / viewing recognition (all profiles)
- LG advertising + ad beacons
- high-confidence telemetry (all profiles)
- standalone cloud-voice hosts (no-voice and above)
- **ThinQ / IoT cloud** (lgtviot.com + lgthinq.com zones — mlock): the ThinQ
  app's cloud sync/remote functions stop working. Ordinary TV use is not
  affected. This is deliberate.
- in-app billing endpoints (ibs.nextlgsdp.com) — if Content Store
  purchases/activation break, review and un-pin via manufacturer-review.sh

---

## Activation (when the LG is discovered)

1. `arp-scan` / neighbour table / SSDP / Pi-hole clients → confirm LG MAC + IP
   (vendor check: OUI must be LG, not another household device).
2. Add the IP to `LG_TVS=` (and `TVS=`) in the ignored `.env` — the policy
   build resolves the target from the machine config (policy YAMLs carry no
   `applies_to`).
3. Rebuild + render TVGuard (atomic `nft -c` → replace; per-vendor LG sets
   only — Samsung sets untouched).
4. Capture a local baseline (DNS history, flows, persistent connections,
   startup + idle behaviour, region prefix eu-).
5. Refine keeps/denies from local evidence if anything unexpected appears.
6. `sudo scripts/privacy-policy-selftest.sh lg` (mock, throwaway state).
7. `sudo scripts/privacy-policy-apply.sh lg manufacturer-lockdown`
8. Verify Samsung still live + unchanged (status, sets, Pi-hole group, NAT).
9. `sudo scripts/privacy-watch.sh` and hand the user
   `LG_MANUAL_TEST_CHECKLIST.md` (physical TV actions only).

Rollback: `sudo scripts/privacy-policy-disable.sh lg` (LG only, Samsung stays
live) or `sudo scripts/privacy-policy-disable.sh` (both).
