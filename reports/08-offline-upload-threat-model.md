# 08 — Offline / Buffer-then-Upload Threat Model (Samsung Tizen TV)

Status: threat model + detection design. **No live experiment has been run yet.**
The test script `scripts/tv-offline-reconnect-test.sh` is prepared, reviewed, and
failsafe (one temporary rule, trap-removed, removal verified), but it has NOT
been executed against the TV in this phase.

## 1. What the claim is

Internet reporting (centred on a 2024 controversy around an **LG** TV, plus
older vendor-disclosure coverage) asserts that some smart TVs:

1. capture/process voice locally (keyword spotting on-device);
2. may retain captured data while offline;
3. upload the retained data when connectivity returns.

**This report deliberately does NOT transfer that behaviour to Samsung.** The
LG demonstration was on a specific LG device/firmware, and no public, reproducible
proof exists that this Samsung QE65Q75C behaves identically. Treating the LG case
as "proof Samsung does it" would be a category error. What IS true and useful:

- Samsung's own documentation acknowledges that **when voice commands are
  enabled/used**, voice information may be transmitted to the cloud (see
  category table below). That is a *documented* behaviour, bounded to
  voice-feature use.
- "Offline buffering → upload on reconnect" for **any** TV is an *unproven
  threat model* for this device. We design controls so that IF it happens, we
  detect and control the **outbound transfer** (which is network-visible) even
  though the **payload** (which is not network-visible without TLS interception —
  which we refuse to do) stays opaque.

## 2. Evidence categories (kept strictly separate)

| Category | Statement | Status for THIS TV |
|----------|-----------|--------------------|
| CONFIRMED BY SAMSUNG | Voice commands, when the voice feature is used, may send audio/voice data to Samsung's voice service (Bixby). Opt-out exists in TV settings. | Documented in Samsung privacy materials; JS-heavy pages limited direct scraping — corroborated via secondary references, not verbatim scrape. |
| CONFIRMED BY RESEARCH | ACR (viewing recognition) runs on the TV, phones home to `samsungacr.com` / `acr0.samsungcloudsolution.com` / regional `acr-*-prd.samsungcloud.tv`; opting out stops the traffic; it works even with the TV as a dumb display. | IMC 2024 (SafeNetIoT/ACR), reproducible. |
| OBSERVED BY US | `prd-euw1-ucs.aibixby.com` and `provisioning-use2.mgmt.aibixby.com` were reached by this TV **during normal sessions in which no voice command was given**. | reports/06. This is provisioning/keepalive to the voice infrastructure — consistent with a feature that is *configured* but not used; it is NOT evidence of ambient listening. |
| COMMUNITY REPORTED | LG "offline recording" claims; various TV telemetry anecdotes. | Not applicable to this Samsung model; recorded only as context. |
| UNPROVEN / THREAT MODEL ONLY | "This Samsung stores voice data offline and uploads it on reconnect." | **No evidence.** The experiment below tests whether such a transfer WOULD be visible and controllable — it cannot test what was stored. |

## 3. What network control CAN and CANNOT determine

**CANNOT (be honest about this):**
- prove or disprove that any encrypted upload *is* a voice transcript;
- see what was captured, stored, or processed on-device;
- know whether audio is being processed locally at all (no payload inspection —
  TLS MITM is explicitly out of scope by project policy).

**CAN:**
1. **Offline-while-attempted** evidence: while WAN egress is denied (rule
   `TVGUARD-OFFTEST`), every new connection the TV *tries* to make is logged
   (dst IP, port, protocol, attempt count). If the TV repeatedly tries a
   Samsung/Bixby/telemetry destination while "offline", that is a buffered-upload
   candidate signal.
2. **Reconnect burst** evidence: after WAN is restored, a time-stamped capture of
   the first N minutes shows *which* destinations get new connections, *how many*
   bytes are transmitted, and *to whom*. A burst to `*.aibixby.com`,
   `*.samsungacr.com` or telemetry endpoints immediately after reconnect — that
   did not occur during the offline window — is exactly the observable signature
   of "store while offline → upload after reconnect".
