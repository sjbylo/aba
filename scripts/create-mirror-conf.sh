#!/usr/bin/bash 

. scripts/include_all.sh

###[ "$1" = "-v" ] && shift && ver=$1 && shift

[ "$1" ] && set -x

ver=$(cat ../target-ocp-version.conf)

if [ ! "$ver" ]; then
	### This URL seems to point to a permanent location to get the latest stable version
#	ver=$(curl -s https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable/release.txt | \
#		grep -E -o "Version: +[0-9]+\.[0-9]+\.[0-9]+"| awk '{print $2}') 
	echo "Please run ./aba first"
	exit 1
fi

echo ==========================================================
echo "Edit the mirror/mirror.conf file?"
echo "For an existing registry in your private network, set the values for that registry."
echo "Otherwise, define the values for where you intend the registry to be installed in your private network." 
echo -n "Hit Return to edit or Ctrl-C to abort [y]: "
#echo "Set the values to match your *private network*.  Define the mirror registry where you intend it to be installed or"
#echo -n "where it already exists. Hit Return to edit or Ctrl-C to abort [y]: "
read yn

# Copy and edit mirror.conf if needed 
[ ! -s ../mirror.conf ] && cp -f templates/mirror.conf ..

sed -i "s/ocp_target_ver=[0-9]\+\.[0-9]\+\.[0-9]\+/ocp_target_ver=$ver/g" ../mirror.conf

vi ../mirror.conf

# The top mirror.conf under aba/ has priority from now on
cp -f ../mirror.conf .

