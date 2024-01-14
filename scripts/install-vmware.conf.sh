#!/bin/bash 
# Install and edit the vmware confo file

#if [ -s ../vmware.conf ]; then
	#cp ../vmware.conf .

	#exit 0
#fi

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
		rm -f vmware.conf
		exit 1
	fi
fi

