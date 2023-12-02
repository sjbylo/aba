#!/usr/bin/bash 

. scripts/include_all.sh

# copy and edit mirror.conf if needed 
if [ ! -s mirror.conf ]; then
	cp -f templates/mirror.conf ..

	# This URL seems to point to a permanent location to get the latest stable version
	stable=$(curl -s https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable/release.txt | \
		egrep -o "Version: +[0-9]+\.[0-9]+\.[0-9]+"| awk '{print $2}') 
	
	sed -i 's/ocp_target_ver=[0-9]\+\.[0-9]\+\.[0-9]\+/ocp_target_ver=4.14.3/g' ../mirror.conf

	echo ==========================================================
	echo "Edit the mirror/mirror.conf file?"
	echo "Change the values to match your environment. Define the mirror registry where it will be installed or"
	echo -n "where it has already been installed: Hit Return to edit or Ctrl-C to break. [y]"
	read yn

	vi ../mirror.conf

	# The top mirror.conf under aba/ has priority from now on
	cp -f ../mirror.conf .
fi

