#!/bin/sh

DEBUG=0
LOG_FILE=
DEBUG_FILE=
CONFIG_FILE=
HASH_ONLY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --logfile|-l)
            LOG_FILE="$2"
            shift
        ;;
        --debug|-d)
            DEBUG=1
        ;;
        --debuglog|-D)
            DEBUG_FILE="$2"
            shift
        ;;
        -c|--config)
            CONFIG_FILE="$2"
            shift
        ;;
        -H|--hash)
            HASH_ONLY=1
        ;;
        --help|-h)
            printf -- 'Usage: %s [options]\n\n' "$0"
            printf -- 'Options:\n'
            printf -- '-H --hash\t\t\tOnly generate state hash. Use to determine if the configuration should be re-detected.\n'
            printf -- '-l --logfile <filename>\t\tFile location to log output (will be overwritten).\n'
            printf -- '-D --debugfile <filename>\tFile location to output debug logging (will be appended to).\n'
            printf -- '-d --debug\t\t\tOutput debug information.\n'
            printf -- '-c --config <filename>\t\tWrite detected configuration to file\n'
            printf -- '-h --help\t\t\tThis help text\n'
            exit 0
        ;;
        *)
            printf "Invalid argument %s passed.  Try --help.\n" "$1"
            exit 1
        ;;
    esac
    shift
done

hash_state() {
    {
        ip li
        brctl show
        for BRPORT_STATE in $(find /sys/devices/virtual/net/sw*/lower_*/brport/state 2>/dev/null); do
             echo "$BRPORT_STATE: $(cat "$BRPORT_STATE")"
        done
    } | sha256sum | awk '{print $1}'
}

STATE_HASH=$(hash_state)
if [ "$HASH_ONLY" -eq 1 ]; then
    echo "$STATE_HASH"
    exit 0
fi


write_config() {
    echo "# Unicast VLAN ID from Bell side" > "$CONFIG_FILE"
    echo "UNICAST_VLAN=$UNICAST_VLAN" >> "$CONFIG_FILE"
    echo >> "$CONFIG_FILE"

    echo "# Mullticast GEM interface" >> "$CONFIG_FILE"
    echo "MULTICAST_GEM=$MULTICAST_GEM" >> "$CONFIG_FILE"
    echo >> "$CONFIG_FILE"

    echo "# Internet PMAP and GEM interfaces" >> "$CONFIG_FILE"
    echo "INTERNET_PMAP=$INTERNET_PMAP" >> "$CONFIG_FILE"
    echo "INTERNET_GEM=$INTERNET_GEM" >> "$CONFIG_FILE"
    echo >> "$CONFIG_FILE"

    echo "# Services PMAP and GEM interfaces" >> "$CONFIG_FILE"
    echo "SERVICES_PMAP=$SERVICES_PMAP" >> "$CONFIG_FILE"
    if [ -n "$SERVICES_GEMS" ]; then
        echo "SERVICES_GEMS=\"$SERVICES_GEMS\"" >> "$CONFIG_FILE"
    else
        echo "SERVICES_GEMS=" >> "$CONFIG_FILE"
    fi

    echo >> "$CONFIG_FILE"
    echo "# Internet VLAN exposed to network (0 = untagged)." >> "$CONFIG_FILE"
    echo "INTERNET_VLAN=${INTERNET_VLAN}" >> "$CONFIG_FILE"
    echo "# Services VLAN exposed to network." >> "$CONFIG_FILE"
    echo "SERVICES_VLAN=${SERVICES_VLAN}" >> "$CONFIG_FILE"

    echo >> "$CONFIG_FILE"
    echo "# State Hash" >> "$CONFIG_FILE"
    echo "STATE_HASH=$STATE_HASH" >> "$CONFIG_FILE"

    echo "Config file written to '$CONFIG_FILE'" >&2
}

log() {
    if [ -z "$LOG_FILE" ]; then
        cat
    elif [ "$1" = "-create" ]; then
        tee "$LOG_FILE"
    else
        tee -a "$LOG_FILE"
    fi
}

debug() {
    if [ "$DEBUG" -eq 1 ] && [ -n "$DEBUG_FILE" ]; then
        tee -a "$DEBUG_FILE" >&2
    elif [ -n "$DEBUG_FILE" ]; then
        cat >> "$DEBUG_FILE"
    elif [ "$DEBUG" -eq 1 ]; then
        cat >&2
    else
        cat > /dev/null
    fi
}

echo "=============" | debug
echo "State Hash: $STATE_HASH" | debug
echo | debug
echo "Getting VLAN settings from fwenvs:" | debug
INTERNET_VLAN=$(fw_printenv -n bell_internet_vlan 2>/dev/null)
SERVICES_VLAN=$(fw_printenv -n bell_services_vlan 2>/dev/null)
echo "bell_internet_vlan=$INTERNET_VLAN" | debug
echo "bell_services_vlan=$SERVICES_VLAN" | debug

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

echo | debug

