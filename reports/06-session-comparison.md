# TV session comparison — 2026-09-21T08:49:43Z UTC

## Session overview

| session | tv | flows (out) | unique dst:port | unique domains | total dst bytes* |
|---|---|---|---|---|---|
| idle | samsung | 282 | 31 | 13 | 0 |
| youtube | samsung | 62 | 26 | 15 | 0 |
| plex | samsung | 0 | 0 | 0 | 0 |
| casting | samsung | 354 | 77 | 41 | 0 |
| voice | samsung | 17 | 7 | 4 | 0 |
| standby | samsung | 41 | 17 | 5 | 0 |

\* bytes only for flows that CLOSED inside the window (conntrack reports cumulative bytes on DESTROY); long-lived flows show 0. The nft counter deltas in each session's summary.md are the reliable aggregate.

## OBSERVED — outbound destinations unique to each session

Destinations seen in ONE session and in NO other session:

### only in `idle`

| dst | port | proto | flows | bytes* |
|---|---|---|---|---|
| 3.253.166.86 | 443 | tcp | 1 | 0 |
| 213.104.27.12 | 443 | udp | 2 | 0 |
| 3.253.178.152 | 443 | tcp | 1 | 0 |
| 213.104.27.12 | 443 | tcp | 2 | 0 |
| 108.133.29.101 | 443 | tcp | 1 | 0 |
| 142.251.29.119 | 443 | udp | 10 | 0 |
| 192.178.223.132 | 443 | udp | 2 | 0 |
| 142.250.117.119 | 443 | udp | 12 | 0 |
| 192.178.223.119 | 443 | udp | 9 | 0 |
| 3.253.180.183 | 443 | tcp | 1 | 0 |
| 62.253.3.82 | 443 | udp | 1 | 0 |
| 194.168.4.100 | 53 | udp | 3 | 0 |
| 142.250.140.156 | 443 | udp | 2 | 0 |
| 108.133.12.121 | 443 | tcp | 1 | 0 |
| 52.31.12.43 | 443 | tcp | 1 | 0 |
| 213.104.27.13 | 443 | udp | 3 | 0 |
| 99.80.222.216 | 443 | tcp | 1 | 0 |

### only in `youtube`

| dst | port | proto | flows | bytes* |
|---|---|---|---|---|
| 142.250.151.119 | 443 | tcp | 1 | 0 |
| 2.16.55.209 | 443 | tcp | 1 | 0 |
| 34.240.131.229 | 443 | tcp | 1 | 0 |
| 192.178.223.119 | 443 | tcp | 1 | 0 |
| 18.245.218.110 | 443 | tcp | 1 | 0 |
| 34.253.71.61 | 443 | tcp | 1 | 0 |
| 18.239.236.121 | 443 | tcp | 1 | 0 |

### only in `casting`

