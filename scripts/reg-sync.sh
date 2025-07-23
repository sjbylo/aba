#!/bin/bash 
# Copy images from RH reg. into the registry.

source scripts/include_all.sh

try_tot=1  # def. value
[ "$1" == "y" ] && set -x && shift  # If the debug flag is "y"
[ "$1" ] && [ $1 -gt 0 ] && try_tot=`expr $1 + 1` && echo "Attempting $try_tot times to sync the images to the registry."    # If the retry value exists and it's a number

umask 077

source <(normalize-aba-conf)
source <(normalize-mirror-conf)

verify-aba-conf || exit 1
verify-mirror-conf || exit 1

# Show warning if 'aba save' has been used previously.
#if [ -s save/mirror_seq1_000000.tar ]; then
if [ -s save/mirror_*.tar ]; then
	echo 
	echo_red "Warning: Existing image set archive files found at $PWD/save." >&2
	echo_red "         Note that you also have the option to load them into the mirror registry at $reg_host (aba load)?" >&2
	echo 

	##ask "Continue with 'sync'" || exit 1
fi

# This is a pull secret for RH registry
pull_secret_mirror_file=pull-secret-mirror.json

if [ -s $pull_secret_mirror_file ]; then
	echo Using $pull_secret_mirror_file ...
elif [ -s $pull_secret_file ]; then
	:
else
	echo
	echo_red "Error: The pull secret file '$pull_secret_file' does not exist!" >&2
	echo_white "       Download it from https://console.redhat.com/openshift/downloads#tool-pull-secret (select 'Tokens' in the pull-down)" >&2
	echo

	exit 1
fi

# Check internet connection...
##echo_cyan -n "Checking access to https://api.openshift.com/: "
if ! curl -skIL --connect-timeout 10 --retry 3 -o "/dev/null" -w "%{http_code}\n" https://api.openshift.com/ >/dev/null; then
	echo_red "Error: Cannot access https://api.openshift.com/.  Access to the Internet is required to sync the images to your registry." >&2

	exit 1
fi

export reg_url=https://$reg_host:$reg_port

# Can the registry mirror already be reached?
[ "$http_proxy" ] && echo "$no_proxy" | grep -q "\b$reg_host\b" || no_proxy=$no_proxy,$reg_host			  # adjust if proxy in use
reg_code=$(curl --connect-timeout 10 --retry 3 -ILsk -o /dev/null -w "%{http_code}\n" $reg_url/health/instance || true)

# This is needed since sometimes an existing registry may already be available
scripts/create-containers-auth.sh

[ ! "$reg_root" ] && reg_root=$HOME/quay-install  # Needed for below TMPDIR

echo
echo "Now syncing (mirror2mirror) images from external network to registry $reg_host:$reg_port/$reg_path. "

# Check if aba installed Quay or it's an existing reg.
if [ -s ./reg-uninstall.sh ]; then
	echo "Warning: Ensure there is enough disk space under $reg_root.  This can take 5 to 20 or more minutes to complete or even longer if Operator images are being copied!"
fi
echo

# If not already set, set the cache and tmp dirs to where there should be more disk space
# Had to use [[ && ]] here, as without it got "mkdir -p <missing operand>" error!
#[[ ! "$TMPDIR" && "$reg_root" ]] && export TMPDIR=$reg_root/.tmp && eval mkdir -p $TMPDIR
[[ ! "$TMPDIR" && "$reg_root" ]] && eval export TMPDIR=$reg_root/.tmp && eval mkdir -p $TMPDIR
# Note that the cache is always used except for mirror-to-mirror (sync) workflows!
# Place the '.oc-mirror/.cache' into a location where there should be more space, i.e. $reg_root, if it's defined
## [[ ! "$OC_MIRROR_CACHE" && "$reg_root" ]] && eval export OC_MIRROR_CACHE=$reg_root && eval mkdir -p $OC_MIRROR_CACHE

