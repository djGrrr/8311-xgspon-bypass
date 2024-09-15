#!/bin/sh

# Location of detect-config script, required if CONFIG file does not exist
DETECT_CONFIG="/root/8311-detect-config.sh"

# Location of configuration file, will be generated if it doesn't exist
CONFIG_FILE="/tmp/8311-config.sh"

####################################################
. /root/8311-vlans-lib.sh


### Configuration
UNICAST_IFACE=eth0_0
MULTICAST_IFACE=eth0_0_2

CONFIG_FILE=${CONFIG_FILE:-"/tmp/8311-config.sh"}
DETECT_CONFIG=${DETECT_CONFIG:-"/root/8311-detect-config.sh"}


if [ ! -e "$DETECT_CONFIG" ]; then
    echo "Required detection script '$DETECT_CONFIG' missing." >&2
    exit 1
fi

# Read config file if it exists
STATE_HASH=
FIX_ENABLED=
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
if [ -n "$FIX_ENABLED" ] && [ "$FIX_ENABLED" -eq 0 ] 2>/dev/null; then
	exit 69
fi

NEW_STATE_HASH=$("$DETECT_CONFIG" -H)

CONFIG_RESET=0
if [ ! -f "$CONFIG_FILE" ] || [ "$NEW_STATE_HASH" != "$STATE_HASH" ]; then
    echo "Config file '$CONFIG_FILE' does not exist or state changed, detecting configuration..."

    "$DETECT_CONFIG" -c "$CONFIG_FILE" > /dev/null
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Error: Unable to detect configuration." >&2
        exit 1
    fi

    CONFIG_RESET=1
fi

. "$CONFIG_FILE"

if [ -n "$FIX_ENABLED" ] && [ "$FIX_ENABLED" -eq 0 ] 2>/dev/null; then
    exit 69
fi

if ! { [ -n "$INTERNET_VLAN" ] && [ -n "$INTERNET_PMAP" ] && [ -n "$UNICAST_VLAN" ]; }; then
    echo "Required variables INTERNET_VLAN, INTERNET_PMAP, and UNICAST_VLAN are not properly set." >&2
    exit 1
fi


### Downstream
internet_pmap_ds_rules() {
    if [ "$INTERNET_VLAN" -ne 0 ]; then
        # Tagged
        tc_flower_add dev $INTERNET_PMAP ingress handle 0x1 protocol 802.1Q pref 1 flower skip_sw action vlan modify id $INTERNET_VLAN protocol 802.1Q pass
    else
        # Untagged
        tc_flower_add dev $INTERNET_PMAP ingress handle 0x1 protocol 802.1Q pref 1 flower skip_sw action vlan pop pass
    fi
}

services_pmap_ds_rules() {
    tc_flower_add dev $SERVICES_PMAP ingress handle 0x1 protocol 802.1Q pref 1 flower skip_sw action vlan modify id $SERVICES_VLAN protocol 802.1Q pass
}

multicast_iface_ds_rules() {
    tc_flower_add dev $MULTICAST_IFACE egress handle 0x1 protocol 802.1Q pref 1 flower skip_sw action vlan modify id $SERVICES_VLAN priority 5 protocol 802.1Q pass
}


## Internet
[ "$CONFIG_RESET" -eq 1 ] && tc_flower_clear dev $INTERNET_PMAP ingress
internet_pmap_ds_rules || { tc_flower_clear dev $INTERNET_PMAP ingress; internet_pmap_ds_rules; }

# Services
if [ -n "$SERVICES_PMAP" ]; then
    [ "$CONFIG_RESET" -eq 1 ] && tc_flower_clear dev $SERVICES_PMAP ingress
    services_pmap_ds_rules || { tc_flower_clear dev $SERVICES_PMAP ingress; services_pmap_ds_rules; }
fi

# Multicast
if [ -n "$SERVICES_PMAP" ] && [ -n "$MULTICAST_GEM" ] ; then
	[ "$CONFIG_RESET" -eq 1 ] && tc_flower_clear dev $MULTICAST_IFACE egress
    multicast_iface_ds_rules || { tc_flower_clear dev $MULTICAST_IFACE egress; multicast_iface_ds_rules; }
fi


### Upstream
internet_pmap_us_rules() {
    if [ "$INTERNET_VLAN" -ne 0 ]; then
        # Tagged
        tc_flower_add dev $INTERNET_PMAP egress handle 0x1 protocol 802.1Q pref 1 flower vlan_id $INTERNET_VLAN skip_sw action vlan modify id $UNICAST_VLAN protocol 802.1Q pass &&
        tc_flower_add dev $INTERNET_PMAP egress handle 0x2 protocol 802.1Q pref 2 flower skip_sw action drop &&
        tc_flower_add dev $INTERNET_PMAP egress handle 0x3 protocol all pref 3 flower skip_sw action drop
    else
        # Untag
        tc_flower_add dev $INTERNET_PMAP egress handle 0x1 protocol 802.1Q pref 1 flower skip_sw action drop &&
        tc_flower_add dev $INTERNET_PMAP egress handle 0x2 protocol all pref 2 flower skip_sw action vlan push id $UNICAST_VLAN priority 0 protocol 802.1Q pass
    fi
}

services_pmap_us_rules() {
    tc_flower_add dev $SERVICES_PMAP egress handle 0x1 protocol 802.1Q pref 1 flower vlan_id $SERVICES_VLAN skip_sw action vlan modify id $UNICAST_VLAN protocol 802.1Q pass &&
    tc_flower_add dev $SERVICES_PMAP egress handle 0x2 protocol 802.1Q pref 2 flower skip_sw action drop &&
    tc_flower_add dev $SERVICES_PMAP egress handle 0x3 protocol all pref 3 flower skip_sw action drop
}


# Internet
[ "$CONFIG_RESET" -eq 1 ] && tc_flower_clear dev $INTERNET_PMAP egress
internet_pmap_us_rules || { tc_flower_clear dev $INTERNET_PMAP egress; internet_pmap_us_rules; }

# Services
if [ -n "$SERVICES_PMAP" ]; then
    [ "$CONFIG_RESET" -eq 1 ] && tc_flower_clear dev $SERVICES_PMAP egress
    services_pmap_us_rules || { tc_flower_clear dev $SERVICES_PMAP egress; services_pmap_us_rules; }
fi

# Cleanup
tc_flower_clear dev $UNICAST_IFACE egress
tc_flower_clear dev $UNICAST_IFACE ingress
