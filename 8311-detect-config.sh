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


# 4354 (AT&T), 57602 (Bell)
KNOWN_INTERNET_PMAPPERS="4354 57602"
# 57603 (Bell)
KNOWN_SERVICES_PMAPPERS="57603"

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

disable_config() {
	echo "# Enable fix_vlans script?" > "$CONFIG_FILE"
	echo "FIX_ENABLED=0" >> "$CONFIG_FILE"

	echo "Config file written to '$CONFIG_FILE'" >&2
}

write_config() {
    echo "# Unicast VLAN ID from ISP side" > "$CONFIG_FILE"
    echo "UNICAST_VLAN=$UNICAST_VLAN" >> "$CONFIG_FILE"
    echo >> "$CONFIG_FILE"

    echo "# Mullticast GEM interface" >> "$CONFIG_FILE"
    echo "MULTICAST_GEM=$MULTICAST_GEM" >> "$CONFIG_FILE"
    echo >> "$CONFIG_FILE"

    echo "# Internet PMAP and GEM interfaces" >> "$CONFIG_FILE"
    echo "INTERNET_PMAP=$INTERNET_PMAP" >> "$CONFIG_FILE"
    echo "INTERNET_GEMS=\"$INTERNET_GEMS\"" >> "$CONFIG_FILE"
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

get_pmap_gems() {
    local PMAP="$1"
    local LINK=$(ip -d link list dev "$PMAP")

    echo "PMAP $PMAP Link:" | debug
    echo "$LINK" | debug
    local GEMS=$(echo "$LINK" | grep -oE "gem\d+" | sort -u)
    echo "PMAP $PMAP GEMs: $(echo $GEMS)" | debug
    echo "$GEMS"
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

FIX_ENABLED=$(fw_printenv -n 8311_fix_vlans 2>/dev/null)
if [ -n "$FIX_ENABLED" ] && [ "$FIX_ENABLED" -eq 0 ] 2>/dev/null; then
	[ -n "$CONFIG_FILE" ] && disable_config
	exit 0
fi

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

for PMAPID in $KNOWN_INTERNET_PMAPPERS; do
    PMAP="pmapper$PMAPID"
    if echo "$PMAPS" | grep -q "^${PMAP}$"; then
        INTERNET_PMAP="$PMAP"
        INTERNET_GEMS=$(echo $(get_pmap_gems "$PMAP"))
        echo "Known Internet PMAP and GEMs found: $INTERNET_PMAP - $INTERNET_GEMS" | debug
        echo | debug
        break
    fi
done

for PMAPID in $KNOWN_SERVICES_PMAPPERS; do
    PMAP="pmapper$PMAPID"
    if echo "$PMAPS" | grep -q "^${PMAP}$"; then
        SERVICES_PMAP="$PMAP"
        SERVICES_GEMS=$(echo $(get_pmap_gems "$PMAP"))
        echo "Known Services PMAP and GEMs found: $SERVICES_PMAP - $SERVICES_GEMS" | debug
        echo | debug
        break
    fi
done

if [ -z "$INTERNET_PMAP" ]; then
    for PMAP in $PMAPS; do
        PMAP_GEMS=$(get_pmap_gems "$PMAP")
        PMAP_NUM_GEMS=$(echo "$PMAP_GEMS" | wc -l)
        if [ -z "$SERVICES_PMAP" ] && [ "$PMAP_NUM_GEMS" -gt 1 ]; then
            SERVICES_PMAP="$PMAP"
            SERVICES_GEMS=$(echo $PMAP_GEMS)
            echo | debug
            echo "Services PMAP and GEMs found: $SERVICES_PMAP - $SERVICES_GEMS" | debug
            echo | debug
        elif [ -z "$INTERNET_PMAP" ]; then
            INTERNET_PMAP="$PMAP"
            INTERNET_GEMS=$(echo $PMAP_GEMS)
            echo | debug
            echo "Internet PMAP and GEMs found: $INTERNET_PMAP - $INTERNET_GEMS" | debug
            echo | debug
        fi
    done
fi

if [ -z "$INTERNET_PMAP" ] && [ -n "$SERVICES_PMAP" ]; then
    INTERNET_PMAP=$SERVICES_PMAP
    SERVICES_PMAP=
    INTERNET_GEMS=$SERVICES_GEMS
    SERVICES_GEMS=
fi

UNICAST_VLAN=
if [ -n "$INTERNET_PMAP" ] ; then
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

DEFAULT_SERVICES_VLAN=
if [ -n "$SERVICES_PMAP" ]; then
    TC=$(tc filter show dev "$SERVICES_PMAP" ingress)
    echo | debug
    echo "TC $SERVICES_PMAP ingress:" | debug
    echo "$TC" | debug

    DEFAULT_SERVICES_VLAN=$(echo "$TC" | grep -oE "modify id \d+" | head -n1 | awk '{print $3}')
    [ -z "$UNICAST_VLAN" ] && UNICAST_VLAN=$(echo "$TC" | grep -oE "vlan_id \d+" | head -n1 | awk '{print $2}')

    [ "$UNICAST_VLAN" -eq "$DEFAULT_SERVICES_VLAN" ] 2>/dev/null && DEFAULT_SERVICES_VLAN=
    if [ -z "$UNICAST_VLAN" ] || [ -z "$DEFAULT_SERVICES_VLAN" ]; then
        TC=$(tc filter show dev "$SERVICES_PMAP" egress)
        echo | debug
        echo "TC $SERVICES_PMAP egress:" | debug
        echo "$TC" | debug

        [ -z "$UNICAST_VLAN" ] && UNICAST_VLAN=$(echo "$TC" | grep -oE "modify id \d+" | tail -n1 | awk '{print $3}')
        [ -z "$DEFAULT_SERVICES_VLAN" ] && DEFAULT_SERVICES_VLAN=$(echo "$TC" | grep -oE "vlan_id \d+" | head -n1 | awk '{print $2}')
    fi
fi

[ "$UNICAST_VLAN" -eq "$DEFAULT_SERVICES_VLAN" ] 2>/dev/null && DEFAULT_SERVICES_VLAN=
if [ -z "$UNICAST_VLAN" ] || [ -z "$DEFAULT_SERVICES_VLAN" ]; then
    echo | debug
    [ -z "$UNICAST_VLAN" ] && echo "Failed to find Unicast VLAN from PMAP, falling back to eth0_0 egress method" | debug
    TC=$(tc filter show dev eth0_0 egress)
    echo "TC eth0_0 egress:" | debug
    echo "$TC" | debug
    [ -z "$UNICAST_VLAN" ] && UNICAST_VLAN=$(echo "$TC" | grep -oE "vlan_id \d+" | tail -n1 | awk '{print $2}')
    [ -z "$DEFAULT_SERVICES_VLAN" ] && DEFAULT_SERVICES_VLAN=$(echo "$TC" | grep -oE "modify id (34|36) " | head -n1 | awk '{print $3}')
fi

if [ -n "$UNICAST_VLAN" ]; then
    echo | debug
    echo "Unicast VLAN Found: $UNICAST_VLAN" | debug
fi

[ "$UNICAST_VLAN" -eq "$DEFAULT_SERVICES_VLAN" ] 2>/dev/null && DEFAULT_SERVICES_VLAN=

echo "Getting VLAN settings from fwenvs:" | debug
INTERNET_VLAN=$(fw_printenv -n 8311_internet_vlan 2>/dev/null || fw_printenv -n bell_internet_vlan 2>/dev/null)
SERVICES_VLAN=$(fw_printenv -n 8311_services_vlan 2>/dev/null || fw_printenv -n bell_services_vlan 2>/dev/null)
echo "8311_internet_vlan=$INTERNET_VLAN" | debug
echo "8311_services_vlan=$SERVICES_VLAN" | debug

INTERNET_VLAN=${INTERNET_VLAN:-0}
SERVICES_VLAN=${SERVICES_VLAN:-${DEFAULT_SERVICES_VLAN:-36}}

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

echo "=============" | debug
echo | debug

[ -n "$UNICAST_VLAN" ] || exit 1


echo "Unicast VLAN: $UNICAST_VLAN" | log -create
echo "Multicast GEM: $MULTICAST_GEM" | log
echo "Internet GEMs: $INTERNET_GEMS" | log
echo "Internet PMAP: $INTERNET_PMAP" | log
echo "Services GEMs: $SERVICES_GEMS" | log
echo "Services PMAP: $SERVICES_PMAP" | log
echo "Internet VLAN: $INTERNET_VLAN" | log
echo "Services VLAN: $SERVICES_VLAN" | log

[ -n "$CONFIG_FILE" ] && write_config
