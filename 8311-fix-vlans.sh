#!/bin/sh
_lib_8311 2>/dev/null || . /lib/8311.sh
# OMCI相关命令
omci="/usr/bin/omci_pipe.sh"
omci_simulate="/usr/bin/omci_simulate"


vid_pattern='4096|409[0-4]|(40[0-8]|[1-3][[:digit:]][[:digit:]]|[1-9][[:digit:]]|[1-9])[[:digit:]]|[0-9]'

# =====================================================
# 工具函数
# =====================================================

# 检查ONU状态是否为O5（正常运行状态）
check_onu_state() {
    # 使用与8311.lua相同的方式获取PLOAM状态
    ploamstate=$(pon psg | cut -b21)
    
    # 检查是否为O5状态(50)
    # [50]	= "O5, Operation state",
    if [ "$ploamstate" != "5" ]; then
        return 1
    fi
    return 0
}



collect_olt_type() {
	local spanning_tree

	for i in $(seq 1 30); do
		olt_type=$(
			$omci managed_entity_attr_data_get 131 0 1 |
				sed -n 's/\(attr\_data\=\)/\1/p' |
				cut -f 3 -d '=' |
				sed s/[[:space:]]//g
		)

		spanning_tree=$(
			$omci managed_entity_attr_data_get 45 1 1 |
				sed -n 's/\(attr\_data\=\)/\1/p' |
				sed s/[[:space:]]//g
		)

		if [ "$olt_type" != "20202020" ] && [ -n "$spanning_tree" ]; then
			break
		else
			logger -t "[vlanexec]" "OLT type and spanning tree not detected, waiting..."
			sleep 2
		fi
	done

	echo "OLT type: $olt_type" >/tmp/collect
}

collect_extended_vlan() {
	local me171_associated_me_ptr
	local me171_instances
	local me171_instance_count

	me171_instances=$(
		$omci mib_dump |
			grep "Extended VLAN conf data" |
			sed -n 's/\(0x\)/\1/p' |
			cut -f 3 -d '|' |
			cut -f 1 -d '(' |
			head -n 1 |
			sed s/[[:space:]]//g
	)

	me171_instance_count=$(
		$omci mib_dump |
			grep -c "Extended VLAN conf data"
	)

	if [ "$me171_instance_count" -gt 1 ]; then
		for i in $me171_instances; do
			me171_associated_me_ptr=$(
				$omci managed_entity_attr_data_get 171 "$i" 7 |
					sed -n 's/\(attr\_data\=\)/\1/p' |
					sed s/[[:space:]]//g
			)

			if [ "$me171_associated_me_ptr" = "0101" ]; then
				me171_instance_id=$i
				if [ -n "$vlan_svc_log" ]; then
					logger -t "[vlan]" "ME 171 exists with instance id: $me171_instance_id"
				fi
				break
			fi
		done
	else
		me171_instance_id=$me171_instances
	fi

	if [ -z "$me171_instance_id" ]; then
		echo "ME 171 instance id is null." >>/tmp/collect
	else
		echo "ME 171 instance id: $me171_instance_id" >>/tmp/collect
	fi
}

collect_bridge() {
	local me47_instances
	local me47_tp_type
	local me47_tp_ptr
	local bridge_count

	bridge_count=$(
		$omci mib_dump |
			grep -c "Bridge config data"
	)

	echo "Bridge count is: $bridge_count" >>/tmp/collect

	me47_instances=$(
		$omci mib_dump | grep "Bridge port config data" |
			sed -n 's/\(0x\)/\1/p' |
			cut -f 3 -d '|' |
			cut -f 1 -d '(' |
			sed s/[[:space:]]//g
	)

	for i in $me47_instances; do
		me47_tp_type=$(
			$omci managed_entity_attr_data_get 47 "$i" 3 |
				sed -n 's/\(attr\_data\=\)/\1/p' |
				cut -f 3 -d '=' |
				sed s/[[:space:]]//g
		)

		me47_tp_ptr=$(
			$omci managed_entity_attr_data_get 47 "$i" 4 |
				sed -n 's/\(attr\_data\=\)/\1/p' |
				cut -f 3 -d '=' |
				sed s/[[:space:]]//g
		)

		echo "Bridge port config data: $me47_tp_type, $me47_tp_ptr" >>/tmp/collect

		if [ "$me47_tp_type" = "01" ] && [ "$me47_tp_ptr" = "0101" ]; then
			echo "PPTP UNI brige port exists." >>/tmp/collect
			return
		elif [ "$me47_tp_type" = "0b" ]; then
			echo "VEIP bridge port exists." >>/tmp/collect
			return
		fi
	done

	echo "WARNING: No VEIP/PPTP UNI brige port exists." >>/tmp/collect
}

