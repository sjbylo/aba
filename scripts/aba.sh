#!/bin/bash -e
# Start here, run this script to get going!

ABA_VERSION=20250106115329

uname -o | grep -q "^Darwin$" && echo "Please run aba on RHEL or Fedora. Most tested is RHEL 9 (no oc-mirror for Mac OS)." >&2 && exit 1

# Check sudo or root access 
[ "$(sudo id -run)" != "root" ] && echo "Please run aba as root or configure passwordless sudo, then try again." >&2 && exit 1

# Having $1 = --dir is an exception only, $1 can point to the top-level repo dir only
if [ "$1" = "--dir" -o "$1" = "-d" ]; then
	[ ! "$2" ] && echo "Error: directory missing after: [$1]" >&2 && exit 1
	[ ! -e "$2" ] && echo "Error: directory [$2] missing!" >&2 && exit 1
	[ ! -d "$2" ] && echo "Error: cannot change to [$2]: not a directory!" >&2 && exit 1

	[ "$DEBUG_ABA" ] && echo "cd \"$2\"" >&2
	cd "$2"
	shift 2
fi

# Check the rpo location
# Need to be sure location of the top of the repo in order to find the important files
if [ -s Makefile ] && grep -q "Top level Makefile" Makefile; then
	ABA_PATH=.
elif [ -s ../Makefile ] && grep -q "Top level Makefile" ../Makefile; then
	ABA_PATH=..
elif [ -s ../../Makefile ] && grep -q "Top level Makefile" ../../Makefile; then
	ABA_PATH=../..
elif [ -s ../../../Makefile ] && grep -q "Top level Makefile" ../../../Makefile; then
	ABA_PATH=../../..
else
	(
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
	) >&2

	exit 1
fi

# Check if aba script needs to be updated
if [ -s $ABA_PATH/scripts/aba.sh ] && grep -Eq "^ABA_VERSION=[0-9]+" $ABA_PATH/scripts/aba.sh; then
	REPO_VER=$(grep "^ABA_VERSION=" $ABA_PATH/scripts/aba.sh | cut -d= -f2)
	[ "$REPO_VER" -a $REPO_VER -gt $ABA_VERSION -a -x $ABA_PATH/install ] && echo "Updating aba script .." >&2 && $ABA_PATH/install -q >&2 && exec "$0" "$@"
fi

usage=$(cat $ABA_PATH/others/help.txt)

# FIXME: only found from the top level dir!
# "Repo checking" above should ensure this always works
source $ABA_PATH/scripts/include_all.sh

# This will be the actual 'make' command that will eventually be run
BUILD_COMMAND=

# Init aba.conf
if [ ! -f $ABA_PATH/aba.conf ]; then
	cp $ABA_PATH/templates/aba.conf $ABA_PATH

	# Initial prep for interactive mode
	sed -i "s/^ocp_version=[^ \t]*/ocp_version= /g" $ABA_PATH/aba.conf
	sed -i "s/^ocp_channel=[^ \t]*/ocp_channel= /g" $ABA_PATH/aba.conf
	sed -i "s/^editor=[^ \t]*/editor= /g" $ABA_PATH/aba.conf
fi

# FIXME: for testing, if unset, testing will halt in edit_file()! 
# for testing, if unset, testing will halt in edit_file()! 
#[ "$*" ] && \
#	sed -i "s/^editor=[^ \t]*/editor=vi /g" $ABA_PATH/aba.conf && \
#	sed -i "s/^ask=[^ \t]*/ask= /g" $ABA_PATH/aba.conf


# Set defaults 
ops_list=
op_set_list=
chan=stable

interactive_mode=
[ "$*" ] && interactive_mode_none=1

