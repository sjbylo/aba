#!/bin/bash 
# Load the registry with images from the local disk

source scripts/include_all.sh

try_tot=1  # def. value
[ "$1" == "y" ] && set -x && shift  # If the debug flag is "y"
[ "$1" ] && [ $1 -gt 0 ] && try_tot=`expr $1 + 1` && echo "Attempting $try_tot times to load the images into the registry."    # If the retry value exists and it's a number

umask 077

source <(normalize-aba-conf)
source <(normalize-mirror-conf)

verify-aba-conf || exit 1
verify-mirror-conf || exit 1

export reg_url=https://$reg_host:$reg_port

scripts/create-containers-auth.sh --load   # --load option indicates that the public pull secret is NOT needed.

# Check if the cert needs to be updated
trust_root_ca regcreds/rootCA.pem

[ ! "$data_dir" ] && data_dir=\~
reg_root=$data_dir/quay-install

# FIXME: [ ! "$tls_verify" ] && tls_verify_opts="--dest-skip-tls"

if [ ! -d save ]; then
	echo_red "Error: Missing 'mirror/save' directory!  For air-gapped environments, run 'aba save' first on an external (Internet connected) bastion/laptop" >&2

	exit 1
fi

echo 
echo "Now loading (disk2mirror) the images from mirror/save/ directory to registry $reg_host:$reg_port$reg_path."
echo

# Check if *aba installed Quay* (if so, show warning) or it's an existing reg. (no need to show warning)
if [ -s ./reg-uninstall.sh ]; then
	echo "Warning: Ensure there is enough disk space under $reg_root.  This can take 5 to 20 minutes to complete or even longer if Operator images are being loaded!"
fi
echo

# Now using data_dir so reg_root=$data_dir/quay-install 
# If not already set, set the cache and tmp dirs to where there should be more disk space
[[ ! "$TMPDIR" && "$data_dir" ]] && eval export TMPDIR=$data_dir/.tmp && eval mkdir -p $TMPDIR
# Note that the cache is always used except for mirror-to-mirror (sync) workflows!
# Place the '.oc-mirror/.cache' into a location where there should be more space, i.e. $data_dir.
[[ ! "$OC_MIRROR_CACHE" && "$data_dir" ]] && eval export OC_MIRROR_CACHE=$data_dir && eval mkdir -p $OC_MIRROR_CACHE

reg-load() {
	local try_tot=$1

	# oc-mirror v2 tuning params
	local parallel_images=8
	local retry_delay=2
	local retry_times=2

	# This loop is based on the "retry=?" value
	local try=1
	local failed=1

	while [ $try -le $try_tot ]
	do
		# Set up the command in a script which can be run manually if needed.
		cmd="oc-mirror --v2 --config imageset-config-save.yaml --from file://\$PWD docker://$reg_host:$reg_port$reg_path --parallel-images $parallel_images --retry-delay ${retry_delay}s --retry-times $retry_times"
		echo "cd save && umask 0022 && $cmd" > load-mirror.sh && chmod 700 load-mirror.sh 

		echo_cyan -n "Attempt ($try/$try_tot)."
		[ $try_tot -le 1 ] && echo_white " Set number of retries with 'aba load --retry <count>'" || echo
		echo "Running: $(cat load-mirror.sh)"
		echo

		./load-mirror.sh
		ret=$?
		#if [ $ret -eq 0 ]; then
		#if ./load-mirror.sh; then
		# Check for error files (only required for v2 of oc-mirror)
		[ -d save/working-dir/logs ] && ls -lt save/working-dir/logs > /tmp/error_file.out || echo DEBUG: save/working-dir/logs missing >&2
		error_file=$(ls -t save/working-dir/logs/mirroring_errors_*_*.txt 2>/dev/null || true | head -1)
		# Example error file:  mirroring_errors_20250914_230908.txt 

		# v2 of oc-mirror can be in error, even if ret=0!
		if [ ! "$error_file" -a $ret -eq 0 ]; then
			failed=
			break    # stop the "try loop"
		fi

		if [ -s "$error_file" ]; then
			mkdir -p save/saved_errors
			cp $error_file save/saved_errors
			echo_red "Error detected and log file saved in save/saved_errors/$(basename $error_file)" >&2
		fi

		# At this point we have an error, so we adjust the tuning of v2 to reduce 'pressure' on the mirror registry
		#parallel_images=$(( parallel_images / 2 < 1 ? 1 : parallel_images / 2 ))	# half the value but it must always be at least 1
		parallel_images=$(( parallel_images - 2 < 2 ? 2 : parallel_images - 2 )) 	# Subtract 2 but never less than 2
		retry_delay=$(( retry_delay + 2 > 10 ? 10 : retry_delay + 2 )) 			# Add 2 but never more than value 10
		retry_times=$(( retry_times + 2 > 10 ? 10 : retry_times + 2 )) 			# Add 2 but never more than value 10

		let try=$try+1
		[ $try -le $try_tot ] && echo_red -n "Image loading failed ($ret) ... Trying again. "
	done

	if [ "$failed" ]; then
		let try=$try-1
		echo_red -n "Image loading aborted ..."
		[ $try_tot -gt 1 ] && echo_white " (after $try/$try_tot attempts!)" || echo
		echo_red "Warning: Long-running processes, copying large amounts of data are prone to error! Resolve any issues (if needed) and try again." >&2
		[ $try_tot -eq 1 ] && echo_red "         Consider using the --retry option!" >&2

		return 1
	else
		echo
		echo_green -n "Images loaded successfully!"
		[ $try_tot -gt 1 -a $try -gt 1 ] && echo_white " (after $try attempts!)" || echo   # Show if more than 1 attempt

		return 0
	fi
}

