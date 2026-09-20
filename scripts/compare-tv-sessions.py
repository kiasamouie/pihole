#!/usr/bin/env python3
"""
compare-tv-sessions.py — compare two or more TV-session capture directories.

Usage:
    python3 scripts/compare-tv-sessions.py DIR1 DIR2 [DIR3 ...] [--out FILE]

Each DIR is a directory produced by scripts/tv-session.sh (contains
connections.csv, dns.csv, metadata.json).

Prints (and with --out, writes) a markdown report that deliberately
SEPARATES three kinds of statement:

  OBSERVED      — raw facts from the captures (counts, bytes, presence/absence)
  INFERENCE     — generated, generic, low-confidence reading of those facts
  CLASSIFICATION — ONLY from config/destinations.yaml (the evidence ledger).
                   Nothing is auto-labelled "telemetry/spyware" from a hostname.

No network access is performed; this is pure offline analysis.
"""

import argparse
import csv
import os
import re
import sys
from datetime import datetime, timezone

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load_session(d):
    s = {"dir": d, "label": os.path.basename(d), "tv": "?", "flows": {}, "bytes": {},
         "domains": {}, "statuses": {}, "n_flows": 0, "n_domains": 0}
    try:
        import json
        with open(os.path.join(d, "metadata.json")) as fh:
            meta = json.load(fh)
        s["label"] = meta.get("label", s["label"])
        s["tv"] = meta.get("tv", "?")
    except (OSError, ValueError):
        pass
    cpath = os.path.join(d, "connections.csv")
    if os.path.exists(cpath):
        with open(cpath, newline="") as fh:
            for row in csv.DictReader(fh):
                if row.get("direction") != "out":
                    continue
                key = (row["dst_ip"], row["dst_port"], row["proto"])
                f = s["flows"].setdefault(key, 0)
                s["flows"][key] = f + 1
                try:
                    by = int(row.get("bytes_original_dir", 0)) + int(row.get("bytes_reply_dir", 0))
                except ValueError:
                    by = 0
                s["bytes"][key] = s["bytes"].get(key, 0) + by
                s["n_flows"] += 1
    dpath = os.path.join(d, "dns.csv")
    if os.path.exists(dpath):
        with open(dpath, newline="") as fh:
            for row in csv.DictReader(fh):
                dom = row.get("domain", "")
                if not dom:
                    continue
                s["domains"][dom] = s["domains"].get(dom, 0) + 1
                s["statuses"].setdefault(dom, set()).add(row.get("status", "?"))
                s["n_domains"] += 1
    return s


