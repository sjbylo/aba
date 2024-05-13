#!/bin/bash 
# Install and edit the vmware (govc) conf file
# This script should really only be run on the internal bastion (with access to vCenter) 

source scripts/include_all.sh

[ "$1" ] && set -x

# Needed for $editor
source <(normalize-aba-conf)

if [ ! -s vmware.conf ]; then
	echo
	if ask "Install OpenShift onto vSphere or ESXi (access from the private network is required!)?"; then

	#echo "Install OpenShift onto vSphere or ESXi (access from the private network is required!)?"
#	echo -n "Hit Return to edit the 'vmware.conf' file or 'n' to skip (Y/n): " 

#	read yn

#	if [ "$yn" = "y" -o "$yn" = "" ]; then
		if [ -s ~/.vmware.conf ]; then
			echo "Creating 'vmware.conf' from '~/.vmware.conf'"
			cp ~/.vmware.conf vmware.conf   # The working user edited file, if any
		else
			echo "Creating 'vmware.conf' from 'templates/vmware.conf'"
			cp templates/vmware.conf .  # The default template 
		fi
		[ "$ask" ] && $editor vmware.conf 
	else
		echo "Creating empty 'vmware.conf' file.  To use vSphere or ESXi, delete the file and run 'make vmw'."
		> vmware.conf
		exit 0
	fi
fi

source <(normalize-vmware-conf)

make -C cli ~/bin/govc 

# Check access
if ! govc about; then
	echo "Error: Cannot access vSphere or ESXi.  Please try again!"
	exit 1
else
	echo "Saving working version of 'vmware.conf' to '~/.vmware.conf'."
	##[ ! -s ~/.vmware.conf ] && cp vmware.conf ~/.vmware.conf
	[ -s vmware.conf ] && cp vmware.conf ~/.vmware.conf
fi
##fi

exit 0

