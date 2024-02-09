#!/bin/bash 

dir=$(dirname $0)
cd $dir

source scripts/include_all.sh

while [ "$*" ] 
do
	if [ "$1" = "--debug" -o "$1" = "-d" ]; then
		export DEBUG_ABA=1
		set -x
		shift 
	elif [ "$1" = "--version" -o "$1" = "-v" ]; then
		shift 
		ver=$(echo $1 | grep -E -o "[0-9]+\.[0-9]+\.[0-9]+")
		sed -i "s/ocp_version=.*/ocp_version=$ver/g" aba.conf
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
		echo "Error: Cannot access mirror.openshift.com"
		exit 1
	fi

	## Get the latest stable OCP version number, e.g. 4.14.6
	stable_ver=$(cat /tmp/.release.txt | grep -E -o "Version: +[0-9]+\.[0-9]+\.[0-9]+" | awk '{print $2}')
	default_ver=$stable_ver

	# Extract the previous stable point version, e.g. 4.13.23
	stable_ver_point=`expr $(echo $stable_ver | grep ^4 | cut -d\. -f2) - 1`
	[ "$stable_ver_point" ] && \
		stable_ver_prev=$(cat /tmp/.release.txt| grep -oE "4\.${stable_ver_point}\.[0-9]+" | tail -n 1)

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
		[ ! "$target_ver" ] && target_ver=$default_ver
		[ "$target_ver" = "l" ] && target_ver=$stable_ver
		[ "$target_ver" = "p" ] && target_ver=$stable_ver_prev
	done

	sed -i "s/ocp_version=.*/ocp_version=$target_ver/g" aba.conf
	#echo "$target_ver" > target-ocp-version.conf # FIXME to delete

fi

# make is needed below
rpm --quiet -q make || sudo dnf install make -y >/dev/null 2>&1

############
# vmware.conf
if [ ! "$auto_vmw" ]; then
	if [ ! -s vmware.conf ]; then
		make vmware.conf
	fi
fi

# Set up the CLIs
make -C cli 

if [ ! "$auto_ver" -a ! "$auto_vmw" ]; then
	############
	# Offer next steps
	echo
	cat others/message-next-steps.txt
fi

