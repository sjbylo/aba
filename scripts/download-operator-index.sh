#!/bin/bash
# Convenience script to download the latest operator catalog and add what's required into the imageset file. 

source scripts/include_all.sh

# Only background for the opertor index to be downloaded, e.g. if it liekly will be needed!
if [ "$1" = "--background" ]; then
	shift
	# Daemon the script!
	( $0 $* & ) & 
	exit 0
fi

[ "$1" ] && set -x

# Clean up on INT
handle_interupt() { echo_red "Aborting download."; rm -f $lock_file $pid_file; [ ! -s $index_file ] && rm -f $index_file; exit 0;}
trap 'handle_interupt' INT

source <(normalize-aba-conf)

[ ! "$ocp_version" ] && echo_red "Error, ocp_version not defined in aba.conf!" >&2 && exit 1

export ocp_ver=$ocp_version
export ocp_ver_major=$(echo $ocp_version | cut -d. -f1-2)

index_file=.redhat-operator-index-v$ocp_ver_major
lock_file=.redhat-operator-index-v$ocp_ver_major.lock
log_file=.redhat-operator-index-v$ocp_ver_major.log
pid_file=.redhat-operator-index-v$ocp_ver_major.pid

# Check if this script is running in the background, if it is then output to a log file
if [ ! -t 0 ]; then
	echo "Downloading operator index in the background from registry.redhat.io/redhat/redhat-operator-index:v$ocp_ver_major (see $log_file) ..." >&2

	exec > $log_file 
	exec 2> $log_file
else
	echo "Downloading operator index from registry.redhat.io/redhat/redhat-operator-index:v$ocp_ver_major ..."
fi

if ! curl --connect-timeout 15 --retry 3 -kIL https://registry.redhat.io/redhat/redhat-operator-index:v$ocp_ver_major >/dev/null 2>&1; then
	echo_red "Error: while fetching the operator index from https://registry.redhat.io/.  Aborting." >&2

	exit 1
fi

# FIXME this is a hack. Better implement as dep in makefile?
scripts/create-containers-auth.sh >/dev/null 2>&1

# See if the index is already downloading (using 'ln') 
[ ! -f $index_file ] && touch $index_file
if ! ln $index_file $lock_file >/dev/null 2>&1; then
	# Passed here only if the lock file exists (index already downloading) 

	# If still downloading...
	if [ ! -s $index_file ]; then
		# No need to wait if operator vars are not defined in aba.conf!
		[ ! "$op_sets" -a ! "$ops" ] && exit 0

		handle_interupt() { echo_red "Stopped waiting for download to complete"; exit 0; }
		echo_magenta "Waiting for operator index v$ocp_ver_major to finish downloading in the background (process id = `cat $pid_file`) ..."
		try_cmd -q 2 0 150 test -s $index_file || true  # keep checking file does not have content, for max 300s (2 x 150s)
	else
		echo_white "Operator index v$ocp_ver_major already downloaded at $index_file"
	fi

	exit 0
fi

echo $$ > $pid_file

echo_cyan "Operator index v$ocp_ver_major is already downloading to $index_file, please wait a few minutes ..."

# Lock successful, now download the index ...

# If running in forground, on INT, delete lock AND run $0 in background
## NOT A GOOD IDEA [ -t 0 ] && handle_interupt() { echo_red "Putting download into background"; rm -f $lock_file; ( $0 $* > .fetch-index.log 2>&1 & ) & exit 0; }
### FIX ME [ -t 0 ] && handle_interupt() { echo_red "Stopping download"; rm -f $lock_file;  exit 0; }

# Fetch latest operator catalog and default channels
if ! oc-mirror list operators --catalog registry.redhat.io/redhat/redhat-operator-index:v$ocp_ver_major > $index_file; then
	echo_red "Error: oc-mirror returned $? whilst downloading operator index from registry.redhat.io/redhat/redhat-operator-index:v$ocp_ver_major."
	rm -f $lock_file $pid_file

	exit 1
fi

echo_white "Downloaded $index_file"

# Generate a handy yaml file with operators which can be manually copied into image set confgi if needed.
tail -n +3 $index_file | awk '{print $1,$NF}' | while read op_name op_default_channel
do
	echo "\
    - name: $op_name
      channels:
      - name: $op_default_channel"
done > imageset-config-operator-catalog-v${ocp_ver_major}.yaml
echo_white "Generated imageset-config-operator-catalog-v${ocp_ver_major}.yaml file"

##rm -f $lock_file $pid_file

# Adding this to log file since it will run in the background
echo_green "Downloaded operator index for v$ocp_ver_major successfully"

