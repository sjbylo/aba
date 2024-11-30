#!/bin/bash
# Start here, run this to get going!

uname -o | grep -q "^Darwin$" && echo "Please run Aba on RHEL or Fedora. Most tested is RHEL 9 (no oc-mirror for Mac OS)." >&2 && exit 1

interactive_mode=1

if [ "$1" = "--dir" -o "$1" = "-d" ]; then
	[ ! -d $2 ] && echo_red "$2 not a directory!" >&2 && exit 1
	echo cd $2
	cd $2
	shift 2
fi

# All of the below options parsing is not pretty and needs a lot of work!

if [ -s Makefile ] && grep -q "Top level Makefile" Makefile; then
	if [ ! "$*" ]; then
		exec aba -i
	fi
elif [ -s ../Makefile ] && grep -q "Top level Makefile" ../Makefile; then
	echo cd .. >&2
	orig_dir=$PWD
	cd ..
	#interactive_mode=
else
	echo "  __   ____   __  "
	echo " / _\ (  _ \ / _\     Install & manage air-gapped OpenShift quickly with the Aba utility!"
	echo "/    \ ) _ (/    \    Follow the instructions below or see the README.md file for more."
	echo "\_/\_/(____/\_/\_/"
	echo
	echo "Please run Aba from the top of its repository."
	echo
	echo "For example:                          cd aba"
	echo "                                      aba --help"
	echo
	echo "Otherwise, clone Aba from GitHub:     git clone https://github.com/sjbylo/aba.git"
	echo "Change to the Aba repo directory:     cd aba"
	echo "Install latest Aba:                   ./install"
	echo "Run Aba:                              aba --help" 

	exit 1
fi

#dir=$(dirname $0)
#cd $dir

if [ ! -s scripts/include_all.sh -a -s ../scripts/include_all.sh ]; then
	orig_dir=$PWD
	cd .. 
#else
#	echo Abort >&2
#	exit 1
fi

source scripts/include_all.sh

OTHER_OPTS=

if [ ! -f aba.conf ]; then
	cp templates/aba.conf .

	# Initial prep for interactive mode
	sed -i "s/^ocp_version=[^ \t]*/ocp_version= /g" aba.conf
	sed -i "s/^ocp_channel=[^ \t]*/ocp_channel= /g" aba.conf
	sed -i "s/^editor=[^ \t]*/editor= /g" aba.conf
fi

fetch_latest_version() {
	# $1 must be one of 'stable', 'fast' or 'candidate'
	local c=$1
	[ "$c" = "eus" ] && c=stable   # .../ocp/eus/release.txt does not exist
	curl --connect-timeout 10 --retry 2 -sL https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/$c/release.txt > /tmp/.release.txt || return 1
	# Get the latest stable OCP version number, e.g. 4.14.6
	stable_ver=$(cat /tmp/.release.txt | grep -E -o "Version: +[0-9]+\.[0-9]+\.[0-9]+" | awk '{print $2}')
	[ "$stable_ver" ] && echo $stable_ver || return 1
}

usage="\
Install & manage air-gapped OpenShift. 

   Aba makes it easier to install an OpenShift cluster - 'Cluster Zero' - into a fully or partially disconnected environment,
   either onto bare-metal, vSphere or ESXi. Because Aba uses the Agent-based installer there is no need to configure a load balancer,
   a bootstrap node or even require DHCP.

Usage:
   aba				# Interactive mode.  Let Aba lead you through the process.

Usage:
   $(basename $0) bundle \\	
	[--channel <channel>] \\
	 --version <version> \\
	 --out </path/to/mybundle|-> \\
	[--pull-secret ~/.pull-secret.json] \\
	[--op-sets <list of operator sets>] \\
	[--ops <list of operator names>] \\
	<<options>> 

   The 'bundle' command writes the provided args to 'aba.conf' and then creates a 'bundle archive' file which can be used to install OpenShift
   in air-gapped/fully disconnected environments. See below for other <<options>>.

   $(basename $0) mirror 

   $(basename $0) cluster --name <mycluster> [--type <sno|compact|standard>] [--step <step>] 

