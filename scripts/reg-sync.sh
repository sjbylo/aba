#!/bin/bash 

source scripts/include_all.sh

umask 077

source <(normalize-aba-conf)
source <(normalize-mirror-conf)

# Show warning if 'make save' has been used previously.
if [ -s save/mirror_seq1_000000.tar ]; then
	[ "$TERM" ] && tput setaf 1 
	echo 
	echo "WARNING: You already have images saved on local disk in $PWD/save."
	echo "         Sure you don't want to 'make load' them into the mirror registry at $reg_host?"
	[ "$TERM" ] && tput sgr0

	ask "Continue with 'sync'" || exit 1
fi

# This is a pull secret for RH registry
pull_secret_mirror_file=pull-secret-mirror.json

echo pull_secret_file=~/.pull-secret.json

if [ -s $pull_secret_mirror_file ]; then
	echo Using $pull_secret_mirror_file ...
elif [ -s ~/.pull-secret.json ]; then
	:
else
	echo "Error: The pull secret file '~/.pull-secret.json' does not exist! Download it from https://console.redhat.com/openshift/downloads#tool-pull-secret" && exit 1
fi

export reg_url=https://$reg_host:$reg_port

# Can the registry mirror already be reached?
[ "$http_proxy" ] && echo "$no_proxy" | grep -q "\b$reg_host\b" || no_proxy=$no_proxy,$reg_host			  # adjust if proxy in use
reg_code=$(curl -ILsk -o /dev/null -w "%{http_code}\n" $reg_url/health/instance || true)

##[ "$http_proxy" ] && echo "$no_proxy" | grep -q "\blocalhost\b" || no_proxy=$no_proxy,localhost 		  # adjust if proxy in use
###res_local=$(curl -ILsk -o /dev/null -w "%{http_code}\n" https://localhost:${reg_port}/health/instance || true)

#FIXME: 
### # Mirror registry installed?
### if [ "$reg_code" != "200" ]; then
### 	echo "Error: Registry at https://$reg_host:${reg_port}/ is not responding" && exit 1
### fi

# FIXME: This is not needed as 'make install' has already verified this
### podman logout --all >/dev/null 
### echo -n "Checking registry access is working using 'podman login' ... "
### podman login -u init -p $reg_password $reg_url 

mkdir -p sync 

# Generate first imageset-config file for syncing images.  
# Do not overwrite the file. Allow users to add images and operators to imageset-config-sync.yaml and run "make sync" again. 
if [ ! -s sync/imageset-config-sync.yaml ]; then
	rm -rf sync/*
	export ocp_ver=$ocp_version
	export ocp_ver_major=$(echo $ocp_version | cut -d. -f1-2)

	echo "Generating initial oc-mirror 'sync/imageset-config-sync.yaml' for 'v$ocp_version' and channel '$ocp_channel' ..."

	[ "$tls_verify" ] && export skipTLS=false || export skipTLS=true
	scripts/j2 ./templates/imageset-config-sync.yaml.j2 > sync/imageset-config-sync.yaml 

	# Fetch latest operator catalog and defaqult channels and append to the imageset file
###	[ ! -s .redhat-operator-index-v$ocp_ver_major ] && \
###		oc-mirror list operators --catalog registry.redhat.io/redhat/redhat-operator-index:v$ocp_ver_major > .redhat-operator-index-v$ocp_ver_major
###
###	tail -n +2 .redhat-operator-index-v$ocp_ver_major | awk '{print $1,$NF}' | while read op_name op_default_channel
###	do
###		echo "\
####      - name: $op_name
####        channels:
####        - name: $op_default_channel"
###	done >> sync/imageset-config-sync.yaml

else
	# FIXME: Check here for matching varsions values in imageset config file and, if they are different, ask to 'reset' them.
	### scripts/check-version-mismatch.sh || exit 1

	echo Using existing sync/imageset-config-sync.yaml
	echo "Reminder: You can edit this file to add more content, e.g. Operators, and then run 'make sync' again."
fi

# This is needed since sometimes an existing registry may already be available
./scripts/create-containers-auth.sh

[ ! "$reg_root" ] && reg_root=$HOME/quay-install

echo
echo "Now mirroring the images."
echo
echo "Now loading the images to the registry $reg_host:$reg_port/$reg_path. "
# Check if aba installed Quay or it's an existing reg.
if [ -s ./reg-uninstall.sh ]; then
	echo "Ensure there is enough disk space under $reg_root.  This can take 5-20+ mins to complete."
fi
echo

[ ! "$tls_verify" ] && tls_verify_opts="--dest-skip-tls"

# Set up script to help for manual re-sync
# --continue-on-error : do not use this option. In testing the registry became unusable! 
cmd="oc mirror $tls_verify_opts --config=imageset-config-sync.yaml docker://$reg_host:$reg_port/$reg_path"
echo "cd sync && umask 0022 && $cmd" > sync-mirror.sh && chmod 700 sync-mirror.sh 
echo "Running: $(cat sync-mirror.sh)"
echo
if ! ./sync-mirror.sh; then
	[ "$TERM" ] && tput setaf 1 
	echo "Warning: an error has occurred! Long running processes are prone to failure. Please try again!"
	[ "$TERM" ] && tput sgr0
       exit 1
fi
# If oc-mirror fails due to transient errors, the user should try again

echo
echo "==> Image synchronization successful"
