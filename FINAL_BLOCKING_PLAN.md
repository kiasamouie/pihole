# FINAL BLOCKING PLAN — Samsung QE65Q75CATXXU (192.168.0.197)

**State: READY, NOT ACTIVE.** No privacy blocking is currently enabled.
Everything below is researched, generated, syntax-tested (netns + throwaway
table), Pi-hole-API-tested (temporary group, fully cleaned), and rollback-tested.

Activation is ONE explicit action by you:

```
sudo scripts/privacy-policy-apply.sh standard    # ACR + ads + high-conf telemetry + DoT
sudo scripts/privacy-policy-apply.sh strict      # + voice/Bixby + low-conf telemetry + DoH-IP
sudo scripts/privacy-policy-disable.sh           # full privacy rollback (one command)
sudo scripts/privacy-live-check.sh               # post-enable verification
sudo scripts/privacy-watch.sh 30 --auto-rollback # 30-min safety watch
```

## 0. How enforcement works (two layers, same source of truth)

Source of truth: `config/privacy-policy.yaml` (deny) + `config/privacy-keep.yaml`
(overrides). `scripts/privacy-policy-build.py` resolves domains via **8.8.8.8**
(never the local Pi-hole) → `data/privacy-policy/resolved.json` (git-ignored,
ephemeral IPs, re-resolved on every apply).

| Layer | What it does | Scope |
|-------|--------------|-------|
| nftables `table ip tvguard` | adds `tv_privacy_blocked` (strict: + `tv_doh_blocked`) IP sets + DROP rules in the forward chain for `ip saddr @tvs ... ct state new` | only the TVs in `applies_to` (currently .197 only) |
| Pi-hole group `TVGuard-Privacy` | exact-domain denies pushed to a dedicated group; only the `applies_to` clients are attached | only attached clients |
| keep-list | any deny IP that collides with a keep-list IP is removed from the firewall set; the keep list is never pushed to the deny group | global safety net |

Current resolution (2026-09-21, via 8.8.8.8): **standard 35 domains → 123 IPs;
strict 51 domains → 171 IPs; DoH 8 domains → 15 IPs. 0 unresolved.**

Two important resolution notes:

1. `eligibility-panelresearch.googlevideo.com` resolves to Google CDN IPs
   (142.250.129.x) that are shared with keep-list YouTube/CDN infrastructure.
   Its 6 IPs were therefore **kept out of the firewall set** (keep wins); the
   **Pi-hole exact-domain deny remains active** for the Samsung client. This is
   the intended behaviour: no IP-level collateral damage, DNS-level control kept.
2. `log-ingestion-eu.samsungacr.com` already resolves to `0.0.0.0` via Pi-hole's
   **default gravity baseline** without any of our rules. The TVGuard layer is a
   second, firewall-level guarantee (it still works even if the Pi-hole group is
   deleted, and it catches direct-IP connections the DNS layer cannot).

## 1. STANDARD WILL BLOCK (35 exact domains, 123 IPs)

### ACR — Automatic Content Recognition (17)
Highest priority. IMC 2024 (SafeNetIoT/ACR) proves this is viewing-recognition
sent from the TV; opt-out stops the traffic; no impact on playback.

| Domain | Local observed | External evidence |
|--------|:---:|---|
| acr0.samsungcloudsolution.com | no | IMC paper, HaGeZi, blocklistproject, marq24, fightback (5 sources) |
| acr-eu-prd.samsungcloud.tv | no | IMC paper, HaGeZi — our region (EU/UK) |
| acr-us-prd.samsungcloud.tv | no | IMC paper, HaGeZi |
| acr-kr / -au / -br / -ca / -in / -mx / -nz / -us-prd.samsungcloud.tv (8) | no | IMC paper, HaGeZi |
| log-config.samsungacr.com | **yes** | blocklistproject |
| log-ingestion.samsungacr.com | no | (samsungacr.com family, all lists) |
| log-ingestion-eu.samsungacr.com | **yes** | perflyst (+ already gravity-blocked) |
| log-1 / log-2 / log-3.samsungacr.com | no | samsungacr.com family |
| targeted-config-test.samsungacr.com | no | samsungacr.com family |

