#!/bin/bash 
# Start here, run this to get going!

uname -o | grep -q "^Darwin$" && echo "Please run 'aba' on RHEL or Fedora. Most tested is RHEL 9 (no oc-mirror for Mac OS)." && exit 1

dir=$(dirname $0)
cd $dir

source scripts/include_all.sh

interactive_mode=1

if [ ! -f aba.conf ]; then
	cp templates/aba.conf .

	# Initial prep for interactive mode
	sed -i "s/^ocp_version=[^ \t]*/ocp_version=			/g" aba.conf
	sed -i "s/^editor=[^ \t]*/editor=			/g" aba.conf
fi

fetch_latest_version() {
	curl --retry 2 -sL https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable/release.txt > /tmp/.release.txt || return 1
	## Get the latest stable OCP version number, e.g. 4.14.6
	stable_ver=$(cat /tmp/.release.txt | grep -E -o "Version: +[0-9]+\.[0-9]+\.[0-9]+" | awk '{print $2}')
	[ "$stable_ver" ] && echo $stable_ver || return 1
}

usage="\
Usage: $(basename $0) bundle <version> /path/to/write/bundle/file /path/to/pull-secret-file [channel]

<version>     OpenShift version
<channel>     Optional OpenShift channel (stable, fast, eus, candidate ...)

Usage: $(basename $0) <<options>>

<<options>>:
	--version <version>
	[--channel <channel>]
	[--platform <vmw|bm>]
	--domain <domain>
	--machine-network <network cidr>
	--dns <dns ip>
	--default-route <next hop ip>
	--ntp <ntp ip>
	[--pull-secret path/to/file]
	[--editor <editor>]
	[--ask <booleon>]
"

# for testing, if unset, testing will halt in edit_file()! 
[ "$*" ] && \
	sed -i "s/^editor=[^ \t]*/editor=vi /g" aba.conf && \
	interactive_mode=

while [ "$*" ] 
do
	if [ "$1" = "--help" -o "$1" = "-h" ]; then
		echo "$usage"
		exit 0
	elif [ "$1" = "--debug" -o "$1" = "-d" ]; then
		export DEBUG_ABA=1
		shift 
	elif [ "$1" = "bundle" ]; then
		shift
		ver=$1
		[ "$1" = "latest" ] && ver=$(fetch_latest_version)
		ver=$(echo $ver | grep -E -o "[0-9]+\.[0-9]+\.[0-9]+" || true)
		[ ! "$ver" ] && echo_red "OpenShift version [$1] missing or wrong format!" >&2 && echo >&2 && echo "$usage" >&2 && exit 1
		sed -i "s/ocp_version=[^ \t]*/ocp_version=$ver/g" aba.conf
		shift
		[ "$1" ] && [ ! -d $(dirname $1) ] && echo "File destination path [$(dirname $1)] incorrect or missing!" >&2 && exit 1
		[ -f "$1" ] && echo_red "Bundle file [$1] already exists!" >&2 && exit 1
		[ "$1" ] && dest_path="$1"
		shift
		[ "$1" ] && [ ! -s $1 ] && echo_red "Pull secret file [$1] incorrect or missing!" >&2 && exit 1
		sed -i "s#^pull_secret_file=[^ \t]*#pull_secret_file=$1#g" aba.conf
		shift
		[ "$1" ] && chan=$(echo $1 | grep -E -o '^(stable|fast|eus|candidate)$' || true)
		[ ! "$chan" ] && chan=stable && echo_cyan "Channel [$1] incorrect or missing. Using default value: stable" >&2
		sed -i "s/^ocp_channel=[^ \t]*/ocp_channel=$chan/g" aba.conf

		normalize-aba-conf | sed "s/^export //g" | grep -E -o "^(ocp_version|pull_secret_file|ocp_channel)=[^[:space:]]*" 

		echo
		make bundle out="$dest_path" retry=3
		exit 
	elif [ "$1" = "--version" -o "$1" = "-v" ]; then
		shift 
		echo "$1" | grep -q "^-" && echo_red "Error in parsing version arguments" >&2 && exit 1
		ver=$(echo $1 | grep -E -o "[0-9]+\.[0-9]+\.[0-9]+")
		sed -i "s/ocp_version=[^ \t]*/ocp_version=$ver/g" aba.conf
		target_ver=$ver
		shift 
	elif [ "$1" = "--channel" -o "$1" = "-c" ]; then
		shift 
		echo "$1" | grep -q "^-" && echo_red "Error in parsing channel arguments" >&2 && exit 1
		chan=$(echo $1 | grep -E -o '^(stable|fast|eus|candidate)$')
		sed -i "s/ocp_channel=[^ \t]*/ocp_channel=$chan  /g" aba.conf
		target_chan=$chan
		shift 
	elif [ "$1" = "--platform" -o "$1" = "-p" ]; then
		shift 
		echo "$1" | grep -q "^-" && echo_red "Error in parsing platform arguments" >&2 && exit 1
		[ ! "$1" ] && echo_red -e "Missing platform, see usage.\n$usage" >&2 && exit 1
		platform="$1"
		sed -i "s/^platform=[^ \t]*/platform=$platform  /g" aba.conf
		shift
	elif [ "$1" = "--editor" -o "$1" = "-e" ]; then
		shift 
		echo "$1" | grep -q "^-" && echo_red "Error in parsing editor arguments" >&2 && exit 1
		[ ! "$1" ] && echo_red -e "Missing editor, see usage.\n$usage" >&2 && exit 1
		editor="$1"
		sed -i "s/^editor=[^ \t]*/editor=$editor  /g" aba.conf
		shift
	elif [ "$1" = "--machine-network" -o "$1" = "-n" ]; then
		shift 
		echo "$1" | grep -q "^-" && echo_red "Error in parsing machine network arguments" >&2 && exit 1
		[ ! "$1" ] && echo_red "Missing machine network value $1" >&2 && exit 1
		sed -i "s/^machine_network=[^ \t]*/machine_network=$1  /g" aba.conf
		shift 
	elif [ "$1" = "--pull-secret" -o "$1" = "-ps" ]; then
		shift 
		echo "$1" | grep -q "^-" && echo_red "Error in parsing pull-secret arguments" >&2 && exit 1
		[ ! -s $1 ] && echo_red "Missing pull secret file [$1]" >&2 && exit 1
		sed -i "s#^pull_secret_file=[^ \t]*#pull_secret_file=$1  #g" aba.conf
		shift 
	elif [ "$1" = "--vmware" -o "$1" = "--vmw" ]; then
		shift 
		echo "$1" | grep -q "^-" && echo_red "Error in parsing vmware arguments" >&2 && exit 1
		[ -s $1 ] && cp $1 vmware.conf
		shift 
	else
		echo "Unknown option: $1"
		shift 
	fi
