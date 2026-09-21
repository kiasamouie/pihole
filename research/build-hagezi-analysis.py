#!/usr/bin/env python3
"""
build-hagezi-analysis.py - cross-reference the HaGeZi Samsung native tracker
list against (a) our own observed Samsung traffic, (b) three other maintained
smart-TV blocklists, and (c) the local privacy policy + never-block lists.

Output: research/github/hagezi-samsung-analysis.csv (committed research data).

Every row records provenance so a future reviewer can see *why* a domain got
its candidate policy. Nothing here is automatically applied - it feeds
config/privacy-policy.yaml and reports/07-github-cross-reference.md.

Usage:  python3 research/build-hagezi-analysis.py
"""
import csv
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SNAP = os.path.join(ROOT, "research", "github", "snapshots")
OUT = os.path.join(ROOT, "research", "github", "hagezi-samsung-analysis.csv")


def load_list(path):
    names = set()
    if not os.path.exists(path):
        return names
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.split("#", 1)[0].strip()
            if not line or line.lower().startswith("include"):
                continue
            # DNSMasq 'local=/domain/' entries (HaGeZi format)
            if line.startswith("local=/"):
                d = line[len("local=/"):].rstrip("/").strip()
                if d:
                    names.add(d.lower())
                continue
            # hosts format '0.0.0.0 domain' (BlocklistProject format)
            parts = line.split()
            if len(parts) == 2 and parts[0].count(".") == 3 and all(c in "0123456789." for c in parts[0]):
                names.add(parts[1].lower())
                continue
            names.add(parts[0].lower())
    return names


def load_yaml_value(path, key):
    vals = set()
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            m = re.match(r"\s*(?:-\s+)?%s:\s*(\S+)" % re.escape(key), line)
            if m:
                vals.add(m.group(1).strip('"').lower())
    return vals


# --- sources -----------------------------------------------------------------
hagezi = load_list(os.path.join(SNAP, "hagezi-native-samsung.txt"))
perflyst = load_list(os.path.join(SNAP, "perflyst-smarttv.txt"))
blocklistproject = load_list(os.path.join(SNAP, "blocklistproject-smart-tv.txt"))
marq24 = load_list(os.path.join(SNAP, "marq24-samsung-smart-tv.txt"))
fightback = load_list(os.path.join(SNAP, "fightback-tv-core.txt"))

observed = load_yaml_value(os.path.join(ROOT, "config", "destinations.yaml"), "domain")

# Local policy (source of truth: config/privacy-policy.yaml).
policy = {
    "deny-standard": load_yaml_value(os.path.join(ROOT, "config", "privacy-policy.yaml"), "domain"),
}
# Split by tier: re-parse the YAML properly for tier membership.
import yaml  # noqa: E402  (PyYAML is a project dependency)

with open(os.path.join(ROOT, "config", "privacy-policy.yaml"), encoding="utf-8") as fh:
    pdoc = yaml.safe_load(fh)

deny_std, deny_strict = set(), set()
for tier, spec in (pdoc.get("policies") or {}).items():
    for e in spec.get("entries", []) or []:
        d = (e.get("domain") or "").lower()
        if not d:
            continue
        tiers = e.get("tiers", [tier])
        for t in tiers:
            if t == "standard":
                deny_std.add(d)
            elif t == "strict":
                deny_strict.add(d)

keep = load_yaml_value(os.path.join(ROOT, "config", "privacy-keep.yaml"), "domain")

NEVER_BLOCK = {
    "time.samsungcloudsolution.com",
    "auth.samsungosp.com",
    "lcprd1.samsungcloudsolution.net",
    "osb-ussvc.samsungqbe.com",
}
# whole families that multiple sources say break the TV if blocked:
NEVER_BLOCK_FAMILIES = {
    "samsungosp.com": "Samsung account/auth + push (Perflyst: breaks sign-in/push)",
    "samsungqbe.com": "QBE app/TV-Plus infra (Perflyst #82: broke YouTube/Prime)",
    "samsungcloudsolution.com": "mixed: contains time/, notice/, oemp... family-level block unsafe",
    "samsungcloudsolution.net": "mixed: contains lcprd1 (Smart Hub), configprd, otnprd*",
    "samsungelectronics.com": "brand-wide, shared marketing+service infra",
}