while [ "$*" ] 
do
	[ "$DEBUG_ABA" ] && echo "\$* = " $* >&2

	if [ "$1" = "--help" -o "$1" = "-h" ]; then
		echo "$usage"

		exit 0
	elif [ "$1" = "-i" ]; then
		interactive_mode=1
		interactive_mode_none=
		sed -i "s/^ask=[^ \t]*/ask=true /g" $ABA_PATH/aba.conf

		shift
	elif [ "$1" = "--dir" -o "$1" = "-d" ]; then
		if [ ! "$WORK_DIR" ]; then
			[ ! "$2" ] && echo "Error: directory missing after: [$1]" >&2 && exit 1
			[ ! -e "$2" ] && echo "Error: directory [$2] missing!" >&2 && exit 1
			[ ! -d "$2" ] && echo "Error: cannot change to [$2]: not a directory!" >&2 && exit 1

			# make will take one -C option only
			BUILD_COMMAND="$BUILD_COMMAND -C '$2'"
			WORK_DIR="$2"
			[ "$DEBUG_ABA" ] && echo "-C \"$WORK_DIR\"" >&2
			#cd "$WORK_DIR"
			#ABA_PATH=.
			shift 2
		else
			# We only act on the first --dir <dir> option and ignore all others
			if [ "$2" ] && echo "$2" | grep -q "^-"; then
				shift   # shift over the '--dir' only
			else
				# Check if it's a dir
				[ "$2" -a -e "$2" -a -d "$2" ] && shift  # shift only if it's really a dir
			fi
		fi
	elif [ "$1" = "--info" ]; then
		export INFO_ABA=1
		shift 
	elif [ "$1" = "--debug" -o "$1" = "-D" ]; then
		export DEBUG_ABA=1
		export INFO_ABA=1
		shift 
	#elif [ "$1" = "bundle" ]; then
		#ACTION=bundle
		#shift
	elif [ "$1" = "--out" -o "$1" = "-o" ]; then
		shift
		[ ! "$1" ] && echo_red "Error: Argument to "--out <file|->" is missing!" >&2 && exit 1
		if [ "$1" = "-" ]; then
			BUILD_COMMAND="$BUILD_COMMAND out=-"
		else
			echo "$1" | grep -q "^-" && echo_red "Error in parsing --out path argument" >&2 && exit 1
			[ "$1" ] && [ ! -d $(dirname $1) ] && echo_red "Directory: [$(dirname $1)] incorrect or missing!" >&2 && exit 1
			#[ "$1" != "-" ] && [ -f "$1.tar" ] && echo_red "Bundle archive file [$1.tar] already exists!" >&2 && exit 1
				[ -f "$1.tar" ] && echo_red "Bundle archive file [$1.tar] already exists!" >&2 && exit 1
			###[ "$1" ] && bundle_dest_path="$1"
			BUILD_COMMAND="$BUILD_COMMAND out='$1'"
		fi
		shift
		# FIXME: This is just one use-case where --all is an opewtion which *is* needed my make! ==> Simplify!!
	elif [ "$1" = "--channel" -o "$1" = "-c" ]; then
		shift 
		echo "$1" | grep -q "^-" && echo_red "Error in parsing --channel arguments" >&2 && exit 1
		chan=$(echo $1 | grep -E -o '^(stable|fast|eus|candidate)$')
		sed -i "s/ocp_channel=[^ \t]*/ocp_channel=$chan /g" $ABA_PATH/aba.conf
		target_chan=$chal
		shift 
	elif [ "$1" = "--version" -o "$1" = "-v" ]; then
		shift 
		ver=$1
		echo "$ver" | grep -q "^-" && echo_red "Error in parsing --version arguments" >&2 && exit 1
		if ! curl --connect-timeout 10 --retry 2 -sL https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/$chan/release.txt > /tmp/.$(whoami)-release.txt; then
			echo_red "Cannot access https://mirror.openshift.com/.  Ensure you have Internet access to download the required images." >&2
			echo_red "To get started, run Aba on a connected workstation/laptop with Fedora or RHEL and try again." >&2

			exit 1
		fi

		[ "$ver" = "latest" ] && ver=$(fetch_latest_version $chan)
		ver=$(echo $ver | grep -E -o "[0-9]+\.[0-9]+\.[0-9]+" || true)
		[ ! "$ver" ] && echo_red "Missing value after --version. OpenShift version missing or wrong format!" >&2 && echo >&2 && echo "$usage" >&2 && exit 1
		sed -i "s/ocp_version=[^ \t]*/ocp_version=$ver /g" $ABA_PATH/aba.conf
		target_ver=$ver

		# Now we have the required ocp version, we can fetch the operator index in the background (to save time).
		[ "$DEBUG_ABA" ] && echo Downloading operator index for version $ver >&2
		make -s -C $ABA_PATH/mirror init >/dev/null 2>&1
		####( cd $ABA_PATH/mirror; date > .fetch-index.log; $ABA_PATH/scripts/download-operator-index.sh --background >> .fetch-index.log 2>&1)
		(
			(
				make -s -C $ABA_PATH/cli ~/bin/oc-mirror >$ABA_PATH/mirror/.log  2>&1 && \
				cd $ABA_PATH/mirror && \
				date > .fetch-index.log && \
				$ABA_PATH/scripts/download-operator-index.sh --background >> .fetch-index.log 2>&1
			) &
		) & 

		shift 

	elif [ "$1" = "--target-hostname" -o "$1" = "-H" ]; then
		echo "$2" | grep -q "^-" && echo_red "Error in parsing [$1] arguments" >&2 && exit 1
		[ ! "$2" ] && echo_red "Missing argument for [$1]" >&2 && exit 1
		make -sC $ABA_PATH/mirror mirror.conf
		sed -i "s/^reg_host=[^ \t]*/reg_host=$2 /g" $ABA_PATH/mirror/mirror.conf

		shift 2

	elif [ "$1" = "--reg-ssh-key" -o "$1" = "-k" ]; then
		echo "$2" | grep -q "^-" && echo_red "Error in parsing [$1] arguments" >&2 && exit 1
		[ ! "$2" ] && echo_red "Missing argument for [$1]" >&2 && exit 1
		sed -i "s|^#*reg_ssh_key=[^ \t]*|reg_ssh_key=$2 |g" $ABA_PATH/mirror/mirror.conf

		shift 2

	elif [ "$1" = "--reg-ssh-user" -o "$1" = "-U" ]; then
		echo "$2" | grep -q "^-" && echo_red "Error in parsing [$1] arguments" >&2 && exit 1
		[ ! "$2" ] && echo_red "Missing argument for [$1]" >&2 && exit 1
		sed -i "s/^reg_ssh_user=[^ \t]*/reg_ssh_user=$2 /g" $ABA_PATH/mirror/mirror.conf

		shift 2

	elif [ "$1" = "--base-domain" -o "$1" = "-b" ]; then
		echo "$2" | grep -q "^-" && echo_red "Error in parsing [$1] arguments" >&2 && exit 1
		domain=$(echo $2 | grep -Eo '([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}')
		sed -i "s/^domain=[^ \t]*/domain=$domain /g" $ABA_PATH/aba.conf
		###target_domain=$domain

		shift 2

	elif [ "$1" = "--dns" -o "$1" = "-N" ]; then
		dns_ips=""
		while [ "$2" ] && ! echo "$2" | grep -q -e "^-"
		do
			# Skip invalid values (ip)
			if echo "$2" | grep -q -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
				[ "$dns_ips" ] && dns_ips="$dns_ips,$2" || dns_ips="$2"
			else
				echo_red "Skipping invalid IP address [$2]" >&2
			fi
			shift
		done
		sed -i "s/^dns_servers=[^ \t]*/dns_servers=$dns_ips /g" $ABA_PATH/aba.conf
		shift 

	elif [ "$1" = "--ntp" -o "$1" = "-T" ]; then
		# Check arg after --ntp, if "empty" then remove value from aba.conf, otherwise add valid ip addr
		ntp_vals=""
		# While there is a valid arg...
		while [ "$2" ] && ! echo "$2" | grep -q -e "^-"
		do
			[ "$ntp_vals" ] && ntp_vals="$ntp_vals,$2" || ntp_vals="$2"
			shift	
		done
		sed -i "s/^ntp_servers=[^ \t]*/ntp_servers=$ntp_vals /g" $ABA_PATH/aba.conf
		shift 
	elif [ "$1" = "--default-route" -o "$1" = "-R" ]; then
		shift 
		def_route_ip=
		if [ "$1" ] && ! echo "$1" | grep -q "^-"; then
			def_route_ip=$(echo $1 | grep -Eo '^([0-9]{1,3}\.){3}[0-9]{1,3}$')
		fi

		sed -i "s/^next_hop_address=[^ \t]*/next_hop_address=$def_route_ip /g" $ABA_PATH/aba.conf

		shift 
	elif [ "$1" = "--platform" -o "$1" = "-p" ]; then
		shift 
		echo "$1" | grep -q "^-" && echo_red "Error in parsing --platform arguments" >&2 && exit 1
		[ ! "$1" ] && echo_red -e "Missing platform, see usage.\n$usage" >&2 && exit 1
		platform="$1"
		sed -i "s/^platform=[^ \t]*/platform=$platform /g" $ABA_PATH/aba.conf
		shift
	elif [ "$1" = "--op-sets" -o "$1" = "-P" ]; then
		shift
		echo "$1" | grep -q "^-" && echo_red "Error in parsing '--op-sets' arguments" >&2 && exit 1
		[ ! "$1" ] && echo_red "Warning: Missing args when parsing op-sets" >&2 && exit 1
		while [ "$1" ] && ! echo "$1" | grep -q -e "^-"; do [ -s "$ABA_PATH/templates/operator-set-$1" ] && op_set_list="$op_set_list $1" || echo "Missing op. set: $1" >&2; shift; done
		op_set_list=$(echo $op_set_list | xargs | tr -s " " | tr " " ",")  # Trim white space and add ','
		op_set_list=$(echo $op_set_list | tr -s " " | tr " " ",")
		#sed -i "s/^op_sets=[^#$]*/op_sets=\"$op_set_list\" /g" $ABA_PATH/aba.conf
		sed -i "s/^op_sets=[^#$]*/op_sets=$op_set_list /g" $ABA_PATH/aba.conf
	elif [ "$1" = "--ops" -o "$1" = "-O" ]; then
		shift
		echo "$1" | grep -q "^-" && echo_red "Error in parsing '--ops' arguments" >&2 && exit 1
		[ ! "$1" ] && echo_red "Warning: Missing args when parsing '--ops'" >&2 && exit 1
		while [ "$1" ] && ! echo "$1" | grep -q -e "^-"; do ops_list="$ops_list $1"; shift; done
		ops_list=$(echo $ops_list | xargs | tr -s " " | tr " " ",")  # Trim white space and add ','
		##sed -i "s/^ops=[^#$]*/ops=\"$ops_list\" /g" $ABA_PATH/aba.conf
		sed -i "s/^ops=[^#$]*/ops=$ops_list /g" $ABA_PATH/aba.conf
	elif [ "$1" = "--editor" -o "$1" = "-e" ]; then
		shift 
		echo "$1" | grep -q "^-" && echo_red "Error in parsing --editor arguments" >&2 && exit 1
		[ ! "$1" ] && echo_red -e "Missing editor, see usage.\n$usage" >&2 && exit 1
		editor="$1"
		sed -i "s/^editor=[^ \t]*/editor=$editor /g" $ABA_PATH/aba.conf
		shift
	elif [ "$1" = "--machine-network" -o "$1" = "-M" ]; then
		#shift 
		echo "$2" | grep -q "^-" && echo_red "Error in parsing argument of [$1]" >&2 && exit 1
		[ ! "$2" ] && echo_red "Missing machine network value after [$1]" >&2 && exit 1
		sed -i "s#^machine_network=[^ \t]*#machine_network=$2 #g" $ABA_PATH/aba.conf
		shift 2
	elif [ "$1" = "--pull-secret" -o "$1" = "-S" ]; then
		shift 
		echo "$1" | grep -q "^-" && echo_red "Error in parsing --pull-secret arguments" >&2 && exit 1
		[ ! -s $1 ] && echo_red "Missing pull secret file [$1]" >&2 && exit 1
		sed -i "s#^pull_secret_file=[^ \t]*#pull_secret_file=$1 #g" $ABA_PATH/aba.conf
		shift 
	elif [ "$1" = "--vmware" -o "$1" = "--vmw" -o "$1" = "-V" ]; then
		shift 
		echo "$1" | grep -q "^-" && echo_red "Error in parsing --vmware arguments" >&2 && exit 1
		[ -s $1 ] && cp $1 vmware.conf
		shift 
	elif [ "$1" = "--ask" -o "$1" = "-a" ]; then
		sed -i "s#^ask=[^ \t]*#ask=true #g" $ABA_PATH/aba.conf
		shift 
	elif [ "$1" = "--noask" -o "$1" = "-A" ]; then
		sed -i "s#^ask=[^ \t]*#ask=false #g" $ABA_PATH/aba.conf
		shift 
	elif [ "$1" = "--name" -o "$1" = "-n" ]; then
		# If there's another arg and it's not an option (^-), accept it, otherwise error.
		if [ "$2" ] && ! echo "$2" | grep -q "^-"; then
			BUILD_COMMAND="$BUILD_COMMAND name='$2'"
			shift 2
		else
			echo_red "Error: Missing or incorrect argument after option [$1]" >&2 && exit 1
		fi

	elif [ "$1" = "--type" -o "$1" = "-t" ]; then
		# If there's another arg and it's an expected cluster type, accept it, otherwise error.
		if echo "$2" | grep -qE "^sno$|^compact$|^standard$"; then
			BUILD_COMMAND="$BUILD_COMMAND type='$2'"
			shift 2
		else
			echo_red "Error: Missing or incorrect argument (sno|compact|standard) after option [$1]" >&2 && exit 1
		fi

	elif [ "$1" = "--step" -o "$1" = "-s" ]; then
		# If there's another arg and it's NOT an option (^-) then accept it, otherwise error
		if [ "$2" ] && ! echo "$2" | grep -q "^-"; then
			BUILD_COMMAND="$BUILD_COMMAND target='$2'"
			shift
		else
			echo_red "Error: Missing argument after option [$1]" >&2 && exit 1
		fi
		shift

	elif [ "$1" = "--retry" -o "$1" = "-r" ]; then
		# If there's another arg and it's a number then accept it
		if [ "$2" ] && echo "$2" | grep -qE "^[0-9]+"; then
			BUILD_COMMAND="$BUILD_COMMAND retry='$2'"
			[ "$DEBUG_ABA" ] && echo Adding retry=$2 to BUILD_COMMAND >&2
			shift 2
		# If there's no another arg then assume '1'
		elif [ ! "$2" ]; then
			BUILD_COMMAND="$BUILD_COMMAND retry=1"
			[ "$DEBUG_ABA" ] && echo Adding retry=1 to BUILD_COMMAND >&2
			shift
		else
			echo_red "Error: Missing argument after option [$1]" >&2 && exit 1
		fi
	elif [ "$1" = "--force" -o "$1" = "-f" ]; then
		# If there's another arg and it's NOT an option (^-) then error
		###if [ "$2" ] && ! echo "$2" | grep -q "^-"; then
		###	echo_red "Error: unexpected argument after [$1]" >&2 && exit 1
		###fi
		shift
		BUILD_COMMAND="$BUILD_COMMAND force=1"
	elif [ "$1" = "--wait" -o "$1" = "-w" ]; then
		## NOT TRUE # If there is another arg, it must be an option, otherwise error
		## NOT TRUE if [ "$2" ] && ! echo "$2" | grep -q "^-"; then
			## NOT TRUE echo_red "Error: unexpected argument after [$1]" >&2 && exit 1
		## NOT TRUE fi
		shift
		BUILD_COMMAND="$BUILD_COMMAND wait=1"
	elif [ "$1" = "--cmd" ]; then
		# Note, -c used for --channel
		cmd=
		shift 
		echo "$1" | grep -q "^-" || cmd="$1"
		[ "$cmd" ] && shift || cmd="get co" # Set default comamnd here

		if [[ "$BUILD_COMMAND" =~ "ssh" ]]; then
			BUILD_COMMAND="$BUILD_COMMAND cmd='$cmd'"
			[ "$DEBUG_ABA" ] && echo BUILD_COMMAND=$BUILD_COMMAND >&2
		elif [[ "$BUILD_COMMAND" =~ "cmd" ]]; then
			BUILD_COMMAND="$BUILD_COMMAND cmd='$cmd'"
			[ "$DEBUG_ABA" ] && echo BUILD_COMMAND=$BUILD_COMMAND >&2
		else
			# Assume it's a kube command by default
			BUILD_COMMAND="$BUILD_COMMAND cmd cmd='$cmd'"
			[ "$DEBUG_ABA" ] && echo BUILD_COMMAND=$BUILD_COMMAND >&2
		fi
	else
		if echo "$1" | grep -q "^-"; then
			echo_red "Error: invaid option [$1]" >&2
			exit 1
		else
			# Assume any other args are "commands", e.g. 'cluster', 'verify', 'mirror', 'ssh', 'cmd' etc 
			# Gather options and args not recognized above and pass them to "make"... yes, we're using make! 
			BUILD_COMMAND="$BUILD_COMMAND $1"
			[ "$DEBUG_ABA" ] && echo Command added: BUILD_COMMAND=$BUILD_COMMAND >&2
		fi
		shift 
	fi
