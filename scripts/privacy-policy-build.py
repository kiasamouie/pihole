#!/usr/bin/env python3
"""
privacy-policy-build.py - resolve the privacy policy configs to IPs (per vendor).

Multi-vendor privacy engine (see config/privacy-instances.yaml):
each vendor (samsung, lg, ...) is an INDEPENDENT policy instance with its own
  targets_key             (machine targets from config/tvguard.conf)
  policy file             (explicit tiered denies: ACR / ads / telemetry / voice)
  keep file               (global keep overrides - keep wins, IP-level)
  manufacturer file       (deny-by-default vendor-owned zones)
  manufacturer-keep file  (essential vendor allowlist -> group-scoped allow rows)

Samsung files stay where they always were (config/privacy-policy.yaml etc.);
LG lives under config/lgtv/. The resolved output is:

  data/privacy-policy/resolved.json
    vendors.<vendor>.{applies_to, standard, standard-no-voice, voice, strict,
                      doh, manufacturer-lockdown, keep, manufacturer-zones}
    + legacy top-level keys mirroring the SAMSUNG instance (backward
      compatibility for older consumers: standard, standard-no-voice, voice,
      strict, doh, manufacturer-lockdown, keep, manufacturer-zones, applies_to)

Per-vendor semantics (identical to the original single-vendor behaviour):
  standard  = entries whose `tiers` include "standard"
  senv      = standard + "voice" tiers (the standard-no-voice profile)
  voice     = entries whose `tiers` include "voice" (reference list)
  strict    = ALL entries (strict is the superset)
  doh       = the `doh` section (strict-only, IP-based)
  mlock     = senv + deny-by-default vendor zones (regex) + vendor allowlist
              (allows); the recommended manufacturer-lockdown profile. It
              deliberately does NOT inherit strict's low-confidence additions
              or the DoH-IP set.

Resolution: every domain is resolved against an EXTERNAL resolver (8.8.8.8 via
dig), never the local Pi-hole. A domain shared by several vendors is resolved
once (shared cache). Keep-list IP collisions are excluded from the firewall
deny set per vendor (keep wins).

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

from tvguard_target_config import TargetConfigError, load_target_config

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INSTANCES = os.path.join(ROOT, "config", "privacy-instances.yaml")
OUTDIR = os.path.join(ROOT, "data", "privacy-policy")

# Anti-wildcard guard (cross-vendor): a deny-by-default zone must NEVER be a
# shared infrastructure provider. The per-vendor allowlists live in
# config/privacy-instances.yaml (known_zones); this list additionally blocks
# the obvious cloud/CDN/corporate zones outright, so even a reviewed registry
# change cannot turn e.g. *.amazonaws.com or *.cloudfront.net into a deny
# zone (Prime/Netflix/YouTube content lives on exactly that infrastructure).
FORBIDDEN_ZONES = {
    "amazonaws.com", "amazon.com", "a2z.com", "cloudfront.net",
    "google.com", "googlevideo.com", "ggpht.com", "googleusercontent.com",
    "gstatic.com", "doubleclick.net", "googlesyndication.com",
    "azure.com", "azureedge.net", "akamai.net", "akamaiedge.net",
    "fastly.net", "cloudflare.com", "cf-ssl.com", "netflix.com",
    "samsungqbe.com",  # documented breakage (Perflyst #82), never a zone
}


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
    r"""Deny-by-default regex for one vendor zone (generic over vendors).

    Generated form:
      ^(([A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*)?\.)?samsungcloudsolution\.com\.?$
    - www.samsungcloudsolution.com   -> MATCHES (denied, unknown vendor host)
    - samsungcloudsolution.com       -> apex also denied (label part optional)
    Keep hosts inside the zone are NOT exempted in the regex: this FTL
    build's regex validator rejects lookaround (RE2-style engine, verified
    2026-09-21), and keep protection is carried by the group-scoped Pi-hole
    ALLOW rows (allow beats deny in FTL; proven by the selftest's keep-host
    resolution test, per vendor). Sublabels of a keep host (x.time.\u2026) are
    NOT auto-allowed - allow explicitly via manufacturer-review.sh if needed.
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
        if not isinstance(spec, dict):
            continue
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


