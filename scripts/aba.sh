#!/bin/bash 
# Start here, run this to get going!

dir=$(dirname $0)
cd $dir

source scripts/include_all.sh

[ ! -f aba.conf ] && cp templates/aba.conf .

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
	elif [ "$1" = "--vmware" -o "$1" = "--vmw" ]; then
		shift 
		[ -s $1 ] && cp $1 vmware.conf
		auto_vmw=1
		shift 
	fi
done

# Include aba bin path and common scripts
export PATH=$PWD/bin:$PATH

if [ ! "$auto_ver" ]; then
	cat others/message.txt

	############
	# Determine OCP version 

	echo -n "Looking up OpenShift release versions ..."

	if ! curl -sL https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable/release.txt > /tmp/.release.txt; then
		tput setaf 1
		echo
		echo "Error: Cannot access https://access mirror.openshift.com/.  Ensure you have Internet access to download the needed images."
		tput sgr0
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
	[ "$cur_ver" ] && or_ret="or currently installed version " && default_ver=$cur_ver

	tput el1
	tput cr
	sleep 0.5

	echo    "Which version of OpenShift do you want to install?"

	target_ver=
	while true
	do
		# Exit loop if release version exists
		if echo "$target_ver" | grep -E -q "^[0-9]+\.[0-9]+\.[0-9]+"; then
			if curl -sIL -o /dev/null -w "%{http_code}\n" https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/$target_ver/release.txt | grep -q ^200$; then
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

fi


# # FIXME: Asking about vmware platform is not really needed at this point in the workflow, consider removing.
# make is needed below and in the next steps 
which make >/dev/null 2>&1 || sudo dnf install make jq python3-yaml -y >/dev/null 2>&1  # jq needed below

############
# vmware.conf
if [ ! "$auto_vmw" ]; then
	if [ ! -s vmware.conf ]; then
		make vmware.conf
	fi
fi
# # FIXME: Asking about vmware platform is not really needed at this point in the workflow, consider removing.

# Set up the CLIs
make -C cli 

# Just in case, check the target ocp version in aba.conf match any existing versions defined in oc-mirror imageset config files. 
(cd mirror && scripts/check-version-mismatch.sh) || exit 1

if [ ! "$auto_ver" -a ! "$auto_vmw" ]; then
	############
	# Offer next steps
	echo
	cat others/message-next-steps.txt
fi

