#!/bin/bash 
# Copy images from RH reg. into the registry.

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

try_tot=1  # def. value
[ "$1" == "y" ] && set -x && shift  # If the debug flag is "y"
[ "$1" ] && [ $1 -gt 0 ] && try_tot=`expr $1 + 1` && aba_info "Attempting $try_tot times to sync the images to the registry."    # If the retry value exists and it's a number

umask 077

source <(normalize-aba-conf)
source <(normalize-mirror-conf)

verify-aba-conf || exit 1
verify-mirror-conf || exit 1

# This is a pull secret for RH registry
pull_secret_mirror_file=pull-secret-mirror.json

if [ -s $pull_secret_mirror_file ]; then
	aba_info Using $pull_secret_mirror_file ...
elif [ -s $pull_secret_file ]; then
	:
else
	aba_abort \
		"The pull secret file '$pull_secret_file' does not exist!" \
		"Download it from https://console.redhat.com/openshift/downloads#tool-pull-secret (select 'Tokens' in the pull-down)"
fi

# Check internet connection...
##aba_info -n "Checking access to https://api.openshift.com/: "
if ! curl -skIL --connect-timeout 10 --retry 8 -o "/dev/null" -w "%{http_code}\n" https://api.openshift.com/ >/dev/null; then
	aba_abort "Cannot access https://api.openshift.com/.  Access to the Internet is required to sync the images to your registry." 
fi

export reg_url=https://$reg_host:$reg_port

# Can the registry mirror already be reached?
[ "$http_proxy" ] && echo "$no_proxy" | grep -q "\b$reg_host\b" || no_proxy=$no_proxy,$reg_host			  # adjust if proxy in use
reg_code=$(curl --connect-timeout 10 --retry 8 -ILsk -o /dev/null -w "%{http_code}\n" $reg_url/health/instance || true)

# This is needed since sometimes an existing registry may already be available
scripts/create-containers-auth.sh

[ ! "$data_dir" ] && data_dir=\~
reg_root=$data_dir/quay-install

###[ ! "$reg_root" ] && reg_root=$HOME/quay-install  # Needed for below TMPDIR

echo
aba_info "Now syncing (mirror2mirror) images from external network to registry $reg_host:$reg_port$reg_path. "

# Check if aba installed Quay or it's an existing reg.
if [ -s ./reg-uninstall.sh ]; then
	aba_warning "Ensure there is enough disk space under $reg_root.  This can take 5 to 20 minutes to complete or even longer if Operator images are being copied!"
fi
echo

# NOTE: that the cache is always used *except* for mirror-to-mirror (sync) workflows, where it is not used! See reg-save.sh and reg-load.sh.
# If not already set, set the cache and tmp dirs to where there should be more disk space
[[ ! "$TMPDIR" && "$data_dir" ]] && eval export TMPDIR=$data_dir/.tmp && eval mkdir -p $TMPDIR

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
		cmd="oc-mirror --v1 --config=imageset-config-sync.yaml docker://$reg_host:$reg_port$reg_path"
		echo "cd sync && umask 0022 && $cmd" > sync-mirror.sh && chmod 700 sync-mirror.sh 
	else
		cmd="oc-mirror --v2 --config imageset-config-sync.yaml --workspace file://. docker://$reg_host:$reg_port$reg_path --image-timeout 15m --parallel-images $parallel_images --retry-delay ${retry_delay}s --retry-times $retry_times"
		echo "cd sync && umask 0022 && $cmd" > sync-mirror.sh && chmod 700 sync-mirror.sh 
	fi

	aba_info -n "Attempt ($try/$try_tot)."
	[ $try_tot -le 1 ] && echo_white " Set number of retries with 'aba -d mirror sync --retry <count>'" || echo
	aba_info "Running:"
	aba_info "$(cat sync-mirror.sh)"
	echo

	###./sync-mirror.sh && failed= && break

	# v1/v2 switch. For v2 need to do extra check!
	#####./load-mirror.sh && failed= && break
	if [ "$oc_mirror_version" = "v1" ]; then
		./sync-mirror.sh && failed= && break || ret=$?
	else
		./sync-mirror.sh
		ret=$?
		#if [ $ret -eq 0 ]; then
			# Check for error files (only required for v2 of oc-mirror)
			error_file=$(ls -t sync/working-dir/logs/mirroring_errors_*_*.txt 2>/dev/null | head -1)
			# Example error file:  mirroring_errors_20250914_230908.txt 

			# v2 of oc-mirror can be in error, even if ret=0!
			if [ ! "$error_file" -a $ret -eq 0 ]; then
				failed=
				break    # stop the "try loop"
			fi

			if [ -s "$error_file" ]; then
				mkdir -p sync/saved_errors
				cp $error_file sync/saved_errors
				echo_red "Error detected and log file saved in sync/saved_errors/$(basename $error_file)" >&2
			fi
		#fi

		# At this point we have an error, so we adjust the tuning of v2 to reduce 'pressure' on the mirror registry
		#parallel_images=$(( parallel_images / 2 < 1 ? 1 : parallel_images / 2 ))	# half the value but it must always be at least 1
		parallel_images=$(( parallel_images - 2 < 2 ? 2 : parallel_images - 2 )) 	# Subtract 2 but never less than 2
		retry_delay=$(( retry_delay + 2 > 10 ? 10 : retry_delay + 2 )) 			# Add 2 but never more than value 10
		retry_times=$(( retry_times + 2 > 10 ? 10 : retry_times + 2 )) 			# Add 2 but never more than value 10
	fi

	let try=$try+1
	[ $try -le $try_tot ] && echo_red -n "[ABA] Image synchronization failed ($ret) ... Trying again. "
done

if [ "$failed" ]; then
	let try=$try-1
	aba_warning -n "Image synchronization aborted ..."
	[ $try_tot -gt 1 ] && echo_white " (after $try/$try_tot attempts!)" || echo
	aba_warning \
		"Long-running processes, copying large amounts of data are prone to error! Resolve any issues (if needed) and try again." \
		"View https://status.redhat.com/ for any current issues or planned maintenance." 
	[ $try_tot -eq 1 ] && echo_red "         Consider using the --retry option!" >&2

	exit 1
fi

echo
aba_info_ok -n "Images synchronized successfully!"
[ $try_tot -gt 1 -a $try -gt 1 ] && echo_white " (after $try attempts!)" || echo   # Show if more than 1 attempt

echo 
aba_info_ok "OpenShift can now be installed. cd to aba's top-level directory and use the command:"
aba_info_ok "  aba cluster --name mycluster [--type <sno|compact|standard>] [--starting-ip <ip>] [--api-vip <ip>] [--ingress-vip <ip>]"
aba_info_ok "Use 'aba cluster --help' for more information about installing clusters."

echo
aba_warning -p IMPORANT \
	"If you have already installed a cluster, (re-)run the command 'aba -d <clustername> day2'" \
	"to configure/refresh OperatorHub/Catalogs, Signatures etc."

exit 0