Usage:
   $(basename $0) <<options>>         # Update provided values in aba.conf

   <<options>>:
	 --pull-secret <path/to/file>	# Location of your pull secret (json) file here. 
	 --channel <channel>		# Set the OpenShift installation channel, e.g. fast, stable (default), eus or candidate.
	 --version <version>		# Set the (x.y.z) OpenShift version, e.g. 4.16.20 or 'latest'.
	 --platform vmw|bm		# Set the target platform, e.g. vmw (vCenter or ESX) or bm (bare-metal). This changes the install flow. 
	 --domain <domain>		# Set the OpenShift base domain, e.g. company.com.
	 --machine-network <cidr>	# Set the OpenShift cluster's host/machine network address, e.g. 10.0.0.0/24.
	 --dns <ip address>		# Set one DNS IP address.
	 --default-route <next hop ip>	# Set the default route of the internal network, if any (optional).
	 --ntp <ntp ip>			# Set the NTP IP address (optional but recommended!). 
	 --ops <list of operators>	# Add individual operators to your image set config file (for oc-mirror).
	 --op-sets <operator set list>	# Add sets of operators to your image set config file, as defined in 'templates/operator-set.*' files.
	 --editor <editor command>	# Set the editor to use, e.g. vi, emacs, pico, none...  'none' means manual editing of config files. 
	 --ask				# Prompt user when needed.
	 --noask			# Do not prompt, assume default answers.
	 --out <file|->			# Bundle output destination, e.g. file or stadout (-).
"

# for testing, if unset, testing will halt in edit_file()! 
[ "$*" ] && \
	sed -i "s/^editor=[^ \t]*/editor=vi /g" aba.conf && \
	interactive_mode=

# set defaults 
ops_list=
op_set_list=
chan=stable

while [ "$*" ] 
do
	####echo "\$* = " $*
	if [ "$1" = "--help" -o "$1" = "-h" ]; then
		echo "$usage"
		exit 0
#	elif [ "$1" = "--dir" -o "$1" = "-d" ]; then
#		[ ! -d $2 ] && echo_red "$2 not a directory!" >&2 && exit 1
#		echo cd $2
#		cd $2
#		shift 2
	elif [ "$1" = "-i" ]; then
		interactive_mode=1
		args_processed=
		shift
