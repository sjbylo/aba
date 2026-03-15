#!/bin/bash 
# This script compares the OpenShift target version in aba.conf with versions defined in any existing imageset config files under sync/ or save/
# Warns if there is a mismatch that needs to be addressed.
# Only if the ISC file has been updated by user.

# Scripts called from mirror/Makefile should cd to mirror/
cd "$(dirname "$0")/../mirror" || exit 1

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

if [ ! -s sync/imageset-config-sync.yaml -a ! -s save/imageset-config-save.yaml ]; then
	# Nothing to check
	exit 0
fi

install_rpms $(cat templates/rpms-external.txt) || exit 1

yaml2json()
{
	python3 -c 'import yaml; import json; import sys; print(json.dumps(yaml.safe_load(sys.stdin)));'
}

source <(normalize-aba-conf)

verify-aba-conf || aba_abort "$_ABA_CONF_ERR"

aba_ocp_ver=$ocp_version
aba_ocp_ver_major=$(echo $ocp_version | cut -d. -f1-2)
aba_ocp_channel=$ocp_channel-$aba_ocp_ver_major

# Check each imageset config independently. Skip auto-generated files
# (.created newer than the yaml) since ABA will re-create them.
for f in sync/imageset-config-sync.yaml save/imageset-config-save.yaml
do
	[ -s "$f" ] || continue

	dir=$(dirname "$f")
	[ "$dir/.created" -nt "$f" ] && continue

	om_ocp_min_ver=$(cat $f | yaml2json | jq -r .mirror.platform.channels[0].minVersion)
	om_ocp_max_ver=$(cat $f | yaml2json | jq -r .mirror.platform.channels[0].maxVersion)
	om_ocp_channel=$(cat $f | yaml2json | jq -r .mirror.platform.channels[0].name)

	if is_version_greater "$om_ocp_min_ver" "$aba_ocp_ver" || is_version_greater $aba_ocp_ver "$om_ocp_max_ver" || [ "$om_ocp_channel" != "$aba_ocp_channel" ]; then
		echo
		echo_red "Warning: The version of 'openshift-install' ($aba_ocp_ver) no longer matches the version defined in '$f'." >&2
		echo_red "         Settings in '$f' are currently min=$om_ocp_min_ver, max=$om_ocp_max_ver and channel=$om_ocp_channel" >&2
		echo_red "         Before syncing or saving images (again), this mismatch must be corrected." >&2
		echo_red "         Your options are:" >&2
		echo_red "         - edit the image set config file ($f) to match the ocp version set in aba.conf ($aba_ocp_ver)" >&2
		echo_red "         - delete mirror/$f and have aba re-create it for you" >&2
		echo_red "         - edit aba.conf to match the version set in the image set config file." >&2
		echo_red "         Fix the mismatch and try again!" >&2
		echo

		exit 1
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