def load_ledger():
    """Parse config/destinations.yaml (minimal parser; no external deps).

    Returns list of dicts with at least: domain, class, confidence, evidence.
    """
    path = os.path.join(REPO, "config", "destinations.yaml")
    entries = []
    if not os.path.exists(path):
        return entries
    cur = {}
    with open(path) as fh:
        for line in fh:
            if line.lstrip().startswith("#"):
                continue
            m = re.match(r"\s*-\s*domain:\s*(\S+)", line)
            if m:
                if cur.get("domain"):
                    entries.append(cur)
                cur = {"domain": m.group(1).strip('"'), "ip": "", "class": "",
                       "confidence": "", "evidence": "", "source": ""}
                continue
            m = re.match(r"\s*(ip|class|confidence|evidence|source):\s*(.*)", line)
            if m and cur.get("domain"):
                cur[m.group(1)] = m.group(2).strip().strip('"')
    if cur.get("domain"):
        entries.append(cur)
    return entries


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dirs", nargs="+")
    ap.add_argument("--out", help="write report to this file (also printed)")
    args = ap.parse_args()

    sessions = [load_session(d) for d in args.dirs]
    if len(sessions) < 2:
        sys.exit("need at least two session directories")

    all_flow_keys = set()
    all_domains = set()
    for s in sessions:
        all_flow_keys |= set(s["flows"])
        all_domains |= set(s["domains"])

    ledger = {e["domain"]: e for e in load_ledger() if e.get("domain")}

    L = []
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    L.append(f"# TV session comparison — {now} UTC")
    L.append("")
    L.append("## Session overview")
    L.append("")
    L.append("| session | tv | flows (out) | unique dst:port | unique domains | total dst bytes* |")
    L.append("|---|---|---|---|---|---|")
    for s in sessions:
        L.append(f"| {s['label']} | {s['tv']} | {s['n_flows']} | {len(s['flows'])} "
                 f"| {len(s['domains'])} | {sum(s['bytes'].values())} |")
    L.append("")
    L.append("\\* bytes only for flows that CLOSED inside the window (conntrack reports "
             "cumulative bytes on DESTROY); long-lived flows show 0. The nft counter "
             "deltas in each session's summary.md are the reliable aggregate.")
    L.append("")

    L.append("## OBSERVED — outbound destinations unique to each session")
    L.append("")
    L.append("Destinations seen in ONE session and in NO other session:")
    L.append("")
    any_unique = False
    for s in sessions:
        others = set()
        for o in sessions:
            if o is not s:
                others |= set(o["flows"])
        uniq = set(s["flows"]) - others
        if uniq:
            any_unique = True
            L.append(f"### only in `{s['label']}`")
            L.append("")
            L.append("| dst | port | proto | flows | bytes* |")
            L.append("|---|---|---|---|---|")
            for k in sorted(uniq, key=lambda k: -s["bytes"].get(k, 0)):
                ip, port, proto = k
                L.append(f"| {ip} | {port} | {proto} | {s['flows'][k]} | {s['bytes'].get(k, 0)} |")
            L.append("")
    if not any_unique:
        L.append("(none — every destination appeared in more than one session)\n")

    common_flows = set(all_flow_keys)
    for s in sessions:
        common_flows &= set(s["flows"])
    L.append("## OBSERVED — destinations common to ALL sessions")
    L.append("")
    if common_flows:
        L.append("| dst | port | proto | " + " | ".join(s["label"] for s in sessions) + " |")
        L.append("|---|---|---|" + "---|" * len(sessions))
        for k in sorted(common_flows, key=lambda k: -sum(s["bytes"].get(k, 0) for s in sessions)):
            ip, port, proto = k
            L.append(f"| {ip} | {port} | {proto} | " +
                     " | ".join(str(s["flows"].get(k, 0)) for s in sessions) + " |")
    else:
        L.append("(none)")
    L.append("")

    L.append("## OBSERVED — connection frequency matrix (flows per session)")
    L.append("")
    L.append("| dst:port | proto | " + " | ".join(s["label"] for s in sessions) + " |")
    L.append("|---|---|" + "---|" * len(sessions))
    for k in sorted(all_flow_keys, key=lambda k: -sum(s["flows"].get(k, 0) for s in sessions)):
        ip, port, proto = k
        L.append(f"| {ip}:{port} | {proto} | " +
                 " | ".join(str(s["flows"].get(k, 0)) for s in sessions) + " |")
    L.append("")

    L.append("## OBSERVED — DNS domains unique / common")
    L.append("")
    any_d = False
    for s in sessions:
        others = set()
        for o in sessions:
            if o is not s:
                others |= set(o["domains"])
        uniq = set(s["domains"]) - others
        if uniq:
            any_d = True
            top = sorted(uniq, key=lambda d: -s["domains"][d])
            shown = ", ".join(f"{d} ({s['domains'][d]})" for d in top[:20])
            more = f" +{len(top)-20} more" if len(top) > 20 else ""
            L.append(f"- **only in `{s['label']}`**: {shown}{more}")
    if not any_d:
        L.append("- (no unique domains)")
    common_dom = set(all_domains)
    for s in sessions:
        common_dom &= set(s["domains"])
    L.append("")
    if common_dom:
        L.append("- **common to all**: " + ", ".join(sorted(common_dom)))
    else:
        L.append("- (no domains common to all sessions)")
    L.append("")

    L.append("## INFERENCE (auto-generated — low confidence, NOT a classification)")
    L.append("")
    for s in sessions:
        others = set()
        for o in sessions:
            if o is not s:
                others |= set(o["flows"]) | set(o["domains"])
        uniq = set(s["flows"]) - (set().union(*[set(o["flows"]) for o in sessions if o is not s]) or {None})
        if uniq:
            L.append(f"- Destinations appearing only during `{s['label']}` are *consistent with* "
                     f"that activity, but a single pair of sessions cannot prove causation. "
                     f"Repeat the session pair to confirm stability before acting on it.")
    L.append("- A destination common to idle AND active sessions is *likely* background "
             "traffic, but may also be needed by any app the TV runs; confirm before blocking.")
    L.append("")

    L.append("## CLASSIFICATION (only from config/destinations.yaml — the evidence ledger)")
    L.append("")
    if ledger:
        L.append("Ledger entries that match what was observed in these sessions:")
        L.append("")
        L.append("| domain | class | confidence | ledger evidence | observed here |")
        L.append("|---|---|---|---|---|")
        matched = False
        for dom, e in ledger.items():
            seen = dom in all_domains
            if seen:
                matched = True
                where = ", ".join(s["label"] for s in sessions if dom in s["domains"])
                L.append(f"| {dom} | {e.get('class','?')} | {e.get('confidence','?')} "
                         f"| {e.get('evidence','')} | yes — {where} |")
        if not matched:
            L.append("(no ledger entries matched the observed traffic)")
        L.append("")
        L.append("Everything else observed is **UNCLASSIFIED** until evidence is recorded in "
                 "`config/destinations.yaml`. Do not block on hostname similarity alone.")
    else:
        L.append("(destinations.yaml has no entries yet — everything observed is unclassified)")
    L.append("")

    report = "\n".join(L)
    print(report)
    if args.out:
        with open(args.out, "w") as fh:
            fh.write(report + "\n")
        print(f"\n(written to {args.out})")


if __name__ == "__main__":
    main()