def other_lists(d):
    hits = []
    if d in perflyst:
        hits.append("perflyst")
    if d in blocklistproject:
        hits.append("blocklistproject")
    if d in marq24:
        hits.append("marq24")
    if d in fightback:
        hits.append("fightback")
    return ",".join(hits) if hits else "-"


def purpose(d):
    if d == "acr0.samsungcloudsolution.com" or (d.startswith("acr-") and d.endswith("samsungcloud.tv")):
        return "Samsung ACR (Automatic Content Recognition) endpoint"
    if d.endswith("samsungacr.com"):
        return "Samsung ACR log ingestion/config"
    if "adgrx" in d:
        return "Programmatic ad exchange (AdGRX)"
    if d.endswith("samsungads.com") or d.endswith("samsungadhub.com") or d.endswith("samsungtvads.com") or "openx" in d:
        return "Samsung/ad-network advertising"
    if "aibixby" in d or d.endswith("samsungbixby.com"):
        return "Bixby voice cloud"
    if d.endswith("samsungqbe.com"):
        return "QBE app platform (Smart Hub apps, TV Plus)"
    if d.endswith("samsungosp.com"):
        return "Samsung account/auth + push (OSP)"
    if "samsungcloud" in d:
        return "Samsung cloud service (content/telemetry mix - check subdomain)"
    if d.endswith("samsung.com"):
        return "Samsung service (mixed - check subdomain)"
    if d.endswith("samsungcloudcdn.com") or d.endswith("samsungotn.net") or d.endswith("samsungnyc.com"):
        return "Samsung CDN/content delivery"
    if "doubleclick" in d or "2mdn" in d:
        return "Google ad infrastructure"
    if d.endswith("onetrust.io") or "cookie" in d or "consent" in d:
        return "Consent/cookie management"
    return "-"


def row(d):
    in_hagezi = d in hagezi
    seen = d in observed
    ol = other_lists(d)
    src_count = sum(x != "-" for x in [ol, in_hagezi and "x", seen and "x"])
    if d in NEVER_BLOCK:
        cand = "keep-never-block"
    elif d in deny_std:
        cand = "deny-standard"
    elif d in deny_strict:
        cand = "deny-strict"
    elif d in keep:
        cand = "keep"
    else:
        cand = "unknown-review"
    if d in NEVER_BLOCK or any(d.endswith(f) for f in NEVER_BLOCK_FAMILIES):
        risk = "high"
    elif cand.startswith("deny"):
        risk = "low" if (seen or src_count >= 2) else "medium"
    elif cand == "unknown-review":
        risk = "medium"
    else:
        risk = "low"
    conf = "high" if src_count >= 3 else ("medium" if src_count == 2 else "low")
    return [d, "yes" if in_hagezi else "no", "yes" if seen else "no",
            ol, purpose(d), risk, conf, cand]


def main():
    all_domains = sorted(hagezi | observed)
    with open(OUT, "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["domain", "present-in-hagezi", "seen-on-my-tv", "also-in-other-list",
                    "known-purpose", "risk", "confidence", "candidate-policy"])
        for d in all_domains:
            w.writerow(row(d))

    # summary for the report
    cands = {}
    for d in all_domains:
        c = row(d)[-1]
        cands[c] = cands.get(c, 0) + 1
    print("hagezi entries: %d | observed: %d | union: %d" % (len(hagezi), len(observed), len(all_domains)))
    print("observed also in hagezi: %d" % len(hagezi & observed))
    print("observed also in >=1 other list: %d" % len([d for d in observed if other_lists(d) != "-"]))
    print("candidate policy counts: %s" % dict(sorted(cands.items())))
    print("wrote %s" % OUT)


if __name__ == "__main__":
    sys.exit(main())
