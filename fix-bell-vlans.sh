#!/bin/sh

# Unicast interface on the ONT (don't change this)
UNICAST_IFACE=eth0_0
# Set UNICAST_VLAN with ISP unicast VLAN (2382, 1209, etc, this is different for everyone). If you are on Bell Canada, and JUST want to get Internet working on a multi-service account, leave this blank
UNICAST_VLAN=2871

# Multicast interface on the ONT (don't change this)
MUTICAST_IFACE=eth0_0_2
# Mullticast GEM interface (probably doesn't need to be changed)
MULTICAST_GEM=gem65534


# Internet VLAN exposed to your network
INTERNET_VLAN=35
# Internet PMAP and GEM interfaces (probably doesn't need to be changed)
INTERNET_PMAP=pmapper57602
INTERNET_GEM=gem1126


# Services VLAN exposed to your network (leave blank if you have no TV or phone services on the account, must be 34 or 36 if Unicast VLAN is unknown)
SERVICES_VLAN=34
# Services PMAP and GEM1 (first services GEM) interfaces (probably doesn't need to be changed)
SERVICES_PMAP=pmapper57603
SERVICES_GEM1=gem1127

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
    echo del $@
    tc_flower_exists "$@" &&
    /sbin/tc filter del $(tc_flower_selector "$@")
}

tc_flower_add() {
    echo add $@
    tc_flower_exists "$@" ||
    /sbin/tc filter add "$@"
}

tc_flower_clear() {
   echo clear $@
   /sbin/tc filter del $(tc_flower_selector -devdironly "$@")
}


# Hack if you don't know the Unicast VLAN
if [ -z "$UNICAST_VLAN" ]; then
    # If we don't know the Unicast VLAN, then the Internet VLAN must be 35 as otherwise the US packets won't work
    INTERNET_VLAN=35
    # No vlan id will be specified for packet matching
    UNI_VLAN=""
else
    UNI_VLAN="vlan_id $UNICAST_VLAN"
fi


### Downstream


## Internet VLAN

if [ -n "$INTERNET_GEM" ]; then
    # Fix DS priority 1-7 on Internet VLAN
    tc_flower_add dev $INTERNET_GEM ingress handle 0x1 protocol 802.1Q pref 1 flower $UNI_VLAN skip_sw action vlan modify priority 0 protocol 802.1Q pass
fi

# Retag DS unicast packets for Internet VLAN
tc_flower_add dev $UNICAST_IFACE egress handle 0x55 protocol 802.1Q pref 5 flower $UNI_VLAN vlan_prio 0 skip_sw action vlan modify id $INTERNET_VLAN priority 0 protocol 802.1Q pass


## Services VLAN
if [ -n "$SERVICES_VLAN" ]; then
    ## Multicast
    if [ -n "$MUTICAST_IFACE" ]; then
        # Set VLAN of DS Multicast packets to Services VLAN
        tc_flower_add dev $MUTICAST_IFACE egress handle 0x1 protocol 802.1Q pref 1 flower skip_sw action vlan modify id $SERVICES_VLAN priority 5 protocol 802.1Q pass

        # Clear pointless rules on Multicast GEM interface
        if [ -n "$MULTICAST_GEM" ]; then
            tc_flower_clear dev $MULTICAST_GEM ingress
        fi
    fi

    ## Unicast
    if [ -n "$SERVICES_GEM1" ]; then
        # Fix downstream Priority 0 on Services VLAN packets
        tc_flower_add dev $SERVICES_GEM1 ingress handle 0x1 protocol 802.1Q pref 1 flower $UNI_VLAN vlan_prio 0 skip_sw action vlan modify priority 6 protocol 802.1Q pass
    fi

    # Retag DS unicast packets for Services VLAN
    tc_flower_add dev $UNICAST_IFACE egress handle 0x100 protocol 802.1Q pref 10 flower $UNI_VLAN skip_sw action vlan modify id $SERVICES_VLAN protocol 802.1Q pass
fi



### Upstream

## Fix broadcast domain bridging of Services and Internet VLANs
if [ -n "$SERVICES_VLAN" ]; then
    if [ -n "$SERVICES_PMAP" ]; then
        # Clear existing Services PMAP egress rules
        tc_flower_clear dev $SERVICES_PMAP egress

        # Block US priority 0 (Internet) on services PMAP
        tc_flower_add dev $SERVICES_PMAP egress handle 0x1 protocol 802.1Q pref 1 flower $UNI_VLAN vlan_prio 0 skip_sw action drop
        tc_flower_add dev $SERVICES_PMAP egress handle 0x2 protocol 802.1Q pref 2 flower $UNI_VLAN skip_sw action pass
        tc_flower_add dev $SERVICES_PMAP egress handle 0x3 protocol all pref 3 flower skip_sw action drop
    fi

    if [ -n "$INTERNET_PMAP" ]; then
        # Clear existing Internet PMAP egress rules
        tc_flower_clear dev $INTERNET_PMAP egress

        # Block US priority 1-7 (Services) on Internet PMAP
        tc_flower_add dev $INTERNET_PMAP egress handle 0x1 protocol 802.1Q pref 1 flower $UNI_VLAN vlan_prio 0 skip_sw action pass
        tc_flower_add dev $INTERNET_PMAP egress handle 0x2 protocol all pref 2 flower skip_sw action drop
    fi
fi

if [ -z "$UNI_VLAN" ] ; then
    # If we don't know the Unicast VLAN, we can't create the remaining US rules, we must rely on the rules generated by omcid which are mostly ok
    exit 0
fi


# Retag US for Internet VLAN
tc_flower_add dev $UNICAST_IFACE ingress handle 0x301 protocol 802.1Q pref 5 flower vlan_id $INTERNET_VLAN skip_sw action vlan modify id $UNICAST_VLAN priority 0 protocol 802.1Q pass


# Services VLAN
if [ -n "$SERVICES_VLAN" ]; then
    # Retag and fix US priority 0 on Services VLAN
    tc_flower_add dev $UNICAST_IFACE ingress handle 0x401 protocol 802.1Q pref 11 flower vlan_id $SERVICES_VLAN vlan_prio 0 skip_sw action vlan modify id $UNICAST_VLAN priority 6 protocol 802.1Q pass

    # Retag US unicast packets for Services VLAN
    tc_flower_add dev $UNICAST_IFACE ingress handle 0x402 protocol 802.1Q pref 12 flower vlan_id $SERVICES_VLAN skip_sw action vlan modify id $UNICAST_VLAN protocol 802.1Q pass
fi
