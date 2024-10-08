#!/bin/bash 
# Start here, run this to get going!

uname -o | grep -q "^Darwin$" && echo "Please run 'aba' on RHEL or Fedora. Most tested is RHEL 9." && exit 1

dir=$(dirname $0)
cd $dir

source scripts/include_all.sh

interactive_mode=1

if [ ! -f aba.conf ]; then
	cp templates/aba.conf .
fi
source <(normalize-aba-conf)

while [ "$*" ] 
do
	if [ "$1" = "--debug" -o "$1" = "-d" ]; then
		export DEBUG_ABA=1
		set -x
		shift 
	elif [ "$1" = "--version" -o "$1" = "-v" ]; then
		shift 
		ver=$(echo $1 | grep -E -o "[0-9]+\.[0-9]+\.[0-9]+")
		sed -i "s/ocp_version=[^ \t]*/ocp_version=$ver/g" aba.conf
		target_ver=$ver
		shift 
		auto_ver=1
		interactive_mode=
#	elif [ "$1" = "--vmware" -o "$1" = "--vmw" ]; then
#		shift 
#		[ -s $1 ] && cp $1 vmware.conf
#		auto_vmw=1
#		shift 
#		interactive_mode=
	else
		echo "Unknown option: $1"
		shift 
	fi
done

[ ! "$interactive_mode" ] && exit 0

# From now on it's all considered interactive

# Include aba bin path and common scripts
export PATH=$PWD/bin:$PATH

cat others/message.txt

############
# Determine OCP version 

echo -n "Looking up OpenShift release versions ..."

if ! curl --connect-timeout 10 --retry 2 -sL https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable/release.txt > /tmp/.release.txt; then
	[ "$TERM" ] && tput setaf 1
	echo
	echo "Error: Cannot access https://access mirror.openshift.com/.  Ensure you have Internet access to download the needed images."
	[ "$TERM" ] && tput sgr0
	exit 1
fi

## Get the latest stable OCP version number, e.g. 4.14.6
stable_ver=$(cat /tmp/.release.txt | grep -E -o "Version: +[0-9]+\.[0-9]+\.[0-9]+" | awk '{print $2}')
default_ver=$stable_ver

# Extract the previous stable point version, e.g. 4.13.23
major_ver=$(echo $stable_ver | grep ^[0-9] | cut -d\. -f1)
stable_ver_point=`expr $(echo $stable_ver | grep ^[0-9] | cut -d\. -f2) - 1`
[ "$stable_ver_point" ] && \
	stable_ver_prev=$(cat /tmp/.release.txt| grep -oE "${major_ver}\.${stable_ver_point}\.[0-9]+" | tail -n 1)

# Determine any already installed tool versions
which openshift-install >/dev/null 2>&1 && cur_ver=$(openshift-install version | grep ^openshift-install | grep -E -o "[0-9]+\.[0-9]+\.[0-9]+")

# If openshift-install is already installed, then offer that version also
[ "$cur_ver" ] && or_ret="or [current version] " && default_ver=$cur_ver

[ "$TERM" ] && tput el1
[ "$TERM" ] && tput cr
sleep 0.5

echo    "Which version of OpenShift do you want to install?"

target_ver=
while true
do
	# Exit loop if release version exists
	if echo "$target_ver" | grep -E -q "^[0-9]+\.[0-9]+\.[0-9]+"; then
		if curl --connect-timeout 10 --retry 2 -sIL -o /dev/null -w "%{http_code}\n" https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/$target_ver/release.txt | grep -q ^200$; then
			break
		else
			echo "Error: Failed to find release $target_ver"
		fi
	fi

	[ "$stable_ver" ] && or_s="or $stable_ver (latest) "
	[ "$stable_ver_prev" ] && or_p="or $stable_ver_prev (previous) "

	echo -n "Enter version $or_s$or_p$or_ret(l/p/<version>/Enter) [$default_ver]: "

	read target_ver
	[ ! "$target_ver" ] && target_ver=$default_ver          # use default
	[ "$target_ver" = "l" ] && target_ver=$stable_ver       # latest
	[ "$target_ver" = "p" ] && target_ver=$stable_ver_prev  # previous latest
done

