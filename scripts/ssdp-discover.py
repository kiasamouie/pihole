#!/usr/bin/env python3
"""SSDP/UPnP discovery: send M-SEARCH to 239.255.255.250:1900, collect
responses, then fetch each device's LOCATION URL and extract friendly name /
model / manufacturer from the XML description.

Safe, standard UPnP discovery only (no exploit probes). Usage:
    sudo python3 ssdp-discover.py [timeout_seconds]
"""
import socket
import struct
import re
import sys
import time
import urllib.request

timeout = float(sys.argv[1]) if len(sys.argv) > 1 else 8.0
BADDR = "239.255.255.250"

def msearch(st, targets):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 4)
    # Join the multicast group so replies (unicast or multicast) are
    # delivered to this socket.
    mreq = struct.pack("4s4s", socket.inet_aton(BADDR), socket.inet_aton("0.0.0.0"))
    s.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
    s.settimeout(0.5)
    for t in targets:
        pkt = (
            f"M-SEARCH * HTTP/1.1\r\n"
            f"HOST: {t}:1900\r\n"
            "MAN: \"ssdp:discover\"\r\n"
            "MX: 3\r\n"
            f"ST: {st}\r\n\r\n"
        ).encode()
        s.sendto(pkt, (t, 1900))
    return s

def listen(dur):
    seen = {}
    end = time.time() + dur
    while time.time() < end:
        try:
            data, (src, sport) = s.recvfrom(2048)
        except socket.timeout:
            continue
        text = data.decode("utf-8", "replace")
        if "HTTP/1.1 200" not in text:
            continue
        hdrs = dict(re.findall(r"^(\w+):\s*(.+)$", text, re.M | re.I))
        key = (src, sport, hdrs.get("USN", "?"))
        if key not in seen:
            seen[key] = hdrs
    return seen

if __name__ == "__main__":
    # Unicast M-SEARCH to known LAN hosts (many TV/embedded devices ignore
    # multicast M-SEARCH and only answer unicast probes).
    targets = [f"192.168.0.{i}" for i in (1, 32, 83, 90, 147, 181, 187, 197, 206, 212, 225)]
    s = msearch("ssdp:all", targets)
    s.settimeout(0.5)
    devices = listen(timeout)
    print(f"Got {len(devices)} unique SSDP responses\n")
    for (src, sport, usn), h in sorted(devices.items()):
        loc = h.get("LOCATION", "")
        print(f"== {src} USN={usn}")
        print(f"   SERVER: {h.get('SERVER','-')}")
        print(f"   LOCATION: {loc}")
        if loc:
            try:
                req = urllib.request.Request(loc, headers={"User-Agent": "Mozilla/5.0 (ssdp-discover)"})
                xml = urllib.request.urlopen(req, timeout=4).read(200000).decode("utf-8", "replace")
                def tag(name):
                    m = re.search(f"<{name}[^>]*>(.*?)</{name}>", xml, re.S | re.I)
                    return m.group(1).strip() if m else ""
                for f in ("friendlyName", "modelName", "modelNumber", "manufacturer", "serialNumber", "udn"):
                    v = tag(f)
                    if v:
                        print(f"   {f}: {v[:200]}")
            except Exception as e:
                print(f"   (fetch failed: {e})")
        print()