#	elif [ "$1" = "--debug" ]; then
#		export DEBUG_ABA=1
#		shift 
	elif [ "$1" = "bundle" ]; then
		ACTION=bundle
		shift
		args_processed=1
	elif [ "$1" = "--out" ]; then
		shift
		echo "$1" | grep -q "^--" && echo_red "Error in parsing --out path argument" >&2 && exit 1
		[ "$1" ] && [ ! -d $(dirname $1) ] && echo_red "File destination path [$(dirname $1)] incorrect or missing!" >&2 && exit 1
		[ "$1" != "-" ] && [ -f "$1.tar" ] && echo_red "Bundle archive file [$1.tar] already exists!" >&2 && exit 1
		[ "$1" ] && bundle_dest_path="$1"
		shift
		### args_processed=1 # Don't mark this as processed since we need make to run for this to work!
		# FIXME: This is just one use-case where --all is an opewtion which *is* needed my make! ==> Simplify!!
	elif [ "$1" = "--channel" -o "$1" = "-c" ]; then
		shift 
		echo "$1" | grep -q "^-" && echo_red "Error in parsing --channel arguments" >&2 && exit 1
		chan=$(echo $1 | grep -E -o '^(stable|fast|eus|candidate)$')
		sed -i "s/ocp_channel=[^ \t]*/ocp_channel=$chan /g" aba.conf
		target_chan=$chan
		shift 
		args_processed=1
	elif [ "$1" = "--version" -o "$1" = "-v" ]; then
		shift 
		ver=$1
		echo "$ver" | grep -q "^-" && echo_red "Error in parsing --version arguments" >&2 && exit 1
		if ! curl --connect-timeout 10 --retry 2 -sL https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/$chan/release.txt > /tmp/.release.txt; then
			echo_red "Cannot access https://mirror.openshift.com/.  Ensure you have Internet access to download the required images." >&2
			echo_red "To get started, run Aba on a connected workstation/laptop with Fedora or RHEL and try again." >&2

			exit 1
		fi

		[ "$ver" = "latest" ] && ver=$(fetch_latest_version $chan)
		ver=$(echo $ver | grep -E -o "[0-9]+\.[0-9]+\.[0-9]+" || true)
		[ ! "$ver" ] && echo_red "Missing value after --version. OpenShift version missing or wrong format!" >&2 && echo >&2 && echo "$usage" >&2 && exit 1
		sed -i "s/ocp_version=[^ \t]*/ocp_version=$ver /g" aba.conf
		target_ver=$ver
		shift 
		args_processed=1
	elif [ "$1" = "--domain" ]; then
		shift 
		echo "$1" | grep -q "^-" && echo_red "Error in parsing --domain arguments" >&2 && exit 1
		domain=$(echo $1 | grep -Eo '([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}')
		sed -i "s/^domain=[^ \t]*/domain=$domain /g" aba.conf
		target_domain=$domain
		shift 
		args_processed=1
	elif [ "$1" = "--dns" ]; then
		shift 
		echo "$1" | grep -q "^-" && echo_red "Error in parsing --dns arguments" >&2 && exit 1
		dns_ip=$(echo $1 | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}')
		sed -i "s/^dns_servers=[^ \t]*/dns_servers=$dns_ip /g" aba.conf
		shift 
		args_processed=1
	elif [ "$1" = "--ntp" ]; then
		shift 
		echo "$1" | grep -q "^-" && echo_red "Error in parsing --ntp arguments" >&2 && exit 1
		ntp_ip=$(echo $1 | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}')
		sed -i "s/^ntp_servers=[^ \t]*/ntp_servers=$ntp_ip /g" aba.conf
		shift 
		args_processed=1
	elif [ "$1" = "--default-route" ]; then
		shift 
		echo "$1" | grep -q "^-" && echo_red "Error in parsing --default-route arguments" >&2 && exit 1
		def_route_ip=$(echo $1 | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}')
		sed -i "s/^next_hop_address=[^ \t]*/next_hop_address=$def_route_ip /g" aba.conf
		shift 
		args_processed=1
	elif [ "$1" = "--platform" -o "$1" = "-p" ]; then
		shift 
		echo "$1" | grep -q "^-" && echo_red "Error in parsing --platform arguments" >&2 && exit 1
		[ ! "$1" ] && echo_red -e "Missing platform, see usage.\n$usage" >&2 && exit 1
		platform="$1"
		sed -i "s/^platform=[^ \t]*/platform=$platform /g" aba.conf
		shift
		args_processed=1
	elif [ "$1" = "--op-sets" ]; then
		shift
		echo "$1" | grep -q "^-" && echo_red "Error in parsing '--op-sets' arguments" >&2 && exit 1
		[ ! "$1" ] && echo_red "Warning: Missing args when parsing op-sets" >&2 && exit 1
		while ! echo "$1" | grep -q -e "^-"; do [ -s templates/operator-set-$1 ] && op_set_list="$op_set_list $1"; shift || break; done
		op_set_list=$(echo "$op_set_list" | xargs)  # Trim white space
		#echo ADDDING op_set_list=$op_set_list
		sed -i "s/^op_sets=[^#$]*/op_sets=\"$op_set_list\" /g" aba.conf
		args_processed=1
	elif [ "$1" = "--ops" ]; then
		shift
		echo "$1" | grep -q "^-" && echo_red "Error in parsing '--ops' arguments" >&2 && exit 1
		[ ! "$1" ] && echo_red "Warning: Missing args when parsing '--ops'" >&2 && exit 1
		while ! echo "$1" | grep -q -e "^-"; do ops_list="$ops_list $1"; shift || break; done
		ops_list=$(echo "$ops_list" | xargs)  # Trim white space
		#echo ADDING ops_list=$ops_list
		sed -i "s/^ops=[^#$]*/ops=\"$ops_list\" /g" aba.conf
		args_processed=1
	elif [ "$1" = "--editor" -o "$1" = "-e" ]; then
		shift 
		echo "$1" | grep -q "^-" && echo_red "Error in parsing --editor arguments" >&2 && exit 1
		[ ! "$1" ] && echo_red -e "Missing editor, see usage.\n$usage" >&2 && exit 1
		editor="$1"
		sed -i "s/^editor=[^ \t]*/editor=$editor /g" aba.conf
		shift
		args_processed=1
	elif [ "$1" = "--machine-network" -o "$1" = "-n" ]; then
		shift 
		echo "$1" | grep -q "^-" && echo_red "Error in parsing --machine-network arguments" >&2 && exit 1
		[ ! "$1" ] && echo_red "Missing machine network value $1" >&2 && exit 1
		sed -i "s/^machine_network=[^ \t]*/machine_network=$1 /g" aba.conf
		shift 
		args_processed=1
	elif [ "$1" = "--pull-secret" -o "$1" = "-ps" ]; then
		shift 
		echo "$1" | grep -q "^-" && echo_red "Error in parsing --pull-secret arguments" >&2 && exit 1
		[ ! -s $1 ] && echo_red "Missing pull secret file [$1]" >&2 && exit 1
		sed -i "s#^pull_secret_file=[^ \t]*#pull_secret_file=$1 #g" aba.conf
		shift 
		args_processed=1
	elif [ "$1" = "--vmware" -o "$1" = "--vmw" ]; then
		shift 
		echo "$1" | grep -q "^-" && echo_red "Error in parsing --vmware arguments" >&2 && exit 1
		[ -s $1 ] && cp $1 vmware.conf
		shift 
		args_processed=1
	elif [ "$1" = "--ask" ]; then
		sed -i "s#^ask=[^ \t]*#ask=true #g" aba.conf
		shift 
		args_processed=1
	elif [ "$1" = "--noask" ]; then
		sed -i "s#^ask=[^ \t]*#ask=false #g" aba.conf
		shift 
		args_processed=1