def build_vendor(vname, vcfg, targets, resolver, cache):
    """Resolve one vendor instance completely. Returns the vendor section dict."""
    policy = yaml.safe_load(open(os.path.join(ROOT, vcfg["policy"]), encoding="utf-8"))
    keep = yaml.safe_load(open(os.path.join(ROOT, vcfg["keep"]), encoding="utf-8"))
    manuf = yaml.safe_load(open(os.path.join(ROOT, vcfg["manufacturer"]), encoding="utf-8"))
    mkeep = yaml.safe_load(open(os.path.join(ROOT, vcfg["manufacturer_keep"]), encoding="utf-8"))

    def resolve_cached(d):
        if d not in cache:
            cache[d] = resolve(d, resolver)
            time.sleep(0.05)
        return cache[d]

    std_entries, senv_entries, voice_entries, strict_entries, doh_entries = collect_tier_entries(policy)
    keep_domains = [(k["domain"].strip().lower(), k) for k in (keep.get("keeps") or [])]

    # Keep domains resolve first: their IP space is protected (per vendor).
    keep_ips = {}
    for d, meta in keep_domains:
        keep_ips[d] = resolve_cached(d)[0]
    protected = set()
    for d, ips in keep_ips.items():
        for ip in ips:
            protected.add(ip)

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
                if "(?" in pattern:
                    sys.exit("FATAL: [%s] suffix regex for %s uses lookaround (rejected by this FTL build)" % (vname, d))
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

    standard = build_section(std_entries, "standard")
    senv = build_section(senv_entries, "standard-no-voice")
    voice = build_section(voice_entries, "voice")
    strict = build_section(strict_entries, "strict")
    doh = build_section(doh_entries, "doh")

    # --- Manufacturer deny-by-default for this vendor ---------------------
    zones = [z["domain"].strip().lower() for z in (manuf.get("deny_default_zones") or [])]
    bad_zones = [z for z in zones if z not in set(vcfg.get("known_zones") or [])]
    if bad_zones:
        sys.exit("FATAL: [%s] unknown zone(s) in %s: %s - a deny-by-default zone "
                 "must be added to the %s entry of config/privacy-instances.yaml "
                 "(known_zones) first (no silent new wildcards)."
                 % (vname, vcfg["manufacturer"], ", ".join(bad_zones), vname))
    forbidden = [z for z in zones if z in FORBIDDEN_ZONES]
    if forbidden:
        sys.exit("FATAL: [%s] zone(s) in FORBIDDEN_ZONES (shared infrastructure, "
                 "never a deny-default zone): %s" % (vname, ", ".join(forbidden)))
    mkeep_hosts = sorted({k["domain"].strip().lower()
                          for k in (mkeep.get("keeps") or []) if (k.get("domain") or "").strip()})
    orphan = [h for h in mkeep_hosts if zone_of(h, zones) is None]
    if orphan:
        sys.exit("FATAL: [%s] manufacturer-keep host(s) outside any deny zone: %s "
                 "(a keep entry must sit inside a zone to have effect)."
                 % (vname, ", ".join(orphan)))
    missing_keep = [d for d, _ in keep_domains if zone_of(d, zones) and d not in mkeep_hosts]
    if missing_keep:
        sys.exit("FATAL: [%s] privacy-keep domain(s) inside a deny zone but missing from "
                 "the manufacturer-keep file (the zone regex would silently deny them): %s"
                 % (vname, ", ".join(missing_keep)))

    zone_regexes = []
    for z in zones:
        pat = zone_regex(z)
        zone_regexes.append({"name": z, "pattern": pat})
        for probe in ("zz9probe." + z, z):
            if not re.match(pat, probe):
                sys.exit("FATAL: [%s] zone regex for %s fails to match probe %s (regex broken)"
                         % (vname, z, probe))
        if "(?" in pat:
            sys.exit("FATAL: [%s] zone regex for %s uses lookaround, which this FTL "
                     "build's validator rejects (RE2-style engine)" % (vname, z))

    # A zone that is ALREADY carried by a `kind: suffix` entry in the policy
    # (e.g. lgsmartad.com / alphonso.tv in the LG policy: ACR+ad suffix in the
    # standard tier AND an mlock deny zone) must not get a second, near-
    # identical zone regex: the suffix regex is already pushed to the Pi-hole
    # group by every profile >= standard, and the zone regex is functionally
    # equivalent for the same zone. Skip the duplicate zone regex.
    suffix_names = {r["name"] for r in senv["regexes"]}
    zone_regexes = [r for r in zone_regexes if r["name"] not in suffix_names]

    # Explicit extra denies for manufacturer-lockdown (manufacturer-review.sh block)
    mlock_domains = set(senv["domains"])
    mlock_ips = set(senv["ips"])
    mlock_unresolved = list(senv["unresolved"])
    for e in (manuf.get("explicit_denies") or []):
        d = (e.get("domain") or "").strip().lower()
        if not d or d in keep_ips:
            continue
        mlock_domains.add(d)
        d_ips, _ = resolve_cached(d)
        if not d_ips:
            mlock_unresolved.append(d)
        for ip in d_ips:
            if ip not in protected:
                mlock_ips.add(ip)
    mlock = {
        "domains": sorted(mlock_domains),
        "regexes": senv["regexes"] + zone_regexes,
        "allows": mkeep_hosts,
        "ips": sorted(mlock_ips),
        "unresolved": sorted(set(mlock_unresolved)),
        "kept_out": senv["kept_out"],
    }
    if set(mlock["domains"]) < set(senv["domains"]) or set(mlock["ips"]) < set(senv["ips"]):
        sys.exit("FATAL: [%s] manufacturer-lockdown section lost standard-no-voice entries" % vname)

    return {
        "label": vcfg.get("label", vname),
        "targets_key": vcfg["targets_key"],
        "active": bool(targets),
        "applies_to": list(targets),
        "standard": standard,
        "standard-no-voice": senv,
        "voice": voice,
        "strict": strict,
        "doh": doh,
        "manufacturer-lockdown": mlock,
        "keep": {"domains": sorted(keep_ips.keys()), "ips": sorted(protected)},
        "manufacturer-zones": sorted(zones),
        "pihole_group": vcfg.get("pihole_group", "TVGuard-Privacy-%s" % vname.upper()),
    }


