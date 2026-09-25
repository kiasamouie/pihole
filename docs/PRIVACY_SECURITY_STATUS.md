# Privacy / security status — Samsung .197 under manufacturer-lockdown

Live as of 2026-09-22 10:54Z. No marketing language; each row is a control
claim about what this network layer can and cannot do.

| Mechanism / vector | Status | Basis |
|---|---|---|
| ACR (known endpoints) | **CONTROLLED** | exact denies + zone regex + resolved-IP firewall deny; SafeNetIoT provenance |
| ACR (future endpoints in samsungacr.com / acr-* hosts in samsungcloud.tv/samsungcloudsolution.com) | **CONTROLLED** | deny-by-default zones: new ACR hosts get no egress until explicitly kept |
| Bixby / cloud voice | **CONTROLLED** | `*.aibixby.com` + bixbyllm + sbixby zones; R-001 (Tokyo-weather regression) closed by the aibixby family block; voice cloud intentionally broken |
| Samsung telemetry (reviewed high-confidence) | **CONTROLLED** | exact denies, re-resolved per apply |
| Samsung telemetry (unreviewed/unknown) | **CONTROLLED + LOGGED** | zone deny-by-default + `show-unknown-samsung.sh` review workflow |
| Samsung advertising | **CONTROLLED** | exact + `*.samsungads.com` zone |
| Unknown Samsung egress (any future host in a listed zone) | **CONTROLLED + LOGGED** | the core mlock guarantee |
| Unknown Samsung egress (in a zone we do NOT list, e.g. a future samsungxyz.com) | **NOT CONTROLLED** | we cannot deny a domain we don't know exists; mitigated by periodic `show-unknown-samsung.sh` + list research. `samsungqbe.com` is deliberately unlisted (breakage). |
| Hard-coded IPv4 DNS (vendor/8.8.8.8 :53) | **CONTROLLED** | TVGuard prerouting DNAT → Pi-hole, scoped to `tv_privacy` (.197 only), selftest-proven |
| DoT (TCP/UDP 853) | **CONTROLLED** | drop + log, scoped to .197 |
| DoH over 443 (dedicated resolver frontends) | **PARTIALLY CONTROLLED** | known frontends land in the resolved deny set when their IPs are not shared with keep infra |
| DoH over 443 (shared CDN frontends) | **NOT CONTROLLED** | indistinguishable from legitimate HTTPS at the network layer; blanket 443 blocking would break YouTube/Prime/Netflix — accepted limitation |
| Direct-IP connections, dedicated Samsung infra | **CONTROLLED** | deny set is IP-based; raw-IP connections to a listed IP are dropped |
| Direct-IP connections, shared cloud infra | **NOT CONTROLLED** | shared IPs cannot be dropped without collateral damage; hostname-level control only |
| QUIC / UDP-443 | **NOT CONTROLLED (intentional)** | no rule touches it; required for streaming |
| IPv6 | **NOT CURRENTLY APPLICABLE** | re-verified 2026-09-22: enp2s0 link-local only, accept_ra=0, no global v6 route; if a v6 path ever appears, re-check BEFORE claiming readiness |
| Shared-CDN telemetry (e.g. googlevideo eligibility) | **PARTIALLY CONTROLLED** | DNS-level exact deny works; IP level kept out by design (keep wins) |
| Cached DNS answers | **PARTIALLY CONTROLLED** | a blocked name resolves from cache until TTL expiry; `privacy-reset-tv-manufacturer-state.sh --flush-dns-cache` closes the gap on re-apply |
| Persistent TLS connections (pre-existing) | **PARTIALLY CONTROLLED** | deny rules match `ct state new`; stale flows to newly-denied IPs are expired per-TV by the reset script (never a global flush) |
| Offline-buffered upload (content) | **NOT PROVABLE** | network layer cannot read encrypted payloads; the tooling can only prove "X bytes to destination Y immediately after reconnect" |
| Offline-buffered upload (detection) | **CONTROLLED (detection only)** | `tv-offline-reconnect-test.sh` measures deferred DNS/connection/upload bursts to Samsung/Bixby/telemetry destinations, fail-safe restore |
| LAN access (TV → other 192.168.0.x, e.g. Plex) | **NOT CONTROLLED (accepted)** | egress policy only; LAN isolation is a later phase |
| Other household clients (incl. Google TV .197/.90) | **NOT AFFECTED** | privacy rules scoped to `tv_privacy` = applies_to = {192.168.0.197}; verified 2026-09-22 (tv_privacy set + rule audit + UFW hash unchanged) |
