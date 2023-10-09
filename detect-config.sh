#!/bin/sh
LOG_FILE=${1:-/root/detected_config.txt}
INTERFACES=$(ip -o link list | awk -F '[@: ]+' '{print $2}' | sort -V)
GEMS=$(echo "$INTERFACES" | grep -E "^gem\d")
PMAPS=$(echo "$INTERFACES" | grep -E "pmapper\d")

for GEM in $GEMS; do
    LINK=$(ip -d link list dev "$GEM")
    if echo "$LINK" | grep -q "mc: 1"; then
        MULTI_GEM="$GEM"
    fi
done

for PMAP in $PMAPS; do
    LINK=$(ip -o -d link list dev "$PMAP")
    PMAP_GEMS=$(echo "$LINK" | grep -oE "gem\d+" | sort -u)
    PMAP_NUM_GEMS=$(echo "$PMAP_GEMS" | wc -l)
    if [ -z "$SERVICES_PMAP" ] && [ "$PMAP_NUM_GEMS" -gt 1 ]; then
        SERVICES_PMAP="$PMAP"
        SERVICES_GEMS=$(echo $PMAP_GEMS)
    elif [ -z "$INTERNET_PMAP" ]; then
        INTERNET_PMAP="$PMAP"
        INTERNET_GEM=$PMAP_GEMS
    fi
done

if [ -n "$INTERNET_PMAP" ]; then
    UNICAST_VLAN=$(tc filter show dev "$INTERNET_PMAP" ingress | grep -oE "vlan_id \d+" | head -n1 | awk '{print $2}')
fi

[ -n "$UNICAST_VLAN" ] || exit 1

echo "Unicast VLAN: $UNICAST_VLAN" | tee "$LOG_FILE"
echo "Multicast GEM: $MULTI_GEM" | tee -a "$LOG_FILE"
echo "Internet GEM: $INTERNET_GEM" | tee -a "$LOG_FILE"
echo "Internet PMAP: $INTERNET_PMAP" | tee -a "$LOG_FILE"
echo "Services GEMs: $SERVICES_GEMS" | tee -a "$LOG_FILE"
echo "Services PMAP: $SERVICES_PMAP" | tee -a "$LOG_FILE"
