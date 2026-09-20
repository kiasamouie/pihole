#!/usr/bin/env python3
"""
session_analyze.py — turn raw TV-session recordings into usable artifacts.

Invoked by scripts/tv-session.sh:

    session_analyze.py OUTDIR TVNAME TVIP LABEL DURATION_S T_START T_END [MODE]

Reads (from OUTDIR):
    events.log              timestamped `conntrack -E` lines
    nft-counters-start.txt  "pkts bytes rulename" lines
    nft-counters-end.txt
    pihole-queries.json     list of Pi-hole v6 API query objects

Writes (into OUTDIR):
    connections.csv         one row per flow touching the TV (metadata only)
    dns.csv                 Pi-hole query rows for the window
    summary.md              human digest (unique dsts, top talkers, DNS)
    metadata.json           session parameters + nft counter deltas

Scope: connection/DNS metadata only. No payload is ever read.
"""

import csv
import json
import re
import sys
from datetime import datetime, timezone

# ---------------------------------------------------------------------------

CT_LINE = re.compile(
    r"^(\d+)\s+\[(NEW|UPDATE|DESTROY)\]\s+(\S+)\s+(\d+)\s+\d+\s+(.*)$"
)
STATE_TOKENS = ("UNREPLIED", "CONFIRMED", "ASSUMED", "UNCONFIRMED", "STREAM_OFF")


def parse_conntrack_events(path):
    """Parse `conntrack -E` lines prefixed with a unix epoch.

    Event format (per direction, original first):
      [NEW] udp 17 30 src=... dst=... sport=... dport=... [UNREPLIED] src=... dst=... sport=... dport=...
      [DESTROY] ... [bytes=N pkts=N] [bytes=N pkts=N]   (original, then reply direction)

    Returns dict keyed by (proto, src, dst, osport, odport) with first/last
    timestamp, latest state, and original/reply-direction bytes+packets from
    the most recent UPDATE/DESTROY (conntrack reports cumulative counters).
    """
    flows = {}
    if not path:
        return flows
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            m = CT_LINE.match(line.strip())
            if not m:
                continue
            ts, event, proto, _proto_num, kv = m.groups()
            ts = int(ts)
            src_m = re.search(r"\bsrc=([0-9.]+)", kv)
            dst_m = re.search(r"\bdst=([0-9.]+)", kv)
            if not src_m or not dst_m:
                continue
            src, dst = src_m.group(1), dst_m.group(1)
            ports = re.findall(r"\bsport=(\d+) dport=(\d+)", kv)
            if not ports:
                continue
            osport, odport = ports[0]
            key = (proto, src, dst, osport, odport)
            f = flows.setdefault(key, {
                "first_ts": ts, "last_ts": ts, "state": "",
                "orig_pkts": 0, "orig_bytes": 0, "reply_bytes": 0,
            })
            f["last_ts"] = max(f["last_ts"], ts)
            f["first_ts"] = min(f["first_ts"], ts)
            st = re.search(r"\[(" + "|".join(STATE_TOKENS) + r")\]", kv)
            if st:
                f["state"] = st.group(1)
            if event in ("UPDATE", "DESTROY"):
                pairs = re.findall(r"\[bytes=(\d+) pkts=(\d+)\]", kv)
                if pairs:
                    f["orig_pkts"], f["orig_bytes"] = int(pairs[0][1]), int(pairs[0][0])
                    if len(pairs) > 1:
                        f["reply_bytes"] = int(pairs[1][0])
    return flows


def read_counters(path):
    out = {}
    if not path:
        return out
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            parts = line.split(None, 2)
            if len(parts) == 3:
                try:
                    name = parts[2].strip().strip('"')
                    out[name] = (int(parts[0]), int(parts[1]))
                except ValueError:
                    pass
    return out


