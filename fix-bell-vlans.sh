#!/bin/sh

# Internet VLAN exposed to your network
INTERNET_VLAN=35

# Services VLAN exposed to your network (leave blank if you have no TV or phone services on the account, must be 34 or 36 if Unicast VLAN is unknown)
SERVICES_VLAN=34

# Location of detect-config script, required if CONFIG file does not exist
DETECT_CONFIG="/root/detect-bell-config.sh"

# Location of configuration file, will be generated if it doesn't exist
CONFIG_FILE="/root/bell-config.sh"

####################################################

tc_flower_selector() {
    dev=$(echo "$@" | grep -oE "dev \S+" | head -n1 | cut -d" " -f2)
    direction=$(echo "$@" | grep -oE  "egress|ingress" | head -n1)
    handle=$(echo "$@" | grep -oE "handle \S+" | head -n1 | cut -d" " -f2)
    protocol=$(echo "$@" | grep -oE "protocol \S+" | head -n1 | cut -d" " -f2)
    pref=$(echo "$@" | grep -oE "pref \S+" | head -n1 | cut -d" " -f2)
    if [ "$1" = "-devdironly" ]; then
        echo "dev $dev $direction"
    else
        echo "dev $dev $direction handle $handle pref $pref protocol $protocol flower"
    fi
}

tc_flower_get() {
    /sbin/tc filter get $(tc_flower_selector "$@")
}

tc_flower_exists() {
    tc_flower_get "$@" > /dev/null 2>&1
}

tc_flower_del() {
    echo del $@ >&2
    tc_flower_exists "$@" &&
    /sbin/tc filter del $(tc_flower_selector "$@")
}

tc_flower_add() {
    echo add $@ >&2
    tc_flower_exists "$@" ||
    /sbin/tc filter add "$@"
}

tc_flower_clear() {
   echo clear $@ >&2
   /sbin/tc filter del $(tc_flower_selector -devdironly "$@")
}


### Configuration
UNICAST_IFACE=eth0_0
MULTICAST_IFACE=eth0_0_2
INTERNET_VLAN=${INTERNET_VLAN:-35}
SERVICES_VLAN=${SERVICES_VLAN:-34}
CONFIG_FILE=${CONFIG_FILE:-"/root/bell-config.sh"}
DETECT_CONFIG=${DETECT_CONFIG:-"/root/detect-config.sh"}

if [ ! -f "$CONFIG_FILE" ]; then
     if [ ! -e "$DETECT_CONFIG" ]; then
        echo "Config file '$CONFIG_FILE' does not exist and detection script '$DETECT_CONFIG' missing." >&2
        exit 1
    fi

    echo "Config file '$CONFIG_FILE' does not exist, detecting configuration..."

    "$DETECT_CONFIG" -c "$CONFIG_FILE" > /dev/null
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Config file '$CONFIG_FILE' does not exist and unable to detect configuration." >&2
        exit 1
    fi
fi

source "$CONFIG_FILE"


### Downstream
internet_pmap_ds_rules() {
    tc_flower_add dev $INTERNET_PMAP ingress handle 0x1 protocol 802.1Q pref 1 flower skip_sw action vlan modify id $INTERNET_VLAN protocol 802.1Q pass
}

services_pmap_ds_rules() {
    tc_flower_add dev $SERVICES_PMAP ingress handle 0x1 protocol 802.1Q pref 1 flower skip_sw action vlan modify id $SERVICES_VLAN protocol 802.1Q pass
}

multicast_gem_ds_rules() {
    tc_flower_add dev $MULTICAST_GEM ingress handle 0x1 protocol 802.1Q pref 1 flower skip_sw action vlan modify id $SERVICES_VLAN priority 5 protocol 802.1Q pass
}


## Internet
internet_pmap_ds_rules || { tc_flower_clear dev $INTERNET_PMAP ingress; internet_pmap_downstream_rules; }

# Services
if [ -n "$SERVICES_PMAP" ]; then
    services_pmap_ds_rules || { tc_flower_clear dev $SERVICES_PMAP ingress; services_pmap_downstream_rules; }
fi

# Multicast
if [ -n "$MULTICAST_GEM" ] ; then
    multicast_gem_ds_rules || { tc_flower_clear dev $MULTICAST_GEM ingress; multicast_gem_ds_rules; }
fi


### Upstream
internet_pmap_us_rules() {
    tc_flower_add dev $INTERNET_PMAP egress handle 0x1 protocol 802.1Q pref 1 flower vlan_id $INTERNET_VLAN skip_sw action vlan modify id $UNICAST_VLAN protocol 802.1Q pass &&
    tc_flower_add dev $INTERNET_PMAP egress handle 0x2 protocol 802.1Q pref 2 flower skip_sw action drop
}

services_pmap_us_rules() {
    tc_flower_add dev $SERVICES_PMAP egress handle 0x1 protocol 802.1Q pref 1 flower vlan_id $SERVICES_VLAN skip_sw action vlan modify id $UNICAST_VLAN protocol 802.1Q pass &&
    tc_flower_add dev $SERVICES_PMAP egress handle 0x2 protocol 802.1Q pref 2 flower skip_sw action drop
}


# Internet
internet_pmap_us_rules || { tc_flower_clear dev $INTERNET_PMAP egress; internet_pmap_us_rules; }

# Services
if [ -n "$SERVICES_PMAP" ]; then
    services_pmap_us_rules || { tc_flower_clear dev $SERVICES_PMAP egress; services_pmap_us_rules; }
fi

# Cleanup
tc_flower_clear dev $UNICAST_IFACE egress
tc_flower_clear dev $UNICAST_IFACE ingress
tc_flower_clear dev $MULTICAST_IFACE egress

