#!/bin/bash 
# Fetch and set ocp versions

#uname -o | grep -q "^Darwin$" && echo "Please run 'aba' on RHEL or Fedora. Most tested is RHEL 9." && exit 1

arch_sys=$(uname -m)
dir=$(dirname $0)
cd $dir

source scripts/include_all.sh

if [ ! -f aba.conf ]; then
	cp templates/aba.conf .
fi
source <(normalize-aba-conf)

verify-aba-conf || exit 1

# Include aba bin path and common scripts
export PATH=$PWD/bin:$PATH

##cat others/message.txt

############
# Determine OCP version 

export tmp_dir=$(mktemp -d /tmp/.aba.$(whoami).XXXX)

echo -n "Looking up OpenShift release versions ..."

if ! curl --connect-timeout 10 --retry 8 -sL https://mirror.openshift.com/pub/openshift-v4/$arch_sys/clients/ocp/stable/release.txt > $tmp_dir/.release.txt; then
	[ "$TERM" ] && tput setaf 1
	echo
	echo "Error: Cannot access https://access mirror.openshift.com/.  Ensure you have Internet access to download the needed images."
	[ "$TERM" ] && tput sgr0
	exit 1
fi

## Get the latest stable OCP version number, e.g. 4.14.6
stable_ver=$(cat $tmp_dir/.release.txt | grep -E -o "Version: +[0-9]+\.[0-9]+\.[0-9]+" | awk '{print $2}')
default_ver=$stable_ver

# Extract the previous stable point version, e.g. 4.13.23
major_ver=$(echo $stable_ver | grep ^[0-9] | cut -d\. -f1)
stable_ver_point=`expr $(echo $stable_ver | grep ^[0-9] | cut -d\. -f2) - 1`
[ "$stable_ver_point" ] && \
	stable_ver_prev=$(cat $tmp_dir/.release.txt| grep -oE "${major_ver}\.${stable_ver_point}\.[0-9]+" | tail -n 1)

# Determine any already installed tool versions
which openshift-install >/dev/null 2>&1 && cur_ver=$(openshift-install version | grep ^openshift-install | grep -E -o "[0-9]+\.[0-9]+\.[0-9]+")

# If openshift-install is already installed, then offer that version also
[ "$cur_ver" ] && or_ret="or [current version] " && default_ver=$cur_ver

[ "$TERM" ] && tput el1
[ "$TERM" ] && tput cr
sleep 0.5

#echo    "Which version of OpenShift do you want to install?"

target_ver=
#while true
#do
	# Exit loop if release version exists
	if echo "$target_ver" | grep -E -q "^[0-9]+\.[0-9]+\.[0-9]+"; then
		if curl --connect-timeout 10 --retry 8 -sL -o /dev/null -w "%{http_code}\n" https://mirror.openshift.com/pub/openshift-v4/$arch_sys/clients/ocp/$target_ver/release.txt | grep -q ^200$; then
			break
		else
			echo "Error: Failed to find release $target_ver"
		fi
	fi

	#[ "$stable_ver" ] && or_s="$stable_ver"
	#[ "$stable_ver_prev" ] && or_p="$stable_ver_prev"

	[ "$stable_ver" ] && echo "Latest current version: $stable_ver"
	[ "$stable_ver_prev" ] && echo "Latest previous version: $stable_ver_prev"
	[ "$default_ver" ] && echo "Version installed: $default_ver"
#	echo "Current available versions: $or_s$or_p$or_ret "
#	echo ": $or_s$or_p$or_ret "

	#read target_ver
	#[ ! "$target_ver" ] && target_ver=$default_ver          # use default
	#[ "$target_ver" = "l" ] && target_ver=$stable_ver       # latest
	#[ "$target_ver" = "p" ] && target_ver=$stable_ver_prev  # previous latest
#done

#echo 

# Update the conf file
#sed -i "s/ocp_version=[^ \t]*/ocp_version=$target_ver/g" aba.conf
#replace-value-conf aba.conf ocp_version $target_ver

