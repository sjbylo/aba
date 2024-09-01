#!/bin/bash
# Convenience script to download the latest operator catalog and add what's required into the imageset file. 

source scripts/include_all.sh

[ "$1" ] && set -x

source <(normalize-aba-conf)
source <(normalize-mirror-conf)

export ocp_ver=$ocp_version
export ocp_ver_major=$(echo $ocp_version | cut -d. -f1-2)

# Wait for the index to be generated 
[ ! -s .redhat-operator-index-v$ocp_ver_major ] && echo "Waiting for the operator index to be generated ..." >&2
until [ -s .redhat-operator-index-v$ocp_ver_major ]
do
	sleep 5
done

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
		echo_red "Operator name '$1' not found in index file mirror/.redhat-operator-index-v$ocp_ver_major" >&2
	fi
}

if [ ! "$op_sets" ]; then
	echo "'op_sets' value not set in mirror.conf. Skipping operator render." >&2
fi

op_sets=$(echo $op_sets | tr -s " ")

if [ "$ops" -o "$op_sets" ]; then
cat <<END
  operators:
  - catalog: registry.redhat.io/redhat/redhat-operator-index:v$ocp_ver_major
    packages:
END
fi

for set in $op_sets
do
	# read in op list from template
	if [ -s templates/operator-set-$set ]; then
		echo "# $set operators"
		for op in $(cat templates/operator-set-$set)
		do
			add_op $op
		done
	else
		echo_red "No such file 'templates/operator-set-$set' for operator set" >&2
	fi
done

if [ "$ops" ]; then
	echo "# misc operators"
else
	echo "'ops' value not set in mirror.conf. Skipping operator render." >&2
fi
ops=$(echo $ops | tr -s " ")
for op in $ops
do
	add_op $op
done