| dst | port | proto | flows | bytes* |
|---|---|---|---|---|
| 52.19.224.221 | 443 | tcp | 2 | 0 |
| 216.137.53.37 | 443 | tcp | 4 | 0 |
| 142.250.140.157 | 443 | tcp | 1 | 0 |
| 2.23.210.96 | 443 | tcp | 1 | 0 |
| 142.251.30.94 | 443 | tcp | 2 | 0 |
| 54.89.6.41 | 443 | tcp | 5 | 0 |
| 34.197.82.150 | 443 | tcp | 1 | 0 |
| 142.250.140.102 | 443 | tcp | 1 | 0 |
| 54.216.136.66 | 443 | tcp | 1 | 0 |
| 23.97.174.104 | 443 | tcp | 2 | 0 |
| 50.17.7.32 | 443 | tcp | 1 | 0 |
| 18.245.247.200 | 443 | tcp | 5 | 0 |
| 52.213.52.62 | 443 | tcp | 1 | 0 |
| 52.51.128.108 | 443 | tcp | 2 | 0 |
| 142.251.29.156 | 443 | udp | 3 | 0 |
| 192.168.0.128 | 32400 | tcp | 1 | 0 |
| 142.251.30.119 | 443 | tcp | 1 | 0 |
| 142.250.140.119 | 443 | tcp | 1 | 0 |
| 52.14.187.208 | 443 | tcp | 2 | 0 |
| 142.250.140.132 | 443 | tcp | 1 | 0 |
| 18.245.218.90 | 443 | tcp | 1 | 0 |
| 142.250.151.148 | 443 | tcp | 1 | 0 |
| 142.250.151.101 | 443 | tcp | 2 | 0 |
| 142.250.129.132 | 443 | tcp | 1 | 0 |
| 54.246.28.67 | 443 | tcp | 1 | 0 |
| 142.251.29.132 | 443 | tcp | 1 | 0 |
| 18.245.162.54 | 443 | tcp | 1 | 0 |
| 34.240.60.17 | 5229 | tcp | 1 | 0 |
| 142.251.30.94 | 443 | udp | 13 | 0 |
| 34.247.72.0 | 443 | tcp | 1 | 0 |
| 142.250.151.139 | 443 | udp | 1 | 0 |
| 216.137.53.19 | 443 | tcp | 3 | 0 |
| 13.226.119.210 | 443 | tcp | 1 | 0 |
| 2.21.64.170 | 443 | tcp | 1 | 0 |
| 142.250.140.102 | 443 | udp | 1 | 0 |
| 2.23.210.83 | 443 | tcp | 1 | 0 |
| 216.137.53.129 | 443 | tcp | 4 | 0 |
| 52.208.236.119 | 443 | tcp | 1 | 0 |
| 142.250.140.119 | 443 | udp | 1 | 0 |
| 18.154.84.95 | 443 | tcp | 1 | 0 |
| 142.251.30.119 | 443 | udp | 9 | 0 |
| 79.125.126.167 | 443 | tcp | 1 | 0 |
| 142.250.151.101 | 443 | udp | 4 | 0 |
| 142.250.129.132 | 443 | udp | 4 | 0 |
| 142.250.151.148 | 443 | udp | 1 | 0 |
| 142.251.157.4 | 443 | tcp | 1 | 0 |
| 142.251.29.156 | 443 | tcp | 2 | 0 |
| 216.137.53.22 | 443 | tcp | 4 | 0 |
| 172.64.155.231 | 443 | tcp | 1 | 0 |
| 18.238.250.17 | 443 | tcp | 2 | 0 |
| 63.34.205.144 | 5229 | tcp | 1 | 0 |
| 18.239.236.47 | 443 | tcp | 2 | 0 |

### only in `standby`

| dst | port | proto | flows | bytes* |
|---|---|---|---|---|
| 99.86.12.62 | 443 | tcp | 1 | 0 |
| 99.86.12.69 | 443 | tcp | 1 | 0 |
| 99.86.12.75 | 443 | tcp | 1 | 0 |
| 142.251.153.4 | 443 | tcp | 1 | 0 |
| 34.241.13.242 | 443 | tcp | 1 | 0 |
| 99.86.12.22 | 443 | tcp | 2 | 0 |
| 108.128.173.155 | 443 | tcp | 1 | 0 |

## OBSERVED — destinations common to ALL sessions

(none)

## OBSERVED — connection frequency matrix (flows per session)

