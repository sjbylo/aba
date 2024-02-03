#!/bin/bash 
# Install and edit the vmware (govc) conf file

if [ ! -s vmware.conf ]; then
	echo "Edit the 'govc' config file (vmware.conf) to enable access to vCenter or ESXi. "
	echo -n "Hit Return to edit or 'n' to abort (y/n) [y]: " 
	read yn
	if [ "$yn" = "y" -o "$yn" = "" ]; then
		[ -s ~/.vmware.conf ] && cp ~/.vmware.conf vmware.conf || cp templates/vmware.conf .
		$EDITOR vmware.conf 
	else
		exit 0
	fi

	source vmware.conf

	# Check access
	if ! govc about; then
		echo "Error: Cannot access vSphere or ESXi"
		rm -f vmware.conf
		exit 1
	else
		# Save working version for later
		[ ! -s ~/.vmware.conf ] && cp vmware.conf ~/.vmware.conf
	fi
fi

exit 0

