#!/usr/bin/env python3
"""
privacy-policy-build.py - resolve config/privacy-policy.yaml to IPs.

Source of truth: config/privacy-policy.yaml (deny) and config/privacy-keep.yaml
(overrides). This script:

  1. Collects entries per tier:
       standard  = entries whose `tiers` include "standard"
       strict    = ALL entries (strict is the superset)
       doh       = the `doh` section (strict-only, IP-based)
  2. Resolves every domain against an EXTERNAL resolver (8.8.8.8 via dig) -
     deliberately NOT the local Pi-hole, which may return synthetic/empty
     answers for blocked domains.
  3. Applies keep-list overrides: an IP that is also used by a keep-list
     domain is removed from the deny sets (keep wins) and reported.
  4. Writes data/privacy-policy/resolved.json (consumed by tvguard-apply.sh)
     and data/privacy-policy/preview.md (human review).

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
OUTDIR = os.path.join(ROOT, "data", "privacy-policy")


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


def collect_tier_entries(doc):
    """Return (standard_domains, strict_domains, doh_domains) - strict is the superset."""
    std, strict, doh = [], [], []
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
            strict.append((d, e))
    # dedupe keeping order
    seen = set()
    uniq = []
    for d, e in std:
        if d not in seen:
            seen.add(d)
            uniq.append((d, e))
    return uniq, strict, doh


def main():
    resolver = sys.argv[1] if len(sys.argv) > 1 else "8.8.8.8"
    with open(POLICY, encoding="utf-8") as fh:
        policy = yaml.safe_load(fh)
    with open(KEEP, encoding="utf-8") as fh:
        keep = yaml.safe_load(fh)

    std_entries, strict_entries, doh_entries = collect_tier_entries(policy)
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

    def build_section(entries, label):
        domains, ips, unresolved, kept_out = [], set(), [], []
        for d, meta in entries:
            if d in keep_ips:
                kept_out.append((d, "keep-domain override"))
                continue
            d_ips, ok = resolve(d, resolver)
            time.sleep(0.05)
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
                "ips": sorted(ips),
                "unresolved": unresolved,
                "kept_out": [{"domain": d, "why": w} for d, w in kept_out]}

    print("Resolving %d standard-tier domains ..." % len(std_entries))
    standard = build_section(std_entries, "standard")
    print("Resolving %d strict-tier domains ..." % len(strict_entries))
    strict = build_section(strict_entries, "strict")
    print("Resolving %d DoH endpoint domains ..." % len(doh_entries))
    doh = build_section(doh_entries, "doh")

    result = {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "resolver": resolver,
        "note": "IPv4 only. This deployment has no usable IPv6 Internet path "
                "(verified 2026-09: link-local only, no RA, no v6 default route).",
        "standard": standard,
        "strict": strict,
        "doh": doh,
        "keep": {
            "domains": sorted(keep_ips.keys()),
            "ips": sorted(protected),
        },
    }

    os.makedirs(OUTDIR, exist_ok=True)
    rj = os.path.join(OUTDIR, "resolved.json")
    with open(rj, "w", encoding="utf-8") as fh:
        json.dump(result, fh, indent=2)

    def section_md(name, sec):
        lines = ["## %s" % name, ""]
        lines.append("- domains: %d | resolved unique IPs: %d | unresolved: %d | kept-out: %d"
                     % (len(sec["domains"]), len(sec["ips"]), len(sec["unresolved"]), len(sec["kept_out"])))
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
    md.append("STANDARD tier blocks: ACR + advertising + high-confidence telemetry. "
              "DoT 853 dropped. DNS :53 forced to Pi-hole (TVGuard baseline).")
    md.append("")
    md.append("STRICT tier = standard + voice/Bixby + low-confidence telemetry + DoH endpoint IPs.")
    md.append("")
    md.append(section_md("standard", standard))
    md.append(section_md("strict", strict))
    md.append(section_md("doh (strict only)", doh))
    md.append("## keep (protected, never blocked)")
    md.append("")
    md.append("%d domains, %d protected IPs." % (len(result["keep"]["domains"]), len(result["keep"]["ips"])))
    md.append("")
    with open(os.path.join(OUTDIR, "preview.md"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(md))

    print("standard: %d domains -> %d IPs (%d kept-out, %d unresolved)"
          % (len(standard["domains"]), len(standard["ips"]), len(standard["kept_out"]), len(standard["unresolved"])))
    print("strict:   %d domains -> %d IPs (%d kept-out, %d unresolved)"
          % (len(strict["domains"]), len(strict["ips"]), len(strict["kept_out"]), len(strict["unresolved"])))
    print("doh:      %d domains -> %d IPs (%d kept-out, %d unresolved)"
          % (len(doh["domains"]), len(doh["ips"]), len(doh["kept_out"]), len(doh["unresolved"])))
    print("wrote %s and preview.md" % rj)


if __name__ == "__main__":
    main()