collect() {
	collect_olt_type
	collect_extended_vlan
	collect_bridge
}


set_me_171() {
	local hw="48575443"
	local alcl="414c434c"
	local zte="5a544547"
	local unset="20202020"

	if [ "$olt_type" = "$unset" ]; then
		olt_type=$(
			$omci managed_entity_attr_data_get 131 0 1 |
				sed -n 's/\(attr\_data\=\)/\1/p' |
				cut -f 3 -d '=' |
				sed s/[[:space:]]//g
		)

		sed -i '/^OLT\ type:*/c\OLT\ type:\ '"$olt_type"'/' /tmp/collect
	fi

	if [ -n "$vlan_svc_log" ]; then
		logger -t "[vlan]" "OLT type: $olt_type"
	fi

	case $olt_type in
	"$hw")
		set_pptp_uni_bridge
		create_me_171 0
		check_me_171
		;;
	"$alcl")
		set_alcl_uni_bridge
		create_me_171 1
		;;
	"$zte")
		set_pptp_uni_bridge
		create_me_171 1
		;;
	*)
		set_pptp_uni_bridge
		create_me_171 1
		;;
	esac
}


set_us_vlan() {
	local vid_tpid_dei
	local vlan_tagging_op
	local vlan_tagging_op_hex
	local vlan_tagging_op_match

	local vid="^($vid_pattern|[u])$"

	if [ -z "$us_vlan_id" ]; then
		if [ -n "$vlan_svc_log" ]; then
			logger -t "[vlan]" "No us_vlan_id is configured."
		fi
		$omci managed_entity_attr_data_set 171 "$me171_instance_id" 6 f8 00 00 00 f8 00 00 00 c0 0f \
			00 00 00 0f 00 00
		return

	elif [ "$(echo "$us_vlan_id" | egrep -c "$vid")" -eq 0 ]; then
		if [ -n "$vlan_svc_log" ]; then
			logger -t "[vlan]" "There was an errror parsing us_vlan_id: $us_vlan_id."
		fi
		return
	fi

	if [ "$us_vlan_id" = "u" ]; then
		logger -t "[vlan]" "Configuration for us_vlan_id is: untagged."
		vlan_tagging_op="f8 00 00 00 f8 00 00 00 00 0f 00 00 00 0f 00 00"
	else
		logger -t "[vlan]" "Configuration for us_vlan_id is: $us_vlan_id."

		vid_tpid_dei=$(
			printf "%04x" $((us_vlan_id * 8 + 4)) |
				sed 's/../& /g'
		)

		vlan_tagging_op="f8 00 00 00 f8 00 00 00 00 0f 80 00 00 00 $vid_tpid_dei"
	fi

	vlan_tagging_op_hex=$(
		echo "$vlan_tagging_op" |
			sed s/[[:space:]]//g |
			sed -r 's/(..)/0x\1/g' |
			sed -r 's/(....)/ \1/g'
	)

	vlan_tagging_op_match=$(
		$omci managed_entity_get 171 "$me171_instance_id" |
			grep "$vlan_tagging_op_hex"
	)

	if [ -n "$vlan_tagging_op_match" ] || [ -z "$force_us_vlan_id" ]; then
		if [ -n "$vlan_svc_log" ]; then
			logger -t "[vlan]" "Match detected for us_vlan_id, or force us_vlan_id is not enabled."
		fi
	else
		if [ -n "$vlan_svc_log" ]; then
			logger -t "[vlan]" "Configuring us_vlan_id..."
		fi
		$omci managed_entity_attr_data_set 171 "$me171_instance_id" 6 "$vlan_tagging_op"
	fi
}

