#!/bin/bash 
# Start here, run this to get going!

uname -o | grep -q "^Darwin$" && echo "Please run 'aba' on RHEL or Fedora. Most tested is RHEL 9." && exit 1

dir=$(dirname $0)
cd $dir

source scripts/include_all.sh

interactive_mode=1

if [ ! -f aba.conf ]; then
	cp templates/aba.conf .
	sed -i "s/^ocp_version=[^ \t]*/ocp_version=			/g" aba.conf
	sed -i "s/^editor=[^ \t]*/editor=			/g" aba.conf
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

###tick="\u2713"

# Include aba bin path and common scripts
export PATH=$PWD/bin:$PATH

cat others/message.txt


##############################################################################################################################
# Determine if this is an "aba bundle" or just a clone from GitHub

if [ ! -f .bundle ]; then
	echo "Fresh GitHub clone of 'aba' repo detected!"

	##############################################################################################################################
	# Check if online
	if ! curl --retry 2 -sL https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable/release.txt > /tmp/.release.txt; then
		echo "To get started with 'aba' please run it on a workstation/laptop with Internet access and try again. Fedora & RHEL have need tested."
		exit 1
	fi

	##############################################################################################################################
	# Determine OCP version 

	if [ "$ocp_version" ]; then
		echo_blue "OpenShift version is defined as '$ocp_version'."
	else

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
	echo_blue "'ocp_version' set to '$target_ver' in aba.conf"

	sleep 1

	fi

	# Just in case, check the target ocp version in aba.conf matches any existing versions defined in oc-mirror imageset config files. 
	# FIXME: Any better way to do this?! .. or just keep this check in 'make sync' and 'make save' (i.e. before we d/l the images
	(
		cd mirror
		../scripts/check-version-mismatch.sh
	)

	##############################################################################################################################
	# Determine editor

	if [ ! "$editor" ]; then
		echo
		echo -n "Aba can use an editor to aid in the workflow.  Enter preferred editor command ('vi', 'nano' etc or 'none')? [vi]: "
		read new_editor

		[ ! "$new_editor" ] && new_editor=vi  # default

		if [ "$new_editor" != "none" ]; then
			if ! which $new_editor >/dev/null 2>&1; then
				echo_red "Editor '$new_editor' command not found! Please install your preferred editor and try again!"
				exit 1
			fi
		fi

		sed -E -i -e 's/^editor=[^ \t]+/editor=/g' -e "s/^editor=([[:space:]]+)/editor=$new_editor\1/g" aba.conf
		export editor=$new_editor
		echo_blue "'editor' set to '$new_editor' in aba.conf"

		sleep 1
	fi

	##############################################################################################################################
	# Determine pull secret

	if grep -qi "registry.redhat.io" $pull_secret_file 2>/dev/null; then
		echo_blue "Pull secret found at '$pull_secret_file'."

		# Now we have the required ocp version, we can fetch the operator index in the background. 
		( make -s -C mirror index & ) & 

		sleep 1
	else
		echo
		echo_red "Error: No Red Hat pull secret file found at '$pull_secret_file'!"
		echo_white "To allow access to the Red Hat image registry, please download your Red Hat pull secret and store is in the file '$pull_secret_file' and try again!"
		echo_white "Note that the location of your pull secret file can be changed in 'aba.conf'."
		echo

		exit 1
	fi

	# make & jq are needed below and in the next steps 
	install_rpms make jq python3-pyyaml

	##############################################################################################################################
	# Determine air-gapped

	echo
	echo_white "If you intend to install OpenShift into a fully disconnected (i.e. air-gapped) environment, 'aba' can download all required software"
	echo_white "(Quay mirror registry install file, container images and CLI install files) and create a 'bundle archive' for you to transfer into the disconnected environment."
	if ask "Install OpenShift into a fully disconnected network environment? (Y/n): "; then
		echo
		echo "Run: make bundle out=/path/to/bundle/filename   # to save all images to local disk & create the bundle archive, follow the instructions."

		exit 0
	fi
	
	##############################################################################################################################
	# Determine online installation (e.g. via a proxy)

	echo
	echo_white "OpenShift can be installed directly from the Internet, e.g. via a proxy."
	if ask "Install OpenShift directly from the Internet (Y/n): "; then
		echo "Run: make cluster name=myclustername"
		exit 1
	fi

	echo 
	echo 
	echo_yellow Instructions
	echo 
	echo "Set up the mirror registry and then sync it with the required container images."
	echo
	echo "You have the choice to install the Quay appliance mirror or re-use an existing registry to store container images."
	echo
	echo "Run:"
	echo "  make install       # to configure and/or install Quay, follow the instructions."
	echo "  make sync          # to sychnonize all container images - from the Internet - into your registry, follow the instructions."
	echo
	echo "Or run:"
	echo "  make install sync  # to complete both actions."
	echo

else
	# aba is running on the internal bastion, in 'bundle' mode.

	# make & jq are needed below and in the next steps 
	install_rpms make jq python3-pyyaml

	echo_blue "Aba bundle detected!  This aba bundle is ready to install OpenShift version '$ocp_version'.  Assuming we're running on an internal bastion!"
	
	echo 
	echo 
	echo_yellow Instructions
	echo 
	echo "Set up the mirror registry and then load it from disk with the required container images."
	echo
	echo "Run:"
	echo "  make install       # to configure and/or install Quay, follow the instructions."
	echo "  make load          # to set up the mirror registry (configure or install quay) and load it, follow the instructions."
	echo "Or run:"
	echo "  make install load  # to complete both actions."
	echo
fi

echo 
echo "Once the images have been loaded or synced into the mirror registry follow the instructions provided."
echo

#echo "Once the registry is configured and loaded with images, run the following command to install OpenShift:"
#echo "Run:"
#echo
#echo "  make cluster name=mycluster    # and follow the instructions.  As usual, run 'make help' for help."

# Set up the CLIs
#make -C cli 

