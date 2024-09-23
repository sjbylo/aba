#!/bin/bash
# Convenience script to download the latest operator catalog and add what's required into the imageset file. 

source scripts/include_all.sh

[ "$1" ] && set -x

source <(normalize-aba-conf)
source <(normalize-mirror-conf)

export ocp_ver=$ocp_version
export ocp_ver_major=$(echo $ocp_version | cut -d. -f1-2)

add_op() {
	line=$(grep "^$1 " .redhat-operator-index-v$ocp_ver_major | awk '{print $1,$NF}')
	op_name=$(echo $line | awk '{print $1}')
	op_default_channel=$(echo $line | awk '{print $2}')

	if [ "$op_name" ]; then
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
	echo "'op_sets' value not set in aba.conf or mirror.conf. No operator sets to add to the image config file." >&2
fi

op_sets=$(echo $op_sets | tr -s " ")

if [ "$ops" -o "$op_sets" ]; then
cat <<END
  operators:
  - catalog: registry.redhat.io/redhat/redhat-operator-index:v$ocp_ver_major
    packages:
END
else
	#echo "No individual operators defined in 'aba.conf'.  Not adding any individual operators to the image set config file." >&2
	echo "No operators to add to the catalog index.  No 'op*' values set in aba.conf" >&2

	exit 0
fi

# Check for the index file
if [ ! -s .redhat-operator-index-v$ocp_ver_major ]; then
	echo "Missing operator index file: .redhat-operator-index-v$ocp_ver_major ..." >&2

	exit 0
fi

echo "Adding operator set(s) to the image set config file ..." >&2
###echo "As defined in 'aba.conf' and/or 'mirror/mirror.conf', adding operator set(s) to the image set config file ..." >&2

for set in $op_sets
do
	# read in op list from template
	if [ -s templates/operator-set-$set ]; then
		echo "# $set operators"
		echo -n "$set: " >&2
		for op in $(cat templates/operator-set-$set)
		do
			echo -n "$op " >&2
			add_op $op
		done
		echo >&2
	else
		echo_red "Missing operator set file: templates/operator-set-$set" >&2
	fi
done

if [ "$ops" ]; then
	echo "# misc operators"
	echo -n "Op: " >&2

	for op in $ops
	do
		add_op $op
		echo -n "$op " >&2
	done

	echo >&2
else
	echo "No 'ops' value set in aba.conf or mirror.conf. No individual operators to add to the image config file." >&2
fi