set_mc_vlans() {
	local ds_mc_pcp
	local ds_mc_tci_hex
	local ds_mc_vid
	local gem_port_id
	local gem_port_nw_ctp_con_ptr
	local mc_gem_iw_tp
	local message
	local new_ds_mc_tci
	local old_ds_mc_tci
	local us_mc_vid_hex

	local tci="^($vid_pattern)(@([0-7]))?$"
	local vid="^($vid_pattern)$"

	if [ -z "$ds_mc_tci" ]; then
		if [ -n "$vlan_svc_log" ]; then
			logger -t "[vlan]" "No ds_mc_tci configured."
		fi
		return

	elif [ "$(echo "$ds_mc_tci" | egrep -c "$tci")" -eq 0 ]; then
		if [ -n "$vlan_svc_log" ]; then
			logger -t "[vlan]" "Error parsing ds_mc_tci: $ds_mc_tci."
		fi
		return
	fi

	ds_mc_pcp=$(
		echo "$ds_mc_tci" |
			grep '@' |
			cut -f 2 -d "@"
	)

	ds_mc_vid=$(
		echo "$ds_mc_tci" |
			cut -f 1 -d '@'
	)

	create_me_309

	ds_mc_tci_hex=$((${ds_mc_pcp:=0} * 8192 | ds_mc_vid))

	new_ds_mc_tci="04 $(printf "%04x" "$ds_mc_tci_hex" | sed 's/../& /g')"

	old_ds_mc_tci=$(
		$omci managed_entity_attr_data_get 309 "$me309_instance_id" 16 2>&- |
			cut -f 3 -d '='
	)

	if [ "$old_ds_mc_tci" = "$new_ds_mc_tci" ]; then
		if [ -n "$vlan_svc_log" ]; then
			logger -t "[vlan]" "Match detected for ds_mc_tci."
		fi
	else
		if [ -n "$vlan_svc_log" ]; then
			logger -t "[vlan]" "Configuring ds_mc_tci..."
		fi
		$omci managed_entity_attr_data_set 309 "$me309_instance_id" 16 "$new_ds_mc_tci"
	fi

	if [ -z "$us_mc_vid" ]; then
		if [ -n "$vlan_svc_log" ]; then
			logger -t "[vlan]" "No us_mc_vid is configured."
		fi
		return
	elif [ "$(echo "$us_mc_vid" | egrep -c "$vid")" -eq 0 ]; then
		if [ -n "$vlan_svc_log" ]; then
			logger -t "[vlan]" "Error configuring us_mc_vid: $us_mc_vid."
		fi
		return
	fi

	us_mc_vid_hex=$(
		printf "%04x" "$us_mc_vid" |
			sed 's/../& /g'
	)

	mc_gem_iw_tp=$(
		$omci mib_dump |
			grep "Multicast GEM TP" |
			sed -n 's/\(0x\)/\1/p' |
			cut -f 3 -d '|' |
			cut -f 1 -d '(' |
			sed s/[[:space:]]//g
	)

	if [ -n "$mc_gem_iw_tp" ]; then
		gem_port_nw_ctp_con_ptr=$(
			$omci managed_entity_attr_data_get "281 $mc_gem_iw_tp 1" |
				sed -n 's/\(attr\_data\=\)/\1/p' |
				cut -f 3 -d '=' | cut -f 1 -d '(' |
				sed s/[[:space:]]//g
		)

		gem_port_id=$(
			$omci managed_entity_attr_data_get "268 0x$gem_port_nw_ctp_con_ptr 1" |
				cut -f 3 -d '='
		)

		if [ -n "$vlan_svc_log" ]; then
			message=$(cat "Detected multicast GEM interworking TP, multicast GEM port id: " \
				"$gem_port_id, configuring...")
			logger -t "[vlan]" "$message"
		fi

		$omci managed_entity_attr_data_set 309 "$me309_instance_id" 7 40 00 "$gem_port_id" \
			"$us_mc_vid_hex" 00 00 00 00 e0 00 01 00 ef ff ff ff 00 00 00 00 00 00
	fi
}

