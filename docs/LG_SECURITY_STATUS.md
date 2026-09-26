# Privacy / security status — LG webOS (manufacturer-lockdown, per-profile)

Status reflects the BUILT policy (mock-tested; live apply pending LG
discovery). No marketing language; each row is a control claim about what
this network layer can and cannot do.

| Mechanism / vector | Status | Basis |
|---|---|---|
| ACR / Alphonso (known endpoints) | **CONTROLLED** | exact denies + `*.alphonso.tv` suffix + resolved-IP deny; SafeNetIoT IMC 2024 + furkan-bayrak + RDAP provenance |
| ACR (rotated/future endpoints) | **CONTROLLED** | suffix deny covers eu-acrX/tkacrX rotation — the documented failure mode of exact-name lists |
| Cloud voice (standalone hosts) | **CONTROLLED** | lgsmartweb.com, netflixvoice + qt2-kic.lab (lgtvcommon) denied in no-voice+ profiles |
| Cloud voice (sdp_nlp via nextlgsdp.com) | **NOT CONTROLLED (documented limitation)** | multiplexed with time sync + store comms in the same zone; blocking the zone = clock stuck at 2021 → all TLS fails (furkan issue #6, HaGeZi #11438). To be verified empirically after apply; if the LG routes voice through it, destination filtering cannot separate it. |
| LG telemetry (reviewed high-confidence) | **CONTROLLED** | exact denies, re-resolved per apply |
| LG telemetry (unclassified in lgtvcommon/lgsmartplatform/lgtviot/lgthinq/wiselg) | **CONTROLLED + LOGGED** | deny-default zones + `show-unknown-samsung.sh lg` review workflow |
| LG advertising | **CONTROLLED** | lgsmartad suffix + exact ad hosts |
| ThinQ / IoT cloud | **CONTROLLED (intentional kill)** | lgtviot.com + lgthinq.com deny-default; ThinQ cloud sync/remote stops; ordinary TV use unaffected |
| Unknown LG egress (future host in a listed zone) | **CONTROLLED + LOGGED** | the core mlock guarantee |
| Unknown LG egress (future LG domain NOT in any listed zone) | **NOT CONTROLLED** | cannot deny a domain that doesn't exist yet; mitigated by periodic research + `show-unknown-samsung.sh lg`. `ueiwsp.com` deliberately unlisted (ownership unproven). |
| Hard-coded DNS (vendor :53, 8.8.8.8, etc.) | **CONTROLLED** | TVGuard prerouting DNAT → Pi-hole, scoped to `tv_privacy_lg` only |
| DoT (TCP/UDP 853) | **CONTROLLED** | drop + log, scoped to the LG |
| DoH over 443 (dedicated frontends) | **PARTIALLY CONTROLLED** | known frontends denied in strict where IPs not shared; mlock relies on DNS hostname deny + no frontend observed from LG yet |
| DoH over 443 (shared CDN frontends) | **NOT CONTROLLED** | indistinguishable from legitimate HTTPS; blanket 443 blocking rejected (would break YouTube/Prime/Netflix) |
| Direct-IP to dedicated LG infra | **CONTROLLED** | IP-based deny set; raw-IP connections to listed IPs dropped |
| Direct-IP to shared cloud infra | **NOT CONTROLLED** | shared IPs (AWS/Akamai/etc.) cannot be dropped without collateral; hostname-level control only |
| QUIC / UDP-443 | **NOT CONTROLLED (intentional)** | no rule touches it; required for streaming |
| IPv6 | **NOT CURRENTLY APPLICABLE** | previously verified: TVGuard box uplink link-local only, no RA, no v6 default route. RE-CHECK after LG is discovered — if a v6 path appears, add equivalent controls before claiming readiness |
| Shared-CDN telemetry | **PARTIALLY CONTROLLED** | exact-name DNS deny works; keep-list IPs kept out of the firewall deny by design (keep wins) |
| Cached DNS answers | **PARTIALLY CONTROLLED** | blocked names resolve from cache until TTL expiry; `privacy-reset-tv-manufacturer-state.sh lg --flush-dns-cache` closes the gap |
| Persistent TLS connections (pre-existing) | **PARTIALLY CONTROLLED** | denies match `ct state new`; stale flows expired per-TV by the reset script (never a global flush) |
| Offline-buffered upload (content) | **NOT PROVABLE** | encrypted payloads cannot be read; tooling proves only "X bytes to destination Y after reconnect" |
| Offline-buffered upload (detection) | **CONTROLLED (detection only)** | `tv-offline-reconnect-test.sh lg [offline-min] [post-min]` (LG_IP required) |
| LAN access (LG → Plex etc.) | **NOT CONTROLLED (accepted)** | egress policy only; LAN isolation is a later phase |
| Samsung .197 / Google TV .90 / other clients | **NOT AFFECTED** | LG rules scoped to `tv_privacy_lg` (the LG IP only); Samsung keeps its own live mlock instance; verified by selftest + status |