INTERFACES=$(ip -o link list | awk -F '[@: ]+' '{print $2}' | sort -V)
GEMS=$(echo "$INTERFACES" | grep -E "^gem\d")
echo "GEMs:" | debug
echo "$GEMS" | debug
echo | debug
PMAPS=$(echo "$INTERFACES" | grep -E "pmapper\d")
echo "PMAPs:" | debug
echo "$PMAPS" | debug
echo | debug

MULTICAST_GEM=
for GEM in $GEMS; do
    LINK=$(ip -d link list dev "$GEM")
    echo "GEM $GEM Link:" | debug
    echo "$LINK" | debug
    if echo "$LINK" | grep -q "mc: 1"; then
        MULTICAST_GEM="$GEM"
        echo "Multicast GEM found: $MULTICAST_GEM" | debug
    fi
done

echo | debug

INTERNET_PMAP=
SERVICES_PMAP=
for PMAP in $PMAPS; do
    LINK=$(ip -d link list dev "$PMAP")
    echo "PMAP $PMAP Link:" | debug
    echo "$LINK" | debug
    PMAP_GEMS=$(echo "$LINK" | grep -oE "gem\d+" | sort -u)
    echo "PMAP $PMAP GEMs: $(echo $PMAP_GEMS)" | debug
    PMAP_NUM_GEMS=$(echo "$PMAP_GEMS" | wc -l)
    if [ -z "$SERVICES_PMAP" ] && [ "$PMAP_NUM_GEMS" -gt 1 ]; then
        SERVICES_PMAP="$PMAP"
        SERVICES_GEMS=$(echo $PMAP_GEMS)
        echo | debug
        echo "Services PMAP and GEMs found: $SERVICES_PMAP - $SERVICES_GEMS" | debug
        echo | debug
    elif [ -z "$INTERNET_PMAP" ]; then
        INTERNET_PMAP="$PMAP"
        INTERNET_GEM=$PMAP_GEMS
        echo | debug
        echo "Internet PMAP and GEM found: $INTERNET_PMAP - $INTERNET_GEM" | debug
        echo | debug
    fi
done

UNICAST_VLAN=
if [ -n "$INTERNET_PMAP" ]; then
    TC=$(tc filter show dev "$INTERNET_PMAP" ingress)
    echo | debug
    echo "TC $INTERNET_PMAP ingress:" | debug
    echo "$TC" | debug
    UNICAST_VLAN=$(echo "$TC" | grep -oE "vlan_id \d+" | head -n1 | awk '{print $2}')
    if [ -z "$UNICAST_VLAN" ]; then
        TC=$(tc filter show dev "$INTERNET_PMAP" egress)
        echo | debug
        echo "TC $INTERNET_PMAP egress:" | debug
        echo "$TC" | debug
        UNICAST_VLAN=$(echo "$TC" | grep -oE "(modify|push) id \d+" | tail -n1 | awk '{print $3}')
    fi
fi

if [ -z "$UNICAST_VLAN" ] && [ -n "$SERVICES_PMAP" ]; then
    TC=$(tc filter show dev "$SERVICES_PMAP" ingress)
    echo | debug
    echo "TC $SERVICES_PMAP ingress:" | debug
    echo "$TC" | debug
    UNICAST_VLAN=$(echo "$TC" | grep -oE "vlan_id \d+" | head -n1 | awk '{print $2}')
    if [ -z "$UNICAST_VLAN" ]; then
        TC=$(tc filter show dev "$SERVICES_PMAP" egress)
        echo | debug
        echo "TC $SERVICES_PMAP egress:" | debug
        echo "$TC" | debug
        UNICAST_VLAN=$(echo "$TC" | grep -oE "modify id \d+" | tail -n1 | awk '{print $3}')
    fi
fi

if [ -z "$UNICAST_VLAN" ]; then
    echo | debug
    echo "Failed to find Unicast VLAN from PMAP, falling back to eth0_0 egress method" | debug
    TC=$(tc filter show dev eth0_0 egress)
    echo "TC eth0_0 egress:" | debug
    echo "$TC" | debug
    UNICAST_VLAN=$(echo "$TC" | grep -oE "vlan_id \d+" | tail -n1 | awk '{print $2}')
fi

if [ -n "$UNICAST_VLAN" ]; then
    echo | debug
    echo "Unicast VLAN Found: $UNICAST_VLAN" | debug
fi
echo "=============" | debug
echo | debug

[ -n "$UNICAST_VLAN" ] || exit 1

echo "Unicast VLAN: $UNICAST_VLAN" | log -create
echo "Multicast GEM: $MULTICAST_GEM" | log
echo "Internet GEM: $INTERNET_GEM" | log
echo "Internet PMAP: $INTERNET_PMAP" | log
echo "Services GEMs: $SERVICES_GEMS" | log
echo "Services PMAP: $SERVICES_PMAP" | log
echo "Internet VLAN: $INTERNET_VLAN" | log
echo "Services VLAN: $SERVICES_VLAN" | log

[ -n "$CONFIG_FILE" ] && write_config
