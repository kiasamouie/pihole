# Research notes

Working source material for the guides. Every fact here carries its origin so contributors can check
it and so writers do not have to re-derive it. Facts marked **UNVERIFIED** must not be published in a
guide without a marker saying so.

Gathered 8 September 2026. Web search was unavailable during collection, so findings come from direct
fetches of vendor documentation, AOSP source, the eCFR API, Apple's documentation API, arXiv, and the
GitHub API used to read blocklist contents verbatim.

## Primary sources to cite rather than listicles

| Source | What it establishes |
| --- | --- |
| [Mazhar and Shafiq, IoTDI 2020](https://arxiv.org/abs/2001.08288) §IV-C | **68%** of smart TVs and 46% of game consoles in 200+ homes reached Google Public DNS directly. The widely repeated "72%" is a mis-citation of this paper. |
| [Anselmi et al., IMC 2024](https://arxiv.org/html/2409.06203v1) | Samsung and LG content recognition domains, cadence, recognition running on HDMI input, regional divergence, and that opt-out works. Code and data: [SafeNetIoT/ACR](https://github.com/SafeNetIoT/ACR), AGPL-3.0 |
| [Mandalari et al., PETS 2021](https://arxiv.org/abs/2105.05162) | Per-device required vs non-required destinations for Fire TV and Roku. Seeds our do-not-block set. |
| [Moghaddam et al., CCS 2019](https://blog.citp.princeton.edu/2019/09/18/watching-you-watch-the-tracking-ecosystem-of-over-the-top-tv-streaming-devices/) | `doubleclick.net` on 975/1000 Roku channels, `amazon-adsystem.com` on 687/1000 Fire TV channels, SSIDs leaking to trackers |
| [Varmarken et al., PETS 2020](https://arxiv.org/abs/1911.03447) | Existing blocklists protect better against third-party tracking than against first-party platform telemetry |
| [Huang et al., IMWUT 2020](https://arxiv.org/abs/1909.09848) | IoT Inspector: 44,956 devices, 4,322 users. The model for our submission design. |
| [AOSP TvSettings](https://android.googlesource.com/platform/packages/apps/TvSettings/+/refs/heads/main/Settings/) | Android TV exposes DNS 1 and DNS 2 in the static IP flow, and has no Private DNS preference in `network.xml` |
| [37 CFR 201.40(b)(10)](https://www.ecfr.gov/current/title-37/section-201.40) | DMCA exemption covering smart TVs and streaming devices |

## Cross-cutting facts

**On-device DNS capability falls into three tiers.** DNS decoupled from IP: tvOS and Samsung Tizen
only. DNS via full static IP: everything Android-derived, plus webOS, Vizio, VIDAA, Panasonic,
Philips, Sharp, Toshiba. Nothing at all: Roku OS in all versions including Roku TVs, and pre-Google-TV
Chromecast.

**Hardcoded resolvers.** Chromecast hardcodes 8.8.8.8 and 8.8.4.4. Roku is reported to fall back to
them since Roku OS 5.4 (Reddit, could not fetch directly, **UNVERIFIED**). Fire TV Sticks are widely
reported to reach 8.8.8.8 regardless of DHCP (**UNVERIFIED**, anecdotal). A Level1Techs wiki states
some webOS firmware hardcodes 8.8.8.8 (secondary source). Claims of a specific Samsung and LG
DNS-over-HTTPS bootstrap matrix circulate on privacysmarthome.com; that site reads as generated SEO,
its captures are unpublished, and its IP set is just the usual public resolvers. **Do not cite it.**

**Hardcoded IP addresses defeat DNS blocking entirely.** LG OTA fallback `156.147.69.32:8080` and live
telemetry `54.186.247.229:443`, both from the [Level1Techs
wiki](https://forum.level1techs.com/t/lg-tv-block-mini-how-to/255178), a rooted OLED65G5WUA. Only a
firewall rule reaches these.

**Encrypted DNS.** DNS-over-TLS on port 853 is trivial to reject. DNS-over-HTTPS is not, being
indistinguishable HTTPS on 443. HaGeZi publishes 3,324 DoH hostnames, 16,372 with VPN and proxy, and
1,451 DoH server IPs for firewall aliases. RFC 9462 Discovery of Designated Resolvers is the coming
problem: a client queries `_dns.resolver.arpa` and auto-upgrades without user configuration.

**IPv6 leakage is the top silent failure.** RFC 8106 defines the RDNSS option type 25 and DNSSL type
31, so Router Advertisements can hand a device a resolver with no DHCPv6 involved. Every interception
rule needs an IPv6 twin. OpenWrt documents `firewall.dns_int6` with `dest_ip="fd53::53"` and
`src_ip="!fd53::53"` for exactly this.

**Carrier-grade NAT is irrelevant** to outbound interception. It comes up constantly and is a red
herring.

**Prefer NXDOMAIN over SERVFAIL and REJECT over DROP.** Some firmware treats a SERVFAIL or a silently
dropped connection as no internet and retries aggressively.

**An mDNS reflector partially undoes VLAN isolation.** Casting across a boundary needs one, but given
that LG sets enumerate LAN devices, a reflector returns the reconnaissance surface the VLAN removed.

## Blocklists

| List | Licence | Cadence | Notes |
| --- | --- | --- | --- |
| [HaGeZi](https://github.com/hagezi/dns-blocklists) | GPL-3.0 | Several times daily | Best per-vendor work. `native.lgwebos` 341 entries, `native.amazon` 369, `native.samsung` 199, `native.apple` 108, `native.roku` 72. **No list for Google/Android TV, Vizio or Hisense.** |
| [Perflyst](https://github.com/Perflyst/PiHoleBlocklist) | MIT | **Stale since 13 July 2023** | The only list with per-domain breakage annotations. That commentary is the most valuable artifact in this space. Firebog's smart TV recommendations are this list. |
| [oisd](https://oisd.nl/) | Not stated | ~Hourly | Explicitly prioritises functionality over blocking. Good safe default, weaker on device-native telemetry. |
| [blocklistproject smart-tv](https://github.com/blocklistproject/Lists/blob/master/smart-tv.txt) | MIT | 2026-07-06 | 77 entries, unannotated. Blocks `cloudservices.roku.com` with no breakage note. |
| [StevenBlack](https://github.com/StevenBlack/hosts) | MIT | Active | General purpose, no smart TV coverage. Not a substitute. |
| [DandelionSprout GameConsoleAdblockList](https://github.com/DandelionSprout/adfilt/blob/master/GameConsoleAdblockList.txt) | | 2024 | ~11 relevant console entries. No smart TV list in that repo. |

**Recommended posture, from HaGeZi's own guidance:** the Light and Normal tiers deliberately include
only native trackers that do not break things. Ultimate blocks every one and does break things. Advise
Pro plus the specific device lists for hardware the household owns.

HaGeZi native list URL pattern:
`https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/native.{lgwebos|samsung|roku|amazon|apple|xiaomi|huawei|oppo-realme|vivo|tiktok|winoffice}-onlydomains.txt`

## LG, webOS

**Content recognition** is Alphonso, LG-owned since 2021, via `eu-acrX.alphonso.tv` in the EU and UK
and `tkacrX.alphonso.tv` in the US, where X rotates. Frames sampled every 10 ms, batched and sent
every 15 seconds, peaking every minute. [IMC 2024]

Firmware shared-object inventories in
[webosbrew/dev-toolbox-cli](https://github.com/webosbrew/dev-toolbox-cli) contain
`libacrcloud_recognizer.so`, `libAdvertisementPlugin.so` and `libTVIS.so`, so the recognition engine
is ACRCloud and is a named, root-reachable binary.

**DNS path.** webOS 6.0 and later: Settings > All Settings > General > Network > Wi-Fi Connection >
Advanced Wi-Fi Settings, or Wired Connection > Edit, then untick Set Automatically and edit DNS
Server. webOS 5.0: All Settings > Connection > Network Connection Settings. webOS 4.5: All Settings >
Connection. webOS 4.0 and earlier: All Settings > Network. Single DNS field, and unticking Set
Automatically pins a static IP. [[LG support](https://www.lg.com/us/support/help-library/lg-tv-how-to-manually-change-the-dns-server-settings--20150576570174)]

**Tier 0 privacy paths.** Live Plus at Settings > All Settings > General > System > Additional
Settings > Live Plus. Limit Ad Tracking at All Settings > Support > Privacy & Terms > Advertising.
User Agreements, covering viewing information, voice information and interest-based advertising, at
Support > Privacy & Terms > User Agreements. Voice at General > AI Service > Voice Recognition. Older
webOS puts Limit Ad Tracking at General > Additional Settings > Advertising. All **needs-confirmation**.

**The free hardening win, no developer mode required.** Disables the SSAP listener on ports 3000 and
3001, which is the attack surface for the whole CVE-2023-63xx chain:

```
luna-send -f -n 1 'luna://com.webos.settingsservice/setSystemSettings' \
  '{"category":"network","settings":{"allowMobileDeviceAccess":false}}'
```

Documented at [webosbrew settings](https://github.com/webosbrew/pages/blob/main/content/pages/hacking/settings.md).
There is an equivalent UI toggle.

**Domains.** `lgads.tv`, `alphonso.tv`, roughly 159 `<cc>.lgsmartad.com` hosts and 163
`<cc>-ad-lgsmartad-com.aws-prd.net` mirrors, so use the regex `(^|\.)lgsmartad\.com`. Telemetry and
home screen: `cdpbeacon`, `cdpsvc`, `homeprv`, `nudge`, `rdl`, `wiseconfig`, `recommend`, `service`
and `ads` under `.lgtvcommon.com`, plus `aic.*` variants. `nextlgsdp.com` family including
`us.`, `ngfts.`, `aic-gfts.`, `rdx2.`. `smartshare.lgtvsdp.com`, `us.rdx2.lgtvsdp.com`,
`ibis.lgappstv.com`, `us.ibs.lgappstv.com`, `ad.lgappstv.com`, `tv.wiselg.com`, `lggalleryplus.com`.
AI and CDN: `ngfts.lge.com` and the `qt2-`, `kic-`, `eic-`, `ruc-`, `aic-` prefixed variants. OTA:
`snu`, `su`, `su-ssl`, `nsu` `.lge.com`. IoT: `*.lgtviot.com`, `*.lgthinq.com`. Third party:
`yumenetworks.com`, `smartclip.com`, `lgad.cjpowercast.com.edgesuite.net`.

Perflyst has added a section headed `# Gamers Nexus - LG Smart TV spying` containing
`aic.cdpsvc.lgtvcommon.com`, `aic.cdpbeacon.lgtvcommon.com`, `us.nextlgsdp.com`,
`ngfts.nextlgsdp.com`, `aic.rdl.lgtvcommon.com`, `aic-gfts.nextlgsdp.com`.

**Never block.** `ngfts.lge.com` breaks Content Store thumbnails. `lgtvsdp.com` and `lgappstv.com`
break the Content Store. `lgsmartweb.com` breaks voice search. `us.lgtvsdp.com` per Perflyst issue 117.

**Developer mode.** Install the Developer Mode app from the Content Store, requires an LG account.
Gives unsigned IPK install, SSH on port 9922 as user `prisoner`, key server on 9991. Not root; the
`prisoner` user is jailed with no PTY. Tooling is `@webosose/ares-cli`:

```
ares-setup-device -a webos -i "username=prisoner" -i "privatekey=webos_rsa" \
  -i "passphrase=PASSPHRASE" -i "host=TV_IP" -i "port=9922"
ares-package sampleApp
ares-install --device webos com.example.app_1.0.0_all.ipk
ares-launch --device webos com.example.app
```

GUI alternative: [dev-manager-desktop](https://github.com/webosbrew/dev-manager-desktop), 2,549 stars,
no LG SDK needed.

**The expiry trap.** LG's own documentation says developer mode enables for a limited time, that you
check the Remain Session field and press EXTEND, and that **if the session runs out you cannot extend
it**. It disables after ten reboots while off the network, or after a reboot once the session has
expired. Critically: "After Developer Mode is disabled, the installed apps that you were using on
Developer Mode are uninstalled." The **1000-hour** figure is corroborated by
[webosbrew](https://www.webosbrew.org/rooting/) but not by LG. **The 50-hour figure appears in no LG
documentation and must not be published.**

**Root.** Compatibility oracle at [cani.rootmy.tv](https://cani.rootmy.tv/). Current tools:
`mvpd-autoroot` for webOS 1 to 3.4.2, `dejavuln-autoroot` for 3.5+ via USB with no dev mode,
`faultmanager-autoroot` for 4.0 to 10.0, `jsbro-autoroot` and `dangbro` for 7.x to 25. RootMyTV v1 and
v2 are patched and dead. As of 24 August 2025 the latest firmware for essentially all webOS 5, 6, 7
and 9 models is patched, and for 2025 models only factory webOS 10.0 was vulnerable.

Two rules that will bite people: uninstall the LG Developer Mode app before rebooting after rooting,
and never install it on a rooted TV. The Homebrew Channel writes to `/etc/motd` on every boot: "NEVER
EVER OVERWRITE SYSTEM PARTITIONS LIKE KERNEL, ROOTFS, TVSERVICE. Your TV will be bricked, guaranteed!"

**What root enables, and the proof on-device blocking works.** The Homebrew Channel
[startup script](https://github.com/webosbrew/webos-homebrew-channel/blob/main/services/startup.sh)
already bind-mounts a writable hosts file and appends LG update servers to it when
`webosbrew_block_updates` is set. It neuters crash and diagnostic upload spools by read-only
bind-mounting `/tmp/rdxd`, `/tmp/uploadd`, `/var/spool/rdxd` and `/var/spool/uploadd/*`. That is crash
telemetry only and does not touch content recognition. Boot hooks run from
`/var/lib/webosbrew/init.d`, which is the correct place for a blocking script. Whether `iptables` is
present and reliable across webOS versions is **UNVERIFIED**.

**Nothing on [repo.webosbrew.org](https://repo.webosbrew.org/api/apps.json) blocks or reports LG
telemetry.** All 51 apps checked. The closest entries are an app update blocker, YouTube and Twitch ad
removal patchers, an OpenVPN client and a WireGuard client. This is the clearest unbuilt slot in the
landscape.

**CVEs.** Bitdefender found CVE-2023-6317 authorisation bypass, CVE-2023-6318 privilege escalation to
root through the analytics reporting service, CVE-2023-6319 command injection in the lyrics library
affecting webOS 4.9.7 to 7.3.1-43, and CVE-2023-6320 authenticated command injection in network
configuration. Chained through ports 3000 and 3001, with over 91,000 devices exposing that
LAN-intended service to the public internet.
[Writeup](https://www.bitdefender.com/en-us/blog/labs/vulnerabilities-identified-in-lg-webos)

## Samsung, Tizen

**Content recognition** is in-house. Regional endpoints `acr-us-prd`, `acr-eu-prd`, `acr-au-prd`,
`acr-br-prd`, `acr-ca-prd`, `acr-in-prd`, `acr-kr-prd`, `acr-mx-prd`, `acr-nz-prd` under
`.samsungcloud.tv`, plus `acr0.samsungcloudsolution.com`, `log-config.samsungacr.com`,
`log-ingestion.samsungacr.com` for the US and `log-ingestion-eu.samsungacr.com` for the EU and UK,
`log-1/-2/-3.samsungacr.com`. Frames sampled every 500 ms, sent about every minute, peaking every five
minutes. [IMC 2024]

**DNS path.** 2016 to 2020: Settings > General > Network > Network Status > IP Settings > DNS Setting >
Enter manually. 2021 onward: Settings > General & Privacy > Network > Network Status > IP Settings >
DNS Setting. **DNS is selectable independently of IP**, which makes Samsung one of only two platforms
where a reader does not need to pin a static address. The DNS row is greyed out until the network
status test completes. Tizen OS 9 has a reported bug where DNS reverts to Auto after leaving IP
Settings. [[techjunctions](https://techjunctions.com/samsung-tv-dns-settings/)]

**Tier 0 paths.** 2022 onward: Settings > All Settings > General & Privacy > Terms & Privacy > Privacy
Choices, then turn off Viewing Information Services. Older: Settings > Support > Terms & Privacy >
Privacy Choices. The same screen holds Interest-Based Advertisements and Voice Recognition Services.
Samsung's own support page gives no path. The full IMC 2024 list of switches: viewing information
services, interest-based advertisements, **Customization Service**, improve personalized ads, news and
special offers, and enable Do Not Track.

**Domains.** Ads: `samsungads.com`, `ads.samsungads.com`, `config.samsungads.com`, `samsungtvads.com`,
`samsungadhub.com` with `ad.` and `rd.` prefixes, `samsungads.adsmeasurement.com`,
`samsungtv-d.openx.net`, `tvx.adgrx.com`. Device telemetry: the `apu/bpu/cpu/dpu/kpu/upu/xpu/ypu/zpu`
`.samsungelectronics.com` cluster, `nmetrics.samsung.com`, `smetrics.samsung.com`,
`event-tracking.samsung.com`, `dc.di.atlas.samsung.com`, `dc.di.runestone.samsung.com`,
`bigdata.ssp.samsung.com`, `analytics.bigdata.samsung.com`, `devicelog.samsungcloudsolution.net`.
Platform: `samsungcloudsolution.com` and `.net` with many prefixes, `samsungqbe.com`,
`samsungyosemite.com`, `internetat.tv`, `pavv.co.kr`, `samsungrm.net`. Third-party marketing stack is
large: 31 `*.demdex.net`, 30 `*.api.useinsider.com`, 15 `*.omtrdc.net`, plus Qualtrics and
`connecttv.pelmorex.com` for weather app tracking.

**Never block.** `time.samsungcloudsolution.com` breaks Plex, YouTube and Prime Video.
`auth.samsungosp.com` breaks account authentication. `infolink.pavv.co.kr` is needed for the app store
and login. `otnprd8` through `otnprd11.samsungcloudsolution.net`, `www.samsungotn.net` and
`otn.samsungcloudcdn.com` are required for software updates. `cdn.samsungcloudsolution.com` breaks
update checks. `lcprd1.samsungcloudsolution.net` breaks Smart Hub. `osb-ussvc.samsungqbe.com` breaks TV
Plus. `ns11.whois.co.kr` prevents Series 7 sets opening YouTube. `multiscreen.samsung.com`.

**Developer mode.** Smart Hub > Apps > App Settings, type `12345`, toggle Developer mode on, enter
your PC's IP address, reboot. The TV whitelists your PC's address. Tooling is Tizen Studio with the
Extension SDK and Samsung Certificate Extension:

```
tizen build-web -- /path/to/Project
tizen package -t wgt -s myCert -- /path/to/Project/.buildResult
sdb connect <TV_IP>
tizen install-permit -t <TV_NAME>
tizen install -n App.wgt -t <TV_NAME>
```

**The hard wall.** Tizen 6 and later retail sets reject SDK-generic distributor certificates outright:
`install failed[118, -12] ... Invalid certificate chain with certificate in signature`. Both
`tizen-distributor-signer.p12` (expired November 2012) and `tizen-distributor-signer-new.p12` (valid to
2032) are rejected. A self-signed setup did work on a 2020 Q70T running Tizen 5.5 with no Samsung
account and no DUID registration, so the cutoff is around Tizen 5.5 versus 6. Error 115 means the DUID
is wrong. Sideloaded certificates also expire, with community reports of apps vanishing from the Apps
row, but the **two-to-three month figure has no primary source and must not be published**.

**Traffic monitoring is impossible on Tizen, confirmed.** Samsung's Network API reference states it
"does not provide traffic monitoring or packet inspection capabilities". What a Tizen app *can* do is
read `getDns()`, `getSecondaryDns()`, `getGateway()`, `getIp()`, `getMac()`, `getWiFiSsid()`, plus
`ProductInfo.getModel()`, `getFirmware()`, `getDuid()`, `getLocalSet()`, and `AdInfo.getTIFA()` and
**`isLATEnabled()`** which reports whether Limit Ad Tracking is on. That makes a settings-audit app
possible even though a monitor is not.

**Root.** No public root for Tizen retail TVs. [samygo.tv](https://samygo.tv/) fails TLS with an
expired certificate, and its work targeted the pre-Tizen Orsay era. Treat Tizen as unrootable.
**Deprioritise Tizen engineering.**

## Roku

**The most locked-down platform in the report.** No DNS field and no static IP form. No ADB. No root,
and no community attempt found. Apps are sandboxed, and "scripts only have access to platform resources
that are exposed to the scripting layer as BrightScript components", so no packet capture, no DNS
visibility, no cross-app visibility. Certification separately forbids cross-app functionality.

**Developer mode** is Home three times, Up twice, then Right, Left, Right, Left, Right. Gives a web
installer at the device IP as user `rokudev`, plus telnet debug consoles on 8085 for BrightScript and
8080 for SceneGraph. **Only one app can be sideloaded at a time**, and a new one replaces the old.

**Publishing.** The private and non-certified channel programme is not offered today. Roku's current
documentation lists only public, which requires certification, and beta, which "cannot be published to
the public Streaming Store", exists for **only 120 days**, is capped at **10 beta apps** per account and
**20 testers** each. The exact retirement date of private channels is **UNVERIFIED**; the developer
forum archive is gone and Wayback holds no snapshot of a non-certified-channels doc.

**What a Roku owner can actually do, precisely three things.** Toggle the privacy settings. Audit from
the LAN over ECP on port 8060, where `GET /query/device-info` returns model, serial number, device ID,
software version, MAC addresses, timezone and locale, and `GET /query/apps` lists installed channels.
Note this is also the fingerprinting surface, so advise turning off "Control by mobile apps" if unused,
which from Roku OS 14.1 gates most control commands. Everything else is router and DNS.

**Tier 0 paths.** Settings > Privacy > Smart TV Experience, uncheck Use info from TV inputs, on Roku
TVs only. Settings > Privacy > Advertising, Limit ad tracking, or Personalize ads on newer builds, plus
Reset advertising identifier. Settings > Privacy > Microphone > Channel microphone access. All
**needs-confirmation**: Roku's privacy policy page is client-side rendered and the support sitemap
contains no privacy article.

**Domains.** `acr.roku.com` is the single most on-target hostname. Logging: `logs.roku.com` and the
`scribe`, `midland`, `austin`, `cooper`, `liberty`, `mobile` subdomains, plus `logs.sr.roku.com`,
`traces.sr.roku.com`, `userdata.sr.roku.com`. Ads: `ads.roku.com`, `adservices.roku.com`,
`advertising.roku.com`, `ads-us-east-1.delivery.roku.com` and regional siblings, `pixel.web.roku.com`,
`roku.adsmeasurement.com`, `ravm.tv`, `display.ravm.tv`. Voice: `samples.voice.cti.roku.com`.

**PETS 2021 classification.** Required: `api.sr.roku.com` and `youtube.com` **only**. Non-required:
`configsvc.cs.roku.com`, `cooper.logs.roku.com`, `scribe.logs.roku.com`, `partnerad.l.doubleclick.net`,
plus four Netflix analytics endpoints. Do not wildcard `roku.com`, and note that
`cloudservices.roku.com` appears in some lists with no breakage note.

## Amazon, Fire OS

**DNS path.** Settings > Network, highlight the network, forget and rejoin, then choose Advanced rather
than Connect, and enter IP, gateway, prefix length, DNS 1 and DNS 2. Wired is Settings > Network >
Configure Network. Static IP is mandatory. Some builds silently ignored custom Wi-Fi DNS.
[[aftvnews](https://www.aftvnews.com/how-to-manually-configure-the-ip-address-or-dns-server-on-an-amazon-fire-tv-or-fire-tv-stick/)]

Private DNS over ADB, community-documented, Fire OS specifics **UNVERIFIED**:

```
adb shell settings put global private_dns_mode hostname
adb shell settings put global private_dns_specifier dns.example
```

**Tier 0 paths.** Settings > Preferences > Privacy Settings, covering Device Usage Data, Collect App
Usage Data, Interest-based Ads and Your Advertising ID. Shipped October 2018. Also Settings >
Preferences > Featured Content for autoplay. Amazon's help page returned 503, so
**needs-confirmation**.

**ADB and sideloading.** Settings > Device or My Fire TV > Developer Options, enable ADB Debugging and
Apps from Unknown Sources. On some builds, Settings > My Fire TV > About > Your TV, then click the
D-pad seven times.

```
adb connect <ip>:5555
adb install app.apk
adb shell pm disable-user --user 0 <package>
adb shell pm enable <package>
```

**Use `pm disable-user`, never `uninstall`, on Fire OS.**

**Metrics packages.** `com.amazon.device.metrics`, `com.amazon.device.logmanager`,
`com.amazon.device.crashmanager`, `com.amazon.tv.fw.metrics`, `com.amazon.wirelessmetrics.service`,
`com.amazon.dp.logger`, `com.amazon.minerva.client.api`, `com.fireos.usagestats.proxy`,
`com.amazon.connectivitydiag`, `com.amazon.android.service.networkmonitor`.

**Ads and home screen.** `com.amazon.videoads.app`, `com.amazon.hedwig`, `com.amazon.firehomestarter`,
`com.amazon.ftv.glorialist`, `com.amazon.firespotlight`, `com.amazon.kindle.kso`,
`com.amazon.advertisingidsettings`, `com.amazon.hybridadidservice`, `com.amazon.tv.launcher`.

**Do not disable, with the documented consequence.** `com.amazon.client.metrics`,
`com.amazon.client.metrics.api` and `com.amazon.metrics.api` break the Settings UI on 5.2.6.3.
`com.amazon.device.settings.sdk.internal.library` breaks Device and Application settings.
`amazon.jackson19` breaks Display and Applications settings on 5.2.7.2.
`com.amazon.application.compatibility.enforcer` must stay on 5.2.7.2.
`com.amazon.identity.auth.device.authorization` breaks Amazon logins and Netflix. `com.amazon.imp` and
`com.amazon.tv.oobe` break applications and sign-in on 5.2.6.3. Note the tension: the metrics packages
are both the most valuable to kill and among the most likely to break Settings on some builds, so
version-gate everything. Sources:
[firestick-loader](https://github.com/esc0rtd3w/firestick-loader/blob/master/scripts/debloat/bloat-disable-noroot.sh),
[Fire-Tools](https://github.com/mrhaydendp/Fire-Tools/blob/main/Fire-Tools/Debloat.txt).

**Domains.** Ads: `aax-ott.amazon-adsystem.com`, `aax-eu.amazon-adsystem.com` and roughly 189
`*.amazon-adsystem.com` hosts, `mads.amazon.com`, `mads-eu.amazon.com`. Metrics:
`device-metrics-us.amazon.com` and its `-us-2` and `-us-ud` siblings,
`mobileanalytics.us-east-1.amazonaws.com`, `minerva.devices.a2z.com`, `forester.a2z.com`,
`federatedanalytics.amazon.com`, `fls-na`, `fls-eu` and `fls-fe` `.amazon.<tld>`,
`device-messaging-na.amazon.com`, `mas-sdk.amazon.com`, `d3p8zr0ffa9t17.cloudfront.net`.

**Never block.** `mas-ext.amazon.com` breaks app installs. `amazonadsi-a.akamaihd.net` breaks installs
and updates. `softwareupdates.amazon.com` and its CloudFront hosts break updates.
`ftv-smp.ntp-fireos.com` and `2.android.pool.ntp.org` break time sync. Alexa endpoints break voice.

**PETS 2021.** Required: `api.amazon.com`, `unagi-eu.amazon.com`, `youtube.com`. Non-required: 11
destinations, the highest of any device tested, including `aax-eu.amazon-adsystem.com`,
`device-metrics-us.amazon.com`, `mas-sdk.amazon.com`, `msh.amazon.com`. Note `api.amazon.com` appears
on both lists because it multiplexes.

**Root.** Fire TV Stick 3rd gen (`sheldonp`) and Lite (`sheldon`) via the MediaTek bootrom exploit
`kamakiri`, requiring Fire OS below 7.2.7.3, a USB cable and a Linux host. During setup you must block
`amzdigitaldownloads.edgesuite.net`, `softwareupdates.amazon.com` and `updates.amazon.com` or the
device force-updates past the vulnerable build. Destructive and warranty-voiding. Other generations
**UNVERIFIED**.

**Amazon Appstore is the friendliest store.** No documented developer registration fee. Publish cycle
every 30 to 90 minutes. The Developer Services Agreement prohibits interference and malware but has no
VpnService-specific policy on record, though several content policy pages returned 404 so a clause may
exist. Judgment: ship a logger to the store, ship a blocker as a sideload.

## Google, Android TV and Google TV

**DNS path, verified in AOSP source.** Settings > Network & Internet > network > IP settings > Static,
then sequential screens labelled `DNS 1:` and `DNS 2:` with placeholder text "Enter a valid IP address
or leave empty. Example: 8.8.8.8". Confirmed in `AdvancedWifiOptionsFlow.java` and
`res/values/strings.xml`. Static IP is required.

**Private DNS has no UI in stock TvSettings.** `res/xml/network.xml` contains no private DNS
preference. The framework capability exists from Android 9. The workaround is the ADB commands above.
Per-OEM availability is **UNVERIFIED**.

**Chromecast before Google TV hardcodes 8.8.8.8 and 8.8.4.4** and has no DNS UI at all.

**Tier 0.** Usage & diagnostics at Settings > Device Preferences on Android TV or Settings > Privacy on
Google TV. Ads at Settings > Privacy > Ads on Google TV, or Device Preferences > About > Ads > Reset
advertising ID on Sony. Google's own page could not be located, so **needs-confirmation**.

**The genuine content recognition package on Sony is `tv.samba.ssm`**, Samba TV, described in the Sony
debloat guide as ad tracking and viewing data collection. This is the single highest-value removal on a
Sony set. Also present in TCL Google TV lists.

**Correction to a common belief.** `com.google.android.tungsten.setupwraith` is **not** a telemetry
package. It is the Android TV Setup Wizard and fallback launcher. It only needs disabling if you have
already disabled `com.google.android.apps.tv.launcherx` and want a third-party launcher to stick,
because it re-enables the default. Source:
[FLauncher](https://github.com/osrosal/flauncher). Known side effect: the YouTube remote button stops
working when the default launcher is disabled on Chromecast with Google TV.

**TCL packages.** `com.tcl.screenadservice` is the ad service. Also `com.tcl.browser`,
`com.tcl.tv.appstore`, `com.tcl.usercenter`, `com.tcl.screensaver`.

**Sony diagnostics.** `com.sony.dtv.sonybugreportsys`, `com.sony.dtv.system.crashlog`,
`com.sony.dtv.customersupport`, `com.sony.dtv.da.service`, `com.sony.dtv.promos`,
`com.sony.dtv.sonyselect`, `com.sony.dtv.demomode`.

**☠️ Do not remove, documented boot loops on Sony Google TV.** `com.google.android.webview` breaks the
entire UI. `com.google.android.katniss` is essential to the launcher. `com.sony.dtv.tvx` kills the boot
process. Also `com.google.android.tts` and `com.android.location.fused`.

**☠️ The trap that breaks our own tooling.** A widely shared Sony debloat one-liner includes
`pm uninstall --user 0 com.android.vpndialogs`. That package is the system VPN consent dialog. Remove
it and `VpnService.prepare()` can never be granted again, so no network observer will ever work on that
device. Source:
[sony-google-tv-debloat](https://github.com/ironshadow786786-boop/sony-google-tv-debloat). This must be
a loud warning in the guide.

**The contradiction that justifies our per-model database.**
`com.google.android.tvrecommendations` is the primary safe-debloat target in
[TCL-Google-TV-Debloat-Optimizer](https://github.com/livvaa/TCL-Google-TV-Debloat-Optimizer) and is
listed under "will cause a boot loop if removed" in the Sony guide. Both may be correct for their
hardware. Never publish a cross-OEM list without per-model gating.

**Domains.** `androidtvchannels-pa.googleapis.com`, `androidtvlauncherxfe-pa.googleapis.com`,
`androidtvwatsonfe-pa.googleapis.com`, plus `googleads.g.doubleclick.net`,
`partnerad.l.doubleclick.net`, `2mdn.net`. **This is a real research gap.** Google's platform telemetry
is co-mingled with load-bearing `*.googleapis.com` hosts and the community has isolated only those
three `-pa` hostnames. There is no HaGeZi native list for Google or Android TV.

**Never block.** `play.google.com`, `*.gvt1.com`, `android.apis.google.com`, `*.googleapis.com`,
`connectivitycheck.android.com`, `connectivitycheck.gstatic.com`, `time.google.com`,
`ota.googlezip.net`. Sony: `applicast.ga.sony.net`, `portal.store.sonyentertainmentnetwork.com`,
`update.biv.sony.tv`.

**VpnService is the only way a third-party app sees other apps' traffic.** Android's documentation:
"If you don't create allowed or disallowed lists, the system sends all network traffic through the
VPN." Per-app attribution uses `ConnectivityManager.getConnectionOwnerUid` on Android 10 and later, or
`/proc/net/tcp` and `/proc/net/udp` below that. DNS tracking is clean on Android 12 and later and
heuristic below. Proven on a TV: a
[Blokada log from a Sony Android TV](https://github.com/blokadaorg/blokada/issues/134) shows it
blocking `googleads.g.doubleclick.net` and `securepubads.g.doubleclick.net`.

**Practical VpnService gotchas.** Always-on VPN frequently has no UI on Android TV; Nvidia Shield
"does not have that option". The ADB fallback writes `always_on_vpn_app` and `always_on_vpn_lockdown`
under `settings put secure`, but whether that arms it without device-owner privileges is
**UNVERIFIED and is the first thing to test on hardware**. Third-party VPN UIs are often not D-pad
navigable. A VPN service on some older Sony firmware caused boot loops. Only one VPN can be active at
a time, so the tool conflicts with a user's commercial VPN.

**Root.** Nvidia Shield is officially supported by LineageOS as `foster`, and NVIDIA publishes stock
recovery images, making it the lowest-risk unlock in the category. No bootloader unlock or root project
exists for Chromecast with Google TV or the Google TV Streamer, **UNVERIFIED negative**. OEM TVs have
locked bootloaders.

**Google Play publishing.** Requires the leanback launcher intent, `touchscreen` not required, a
320x180 banner containing the app name, full D-pad operability, App Bundles, and minSdk 31 or lower.
$25 fee plus identity verification, and new personal accounts need 12 testers opted in continuously
for 14 days before production access. The VpnService policy explicitly permits "App usage tracking",
"Device security apps (for example, anti-virus, mobile device management, firewall)" and "Network
related tools", requires documenting the VpnService use in the listing, and requires encrypting to the
tunnel endpoint, which is meaningless for a local tunnel. The real landmine is the Device and Network
Abuse policy: "Apps that block or interfere with another app displaying ads." Empirical calibration:
TrackerControl ships a Play "Slim" build with only Minimal blocking, versus a full F-Droid build. So
logging is fine, blocking is graduated, ad-blocking does not go on Play.

## Vizio, SmartCast

**No developer access of any kind.** No developer mode, no sideloading, no ADB, no root, no
third-party SDK, no homebrew project. Router and DNS only.

**DNS path.** Menu > Network > Manual Setup, turn DHCP off, then Pref DNS Server and Alt DNS Server.
Static IP required.

**Tier 0.** All Settings > Privacy & Legal > Viewing Data on current firmware. Older: All Settings >
Admin & Privacy > Viewing Data, or Menu > System > Reset & Admin > Viewing Data. Every Vizio privacy
URL probed returned 404 or 401, so **needs-confirmation**.

**The framing that matters.** Turning Viewing Data off is a legally backed right rather than a hack.
The FTC order requires Vizio to obtain affirmative express consent, so the toggle exists because a
regulator made it exist.

**Domains.** `control.tvinteractive.tv`, `control2.tvinteractive.tv`, `mcp.tvinteractive.tv`,
`tvmeta-dynamic.tvinteractive.tv`, regex `(\.|^)tvinteractive\.tv$`. Inscape corporate:
`inscape.tv`, `inscape-ai.com`, `tvmetrix.com`, low-confidence source. Hardcoded NTP
`vizio.pool.ntp.org`.

**Never block.** `api.vizio.com` and `images.vizio.com` are required for SmartCast features.
Perflyst explicitly declines to block `announcements.vizio.com`.

## Hisense, VIDAA

**DNS path.** Settings > Network > Network Configuration > Advanced Settings > IP Settings > IP Setting
Mode Manual, then DNS Server 1 and DNS Server 2. Static required.

**Tier 0.** Settings > System > Advanced Settings > Personalised Ads on VIDAA 6 and 7. A "Settings >
System > Privacy > Viewing Information Services" path appears in one guide but mirrors Samsung wording
and is **UNVERIFIED**. Hisense's US privacy policy admits content recognition audio collection without
giving a path.

**Sideloading works by DNS-hijacking a Hisense domain.** `weinzii/vidaa-edge` points `vidaahub.com` at
your own host, then the TV's browser is used to reach it, and privileged JavaScript bridge functions
install a PWA. The underlying research at [bananamafia.dev](https://bananamafia.dev/post/hisensehax/)
found `Hisense_installApp()` silently installs HTML5 applications without user notification, and that
custom `File.read()` with `../` traversal read Netflix preferences, Wi-Fi configuration and
`/etc/passwd`.

**That cuts both ways, and belongs in the consumer advice.** The same primitive means any web page the
TV's browser visits can silently install an app and read config files. "Do not browse the web on your
Hisense TV" is legitimate, sourced advice.

**Domains.** `api-gps-em`, `auth-em`, `msg-em`, `api-launcher-em`, `auth-launcher-em`, and the `-na`
equivalents, plus `unified-ter-na`, all under `.hismarttv.com`. `api-gps-em` connects thousands of
times a day.

**Do not use the regex `^api\..*\.hismarttv\.com$`** that circulates for this vendor. It matches
`api.us.hismarttv.com`, `api.euro.hismarttv.com` and `api.eu.hismarttv.com`, which are the three
hosts on the never-block list because they may carry firmware updates. Use a prefix-scoped pattern
instead, as `data/endpoints/hisense.yml` does.

**Never block.** `api.us.hismarttv.com`, `api.euro.hismarttv.com` and `api.eu.hismarttv.com` may be
needed for firmware updates.

## Apple, tvOS

**DNS is decoupled from IP**, one of only two platforms where that is true. Settings > General >
Network > network > Configure DNS > Manual. Apple's own guide page does not document it, so
**needs-confirmation**.

**No content recognition.** tvOS is the least invasive major platform on this axis. The exposure is
analytics and Apple's own ad network.

**The surprise: tvOS 17 gained packet tunnel support.** Verified from Apple's documentation API,
`NEPacketTunnelProvider`, `NEVPNManager`, `NETunnelProviderManager` and the
`com.apple.developer.networking.networkextension` entitlement all show tvOS 17.0 availability.
`NEDNSSettingsManager`, `NEDNSProxyProvider`, `NEFilterDataProvider` and `NEAppProxyProvider` remain
unavailable. So whole-device DNS and SNI visibility is possible, with **no per-app attribution**, no
content filtering, and no system-wide DNS settings. Requires the managed entitlement.

**App Store approval is implausible.** Guideline 5.4(a) requires a VPN app be "offered by a VPN
provider, not by a third party", with disclosures about "which servers and countries" that a local-only
tool structurally cannot make. Guideline 2.5.1 adds an intended-purpose clause. TestFlight, capped at
100 internal and 10,000 external testers with Beta App Review, is the realistic path.

**Tier 0.** Settings > General > Privacy > Apple Advertising > Personalized Ads, and Analytics &
Improvements > Share Apple TV Analytics. **needs-confirmation**.

**Domains.** `metrics.apple.com`, `xp.apple.com`, `iadsdk.apple.com`, `tv-analytics-events.apple.com`,
`securemetrics.apple.com`, roughly 110 entries in HaGeZi's `native.apple`.

**Never block.** `mesu`, `gdmf`, `gg` and `gs` `.apple.com` for updates, `albert.apple.com` for
activation, `*.itunes.apple.com`, `*.apps.apple.com`, `*.mzstatic.com`, `ocsp`, `certs` and `valid`
`.apple.com`, `guzzoni.apple.com`, `*.push.apple.com`.

## Which OS is it

| Brand | Platform | Route to |
| --- | --- | --- |
| Sony Bravia | Google TV or Android TV on all current models | Google guide, plus kill `tv.samba.ssm` |
| Philips | Titan OS on many current EU sets, Android TV on others, Saphi on older | Titan OS is business-gated with no consumer dev mode found, **UNVERIFIED** |
| Panasonic | My Home Screen on older EU sets, Amazon Fire TV built in on several current flagships | Fire OS guide, or no known path for My Home Screen |
| Sharp | Roku TV in the US, Android or Google TV, or Aquos Linux | Roku or Google guide |
| Toshiba | Fire TV Edition in the US, Google TV on newer, VIDAA in some regions | Fire OS, Google or VIDAA guide |
| Hisense | VIDAA, plus Google TV and Roku TV SKUs | VIDAA, Google or Roku guide |
| TCL | Google TV, Roku TV, some EU variants | Google or Roku guide |

**Universal identification tool.** [epk2extract](https://github.com/throwaway96/epk2extract) extracts
firmware for LG, Hisense, Sharp, Philips and Thompson. Combined with `dev-toolbox-cli` shared-object
inventories, this is how you prove a set ships `libacrcloud_recognizer.so` rather than asserting it.

## Resolvers

| Tool | Per-client policy | Log export | API | Notes |
| --- | --- | --- | --- | --- |
| AdGuard Home | Yes, with tags and per-client upstreams | Yes, file-based, 1 hour to 1 year | REST | Built-in DHCP so you can own option 6 without the router. Best general recommendation. |
| Pi-hole v6 | Yes, groups | Yes | Yes, new in v6 | Largest community and most tutorials |
| Blocky | Yes, per client group | **CSV or Postgres, MariaDB, Timescale** | REST plus Prometheus and Grafana dashboards | Shortest path for datamining. Collects no telemetry itself. |
| Technitium | Yes, per-client blocklists | Yes | Yes | Also a DoH, DoT and DoQ **server**, so you can hand a TV a private encrypted endpoint |
| Unbound on OPNsense | Yes, multiple policies | Log Queries and Log Replies | Via OPNsense | Built-in feeds include oisd and HaGeZi. Docs warn query logging makes the server significantly slower. |
| dnscrypt-proxy | Limited | Separate logs for suspicious queries | No | Best as an upstream, not the policy engine |

**Hosted.** NextDNS gives per-device configurations, log retention from 1 hour to 2 years, storage
region choice, and 300,000 queries a month free. **It fails open past the cap**, answering normally
instead of blocking, which readers must be warned about. AdGuard public DNS default is 94.140.14.14
and 94.140.15.15. ControlD's free resolvers keep no individual logs; paid adds API and log streaming.

**Two resolvers that do not solve this problem.** Quad9 and Cloudflare for Families block malware, not
advertising or telemetry. **Mullvad DNS is scheduled for discontinuation on 2 November 2026**, so
nothing should be built on it.

## Router enforcement

**DHCP option 6** is defined in [RFC 2132](https://www.rfc-editor.org/rfc/rfc2132.html) §3.8. OpenWrt:

```
uci add_list dhcp.lan.dhcp_option='6,192.168.1.2'
uci commit dhcp
service dnsmasq restart
```

**Port 53 redirect on OpenWrt**, documented verbatim on the wiki and identical for fw3 and fw4:

```
uci set firewall.dns_int="redirect"
uci set firewall.dns_int.name="Intercept-DNS"
uci set firewall.dns_int.family="any"
uci set firewall.dns_int.proto="tcp udp"
uci set firewall.dns_int.src="lan"
uci set firewall.dns_int.src_dport="53"
uci set firewall.dns_int.target="DNAT"
uci set firewall.dns_int.dest_ip="192.168.2.2"
uci set firewall.dns_int.src_ip="!192.168.2.2"
uci commit firewall
service firewall restart
```

The `!` self-exclusion is the step people forget, and omitting it causes a redirect loop. Source:
[OpenWrt intercept DNS](https://openwrt.org/docs/guide-user/firewall/fw3_configurations/intercept_dns).
The `fw4_configurations/intercept_dns` page does not exist; do not link it.

**Two fragments that are incomplete, and must not be published as working config.** Research
captured only the distinguishing lines of the IPv6 rule and the port 853 rule, not the whole
sections. Both are missing the section type, `name`, `family`, `proto`, `src` and `src_dport` that
the IPv4 rule above sets:

```
# FRAGMENT ONLY. Not a working rule. See the wiki for the full section.
uci set firewall.dns_int6.dest_ip="fd53::53"
uci set firewall.dns_int6.src_ip="!fd53::53"

# FRAGMENT ONLY. Not a working rule.
uci set firewall.dot_fwd.target="REJECT"
uci set firewall.dot_fwd.dest_port="853"
```

The IPv6 twin and the port 853 reject are both real and documented on the same wiki page. What is
missing here is the surrounding boilerplate, so anyone writing the OpenWrt guide has to pull the
complete sections from the wiki rather than pasting these two pairs. Publishing a half-specified
firewall rule is the worst failure mode this project has, because it silently does nothing while the
reader believes they are protected.

**pfSense**, three rules and order matters. A port forward on LAN for TCP and UDP 53 with the
destination inverted to exclude the resolver, redirecting to the resolver. Above it, a No RDR rule for
the resolver's own upstream queries. Then outbound NAT. **That third rule masquerades the source and
destroys per-client attribution in the query log**, which matters for datamining, so prefer a topology
that does not need it. Source: [LabZilla](https://labzilla.io/blog/force-dns-pihole).

**Verification, in increasing rigour.** Create a record only your resolver knows, point a laptop at a
public resolver, and look it up. Query a public resolver and confirm the query appears in your log.
Filter the log to the TV. Packet-capture the LAN side for 53, 853 and UDP 443. Packet-capture the WAN
side to catch hardcoded-IP dials. Browser leak test, which only tests browsers. Repeat over IPv6.

**Verified as unfetchable during research, so publish nothing specific.** UniFi, GL.iNet, Firewalla and
Asuswrt-Merlin documentation all returned 403 or 404, and the Merlin DNSFilter wiki rendered as an
empty edit form. Diversion is free per [diversion.ch](https://diversion.ch/) and that is all that could
be confirmed.

## Collector design

**Do not fork PCAPdroid, drive it.** Its manifest declares `android.software.leanback`,
`LEANBACK_LAUNCHER`, a banner, and `touchscreen` not required. Changelog shows "Add Android TV support"
in 1.3.0 on 5 March 2021 and continuous TV fixes since. It extracts hostnames from DNS, TLS and HTTP.
Its connections CSV columns are `ipproto, src_ip, src_port, dst_ip, dst_port, uid, appName,
packageName, l7proto, status, info, sent_bytes, rcvd_bytes, sent_pkts, rcvd_pkts, first_seen,
last_seen`, where `info` is the resolved hostname. Our transform drops four columns and rounds two,
which is subtractive and therefore safe. It is scriptable headlessly:

```
adb shell am start -e action start -e api_key <KEY> \
  -n com.emanuelef.remote_capture/.activities.CaptureCtrl
```

Actions `start`, `stop`, `get_status`, with `pcap_dump_mode`, `app_filter`, `collector_host`,
`collector_port`. GPL-3.0. Fire TV compatibility is **UNVERIFIED** and is an explicit test item.

An Android TV fork of RethinkDNS already exists at
[ezelab/rethink-tv](https://github.com/ezelab/rethink-tv) with a `tv` Gradle flavour and Compose for TV
navigation, proposed upstream as
[celzero/rethink-app#2664](https://github.com/celzero/rethink-app/issues/2664). **Talk to that
maintainer before writing Android code.**

**Log field inventories.** Pi-hole v6 `GET /api/queries` returns `id`, `time`, `type`, `domain`,
`cname`, `status`, `client{ip,name}`, `dnssec`, `reply{type,time_ms}`, `list_id`, `upstream`, `ede`.
AdGuard Home's querylog is JSONL with `T`, `QH`, `QT`, `QC`, `ECS`, `CID`, `CP`, `Upstream`, `Answer`,
`IP`, `Result`, `Elapsed`, `Cached`. **`Answer` is a fully packed DNS message and `IP` is the client
address on every record**, so a raw querylog upload leaks LAN topology. NextDNS has a resumable
server-sent events log stream.

**Capture must start before the TV boots.** The IMC 2024 team note most DNS requests fire in the first
seconds after activation, so a late start loses the hostname-to-address mapping for the session.

**TLS interception is out of scope, and the state of the art agrees.** mitmproxy's own documentation
says pinned applications will not accept its certificates and the workarounds are all app-patching
tools. The IMC 2024 team adopted black-box auditing explicitly and listed payload analysis as future
work. An IMC 2021 baseline found 11 of 32 IoT devices interceptable, so roughly a third, which is
unreliable as a methodology.

**JA4 licensing.** JA4 for TLS clients is BSD-3-Clause. The rest of the JA4+ family is patent-pending
under FoxIO License 1.1 with commercial restrictions. JA3 was archived on 1 May 2025 and deprecated by
its author. **Collect JA4 only.**

## Things we deliberately do not publish

| Claim | Status |
| --- | --- |
| 72% of smart TVs hardcode DNS | Mis-citation. The paper says 68%. |
| webOS developer mode expires after 50 hours | Absent from all LG documentation. Only 1000 hours is corroborated. |
| Tizen sideload certificates expire after 2 to 3 months | No primary source. Expiry is real, the interval is not established. |
| Firmware updates silently re-enable content recognition | Widely repeated, undocumented. **This is measurable and would be an original contribution.** |
| Samsung and LG use a specific hardcoded DoH bootstrap IP set | Single low-quality source with unpublished captures. |
| The Gamers Nexus endpoint list | Not reproduced in any article. Needs pulling from the video directly. |
| Texas alleges 7,200 screenshots per hour | Get the complaint PDFs before citing the figure. |
