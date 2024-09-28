#!/bin/bash 
# Copy images from RH reg. into the registry.

source scripts/include_all.sh

try_tot=1  # def. value
[ "$1" == "y" ] && set -x && shift  # If the debug flag is "y"
[ "$1" ] && [ $1 -gt 0 ] && try_tot=`expr $1 + 1` && echo "Will try $try_tot times to sync the images to the registry."    # If the retry value exists and it's a number

umask 077

source <(normalize-aba-conf)
source <(normalize-mirror-conf)

# Show warning if 'make save' has been used previously.
if [ -s save/mirror_seq1_000000.tar ]; then
	echo 
	echo_red "Warning: Image sets exist on local disk in $PWD/save."
	echo_red "         Are you sure you don't want to load them into the mirror registry at $reg_host (make load)?"

	ask "Continue with 'sync'" || exit 1
fi

# This is a pull secret for RH registry
pull_secret_mirror_file=pull-secret-mirror.json

if [ -s $pull_secret_mirror_file ]; then
	echo Using $pull_secret_mirror_file ...
elif [ -s $pull_secret_file ]; then
	:
else
	echo_red "Error: The pull secret file '$pull_secret_file' does not exist! Download it from https://console.redhat.com/openshift/downloads#tool-pull-secret" && exit 1
fi

# Check internet connection...
##echo_cyan -n "Checking access to https://api.openshift.com/: "
if ! curl -skIL --connect-timeout 10 --retry 3 -o "/dev/null" -w "%{http_code}\n" https://api.openshift.com/ >/dev/null; then
	echo_red "Error: Cannot access https://api.openshift.com/.  Access to the Internet is required to sync the images to your registry."

	exit 1
fi

export reg_url=https://$reg_host:$reg_port

# Can the registry mirror already be reached?
[ "$http_proxy" ] && echo "$no_proxy" | grep -q "\b$reg_host\b" || no_proxy=$no_proxy,$reg_host			  # adjust if proxy in use
reg_code=$(curl --connect-timeout 10 --retry 3 -ILsk -o /dev/null -w "%{http_code}\n" $reg_url/health/instance || true)

mkdir -p sync 

# Generate first imageset-config file for syncing images.  
# Do not overwrite the file. Allow users to add images and operators to imageset-config-sync.yaml and run "make sync" again. 
if [ ! -s sync/imageset-config-sync.yaml ]; then
	rm -rf sync/*

	export ocp_ver=$ocp_version
	export ocp_ver_major=$(echo $ocp_version | cut -d. -f1-2)

	echo "Generating initial image set configuration: 'sync/imageset-config-sync.yaml' for 'v$ocp_version' and channel '$ocp_channel' ..."

	[ "$tls_verify" ] && export skipTLS=false || export skipTLS=true
	scripts/j2 ./templates/imageset-config-sync.yaml.j2 > sync/imageset-config-sync.yaml 
	scripts/add-operators-to-imageset.sh >> sync/imageset-config-sync.yaml

	touch sync/.created
else
	echo_cyan "Using existing image set config file (save/imageset-config-sync.yaml)"
	echo_cyan "Reminder: You can edit this file to add more content, e.g. Operators, and then run 'make sync' again."
fi

# This is needed since sometimes an existing registry may already be available
scripts/create-containers-auth.sh

[ ! "$reg_root" ] && reg_root=$HOME/quay-install

echo
echo "Now mirroring the images."
echo
echo "Now loading the images to the registry $reg_host:$reg_port/$reg_path. "
# Check if aba installed Quay or it's an existing reg.
if [ -s ./reg-uninstall.sh ]; then
	echo "Warning: Ensure there is enough disk space under $reg_root.  This can take 5-20+ minutes to complete or even longer if Operator images are being copied!"
fi
echo

[ ! "$tls_verify" ] && tls_verify_opts="--dest-skip-tls"

# Set up script to help for manual re-sync
# --continue-on-error : do not use this option. In testing the registry became unusable! 
cmd="oc mirror $tls_verify_opts --config=imageset-config-sync.yaml docker://$reg_host:$reg_port/$reg_path"
echo "cd sync && umask 0022 && $cmd" > sync-mirror.sh && chmod 700 sync-mirror.sh 

# This loop is based on the "retry=?" value
try=1
failed=1
while [ $try -le $try_tot ]
do
	echo_magenta -n "Attempt ($try/$try_tot)."
	[ $try_tot -le 1 ] && echo_white " Set number of retries with 'make sync retry=<number>'" || echo
	echo "Running: $(cat sync-mirror.sh)"
	echo

	./sync-mirror.sh && failed= && break

	let try=$try+1
	[ $try -le $try_tot ] && echo_red -n "Image synchronization failed ... Trying again. "
done

if [ "$failed" ]; then
	echo_red -n "Image synchronization aborted ..."
	[ $try_tot -gt 1 ] && echo_white " (after $try_tot/$try_tot attempts)!" || echo
	echo_red "Warning: Long-running processes may fail. Resolve any issues if needed, otherwise, try again."

	exit 1
fi

echo
echo_green -n "Images synchronized successfully!"
[ $try_tot -gt 1 ] && echo_white " (after $try/$try_tot attempts)!" || echo

echo 
echo "OpenShift can now be installed with the command:"
echo "  cd aba"
echo "  make cluster name=mycluster [type=sno|compact|standard]   # and follow the instructions."

exit 0
