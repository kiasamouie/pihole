# Level1Techs — "LG TV Block Mini-How-to" Endpoint Inventory

Thread: https://forum.level1techs.com/t/lg-tv-block-mini-how-to/255178
Created 2026-09-05 23:39 UTC (2 days before the Gamers Nexus video "216,000,000 Spy TVs | The LG Smart TV Problem", https://www.youtube.com/watch?v=6IFVTcM28KA, ~2026-09-07). 51 posts, 32.6k views, last activity 2026-09-16. Post #1 by **wendell** (L1Techs staff): "HOWTO: Locking LG out of a rooted webOS TV".

## ⚠ Source ranking: C — evidence candidates, NOT universal truth

- **Single target unit, rooted.** Everything in post #1 was read off **one rooted TV: OLED65G5WUA (LG G5 65"), "webOS 10.2.1 (starfish)" (build ponytail-paparoa), kernel `5.4.268-329.ptl4tv.2`, LG1214 SoC**, with Homebrew Channel, root SSH/telnet, dev mode. Author's own words: "only been tested on the one target". Recon date 2026-08-24, read-only.
- **Layers 2–5 of the how-to require root** (Homebrew Channel init scripts, `/etc/hosts` bind-mount, consent files via `luna-send`). **Only Layer 1 (router-level DNS + firewall) and the DNS blocklist itself apply to unrooted TVs.**
- **Version-name inconsistency (not papered over):** the target section says "webOS 10.2.1" but the consent section says "this was against webOS 25", and the thread notes webOS 26 exists for 2026 models. Treat the exact webOS version of the target as *as-reported-in-post*; the *mechanisms* (process names, conf files, consent keys) are plausibly stable across webOS but each must be re-verified per firmware.
- Second independent data point in-thread: **mrcleantowels, OLED65C2PUA (C2, webOS 22-era), post #28** — same hostnames, but the consent/hosts steps behaved differently (see "Thread evidence"). KallistoX's wire capture (webOS 6.0 unit, see `hagezi-lg.md` §6) is the third: it shows a **webOS 6 device never queried the old `lgtvsdp.com`/`lgsmartad.com`/`lgappstv.com`/`alphonso.tv` families at all** — its traffic is in the `nextlgsdp.com` zone with **uppercase** region prefixes (`DE.`, `EIC.`).

## Channel → process → endpoint (from post #1)

| Channel | Process / binary | Endpoint | Port | Model/firmware applicability |
|---|---|---|---|---|
| OS updates | `/usr/sbin/update` | `snu.lge.com`, `su.lge.com`, `su-ssl.lge.com`, `nsu.lge.com` + **hardcoded IP `156.147.69.32:8080`** (`/CheckSWAutoUpdate.laf`, used as fallback **when DNS fails** — i.e. blocking the domains actively routes updates to a raw IP) | 443 / 8080 | Universal purpose; the hardcoded IP was read off this one rooted unit — verify per firmware. Blocking OTA = security trade-off (unpatched webOS RCEs), not just privacy. |
| Telemetry (SDX) | `/usr/sbin/sdx` | `nextlgsdp.com` (apex on this unit; cc-prefixed on webOS 6), `*.lgtvcommon.com`; observed live `54.186.247.229:443` (AWS) | 443 | Zone is universal (webOS 5/6 confirmed by KallistoX); the exact apex-vs-cc-prefixed split is firmware-specific. |
| ACR | `/usr/sbin/acr2` | `alphonso.tv` (+ `*-ad-lgsmartad-com.aws-prd.net` per KallistoX/#11412) | 443 | Config present on this unit (`acr.xml` `ACR_On=true`, Alphonso, `dsnoop:0,12`, token `LG-webOS25-X-…`) but **observed inert / consent-gated** — consent declined ⇒ no traffic. Behavior likely similar but unverified on other units. |
| Ads | `/usr/sbin/admanager` (`com.webos.service.admanager`) | `info.lgsmartad.com` (~60 s poll) | 443 | `lgsmartad.com` zone is universal; the specific subdomain cadence is from this unit. |
| ThinQ / IoT | `iot-client`, `pushclient` | `*.lgtviot.com`, `*.lgthinq.com`, per-device AWS IoT MQTT broker `*.iot.<region>.amazonaws.com` with **per-device cert** at `/mnt/lg/cmn_data/.pushclient/push.cert.pem` | 443 / 8883 (MQTT) | MQTT channel is device-specific (per-TV cert + broker) — **not blockable by hostname at the router** without breaking per-device pairing; DNS-level `*.lgtviot.com`/`*.lgthinq.com` is the practical lever. |
| LLM / AI | `com.webos.app.aiplatform` | `ngfts.lge.com` family (gfts) | 443 | **Model/firmware-specific**: `profile.json` `"llm":{"support":true}` on this unit. Newer-feature; not present on older firmwares. |
| Crash / analytics | `uploadd`, `rdxd` | `rdx2.nextlgsdp.com`, `rdl.lgtvcommon.com` (`/etc/rdxd.conf` `AutoUpload=true`) | 443 | Near-universal (confirmed by HaGeZi list + KallistoX capture on a different unit/OS). |
| Consents | `eula-service` | local: `/var/luna/preferences/eula` (keys: Marketing/Privacy/Voice/ACR/IBA-ads) | — | Local file; the Luna method (`luna-send … setSystemSettings`) works but the **exact key set varies by firmware/region** (C2 post #28 needed different keys and a missing-`voiceAllowed` edge case, post #21). |

## SDX endpoint map (from `/mnt/lg/cmn_data/sdp/sdx/server_addr_version.conf`, v1.5 on the target)

- `nextlgsdp.com` (apex) → services: `sdp_auth`, `sdp_init`, `sdp_common`, `sdp_logging`, `sdp_home`, **`sdp_nlp` (voice NLP — the voice channel runs through SDX, not only through the mic stack)**, `sdp_onnow`, `sdp_search`, `sdp_apps`, `sdp_apps_resource`, `sdp_airplay`, `sdp_nais`.
- `ibs.nextlgsdp.com` → `ibis_secure`; `ibsstat.nextlgsdp.com` → `ibis_stat_secure` (billing per hagezi's later read); `rdx2.nextlgsdp.com` → `rdx_secure`.
- `*.lgtvcommon.com` roles: `netflixvoice` (voice proxy), `nudge`, `homeprv`, `wiseconfig`, `pnv`, `recommend`, `cdpsvc`, `cpauth`, `cdpbeacon`, `rdl` (crash-log dir), `wiseresource`, `qcardservice`, `qt2-kic.lab.lgtvcommon.com` (ThinQ AI lab).
- Other SDX-adjacent: `lgshopsvc.lgappstv.com` (store), `lggalleryplus.com`, `tv.wiselg.com`.

**Model/firmware-specific vs universal:** the *conf-file path and service-name table* are specific to this webOS-10.2.1-era image. The *zones* (`nextlgsdp.com`, `lgtvcommon.com`, `lgsmartad.com`, `lgtviot.com`, `lgthinq.com`) are universal to LG webOS; the *which-host-within-the-zone is live* is firmware-specific (webOS 6 → cc-prefixed `nextlgsdp` hosts; older → apex + `lgtvsdp.com` + `alphonso.tv`).

## How-to blocklist (author's) and wildcard guidance

- Block (observed live 2026-08-24 unless marked community):
  - OTA: `snu / su / su-ssl / nsu / snu-dev / su-dev .lge.com` + `156.147.69.32` (firewall).
  - Ads: `lgsmartad.com`, `info.lgsmartad.com`.
  - ThinQ: `api / commonpush / sports / ocp / push / buddy .lgtviot.com`, `common / connect-client .lgthinq.com`.
  - AI: `ngfts / qt2-ngfts / kic-ngfts / kic-qt2-ngfts .lge.com`.
  - Crash: `rdx2.nextlgsdp.com`, `rdl.lgtvcommon.com`.
  - Voice: `nextlgsdp.com` (sdp_nlp) + `lgsmartweb.com` (**voice *search* only** — the voice input stack `voiceinput*` / `trigger_thinq` / `trigger_alexa` and the "hiLG" wake word run **locally** on the SoC; blocking these domains does not disable the microphone, only the cloud round-trip).
  - **Content Store (trade-off, commented OUT by default in the author's list): `lgtvsdp.com`, `lgappstv.com`, `lgshopsvc.lgappstv.com`** — blocking = no app store/updates from store; author leaves it to the user.
- Wildcards the author calls safe: `*.nextlgsdp.com`, `*.lgtvcommon.com`, `*.lgsmartad.com`, `*.lgtviot.com`, `*.lgthinq.com` (store ones with trade-off). **Never block `.lge.com` wholesale** (firmware/OTA lives there).
- ⚠ Cross-check: the author's "safe" `*.nextlgsdp.com` wildcard is the exact thing that broke time/store for #11438 reporters (Sep 11) — KallistoX and the HaGeZi fix (52 cc-subdomains + gfts carve-outs) contradict it. The wildcard is only "safe" on the author's own (rooted, no-Store-usage) target.

## Platform facts (rooted-unit specifics — do not generalize without re-verification)

- `/etc/hosts` is a read-only overlay; blocking there requires a bind-mount (the `10-block-lg-telemetry` init script). **Two independent users hit a mount-check bug** (#13 awsneed, LG G5 55"; #21/#28) — the script can falsely report success; verify with `findmnt` + reboot.
- No netfilter kernel modules loaded ⇒ **iptables on the TV is dead**; persistence is via `/var/lib/webosbrew/init.d/*`. Only **router-layer blocking survives a factory reset**.
- TV resolver = local connman proxy `127.0.0.1:53` → DHCP upstream; **some firmwares hardcode `8.8.8.8`** (author's note) — verify yours (KallistoX observed no hardcoded resolvers on webOS 6 DE).
- Push channel: per-device AWS IoT MQTT cert + regional broker — device-specific, not hosts-blockable.
- Layers: 1 router DNS+firewall (works unrooted) → 2 Homebrew Channel built-in `webosbrew_block_updates` flag → 3 custom hosts bind → 4 consent decline (`decline-tos.sh`: `S_MKT`/`S_PRG`/`S_VNG`/`S_ADG`/`S_TAG` declined, `voiceAllowed=false`, ACR opt-out marker `/mnt/lg/cmn_data/acr/data/eula_disallowed_rebooted`) → 5 update-gate wipe (`updateInfo` + `updateDependencyInfo` emptied) → 6 verifier script.
- Caveats: never accept OS updates once rooted (root persistence across updates not guaranteed); eula write-shape is medium-confidence.

## Thread evidence (posts 2–36)

- **#13 awsneed (LG G5 55")**: hosts-mount check bug in `10-block-lg-telemetry` (matched Homebrew Channel's existing hosts mount) — fixed with `findmnt`.
- **#16 HamSandwich**: cites privacysmarthome.com "Samsung & LG Smart TV DoH IP & Domain Blocklist Matrix" claim that TVs **fall back to Google/Cloudflare DoH** if telemetry addresses are blocked — **single forum claim, unverified** (KallistoX's 40-min wire capture on webOS 6 observed *no* DoH/DoT/QUIC, but that is one device).
- **#20 fade (C5, C1)**: blocking `nextlgsdp.com` disables Content Store; exactly `countrycode.nextlgsdp.com` must remain reachable. (Corroborates HaGeZi #11438.)
- **#21 shade3**: verify script false-fails when `voiceAllowed`/`voiceAllowed2` are simply absent from the option file (not `false`); same hosts-mount symptom as #13.
- **#24 spectrumbranch**: the `lg-lockout` folder referenced in layer 3 was not linked in the post (documentation gap).
- **#26 nrcxzs3939**: "Undisclosed AI use, with multiple mistakes in the post/scripts resulting from it." — unverified claim, but the mount bug + verify-script gaps above are consistent with it. Treat post #1's procedural details with extra care.
- **#28 mrcleantowels (OLED65C2PUA, C2)**: post-reboot verify: hosts blocks did **not** persist (mount issue), `eula.networkAllowed` still `true`, `acrAllowed=false`/`voiceAllowed=false` stuck. Workaround that worked on his unit: `luna-send -f luna://com.webos.settingsservice/setSystemSettings '{"category":"eula","settings":{"networkAllowed":false}}'` and `{"category":"option","settings":{"usageCare":false,"dbgLogUpload":false,"watchedListCollection":"off"}}`. Confirms the same endpoint hostnames on a different (older) model, and that consent plumbing differs per firmware.
- Community lists cited in post #1 (all rank C/D, cross-reference only): TheShawnMiranda/LG-TV-Ad-Block (LG C2, NA), hugobatista/lg-tv-ad-block, AMV007/lg_tv_blocklist, kkl1974/LG-WebOS-AdGuard-blocklist, athimannil/webos-pihole-blocklists, samsapti/LG-webOS-Blocklist, webosbrew/homebrew-channel, Informatic/RootMyTV, dr0dr1dr2dr3/lgappupdateblocker.

## Model/firmware applicability summary

| Fact | Scope |
|---|---|
| Zones: `nextlgsdp.com` (SDX backbone + cc subs), `lgtvcommon.com`, `lgsmartad.com`, `alphonso.tv`, `lgtviot.com`, `lgthinq.com` | **Universal** across webOS (3 independent observations: rooted G5, rooted C2, wire-captured webOS 6 DE) |
| `cc.nextlgsdp.com` required for time/store; `*gfts*` for firmware; `*.security.lgtvsdp.com` for DRM | **Universal** (multiple users + maintainer) |
| Apex `nextlgsdp.com` usage (vs cc-prefixed), `lgtvsdp.com`/`lgappstv.com`/`alphonso.tv` still queried | **Firmware-specific**: yes on webOS ≤5 era (CX unit queries `prov-lg.alphonso.tv` daily); **absent** on the webOS 6 unit |
| `sdx` conf map (service names), hardcoded `156.147.69.32:8080`, `acr2` inert state, `aiplatform`/`ngfts` LLM, `rdxd.conf`, AWS IoT MQTT cert path | **Model/firmware-specific** (rooted G5 webOS 10.2.1 unit; C2 partially corroborates consent plumbing only) |
| Root-only layers (hosts bind, init.d persistence, eula files, update-gate wipe) | **Rooted TVs only**; router DNS + firewall works on any TV |