### Advertising (10)
| Domain | Local observed | External evidence |
|--------|:---:|---|
| catalyst.adgrx.com | **yes** | AdGRX programmatic exchange |
| rtb.adgrx.com | **yes** | AdGRX |
| tvx.adgrx.com | **yes** | AdGRX |
| rtb-config.samsungads.com | **yes** | fightback, marq24 |
| tvp-ads-log.samsungads.com | **yes** | fightback, marq24 |
| ad.samsungadhub.com | no | perflyst, marq24 |
| rd.samsungadhub.com | no | perflyst, marq24 |
| googleads.g.doubleclick.net | **yes** | CCS 2019 (Moghaddam), all lists |
| static.doubleclick.net | **yes** | all lists |
| samsungtv-d.openx.net | no | HaGeZi, fightback |

### Non-essential analytics/telemetry (8)
| Domain | Local observed | External evidence |
|--------|:---:|---|
| qoe.samsungcloud.tv | **yes** | QoE diagnostics; observed heavy flow |
| nrdp.logs.netflix.com | **yes** | Netflix telemetry host (playback uses other paths) |
| eligibility-panelresearch.googlevideo.com | **yes** | Google research-panel eligibility (IPs kept out - shared CDN; DNS deny active) |
| devicelog.samsungcloudsolution.net | no | HaGeZi, fightback |
| prderrordumphsm.samsungcloudsolution.com | no | HaGeZi, perflyst (crash-detail reporting) |
| notice.samsungcloudsolution.com | no | HaGeZi (firmware *notice* fetch, not the update itself) |
| noticecdn.samsungcloudsolution.com | no | HaGeZi |
| noticefile.samsungcloudsolution.com | no | HaGeZi |

STANDARD will also, structurally:
- DROP TV → any TCP/UDP **853** (DoT) — `TVGUARD-DOT`
- keep forcing TV → any external **:53** to Pi-hole (existing TVGuard DNAT, unchanged)

## 2. STANDARD WILL NOT BLOCK (selected from privacy-keep.yaml — full file is the source of truth)

| Family | Why kept |
|--------|----------|
| YouTube/Google: youtube.com, googlevideo.com (incl. observed rr*---sn-* hosts), gstatic, ggpht/googleusercontent, clients1/tools.google, ytimg | streaming/content |
| Samsung platform: time.samsungcloudsolution.com (Perflyst: breaks Plex/YouTube/Prime), cdn.samsungcloudsolution.com, play/api.samsungcloud.com, tvpnlinupepgpeu.samsungcloud.tv (TV Plus EPG), fc.samsungcloud.tv (uncharacterised workhorse - keep until characterised) | core function |
| Samsung QBE: gpm + all 6 osb-*.samsungqbe.com hosts | Perflyst #82: broke YouTube/Prime/apps |
| Samsung OSP: auth + gld.push.samsungosp.com | account sign-in / push |
| Smart Hub + OTA: lcprd1, configprd, otnprd8/9/10/11.samsungcloudsolution.net, www.samsungotn.net, otn.samsungcloudcdn.com | Smart Hub / firmware updates |
| Casting/app-store: multiscreen.samsung.com, infolink.pavv.co.kr, ns11.whois.co.kr | casting / app store / Series-7 YouTube |
| Prime Video/Amazon: unagi-eu.amazon.com, api.amazon.co.uk, api.amazonvideo.com, global.telemetry.insights.video.a2z.com | streaming (shared infra - keep) |
| CDN: d1itljbfuaik2i.cloudfront.net, img-resize-cdn-prod.samsungnyc.com, mediaservices.cdn-apple.com, mobile-data.onetrust.io (uncharacterised) | content / uncharacterised |