#	elif [ "$1" = "--cmd" ]; then
#		[ ! "$2" ] && echo_red "Missing command after --cmd" >&2 && exit 1
#		cmd="$2"
#		shift 2
	else
		#echo_red "Unknown option: $1" >&2
		#err=1
		
		# Gather options and args not recognized above and pass them to "make"... yes make! 
		OTHER_OPTS="$OTHER_OPTS $1"

		#echo OTHER_OPTS=$OTHER_OPTS >&2
		shift 
	fi
done

[ "$err" ] && echo_red "An error has occurred, aborting!" >&2 && exit 1

if [ "$ACTION" = "bundle" ]; then
	make -s bundle out="$bundle_dest_path"

	exit 
fi

echo OTHER_OPTS=$OTHER_OPTS >&2

[ "$args_processed" ] && echo args_processed=$args_processed >&2 && exit 0

# Next part will "translate" the options into what make is expecting, eg. --force to force=1

if [ ! "$interactive_mode" ]; then
	# Translate the options not recognized above
	echo DEBUG: fixing args OTHER_OPTS=$OTHER_OPTS >&2

	# This is a HACK, so that make can receive out=file properly (---out is parsed earlier)
	if [ "$bundle_dest_path" ]; then
		echo DEBUG: fixing args OTHER_OPTS=$OTHER_OPTS >&2
		OTHER_OPTS="$OTHER_OPTS --out $bundle_dest_path"
		echo DEBUG: fixing args OTHER_OPTS=$OTHER_OPTS >&2
