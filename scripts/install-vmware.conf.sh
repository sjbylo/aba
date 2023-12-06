#!/bin/bash 
# Install and edit the vmware confo file

if [ ! -s ../vmware.conf ]; then
	cp templates/vmware.conf ..

	echo -n "Edit the govc configuration file (vmware.conf) for access to vCenter or ESXi. Hit Return to edit or Ctrl-C to abort: " 
	read yn

	vi ../vmware.conf

	scripts/install-govc.sh

	source ../vmware.conf
	if ! govc about; then
		rm -f ../vmware.conf
		exit 1
	fi
fi


