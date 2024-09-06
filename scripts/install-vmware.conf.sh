#!/bin/bash 
# Install and edit the vmware (govc) conf file
# This script should really only be run on the internal bastion (with access to vCenter) 

source scripts/include_all.sh

[ "$1" ] && set -x

# Needed for $editor and $ask
source <(normalize-aba-conf)

[ "$platform" != "vmw" ] && echo "Platform param not set to 'vmw' in 'aba.conf'. Not configuring 'vmware.conf'." && > vmware.conf && exit 0

if [ ! -s vmware.conf ]; then
	echo

	if [ -s ~/.vmware.conf ]; then
		echo "Creating 'vmware.conf' from '~/.vmware.conf'"
		cp ~/.vmware.conf vmware.conf   # The working user edited file, if any
	else
		echo "Creating 'vmware.conf' from 'templates/vmware.conf'"
		cp templates/vmware.conf .  # The default template 
	fi

	edit_file vmware.conf "If you want to use VMware, edit the vmware.conf file"
fi

source <(normalize-vmware-conf)

make -C cli ~/bin/govc 

# Check access
if ! govc about; then
	echo "Error: Cannot access vSphere or ESXi.  Please try again!"
	exit 1
else
	echo "Saving working version of 'vmware.conf' to '~/.vmware.conf'."
	[ -s vmware.conf ] && cp vmware.conf ~/.vmware.conf
fi

exit 0

