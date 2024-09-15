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
		echo_red "Warning: Operator name '$1' not found in index file mirror/.redhat-operator-index-v$ocp_ver_major" >&2
	fi
}

if [ ! "$op_sets" ]; then
	echo "'op_sets' value not set in aba.conf or mirror.conf. Skipping operator sets render." >&2
fi

op_sets=$(echo $op_sets | tr -s " ")

if [ "$ops" -o "$op_sets" ]; then
cat <<END
  operators:
  - catalog: registry.redhat.io/redhat/redhat-operator-index:v$ocp_ver_major
    packages:
END
else
	echo "No operators defined in 'aba.conf'.  Not adding any operators to image set config file." >&2

	exit 0
fi

echo "As defined in 'aba.conf' and/or 'mirror/mirror.conf', adding opperators to the image set conf file ..." >&2

# Wait for the index to be generated?
i=0
if [ ! -s .redhat-operator-index-v$ocp_ver_major ]; then
	echo "Waiting 1-2 mins for the operator index to be generated ..." >&2
	until [ -s .redhat-operator-index-v$ocp_ver_major ]
	do
		sleep 3
	done
	sleep 1

	[ $1 -ge 8 ] && echo_red "Giving up waiting for operator index download! Do you have Internet access?" && break
	let i=$i+1
fi

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
		echo_red "No such file 'templates/operator-set-$set' for operator set" >&2
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
	echo "No 'ops' value set in aba.conf or mirror.conf. Skipping operator render." >&2
fi