**No wildcard rules exist or will be created** (no `*.samsung.com`,
`*.samsungqbe.com`, `*.cloudfront.net`, `*.amazonaws.com`, `*.google.com`).

## 3. STANDARD WILL FORCE

- TV → external DNS UDP/TCP 53 (e.g. 8.8.8.8, 1.1.1.1, vendor resolvers):
  **DNAT to Pi-hole** (transparent redirect to our resolver; attribution kept
  via the explicit container-IP DNAT). The TV keeps working; Pi-hole keeps control.
- TV → TCP/UDP 853 (DoT): **DROP + log** (`TVGUARD-DOT`).
- TV → anything: MASQUERADE out, replies return via kiaserver (proven live).

## 4. STANDARD WILL LEAVE WORKING

YouTube (incl. QUIC/UDP-443), Plex (LAN + Internet), casting (mDNS/SSDP/
multiscreen), Samsung home screen + app launching, TV Plus EPG, Samsung account
+ push, **Bixby voice (standard leaves voice functional)**, firmware/OTA
updates, Prime Video, app store, normal HTTPS (TCP 443 untouched).

No rule touches: TCP/443 (blanket), UDP/443 (QUIC stays free), LAN traffic
(Plex/casting/discovery), other devices (policy scoped to .197 only).

## 5. STRICT ADDITIONS (strict = standard + 16 domains + DoH-IP set)

| Domain | Class | Note |
|--------|-------|------|
| prd-euw1-ucs.aibixby.com | voice-related | **observed on our TV**; intentional breakage: cloud voice |
| provisioning-use2.mgmt.aibixby.com | voice-related | **observed**; provisioning/keepalive |
| nmetrics.samsung.com | telemetry (low conf) | observed in hagezi list |
| smetrics.samsung.com | telemetry (low conf) | |
| event-tracking.samsung.com | telemetry (low conf) | |
| devicelog-class: fkp.samsungcloudsolution.{com,net} | telemetry (low conf) | |
| oempprd.samsungcloudsolution.{com,net} | OEM diagnostics (low conf) | |
| prov.samsungcloudsolution.com | provisioning (low conf) | |
| sas.samsungcloudsolution.com | diagnostics (low conf) | |
| vdterms.samsungcloudsolution.com | terms-fetch (low conf) | |
| samsungdm.com | device-management (low conf) | |
| syncplusconfig.s3.amazonaws.com | app config (low conf, shared AWS S3) | |
| vd.emp.prd.s3.amazonaws.com | app data (low conf, shared AWS S3) | |
| 2mdn.net | shared Google ad CDN (low conf) | **breakage accepted and documented**: may affect some third-party ad rendering |

Strict will additionally:
- DROP TV → the 15 resolved **DoH endpoint IPs** (`tv_doh_blocked`): dns.google,
  one.one.one.one / dns.cloudflare.com, dns.quad9.net / dns9.quad9.net,
  dns.adguard.com / adguard-dns.com, dns.nextdns.io.
- **KNOWN LIMITATION**: DoH over 443 to a CDN fronting multiple services cannot
  always be distinguished from legitimate HTTPS using destination metadata alone.
  The DoH IP set is a curated list of resolver-front-end IPs; it is PARTIAL
  control by design, not a claim of complete DoH prevention.

STRICT WILL LEAVE WORKING: everything in §4 **except** cloud voice
(intentional) **plus** the low-confidence telemetry rows above (accepted
degradation: Samsung diagnostics stop; playback unaffected per sources).

## 6. DOH (strict only) — 8 domains → 15 IPs
dns.google, one.one.one.one, dns.cloudflare.com, dns.quad9.net,
dns9.quad9.net, dns.adguard.com, adguard-dns.com, dns.nextdns.io
(from HaGeZi's DoH list, restricted to the major public resolvers the TV is
realistically likely to be configured against; full 3,300+ hostname list NOT
imported - most entries would be irrelevant and some are shared infrastructure).

## 7. BLOCK / KEEP / OPTIONAL-STRICT / UNKNOWN summary