| dst:port | proto | idle | youtube | plex | casting | voice | standby |
|---|---|---|---|---|---|---|---|
| 192.168.0.128:53 | udp | 31 | 21 | 0 | 87 | 6 | 15 |
| 142.251.154.4:443 | udp | 10 | 0 | 0 | 63 | 0 | 0 |
| 142.251.157.4:443 | udp | 37 | 4 | 0 | 22 | 0 | 4 |
| 142.251.156.4:443 | udp | 36 | 13 | 0 | 13 | 0 | 0 |
| 142.251.152.4:443 | udp | 46 | 0 | 0 | 11 | 0 | 0 |
| 142.251.155.4:443 | udp | 31 | 0 | 0 | 6 | 4 | 0 |
| 142.251.153.4:443 | udp | 19 | 0 | 0 | 0 | 1 | 5 |
| 142.251.151.4:443 | udp | 11 | 0 | 0 | 0 | 0 | 2 |
| 142.251.30.94:443 | udp | 0 | 0 | 0 | 13 | 0 | 0 |
| 142.250.117.119:443 | udp | 12 | 0 | 0 | 0 | 0 | 0 |
| 142.251.29.119:443 | udp | 10 | 0 | 0 | 0 | 0 | 0 |
| 142.251.30.119:443 | udp | 0 | 0 | 0 | 9 | 0 | 0 |
| 13.224.89.237:443 | tcp | 0 | 1 | 0 | 8 | 0 | 0 |
| 192.178.223.119:443 | udp | 9 | 0 | 0 | 0 | 0 | 0 |
| 34.160.212.185:443 | tcp | 2 | 1 | 0 | 3 | 1 | 0 |
| 142.251.29.132:443 | udp | 1 | 0 | 0 | 5 | 0 | 0 |
| 104.18.18.218:443 | tcp | 0 | 2 | 0 | 3 | 0 | 0 |
| 54.89.6.41:443 | tcp | 0 | 0 | 0 | 5 | 0 | 0 |
| 18.245.247.200:443 | tcp | 0 | 0 | 0 | 5 | 0 | 0 |
| 142.251.150.4:443 | udp | 0 | 0 | 0 | 0 | 2 | 2 |
| 62.253.3.77:443 | tcp | 0 | 1 | 0 | 3 | 0 | 0 |
| 216.137.53.129:443 | tcp | 0 | 0 | 0 | 4 | 0 | 0 |
| 104.18.19.218:443 | tcp | 0 | 1 | 0 | 2 | 1 | 0 |
| 142.250.151.101:443 | udp | 0 | 0 | 0 | 4 | 0 | 0 |
| 142.250.129.132:443 | udp | 0 | 0 | 0 | 4 | 0 | 0 |
| 216.137.53.37:443 | tcp | 0 | 0 | 0 | 4 | 0 | 0 |
| 62.253.3.81:443 | udp | 0 | 0 | 0 | 3 | 0 | 1 |
| 54.194.205.84:443 | tcp | 2 | 1 | 0 | 1 | 0 | 0 |
| 18.239.236.16:443 | tcp | 0 | 1 | 0 | 3 | 0 | 0 |
| 216.137.53.22:443 | tcp | 0 | 0 | 0 | 4 | 0 | 0 |
| 194.168.4.100:53 | udp | 3 | 0 | 0 | 0 | 0 | 0 |
| 52.213.140.149:443 | tcp | 0 | 0 | 0 | 0 | 2 | 1 |
| 142.251.29.156:443 | udp | 0 | 0 | 0 | 3 | 0 | 0 |
| 18.239.236.27:443 | tcp | 0 | 1 | 0 | 2 | 0 | 0 |
| 3.254.239.211:443 | tcp | 0 | 0 | 0 | 2 | 0 | 1 |
| 216.137.53.19:443 | tcp | 0 | 0 | 0 | 3 | 0 | 0 |
| 213.104.27.13:443 | udp | 3 | 0 | 0 | 0 | 0 | 0 |
| 62.253.3.81:443 | tcp | 0 | 0 | 0 | 2 | 0 | 1 |
| 63.33.218.101:443 | tcp | 1 | 1 | 0 | 1 | 0 | 0 |
| 52.19.224.221:443 | tcp | 0 | 0 | 0 | 2 | 0 | 0 |
| 142.251.30.94:443 | tcp | 0 | 0 | 0 | 2 | 0 | 0 |
| 192.178.223.132:443 | udp | 2 | 0 | 0 | 0 | 0 | 0 |
| 54.246.169.239:443 | tcp | 1 | 1 | 0 | 0 | 0 | 0 |
| 3.254.238.10:443 | tcp | 1 | 1 | 0 | 0 | 0 | 0 |
| 142.251.154.4:443 | tcp | 0 | 0 | 0 | 1 | 0 | 1 |
| 52.14.187.208:443 | tcp | 0 | 0 | 0 | 2 | 0 | 0 |
| 54.78.39.206:5229 | tcp | 0 | 1 | 0 | 1 | 0 | 0 |
| 99.86.12.22:443 | tcp | 0 | 0 | 0 | 0 | 0 | 2 |
| 142.250.140.156:443 | udp | 2 | 0 | 0 | 0 | 0 | 0 |
| 34.255.156.109:5229 | tcp | 0 | 1 | 0 | 1 | 0 | 0 |
| 18.239.236.47:443 | tcp | 0 | 0 | 0 | 2 | 0 | 0 |
| 213.104.27.12:443 | udp | 2 | 0 | 0 | 0 | 0 | 0 |
| 224.0.0.251:5353 | udp | 0 | 1 | 0 | 1 | 0 | 0 |
| 23.97.174.104:443 | tcp | 0 | 0 | 0 | 2 | 0 | 0 |
| 52.51.128.108:443 | tcp | 0 | 0 | 0 | 2 | 0 | 0 |
| 142.250.151.101:443 | tcp | 0 | 0 | 0 | 2 | 0 | 0 |
| 213.104.27.12:443 | tcp | 2 | 0 | 0 | 0 | 0 | 0 |
| 52.31.162.23:443 | tcp | 0 | 1 | 0 | 1 | 0 | 0 |
| 142.251.29.156:443 | tcp | 0 | 0 | 0 | 2 | 0 | 0 |
| 18.238.250.17:443 | tcp | 0 | 0 | 0 | 2 | 0 | 0 |
| 54.247.14.66:443 | tcp | 0 | 1 | 0 | 1 | 0 | 0 |
| 54.216.136.66:443 | tcp | 0 | 0 | 0 | 1 | 0 | 0 |
| 52.213.52.62:443 | tcp | 0 | 0 | 0 | 1 | 0 | 0 |
| 3.253.166.86:443 | tcp | 1 | 0 | 0 | 0 | 0 | 0 |
| 142.251.30.119:443 | tcp | 0 | 0 | 0 | 1 | 0 | 0 |
| 142.250.140.119:443 | tcp | 0 | 0 | 0 | 1 | 0 | 0 |
| 99.86.12.69:443 | tcp | 0 | 0 | 0 | 0 | 0 | 1 |
| 18.245.218.90:443 | tcp | 0 | 0 | 0 | 1 | 0 | 0 |
| 142.250.151.148:443 | tcp | 0 | 0 | 0 | 1 | 0 | 0 |
| 99.86.12.75:443 | tcp | 0 | 0 | 0 | 0 | 0 | 1 |
| 34.240.60.17:5229 | tcp | 0 | 0 | 0 | 1 | 0 | 0 |
| 52.31.12.43:443 | tcp | 1 | 0 | 0 | 0 | 0 | 0 |
| 18.245.162.54:443 | tcp | 0 | 0 | 0 | 1 | 0 | 0 |
| 142.250.151.119:443 | tcp | 0 | 1 | 0 | 0 | 0 | 0 |
| 34.247.72.0:443 | tcp | 0 | 0 | 0 | 1 | 0 | 0 |
| 99.86.12.62:443 | tcp | 0 | 0 | 0 | 0 | 0 | 1 |
| 13.226.119.210:443 | tcp | 0 | 0 | 0 | 1 | 0 | 0 |
| 34.253.71.61:443 | tcp | 0 | 1 | 0 | 0 | 0 | 0 |
| 2.23.210.83:443 | tcp | 0 | 0 | 0 | 1 | 0 | 0 |
| 52.208.236.119:443 | tcp | 0 | 0 | 0 | 1 | 0 | 0 |
| 18.154.84.95:443 | tcp | 0 | 0 | 0 | 1 | 0 | 0 |
| 142.251.157.4:443 | tcp | 0 | 0 | 0 | 1 | 0 | 0 |
| 172.64.155.231:443 | tcp | 0 | 0 | 0 | 1 | 0 | 0 |
| 108.133.12.121:443 | tcp | 1 | 0 | 0 | 0 | 0 | 0 |
| 63.34.205.144:5229 | tcp | 0 | 0 | 0 | 1 | 0 | 0 |
| 99.80.222.216:443 | tcp | 1 | 0 | 0 | 0 | 0 | 0 |
| 18.239.236.121:443 | tcp | 0 | 1 | 0 | 0 | 0 | 0 |
| 34.241.13.242:443 | tcp | 0 | 0 | 0 | 0 | 0 | 1 |
| 142.250.140.157:443 | tcp | 0 | 0 | 0 | 1 | 0 | 0 |
| 3.253.178.152:443 | tcp | 1 | 0 | 0 | 0 | 0 | 0 |
| 2.23.210.96:443 | tcp | 0 | 0 | 0 | 1 | 0 | 0 |
| 34.240.131.229:443 | tcp | 0 | 1 | 0 | 0 | 0 | 0 |
| 34.197.82.150:443 | tcp | 0 | 0 | 0 | 1 | 0 | 0 |
| 142.250.140.102:443 | tcp | 0 | 0 | 0 | 1 | 0 | 0 |
| 62.253.3.82:443 | udp | 1 | 0 | 0 | 0 | 0 | 0 |
| 50.17.7.32:443 | tcp | 0 | 0 | 0 | 1 | 0 | 0 |
| 192.168.0.128:32400 | tcp | 0 | 0 | 0 | 1 | 0 | 0 |
| 108.133.29.101:443 | tcp | 1 | 0 | 0 | 0 | 0 | 0 |
| 142.250.140.132:443 | tcp | 0 | 0 | 0 | 1 | 0 | 0 |
| 3.253.180.183:443 | tcp | 1 | 0 | 0 | 0 | 0 | 0 |
| 192.178.223.119:443 | tcp | 0 | 1 | 0 | 0 | 0 | 0 |
| 142.250.129.132:443 | tcp | 0 | 0 | 0 | 1 | 0 | 0 |
| 54.246.28.67:443 | tcp | 0 | 0 | 0 | 1 | 0 | 0 |
| 142.251.29.132:443 | tcp | 0 | 0 | 0 | 1 | 0 | 0 |
| 142.251.153.4:443 | tcp | 0 | 0 | 0 | 0 | 0 | 1 |
| 108.128.173.155:443 | tcp | 0 | 0 | 0 | 0 | 0 | 1 |
| 142.250.151.139:443 | udp | 0 | 0 | 0 | 1 | 0 | 0 |
| 2.21.64.170:443 | tcp | 0 | 0 | 0 | 1 | 0 | 0 |
| 142.250.140.102:443 | udp | 0 | 0 | 0 | 1 | 0 | 0 |
| 18.245.218.110:443 | tcp | 0 | 1 | 0 | 0 | 0 | 0 |
| 142.250.140.119:443 | udp | 0 | 0 | 0 | 1 | 0 | 0 |
| 79.125.126.167:443 | tcp | 0 | 0 | 0 | 1 | 0 | 0 |
| 142.250.151.148:443 | udp | 0 | 0 | 0 | 1 | 0 | 0 |
| 2.16.55.209:443 | tcp | 0 | 1 | 0 | 0 | 0 | 0 |

