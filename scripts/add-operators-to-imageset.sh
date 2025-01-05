#!/bin/bash
# Convenience script to download the latest operator catalog and add what's required into the imageset file. 

source scripts/include_all.sh

[ "$1" ] && set -x

source <(normalize-aba-conf)
source <(normalize-mirror-conf)

export ocp_ver=$ocp_version
export ocp_ver_major=$(echo $ocp_version | cut -d. -f1-2)

declare -A added_operators  # Associative array to track added operators

add_op() {
	# Extract operator name and default channel from the file
	read op_name op_default_channel < <(grep "^$1 " .redhat-operator-index-v$ocp_ver_major | awk '{print $1, $NF}')

	# Check if the operator name exists
	if [ "$op_name" ]; then
		# Skip if the operator has already been added
		if [ -n "${added_operators[$op_name]}" ]; then
			echo "Operator '$op_name' already added. Skipping..." >&2
			###echo "    # $op_name added above"
			return
		fi

		# Mark the operator as added
		added_operators["$op_name"]=1

		# Output the operator information
		if [ "$op_default_channel" ]; then
			echo "\
    - name: $op_name
      channels:
      - name: $op_default_channel"
		else
			echo "\
    - name: $op_name"
		fi
	else
		echo_red "Warning: Operator '$1' not found in index file mirror/.redhat-operator-index-v$ocp_ver_major" >&2
	fi
}

if [ ! "$op_sets" ]; then
	[ "$INFO_ABA" ] && echo_cyan "'op_sets' value not set in aba.conf or mirror.conf. Not adding operators to the image set config file." >&2
fi

###op_sets=$(echo $op_sets | tr -s " ")

if [ "$ops" -o "$op_sets" ]; then
	# Check for the index file
	if [ ! -s .redhat-operator-index-v$ocp_ver_major ]; then
		echo_red "Warning: Missing operator index file: .redhat-operator-index-v$ocp_ver_major ... not adding your selected operators to the image set config!" >&2

		exit 0
	fi

cat <<END
  operators:
  - catalog: registry.redhat.io/redhat/redhat-operator-index:v$ocp_ver_major
    packages:
END
else
	[ "$INFO_ABA" ] && echo_cyan "No 'op*' values set in aba.conf. Not adding operators to the image set config file." >&2

	exit 0
fi

[ "$INFO_ABA" ] && echo_cyan "Adding operators to the image set config file ..." >&2

for set in $(echo $op_sets | tr "," " ")
do
	# read in op list from template
	if [ -s templates/operator-set-$set ]; then
		echo "# $set operators"
		[ "$INFO_ABA" ] && echo_cyan -n "$set: " >&2
		for op in $(cat templates/operator-set-$set)
		do
			[ "$INFO_ABA" ] && echo_cyan -n "$op " >&2
			add_op $op
		done
		#echo >&2
	else
		echo_red "Warning: Missing operator set file: 'templates/operator-set-$set'.  Please adjust your operator settings in aba.conf or create the file." >&2
	fi
done

if [ "$ops" ]; then
	echo "# misc operators"
	[ "$INFO_ABA" ] && echo_cyan -n "Op: " >&2

	for op in $(echo $ops | tr "," " ")
	do
		[ "$INFO_ABA" ] && echo_cyan -n "$op " >&2
		add_op $op
	done
	#echo >&2
else
	[ "$INFO_ABA" ] && echo_cyan "No 'ops' value set in aba.conf or mirror.conf. No individual operators to add to the image set config file." >&2
fi

exit 0
