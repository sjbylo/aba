#!/bin/bash 
# This script compares the OpenShift target version in aba.conf with versions defined in data/imageset-config.yaml.
# Warns if there is a mismatch that needs to be addressed.
# Only if the ISC file has been updated by user.

# Called from mirror/Makefile (CWD = mirror dir) or via aba.sh
# (make -C mirror, which also sets CWD = mirror dir).
# No explicit cd needed — rely on Make's CWD.

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

if [ ! -s data/imageset-config.yaml ]; then
	# Nothing to check
	exit 0
fi

install_rpms $(cat templates/rpms-external.txt) || exit 1

yaml2json()
{
	python3 -c 'import yaml; import json; import sys; print(json.dumps(yaml.safe_load(sys.stdin)));'
}

source <(normalize-aba-conf)
export regcreds_dir=$HOME/.aba/mirror/$(basename "$PWD")
# mirror.conf is optional — the version comparison only needs aba.conf values
if [ -f mirror.conf ]; then
	source <(normalize-mirror-conf)
	verify-aba-conf || aba_abort "$_ABA_CONF_ERR"
fi

aba_ocp_ver=$ocp_version
aba_ocp_ver_major=$(echo "$ocp_version" | cut -d. -f1-2)
aba_ocp_channel=$ocp_channel-$aba_ocp_ver_major

# Check imageset config. Skip if auto-generated (.created newer than the yaml).
f=data/imageset-config.yaml
dir=$(dirname "$f")
[ "$dir/.created" -nt "$f" ] && exit 0

om_ocp_min_ver=$(yaml2json < "$f" | jq -r .mirror.platform.channels[0].minVersion)
om_ocp_max_ver=$(yaml2json < "$f" | jq -r .mirror.platform.channels[0].maxVersion)
om_ocp_channel=$(yaml2json < "$f" | jq -r .mirror.platform.channels[0].name)

if is_version_greater "$om_ocp_min_ver" "$aba_ocp_ver" || is_version_greater $aba_ocp_ver "$om_ocp_max_ver" || [ "$om_ocp_channel" != "$aba_ocp_channel" ]; then
	_mdir=$(basename "$PWD")
	echo
	echo_red "Warning: The version of 'openshift-install' ($aba_ocp_ver) no longer matches the version defined in '$_mdir/$f'." >&2
	echo_red "         Settings in '$_mdir/$f' are currently min=$om_ocp_min_ver, max=$om_ocp_max_ver and channel=$om_ocp_channel" >&2
	echo_red "         Before syncing or saving images (again), this mismatch must be corrected." >&2
	echo_red "         Your options are:" >&2
	echo_red "         - edit '$_mdir/$f' to match the ocp version set in aba.conf ($aba_ocp_ver)" >&2
	echo_red "         - delete '$_mdir/$f' and have aba re-create it for you" >&2
	echo_red "         - edit aba.conf to match the version set in the image set config file." >&2
	echo_red "         Fix the mismatch and try again!" >&2
	echo

	exit 1
fi

exit 0

#ocp_version=4.14.9
#ocp_channel=stable

#mirror:
#  platform:
#    channels:
#    - name: stable-4.15
#      minVersion: 4.15.0
#      maxVersion: 4.15.0

