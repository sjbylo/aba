#!/usr/bin/bash 

. scripts/include_all.sh

[ "$1" ] && set -x

ver=$(cat ../target-ocp-version.conf)

if [ ! "$ver" ]; then
	### This URL seems to point to a permanent location to get the latest stable version
#	ver=$(curl -s https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable/release.txt | \
#		grep -E -o "Version: +[0-9]+\.[0-9]+\.[0-9]+"| awk '{print $2}') 
	echo "Please run ./aba first!"
	exit 1
fi

echo
echo ==========================================================
echo -n "Configure your private mirror registry? Hit ENTER to continue or Ctrl-C to abort: "

#echo -n "Hit Return to edit or Ctrl-C to abort [y]: "
#echo "Edit the mirror/mirror.conf file?"
#echo "For an existing registry in your private network, set the values for that registry."
#echo "Otherwise, define the values for where you want the registry to be installed in your private network." 

read yn

cp -f templates/mirror.conf .

# Add target version into the conf file
sed -i "s/ocp_target_ver=[0-9]\+\.[0-9]\+\.[0-9]\+/ocp_target_ver=$ver/g" mirror.conf

$EDITOR mirror.conf

exit 0

