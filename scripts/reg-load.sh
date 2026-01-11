#!/bin/bash 
# Load the registry with images from the local disk

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

try_tot=1  # def. value
[ "$1" == "y" ] && set -x && shift  # If the debug flag is "y"
[ "$1" ] && [ $1 -gt 0 ] && try_tot=`expr $1 + 1` && echo "[ABA] Attempting $try_tot times to load the images into the registry."    # If the retry value exists and it's a number

umask 077

source <(normalize-aba-conf)
source <(normalize-mirror-conf)

verify-aba-conf || exit 1
verify-mirror-conf || exit 1

# Be sure a download has started ..
run_once    -i mirror:install:oc-mirror -- make -sC $ABA_ROOT/cli oc-mirror

export reg_url=https://$reg_host:$reg_port

scripts/create-containers-auth.sh --load   # --load option indicates that the public pull secret is NOT needed.

# Check if the cert needs to be updated
if [ -s regcreds/rootCA.pem ]; then
	trust_root_ca regcreds/rootCA.pem # FIXME: Is this required here since the rootCA.pem is installed after reg install?
else
	aba_warning "No regcreds/rootCA.pem cert file found (skipTLS=$skipTLS)" 
fi

[ ! "$data_dir" ] && data_dir=\~
reg_root=$data_dir/quay-install

if [ ! -d save ]; then
	aba_abort "Error: Missing 'mirror/save' directory!  For air-gapped environments, run 'aba -d mirror save' first on an external (Internet connected) bastion/laptop" 
fi

echo 
aba_info "Now loading (disk2mirror) the images from mirror/save/ directory to registry $reg_host:$reg_port$reg_path."
echo

# Check if *aba installed Quay* (if so, show warning) or it's an existing reg. (no need to show warning)
if [ -s ./reg-uninstall.sh ]; then
	aba_warning \
		"Ensure there is enough disk space under $reg_root." \
		"This can take 5 to 20 minutes to complete or even longer if Operator images are being loaded!"
fi
echo

# Now using data_dir so reg_root=$data_dir/quay-install 
# If not already set, set the cache and tmp dirs to where there should be more disk space
[[ ! "$TMPDIR" && "$data_dir" ]] && eval export TMPDIR=$data_dir/.tmp && eval mkdir -p $TMPDIR
# Note that the cache is always used except for mirror-to-mirror (sync) workflows!
# Place the '.oc-mirror/.cache' into a location where there should be more space, i.e. $data_dir.
[[ ! "$OC_MIRROR_CACHE" && "$data_dir" ]] && eval export OC_MIRROR_CACHE=$data_dir && eval mkdir -p $OC_MIRROR_CACHE

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
	# Wait for oc-mirror to be available!
	run_once -w -i mirror:install:oc-mirror -- make -sC $ABA_ROOT/cli oc-mirror 
	cmd="oc-mirror --v2 --config imageset-config-save.yaml --from file://. docker://$reg_host:$reg_port$reg_path --image-timeout 15m --parallel-images $parallel_images --retry-delay ${retry_delay}s --retry-times $retry_times"
	echo "cd save && umask 0022 && $cmd" > load-mirror.sh && chmod 700 load-mirror.sh 

	echo
	aba_info -n "Attempt ($try/$try_tot)."
	[ $try_tot -le 1 ] && echo_white " Set number of retries with 'aba -d mirror load --retry <count>'" || echo
	aba_info "Running:"
	aba_info "$(cat load-mirror.sh)"
	echo

	# v1/v2 switch. For v2 need to do extra check!
	if [ "$oc_mirror_version" = "v1" ]; then
		./load-mirror.sh && failed= && break || ret=$?
	else
		./load-mirror.sh
		ret=$?
		#if [ $ret -eq 0 ]; then
		#if ./load-mirror.sh; then
			# Check for error files (only required for v2 of oc-mirror)
			#ls -lt save/working-dir/logs > /tmp/error_file.out
			error_file=$(ls -t save/working-dir/logs/mirroring_errors_*_*.txt 2>/dev/null | head -1)
			# Example error file:  mirroring_errors_20250914_230908.txt 

			# v2 of oc-mirror can be in error, even if ret=0!
			if [ ! "$error_file" -a $ret -eq 0 ]; then
				failed=
				break    # stop the "try loop"
			fi

			if [ -s "$error_file" ]; then
				mkdir -p save/saved_errors
				cp $error_file save/saved_errors
				aba_warning "An error was detected and the log file was saved in save/saved_errors/$(basename $error_file)"
			fi
		#fi

		# At this point we have an error, so we adjust the tuning of v2 to reduce 'pressure' on the mirror registry
		#parallel_images=$(( parallel_images / 2 < 1 ? 1 : parallel_images / 2 ))	# half the value but it must always be at least 1
		parallel_images=$(( parallel_images - 2 < 2 ? 2 : parallel_images - 2 )) 	# Subtract 2 but never less than 2
		retry_delay=$(( retry_delay + 2 > 10 ? 10 : retry_delay + 2 )) 			# Add 2 but never more than value 10
		retry_times=$(( retry_times + 2 > 10 ? 10 : retry_times + 2 )) 			# Add 2 but never more than value 10
	fi

	let try=$try+1
	[ $try -le $try_tot ] && echo_red -n "[ABA] Image loading failed ($ret) ... Trying again. " >&2
done

if [ "$failed" ]; then
	let try=$try-1
	aba_warning -n "Image loading aborted ..."
	[ $try_tot -gt 1 ] && echo_white " (after $try/$try_tot attempts!)" || echo
	aba_warning \
		"Long-running processes, copying large amounts of data are prone to error! Resolve any issues (if needed) and try again." 

	[ $try_tot -eq 1 ] && echo_red "         Consider using the --retry option!" >&2

	exit 1
fi

echo
aba_info_ok -n "Images loaded successfully!"
[ $try_tot -gt 1 -a $try -gt 1 ] && echo_white " (after $try attempts!)" || echo   # Show if more than 1 attempt

echo 
aba_info_ok "OpenShift can now be installed. cd to aba's top-level directory and use the command:"
aba_info_ok "  aba cluster --name mycluster [--type <sno|compact|standard>] [--starting-ip <ip>] [--api-vip <ip>] [--ingress-vip <ip>]"
aba_info_ok "Use 'aba cluster --help' for more information about installing clusters."

echo
if have_installed_clusters=$(echo ../*/.install-complete) && [ "$have_installed_clusters" != "../*/.install-complete" ]; then
	aba_warning -c magenta -p IMPORANT \
		"If you have already installed a cluster, (re-)run the command 'aba -d <clustername> day2'" \
		"to configure/refresh OperatorHub/Catalogs, Signatures etc."
	echo
fi

exit 0
