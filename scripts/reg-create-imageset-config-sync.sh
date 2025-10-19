#!/bin/bash 
# Copy images from RH reg. into the registry.

source scripts/include_all.sh

[ "$1" == "y" ] && set -x && shift  # If the debug flag is "y"

umask 077

source <(normalize-aba-conf)
source <(normalize-mirror-conf)

verify-aba-conf || exit 1
verify-mirror-conf || exit 1

export reg_url=https://$reg_host:$reg_port

# Can the registry mirror already be reached?
[ "$http_proxy" ] && echo "$no_proxy" | grep -q "\b$reg_host\b" || no_proxy=$no_proxy,$reg_host			  # adjust if proxy in use
reg_code=$(curl --connect-timeout 10 --retry 3 -ILsk -o /dev/null -w "%{http_code}\n" $reg_url/health/instance || true)

# Note that any existing sync/* files will not be deleted
mkdir -p sync 

# Generate first imageset-config file for syncing images.  
# Do not overwrite the file if it has been modified. Allow users to add images and operators to imageset-config-sync.yaml and run "make sync" again. 
if [ ! -s sync/imageset-config-sync.yaml -o sync/.created -nt sync/imageset-config-sync.yaml ]; then
	###rm -rf sync/*

	export ocp_ver=$ocp_version
	export ocp_ver_major=$(echo $ocp_version | cut -d. -f1-2)

	echo_cyan "Generating initial image set configuration: sync/imageset-config-sync.yaml to sync images to the mirror registry ..."
	[ ! "$excl_platform" ] && echo_cyan "OpenShift platform release images for'v$ocp_version', channel '$ocp_channel' and arch '$arch_short' ..."

	[ ! "$ocp_channel" -o ! "$ocp_version" ] && echo_red "Error: ocp_channel or ocp_version incorrectly defined in aba.conf" >&2 && exit 1

	scripts/j2 ./templates/imageset-config-sync-$oc_mirror_version.yaml.j2 > sync/imageset-config-sync.yaml 
	scripts/add-operators-to-imageset.sh >> sync/imageset-config-sync.yaml

	[ "$excl_platform" ] && sed -i -E "/ platform:/,/ graph: true/ s/^/#/" sync/imageset-config-sync.yaml

	touch sync/.created

	echo_green "Image set config file created: mirror/sync/imageset-config-sync.yaml"
	echo_white "Reminder: Edit this file to add more content, e.g. Operators, and then run 'aba -d mirror sync' again."
else
	echo_cyan "Using existing image set config file (save/imageset-config-sync.yaml)"
fi

# This is needed since sometimes an existing registry may already be available
scripts/create-containers-auth.sh

