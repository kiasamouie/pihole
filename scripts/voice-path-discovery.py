#!/usr/bin/env python3
"""
voice-path-discovery.py - high-resolution (~1 Hz) recorder of everything a
target TV does through this host, for voice-path correlation.

Purpose:
  A voice request may ride an ALREADY-OPEN persistent connection with no new
  DNS query at all. Coarse 5-10 min captures cannot prove which flow carried
  it. This tool records:

    * a snaplen-128 tcpdump of the TV's packets (headers only - NOT the full
      encrypted payload), with microsecond timestamps; it is parsed OFFLINE
      after the capture into per-second per-flow packet/byte deltas, which is
      what makes byte spikes on PRE-EXISTING flows visible
    * conntrack flow lifecycle at 1 Hz (new flows, flow expiry)
    * DNS queries via the Pi-hole v6 API (2 Hz poll, deduped by id)
    * TVGuard nftables counters (every 5 s)

Usage (run via the .sh wrapper, as root):
  voice-path-discovery.py LABEL TOTAL_S ACTIVE_START_S ACTIVE_END_S OUTDIR TV_IP

  Phases: 0..ACTIVE_START_S = "pre", ACTIVE_START_S..ACTIVE_END_S = "active"
  (the window in which the human uses the TV's microphone), then "post".

Outputs (in OUTDIR):
  metadata.json  timeline.csv  dns.csv  flows.csv  counters.csv
  candidates.csv summary.md  capture.pcap (headers only, git-ignored)
"""
import csv
import json
import os
import re
import signal
import struct
import subprocess
import sys
import time
import urllib.request

def run(cmd, timeout=6):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.stdout or ""
    except Exception:
        return ""


def default_iface():
    out = run(["ip", "-4", "route", "show", "default"])
    for line in out.splitlines():
        parts = line.split()
        if "dev" in parts:
            return parts[parts.index("dev") + 1]
    return "enp2s0"


def default_pihole_base():
    # pihole container is on docker's bridge; FTL also listens on 127.0.0.1
    # via the compose port mapping (3001 -> 80). Use 3001 like the other scripts.
    return "http://127.0.0.1:3001"


CT_TUPLE_RE = re.compile(
    r"^(?P<proto>[a-z]+)\s+\S+\s+\S+\s+\S+\s+.*?"
    r"SRC=(?P<src>\d+\.\d+\.\d+\.\d+)\s+DST=(?P<dst>\d+\.\d+\.\d+\.\d+)"
    r"(?:\s+SPI=(?P<sp>\d+))?(?:\s+DPI=(?P<dp>\d+))?"
)


def parse_conntrack(out, tv):
    """Yield (proto, src, dst, sport, dport) tuples involving tv (lifecycle only)."""
    rows = []
    for line in out.splitlines():
        if tv not in line:
            continue
        m = CT_TUPLE_RE.match(line)
        if not m:
            continue
        d = m.groupdict()
        rows.append((d["proto"], d["src"], d["dst"], d.get("sp") or "", d.get("dp") or ""))
    return rows


def parse_pcap(path, tv):
    """Parse a classic pcap (v2) produced by tcpdump -s 128.

    Returns list of (ts_epoch, proto, src, dst, sport, dport, nbytes).
    Handles Ethernet (14B) or raw-IP links; best-effort, never raises.
    """
    out = []
    try:
        with open(path, "rb") as f:
            gh = f.read(24)
            if len(gh) < 24:
                return out
            magic = struct.unpack("<I", gh[:4])[0]
            if magic not in (0xA1B2C3D4, 0xA1B23C3D):
                return out
            nanosec = magic == 0xA1B2C3D4
            while True:
                rh = f.read(16)
                if len(rh) < 16:
                    break
                ts_s, ts_frac = struct.unpack("<II", rh[:8])
                ts = ts_s + (ts_frac / 1_000_000_000.0 if nanosec else ts_frac / 1_000_000.0)
                _, _, incl_len, _ = struct.unpack("<IIII", rh[:16])
                data = f.read(incl_len)
                if len(data) < incl_len:
                    break
                # locate the IP header (Ethernet, optional 802.1Q VLAN tag, or raw IP)
                if len(data) >= 14 and data[12:14] == b"\x08\x00":
                    ip = data[14:]
                elif len(data) >= 18 and data[12:14] == b"\x81\x00" and data[16:18] == b"\x08\x00":
                    ip = data[18:]
                else:
                    ip = data
                if len(ip) < 20 or (ip[0] >> 4) != 4:
                    continue
                ihl = (ip[0] & 0x0F) * 4
                proto = ip[9]
                if proto not in (6, 17):
                    continue
                src = "%d.%d.%d.%d" % ip[12:16]
                dst = "%d.%d.%d.%d" % ip[16:20]
                if tv not in (src, dst):
                    continue
                if len(ip) >= ihl + 8:
                    s_port, d_port = struct.unpack("!HH", ip[ihl:ihl + 4])
                else:
                    continue
                out.append((ts, "tcp" if proto == 6 else "udp", src, dst, s_port, d_port, incl_len))
    except Exception:
        pass
    return out


