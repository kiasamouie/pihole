#!/bin/sh
# wait-lan-address.sh - docker.service ExecStartPre helper.
#
# Debian's ifupdown brings `allow-hotplug` interfaces up asynchronously, so
# network-online.target is reached BEFORE dhcpcd has assigned the LAN address.
# dockerd then restores containers that publish ports on that address
# (Pi-hole 192.168.0.128:53, the platform TLS edge :443), the binds fail with
# "cannot assign requested address", and Docker 29 leaves them detached.
#
# This waits (bounded) for the address, then always exits 0: Docker must never
# be blocked indefinitely. If the deadline passes, docker-lan-heal and the
# tvguard watchdog repair the affected containers once the address appears.
#
# Installed as a COPY (not a symlink into /home) by deploy/install-boot-hardening.sh;
# configured through TVGUARD_LAN_IF / TVGUARD_LAN_IP / TVGUARD_LAN_WAIT.
PATH=/usr/sbin:/usr/bin:/sbin:/bin

IF="${TVGUARD_LAN_IF:-}"
IP="${TVGUARD_LAN_IP:-}"
WAIT="${TVGUARD_LAN_WAIT:-90}"

if [ -z "$IF" ] || [ -z "$IP" ]; then
    echo "wait-lan-address: TVGUARD_LAN_IF/TVGUARD_LAN_IP not set; not waiting"
    exit 0
fi

i=0
while [ "$i" -lt "$WAIT" ]; do
    if ip -4 -o address show dev "$IF" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$IP"; then
        echo "wait-lan-address: $IP present on $IF after ${i}s"
        exit 0
    fi
    sleep 1
    i=$((i + 1))
done
echo "wait-lan-address: WARNING: $IP not on $IF after ${WAIT}s; starting Docker anyway (watchdog will heal LAN-bound containers)"
exit 0
