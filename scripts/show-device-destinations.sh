#!/usr/bin/env bash
# show-device-destinations.sh - Show where one LAN device is currently talking to.
#
# Usage: sudo scripts/show-device-destinations.sh <srcIP> [filter: internet|lan|all]
#   e.g. sudo scripts/show-device-destinations.sh 192.168.0.197 internet
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

IP="${1:?usage: show-device-destinations.sh <srcIP> [internet|lan|all]}"
FILTER="${2:-all}"

if [ "$FILTER" = "internet" ]; then
    MATCH="src $IP and dst != 192.168.0.0/24"
elif [ "$FILTER" = "lan" ]; then
    MATCH="src $IP and dst 192.168.0.0/24"
else
    MATCH="src $IP"
fi

echo "Current conntrack flows for src $IP ($FILTER) - live only, not history:"
sudo conntrack -L 2>/dev/null | awk -v ip="$IP" -v flt="$FILTER" '
{
    # conntrack line: udp/tcp 1 17 src=... dst=... sport=... dport=... [...]
    for(i=1;i<=NF;i++){
        if($i ~ /^src=/) { split($i,a,"="); s=a[2] }
        if($i ~ /^dst=/) { split($i,b,"="); d=b[2] }
        if($i ~ /^sport=/) { split($i,c,"="); sp=c[2] }
        if($i ~ /^dport=/) { split($i,e,"="); dp=e[2] }
    }
    if(s != ip) next
    if(flt=="internet" && d ~ /^192\.168\.0\./) next
    if(flt=="lan" && d !~ /^192\.168\.0\./) next
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