#	elif [ "$cmd" ]; then
#		OTHER_OPTS="$OTHER_OPTS --cmd='$cmd'"
	fi

	# Translate options to make format
	# FIXME: -d and --dir needed here?
	args=$(echo "$OTHER_OPTS" | sed -E \
		-e "s/ --dir\s*/ -C /g" \
		-e "s/ -d\s*/ -C /g" \
		-e "s/ --name\s*/ name=/g" \
		-e "s/ -n\s*/ name=/g" \
		-e "s/ --type\s*/ type=/g" \
		-e "s/ -t\s*/ type=/g" \
		-e "s/ --step\s*/ target=/g" \
		-e "s/ -s\s*/ target=/g" \
		-e "s/ --out\s*/ out=/g" \
		-e "s/ -o\s*/ out=/g" \
		-e "s/ --force\s*/ force=1/g" \
		-e "s/ -f\s*/ force=1/g" \
		-e "s/ --cmd\s*/ cmd=/g" \
		-e "s/ -c\s*/ cmd=/g" \
		-e "s/ --retry\s*/ retry=/g" \
		-e "s/ -r\s*/ retry=/g" \
		-e "s/ --debug\s*/ debug=1/g" \
		-e "s/ --wait\s*/ wait=1/g" \
		-e "s/ -w\s*/ wait=1/g" \

	)  # Keep the empty line above!

	# No short options should get this far! 
	echo $args | grep -q -e " -[a-z]" && echo "Unknown args '$args'" >&2 && exit 1

	echo "DEBUG: Running: 'make -s $args'" >&2

	# This needs to be simplified!
	[ "$orig_dir" ] && echo cd $orig_dir && cd $orig_dir
	make -s $args

	exit 
fi

# ###########################################
# From now on it's all considered INTERACTIVE

source <(normalize-aba-conf)

# Include aba bin path and common scripts
### export PATH=$PWD/bin:$PATH  # done in include.sh

cat others/message.txt


##############################################################################################################################
# Determine if this is an "aba bundle" or just a clone from GitHub