# oc-mirror v2 tuning params
parallel_images=8
retry_delay=2
retry_times=2

# This loop is based on the "retry=?" value
try=1
failed=1
while [ $try -le $try_tot ]
do
	# Set up the command in a script which can be run manually if needed.
	if [ "$oc_mirror_version" = "v1" ]; then
		# Set up script to help for manual re-sync
		# --continue-on-error : do not use this option. In testing the registry became unusable! 
		cmd="oc-mirror --v1 --config=imageset-config-sync.yaml docker://$reg_host:$reg_port/$reg_path"
		echo "cd sync && umask 0022 && $cmd" > sync-mirror.sh && chmod 700 sync-mirror.sh 
	else
		cmd="oc-mirror --v2 --config imageset-config-sync.yaml --workspace file://\$PWD docker://$reg_host:$reg_port/$reg_path --parallel-images $parallel_images --retry-delay ${retry_delay}s --retry-times $retry_times"
		echo "cd sync && umask 0022 && $cmd" > sync-mirror.sh && chmod 700 sync-mirror.sh 
	fi

	echo_cyan -n "Attempt ($try/$try_tot)."
	[ $try_tot -le 1 ] && echo_white " Set number of retries with 'aba sync --retry <count>'" || echo
	echo "Running: $(cat sync-mirror.sh)"
	echo

	###./sync-mirror.sh && failed= && break

	# v1/v2 switch. For v2 need to do extra check!
	#####./load-mirror.sh && failed= && break
	if [ "$oc_mirror_version" = "v1" ]; then
		./sync-mirror.sh && failed= && break
	else
		if ./sync-mirror.sh; then
			# Check for errors
			error_file=$(ls -t sync/working-dir/logs/mirroring_errors_*_*.txt 2>/dev/null | head -1)
			if [ ! "$error_file" ]; then
				failed=
				break
			fi
			mkdir -p sync/saved_errors
			cp $error_file sync/saved_errors
			echo_red "Error detected and log file saved in sync/saved_errors/$(basename $error_file)" >&2
		fi

		# At this point we have an error, so we adjust the tuning of v2 to reduce 'pressure' on the mirror registry
		#parallel_images=$(( parallel_images / 2 < 1 ? 1 : parallel_images / 2 ))	# half the value but it must always be at least 1
		parallel_images=$(( parallel_images - 2 < 2 ? 2 : parallel_images - 2 )) 	# Subtract 2 but never less than 2
		retry_delay=$(( retry_delay + 2 > 10 ? 10 : retry_delay + 2 )) 			# Add 2 but never more than value 10
		retry_times=$(( retry_times + 2 > 10 ? 10 : retry_times + 2 )) 			# Add 2 but never more than value 10
	fi

	let try=$try+1
	[ $try -le $try_tot ] && echo_red -n "Image synchronization failed ... Trying again. "
done

if [ "$failed" ]; then
	echo_red -n "Image synchronization aborted ..."
	[ $try_tot -gt 1 ] && echo_white " (after $try_tot/$try_tot attempts!)" || echo
	echo_red "Warning: Long-running processes, copying large amounts of data are prone to error! Resolve any issues (if needed) and try again." >&2
	echo_red "         View https://status.redhat.com/ for any current issues or planned maintenance." >&2
	[ $try_tot -eq 1 ] && echo_red "         Consider using the --retry option!" >&2

	exit 1
fi

echo
echo_green -n "Images synchronized successfully!"
[ $try_tot -gt 1 ] && echo_white " (after $try/$try_tot attempts!)" || echo

echo 
echo "OpenShift can now be installed with the command:"
echo "  cd aba"
echo "  aba cluster --name mycluster [--type <sno|compact|standard>] [--starting-ip <ip>] [--api-vip <ip>] [--ingress-vip <ip>] [--int-connection <proxy|direct>]   # and follow the instructions."

exit 0
