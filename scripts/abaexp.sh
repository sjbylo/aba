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

############# SHOULD THIS GO HERE? ############
source <(normalize-aba-conf)

# Just in case, check the target ocp version in aba.conf match any existing versions defined in oc-mirror imageset config files. 
# FIXME: Any better way to do this?! .. or just keep this check in 'make sync' and 'make save' (i.e. before we d/l the images
(
	cd mirror
	if [ -x scripts/check-version-mismatch.sh ]; then
		scripts/check-version-mismatch.sh
	fi
)
############# SHOULD THIS GO HERE? ############

##############################################################################################################################
# Determine if this is an "aba bundle" or just a clone from GitHub

if [ ! -f .bundle ]; then
	echo "Aba fresh GitHub clone detected!"

	##############################################################################################################################
	# Check if online
	if ! curl --retry 2 -sL https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable/release.txt > /tmp/.release.txt; then
		echo "To get started with 'aba' please run it on a workstation/laptop with Internet access and try again. Fedora & RHEL have need tested."
		exit 1
	fi

	##############################################################################################################################
	# Determine OCP version 

	echo -n "Looking up OpenShift release versions ..."

	if ! curl --retry 2 -sL https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable/release.txt > /tmp/.release.txt; then
		[ "$TERM" ] && tput setaf 1
		echo
		echo "Error: Cannot access https://access mirror.openshift.com/.  Ensure you have Internet access to download the required images."
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

	echo "Which version of OpenShift do you want to install?"

	target_ver=
	while true
	do
		# Exit loop if release version exists
		if echo "$target_ver" | grep -E -q "^[0-9]+\.[0-9]+\.[0-9]+"; then
			if curl --retry 2 -sIL -o /dev/null -w "%{http_code}\n" https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/$target_ver/release.txt | grep -q ^200$; then
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

	##############################################################################################################################
	# Determine editor

	if [ ! "$editor" ]; then
		echo
		echo -n "Aba can use an editor to aid in the workflow.  Enter preferred editor command (vi, nano etc or none)? [vi]: "
		read new_editor

		[ ! "$new_editor" ] && new_editor=vi  # default

		if [ "$new_editor" != "none" ]; then
			if ! which $new_editor >/dev/null 2>&1; then
				echo "Editor '$new_editor' command not found! Please install your preferred editor and try again!"
				exit 1
			fi
		fi

		sed -E -i -e 's/^editor=[^ \t]+/editor=/g' -e "s/^editor=([[:space:]]+)/editor=$new_editor\1/g" aba.conf
		export editor=$new_editor
	fi

	##############################################################################################################################
	# Determine pull secret

	if grep -qi "registry.redhat.io" $pull_secret_file 2>/dev/null; then
		echo "Pull secret found at '$pull_secret_file'."
	else
		echo "Please download your Red Hat pull secret and store is in the file '$pull_secret_file' and try again!  Note that the file location can be configured in 'aba.conf'."
		exit 1
	fi

	# make & jq are needed below and in the next steps 
	install_rpms make jq python3-pyyaml

	##############################################################################################################################
	# Determine pull secret

	echo "If you intend to install OpenShift into a fully disconnected (i.e. air-gapped) environment, 'aba' will download all required software"
	echo "(mirror registry install files, container images and CLI install files) and create a 'bundle' archive for you to transfer into the disconnected environment."
	echo
	if ask "Do you intend to install OpenShift into a fully disconnected network environment? (Y/n): "; then
		echo "Run: make save && make repo ...."
		exit 0
	fi
	
	##############################################################################################################################
	# Determine online installation (e.g. with a proxy)

	echo "OpenShift can be installed directly from external software and container image repositories, e.g. via a proxy."
	if ask "Do you intend to install OpenShift directly from the Internet (Y/n): "; then
		echo "Run: make cluster name=myclustername"
		exit 1
	fi

	echo "You have the choice to install the Quay appliance or re-use an existing mirror registry for container images."
	read yn
	make install sync

	exit 0

else
	# make & jq are needed below and in the next steps 
	install_rpms make jq python3-pyyaml

	echo "Aba bundle detected!  This aba repo has been prepared on an external worksation,  Assuming we're running on an internal bastion."
	
	make install load
	touch .bundle 
fi

# Set up the CLIs
#make -C cli 

