#!/usr/bin/env python3
"""
privacy-policy-build.py - resolve the privacy policy configs to IPs.

Source of truth: config/privacy-policy.yaml (deny), config/privacy-keep.yaml
(global keep overrides), config/manufacturer.yaml (Samsung deny-by-default
zones) and config/manufacturer-keep.yaml (essential Samsung allowlist).
This script:

  1. Collects entries per tier (one source of truth: per-entry `tiers:` lists):
       standard  = entries whose `tiers` include "standard"
       senv      = entries whose `tiers` include "standard" or "voice"
                    (the standard-no-voice profile)
       voice     = entries whose `tiers` include "voice" (reference list)
       strict    = ALL entries (strict is the superset)
       doh       = the `doh` section (strict-only, IP-based)
       mlock     = standard-no-voice + Samsung deny-by-default zones (regex)
                   + essential Samsung allowlist (allows); the recommended
                   manufacturer-lockdown profile. It deliberately does NOT
                   inherit strict's low-confidence third-party telemetry or
                   DoH-IP set.
  2. Resolves every domain against an EXTERNAL resolver (8.8.8.8 via dig) -
     deliberately NOT the local Pi-hole, which may return synthetic/empty
     answers for blocked domains.
  3. Applies keep-list overrides: an IP that is also used by a keep-list
     domain is removed from the deny sets (keep wins) and reported.
     Entries with `kind: suffix` (documented exception, see the YAML header)
     are emitted as Pi-hole regex denies ("regexes") plus a resolved IP set
     built from the entry's explicit `hosts:` list; a keep-list domain under
     a suffix keeps the whole suffix out.
  4. Writes data/privacy-policy/resolved.json (consumed by tvguard-apply.sh
     for IPs and by privacy-policy-apply.sh for domains + regexes) and
     data/privacy-policy/preview.md (human review).

Nothing here is applied to the firewall or Pi-hole.

Usage:  python3 scripts/privacy-policy-build.py [resolver-ip]
"""
import ipaddress
import json
import os
import re
import subprocess
import sys
import time

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
POLICY = os.path.join(ROOT, "config", "privacy-policy.yaml")
KEEP = os.path.join(ROOT, "config", "privacy-keep.yaml")
MANUF = os.path.join(ROOT, "config", "manufacturer.yaml")
MANUF_KEEP = os.path.join(ROOT, "config", "manufacturer-keep.yaml")
OUTDIR = os.path.join(ROOT, "data", "privacy-policy")

# Anti-wildcard guard: the ONLY zones config/manufacturer.yaml may use for
# deny-by-default. Adding a new zone requires a reviewed code change here -
# the build refuses anything else, so no new wildcard zone can sneak in.
KNOWN_SAMSUNG_ZONES = {
    "samsungacr.com", "samsungads.com", "samsungcloud.tv", "samsungcloud.com",
    "samsungcloudcdn.com", "samsungcloudsolution.com", "samsungcloudsolution.net",
    "samsungotn.net", "samsungnyc.com", "samsung.com", "samsungosp.com",
    "bixbyllm.com", "sbixby.com",
}

# Deliberately NOT zones (documented in research/samsung-ownership.yaml):
#   aibixby.com      - already controlled by the voice-tier *.aibixby.com regex
#   samsungqbe.com   - dynamic app infra, documented breakage (Perflyst #82)
#   samsungadhub.com - lapsed + drop-captured, not Samsung-owned today


def resolve(domain, resolver):
    """Return (ipv4s, ok). Never resolves via the local Pi-hole."""
    try:
        out = subprocess.run(
            ["dig", "+noall", "+answer", "+time=4", "+tries=2", "@%s" % resolver, domain],
            capture_output=True, text=True, timeout=15,
        ).stdout
    except Exception:
        return [], False
    ips = []
    for line in out.splitlines():
        # dig +answer line: <name> <ttl> <class> <type> <rdata>
        parts = line.split()
        if len(parts) >= 5 and parts[3] == "A":
            try:
                ip = ipaddress.ip_address(parts[4])
                if not ip.is_private and not ip.is_loopback:
                    ips.append(str(ip))
            except ValueError:
                pass
    return sorted(set(ips)), True


