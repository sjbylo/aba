#!/bin/bash 
# Install and edit the vmware (govc) conf file

source scripts/include_all.sh

[ "$1" ] && set -x

# Needed for $editor
source <(normalize-aba-conf)

if [ ! -s vmware.conf ]; then
	echo
	echo "Do you want to install OpenShift onto vSphere or ESXi?"
	#echo "Edit the 'govc' config file (vmware.conf) to enable access to vCenter or ESXi. "
	echo -n "Hit Return to edit the 'vmware.conf' file or 'n' to skip (y/n) [y]: " 
	read yn
	if [ "$yn" = "y" -o "$yn" = "" ]; then
		if [ -s ~/.vmware.conf ]; then
			cp ~/.vmware.conf vmware.conf   # The working user edited file, if any
		elif [ -s .vmware.conf ]; then
			cp .vmware.conf vmware.conf  # The user edited file, if any
		else
			cp templates/vmware.conf .  # The default template 
		fi
		$editor vmware.conf 
	else
		> vmware.conf
		exit 0
	fi

	source <(normalize-vmware-conf)

	make -C cli ~/bin/govc 

	# Check access
	if ! govc about; then
		echo "Error: Cannot access vSphere or ESXi"
		mv vmware.conf .vmware.conf    # remember this to edit next time (see above) 
		exit 1
	else
		# Save working version for later
		[ ! -s ~/.vmware.conf ] && cp vmware.conf ~/.vmware.conf
	fi
fi

exit 0

