#!/bin/bash
# Convenience script to download the latest operator catalog and add what's required into the imageset file. 
# The script is complicated becasue it can do the downloading in the background to save time!

# Ensure we're in aba root (script is in scripts/ subdirectory)
cd "$(dirname "$0")/.." || exit 1

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

# Only d/l the opertor index in the background to save time!
if [ "$1" = "true" -o "$1" = "1" ]; then
	shift
	# Daemonify the script!
	( $0 --bg $* & ) & 
	sleep 0.2

	exit 0
fi

# Set default catalog name
catalog_name=redhat-operator

while [ $# -gt 0 ]
do
	if [ "$1" = "--bg" ]; then
		shift  # Now we know this script is running as a daemon 
		bg=1
	else
		catalog_name="$1"
		shift
	fi
done

source <(normalize-aba-conf)

verify-aba-conf || exit 1

[ ! "$ocp_version" ] && aba_abort "Error, ocp_version incorrectly defined in aba.conf!"

export ocp_ver=$ocp_version
export ocp_ver_major=$(echo $ocp_version | cut -d. -f1-2)

# FIXME: this is a hack. Better implement as dep in makefile?
#scripts/create-containers-auth.sh >/dev/null 2>&1
scripts/create-containers-auth.sh >/dev/null  # Ensure only errors are output

################################################################
# Start of download ...

#catalog_name in redhat-operator certified-operator redhat-marketplace community-operator

#catalog_name=redhat-operator

mkdir -p mirror/.index
index_file=mirror/.index/$catalog_name-index-v$ocp_ver_major
lock_file=mirror/.index/.$catalog_name-index-v$ocp_ver_major.lock
log_file=mirror/.index/.$catalog_name-index-v$ocp_ver_major.log
pid_file=mirror/.index/.$catalog_name-index-v$ocp_ver_major.pid
done_file=mirror/.index/.$catalog_name-index-v$ocp_ver_major.done

# Clean up on INT
handle_interupt() { echo_red "Aborting catalog download." >&2; [ ! -f $done_file ] && rm -f $index_file; rm -f $lock_file $pid_file; exit 0; }
trap 'handle_interupt' INT TERM

# Check if this script is running in the background, if it is then output to a log file
#if [ ! -t 0 ]; then
if [ "$bg" ]; then
	#echo "Downloading operator $catalog_name index in the background from registry.redhat.io/redhat/$catalog_name-index:v$ocp_ver_major (see $log_file) ..." >&2

	exec >> $log_file 
	exec 2>> $log_file
fi

# See if the index is already downloaded
if [[ -s $index_file && -f $done_file ]]; then
	aba_info "Operator index: $catalog_name v$ocp_ver_major already downloaded to file mirror/$index_file" >&2

	# Check age of file is older than one day
	if [ "$(find $index_file -type f -mtime +0)" ]; then
		aba_info "Operator $catalog_name index needs to be refreshed as it's older than one day."

		rm -f $lock_file
	else
		exit 0  # Index already exists and is less than a day old
	fi
fi

# Check connectivity to registry (Keep this here so it does not slow the script down for the ".done" case)
if ! curl --connect-timeout 15 --retry 8 -IL http://registry.redhat.io/v2 >/dev/null 2>&1; then
	aba_abort "cannot access the registry: https://registry.redhat.io/.  Aborting." 
fi

[ ! -f $index_file ] && touch $index_file

# See if the index is currently downloading (using 'ln' to get a lock)
if ! ln $index_file $lock_file >/dev/null 2>&1; then
	touch $index_file
	aba_debug "Lock file $lock_file already exists ..." >&2
	# Passed here only if the lock file already exists (i.e. index already downloading) 

	# Check if still downloading...
	if [[ -s $index_file && -f $done_file ]]; then
		aba_info "Operator index $catalog_name v$ocp_ver_major already downloaded to file mirror/$index_file"

		exit 0
	fi

	# Check to be sure the command with the expected pid is running

	# If the bg process is no longer running, then reset and try to download again
	if [ -f $pid_file ]; then
		aba_debug "PID file $pid_file found ..." >&2
		bg_pid=$(cat $pid_file)
		if ! ps -p $bg_pid >/dev/null; then
			aba_debug "Background process with pid [$bg_pid] not running." >&2
			rm -f $lock_file $pid_file
			aba_debug "Re-running script $0" >&2
			sleep 0.5
			exec $0 --bg $catalog_name
		fi

		# OK, oc-mirror bg process is still running
	else
		aba_debug "Expected pid file $pid_file not found!" >&2
	fi

	handle_interupt() { echo_red "Stopped waiting for download to complete" >&2; exit 0; }
	echo_magenta "[ABA] Waiting for operator index: $catalog_name v$ocp_ver_major to finish downloading in the background (process id = `cat $pid_file`) ..."
	if ! try_cmd -q 5 0 120 test -f $done_file; then
		rm -f $lock_file  # Remove just the lock file
	       	aba_abort "Giving up waiting for $catalog_name index download! Please check: mirror/$log_file"  # keep checking completion for max 600s (5 x 120s)
	fi

	aba_info_ok "Operator $catalog_name index v$ocp_ver_major download to file mirror/$index_file has completed"

	exit 0
fi

########################################
# PAST THIS POINT?  You own the download
########################################

# Check size of /tmp (tmpfs) on Fedora to see if it needs to be increased (oc-mirror uses up a lot of /tmp space)
#if [ ! "$bg" ] && grep -qi '^ID=fedora' /etc/os-release; then
# FIXME; This is not a good place to do this as it could be called > 1
if grep -qi '^ID=fedora' /etc/os-release; then
  size=$(df --output=size -BG /tmp | tail -1 | tr -dc '0-9')
  (( size < 10 )) && sudo mount -o remount,size=10G /tmp || true
fi

echo $$ > $pid_file
rm -f $done_file  # Just to be sure

# Lock successful, now download the index ...

# If running in forground, on INT, delete lock AND run $0 in background
## NOT A GOOD IDEA [ -t 0 ] && handle_interupt() { echo_red "Putting download into background" >&2; rm -f $lock_file; ( $0 $* > .fetch-index.log 2>&1 & ) & exit 0; }
### FIX ME [ -t 0 ] && handle_interupt() { echo_red "Stopping download" >&2; rm -f $lock_file;  exit 0; }

aba_info "Downloading Operator $catalog_name index v$ocp_ver_major to $index_file, please wait a few minutes ..."

# Wait for oc-mirror binary to be downloaded and available!
run_once -w -i cli:install:oc-mirror -- make -sC cli oc-mirror 

# Fetch latest operator catalog and default channels
aba_info "Running: oc-mirror list operators --catalog registry.redhat.io/redhat/$catalog_name-index:v$ocp_ver_major" >&2
oc-mirror list operators --catalog registry.redhat.io/redhat/$catalog_name-index:v$ocp_ver_major > $index_file
ret=$?
if [ $ret -ne 0 ]; then
	rm -f $lock_file $pid_file
	aba_abort "oc-mirror returned $ret whilst downloading operator $catalog_name index from registry.redhat.io/redhat/$catalog_name-index:v$ocp_ver_major." 
fi

touch $done_file   # This marks successful completion of download!
rm -f $lock_file 
rm -f $pid_file

aba_info_ok "Downloaded $index_file operator list successfully"

# Generate a handy yaml file with operators which can be manually copied into image set config if needed.
tail -n +3 $index_file | awk '{print $1,$NF}' | while read op_name op_default_channel
do
	echo "\
    - name: $op_name
      channels:
      - name: \"$op_default_channel\""
done > imageset-config-$catalog_name-catalog-v${ocp_ver_major}.yaml

aba_info "Generated mirror/imageset-config-$catalog_name-catalog-v${ocp_ver_major}.yaml file for easy reference when editing your image set config file."

# Adding this to log file since it will run in the background
aba_info_ok "Downloaded $catalog_name index for v$ocp_ver_major successfully"