done

####[ "$err" ] && echo_red "An error has occurred, aborting!" >&2 && exit 1

[ "$DEBUG_ABA" ] && echo DEBUG: interactive_mode=$interactive_mode >&2

# Sanitize $BUILD_COMMAND
BUILD_COMMAND=$(echo "$BUILD_COMMAND" | tr -s " " | sed -E -e "s/^ //g" -e "s/ $//g")

[ "$DEBUG_ABA" ] &&  echo "ABA_PATH=[$ABA_PATH]"
[ "$DEBUG_ABA" ] &&  echo "BUILD_COMMAND=[$BUILD_COMMAND]"

# We want interactive mode if aba is running at the top of the repo and without any args
[ ! "$BUILD_COMMAND" -a "$ABA_PATH" = "." ] && interactive_mode=1

if [ ! "$interactive_mode" ]; then
	[ "$DEBUG_ABA" ] && echo "DEBUG: Running: \"make $BUILD_COMMAND\" from dir $PWD" >&2

	# eval is needed here since $BUILD_COMMAND should not be evaluated/processed (it may have ' or " in it)
	if [ "$DEBUG_ABA" ]; then
		eval make    $BUILD_COMMAND
	else
		eval make -s $BUILD_COMMAND
	fi

	exit 
fi

# We don't want interactive mode if there were args in the command
#[ "$interactive_mode_none" ] && echo Exiting ... >&2 && exit 
[ "$interactive_mode_none" ]                          && exit 