## OBSERVED — DNS domains unique / common

- **only in `idle`**: rr1---sn-8pgbpohxqp5-aige7.googlevideo.com (4), api.amazon.co.uk (2), rr2---sn-8pgbpohxqp5-aige7.googlevideo.com (2), rr7---sn-8pgbpohxqp5-aigk.googlevideo.com (2)
- **only in `youtube`**: catalyst.adgrx.com (2)
- **only in `casting`**: fc.samsungcloud.tv (30), gpm.samsungqbe.com (6), osb-eusvc-v2.samsungqbe.com (5), provisioning-use2.mgmt.aibixby.com (4), rtb.adgrx.com (4), time.samsungcloudsolution.com (4), mediaservices.cdn-apple.com (2), d1itljbfuaik2i.cloudfront.net (2), osb-auth-eusvc-v2.samsungqbe.com (2), tools.google.com (2), qoe.samsungcloud.tv (2), yt3.googleusercontent.com (2), static.doubleclick.net (2), play.samsungcloud.com (2), clients1.google.com (2), lh3.googleusercontent.com (2), www.gstatic.com (2), eligibility-panelresearch.googlevideo.com (2), mobile-data.onetrust.io (2), osb-tnc-v2-appsacc.samsungqbe.com (2) +5 more
- **only in `standby`**: tvpnlinupepgpeu.samsungcloud.tv (12)

