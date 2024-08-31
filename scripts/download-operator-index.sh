#!/bin/bash
# Convenience script to download the latest operator catalog and add what's required into the imageset file. 

source scripts/include_all.sh

[ "$1" ] && set -x

source <(normalize-aba-conf)

export ocp_ver=$ocp_version
export ocp_ver_major=$(echo $ocp_version | cut -d. -f1-2)

[ ! "$ocp_ver_major" ] && echo "Error, ocp_version not defined" && exit 1

if ! curl -kIL http://registry.redhat.io/redhat/redhat-operator-index:v$ocp_ver_major >/dev/null 2>&1; then
	echo_red "Error: can't access registry.redhat.io to fetch the operator index.  Aborting."

	exit 1
fi

index_file=.redhat-operator-index-v$ocp_ver_major
lock_file=.redhat-operator-index-v$ocp_ver_major.lock
log_file=.redhat-operator-index-v$ocp_ver_major.log

exec > $log_file
#exec 2> $log_file

# See if the index is already downloaded (using ln)
[ ! -f $index_file ] && touch $index_file
if ! ln $index_file $lock_file >/dev/null 2>&1; then
	echo "Operator index already downloaded - or in progress - for v$ocp_ver_major"
	exit 0
fi

# Fetch latest operator catalog and default channels
if ! oc-mirror list operators --catalog registry.redhat.io/redhat/redhat-operator-index:v$ocp_ver_major > $index_file; then
	rm -f $lock_file
	echo "Error: cannot download operator index.  Aborting."
	exit 1
fi

tail -n +3 $index_file | awk '{print $1,$NF}' | while read op_name op_default_channel
do
	echo "\
    - name: $op_name
      channels:
      - name: $op_default_channel"
done > imageset-config-operator-catalog-v${ocp_ver_major}.yaml

echo "Download operator index for v$ocp_ver_major successfuly" 


