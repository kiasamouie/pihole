#!/usr/bin/env bash
# show-device-destinations.sh - Show where one LAN device is currently talking to.
#
# Usage: sudo scripts/show-device-destinations.sh <srcIP> [filter: internet|lan|all]
#   e.g. sudo scripts/show-device-destinations.sh <TV_IP> internet
#
# Uses conntrack (kernel connection table) to list current established/related
# flows for that source IP, aggregated by destination. This is a LIVE snapshot
# (conntrack only holds current connections, default ~5 min tcp timeout) - it
# is NOT a log. For history, use show-dns-activity.py (DNS) or capture-device.sh.
#
# Limitation (switched LAN): conntrack here only shows connections that
# traverse THIS machine's network stack - i.e. traffic addressed to this server
# plus anything mirrored/gatewayed later. It will NOT show TV->Internet flows
# until the box is in the path.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/_tvguard_env.sh" 2>/dev/null || true
LAN_NET="${LAN_SUBNET:-0.0.0.0/0}"

IP="${1:?usage: show-device-destinations.sh <srcIP> [internet|lan|all]}"
FILTER="${2:-all}"

if [ "$FILTER" = "internet" ]; then
    MATCH="src $IP and dst != $LAN_NET"
elif [ "$FILTER" = "lan" ]; then
    MATCH="src $IP and dst $LAN_NET"
else
    MATCH="src $IP"
fi

echo "Current conntrack flows for src $IP ($FILTER) - live only, not history:"
sudo conntrack -L 2>/dev/null | awk -v ip="$IP" -v flt="$FILTER" -v lanp="${LAN_NET%/*}." '
{
    # conntrack line: udp/tcp 1 17 src=... dst=... sport=... dport=... [...]
    for(i=1;i<=NF;i++){
        if($i ~ /^src=/) { split($i,a,"="); s=a[2] }
        if($i ~ /^dst=/) { split($i,b,"="); d=b[2] }
        if($i ~ /^sport=/) { split($i,c,"="); sp=c[2] }
        if($i ~ /^dport=/) { split($i,e,"="); dp=e[2] }
    }
    if(s != ip) next
    if(flt=="internet" && index(d, lanp) == 1) next
    if(flt=="lan" && index(d, lanp) != 1) next
    key=d":"dp
    proto=$1; proto2=$2
    cnt[key]++
    seen[key]=proto"/"proto2
}
END{
    printf "%-35s %-10s %s\n","DESTINATION","PROTO","ACTIVE"
    for(k in cnt) printf "%-35s %-10s %d\n", k, seen[k], cnt[k]
}' | sort -t$'\t' -k1
echo
echo "(conntrack is a live snapshot; rerun during the TV activity window of interest)"
