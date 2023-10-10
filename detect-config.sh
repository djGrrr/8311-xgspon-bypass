#!/bin/sh
LOG_FILE=${1:-/root/detected-config.txt}
DEBUG_FILE=$2

log() {
    if [ "$1" = "-create" ]; then
        tee "$LOG_FILE"
    else
        tee -a "$LOG_FILE"
    fi
}

debug() {
    if [ "$DEBUG_FILE" ]; then
        tee -a "$DEBUG_FILE" >&2
    else
        cat >&2
    fi
}

echo "=============" | debug
INTERFACES=$(ip -o link list | awk -F '[@: ]+' '{print $2}' | sort -V)
echo "Interfaces:" | debug
echo "$INTERFACES" | debug
echo | debug
GEMS=$(echo "$INTERFACES" | grep -E "^gem\d")
echo "GEMs:" | debug
echo "$GEMS" | debug
echo | debug
PMAPS=$(echo "$INTERFACES" | grep -E "pmapper\d")
echo "PMAPs:" | debug
echo "$PMAPS" | debug
echo | debug

for GEM in $GEMS; do
    LINK=$(ip -d link list dev "$GEM")
    echo "GEM $GEM Link: $LINK" | debug
    if echo "$LINK" | grep -q "mc: 1"; then
        MULTI_GEM="$GEM"
        echo "Multicast GEM found: $MULTI_GEM" | debug
    fi
done

echo | debug

for PMAP in $PMAPS; do
    LINK=$(ip -o -d link list dev "$PMAP")
    echo "PMAP $PMAP Link: $LINK" | debug
    PMAP_GEMS=$(echo "$LINK" | grep -oE "gem\d+" | sort -u)
    echo "PMAP $PMAP GEMs: $(echo $PMAP_GEMS)" | debug
    PMAP_NUM_GEMS=$(echo "$PMAP_GEMS" | wc -l)
    if [ -z "$SERVICES_PMAP" ] && [ "$PMAP_NUM_GEMS" -gt 1 ]; then
        SERVICES_PMAP="$PMAP"
        SERVICES_GEMS=$(echo $PMAP_GEMS)
        echo "Services PMAP and GEMs found: $SERVICES_PMAP - $SERVICES_GEMS" | debug
    elif [ -z "$INTERNET_PMAP" ]; then
        INTERNET_PMAP="$PMAP"
        INTERNET_GEM=$PMAP_GEMS
        echo "Internet PMAP and GEM found: $INTERNET_PMAP - $INTERNET_GEM" | debug
    fi
done

if [ -n "$INTERNET_PMAP" ]; then
    TC=$(tc filter show dev "$INTERNET_PMAP" ingress)
    echo "TC $INTERNET_PMAP ingress:" | debug
    echo "$TC" | debug
    UNICAST_VLAN=$(echo "$TC" | grep -oE "vlan_id \d+" | head -n1 | awk '{print $2}')
    [ -n "$UNICAST_VLAN" ] && echo "Unicast VLAN Found: $UNICAST_VLAN" | debug
fi

if [ -z "$UNICAST_VLAN" ]; then
    echo | debug
    echo "Failed to find Unicast VLAN from PMAP, falling back to eth0_0 egress method" | debug
    TC=$(tc filter show dev eth0_0 egress)
    echo "TC eth0_0 egress:" | debug
    echo "$TC" | debug
    UNICAST_VLAN=$(echo "$TC" | grep -oE "vlan_id \d+" | tail -n1 | awk '{print $2}')
    [ -n "$UNICAST_VLAN" ] && echo "Unicast VLAN Found: $UNICAST_VLAN" | debug
fi

echo | debug
[ -n "$UNICAST_VLAN" ] || exit 1

echo "Unicast VLAN: $UNICAST_VLAN" | log -create
echo "Multicast GEM: $MULTI_GEM" | log
echo "Internet GEM: $INTERNET_GEM" | log
echo "Internet PMAP: $INTERNET_PMAP" | log
echo "Services GEMs: $SERVICES_GEMS" | log
echo "Services PMAP: $SERVICES_PMAP" | log