def main():
    if len(sys.argv) < 7:
        sys.exit("usage: voice-path-discovery.py LABEL TOTAL_S ACTIVE_START_S ACTIVE_END_S OUTDIR TV_IP")
    label, total_s, a0, a1, outdir, tv = (
        sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]),
        sys.argv[5], sys.argv[6],
    )
    os.makedirs(outdir, exist_ok=True)

    base = default_pihole_base()

    # --- tcpdump (headers only, snaplen 128) ---
    iface = default_iface()
    pcap = os.path.join(outdir, "capture.pcap")
    td = None
    try:
        td = subprocess.Popen(
            ["tcpdump", "-i", iface, "-s", "128", "-nn", "-q",
             "ip src %s or ip dst %s" % (tv, tv), "-w", pcap],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception as e:
        sys.stderr.write("WARN: tcpdump failed to start (%s); byte deltas unavailable\n" % e)
        td = None

    # --- Pi-hole auth ---
    sid = None
    try:
        pw = ""
        root = os.environ.get("PRIVACY_ROOT")
        if root:
            for line in open(os.path.join(root, ".env")):
                if line.startswith("ADMIN_PASSWORD="):
                    pw = line.strip().split("=", 1)[1]
        if pw:
            r = urllib.request.Request(base + "/api/auth", method="POST",
                                       data=json.dumps({"password": pw}).encode(),
                                       headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(r, timeout=10) as resp:
                sid = json.loads(resp.read())["session"]["sid"]
    except Exception as e:
        sys.stderr.write("WARN: Pi-hole auth failed (%s); DNS polling disabled\n" % e)
        sid = None

    def fetch_dns():
        if not sid:
            return []
        try:
            r = urllib.request.Request(base + "/api/queries?limit=200")
            r.add_header("X-FTL-SID", sid)
            with urllib.request.urlopen(r, timeout=10) as resp:
                return json.loads(resp.read()).get("queries") or []
        except Exception:
            return []

    def fetch_counters():
        out = run(["nft", "-s", "list", "chain", "ip", "tvguard", "forward"])
        rows = []
        for line in out.splitlines():
            if "counter" not in line:
                continue
            pref = ""
            for p in ("TVGUARD-NEW", "TVGUARD-PRIVACY", "TVGUARD-DOT", "TVGUARD-DOH", "TVGUARD-PT-"):
                if p in line:
                    pref = p
            m = re.search(r"packets (\d+) bytes (\d+)", line)
            if m:
                rows.append((pref or "other", int(m.group(1)), int(m.group(2))))
        return rows

    f_tl = open(os.path.join(outdir, "timeline.csv"), "w")
    f_dns = open(os.path.join(outdir, "dns.csv"), "w")
    f_cnt = open(os.path.join(outdir, "counters.csv"), "w")
    tlw = csv.writer(f_tl)
    tlw.writerow(["ts", "epoch", "phase", "event", "detail"])
    dnsw = csv.writer(f_dns)
    dnsw.writerow(["ts", "epoch", "phase", "status", "type", "domain", "rrtype", "ip"])
    cntw = csv.writer(f_cnt)
    cntw.writerow(["ts", "epoch", "phase", "rule", "packets", "bytes"])

    flows = {}
    seen_dns = set()
    dns_rows = []
    start = time.time()
    last_phase = None
    next_dns = 0.0
    next_cnt = 5.0
    t0 = start

    def phase_of(now):
        el = now - start
        if el < a0:
            return "pre"
        return "active" if el < a1 else "post"

    print("[%s] recording %s | iface=%s | total %ds | active window %d-%ds (s)" %
          (time.strftime("%H:%M:%S"), tv, iface, total_s, a0, a1), flush=True)
    print("  phases: pre 0-%ds | active %d-%ds | post %d-%ds" % (a0, a0, a1, a1, total_s), flush=True)
    if td:
        print("  pcap: %s (snaplen 128, headers only)" % pcap, flush=True)

    while True:
        now = time.time()
        if now - start >= total_s:
            break
        el = now - start
        phase = phase_of(now)
        if phase != last_phase:
            if last_phase is not None:
                print("[%s] -> phase %s" % (time.strftime("%H:%M:%S"), phase), flush=True)
            ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now))
            tlw.writerow([ts, "%.3f" % el, phase, "PHASE", phase])
            f_tl.flush()
            last_phase = phase

        # 1 Hz conntrack (flow lifecycle: NEW flows and disappearances)
        out = run(["conntrack", "-L"], timeout=4)
        cur = set()
        for (proto, src, dst, sp, dp) in parse_conntrack(out, tv):
            key = (proto, src, dst, sp, dp)
            cur.add(key)
            if key not in flows:
                flows[key] = el
                ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now))
                tlw.writerow([ts, "%.3f" % el, phase, "NEW-FLOW",
                              "%s %s:%s -> %s:%s" % (proto, src, sp, dst, dp)])
                f_tl.flush()
        gone = [k for k in list(flows) if k not in cur]
        for k in gone:
            proto, src, dst, sp, dp = k
            ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now))
            tlw.writerow([ts, "%.3f" % el, phase, "FLOW-END",
                          "%s %s:%s -> %s:%s" % (proto, src, sp, dst, dp)])
            f_tl.flush()
        for k in gone:
            del flows[k]

        # 2 Hz DNS
        if now >= next_dns:
            next_dns = now + 2
            rows = fetch_dns()
            ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now))
            for q in rows:
                qid = q.get("id")
                if qid in seen_dns:
                    continue
                if (q.get("client_ip") or q.get("client") or "") != tv:
                    continue
                seen_dns.add(qid)
                row = [ts, "%.3f" % (now - start), phase,
                       q.get("status", ""), q.get("type", ""),
                       q.get("domain", ""), q.get("rrtype", ""), q.get("ip", "")]
                dnsw.writerow(row)
                dns_rows.append((now - start, phase, row))
                tlw.writerow([ts, "%.3f" % (now - start), phase, "DNS",
                              "%s %s -> %s" % (row[3], row[5], row[7] or "?")])
            f_dns.flush()

        # 5 s counters
        if now >= next_cnt:
            next_cnt = now + 5
            for (rule, pk, by) in fetch_counters():
                cntw.writerow([time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)),
                               "%.3f" % (now - start), phase, rule, pk, by])
            f_cnt.flush()

        time.sleep(1)

    # --- stop tcpdump and parse the pcap offline (per-second flow bytes) ---
    if td:
        try:
            td.send_signal(signal.SIGTERM)
            td.wait(timeout=5)
        except Exception:
            try:
                td.kill()
            except Exception:
                pass

    pkts = parse_pcap(pcap, tv) if td else []
    # aggregate per-second per-flow
    per_sec = {}
    first_seen = {}
    for (ts, proto, src, dst, sp, dp, n) in pkts:
        key = (proto, src, dst, sp, dp)
        rel = max(0.0, ts - t0)
        sec = int(rel)
        st = per_sec.setdefault((sec, key), [0, 0])
        st[0] += 1
        st[1] += n
        if key not in first_seen or rel < first_seen[key]:
            first_seen[key] = rel

    f_flows = open(os.path.join(outdir, "flows.csv"), "w")
    floww = csv.writer(f_flows)
    floww.writerow(["sec", "phase", "state", "proto", "src", "dst", "sport", "dport",
                    "pkts", "bytes", "cum_pkts", "cum_bytes"])
    cum = {}
    keys = sorted(per_sec.keys(), key=lambda k: (k[0], k[1]))
    for (sec, key) in keys:
        pk, by = per_sec[(sec, key)]
        proto, src, dst, sp, dp = key
        state = "NEW" if abs(sec - first_seen.get(key, -1)) < 1.5 else "EXIST"
        c = cum.get(key, [0, 0])
        c[0] += pk
        c[1] += by
        cum[key] = c
        phase = "pre" if sec < a0 else ("active" if sec < a1 else "post")
        floww.writerow([sec, phase, state, proto, src, dst, sp, dp, pk, by, c[0], c[1]])
    f_flows.close()

    # candidates + summary
    doms = {}
    for (el, phase, row) in dns_rows:
        d = row[5]
        e = doms.setdefault(d, {"n": 0, "first": el, "last": el, "status": set(), "phases": set()})
        e["n"] += 1
        e["first"] = min(e["first"], el)
        e["last"] = max(e["last"], el)
        e["status"].add(row[3])
        e["phases"].add(phase)
    ipstat = {}
    for key, c in cum.items():
        proto, src, dst, sp, dp = key
        st = ipstat.setdefault(dst, {"flows": 0, "pk": 0, "by": 0, "first": first_seen.get(key, 0)})
        st["flows"] += 1
        st["pk"] += c[0]
        st["by"] += c[1]
        st["first"] = min(st["first"], first_seen.get(key, 0))
    new_ips = [ip for ip, st in ipstat.items() if st["first"] >= a0 - 5 and st["first"] < a1 + 5]

    with open(os.path.join(outdir, "candidates.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["kind", "name", "count", "first_el", "status", "phases", "extra"])
        for d, e in sorted(doms.items(), key=lambda kv: -kv[1]["n"]):
            w.writerow(["dns", d, e["n"], "%.0f" % e["first"],
                        ",".join(sorted(e["status"])), ",".join(sorted(e["phases"])), ""])
        for ip, st in sorted(ipstat.items(), key=lambda kv: -kv[1]["by"]):
            w.writerow(["ip", ip, st["flows"], "%.0f" % st["first"], "", "",
                        "pkts=%d bytes=%d" % (st["pk"], st["by"])])

    with open(os.path.join(outdir, "metadata.json"), "w") as f:
        json.dump({
            "label": label,
            "tv": tv,
            "iface": iface,
            "start_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t0)),
            "end_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time())),
            "total_s": total_s,
            "active_window_s": [a0, a1],
            "phases": {"pre": "0-%d" % a0, "active": "%d-%d" % (a0, a1), "post": "%d-%d" % (a1, total_s)},
            "pcap": "capture.pcap (snaplen 128 - headers only, NOT full payload)",
            "pcap_packets_parsed": len(pkts),
            "dns_queries": len(dns_rows),
            "flows_seen": len(cum),
            "note": "byte accounting comes from the snaplen-128 pcap (offline parse); "
                    "per-flow conntrack byte counters are unavailable on this system's "
                    "conntrack build.",
        }, f, indent=2)

    with open(os.path.join(outdir, "summary.md"), "w") as f:
        f.write("# Voice-path discovery: %s\n\n" % label)
        f.write("- TV: %s | iface: %s\n- Window: %s .. %s UTC (active: t+%d..t+%ds)\n" %
                (tv, iface,
                 time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t0)),
                 time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time())), a0, a1))
        f.write("- DNS queries: %d | flows: %d | pcap packets parsed: %d\n\n" %
                (len(dns_rows), len(cum), len(pkts)))
        f.write("## Flows ranked by total bytes (active-window spikes are the key column set)\n\n")
        f.write("| flow | total pkts | total bytes | first seen (s) |\n|---|---|---|---|\n")
        for key, c in sorted(cum.items(), key=lambda kv: -kv[1][1])[:25]:
            proto, src, dst, sp, dp = key
            f.write("| %s %s:%s -> %s:%s | %d | %d | t+%ds |\n" %
                    (proto, src, sp, dst, dp, c[0], c[1], int(first_seen.get(key, 0))))
        f.write("\n## Flow-second rows in the ACTIVE window with the largest byte counts\n\n")
        f.write("| sec | flow | pkts | bytes | state |\n|---|---|---|---|---|\n")
        rows = []
        for (sec, key), v in per_sec.items():
            if a0 <= sec < a1:
                proto, src, dst, sp, dp = key
                rows.append((v[1], sec, "%s %s:%s -> %s:%s" % (proto, src, sp, dst, dp), v[0],
                             "NEW" if abs(sec - first_seen.get(key, -1)) < 1.5 else "EXIST"))
        rows.sort(reverse=True)
        for by, sec, fl, pk, st in rows[:30]:
            f.write("| t+%d | %s | %d | %d | %s |\n" % (sec, fl, pk, by, st))
        if not rows:
            f.write("(no active-window rows)\n")
        f.write("\n## DNS names first seen during the ACTIVE window\n\n")
        anyv = False
        for d, e in sorted(doms.items()):
            if a0 <= e["first"] < a1:
                f.write("- %s (%dx, %s)\n" % (d, e["n"], ",".join(sorted(e["status"]))))
                anyv = True
        if not anyv:
            f.write("(none - all DNS happened pre/post; check persistent-flow rows above)\n")
        f.write("\n## IPs first contacted in/around the ACTIVE window\n\n")
        for ip in new_ips:
            f.write("- %s (first packet t+%ds, %d pkts / %d bytes total)\n" %
                    (ip, int(ipstat[ip]["first"]), ipstat[ip]["pk"], ipstat[ip]["by"]))
        if not new_ips:
            f.write("(none)\n")

    for fh in (f_tl, f_dns, f_cnt):
        fh.close()
    print("[%s] done - wrote %s (metadata.json timeline.csv dns.csv flows.csv counters.csv candidates.csv summary.md + capture.pcap)" %
          (time.strftime("%H:%M:%S"), outdir), flush=True)


if __name__ == "__main__":
    main()