try_tot=2
if [ -d save/ARCHIVES ]; then
	# Load each seperate archive into the reg. one after the other
	for f in save/ARCHIVES/*imageset-config.yaml
	do
		# Extract op-set name from filename
        	#n=$(echo $f|sed -E  's#^save/ARCHIVES\/\(.*\)-[0-9]+\.[0-9]+\.[0-9]+-imageset-config.yaml$#\1#g')
        	n=$(echo $f|sed -E  's#^save/ARCHIVES/(.*)-.*-imageset-config.yaml$#\1#g')
		# Extract path from filename
		#n2=$(echo $f|sed -E 's#^save/\(ARCHIVES.*-[0-9]+\.[0-9]+\.[0-9]+-imageset-config.yaml\)$#\1#g')
		n2=$(echo $f|sed -E 's#^save/(ARCHIVES/.*-.*-imageset-config.yaml)$#\1#g')

		echo n=$n
		echo n2=$n2
		[ ! "$n2" ] && echo Error exatrcting name && exit 9
		[ ! "$n" ] && echo Error exatrcting name && exit 9

        	#cp $f save/imageset-config-save.yaml
        	#cp save/save/ARCHIVES/$n-*-mirror.tar save/mirror_000001.tar # FIXME: Ensure only one file!
                ln -sf $n2                      save/imageset-config-save.yaml
                (
			cd save
                	ln -sf ARCHIVES/$n-*-mirror.tar mirror_000001.tar
                	ls -l
                	ls -lL mirr*tar
		)
                #cd ..

        	#cat imageset-config-save.yaml
        	#ls -hal save save/ARCHIVES

        	#read -t 5 yn || true

		# Call load function
        	#reg-load $try_tot && cp -rp working-dir/cluster-resources save/ARCHIVES/working-dir-cluster-resources.$n
		# FIXME: Do some files need to be saved for day2 to work with? 
       		if reg-load $try_tot; then
			[ -d save/working-dir/cluster-resources ] && cp -rp save/working-dir/cluster-resources save/working-dir-cluster-resources.$n
		else
			exit 1
		fi
	done
	cd ..
else
       	reg-load $try_tot
fi


echo 
echo "OpenShift can now be installed. cd to aba's top-level directory and use the command:"
echo "  aba cluster --name mycluster [--type <sno|compact|standard>] [--starting-ip <ip>] [--api-vip <ip>] [--ingress-vip <ip>]"
echo "Use 'aba cluster --help' for more information about installing clusters"

echo
echo_green "If you have already installed a cluster, consider (re-)running the command 'aba day2' to configure or refresh OperatorHub."

exit 0
