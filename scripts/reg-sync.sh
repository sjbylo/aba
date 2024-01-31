#!/bin/bash 

. scripts/include_all.sh

umask 077

source mirror.conf

if [ -s save/mirror_seq1_000000.tar ]; then
	echo 
	echo "WARNING: You already have images saved on local disk in $PWD/save."
	echo "         Sure you don't want to 'make load' them into the mirror registry at $reg_host?" &&
	echo -n "         Enter Return to continue (sync) or Ctl-C to abort: "
	read yn
fi

# This is a pull secret for RH registry
pull_secret_mirror_file=pull-secret-mirror.json

echo pull_secret_file=$pull_secret_file

if [ -s $pull_secret_mirror_file ]; then
	echo Using $pull_secret_mirror_file ...
elif [ -s $pull_secret_file ]; then
	#SB#ln -fs ./pull-secret.json pull-secret.json 
	:
else
	echo "Error: Your pull secret file [$pull_secret_file] does not exist! Download it from https://console.redhat.com/openshift/downloads#tool-pull-secret" && exit 1
fi

export reg_url=https://$reg_host:$reg_port

# Can the registry mirror already be reached?
[ "$http_proxy" ] && echo "$no_proxy" | grep -q "\b$reg_host\b" || no_proxy=$no_proxy,$reg_host			  # adjust if proxy in use
#reg_code=$(curl -ILsk -o /dev/null -w "%{http_code}\n" https://$reg_host:${reg_port}/health/instance || true)
reg_code=$(curl -ILsk -o /dev/null -w "%{http_code}\n" $reg_url/health/instance || true)

##[ "$http_proxy" ] && echo "$no_proxy" | grep -q "\blocalhost\b" || no_proxy=$no_proxy,localhost 		  # adjust if proxy in use
###res_local=$(curl -ILsk -o /dev/null -w "%{http_code}\n" https://localhost:${reg_port}/health/instance || true)

# Mirror registry installed?
if [ "$reg_code" != "200" ]; then
	echo "Error: Registry at https://$reg_host:${reg_port}/ is not responding" && exit 1
fi

podman logout --all 
echo -n "Checking registry access is working using 'podman login': "
podman login -u init -p $reg_password $reg_url 

mkdir -p sync 

# Generate first imageset-config file for syncing images.  
# Do not overwrite the file. Allow users to add images and operators to imageset-config-sync.yaml and run "make sync" again. 
if [ ! -s sync/imageset-config-sync.yaml ]; then
#if [ ! -s imageset-config.yaml ]; then
	echo Generating sync/imageset-config-sync.yaml for oc-mirror ...
	export ocp_ver=$ocp_target_ver
	export ocp_ver_major=$(echo $ocp_target_ver | cut -d. -f1-2)

	[ "$tls_verify" ] && export skipTLS=false || export skipTLS=true
	scripts/j2 ./templates/imageset-config-sync.yaml.j2 > sync/imageset-config-sync.yaml 
	#scripts/j2 ./templates/imageset-config.yaml.j2 > imageset-config.yaml 
else
	echo Using existing sync/imageset-config-sync.yaml
	#echo Using existing imageset-config.yaml
fi

# This is needed since sometimes an existing registry may already be available
./scripts/create-containers-auth.sh

[ ! "$reg_root" ] && reg_root=$HOME/quay-install

echo "Now mirroring the images.  "
echo "Ensure there is enough disk space under $reg_root.  This can take 10-20 mins to complete."

[ ! "$tls_verify" ] && tls_verify_opts="--dest-skip-tls"

# Set up script to help for manual re-sync
echo "cd sync && oc mirror $tls_verify_opts --config=imageset-config-sync.yaml docker://$reg_host:$reg_port/$reg_path" > sync-mirror.sh && chmod 700 sync-mirror.sh 
#echo "oc mirror $tls_verify_opts --config=imageset-config.yaml docker://$reg_host:$reg_port/$reg_path" > sync-mirror.sh && chmod 700 sync-mirror.sh 
./sync-mirror.sh 