- (no domains common to all sessions)

## INFERENCE (auto-generated — low confidence, NOT a classification)

- Destinations appearing only during `idle` are *consistent with* that activity, but a single pair of sessions cannot prove causation. Repeat the session pair to confirm stability before acting on it.
- Destinations appearing only during `youtube` are *consistent with* that activity, but a single pair of sessions cannot prove causation. Repeat the session pair to confirm stability before acting on it.
- Destinations appearing only during `casting` are *consistent with* that activity, but a single pair of sessions cannot prove causation. Repeat the session pair to confirm stability before acting on it.
- Destinations appearing only during `standby` are *consistent with* that activity, but a single pair of sessions cannot prove causation. Repeat the session pair to confirm stability before acting on it.
- A destination common to idle AND active sessions is *likely* background traffic, but may also be needed by any app the TV runs; confirm before blocking.

## CLASSIFICATION (only from config/destinations.yaml — the evidence ledger)

Ledger entries that match what was observed in these sessions:

| domain | class | confidence | ledger evidence | observed here |
|---|---|---|---|---|
| www.youtube.com | essential | high | Present in all 5 active sessions (idle 18, youtube 2, casting 14, voice 6, standby 12 queries); the user ran YouTube during youtube/idle windows | yes — idle, youtube, casting, voice, standby |
| i.ytimg.com | essential | high | idle 8, youtube 4, casting 4 queries - YouTube thumbnail CDN | yes — idle, youtube, casting |
| yt3.ggpht.com | essential | high | idle 6, casting 2 queries - Google profile-picture host (channel avatars) | yes — idle, casting |
| yt3.googleusercontent.com | essential | high | casting 2 queries - Google user content host (YouTube avatars/thumbs) | yes — casting |
| lh3.googleusercontent.com | essential | high | casting 2 queries - Google user content host | yes — casting |
| www.gstatic.com | essential | high | casting 2 queries - Google static assets | yes — casting |
| rr6---sn-8pgbpohxqp5-aigk.googlevideo.com | essential | high | casting 6, standby 2 queries; UDP/443 (QUIC) flows to 142.251.x.x video edges in every media window | yes — casting, standby |
| rr1---sn-8pgbpohxqp5-aige7.googlevideo.com | essential | high | idle 4 queries | yes — idle |
| rr2---sn-8pgbpohxqp5-aigk.googlevideo.com | essential | high | youtube 2, casting 2 queries | yes — youtube, casting |
| rr7---sn-8pgbpohxqp5-aigk.googlevideo.com | essential | high | idle 2 queries (FORWARDED) | yes — idle |
| rr2---sn-8pgbpohxqp5-aige7.googlevideo.com | essential | high | idle 2 queries | yes — idle |
| d1itljbfuaik2i.cloudfront.net | likely-essential | medium | casting 2 queries; 13.226.119.0/24 + 13.224.89.237 (AWS CloudFront) among top media-window flows | yes — casting |
| img-resize-cdn-prod.samsungnyc.com | likely-essential | medium | youtube 6, casting 4, voice 2 queries; resolves to 104.18.18/19.218 (Cloudflare) | yes — youtube, casting, voice |
| time.samsungcloudsolution.com | likely-essential | medium | casting 4 queries; resolves to 23.97.174.104 (Microsoft Azure) | yes — casting |
| lcprd1.samsungcloudsolution.net | likely-essential | low | idle 4, youtube 2, casting 4, voice 2 queries; resolves to 34.160.212.185 (Google Cloud); persistent ESTABLISHED flow seen overnight | yes — idle, youtube, casting, voice |
| cdn.samsungcloudsolution.com | likely-essential | low | youtube 1, casting 1 query; resolves to 62.252.115.x (UK NTLI) | yes — youtube, casting |
| play.samsungcloud.com | likely-essential | medium | casting 2 queries | yes — casting |
| api.samsungcloud.com | likely-essential | medium | casting 2 queries; resolves to 52.50.x/54.229.x/52.18.x (AWS) | yes — casting |
| gld.push.samsungosp.com | likely-essential | medium | idle 2, youtube 2, casting 4 queries; resolves to 34.247.x/52.208.x/52.210.x (AWS) | yes — youtube, casting |
| tvpnlinupepgpeu.samsungcloud.tv | likely-essential | medium | standby 12 queries (heaviest single domain in that window); resolves to 99.86.12.x (AWS CloudFront) | yes — standby |
| osb-v2.samsungqbe.com | likely-essential | low | youtube 2, casting 17 queries; 18.245.247.200 (AWS CloudFront) | yes — youtube, casting |
| osb-apps-v2.samsungqbe.com | likely-essential | low | youtube 8, casting 6 queries | yes — youtube, casting |
| osb-eusvc-v2.samsungqbe.com | likely-essential | low | casting 5 queries | yes — casting |
| osb-ussvc-v2.samsungqbe.com | likely-essential | low | casting 2 queries | yes — casting |
| osb-auth-eusvc-v2.samsungqbe.com | likely-essential | low | casting 2 queries | yes — casting |
| osb-tnc-v2-appsacc.samsungqbe.com | likely-essential | low | casting 2 queries | yes — casting |
| gpm.samsungqbe.com | likely-essential | low | casting 6 queries; 108.132.31.117/52.49.107.199/52.213.214.204 (AWS global accelerator) | yes — casting |
| unagi-eu.amazon.com | likely-essential | medium | idle 6, youtube 2, casting 2, standby 2 queries; 3.254.239.211/3.253.168.113/3.251.216.53 (AWS); matches observed 3.253/3.254 flows | yes — idle, youtube, casting, standby |
| api.amazon.co.uk | likely-essential | medium | idle 2 queries (FORWARDED); 3.253.168.177 (AWS) | yes — idle |
| tools.google.com | likely-essential | medium | casting 2 queries; 142.250.129.x (Google) | yes — casting |
| clients1.google.com | likely-essential | medium | casting 2 queries; 142.251.29.x (Google) | yes — casting |
| mediaservices.cdn-apple.com | likely-essential | medium | casting 2 queries; 62.253.3.x (UK NTLI); observed in the same window as mDNS 224.0.0.251:5353 and a local 192.168.0.128:32400 (Plex) flow - consistent with screen-mirroring/casting from an Apple device or the Apple TV app | yes — casting |
| fc.samsungcloud.tv | unknown | low | casting 30 queries (heaviest Samsung domain in that window); 216.137.53.x (AWS). Purpose not verified; candidate firmware/framework check triggered when apps were opened | yes — casting |
| mobile-data.onetrust.io | unknown | low | casting 2 queries; 172.64.155.231/104.18.32.25 (Cloudflare) | yes — casting |
| eligibility-panelresearch.googlevideo.com | analytics | medium | casting 2 queries (FORWARDED); 142.251.29.x (Google) | yes — casting |
| googleads.g.doubleclick.net | advertising | high | idle 2, casting 2 queries; 192.178.223.0/24 (Google); UDP/443 flows to .119/.132 during idle | yes — idle, casting |
| static.doubleclick.net | advertising | high | casting 2 queries; 172.217.76.x (Google) | yes — casting |
| catalyst.adgrx.com | advertising | medium | youtube 2 queries (FORWARDED); 34.240.131.229 (AWS) | yes — youtube |
| rtb.adgrx.com | advertising | medium | casting 4 queries; 52.19.224.221 (AWS) | yes — casting |
| tvx.adgrx.com | advertising | medium | youtube 2 (CACHE_STALE/FORWARDED), casting 2 queries; 34.243.118.177 (AWS) | yes — youtube, casting |
| rtb-config.samsungads.com | advertising | medium | casting 1 query; 54.162.159.37/54.237.106.192/50.17.7.32 (AWS) | yes — casting |
| tvp-ads-log.samsungads.com | advertising | medium | casting 1 query; 44.217.123.171/3.232.43.57/34.239.90.46 (AWS) | yes — casting |
| log-ingestion-eu.samsungacr.com | telemetry | high | ALL 5 active sessions (idle 4, youtube 2, casting 4, voice 2, standby 4); 18.203.131.210/52.31.162.23/63.34.234.233 (AWS) - the steady background 'heartbeat' of this TV | yes — idle, youtube, casting, voice, standby |
| log-config.samsungacr.com | telemetry | high | casting 2 queries; 35.169.253.43/34.197.82.150/3.234.95.195 (Atos/AWS) | yes — casting |
| qoe.samsungcloud.tv | telemetry | medium | casting 2 queries; 34.250.239.47/34.252.110.18/54.216.136.66 (AWS) | yes — casting |
| nrdp.logs.netflix.com | telemetry | medium | idle 5, youtube 2 queries; 54.229.239.201/3.254.26.105/54.246.169.239 (AWS); present whenever the Netflix app context is active | yes — idle, youtube |
| prd-euw1-ucs.aibixby.com | voice-related | high | idle 8, youtube 4, casting 4 queries; 108.133.12.121/63.33.218.101/54.194.205.84 (AWS) - matches observed 3.253/108.133 flows; aibixby.com is Samsung's Bixby (voice assistant) cloud | yes — idle, youtube, casting |
| provisioning-use2.mgmt.aibixby.com | voice-related | medium | casting 4 queries (FORWARDED); 3.149.37.111/52.14.215.191/3.20.117.82 (AWS us-east) | yes — casting |

Everything else observed is **UNCLASSIFIED** until evidence is recorded in `config/destinations.yaml`. Do not block on hostname similarity alone.