def zone_of(domain, zones):
    """Return the deny zone `domain` falls under (exact or subdomain), else None."""
    dl = domain.strip().lower()
    for z in sorted(zones, key=len, reverse=True):
        if dl == z or dl.endswith("." + z):
            return z
    return None


def zone_regex(zone, keep_hosts=None):
    r"""Deny-by-default regex for one Samsung zone.

    Generated form:
      ^(([A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*)?\.)?samsungcloudsolution\.com\.?$
    - www.samsungcloudsolution.com   -> MATCHES (denied, unknown Samsung host)
    - samsungcloudsolution.com       -> apex also denied (label part optional)
    Keep hosts inside the zone (time., cdn., ...) are NOT exempted in the
    regex: this FTL build's regex validator rejects lookaround (RE2-style
    engine, verified 2026-09-21), and keep protection is carried by the
    group-scoped Pi-hole ALLOW rows (allow beats deny in FTL; proven by the
    selftest's keep-host resolution test). Sublabels of a keep host
    (x.time.\u2026) are NOT auto-allowed - allow explicitly via
    manufacturer-review.sh if needed.
    """
    return (r"^(([A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*)\.)?" + re.escape(zone) + r"\.?$")


def collect_tier_entries(doc):
    """Return (standard, senv, voice, strict, doh) entry lists.

    standard = tiers include "standard"
    senv     = tiers include "standard" or "voice" (the standard-no-voice profile)
    voice    = tiers include "voice" (reference list; also part of senv)
    strict   = ALL non-doh entries (strict is the superset)
    doh      = the `doh` section (strict-only, IP-based)
    """
    std, senv, voice, strict, doh = [], [], [], [], []
    for tier_name, spec in (doc.get("policies") or {}).items():
        for e in spec.get("entries", []) or []:
            d = (e.get("domain") or "").strip().lower()
            if not d:
                continue
            tiers = e.get("tiers") or [tier_name]
            if tier_name == "doh":
                doh.append((d, e))
                continue
            if "standard" in tiers:
                std.append((d, e))
                senv.append((d, e))
            if "voice" in tiers:
                voice.append((d, e))
                senv.append((d, e))
            strict.append((d, e))

    def dedupe(pairs):
        seen, out = set(), []
        for d, e in pairs:
            if d not in seen:
                seen.add(d)
                out.append((d, e))
        return out

    return dedupe(std), dedupe(senv), dedupe(voice), dedupe(strict), doh