if [ ! -f .bundle ]; then
	# Fresh GitHub clone of Aba repo detected!

	echo -n "Checking Internet connectivity ..."
	if ! curl --connect-timeout 10 --retry 2 -sL https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable/release.txt > /tmp/.release.txt; then
		[ "$TERM" ] && tput el1 && tput cr
		echo_red "Cannot access https://mirror.openshift.com/.  Ensure you have Internet access to download the required images." >&2
		echo_red "To get started with Aba run it on a connected workstation/laptop with Fedora or RHEL and try again." >&2

		exit 1
	fi

	[ "$TERM" ] && tput el1 && tput cr

	##############################################################################################################################
	# Determine OCP channel

	[ "$ocp_channel" = "eus" ] && ocp_channel=stable  # .../ocp/eus/release.txt does not exist!

	if [ "$ocp_channel" ]; then
		echo_cyan "OpenShift update channel is defined in aba.conf as '$ocp_channel'."
	else
		echo_cyan -n "Which OpenShift update channel do you want to use? (f)ast, (s)table, or (c)andidate) [stable]: "
		read ans
		[ ! "$ans" ] && ocp_channel=stable
		[ "$ans" = "f" ] && ocp_channel=fast
		[ "$ans" = "s" ] && ocp_channel=stable
		#[ "$ans" = "e" ] && ocp_channel=eus
		[ "$ans" = "c" ] && ocp_channel=candidate

		sed -i "s/ocp_channel=[^ \t]*/ocp_channel=$ocp_channel /g" aba.conf
		echo_cyan "'ocp_channel' set to '$ocp_channel' in aba.conf"
		sleep 0.5
	fi

	##############################################################################################################################
	# Fetch release.txt

	if ! curl --connect-timeout 10 --retry 2 -sL https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/$ocp_channel/release.txt > /tmp/.release.txt; then
		[ "$TERM" ] && tput el1 && tput cr
		echo_red "Failed to access https://mirror.openshift.com" >&2

		exit 1
	fi

	###[ "$TERM" ] && tput el1 && tput cr

	##############################################################################################################################
	# Determine OCP version 

	if [ "$ocp_version" ]; then
		echo_cyan "OpenShift version is defined in aba.conf as '$ocp_version'."
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

		echo_cyan "Which version of OpenShift do you want to install?"

		target_ver=
		while true
		do
			# Exit loop if release version exists
			if echo "$target_ver" | grep -E -q "^[0-9]+\.[0-9]+\.[0-9]+"; then
				if curl --connect-timeout 10 --retry 2 -sIL -o /dev/null -w "%{http_code}\n" https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/$target_ver/release.txt | grep -q ^200$; then
					break
				else
					echo_red "Error: Failed to find release $target_ver" >&2
				fi
			fi

			[ "$stable_ver" ] && or_s="or $stable_ver (latest) "
			[ "$stable_ver_prev" ] && or_p="or $stable_ver_prev (previous) "

			echo_cyan -n "Enter version $or_s$or_p$or_ret(<version>/l/p/Enter) [$default_ver]: "

			read target_ver
			[ ! "$target_ver" ] && target_ver=$default_ver          # use default
			[ "$target_ver" = "l" ] && target_ver=$stable_ver       # latest
			[ "$target_ver" = "p" ] && target_ver=$stable_ver_prev  # previous latest
		done

		# Update the conf file
		sed -i "s/ocp_version=[^ \t]*/ocp_version=$target_ver /g" aba.conf
		echo_cyan "'ocp_version' set to '$target_ver' in aba.conf"

		sleep 0.5
	fi

	# Just in case, check the target ocp version in aba.conf matches any existing versions defined in oc-mirror imageset config files. 
	# FIXME: Any better way to do this?! .. or just keep this check in 'aba sync' and 'aba save' (i.e. before we d/l the images
	(
		install_rpms make || exit 1
		make -s -C mirror checkversion 
	) || exit 

	##############################################################################################################################
	# Determine editor

	if [ ! "$editor" ]; then
		echo
		echo    "Aba can use an editor to aid in the workflow."
		echo -n "Enter your preferred editor or set to 'none' if you prefer to edit the configuration files yourself ('vi', 'nano' etc or 'none')? [vi]: "
		read new_editor

		[ ! "$new_editor" ] && new_editor=vi  # default

		if [ "$new_editor" != "none" ]; then
			if ! which $new_editor >/dev/null 2>&1; then
				echo_red "Editor '$new_editor' command not found! Please install your preferred editor and try again!" >&2
				exit 1
			fi
		fi

		sed -E -i -e 's/^editor=[^ \t]+/editor=/g' -e "s/^editor=([[:space:]]+)/editor=$new_editor\1/g" aba.conf
		export editor=$new_editor
		echo_cyan "'editor' set to '$new_editor' in aba.conf"

		sleep 0.5
	fi

	##############################################################################################################################
	# Allow edit of aba.conf

	if [ ! -f .aba.conf.seen ]; then
		touch .aba.conf.seen

		edit_file aba.conf "Edit aba.conf to set global values, e.g. platform, pull secret, default base domain & net address, dns & ntp etc (if known)" || exit 1
	fi


	##############################################################################################################################
	# Determine pull secret

	if grep -qi "registry.redhat.io" $pull_secret_file 2>/dev/null; then
		echo_cyan "Pull secret found at '$pull_secret_file'."

		install_rpms make || exit 1

		# Now we have the required ocp version, we can fetch the operator index in the background (to save time).
		make -s -C mirror init >/dev/null 2>&1
		( cd mirror; scripts/download-operator-index.sh --background > .fetch-index.log 2>&1)

		sleep 0.5
	else
		echo
		echo_red "Error: No Red Hat pull secret file found at '$pull_secret_file'!" >&2
		echo_white "To allow access to the Red Hat image registry, please download your Red Hat pull secret and store is in the file '$pull_secret_file' and try again!"
		echo_white "Note that the location of your pull secret file can be changed in 'aba.conf'."
		echo

		exit 1
	fi

	# make & jq are needed below and in the next steps 
	#install_rpms make jq python3-pyyaml
	scripts/install-rpms.sh external 

	##############################################################################################################################
	# Determine air-gapped

	echo
	echo_white "If you intend to install OpenShift into a fully disconnected (i.e. air-gapped) environment, Aba can download all required software"
	echo_white "(Quay mirror registry install file, container images and CLI install files) and create a 'bundle archive' for you to transfer into your disconnected environment."
	if ask "Install OpenShift into a fully disconnected network environment"; then
		echo
		echo_yellow Instructions
		echo
		echo "Run: aba bundle --out /path/to/portable/media             # to save all images to local disk & then create the bundle archive"
		echo "                                                          # (size ~20-30GB for a base installation)."
		echo "     aba bundle --out - | ssh user@remote -- tar xvf -    # Stream the archive to a remote host and unpack it there."
		echo "     aba bundle --out - | split -b 10G - ocp_             # Stream the archive and split it into several more managable files."
		echo "                                                          # Unpack the files with: cat ocp_* | tar xvf - "
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
		echo "Run: aba cluster --name myclustername [--type <sno|compact|standard>] [--step <command>]"
		echo 

		exit 1
	fi

	echo 
	echo_yellow Instructions
	echo 
	echo "Action required: Set up the mirror registry and sync it with the necessary container images."
	echo
	echo "To store container images, Aba can install the Quay mirror appliance or you can use an existing container registry."
	echo
	echo "Run:"
	echo "  aba mirror                  # to configure and/or install Quay."
	echo "  aba sync --retry N          # to sychnonize all container images - from the Internet - into your registry."
	echo
	echo "Or run:"
	echo "  aba mirror sync --retry 8   # to complete both actions and ensure any image sync issues are retried."
	echo

