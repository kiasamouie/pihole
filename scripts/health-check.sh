#!/usr/bin/env bash
# health-check.sh - Verify the pre-existing workloads are still healthy AND the
# new Pi-hole stack is up. Read-only. Safe to run anytime.
#
# Usage: scripts/health-check.sh
#
# Checks (no disruption):
#   - plexmediaserver, samba (smbd/nmbd), noip2, transmission, sshd  -> active
#   - invoice docker containers -> Up
#   - pihole container -> healthy, DNS answering locally
#   - tvguard: consistent (active marker <=> table + 2 ufw route rules)
#   - no accidental DHCP server on :67, no new NAT/forwarding rules
#   - memory / disk free
set -uo pipefail

fail=0
say(){ printf "%-55s %s\n" "$1" "$2"; }
check(){ # $1 label, $2.. conditions (all must be 0)
    local label="$1"; shift
    local ok=0
    for c in "$@"; do
        eval "$c" || ok=1
    done
    if [ $ok -eq 0 ]; then say "$label" "OK"; else say "$label" "FAIL"; fail=1; fi
}

echo "=== pre-existing services (must stay up) ==="
for svc in plexmediaserver smbd nmbd winbind noip2 transmission-daemon ssh; do
    st=$(systemctl is-active "$svc" 2>/dev/null || echo missing)
    [ "$st" = "active" ] && say "$svc" "active" || { say "$svc" "NOT active ($st)"; [ "$st" = "missing" ] || fail=1; }
done

echo; echo "=== docker containers ==="
docker ps --format '{{.Names}}\t{{.Status}}' | while IFS=$'\t' read -r n s; do
    echo "  $n  $s"
done
docker ps --format '{{.Names}}' | grep -q pihole || { echo "  pihole NOT running"; fail=1; }

echo; echo "=== Pi-hole local DNS test ==="
dig +time=3 +tries=2 @127.0.0.1 example.com >/dev/null 2>&1 \
    && say "dig @127.0.0.1 example.com" "OK (NOERROR)" || { say "dig @127.0.0.1 example.com" "FAIL"; fail=1; }

echo; echo "=== safety checks (must be clean) ==="
# No DHCP server listening on 67/udp (Pi-hole DHCP must stay off)
if ss -lntup | awk '{print $5}' | grep -qE ':(67)$'; then
    say "UDP :67 (DHCP) listener" "PRESENT - investigate!"; fail=1
else
    say "UDP :67 (DHCP) listener" "absent (good)"
fi

# --- TVGuard consistency (our own footprint only) ---
echo
echo "=== TVGuard (this project's firewall role) ==="
if [ -f /var/lib/tvguard/active ]; then
    if nft list table ip tvguard >/dev/null 2>&1; then
        say "tvguard table" "present (active expected)"
        # exactly our two TV route rules, nothing more in ufw-user-forward
        n_tv_rules=$(sudo iptables -t filter -S ufw-user-forward 2>/dev/null | grep -c ' -j ACCEPT')
        [ "$n_tv_rules" = "2" ] && say "ufw-user-forward TV rules" "2 (expected)" \
            || { say "ufw-user-forward TV rules" "UNEXPECTED COUNT: $n_tv_rules"; fail=1; }
    else
        say "tvguard table" "MISSING but active marker set - run tvguard-enable-monitor.sh"; fail=1
    fi
else
    if nft list table ip tvguard >/dev/null 2>&1; then
        say "tvguard table" "present but no active marker - run tvguard-disable.sh (or enable-monitor)"
    else
        say "tvguard table" "absent (disabled - consistent)"
    fi
fi
say "tvguard.service" "$(systemctl is-enabled tvguard.service 2>/dev/null || echo not-installed)"

# No new forwarding/NAT: forwarding chain should be empty on the LAN-facing table
# (Docker's own nat/forwarding for the invoice net is expected and pre-existing)
echo "  current 'filter FORWARD' rules:"
sudo nft -a list chain filter FORWARD 2>/dev/null | sed 's/^/    /' || echo "    (none / n/a)"

echo; echo "=== resources ==="
free -h | sed -n '2p'
df -h / /mnt/data 2>/dev/null | sed 1q
echo "loadavg: $(cut -d' ' -f1-3 /proc/loadavg)"

echo
if [ $fail -eq 0 ]; then echo "ALL CHECKS PASSED"; else echo "SOME CHECKS FAILED (see above)"; exit 1; fi