# Update the conf file
sed -i "s/ocp_version=[^ \t]*/ocp_version=$target_ver/g" aba.conf

# make & jq are needed below and in the next steps 
install_rpms make jq python3-pyyaml

# Set up the CLIs
make -C cli 

if [ ! "$editor" ]; then
	echo
	echo -n "Aba uses an editor to aid in the workflow.  Which editor do you prefer (vi, nano or none)? [vi]: "
	read new_editor

	[ ! "$new_editor" ] && new_editor=vi

	if [ "$new_editor" != "none" ]; then
		if ! which $new_editor >/dev/null 2>&1; then
			echo "Editor '$new_editor' not found! Install it and try again!"

			exit 1
		fi
	fi

	sed -E -i -e 's/^editor=[^ \t]+/editor=/g' -e "s/^editor=([[:space:]]+)/editor=$new_editor\1/g" aba.conf
	export editor=$new_editor
fi

if [ ! -f ~/.aba.conf.created -o ~/.aba.conf.created -nt aba.conf ]; then
	touch ~/.aba.conf.created

	echo
	echo -n "Aba uses an editor to aid in the workflow.  Which editor do you prefer (vi, nano or none)? [vi]: "
	read new_editor

	[ ! "$new_editor" ] && new_editor=vi

	if [ "$new_editor" != "none" ]; then
		if ! which $new_editor >/dev/null 2>&1; then
			echo "Editor '$new_editor' not found! Install it and try again!"

			exit 1
		fi
	fi

	sed -E -i -e 's/^editor=[^ \t]+/editor=/g' -e "s/^editor=([[:space:]]+)/editor=$new_editor\1/g" aba.conf
	export editor=$new_editor

	edit_file aba.conf "Edit the config file 'aba.conf' to set your domain name, network CIDR, DNS and more" || \
		( echo "Reminder: Don't forget to edit the file 'aba.conf' before creating a cluster!"; sleep 3 )
fi

domain_reachable() {
	curl --connect-timeout 10 --retry 2 -IL $1 >/dev/null 2>&1 && return 0
	return 1
}
ip_reachable() {
	ping -w3 -c10 -A $1 >/dev/null 2>&1 && return 0
	return 1
}

source <(normalize-aba-conf)

echo 
echo =============================
echo Checking network connectivity
echo =============================
echo 

domain_reachable registry.redhat.io && net_pub=1
ip_reachable $next_hop_address && net_priv=1

if [ "$net_pub" -a "$net_priv" ]; then
	echo "Access to Internet (registry.redhat.io): Yes"
	echo "Access to Private network ($next_hop_address): Yes"
	echo
	echo "Access to both the Internet and your private network has been detected."
	echo "Note that installing a private registry is *optional* since there is access to both the Internet and your private network. Assuming fully connected env."
	echo "If you want to install, or re-use, a private registry, follow step 1) below."

elif [ "$net_pub" -a ! "$net_priv" ]; then
	echo "Access to Internet (registry.redhat.io): Yes"
	echo "Access to Private network ($next_hop_address): No"
	echo
	echo "Only access to the Internet has been detected. No access to your private network has been detected.  Assuming air-gapped env."
	echo "You need to follow 1b) below (make save & make inc)."
elif [ ! "$net_pub" -a "$net_priv" ]; then
	echo "Access to Internet (registry.redhat.io): No "
	echo "Access to Private network ($next_hop_address): Yes"
	echo
	echo "Access to your private network has been detected.  No access to the Internet has been detected."
	echo "You need to following 1c) below (make load), assuming you have already synched the files over after 'make save' on a connected env. Assuming air-gapped env."
else
	echo "No acecss to any required networks!"
	echo "Get access to the Internet and/or your target private network and try again!"

	exit 1
fi

# Just in case, check the target ocp version in aba.conf match any existing versions defined in oc-mirror imageset config files. 
# FIXME: Any better way to do this?! .. or just keep this check in 'make sync' and 'make save' (i.e. before we d/l the images
(
	cd mirror
	if [ -x scripts/check-version-mismatch.sh ]; then
		scripts/check-version-mismatch.sh
	fi
)

# Offer next steps
echo
cat others/message-next-steps.txt