else
	# aba is running on the internal bastion, in 'bundle' mode.

	# make & jq are needed below and in the next steps 
	#install_rpms make jq python3-pyyaml
	scripts/install-rpms.sh internal

	echo_cyan "Aba bundle detected! This aba bundle is ready to install OpenShift version '$ocp_version', assuming this is running on an internal RHEL bastion!"
	
	# Check if tar files are already in place
	if [ ! "$(ls mirror/save/mirror_seq*tar 2>/dev/null)" ]; then
		echo
		echo_red "Warning: Please ensure the image set tar files (created in the previous step with 'aba save') are copied to the 'aba/mirror/save' directory before following the instructions below!" >&2
		echo_red "         For example, run the command: cp /path/to/portable/media/mirror_seq*tar mirror/save" >&2
	fi

	echo 
	echo_yellow Instructions
	echo 
	echo "Action Required: Set up the mirror registry and load it from disk with the necessary container images."
	echo
	echo "To store container images, Aba can install the Quay mirror appliance or you can utilize an existing container registry."
	echo
	echo "Run:"
	echo "  aba mirror                   # to configure and/or install Quay."
	echo "  aba load --retry N           # to set up the mirror registry (configure or install quay) and load it."
	echo "Or run:"
	echo "  aba mirror load --retry 8    # to complete both actions and ensure any image load issues are retried."
	echo
fi

echo "Once the images are stored in the mirror registry, you can proceed with the OpenShift installation by following the instructions provided."
echo

