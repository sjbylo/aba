#!/bin/bash 
# Install and edit the vmware (govc) conf file
# This script should really only be run on the internal bastion (with access to vCenter) 

source scripts/include_all.sh

[ "$1" ] && set -x

# Needed for $editor and $ask
source <(normalize-aba-conf)

verify-aba-conf || exit 1

[ "$platform" != "vmw" ] && echo_white "Platform value not set to 'vmw' in 'aba.conf'. Not configuring: vmware.conf" && > vmware.conf && exit 0

# Ensure govc is installed
make -sC cli govc

if [ -s vmware.conf ]; then
	source <(normalize-vmware-conf)

	if ! govc about >/dev/null 2>&1; then
		echo_red "Error: Cannot access vSphere or ESXi.  Please edit 'vmware.conf' and try again!" >&2

		exit 1
	fi
fi

if [ ! -s vmware.conf ]; then
	if [ -s ~/.vmware.conf ]; then
		echo "Creating 'vmware.conf' from '~/.vmware.conf'"
		cp ~/.vmware.conf vmware.conf   # The working user edited file, if it exists
	else
		echo "Creating 'vmware.conf' from 'templates/vmware.conf'"
		cp templates/vmware.conf .  # The default template 
	fi

	trap - ERR
	edit_file vmware.conf "If you want to deploy to VMware, edit the 'vmware.conf' file" || exit 0

	source <(normalize-vmware-conf)

	# Check access
	if ! govc about; then
		echo_red "Error: Cannot access vSphere or ESXi.  Please edit 'vmware.conf' and try again!" >&2

		exit 1
	else
		echo_cyan "Saving working version of 'vmware.conf' to '~/.vmware.conf'."
		[ -s vmware.conf ] && cp vmware.conf ~/.vmware.conf
	fi
fi

exit 0