| Bucket | Count | Where |
|--------|-------|-------|
| BLOCK (standard) | 35 domains / 123 IPs | §1 |
| BLOCK (strict adds) | 16 domains + 15 DoH IPs | §5, §6 |
| KEEP (documented) | ~30 domains / ~100 protected IPs | §2 (privacy-keep.yaml) |
| OPTIONAL STRICT (voice) | 2 domains | §5 (only in strict) |
| UNKNOWN (NOT blocked) | 195 rows | hagezi-samsung-analysis.csv `unknown-review` |

Every `unknown-review` row was deliberately NOT put into the policy. "In a
blocklist" ≠ "safe to block on this TV"; they remain candidates for future
per-domain review after more observation.

## 8. Bypass-vector control status (honest assessment)

| Vector | Status | How |
|--------|--------|-----|
| Hard-coded IPv4 DNS (8.8.8.8, 1.1.1.1, vendor :53) | **CONTROLLED** | TVGuard DNAT forces it to Pi-hole; proven in selftest (dig @8.8.8.8 from mock TV → resolved via Pi-hole, client attributed as TV) |
| DoT (TCP/UDP 853) | **CONTROLLED when policy active** | explicit drop + log (`TVGUARD-DOT`); also enforced by TVGuard `enforce` mode |
| DoH (known resolver endpoints) | **PARTIALLY CONTROLLED** (strict) | curated IP set of 15; cannot distinguish DoH from HTTPS when the same IP fronts both |
| QUIC / UDP-443 | **INTENTIONALLY ALLOWED** | no rule exists touching UDP/443 (verified in rendered table) - YouTube/streaming depend on it |
| IPv6 | **NOT CURRENTLY APPLICABLE** | re-verified 2026-09-21: enp2s0 link-local only, no RA (accept_ra=0), no v6 default route, v6 forwarding off → no IPv6 Internet path exists to bypass through |
| Direct-IP connections (no DNS) | **CONTROLLED for listed IPs only** | the deny set is IP-based, so a TV connecting by raw IP to a listed deny IP is still dropped; unlisted raw-IP destinations are not (DNS can't see them either) |
| Shared CDN IPs / cached DNS | **PARTIALLY CONTROLLED** | keep-list IP collision check protects essential shared infra in the other direction; cached DNS means a blocked domain still works from cache until TTL expiry |
| Local LAN access (TV → other 192.168.0.x) | **NOT CONTROLLED (accepted)** | flat L2 PoC; this policy is about TV→Internet egress. LAN isolation requires the later VLAN/dedicated-hardware phase |

## 9. Physical TV tests to run AFTER enabling (server cannot click the TV)

From `scripts/privacy-live-check.sh` output, plus:

1. Home screen idle 2 min — apps load, TV Plus channel list works
2. YouTube: open, play, seek, close
3. Plex: open, play
4. Casting from phone (if used)
5. App store opens and lists apps
6. (standard) one voice command — should still work
   (strict) voice should NOT work (intended) — confirm everything else works

If anything breaks: `sudo scripts/privacy-policy-disable.sh`, find the failing
domain in the Pi-hole query log, add it to `config/privacy-keep.yaml` if the
keep decision is right, re-apply.

## 10. Rollback guarantees (tested)

`privacy-policy-disable.sh` removes ONLY:
- the `tv_privacy_blocked` / `tv_doh_blocked` sets + privacy/DoT drop rules
  (re-render of `table ip tvguard` — NAT, masquerade, DNS-bypass DNAT, monitor
  mode, UFW route rules all preserved and verified present after disable);
- the Pi-hole group `TVGuard-Privacy`, its domains, and client attachments
  (other groups untouched; batchDelete API).

Verified in the mock selftest (15/15 pass) and the throwaway-table dry run:
production `tvguard` table structurally unchanged, UFW unchanged (minus the
temporary mock rule), Docker unchanged, no privacy sets after disable.
**Disabling never removes the TV's Internet path.**
