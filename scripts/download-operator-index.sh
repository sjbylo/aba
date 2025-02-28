#!/bin/bash
# Convenience script to download the latest operator catalog and add what's required into the imageset file. 
# The script is complicated becasue it can do the downloading in the background to save time!

source scripts/include_all.sh

# Only background for the opertor index to be downloaded, e.g. if it likely will be needed!
if [ "$1" = "true" ]; then
	shift
	# Daemon the script!
	( $0 --bg $* & ) & 

	exit 0
fi

[ "$1" = "--bg" ] && bg=1 && shift  # Now we know if this script is running as a daemon 
[ "$1" ] && set -x

source <(normalize-aba-conf)

verify-aba-conf || exit 1

[ ! "$ocp_version" ] && echo_red "Error, ocp_version incorrectly defined in aba.conf!" >&2 && exit 1

export ocp_ver=$ocp_version
export ocp_ver_major=$(echo $ocp_version | cut -d. -f1-2)

mkdir -p .index
index_file=.index/redhat-operator-index-v$ocp_ver_major
lock_file=.index/redhat-operator-index-v$ocp_ver_major.lock
log_file=.index/redhat-operator-index-v$ocp_ver_major.log
pid_file=.index/redhat-operator-index-v$ocp_ver_major.pid
done_file=.index/redhat-operator-index-v$ocp_ver_major.done

# Clean up on INT
handle_interupt() { echo_red "Aborting catalog download." >&2; [ ! -s $index_file ] && rm -f $index_file; rm -f $lock_file $pid_file; exit 0;}
trap 'handle_interupt' INT

# Check if this script is running in the background, if it is then output to a log file
#if [ ! -t 0 ]; then
if [ "$bg" ]; then
	#echo "Downloading operator index in the background from registry.redhat.io/redhat/redhat-operator-index:v$ocp_ver_major (see $log_file) ..." >&2

	exec > $log_file 
	exec 2> $log_file
fi

# Check connectivity to registry
if ! curl --connect-timeout 15 --retry 3 -IL http://registry.redhat.io/v2 >/dev/null 2>&1; then
	echo_red "Error: cannot access the registry: https://registry.redhat.io/.  Aborting." >&2

	exit 1
fi

# FIXME: this is a hack. Better implement as dep in makefile?
scripts/create-containers-auth.sh >/dev/null 2>&1

[[ -s $index_file && -f $done_file ]] && echo_white "Operator index v$ocp_ver_major already downloaded to file mirror/$index_file" && exit 0

# See if the index is already downloaded
[ ! -f $index_file ] && touch $index_file

# See if the index is currently downloading (using 'ln' to get a lock)
if ! ln $index_file $lock_file >/dev/null 2>&1; then
	[ "$DEBUG_ABA" ] && echo "Lock file $lock_file already exists ..." >&2
	# Passed here only if the lock file exists (i.e. index already downloading) 

	# If still downloading...
	if [[ -s $index_file && -f $done_file ]]; then
		echo_white "Operator index v$ocp_ver_major already downloaded to file mirror/$index_file"
	else
		# No need to wait if operator vars are not defined in aba.conf!
		if [ ! "$op_sets" -a ! "$ops" ]; then
			[ "$DEBUG_ABA" ] && echo "No operators defined ..."
			exit 0
		fi

		# Check to be sure the command with the expected pid is running

		# If the bg process is no longer running, then reset and try to download again
		if [ -f $pid_file ]; then
			[ "$DEBUG_ABA" ] && echo "PID file $pid_file found ..." >&2
			bg_pid=$(cat $pid_file)
			if ! pgrep -u $(whoami) -f download-operator-index.sh | grep -q "^$bg_pid$"; then
				[ "$DEBUG_ABA" ] && echo "Background process with pid [$bg_pid] not running" >&2
				rm -f $lock_file $pid_file
				[ "$DEBUG_ABA" ] && echo "Re-running script $0" >&2
				sleep 1
				exec $0
			fi

			# OK, oc-mirror bg process is still running
		else
			[ "$DEBUG_ABA" ] && echo "Expected pid file $pid_file not found!" >&2
		fi

		handle_interupt() { echo_red "Stopped waiting for download to complete" >&2; exit 0; }
		echo_magenta "Waiting for operator index v$ocp_ver_major to finish downloading in the background (process id = `cat $pid_file`) ..."
		if ! try_cmd -q 5 0 120 test -f $done_file; then
		       	echo "Giving up waiting for index download! Please check: mirror/$log_file"  # keep checking completion for max 600s (5 x 120s)
			rm -f $lock_file  # Remove just the lock file

			exit 1
		fi

		echo_white "Operator index v$ocp_ver_major download to file mirror/$index_file has completed"
	fi

	exit 0
fi

echo $$ > $pid_file

# Lock successful, now download the index ...

# If running in forground, on INT, delete lock AND run $0 in background
## NOT A GOOD IDEA [ -t 0 ] && handle_interupt() { echo_red "Putting download into background" >&2; rm -f $lock_file; ( $0 $* > .fetch-index.log 2>&1 & ) & exit 0; }
### FIX ME [ -t 0 ] && handle_interupt() { echo_red "Stopping download" >&2; rm -f $lock_file;  exit 0; }

echo_cyan "Downloading Operator index v$ocp_ver_major to $index_file, please wait a few minutes ..."

make -sC ../cli ~/bin/oc-mirror 

# Fetch latest operator catalog and default channels
echo Running: oc-mirror list operators --catalog registry.redhat.io/redhat/redhat-operator-index:v$ocp_ver_major >&2
oc-mirror list operators --catalog registry.redhat.io/redhat/redhat-operator-index:v$ocp_ver_major > $index_file
ret=$?
if [ $ret -ne 0 ]; then
	echo_red "Error: oc-mirror returned $ret whilst downloading operator index from registry.redhat.io/redhat/redhat-operator-index:v$ocp_ver_major." >&2
	rm -f $lock_file $pid_file

	exit 1
fi

touch $done_file   # This marks successful completion of download!

# If the catalog is downloaded ok, we leave the lock file so there's no risk of it being overwritten. 

echo_white "Downloaded $index_file successfully"

# Generate a handy yaml file with operators which can be manually copied into image set config if needed.
tail -n +3 $index_file | awk '{print $1,$NF}' | while read op_name op_default_channel
do
	echo "\
    - name: $op_name
      channels:
      - name: $op_default_channel"
done > imageset-config-operator-catalog-v${ocp_ver_major}.yaml

echo_white "Generated imageset-config-operator-catalog-v${ocp_ver_major}.yaml file"

# Keep the lock file since we assume the catalog was downloaded ok
##rm -f $lock_file $pid_file

# Adding this to log file since it will run in the background
echo_green "Downloaded operator index for v$ocp_ver_major successfully"

