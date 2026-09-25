# What Samsung CAN still receive (manufacturer-lockdown, live 2026-09-22)

Everything on this list is a **deliberate, documented** allow decision. There
are no invisible allows: any Samsung host NOT listed here inside a
deny-by-default zone is **denied and logged** until reviewed.

Samsung-owned, intentionally allowed (group-scoped Pi-hole allow rows, keep
wins):

| Domain/family | Purpose | Why allowed | Privacy implication |
|---|---|---|---|
| time.samsungcloudsolution.com | Time synchronisation | Blocking breaks playback apps (Perflyst/fightback) | minimal (time queries) |
| cdn.samsungcloudsolution.com | Content delivery / system update checks | observed + Perflyst | moderate (usage metadata to Samsung) |
| lcprd1.samsungcloudsolution.net | Platform core service | persistent 100k+ packet flow from this TV; Smart Hub | moderate — core platform channel, cannot currently be characterised finer |
| configprd.samsungcloudsolution.net | Platform config | documented do-not-block family | low–moderate |
| otnprd8/9/10/11.samsungcloudsolution.net | OTA firmware updates | Perflyst: required for software update | update-check metadata |
| www.samsungotn.net | OTA firmware updates | Perflyst (QE65Q75 class) | update-check metadata |
| otn.samsungcloudcdn.com | OTA update CDN | Perflyst issue #60 (firmware updates break if blocked) | update-download traffic |
| play.samsungcloud.com | Samsung app platform (Smart Hub/apps) | observed local capture | app usage metadata |
| api.samsungcloud.com | Samsung cloud API | observed local capture | app usage metadata |
| auth.samsungosp.com | Samsung account authentication | Perflyst + observed sign-in | account activity |
| eu-auth2.samsungosp.com | Samsung account authentication (EU) | observed during account activity | account activity |
| gld.push.samsungosp.com | Samsung push notifications | observed + Perflyst | push channel (device token) |
| tvpnlinupepgpeu.samsungcloud.tv | Samsung TV Plus EPG (EU) | heaviest observed Samsung domain; TV Plus is a used feature | channel/EPG metadata; content via CloudFront |
| fc.samsungcloud.tv | **UNKNOWN purpose** — heaviest Samsung domain observed | never block an uncharacterised workhorse; CloudFront-backed | unknown — flagged for future characterisation (see below) |
| multiscreen.samsung.com | Multi Screen (casting / remote) | fightback whitelist: casting breaks | low (discovery/signalling) |
| img-resize-cdn-prod.samsungnyc.com | Samsung NY image CDN | observed; UI/EPG imagery | minimal |

Whole family intentionally allowed (NOT in a deny-by-default zone):

| Family | Why |
|---|---|
| *.samsungqbe.com | Dynamic `osb-*`/`gpm.*` app infrastructure; Perflyst issue #82: blocking it breaks YouTube, Prime Video and TV Plus on Samsung TVs. Reviewed 2026-09-21. |

Not Samsung (no deny-by-default semantics; names still blocked individually in
the advertising tier where classified):

| Family | Note |
|---|---|
| samsungadhub.com | Domain lapsed and was **drop-captured** (Namebright expired NS → DropCatch registrar; RDAP 2026-09-21). `ad.*`/`rd.*` names remain exact denies; the zone itself is not Samsung-owned today, so it is not a deny-default zone. |

Non-Samsung egress (untouched by this policy by design — no generic
cloud-provider or CDN wildcards): YouTube/Google video + CDN, Netflix,
Prime/Amazon (incl. CloudFront/AWS), Plex, Apple casting, app CDNs, QUIC/UDP-443,
ordinary HTTPS.

**Follow-up (not urgent):** characterise `fc.samsungcloud.tv` (candidate for
`scripts/voice-path-discovery.sh`-style correlation if its traffic pattern is
ever suspect). Until then it stays allowed on the "never block an
uncharacterised workhorse" rule.