# Change to the top level repo directory
cd $ABA_PATH

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
	if ! curl --connect-timeout 10 --retry 2 -sL https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable/release.txt > /tmp/.$(whoami)-release.txt; then
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
		sleep 0.3
	fi

	##############################################################################################################################
	# Fetch release.txt

	if ! curl --connect-timeout 10 --retry 2 -sL https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/$ocp_channel/release.txt > /tmp/.$(whoami)-release.txt; then
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
		stable_ver=$(cat /tmp/.$(whoami)-release.txt | grep -E -o "Version: +[0-9]+\.[0-9]+\.[0-9]+" | awk '{print $2}')
		default_ver=$stable_ver

		# Extract the previous stable point version, e.g. 4.13.23
		major_ver=$(echo $stable_ver | grep ^[0-9] | cut -d\. -f1)
		stable_ver_point=`expr $(echo $stable_ver | grep ^[0-9] | cut -d\. -f2) - 1`
		[ "$stable_ver_point" ] && \
			stable_ver_prev=$(cat /tmp/.$(whoami)-release.txt| grep -oE "${major_ver}\.${stable_ver_point}\.[0-9]+" | tail -n 1)

		# Determine any already installed tool versions
		which openshift-install >/dev/null 2>&1 && cur_ver=$(openshift-install version | grep ^openshift-install | grep -E -o "[0-9]+\.[0-9]+\.[0-9]+")

		# If openshift-install is already installed, then offer that version also
		[ "$cur_ver" ] && or_ret="or [current version] " && default_ver=$cur_ver

		[ "$TERM" ] && tput el1 && tput cr
		sleep 0.3

		echo_cyan "Which version of OpenShift do you want to install?"

		target_ver=
		while true
		do
			# Exit loop if release version exists
			if echo "$target_ver" | grep -E -q "^[0-9]+\.[0-9]+\.[0-9]+"; then
				if curl --connect-timeout 10 --retry 2 -sL -o /dev/null -w "%{http_code}\n" https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/$target_ver/release.txt | grep -q ^200$; then
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

		sleep 0.3
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
		echo -n "Enter your preferred editor or set to 'none' if you prefer to edit the configuration files manually ('vi', 'nano' etc or 'none')? [vi]: "
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

		sleep 0.3
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
		[ "$INFO_ABA" ] && echo_cyan "Pull secret found at '$pull_secret_file'."

		install_rpms make || exit 1

		# Now we have the required ocp version, we can fetch the operator index in the background (to save time).
		make -s -C mirror init >/dev/null 2>&1

		(
			(
				make -s -C cli ~/bin/oc-mirror >mirror/.log  2>&1 && \
				cd mirror && \
				date > .fetch-index.log && \
				scripts/download-operator-index.sh --background >> .fetch-index.log 2>&1
			) &
		) & 

		sleep 0.3
	else
		echo
		echo_red "Error: No Red Hat pull secret file found at '$pull_secret_file'!" >&2
		echo_white "To allow access to the Red Hat image registry, please download your Red Hat pull secret and store it in the file '$pull_secret_file' and try again!"
		echo_white "Note that, if needed, the location of your pull secret file can be changed in 'aba.conf'."
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
	echo_white "OpenShift can be installed directly from the Internet *without* using a mirror registry, e.g. via a proxy."
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