delete_vlan_translation() {
	local filter_inner_word
	local vlan_tagging_op

	filter_inner_word=$(
		echo "8$(printf "%04x" $(($1 * 8)))0" |
			sed 's/../& /g'
	)

	vlan_tagging_op="f8 00 00 00 $filter_inner_word 00 ff ff ff ff ff ff ff ff"
	logger -t "[vlanexec]" "Deleting VLAN tagging operation $1."
	$omci managed_entity_attr_data_set "171 $me171_instance_id 6 $vlan_tagging_op"
}

check_vlan_translations() {
	local vlan_tagging_ops_num

	local tci_a="($vid_pattern)(@([0-7]))?"
	local tci_b="([u]|$vid_pattern)(@([0-7]))?"
	local pattern="^($tci_a\\:$tci_b)(,$tci_a\\:$tci_b)*$"

	if [ -z "$vlan_tag_ops" ]; then
		if [ -n "$vlan_svc_log" ]; then
			logger -t "[vlan]" "No vlan_tag_ops is configured."
		fi
		return

	elif [ "$(echo "$vlan_tag_ops" | egrep -c "$pattern")" -eq 0 ]; then
		if [ -n "$vlan_svc_log" ]; then
			logger -t "[vlan]" "Error parsing vlan_tag_ops: \"$vlan_tag_ops\"."
		fi
		return
	fi

}


set_vlan_translations() {
	local priority_a
	local priority_b
	local vlan_a
	local vlan_b
	local vlan_tagging_op
	local vlan_tagging_ops_num
	local vlan_tagging_op_hex
	local vlan_tagging_op_match

	local tci_a="($vid_pattern)(@([0-7]))?"
	local tci_b="([u]|$vid_pattern)(@([0-7]))?"
	local pattern="^($tci_a\\:$tci_b)(,$tci_a\\:$tci_b)*$"

	if [ -z "$vlan_tag_ops" ]; then
		if [ -n "$vlan_svc_log" ]; then
			logger -t "[vlan]" "No vlan_tag_ops is configured."
		fi
		return

	elif [ "$(echo "$vlan_tag_ops" | egrep -c "$pattern")" -eq 0 ]; then
		if [ -n "$vlan_svc_log" ]; then
			logger -t "[vlan]" "Error parsing vlan_tag_ops: $vlan_tag_ops."
		fi
		return
	fi

	vlan_tagging_ops_num=$(
		echo "$vlan_tag_ops" |
			grep -o ":" | grep -c ":"
	)

	for i in $(seq 1 "$vlan_tagging_ops_num"); do
		vlan_a=$(
			echo "$vlan_tag_ops" |
				cut -f "$i" -d ',' |
				cut -f 1 -d ':' |
				cut -f 1 -d '@'
		)

		vlan_b=$(
			echo "$vlan_tag_ops" |
				cut -f "$i" -d ',' |
				cut -f 2 -d ':' |
				cut -f 1 -d '@'
		)

		priority_a=$(
			echo "$vlan_tag_ops" |
				cut -f "$i" -d ',' |
				cut -f 1 -d ':' |
				grep '@' |
				cut -f 2 -d "@"
		)

		priority_b=$(
			echo "$vlan_tag_ops" |
				cut -f "$i" -d ',' |
				cut -f 2 -d ':' |
				grep '@' |
				cut -f 2 -d "@"
		)

		filter_inner=$(
			printf "%04x" "$((vlan_a * 8))"
		)

		treatment_inner=$(
			printf "%04x" "$((vlan_b * 8))" |
				sed 's/../& /g'
		)

		filter_inner_word=$(
			echo "${priority_a:=8}${filter_inner}0" |
				sed 's/../& /g'
		)

		treatment_inner_word="00 0${priority_b:=8} $treatment_inner"

		if [ "$vlan_b" = "u" ]; then
			treatment_inner_word="0x00 0x0f 0x00 0x00"
		fi

		vlan_tagging_op="f8 00 00 00 $filter_inner_word 00 40 0f 00 00 $treatment_inner_word"

		vlan_tagging_op_hex=$(
			echo "$vlan_tagging_op" |
				sed s/[[:space:]]//g |
				sed -r 's/(..)/0x\1/g' |
				sed -r 's/(....)/ \1/g'
		)

		vlan_tagging_op_match=$(
			$omci managed_entity_get 171 "$me171_instance_id" |
				grep "$vlan_tagging_op_hex"
		)

		if [ -n "$vlan_tagging_op_match" ]; then
			if [ -n "$vlan_svc_log" ]; then
				logger -t "[vlan]" "Match detected for VLAN tagging operation $i: $vlan_a:$vlan_b."
			fi
		else
			if [ -n "$vlan_svc_log" ]; then
				logger -t "[vlan]" "Configuring VLAN tagging operation $i: $vlan_a:$vlan_b"
			fi
			$omci managed_entity_attr_data_set 171 "$me171_instance_id 6 $vlan_tagging_op"
		fi
	done
}

