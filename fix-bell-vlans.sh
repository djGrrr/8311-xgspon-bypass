#!/bin/sh

# Location of detect-config script, required if CONFIG file does not exist
DETECT_CONFIG="/root/detect-bell-config.sh"

# Location of configuration file, will be generated if it doesn't exist
CONFIG_FILE="/tmp/bell-config.sh"

####################################################
TC=$(PATH=/usr/sbin:/sbin /usr/bin/which tc)

tc() {
    $TC "$@"
}

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
    tc filter get $(tc_flower_selector "$@")
}

tc_flower_exists() {
    tc_flower_get "$@" > /dev/null 2>&1
}

tc_flower_del() {
    echo del $@ >&2
    tc_flower_exists "$@" &&
    tc filter del $(tc_flower_selector "$@")
}

tc_flower_add() {
    echo add $@ >&2
    tc_flower_exists "$@" ||
    tc filter add "$@"
}

tc_flower_clear() {
   echo clear $@ >&2
   tc filter del $(tc_flower_selector -devdironly "$@")
}


### Configuration
UNICAST_IFACE=eth0_0
MULTICAST_IFACE=eth0_0_2

CONFIG_FILE=${CONFIG_FILE:-"/tmp/bell-config.sh"}
DETECT_CONFIG=${DETECT_CONFIG:-"/root/detect-config.sh"}


CONFIG_RESET=
if [ ! -f "$CONFIG_FILE" ]; then
     if [ ! -e "$DETECT_CONFIG" ]; then
        echo "Config file '$CONFIG_FILE' does not exist and detection script '$DETECT_CONFIG' missing." >&2
        exit 1
    fi

    echo "Config file '$CONFIG_FILE' does not exist, detecting configuration..."

    # Get configuration from fwenvs
    INTERNET_VLAN=$(fw_printenv -n bell_internet_vlan 2>/dev/null)
    SERVICES_VLAN=$(fw_printenv -n bell_services_vlan 2>/dev/null)

    INTERNET_VLAN=${INTERNET_VLAN:-35}
    SERVICES_VLAN=${SERVICES_VLAN:-34}

    if ! { [ "$INTERNET_VLAN" -ge 0 ] 2>/dev/null && [ "$INTERNET_VLAN" -le 4095 ]; }; then
        echo "Internet VLAN '$INTERNET_VLAN' is invalid." >&2
        exit 1
    fi

    if ! { [ "$SERVICES_VLAN" -ge 1 ] 2>/dev/null && [ "$SERVICES_VLAN" -le 4095 ]; }; then
        echo "Services VLAN '$SERVICES_VLAN' is invalid." >&2
        exit 1
    fi

    if [ "$INTERNET_VLAN" -eq "$SERVICES_VLAN" ]; then
        echo "Internet VLAN and Services VLAN must be different." >&2
        exit 1
    fi

    "$DETECT_CONFIG" -c "$CONFIG_FILE" > /dev/null
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Config file '$CONFIG_FILE' does not exist and unable to detect configuration." >&2
        exit 1
    fi

    echo >> "$CONFIG_FILE"
    echo "# Internet VLAN exposed to network (0 = untagged)." >> "$CONFIG_FILE"
	echo "INTERNET_VLAN=${INTERNET_VLAN}" >> "$CONFIG_FILE"
    echo "# Services VLAN exposed to network." >> "$CONFIG_FILE"
    echo "SERVICES_VLAN=${SERVICES_VLAN}" >> "$CONFIG_FILE"

    CONFIG_RESET=1
fi

. "$CONFIG_FILE"

if ! { [ -n "$INTERNET_VLAN" ] && [ -n "$INTERNET_PMAP" ] && [ -n "$UNICAST_VLAN" ]; }; then
    echo "Required variables INTERNET_VLAN, INTERNET_PMAP, and UNICAST_VLAN are not properly set." >&2
    exit 1
fi

if [ -n "$CONFIG_RESET" ]; then
    # Clear all tables
    tc_flower_clear dev $MULTICAST_IFACE egress
    tc_flower_clear dev $INTERNET_PMAP ingress
    tc_flower_clear dev $INTERNET_PMAP egress

    if [ -n "$SERVICES_PMAP" ]; then
        tc_flower_clear dev $SERVICES_PMAP ingress
        tc_flower_clear dev $SERVICES_PMAP egress
    fi
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
internet_pmap_ds_rules || { tc_flower_clear dev $INTERNET_PMAP ingress; internet_pmap_downstream_rules; }

# Services
if [ -n "$SERVICES_PMAP" ]; then
    services_pmap_ds_rules || { tc_flower_clear dev $SERVICES_PMAP ingress; services_pmap_downstream_rules; }
fi

# Multicast
if [ -n "$SERVICES_PMAP" ] && [ -n "$MULTICAST_GEM" ] ; then
    multicast_iface_ds_rules || { tc_flower_clear dev $MULTICAST_IFACE egress; multicast_iface_ds_rules; }
fi


### Upstream
internet_pmap_us_rules() {
    if [ "$INTERNET_VLAN" -ne 0 ]; then
        # Tagged
        tc_flower_add dev $INTERNET_PMAP egress handle 0x1 protocol 802.1Q pref 1 flower vlan_id $INTERNET_VLAN skip_sw action vlan modify id $UNICAST_VLAN protocol 802.1Q pass &&
        tc_flower_add dev $INTERNET_PMAP egress handle 0x2 protocol 802.1Q pref 2 flower skip_sw action drop
        tc_flower_add dev $INTERNET_PMAP egress handle 0x3 protocol all pref 3 flower skip_sw action drop
    else
        # Untag
        tc_flower_add dev $INTERNET_PMAP egress handle 0x1 protocol 802.1Q pref 1 flower skip_sw action drop
        tc_flower_add dev $INTERNET_PMAP egress handle 0x2 protocol all pref 2 flower skip_sw action vlan push id $UNICAST_VLAN priority 0 protocol 802.1Q pass
    fi
}

services_pmap_us_rules() {
    tc_flower_add dev $SERVICES_PMAP egress handle 0x1 protocol 802.1Q pref 1 flower vlan_id $SERVICES_VLAN skip_sw action vlan modify id $UNICAST_VLAN protocol 802.1Q pass &&
    tc_flower_add dev $SERVICES_PMAP egress handle 0x2 protocol 802.1Q pref 2 flower skip_sw action drop
    tc_flower_add dev $SERVICES_PMAP egress handle 0x3 protocol all pref 3 flower skip_sw action drop
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
