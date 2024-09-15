#!/bin/sh
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

tc_exists() {
   tc filter get "$@" &>/dev/null
}

tc_flower_get() {
    tc filter get $(tc_flower_selector "$@")
}

tc_flower_exists() {
    tc_flower_get "$@" &>/dev/null
}

tc_flower_del() {
    local selector=$(tc_flower_selector "$@")
    echo del $selector

    tc_exists "$selector" &&
    tc filter del $selector
}

tc_flower_add() {
    echo add $@

    tc_flower_exists "$@" ||
    tc filter add "$@"
}

tc_flower_replace() {
    echo replace $@

    tc filter del $(tc_flower_selector "$@") 2>/dev/null
    tc filter add "$@"
}

tc_flower_clear() {
   local selector=$(tc_flower_selector -devdironly "$@")
   echo del $selector

   tc filter del $selector
}