set_pptp_uni_bridge() {
	local bridge_instance
	local me47_instances
	local me47_tp_type
	local me47_tp_ptr
	local message
	local spanning_tree

	me47_instances=$(
		$omci mib_dump | grep "Bridge port config data" |
			sed -n 's/\(0x\)/\1/p' |
			cut -f 3 -d '|' |
			cut -f 1 -d '(' |
			sed s/[[:space:]]//g
	)

	spanning_tree=$(
		$omci managed_entity_attr_data_get 45 1 1 |
			sed -n 's/\(attr\_data\=\)/\1/p' |
			cut -f 3 -d '=' |
			sed s/[[:space:]]//g
	)

	if [ -n "$vlan_svc_log" ]; then
		logger -t "[vlan]" "ME 47 instances: $me47_instances"
	fi

	for i in $me47_instances; do
		me47_tp_type=$(
			$omci managed_entity_attr_data_get 47 "$i" 3 |
				sed -n 's/\(attr\_data\=\)/\1/p' |
				cut -f 3 -d '=' |
				sed s/[[:space:]]//g
		)

		me47_tp_ptr=$(
			$omci managed_entity_attr_data_get 47 "$i" 4 |
				sed -n 's/\(attr\_data\=\)/\1/p' |
				cut -f 3 -d '=' |
				sed s/[[:space:]]//g
		)

		if [ "$me47_tp_type" = "01" ] && [ "$me47_tp_ptr" = "0101" ]; then
			if [ -n "$vlan_svc_log" ]; then
				logger -t "[vlan]" "PPTP UNI bridge port exists with instance id: $i"
			fi

			pptp_uni_bridge=$i

			$omci managed_entity_attr_data_set 47 "$i" 3 1
			$omci managed_entity_attr_data_set 47 "$i" 4 01 01
			$omci managed_entity_attr_data_set 47 "$i" 7 "$spanning_tree"

			return
		fi
	done

	me47_tp_type=$(
		$omci managed_entity_attr_data_get 47 1 3 |
			sed -n 's/\(attr\_data\=\)/\1/p' |
			cut -f 3 -d '=' |
			sed s/[[:space:]]//g
	)

	if [ -n "$me47_tp_type" ]; then
		$omci managed_entity_delete 47 1
	fi

	bridge_instance=$(
		$omci mib_dump |
			grep "Bridge config data" |
			sed -n 's/\(0x\)/\1/p' |
			cut -f 3 -d '|' |
			cut -f 1 -d '(' |
			tail -n 1 |
			sed s/[[:space:]]//g
	)

	if [ -n "$vlan_svc_log" ]; then
		message="No PPTP UNI bridge port detected, creating with instance id 1."
		logger -t "[vlan]" "$message"
	fi

	$omci managed_entity_create 47 1 "$bridge_instance" 1 1 257 0 1 \
		"$(echo "$spanning_tree" | cut -c 2-3)" 1 1

	pptp_uni_bridge=1
}

