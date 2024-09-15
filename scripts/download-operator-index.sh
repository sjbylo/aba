#!/bin/bash
# Convenience script to download the latest operator catalog and add what's required into the imageset file. 

source scripts/include_all.sh

[ "$1" ] && set -x

source <(normalize-aba-conf)

export ocp_ver=$ocp_version
export ocp_ver_major=$(echo $ocp_version | cut -d. -f1-2)

[ ! "$ocp_ver_major" ] && echo_red "Error, ocp_version not defined" && exit 1

if ! curl --connect-timeout 10 --retry 3 -kIL https://registry.redhat.io/redhat/redhat-operator-index:v$ocp_ver_major >/dev/null 2>&1; then
	echo_red "Error: can't access registry.redhat.io to fetch the operator index.  Aborting."

	exit 1
fi

# FIXME this is a hack. Better implement as dep in make
#make -s -C ../cli ~/bin/oc-mirror 2>/dev/null >&2
scripts/create-containers-auth.sh >/dev/null 2>&1

index_file=.redhat-operator-index-v$ocp_ver_major
lock_file=.redhat-operator-index-v$ocp_ver_major.lock
log_file=.redhat-operator-index-v$ocp_ver_major.log

delete_lock() { rm -f $lock_file; [ ! -s $index_file ] && rm -f $index_file; }
trap 'delete_lock' INT

# See if the index is already downloading (using 'ln') 
[ ! -f $index_file ] && touch $index_file
if ! ln $index_file $lock_file >/dev/null 2>&1; then
	if [ ! -s $index_file ]; then
		echo_magenta "Operator index 'v$ocp_ver_major' is downloading ..."
	else
		echo_white "Operator index 'v$ocp_ver_major' already downloaded."
	fi

	exit 0
fi

echo_blue "The operator index is downloading for v$ocp_ver_major, please wait 3-6 mins ..."

# Lock successful, now download the index ...

# Check if this script is running in the background, if it is then output to a log file
if [ ! -t 0 ]; then
	echo "Downloading operator index from registry.redhat.io/redhat/redhat-operator-index:v$ocp_ver_major (in the background - see $log_file) ...: >&2

	exec >> $log_file 
	exec 2>> $log_file
else
	echo "Downloading operator index from registry.redhat.io/redhat/redhat-operator-index:v$ocp_ver_major ...:
fi

# Fetch latest operator catalog and default channels
if ! oc-mirror list operators --catalog registry.redhat.io/redhat/redhat-operator-index:v$ocp_ver_major > $index_file; then
	echo "$(date): Error: oc-mirror returned $? whilst downloading operator index."
	rm -f $lock_file

	exit 1
fi

tail -n +3 $index_file | awk '{print $1,$NF}' | while read op_name op_default_channel
do
	echo "\
    - name: $op_name
      channels:
      - name: $op_default_channel"
done > imageset-config-operator-catalog-v${ocp_ver_major}.yaml

# Adding this to log file sincxe it will run in the background
echo "$(date): Downloaded operator index for v$ocp_ver_major successfuly"