3. **Containment**: because all TV Internet traffic traverses this box (NAT path
   proven, reports/05/06), any such upload MUST cross our egress point. We can
   deny, log, or throttle it per destination — we do not need to read the payload
   to stop it.

The truthful reporting language the tooling uses:

> "X connections / Y bytes were transmitted to <destination> in the first
> N minutes after connectivity was restored, following M denied attempts to the
> same destination while offline."

It never says "transcripts", "audio", or "what was recorded".

## 4. The experiment (prepared, not run)

`scripts/tv-offline-reconnect-test.sh samsung [offline-min] [post-min]`

1. Pre-check: Samsung must currently route through this host (conntrack must show
   live entries for <SAMSUNG_TV_IP>). If not, the script refuses to run (nothing
   to observe, and we don't want a false "no buffering" result).
2. Baseline snapshot: recent conntrack + journal.
3. **Phase 1 (offline):** one temporary nftables rule at position 1 of the
   `tvguard` forward chain — `ip saddr <SAMSUNG_TV_IP> ip daddr != <LAN_SUBNET>
   ct state new ... drop`. LAN traffic (Plex, EPG, casting, the hub) is
   unaffected by design. All dropped WAN attempts are kernel-logged with the
   `TVGUARD-OFFTEST` prefix.
4. **Phase 2 (restore):** rule deleted by handle; deletion verified; a trap
   guarantees deletion on ANY exit (including Ctrl-C/Crash), with a re-entrancy
   guard so the trap cannot recurse. The script fails loudly (exit 7) if the
   rule cannot be verified removed — it never silently leaves the TV offline.
5. **Phase 3 (post):** observe for N minutes; collect conntrack deltas, journal
   `TVGUARD-NEW` lines, and Pi-hole query log (deferred DNS bursts are the
   strongest "it was queued" signal — a device that couldn't resolve a name while
   offline and resolves it the moment WAN returns is buffering *something*).
6. Output: `data/offline-reconnect/<timestamp>/{metadata.json,offline-attempts.
   csv,post-queries.csv,summary.md}` (git-ignored).

Interpretation guidance (for the future review, not automation):

| Observation | Meaning |
|-------------|---------|
| No denied attempts while offline, no post-burst | No observable buffering. Does NOT prove nothing is stored. |
| Denied attempts to ACR/Bixby/telemetry hosts while offline | The TV was *trying* to report while disconnected → retry/backoff behaviour, possible buffering. |
| Quiet while offline, then a burst to a Samsung/Bixby host in the first minutes after reconnect | The strongest network-visible signature of "stored → uploaded". Still does not identify payload content. |
| Bursts only to CDN/content hosts | Normal app behaviour (catch-up on content metadata), not a telemetry signal by itself. |

## 5. Interaction with the privacy policy

- The experiment is **orthogonal** to standard/strict tiers: run it in MONITOR
  mode (privacy off or on — the OFFTEST rule is separate and temporary).
- If the experiment later shows a buffered upload to a Bixby/ACR destination,
  the *control* is already in place: that destination is either in the strict
  voice tier or gets added to `config/privacy-policy.yaml` with this evidence
  attached. No new architecture needed.
- If the experiment shows nothing, that is a **null result**, reported as such —
  absence of observed traffic is not proof of absence of collection.

## 6. Explicit non-claims

- We do NOT claim Samsung records ambient audio on this TV.
- We do NOT claim the LG controversy applies to Samsung.
- We do NOT claim any captured bytes are transcripts.
- We DO claim: if any offline-stored data is uploaded on reconnect, the upload
  will (a) be visible to us as a post-reconnect connection/byte burst, (b) be
  attributable to a destination we can research, and (c) be controllable by the
  same egress policy we have already validated.