rollback_mib_data_sync() {
	local mib_data_sync

	mib_data_sync=$(
		$omci managed_entity_attr_data_get 2 0 1 |
			sed -n 's/\(attr\_data\=\)/\1/p' |
			cut -f 3 -d '=' |
			sed s/[[:space:]]//g
	)

	mib_data_sync=$(printf "%x" "$((0x$mib_data_sync - 0x3))")

	$omci managed_entity_attr_data_set 2 0 1 "$mib_data_sync"

	if [ -n "$vlan_svc_log" ]; then
		logger -t "[vlan]" "MIB data sync: $mib_data_sync."
	fi
}

create_me_171() {
	local me171_associated_me_ptr
	local create_flag
	local instance_id
	local me171_instances
	local me171_instance_count
	local me47_instance_id
	local original
	local replacment

	create_flag=$1

	me171_instances=$(
		$omci mib_dump |
			grep "Extended VLAN conf data" |
			sed -n 's/\(0x\)/\1/p' |
			cut -f 3 -d '|' |
			cut -f 1 -d '(' |
			sed s/[[:space:]]//g
	)

	me171_instance_count=$(
		$omci mib_dump |
			grep -c "Extended VLAN conf data"
	)

	if [ "$me171_instance_count" -gt 1 ]; then
		for i in $me171_instances; do
			me171_associated_me_ptr=$(
				$omci managed_entity_attr_data_get 171 "$i" 7 |
					sed -n 's/\(attr\_data\=\)/\1/p' |
					sed s/[[:space:]]//g
			)

			if [ "$me171_associated_me_ptr" = "0101" ]; then
				me171_instance_id=$i
				if [ -n "$vlan_svc_log" ]; then
					logger -t "[vlan]" "ME 171 exists with instance id: $me171_instance_id"
				fi
				break
			fi
		done
	else
		me171_instance_id=$me171_instances
	fi

	me47_instance_id=$pptp_uni_bridge

	case $create_flag in
	0)
		if [ -z "$me171_instance_id" ] && [ -n "$vlan_svc_log" ]; then
			logger -t "[vlan]" "ME 171 instance id should not be null."
		fi
		;;
	1)
		if [ -z "$me171_instance_id" ]; then
			# new create me171,untag discard,tag transparent
			instance_id=$(
				printf "%04x" "$((me47_instance_id))" |
					sed 's/../& /g' |
					sed 's/[ ]*$//g'
			)

			original=$(
				sed -n '2p' /etc/me171 |
					cut -c 43-50
			)

			replacment="ab $instance_id"

			sed -i "s/$original/$replacment/" /etc/me171
			$omci_simulate /etc/me171
			sleep 5
			rollback_mib_data_sync

			if [ -n "$vlan_svc_log" ]; then
				logger -t "[vlan]" "Creating ME 171 with instance id: $me47_instance_id"
			fi

			me171_instance_id=$me47_instance_id
		fi
		;;
	*)
		if [ -n "$vlan_svc_log" ]; then
			logger -t "[vlan]" "ME 171 create_flag value error."
		fi
		;;
	esac
}