def main():
    resolver = sys.argv[1] if len(sys.argv) > 1 else "8.8.8.8"
    with open(INSTANCES, encoding="utf-8") as fh:
        inst = yaml.safe_load(fh)
    instances = inst.get("instances") or {}
    if not instances:
        sys.exit("FATAL: no instances in config/privacy-instances.yaml")
    try:
        target_config = load_target_config(instances, root=ROOT)
    except TargetConfigError as exc:
        sys.exit("FATAL: %s" % exc)

    # Cross-vendor registry sanity: two vendors must never share a zone (a
    # shared zone would make the per-vendor allow/deny semantics ambiguous).
    seen_zones = {}
    for v, vcfg in instances.items():
        for z in vcfg.get("known_zones") or []:
            z = z.lower()
            if z in seen_zones:
                sys.exit("FATAL: zone %s claimed by both vendors %s and %s"
                         % (z, seen_zones[z], v))
            seen_zones[z] = v
        for f in ("policy", "keep", "manufacturer", "manufacturer_keep"):
            if not os.path.exists(os.path.join(ROOT, vcfg[f])):
                sys.exit("FATAL: vendor %s config file missing: %s" % (v, vcfg[f]))

    cache = {}
    vendors = {}
    for vname, vcfg in instances.items():
        targets = target_config.vendor_targets[vname]
        status = ", ".join(targets) if targets else "<empty - inactive>"
        print("=== vendor: %s (%s) ===" % (vname, vcfg.get("label", "")))
        print("Targets (%s): %s" % (vcfg["targets_key"], status))
        print("Resolving keep-list + policy domains via %s ..." % resolver)
        vendors[vname] = build_vendor(vname, vcfg, targets, resolver, cache)

    s = vendors["samsung"] if "samsung" in vendors else None

    result = {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "resolver": resolver,
        "note": "Multi-vendor privacy policy. Per-vendor sections are under "
                "'vendors'. Top-level keys (standard, ... , applies_to) are "
                "LEGACY ALIASES mirroring the samsung instance for older "
                "consumers; use vendors.<vendor> for new code.",
        "vendors": vendors,
    }
    if s:
        # Legacy top-level samsung aliases (backward compatibility).
        result["applies_to"] = s["applies_to"]
        result["standard"] = s["standard"]
        result["standard-no-voice"] = s["standard-no-voice"]
        result["voice"] = s["voice"]
        result["strict"] = s["strict"]
        result["doh"] = s["doh"]
        result["manufacturer-lockdown"] = s["manufacturer-lockdown"]
        result["keep"] = s["keep"]
        result["manufacturer-zones"] = s["manufacturer-zones"]

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

    md = ["# Privacy policy preview (multi-vendor)", ""]
    md.append("Generated %s via resolver %s." % (result["generated_at"], resolver))
    md.append("")
    md.append("Vendors: %s. Each vendor is an independent instance (own "
              "client scope, own Pi-hole group, own firewall sets, own state "
              "line - see config/privacy-instances.yaml)."
              % ", ".join(vendors.keys()))
    md.append("")
    md.append("Profiles per vendor: standard < standard-no-voice < strict by "
              "privacy-entry inclusion; manufacturer-lockdown = "
              "standard-no-voice + vendor deny-by-default zones + vendor "
              "allowlist (recommended). DoT 853 dropped, DNS :53 forced to "
              "Pi-hole, in every active profile, per vendor scope only.")
    md.append("")
    for vname, v in vendors.items():
        mlock = v["manufacturer-lockdown"]
        senv = v["standard-no-voice"]
        md.append("# vendor: %s" % vname)
        md.append("")
        md.append("Targets (%s): %s | status: %s | Pi-hole group: %s | zones: %d | allow rows: %d"
                  % (v["targets_key"], ", ".join(v["applies_to"]) or "<empty>",
                     "active" if v["active"] else "inactive", v["pihole_group"],
                     len(v["manufacturer-zones"]), len(mlock["allows"])))
        md.append("")
        md.append(section_md("%s / standard" % vname, v["standard"]))
        md.append(section_md("%s / standard-no-voice" % vname, senv))
        md.append(section_md("%s / voice (reference)" % vname, v["voice"]))
        md.append(section_md("%s / strict" % vname, v["strict"]))
        md.append(section_md("%s / manufacturer-lockdown (recommended)" % vname, mlock))
        md.append(section_md("%s / doh (strict only)" % vname, v["doh"]))
        md.append("## %s - manufacturer-lockdown allow rows (keep wins, group-scoped)" % vname)
        md.append("")
        for a in mlock["allows"]:
            md.append("- allow `%s`" % a)
        md.append("")
        md.append("## %s - keep (protected, never blocked)" % vname)
        md.append("")
        md.append("%d domains, %d protected IPs." % (len(v["keep"]["domains"]), len(v["keep"]["ips"])))
        md.append("")
    with open(os.path.join(OUTDIR, "preview.md"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(md))

    for vname, v in vendors.items():
        mlock = v["manufacturer-lockdown"]
        print("%s / standard:            %d domains -> %d IPs (%d kept-out, %d unresolved)"
              % (vname, len(v["standard"]["domains"]), len(v["standard"]["ips"]),
                 len(v["standard"]["kept_out"]), len(v["standard"]["unresolved"])))
        print("%s / standard-no-voice:   %d domains -> %d IPs (%d kept-out, %d unresolved)"
              % (vname, len(v["standard-no-voice"]["domains"]), len(v["standard-no-voice"]["ips"]),
                 len(v["standard-no-voice"]["kept_out"]), len(v["standard-no-voice"]["unresolved"])))
        print("%s / voice (reference):   %d domains -> %d IPs" % (vname, len(v["voice"]["domains"]), len(v["voice"]["ips"])))
        print("%s / strict:              %d domains -> %d IPs (%d kept-out, %d unresolved)"
              % (vname, len(v["strict"]["domains"]), len(v["strict"]["ips"]),
                 len(v["strict"]["kept_out"]), len(v["strict"]["unresolved"])))
        print("%s / doh:                  %d domains -> %d IPs (%d kept-out, %d unresolved)"
              % (vname, len(v["doh"]["domains"]), len(v["doh"]["ips"]),
                 len(v["doh"]["kept_out"]), len(v["doh"]["unresolved"])))
        print("%s / manufacturer-lockdown: %d domains -> %d IPs (%d zone regexes, %d allows)"
              % (vname, len(mlock["domains"]), len(mlock["ips"]),
                 len(mlock["regexes"]) - len(v["standard-no-voice"]["regexes"]), len(mlock["allows"])))
    print("wrote %s and preview.md" % rj)


if __name__ == "__main__":
    main()
