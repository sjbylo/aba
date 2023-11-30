#!/usr/bin/bash 

. scripts/include_all.sh

# copy and edit mirror.conf if needed 
if [ ! -s mirror.conf ]; then
	cp templates/mirror.conf .

	# This URL seems to point to a permanent location to get the latest stable version
	stable=$(curl -s https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable/release.txt | \
		egrep -o "Version: +[0-9]+\.[0-9]+\.[0-9]+"| awk '{print $2}') 
	
	sed -i 's/ocp_target_ver=[0-9]\+\.[0-9]\+\.[0-9]\+/ocp_target_ver=4.14.3/g' mirror.conf

	echo ==========================================================
	echo "Edit the mirror.conf file in $PWD...?"
	echo "Change the values to match your environment. Define the mirror registry where it will be installed or"
	echo -n "where it has already been installed: Hit Return to continue or Ctrl-C to break. [y]"
	read yn

	vi mirror.conf
else
	echo "Install a mirror registry first with 'make mirror'?"
	exit 1
fi

