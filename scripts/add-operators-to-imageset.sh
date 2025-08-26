#!/bin/bash
# Convenience script to download the latest operator catalog and add what's required into the imageset file. 

source scripts/include_all.sh

[ "$1" ] && set -x

source <(normalize-aba-conf)
source <(normalize-mirror-conf)

verify-aba-conf || exit 1
verify-mirror-conf || exit 1

export ocp_ver=$ocp_version
export ocp_ver_major=$(echo $ocp_version | cut -d. -f1-2)

declare -A added_operators  # Associative array to track added operators

add_op() {
	# Extract operator name and default channel from the file
	read op_name op_default_channel < <(grep "^$1 " .index/redhat-operator-index-v$ocp_ver_major | awk '{print $1, $NF}')

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
		echo_red "Warning: Operator '$1' not found in index file mirror/.index/redhat-operator-index-v$ocp_ver_major" >&2
	fi
}

if [ ! "$op_sets" ]; then
	[ "$INFO_ABA" ] && echo_cyan "'op_sets' value not set in aba.conf or mirror.conf. Not adding operators to the image set config file." >&2
fi

if [ "$ops" -o "$op_sets" ]; then
	# Check for the index file
	if [ ! -s .index/redhat-operator-index-v$ocp_ver_major ]; then
		echo_red "Error: Missing operator catalog: $PWD/.index/redhat-operator-index-v$ocp_ver_major ... cannot add required operators to the image set config file!" >&2
		echo_red "       Your options are:" >&2
		echo_red "       - Remove any existing catalog files by running: 'cd mirror; rm -f .index/redhat-operator-index-v${ocp_ver_major}*' and try again." >&2
		echo_red "       - run 'cd mirror; aba catalog' to try to download the catalog file again." >&2
		echo_red "       - Check that the following command is working:" >&2
		echo_red "           oc-mirror list operators --catalog registry.redhat.io/redhat/redhat-operator-index:v$ocp_ver_major" >&2
		echo_red "       - Check access to registry is working: 'curl -IL http://registry.redhat.io/v2'" >&2

		exit 1  # We want to ensure the user gets what they expect, i.e. operators downloaded!
	fi

cat <<END
  operators:
  - catalog: registry.redhat.io/redhat/redhat-operator-index:v$ocp_ver_major
    packages:
END

else
	[ "$INFO_ABA" ] && echo_cyan "No 'op*' values set in aba.conf or mirror.conf. Not adding operators to the image set config file." >&2

	exit 0
fi

[ "$INFO_ABA" ] && echo_cyan "Adding operators to the image set config file ..." >&2

# 'all' is a special operator set which allows all operators to be downloaded!  The above "operators->catalog" entry will enable all op.
echo $op_sets | grep -qe "^all$" -e "^all," -e ",all$" -e ",all," && echo_yellow "Adding all operators to your image set config file!" >&2 && exit 0

for set in $(echo $op_sets | tr "," " ")
do
	# read in op list from template
	if [ -s templates/operator-set-$set ]; then
		echo "# $set operators"
		[ "$INFO_ABA" ] && echo_cyan -n "$set: " >&2
		for op in $(cat templates/operator-set-$set | sed -e 's/#.*//' -e '/^\s*$/d' -e 's/^\s*//g' -e 's/\s*$//g')
		do
			[ "$INFO_ABA" ] && echo_cyan -n "$op " >&2
			add_op $op
		done
		#echo >&2
	else
		echo_red "Warning: Missing operator set file: 'templates/operator-set-$set'.  Please adjust your operator settings in aba.conf or create the missing file." >&2
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

echo_cyan "Number of operators added: ${#added_operators[@]}" >&2

exit 0