create_me_309() {
	local me309_instance_count

	me309_instance_id=$(
		$omci mib_dump |
			grep 309 |
			sed -n 's/\(0x\)/\1/p' |
			cut -f 3 -d '|' |
			cut -f 1 -d '(' |
			head -n 1 |
			sed s/[[:space:]]//g
	)

	me309_instance_count=$(
		$omci mib_dump |
			grep -c 309
	)

	if [ -z "$me309_instance_id" ] ||
		{ [ -n "$force_me309_create" ] &&
			[ "$me309_instance_count" -ge 2 ]; }; then

		me309_instance_id=$pptp_uni_bridge

		if [ -n "$vlan_svc_log" ]; then
			logger -t "[vlan]" "ME 309 does not exist or force_me309_create enabled, creating with instance id: $me309_instance_id"
		fi

		$omci managed_entity_create 309 "$me309_instance_id" "${igmp_version:=3}" 0 1 0 0 32
		$omci managed_entity_attr_data_set 309 "$me309_instance_id" 10 02
		$omci managed_entity_attr_data_set 309 "$me309_instance_id" 12 00 00 00 7d
		$omci managed_entity_attr_data_set 309 "$me309_instance_id" 13 00 00 00 64
		$omci managed_entity_attr_data_set 309 "$me309_instance_id" 15 01
		$omci managed_entity_create 310 "$me309_instance_id" 0 "$me309_instance_id" 64 0 1
		$omci managed_entity_create 311 "$me309_instance_id" 0
		sleep 5
	else
		if [ -n "$vlan_svc_log" ]; then
			logger -t "[vlan]" "ME 309 already exists with instance id: $me309_instance_id"
		fi
		$omci managed_entity_attr_data_set 309 "$me309_instance_id" 1 "0$igmp_version"
	fi
}

set_alcl_uni_bridge() {
	local me47_instances
	local me47_tp_type
	local me47_tp_ptr
	local spanning_tree

	me47_instances=$(
		$omci mib_dump |
			grep "Bridge port config data" |
			sed -n 's/\(0x\)/\1/p' |
			cut -f 3 -d '|' |
			cut -f 1 -d '(' |
			sed s/[[:space:]]//g
	)

	spanning_tree=$(
		$omci managed_entity_attr_data_get 45 1 1 |
			sed -n 's/\(attr\_data\=\)/\1/p' |
			cut -f 3 -d '=' |
			sed s/[[:space:]]//g
	)

	for i in $me47_instances; do
		me47_tp_type=$(
			$omci managed_entity_attr_data_get 47 "$i" 3 |
				sed -n 's/\(attr\_data\=\)/\1/p' |
				cut -f 3 -d '=' |
				sed s/[[:space:]]//g
		)

		me47_tp_ptr=$(
			$omci managed_entity_attr_data_get 47 "$i" 4 |
				sed -n 's/\(attr\_data\=\)/\1/p' |
				cut -f 3 -d '=' |
				sed s/[[:space:]]//g
		)

		if [ "$me47_tp_type" = "01" ] && [ "$me47_tp_ptr" = "0101" ]; then
			if [ -n "$vlan_svc_log" ]; then
				logger -t "[vlan]" "PPTP UNI bridge port exists with instance id: $i"
			fi

			if [ -n "$force_me_create" ]; then
				$omci managed_entity_attr_data_set 47 "$i" 3 1
				$omci managed_entity_attr_data_set 47 "$i" 4 01 01
			fi

			$omci managed_entity_attr_data_set 47 "$i" 7 "$spanning_tree"

			pptp_uni_bridge=$i

			return
		elif [ "$me47_tp_type" = "0b" ]; then
			if [ -n "$vlan_svc_log" ]; then
				logger -t "[vlan]" "VEIP bridge port exists with instance id: $i"
			fi

			$omci managed_entity_attr_data_set 47 "$i" 3 1
			$omci managed_entity_attr_data_set 47 "$i" 4 01 01
			$omci managed_entity_attr_data_set 47 "$i" 7 "$spanning_tree"

			pptp_uni_bridge=$i

			return
		fi
	done
}

