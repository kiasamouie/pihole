# What Samsung CANNOT receive (manufacturer-lockdown, live 2026-09-22)

All entries below are enforced on client `<SAMSUNG_TV_IP>` only, at two layers
where applicable (Pi-hole DNS in group TVGuard-Privacy + resolved-IP firewall
set `tv_privacy_blocked`, 166 IPs as of 2026-09-22).

## ACR / viewing-history (Tier A) — blocked

Exact domains: log-ingestion.samsungacr.com, log-ingestion-eu.samsungacr.com,
log-config.samsungacr.com, log-1/2/3.samsungacr.com, acr0.samsungcloudsolution.com,
regional acr-*-prd.samsungcloud.tv hosts.
**Plus the whole `*.samsungacr.com` zone** (any new ACR host is denied).

## Advertising (Tier B) — blocked

googleads.g.doubleclick.net, static.doubleclick.net, catalyst.adgrx.com,
rtb.adgrx.com, tvx.adgrx.com, rtb-config.samsungads.com, tvp-ads-log.samsungads.com,
ad.samsungadhub.com, rd.samsungadhub.com, samsungtv-d.openx.net
— **plus the whole `*.samsungads.com` zone** (new ad hosts denied).

## High-confidence telemetry (Tier C) — blocked

qoe.samsungcloud.tv, nrdp.logs.netflix.com, eligibility-panelresearch.googlevideo.com
(6 shared CDN IPs kept out of the firewall set — DNS deny only, keep wins)
+ remaining reviewed standard-tier telemetry entries.

## Voice / Bixby cloud — blocked (intentional breakage)

- `*.aibixby.com` — scoped zone regex (100% Bixby infrastructure per CT
  analysis; confirmed live voice path `prdcore1-euw1-user.aibixby.com`,
  regression R-001)
- `*.bixbyllm.com` — Bixby LLM / Samsung Intelligence zone
- `*.sbixby.com` — Bixby voice/AI plane zone
- prd-euw1-ucs.aibixby.com, provisioning-use2.mgmt.aibixby.com (explicit entries, redundant with the zone)

## Unknown Samsung egress — DENIED BY DEFAULT + logged

Every host in the 13 deny-default zones that is not on the documented
allow-list (SAMSUNG_ALLOWED_EGRESS.md) is denied at DNS and recorded in
`data/manufacturer-unknown/`. Review workflow:

```
sudo scripts/show-unknown-samsung.sh 24     # what new hosts appeared
sudo scripts/manufacturer-review.sh list    # review queue
sudo scripts/manufacturer-review.sh keep <domain> "reason"   # approve
sudo scripts/manufacturer-review.sh block <domain> "reason"  # pin a deny
```

## DNS bypass / DoT — blocked (scoped to <SAMSUNG_TV_IP>)

- external UDP/53 + TCP/53 (hard-coded resolvers) → transparently DNAT'd to
  Pi-hole (attributed to the TV)
- TCP/853 + UDP/853 (DoT) → dropped + logged (`TVGUARD-DOT`)
- resolved DoH frontend IPs → in the 166-IP deny set where not shared with
  keep-list infrastructure

## What is NOT blocked (deliberately)

- No blanket 443/UDP-443 rule (HTTPS + QUIC stay free)
- No generic `*.amazonaws.com` / `*.cloudfront.net` / `*.google.com` / cloud-ASN rules
- `*.samsungqbe.com` (app infrastructure, documented breakage)
- the 19 documented keep hosts + the qbe family
- strict-profile low-confidence telemetry (nmetrics/smetrics/fkp/oempprd/…) —
  those remain `strict`-only and are NOT part of manufacturer-lockdown
- the DoH-IP enforcement set — strict-only; mlock covers known DoH frontends
  via the resolved deny set but makes no blanket DoH claim