def iso(ts):
    return datetime.fromtimestamp(int(ts), tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# Pi-hole v6 numeric query status codes
DNS_STATUS = {
    0: "NONE", 1: "CLIENT_QUERY", 2: "FORWARDED", 3: "CACHE_HIT",
    4: "REVERSE", 5: "GRAVITY", 6: "QUERY_RETRIED", 7: "CACHE_FLUSH",
    8: "CLIENT_DENY", 9: "UPSTREAM_BLOCKED", 10: "CNAME", 11: "DNSSEC",
    12: "CLIENT_ALLOW", 13: "SHUNT", 14: "SINKHOLE", 15: "BLACKLIST",
    16: "WHITELIST", 17: "UPSTREAM_TIMEOUT",
}


def main():
    if len(sys.argv) < 8:
        sys.exit("usage: session_analyze.py OUTDIR TVNAME TVIP LABEL DURATION_S T_START T_END [MODE]")
    outdir, tvname, tvip, label, dur = sys.argv[1:6]
    t_start, t_end = int(sys.argv[6]), int(sys.argv[7])
    mode = sys.argv[8] if len(sys.argv) > 8 else ""

    flows = parse_conntrack_events(f"{outdir}/events.log")

    # keep only flows where the TV is an endpoint
    tv_flows = []
    for (proto, src, dst, osport, odport), f in flows.items():
        if tvip not in (src, dst):
            continue
        tv_flows.append({
            "proto": proto, "src_ip": src, "src_port": int(osport),
            "dst_ip": dst, "dst_port": int(odport),
            "first_ts": f["first_ts"], "last_ts": f["last_ts"],
            "state": f["state"],
            "orig_bytes": f["orig_bytes"], "reply_bytes": f["reply_bytes"],
            "direction": "out" if src == tvip else "in",
        })
    tv_flows.sort(key=lambda r: -(r["orig_bytes"] + r["reply_bytes"]))

    with open(f"{outdir}/connections.csv", "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["dst_ip", "dst_port", "proto", "src_ip", "src_port",
                    "first_seen", "last_seen", "duration_s",
                    "bytes_original_dir", "bytes_reply_dir", "state", "direction"])
        for r in tv_flows:
            w.writerow([r["dst_ip"], r["dst_port"], r["proto"], r["src_ip"], r["src_port"],
                        iso(r["first_ts"]), iso(r["last_ts"]),
                        r["last_ts"] - r["first_ts"],
                        r["orig_bytes"], r["reply_bytes"], r["state"], r["direction"]])

    # ---- DNS ---------------------------------------------------------------
    queries = []
    try:
        with open(f"{outdir}/pihole-queries.json", encoding="utf-8") as fh:
            queries = json.load(fh)
    except (OSError, ValueError):
        pass

    dns_rows = []
    for q in queries:
        client = q.get("client") or {}
        upstream = q.get("upstream") or {}
        status = q.get("status", q.get("status_code", ""))
        try:
            status_name = DNS_STATUS.get(int(status), str(status))
        except (TypeError, ValueError):
            status_name = str(status)
        reply = q.get("reply", "")
        if isinstance(reply, dict):
            reply = "{}".join(filter(None, [reply.get("type", "")]))
        dns_rows.append({
            "time": iso(q.get("time", 0)),
            "domain": q.get("domain", ""),
            "type": q.get("type", ""),
            "status": status_name,
            "reply": reply,
            "client_ip": client.get("ip", ""),
            "upstream_ip": upstream.get("ip", ""),
        })

    with open(f"{outdir}/dns.csv", "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["time", "domain", "type", "status", "reply", "client_ip", "upstream_ip"])
        for r in dns_rows:
            w.writerow([r["time"], r["domain"], r["type"], r["status"],
                        r["reply"], r["client_ip"], r["upstream_ip"]])

    # ---- nft counter deltas -------------------------------------------------
    c_start = read_counters(f"{outdir}/nft-counters-start.txt")
    c_end = read_counters(f"{outdir}/nft-counters-end.txt")
    deltas = {}
    for name in sorted(set(c_start) | set(c_end)):
        s = c_start.get(name, (0, 0))
        e = c_end.get(name, (0, 0))
        deltas[name] = {"start_pkts": s[0], "end_pkts": e[0], "delta_pkts": e[0] - s[0],
                        "start_bytes": s[1], "end_bytes": e[1], "delta_bytes": e[1] - s[1]}

    # ---- summary --------------------------------------------------------------
    uniq_dst = {(r["dst_ip"], r["dst_port"]) for r in tv_flows if r["direction"] == "out"}
    by_dst = {}
    for r in tv_flows:
        if r["direction"] != "out":
            continue
        d = by_dst.setdefault((r["dst_ip"], r["dst_port"]), {"pkts": 0, "bytes": 0})
        d["pkts"] += 1
        d["bytes"] += r["orig_bytes"] + r["reply_bytes"]
    top_bytes = sorted(by_dst.items(), key=lambda kv: -kv[1]["bytes"])[:15]
    top_conns = sorted(by_dst.items(), key=lambda kv: -kv[1]["pkts"])[:15]
    dns_by_status = {}
    dns_by_domain = {}
    for r in dns_rows:
        dns_by_status[r["status"]] = dns_by_status.get(r["status"], 0) + 1
        dns_by_domain[r["domain"]] = dns_by_domain.get(r["domain"], 0) + 1
    blocked = {s: c for s, c in dns_by_status.items() if s in ("GRAVITY", "SHUNT", "SINKHOLE", "BLACKLIST", "CLIENT_DENY")}
    top_domains = sorted(dns_by_domain.items(), key=lambda kv: -kv[1])[:15]

    L = []
    L.append(f"# TV session — {tvname} ({tvip}) — {label}")
    L.append("")
    L.append(f"- window: {iso(t_start)} → {iso(t_end)} UTC ({dur}s)")
    L.append(f"- tvguard mode: {mode or 'unknown'}")
    L.append(f"- flows touching TV: {len(tv_flows)} | unique outbound dst:port: {len(uniq_dst)}")
    L.append(f"- DNS queries logged for this client: {len(dns_rows)} (blocked: {sum(blocked.values()) if blocked else 0})")
    L.append("")
    L.append("## Top outbound destinations by bytes")
    L.append("")
    L.append("| dst | port | flows | bytes |")
    L.append("|---|---|---|---|")
    for (ip, port), d in top_bytes:
        L.append(f"| {ip} | {port} | {d['pkts']} | {d['bytes']} |")
    L.append("")
    L.append("## Top outbound destinations by connection count")
    L.append("")
    L.append("| dst | port | flows | bytes |")
    L.append("|---|---|---|---|")
    for (ip, port), d in top_conns:
        L.append(f"| {ip} | {port} | {d['pkts']} | {d['bytes']} |")
    L.append("")
    L.append("## DNS queries")
    L.append("")
    L.append(f"Status breakdown: " + (", ".join(f"{k}={v}" for k, v in sorted(dns_by_status.items())) or "none"))
    L.append("")
    L.append("| domain | queries |")
    L.append("|---|---|")
    for dom, n in top_domains:
        L.append(f"| {dom} | {n} |")
    L.append("")
    L.append("## nftables counter deltas (tvguard table)")
    L.append("")
    L.append("| rule | pkts delta | bytes delta |")
    L.append("|---|---|---|")
    for name, d in deltas.items():
        L.append(f"| {name} | {d['delta_pkts']} | {d['delta_bytes']} |")
    L.append("")
    L.append("_Note: flows to other 192.168.0.x devices do not traverse this box (layer-2 "
             "PoC limitation) and therefore do NOT appear here. TLS/QUIC payloads are not "
             "captured; only flow/DNS metadata._")
    with open(f"{outdir}/summary.md", "w", encoding="utf-8") as fh:
        fh.write("\n".join(L) + "\n")

    # ---- metadata -----------------------------------------------------------
    meta = {
        "tv": tvname, "tv_ip": tvip, "label": label,
        "duration_s": int(dur), "t_start": t_start, "t_end": t_end,
        "window_utc": [iso(t_start), iso(t_end)],
        "tvguard_mode": mode,
        "flow_count": len(tv_flows),
        "unique_outbound_dsts": len(uniq_dst),
        "dns_query_count": len(dns_rows),
        "nft_counter_deltas": deltas,
        "tool": "session_analyze.py",
    }
    with open(f"{outdir}/metadata.json", "w", encoding="utf-8") as fh:
        json.dump(meta, fh, indent=2)
        fh.write("\n")

    print(f"  connections.csv: {len(tv_flows)} flows, {len(uniq_dst)} unique outbound dsts")
    print(f"  dns.csv:         {len(dns_rows)} queries")
    print(f"  summary.md + metadata.json written")


if __name__ == "__main__":
    main()