done

[ ! "$interactive_mode" ] && exit 0
# From now on it's all considered interactive

source <(normalize-aba-conf)

# Include aba bin path and common scripts
export PATH=$PWD/bin:$PATH

cat others/message.txt


##############################################################################################################################
# Determine if this is an "aba bundle" or just a clone from GitHub

if [ ! -f .bundle ]; then
	#echo "Fresh GitHub clone of 'aba' repo detected!"

	##############################################################################################################################
	# Check if online
	echo -n "Checking Internet connectivity ..."

	if ! curl --connect-timeout 10 --retry 2 -sL https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable/release.txt > /tmp/.release.txt; then
		[ "$TERM" ] && tput el1 && tput cr
		echo_red "Cannot access https://access mirror.openshift.com/.  Ensure you have Internet access to download the required images."
		echo_red "To get started with Aba run it on a connected workstation/laptop with Fedora or RHEL and try again."

		exit 1
	fi

	[ "$TERM" ] && tput el1 && tput cr

	##############################################################################################################################
	# Determine OCP version 

	if [ "$ocp_version" ]; then
		echo_blue "OpenShift version is defined in aba.conf as '$ocp_version'."
	else
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

		[ "$TERM" ] && tput el1 && tput cr
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
		make -s -C mirror checkversion
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
	# Allow edit of aba.conf

	if [ ! -f .aba.conf.seen ]; then
		touch .aba.conf.seen

		if edit_file aba.conf "Edit aba.conf to set global values, e.g. platform, ocp version, pull secret, base domain, net address etc (if known)"; then
			:
		else
			#echo_red "Warning: Please edit aba.conf before continuing!"
			exit 1
		fi
	fi


	##############################################################################################################################
	# Determine pull secret

	if grep -qi "registry.redhat.io" $pull_secret_file 2>/dev/null; then
		echo_blue "Pull secret found at '$pull_secret_file'."

		# Now we have the required ocp version, we can fetch the operator index in the background. 
		( make -s -C mirror index >> .fetch-index.log 2>&1 & ) & 

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
	if ask "Install OpenShift into a fully disconnected network environment"; then
		echo
		echo_yellow Instructions
		echo
		echo "Run: make bundle out=/path/to/bundle/filename   # to save all images to local disk & create the bundle archive (size ~2-3GB), follow the instructions."
		echo

		exit 0
	fi
	
	##############################################################################################################################
	# Determine online installation (e.g. via a proxy)

	echo
	echo_white "OpenShift can be installed directly from the Internet, e.g. via a proxy."
	if ask "Install OpenShift directly from the Internet"; then
		echo 
		echo_yellow Instructions
		echo 
		echo "Run: make cluster name=myclustername"
		echo 

		exit 1
	fi

	echo 
	echo 
	echo_yellow Instructions
	echo 
	echo "Set up the mirror registry and sync it with the required container images."
	echo
	echo "You have the choice to install the Quay mirror appliance or re-use an existing container registry to store container images."
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

	echo_blue "Aba bundle detected!  This aba bundle is ready to install OpenShift version '$ocp_version'.  Assuming we're running on an internal RHEL bastion!"
	
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

echo "Once the images have been loaded or synced into the mirror registry follow the instructions provided."
echo