check_me_171() {
	local current_single_tag_value
	local current_double_tag_value
	local vlan_tagging_op
	local vlan_tagging_ops_num

	local single_tag_value="0xf80x000x000x000xe80x000x000x000x000x0f0x000x000x000x0f0x000x00"
	local double_tag_value="0xe80x000x000x000xe80x000x000x000x000x0f0x000x000x000x0f0x000x00"

	current_single_tag_value=$(
		$omci managed_entity_get 171 "$me171_instance_id" |
			grep "0xf8 0x00 0x00 0x00 0xe8" |
			tail -n 1 |
			sed s/[[:space:]]//g
	)

	current_double_tag_value=$(
		$omci managed_entity_get 171 "$me171_instance_id" |
			grep "0xe8 0x00 0x00 0x00 0xe8" |
			tail -n 1 |
			sed s/[[:space:]]//g
	)

	$omci managed_entity_get 171 "$me171_instance_id" |
		sed -n '/^ 5 RX frame VLAN table/,$p' |
		sed '/^ 6 Associated ME ptr/,$d' |
		grep '^   0x' |
		grep -v "0xf8 0x00 0x00 0x00 0xe8" |
		grep -v "0xe8 0x00 0x00 0x00 0xe8" |
		sed 's/^   //g' |
		sed 's/0x//g' >/tmp/me171_rule

	vlan_tagging_ops_num=$(
		$omci managed_entity_get 171 1 |
			sed -n '/^ 5 RX frame VLAN table/,$p' |
			sed '/^ 6 Associated ME ptr/,$d' |
			grep '^   0x' |
			grep -v "0xf8 0x00 0x00 0x00 0xe8" |
			grep -vc "0xf8 0x00 0x00 0x00 0xe8"
	)

	if [ "$vlan_tagging_ops_num" -ge 1 ] && [ -n "$vlan_svc_log" ]; then
		for i in $(seq 1 "$vlan_tagging_ops_num"); do
			vlan_tagging_op=$(tail -n "$i" /tmp/me171_rule | head -n 1)
			logger -t "[vlan]" "ME 171 VLAN tagging operation: $vlan_tagging_op"
		done
	fi

	if [ -n "$force_me_create" ] ||
		{ [ "$current_single_tag_value" != "$single_tag_value" ] ||
			[ "$current_double_tag_value" != "$double_tag_value" ]; }; then
		if [ -n "$vlan_svc_log" ]; then
			logger -t "[vlan]" "Default VLAN tagging operation does not match or force_me_create enabled, creating..."
		fi

		$omci managed_entity_attr_data_set 171 "$me171_instance_id" 6 f8 00 00 00 e8 00 00 00 00 0f 00 00 00 0f 00 00
		$omci managed_entity_attr_data_set 171 "$me171_instance_id" 6 e8 00 00 00 e8 00 00 00 00 0f 00 00 00 0f 00 00

		if [ "$vlan_tagging_ops_num" -ge 1 ]; then
			for i in $(seq 1 "$vlan_tagging_ops_num"); do
				vlan_tagging_op=$(tail -n "$i" /tmp/me171_rule | head -n 1)
				$omci managed_entity_attr_data_set 171 "$me171_instance_id" 6 "$vlan_tagging_op"
			done
		fi
	fi
}

main() {
			collect
			check_vlan_translations
			set_me_171
			set_us_vlan
			set_mc_vlans
			set_vlan_translations
}


# =====================================================
# 主程序
# =====================================================

us_vlan_id=$(fwenv_get_8311 "us_vlan_id")
vlan_tag_ops=$(fwenv_get_8311 "vlan_tag_ops")
ds_mc_tci=$(fwenv_get_8311 "ds_mc_tci")
us_mc_vid=$(fwenv_get_8311 "us_mc_vlan_id")
igmp_version=$(fwenv_get_8311 "igmp_version")
force_me_create=$(fwenv_get_8311 "force_me_create")
force_me309_create=$(fwenv_get_8311 "force_me309_create")
force_us_vlan_id=$(fwenv_get_8311 "force_us_vlan_id")
vlan_svc_log=$(fwenv_get_8311 "vlan_svc_log")

# 验证ONU状态，如果不是O5状态则退出
if ! check_onu_state; then
    logger -t "8311-fixvlan" -p daemon.info "Exiting: ONU not in O5 state"
    exit 0
fi

# 初始化并配置VLAN规则
logger -t "8311-fixvlan" -p daemon.info "Starting VLAN configuration..."

main

logger -t "8311-fixvlan" -p daemon.info "VLAN configuration completed"
exit 0
