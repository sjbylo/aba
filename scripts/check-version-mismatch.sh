#!/bin/bash 
# This script compares the OCP target version in aba.conf with versions defined in any existing imageset config files under mirror/sync/ or save/
# Warns if there is a mismatch that needs to be addressed.

source scripts/include_all.sh

if [ ! -s sync/imageset-config-sync.yaml -a ! -s save/imageset-config-save.yaml ]; then
	# Nothing to check
	exit 0
fi

# python rpm package is diffeent on RHEL8 vs RHEL9!
rpm -q --quiet python3 || rpm -q --quiet python36 || sudo dnf install python3 -y >> .dnf-install.log 2>&1
install_rpms python3-jinja2 python3-pyyaml

yaml2json()
{
	python3 -c 'import yaml; import json; import sys; print(json.dumps(yaml.safe_load(sys.stdin)));'
}

source <(normalize-aba-conf)

aba_ocp_ver=$ocp_version
aba_ocp_ver_major=$(echo $ocp_version | cut -d. -f1-2)
aba_ocp_channel=$ocp_channel-$aba_ocp_ver_major

# Check the versions match and warn if they do not. 
# Don't want to use yq here as it can only be downloaded via curl (just more stuff to install, keep it simple).
for f in sync/imageset-config-sync.yaml save/imageset-config-save.yaml
do
	if [ -s $f ]; then
		om_ocp_min_ver=$(cat $f | yaml2json | jq -r .mirror.platform.channels[0].minVersion)
		om_ocp_max_ver=$(cat $f | yaml2json | jq -r .mirror.platform.channels[0].maxVersion)
		om_ocp_channel=$(cat $f | yaml2json | jq -r .mirror.platform.channels[0].name)

		##if [ "$om_ocp_min_ver" != "$aba_ocp_ver" -o "$om_ocp_max_ver" != "$aba_ocp_ver" -o "$om_ocp_channel" != "$aba_ocp_channel" ]; then
		####### echo is_version_greater "$om_ocp_min_ver" "$aba_ocp_ver" \|\| is_version_greater $aba_ocp_ver "$om_ocp_max_ver" \|\| \[ "$om_ocp_channel" \!\= "$aba_ocp_channel" \]
		if is_version_greater "$om_ocp_min_ver" "$aba_ocp_ver" || is_version_greater $aba_ocp_ver "$om_ocp_max_ver" || [ "$om_ocp_channel" != "$aba_ocp_channel" ]; then
			echo 
			echo_red "Warning: The version of 'openshift-install' ($aba_ocp_ver) no longer matches the version defined in the imageset-config file."
			echo_red "         Settings in 'mirror/$f' are currently min=$om_ocp_min_ver, max=$om_ocp_max_ver and channel=$om_ocp_channel"
			echo_red "         Before syncing or saving images (again), this mismatch must be corrected."
			echo_red "         Fix the mismatch and try again!" 
			echo

			exit 1
		fi
	fi
done

exit 0

#ocp_version=4.14.9
#ocp_channel=stable

#mirror:
#  platform:
#    channels:
#    - name: stable-4.15
#      minVersion: 4.15.0
#      maxVersion: 4.15.0