def main():
    resolver = sys.argv[1] if len(sys.argv) > 1 else "8.8.8.8"
    with open(POLICY, encoding="utf-8") as fh:
        policy = yaml.safe_load(fh)
    with open(KEEP, encoding="utf-8") as fh:
        keep = yaml.safe_load(fh)
    with open(MANUF, encoding="utf-8") as fh:
        manuf = yaml.safe_load(fh)
    with open(MANUF_KEEP, encoding="utf-8") as fh:
        mkeep = yaml.safe_load(fh)

    std_entries, senv_entries, voice_entries, strict_entries, doh_entries = collect_tier_entries(policy)
    keep_domains = [(k["domain"].strip().lower(), k) for k in (keep.get("keeps") or [])]

    # Keep domains resolve first: their IP space is protected.
    keep_ips = {}
    print("Resolving keep-list domains via %s ..." % resolver)
    for d, meta in keep_domains:
        ips, _ = resolve(d, resolver)
        keep_ips[d] = ips
        time.sleep(0.05)
    protected = set()
    for d, ips in keep_ips.items():
        for ip in ips:
            protected.add(ip)

    # Resolve cache: each domain is looked up at most once, no matter how many
    # profile sections it belongs to (standard/senv/strict all overlap heavily).
    cache = {}
    def resolve_cached(d):
        if d not in cache:
            cache[d] = resolve(d, resolver)
            time.sleep(0.05)
        return cache[d]

    def build_section(entries, label):
        domains, ips, unresolved, kept_out, regexes = [], set(), [], [], []
        for d, meta in entries:
            if d in keep_ips:
                kept_out.append((d, "keep-domain override"))
                continue
            if (meta.get("kind") or "exact") == "suffix":
                # Scoped single-purpose family: DNS-layer regex deny (primary)
                # + IP set from the explicit host list (second layer).
                if any(kd == d or kd.endswith("." + d) for kd in keep_ips):
                    kept_out.append((d, "suffix contains keep-list domain(s) - whole family kept out"))
                    continue
                pattern = r"^(\S+\.)?" + re.escape(d) + r"\.?$"
                regexes.append({"name": d, "pattern": pattern})
                for host in [d] + [h.strip().lower() for h in (meta.get("hosts") or [])]:
                    d_ips, ok = resolve_cached(host)
                    if not ok and not d_ips:
                        unresolved.append(host)
                        continue
                    for ip in d_ips:
                        if ip in protected:
                            kept_out.append((host, "IP %s shared with keep-list infrastructure" % ip))
                        else:
                            ips.add(ip)
                continue
            d_ips, ok = resolve_cached(d)
            domains.append(d)
            if not ok and not d_ips:
                unresolved.append(d)
                continue
            for ip in d_ips:
                if ip in protected:
                    kept_out.append((d, "IP %s shared with keep-list infrastructure" % ip))
                else:
                    ips.add(ip)
        return {"domains": sorted(domains),
                "regexes": regexes,
                "ips": sorted(ips),
                "unresolved": unresolved,
                "kept_out": [{"domain": d, "why": w} for d, w in kept_out]}

    print("Resolving %d standard-tier domains ..." % len(std_entries))
    standard = build_section(std_entries, "standard")
    print("Resolving %d standard-no-voice domains ..." % len(senv_entries))
    senv = build_section(senv_entries, "standard-no-voice")
    print("Resolving %d voice-tier domains (reference) ..." % len(voice_entries))
    voice = build_section(voice_entries, "voice")
    print("Resolving %d strict-tier domains ..." % len(strict_entries))
    strict = build_section(strict_entries, "strict")
    print("Resolving %d DoH endpoint domains ..." % len(doh_entries))
    doh = build_section(doh_entries, "doh")

    # --- Manufacturer deny-by-default (manufacturer-lockdown) -----------------
    # Samsung-owned zone + keep host      -> ALLOW (group-scoped allow row; FTL
    #                                          allow beats deny - regex is plain)
    # Samsung-owned zone + explicit deny  -> DENY (privacy-policy.yaml tiers)
    # Samsung-owned zone + anything else  -> DENY + LOG (zone regex in the group)
    # Non-Samsung domains                  -> untouched (normal egress)
    zones = [z["domain"].strip().lower() for z in (manuf.get("deny_default_zones") or [])]
    bad_zones = [z for z in zones if z not in KNOWN_SAMSUNG_ZONES]
    if bad_zones:
        sys.exit("FATAL: unknown zone(s) in config/manufacturer.yaml: %s - "
                 "a deny-by-default zone must be added to KNOWN_SAMSUNG_ZONES "
                 "in privacy-policy-build.py first (no silent new wildcards)."
                 % ", ".join(bad_zones))
    mkeep_hosts = sorted({k["domain"].strip().lower()
                          for k in (mkeep.get("keeps") or []) if (k.get("domain") or "").strip()})
    orphan = [h for h in mkeep_hosts if zone_of(h, zones) is None]
    if orphan:
        sys.exit("FATAL: manufacturer-keep host(s) outside any deny zone: %s "
                 "(a keep entry must sit inside a zone to have effect)."
                 % ", ".join(orphan))
    missing_keep = [d for d, _ in keep_domains if zone_of(d, zones) and d not in mkeep_hosts]
    if missing_keep:
        sys.exit("FATAL: privacy-keep domain(s) inside a deny zone but missing from "
                 "config/manufacturer-keep.yaml (the zone regex would silently deny them): %s"
                 % ", ".join(missing_keep))

    zone_regexes = []
    for z in zones:
        pat = zone_regex(z)
        zone_regexes.append({"name": z, "pattern": pat})
        # keep hosts inside the zone are protected by ALLOW rows (FTL allow
        # beats deny), not by the regex; the regex must still be a working
        # deny pattern: probe + apex must match.
        for probe in ("zz9probe." + z, z):
            if not re.match(pat, probe):
                sys.exit("FATAL: zone regex for %s fails to match probe %s (regex broken)"
                         % (z, probe))
        # this FTL build rejects lookaround - guard against reintroducing it
        if "(?" in pat:
            sys.exit("FATAL: zone regex for %s uses lookaround, which this FTL "
                     "build's validator rejects (RE2-style engine)" % z)

    # Explicit extra denies for manufacturer-lockdown (manufacturer-review.sh block)
    mlock_domains = set(senv["domains"])
    mlock_ips = set(senv["ips"])
    for e in (manuf.get("explicit_denies") or []):
        d = (e.get("domain") or "").strip().lower()
        if not d or d in keep_ips:
            continue
        mlock_domains.add(d)
        d_ips, _ = resolve_cached(d)
        for ip in d_ips:
            if ip not in protected:
                mlock_ips.add(ip)
    mlock = {
        "domains": sorted(mlock_domains),
        "regexes": senv["regexes"] + zone_regexes,
        "allows": mkeep_hosts,
        "ips": sorted(mlock_ips),
        "unresolved": senv["unresolved"],
        "kept_out": senv["kept_out"],
    }
    if set(mlock["domains"]) < set(senv["domains"]) or set(mlock["ips"]) < set(senv["ips"]):
        sys.exit("FATAL: manufacturer-lockdown section lost standard-no-voice entries")

    result = {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "resolver": resolver,
        "note": "IPv4 only. This deployment has no usable IPv6 Internet path "
                "(verified 2026-09: link-local only, no RA, no v6 default route).",
        "standard": standard,
        "standard-no-voice": senv,
        "voice": voice,
        "strict": strict,
        "doh": doh,
        "manufacturer-lockdown": mlock,
        "keep": {
            "domains": sorted(keep_ips.keys()),
            "ips": sorted(protected),
        },
        "manufacturer-zones": sorted(zones),
    }

    os.makedirs(OUTDIR, exist_ok=True)
    rj = os.path.join(OUTDIR, "resolved.json")
    with open(rj, "w", encoding="utf-8") as fh:
        json.dump(result, fh, indent=2)

    def section_md(name, sec):
        lines = ["## %s" % name, ""]
        lines.append("- domains: %d | resolved unique IPs: %d | unresolved: %d | kept-out: %d"
                     % (len(sec["domains"]), len(sec["ips"]), len(sec["unresolved"]), len(sec["kept_out"])))
        if sec["regexes"]:
            lines.append("")
            lines.append("Regex (suffix) denies - DNS layer, group-scoped:")
            for r in sec["regexes"]:
                lines.append("- `%s` (suffix %s)" % (r["pattern"], r["name"]))
        if sec["kept_out"]:
            lines.append("")
            lines.append("Kept out of the firewall set (keep-list wins):")
            for k in sec["kept_out"]:
                lines.append("- `%s` - %s" % (k["domain"], k["why"]))
        if sec["unresolved"]:
            lines.append("")
            lines.append("Unresolved (no rule generated; Pi-hole layer still applies): %s"
                         % ", ".join("`%s`" % d for d in sec["unresolved"]))
        if sec["ips"]:
            lines.append("")
            lines.append("Firewall IPs: " + ", ".join("`%s`" % i for i in sec["ips"]))
        lines.append("")
        return "\n".join(lines)

    md = ["# Privacy policy preview", ""]
    md.append("Generated %s via resolver %s." % (result["generated_at"], resolver))
    md.append("")
    md.append("Profiles: standard < standard-no-voice < strict by privacy-entry "
              "inclusion; manufacturer-lockdown = standard-no-voice + Samsung "
              "deny-by-default zones + essential Samsung allowlist (recommended).")
    md.append("STANDARD: ACR + advertising + high-confidence telemetry. "
              "DoT 853 dropped. DNS :53 forced to Pi-hole (TVGuard baseline).")
    md.append("")
    md.append("STANDARD-NO-VOICE = standard + confirmed Bixby/voice cloud "
              "(intentionally breaks cloud voice; no low-conf telemetry, no DoH-IP set).")
    md.append("")
    md.append("STRICT = standard-no-voice + low-confidence telemetry + DoH endpoint IPs.")
    md.append("")
    md.append("MANUFACTURER-LOCKDOWN (recommended) = standard-no-voice + %d Samsung "
              "deny-by-default zones + %d essential allow rows. Unknown Samsung "
              "hosts are DENIED+LOGGED by default (review: scripts/show-unknown-samsung.sh, "
              "scripts/manufacturer-review.sh). No strict low-conf additions, no new "
              "firewall IPs beyond the standard-no-voice set."
              % (len(zones), len(mkeep_hosts)))
    md.append("")
    md.append(section_md("standard", standard))
    md.append(section_md("standard-no-voice", senv))
    md.append(section_md("voice (reference, in standard-no-voice + strict)", voice))
    md.append(section_md("strict", strict))
    md.append(section_md("manufacturer-lockdown (recommended)", mlock))
    md.append(section_md("doh (strict only)", doh))
    md.append("## manufacturer-lockdown allow rows (keep wins, group-scoped)")
    md.append("")
    for a in mlock["allows"]:
        md.append("- allow `%s`" % a)
    md.append("")
    md.append("## keep (protected, never blocked)")
    md.append("")
    md.append("%d domains, %d protected IPs." % (len(result["keep"]["domains"]), len(result["keep"]["ips"])))
    md.append("")
    with open(os.path.join(OUTDIR, "preview.md"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(md))

    print("standard:            %d domains -> %d IPs (%d kept-out, %d unresolved)"
          % (len(standard["domains"]), len(standard["ips"]), len(standard["kept_out"]), len(standard["unresolved"])))
    print("standard-no-voice:   %d domains -> %d IPs (%d kept-out, %d unresolved)"
          % (len(senv["domains"]), len(senv["ips"]), len(senv["kept_out"]), len(senv["unresolved"])))
    print("voice (reference):   %d domains -> %d IPs" % (len(voice["domains"]), len(voice["ips"])))
    print("strict:              %d domains -> %d IPs (%d kept-out, %d unresolved)"
          % (len(strict["domains"]), len(strict["ips"]), len(strict["kept_out"]), len(strict["unresolved"])))
    print("doh:      %d domains -> %d IPs (%d kept-out, %d unresolved)"
          % (len(doh["domains"]), len(doh["ips"]), len(doh["kept_out"]), len(doh["unresolved"])))
    print("manufacturer-lockdown: %d domains -> %d IPs (%d zone regexes, %d allows)"
          % (len(mlock["domains"]), len(mlock["ips"]),
             len(mlock["regexes"]) - len(senv["regexes"]), len(mlock["allows"])))
    print("wrote %s and preview.md" % rj)


if __name__ == "__main__":
    main()
