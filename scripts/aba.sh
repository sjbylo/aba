#!/bin/bash
# Start here, run this script to get going!

ABA_VERSION=20251024224651
# Sanity check
echo -n $ABA_VERSION | grep -qE "^[0-9]{14}$" || { echo "ABA_VERSION in $0 is incorrect [$ABA_VERSION]! Fix the format to YYYYMMDDhhmmss and try again!" >&2 && exit 1; }

arch_sys=$(uname -m)

uname -o | grep -q "^Darwin$" && echo "Run aba on RHEL, Fedora or even in a Centos-Stream container. Most tested is RHEL 9 (no oc-mirror for Mac OS!)." >&2 && exit 1

SUDO=
which sudo 2>/dev/null >&2 && SUDO=sudo

# Check we have sudo or root access 
[ "$SUDO" ] && [ "$(sudo id -run)" != "root" ] && echo "Configure passwordless sudo OR run aba as root, then try again!" >&2 && exit 1

WORK_DIR=$PWD # Remember so can change config file here 

# Change dir if asked
if [ "$1" = "--dir" -o "$1" = "-d" ]; then
	[ ! "$2" ] && echo "Error: directory missing after: [$1]" >&2 && exit 1
	[ ! -e "$2" ] && echo "Error: directory [$2] does not exist!" >&2 && exit 1
	[ ! -d "$2" ] && echo "Error: cannot change to [$2]: not a directory!" >&2 && exit 1

	[ "$DEBUG_ABA" ] && echo "$0: change dir to: \"$2\"" >&2
	cd "$2"
	shift 2

	WORK_DIR=$PWD # Remember so can change config file here - can override existing value (set above)
fi

# Check the repo location
# Need to be sure location of the top of the repo in order to find the important files
# FIXME: Place the files (scripts and templates etc) into a well known location, e.g. /opt/aba/...
if [ -s Makefile ] && grep -q "Top level Makefile" Makefile; then
	ABA_PATH=.
elif [ -s ../Makefile ] && grep -q "Top level Makefile" ../Makefile; then
	ABA_PATH=..
elif [ -s ../../Makefile ] && grep -q "Top level Makefile" ../../Makefile; then
	ABA_PATH=../..
elif [ -s ../../../Makefile ] && grep -q "Top level Makefile" ../../../Makefile; then
	ABA_PATH=../../..
else
	# Give an error to change to the top level dir. Text must be coded here.
	(
		echo "  __   ____   __  "
		echo " / _\ (  _ \ / _\     Install & manage air-gapped OpenShift quickly with the Aba utility!"
		echo "/    \ ) _ (/    \    Follow the instructions below or see the aba/README.md file for more."
		echo "\_/\_/(____/\_/\_/"
		echo
		echo "Run Aba from the top of its repository."
		echo
		echo "For example:                          cd aba"
		echo "                                      aba"
		echo "                                      aba -h"
		echo
		echo "Otherwise, clone Aba from GitHub:     git clone https://github.com/sjbylo/aba.git"
		echo "Change to the Aba repo directory:     cd aba"
		echo "Install latest Aba:                   ./install"
		echo "Run Aba:                              aba" 
		echo "                                      aba -h" 
	) >&2

	exit 1
fi

## install will check if aba needs to be updated, if so it will return 2 ... so we re-execute it!
if [ ! "$ABA_DO_NOT_UPDATE" ]; then
	$ABA_PATH/install -q   # Only aba iself should use the flag -q
	if [ $? -eq 2 ]; then
		export ABA_DO_NOT_UPDATE=1
		$0 "$@"  # This means aba was updated and needs to be called again
		exit
	fi
fi

source $ABA_PATH/scripts/include_all.sh

# This will be the actual 'make' command that will eventually be run
BUILD_COMMAND=

# Init aba.conf
if [ ! -f $ABA_PATH/aba.conf ]; then

	# Determine resonable defaults for ...
	export domain=$(get_domain)
	export machine_network=$(get_machine_network)
	export dns_servers=$(get_dns_servers)
	export next_hop_address=$(get_next_hop)
	export ntp_servers=$(get_ntp_servers)

	scripts/j2 templates/aba.conf.j2 > aba.conf
fi

### Set some defaults 
##ops_list=
##op_set_list=
###chan=stable  # value fetched from aba.conf now

# Fetch any existing values (e.e. ocp_channel is used later for '-v')
source <(normalize-aba-conf)

interactive_mode=
[ "$*" ] && interactive_mode_none=1

cur_target=   # Can be 'cluster', 'mirror', 'save', 'load' etc 

while [ "$*" ] 
do
	[ "$DEBUG_ABA" ] && echo "$0: \$* = " $* >&2

	if [ "$1" = "--help" -o "$1" = "-h" ]; then
		if [ ! "$cur_target" ]; then
			cat $ABA_PATH/others/help-aba.txt
		elif [ "$cur_target" = "mirror" -o "$cur_target" = "save" -o "$cur_target" = "load" -o "$cur_target" = "sync" ]; then
			cat $ABA_PATH/others/help-mirror.txt
		elif [ "$cur_target" = "cluster" ]; then
			cat $ABA_PATH/others/help-cluster.txt
		elif [ "$cur_target" = "bundle" ]; then
			cat $ABA_PATH/others/help-bundle.txt
		else
			# If some other target, then show the main help
			cat $ABA_PATH/others/help-aba.txt
		fi

		exit 0
	elif [ "$1" = "--interactive" ]; then
		interactive_mode=1
		interactive_mode_none=
		# If the user explicitly wants interactive mode, then ensure we make it interactive with "ask=true"
		replace-value-conf -n ask -v true -f $ABA_PATH/aba.conf
		shift
	elif [ "$1" = "--dir" -o "$1" = "-d" ]; then  #FIXME: checking --dir is also above!
		# FIXME: Simplify this!  Put all static files into well-known location?
		# Check id --dir already specified
		if [ ! "$WORK_DIR" ]; then
			[ ! "$2" ] && echo "Error: directory missing after: [$1]" >&2 && exit 1
			[ ! -e "$2" ] && echo "Error: directory [$2] does not exist!" >&2 && exit 1
			[ ! -d "$2" ] && echo "Error: cannot change to [$2]: not a directory!" >&2 && exit 1

			# Note that make will take *one* -C option only, so we only use one also
			BUILD_COMMAND="$BUILD_COMMAND -C '$2'"
			WORK_DIR="$2"
			[ "$DEBUG_ABA" ] && echo "$0: -C \"$WORK_DIR\"" >&2
			#cd "$WORK_DIR"  # Do not cd
			#ABA_PATH=.
			shift 2
		else  # FIXME: this uses make -C ... do we want to do that still?
			# We only act on the first --dir <dir> option and ignore all others
			# If there is no arg...
			if [[ "$2" =~ ^- || -z "$2" ]]; then
				# If there's an option next or $1 is the last arg, pass over
				shift   # shift over the '--dir' only
			else
				# Check if arg is a dir
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
	elif [ "$1" = "--out" -o "$1" = "-o" ]; then
		shift
		if [ "$1" = "-" ]; then
			BUILD_COMMAND="$BUILD_COMMAND out=-"  # FIXME: This only works if command=bundle
		else
			echo "$1" | grep -q "^-" && echo_red "Error in parsing --out path argument" >&2 && exit 1
			[ "$1" ] && [ ! -d $(dirname $1) ] && echo_red "Directory: [$(dirname $1)] incorrect or missing!" >&2 && exit 1
			[ -f "$1.tar" ] && echo_red "Install bundle file [$1.tar] already exists!" >&2 && exit 1

			BUILD_COMMAND="$BUILD_COMMAND out='$1'"
		fi
		shift
	elif [ "$1" = "--channel" -o "$1" = "-c" ]; then
		opt=$1
		# Be strict if arg missing
		[[ "$2" =~ ^- || -z "$2" ]] && echo_red "Error: Missing argument after option $opt" >&2 && exit 1
		chan=$2  # This $chan var can be used below for "--version"
		# As far as possible, always ensure there is a valid value in aba.conf
		case "$chan" in
			stable | s)	chan=stable ;;
			fast | f)	chan=fast ;;
			eus | e)	chan=eus ;;
			candidate | c)	chan=candidate ;;
			*)
				echo_red "Wrong value [$chan] after option $opt" >&2
				exit 1
				;;
		esac
		replace-value-conf -n ocp_channel -v $chan -f $ABA_PATH/aba.conf
		shift 2
	elif [ "$1" = "--version" -o "$1" = "-v" ]; then
		opt=$1
		# Be strict if arg missing
		[[ "$2" =~ ^- || -z "$2" ]] && echo_red "Error: Missing argument after option $opt" >&2 && exit 1
		ver=$2
		[ ! "$chan" ] && chan=$ocp_channel  # Prioritize the $chan var (from above) or fetch from aba.conf file
		case "$ver" in
			latest | l)
				ver=$(fetch_latest_version "$chan" "$arch_sys")
			;;
			previous | p)
				ver=$(fetch_previous_version "$chan" "$arch_sys")
			;;
		esac

		# Expand ver to latest, if it's just a point version (x.y)
		echo $ver | grep -q -E "^[0-9]+\.[0-9]+$" && ver=$(fetch_latest_z_version "$chan" "$ver" "$arch_sys")

		# Extract only the full major.minor.patch version if present
		ver=$(echo "$ver" | grep -Eo '^[0-9]+\.[0-9]+\.[0-9]+$' || true)

		# As far as possible, always ensure there is a valid value in aba.conf
		[ ! "$ver" ] && echo_red "Wrong value [$2] after option $opt" >&2 && exit 1
		replace-value-conf -n ocp_version -v $ver -f $ABA_PATH/aba.conf

		# Now we have the required ocp version, we can fetch the operator index in the background (to save time).
		[ "$DEBUG_ABA" ] && echo $0: Downloading operator index for version $ver >&2

		( make -s -C $ABA_PATH catalog bg=true & ) & 

		shift 2
	elif [ "$1" = "--mirror-hostname" -o "$1" = "-H" ]; then
		[[ "$2" =~ ^- || -z "$2" ]] && echo_red "Error: Missing argument after option $1" >&2 && exit 1
		# force will skip over asking to edit the conf file
		make -sC $ABA_PATH/mirror mirror.conf force=yes
		replace-value-conf -n reg_host -v "$2" -f $ABA_PATH/mirror/mirror.conf
		shift 2
	elif [ "$1" = "--reg-ssh-key" -o "$1" = "-k" ]; then
		# The ssh key used to access the linux registry host
		# If no value, remove from mirror.conf
		#[[ "$2" =~ ^- || -z "$2" ]] && echo_red "Error: Missing argument after option $1" >&2 && exit 1  # FIXME
		[[ "$2" =~ ^- || -z "$2" ]] && reg_ssh_key= || { reg_ssh_key=$2; shift; }
		# force will skip over asking to edit the conf file
		make -sC $ABA_PATH/mirror mirror.conf force=yes
		replace-value-conf -n reg_ssh_key -v "$reg_ssh_key" -f $ABA_PATH/mirror/mirror.conf
		shift
	elif [ "$1" = "--reg-ssh-user" -o "$1" = "-U" ]; then
		# The ssh username used to access the linux registry host
		# If no value, remove from mirror.conf
		#[[ "$2" =~ ^- || -z "$2" ]] && echo_red "Error: Missing argument after option $1" >&2 && exit 1  # FIXME
		[[ "$2" =~ ^- || -z "$2" ]] && reg_ssh_user_val= || { reg_ssh_user_val=$2; shift; }
		# force will skip over asking to edit the conf file
		make -sC $ABA_PATH/mirror mirror.conf force=yes
		replace-value-conf -n reg_ssh_user -v "$reg_ssh_user_val" -f $ABA_PATH/mirror/mirror.conf
		shift
	elif [ "$1" = "--data-dir" ]; then
		[[ "$2" =~ ^- || -z "$2" ]] && echo_red "Error: Missing argument after option $1" >&2 && exit 1
		# force will skip over asking to edit the conf file
		make -sC $ABA_PATH/mirror mirror.conf force=yes
		replace-value-conf -n data_dir -v "$2" -f $ABA_PATH/mirror/mirror.conf
		shift 2
	elif [ "$1" = "--reg-user" ]; then
		# The username used to access the mirror registry 
		[[ "$2" =~ ^- || -z "$2" ]] && echo_red "Error: Missing argument after option $1" >&2 && exit 1
		# force will skip over asking to edit the conf file
		make -sC $ABA_PATH/mirror mirror.conf force=yes
		replace-value-conf -n reg_user -v "$2" -f $ABA_PATH/mirror/mirror.conf
		shift 2
	elif [ "$1" = "--reg-password" ]; then
		# The password used to access the mirror registry 
		# Add a password in ='password'
		#[[ "$2" =~ ^- || -z "$2" ]] && echo_red "Error: Missing argument after option $1" >&2 && exit 1
		[[ "$2" =~ ^- || -z "$2" ]] && reg_pw_value= || { reg_pw_value="$2"; shift; }
		# force will skip over asking to edit the conf file
		make -sC $ABA_PATH/mirror mirror.conf force=yes
		replace-value-conf -n reg_pw -v "'$reg_pw_value'" -f $ABA_PATH/mirror/mirror.conf
		shift
	elif [ "$1" = "--reg-path" ]; then
		[[ "$2" =~ ^- || -z "$2" ]] && echo_red "Error: Missing argument after option $1" >&2 && exit 1
		# force will skip over asking to edit the conf file
		make -sC $ABA_PATH/mirror mirror.conf force=yes
		replace-value-conf -n reg_path -v "$2" -f $ABA_PATH/mirror/mirror.conf
		shift 2
	elif [ "$1" = "--base-domain" -o "$1" = "-b" ]; then
		[[ "$2" =~ ^- || -z "$2" ]] && echo_red "Error: Missing argument after option $1" >&2 && exit 1
		#domain=$(echo "$2" | grep -Eo '([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}')
		[[ $2 =~ ([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}$ ]] && domain=${BASH_REMATCH[0]}  # no need for grep
		[ ! "$domain" ] && echo_red "Error: Domain format incorrect [$2]" >&2 && exit 1
		replace-value-conf -n domain -v "$domain" -f $WORK_DIR/cluster.conf $ABA_PATH/aba.conf
		shift 2
	elif [ "$1" = "--machine-network" -o "$1" = "-M" ]; then
		[[ "$2" =~ ^- || -z "$2" ]] && echo_red "Error: Missing argument after option $1" >&2 && exit 1
		if echo "$2" | grep -q -E '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$'; then
			replace-value-conf -n machine_network -v "$2" -f $WORK_DIR/cluster.conf $ABA_PATH/aba.conf
		else
			echo_red "Error: Invalid CIDR [$2]" >&2
			exit 1
		fi
		shift 2
	elif [ "$1" = "--dns" -o "$1" = "-N" ]; then
		# If arg missing remove from aba.conf
		dns_ips=""
		##while [ "$2" ] && ! echo "$2" | grep -q -e "^-"; do
		while [[ -n $2 && $2 != -* ]]; do  # no need for grep
			# Skip invalid values (ip)
			if echo "$2" | grep -q -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
				[ "$dns_ips" ] && dns_ips="$dns_ips,$2" || dns_ips="$2"
			else
				echo_red "Skipping invalid IP address [$2]" >&2
			fi
			shift
		done
		replace-value-conf -n dns_servers -v "$dns_ips" -f $WORK_DIR/cluster.conf $ABA_PATH/aba.conf
		shift 
	elif [ "$1" = "--ntp" -o "$1" = "-T" ]; then
		# If arg missing remove from aba.conf
		# Check arg after --ntp, if "empty" then remove value from aba.conf, otherwise add valid ip addr
		ntp_vals=""
		# While there is a valid arg...
		#while [ "$2" ] && ! echo "$2" | grep -q -e "^-"
		while [[ -n $2 && $2 != -* ]]; do  # no need for grep
			[ "$ntp_vals" ] && ntp_vals="$ntp_vals,$2" || ntp_vals="$2"
			shift	
		done
		replace-value-conf -n ntp_servers -v "$ntp_vals" -f $WORK_DIR/cluster.conf $ABA_PATH/aba.conf
		shift 
	elif [ "$1" = "--default-route" -o "$1" = "-R" ]; then
		# If arg missing remove from aba.conf
		shift 
		def_route_ip=
		if [[ -n $1 && $1 != -* && $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
			def_route_ip=$1
		fi
	#	if [ "$1" ] && ! echo "$1" | grep -q "^-"; then
	#		def_route_ip=$(echo $1 | grep -Eo '^([0-9]{1,3}\.){3}[0-9]{1,3}$')
	#	fi
		replace-value-conf -n next_hop_address -v "$def_route_ip" -f $WORK_DIR/cluster.conf $ABA_PATH/aba.conf
		shift 
	elif [ "$1" = "--api-vip" -o "$1" = "-XXXXXX" ]; then # FIXME: opt?
		# If arg ip addr then replace value in cluster.conf
		# If arg missing remove from cluster.conf
		api_vip=
		# If arg is available and not an opt
		if [[ -n $2 && $2 != -* ]]; then
			if [[ $2 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
				IFS=. read -r o1 o2 o3 o4 <<< "$2"
				if (( o1 <= 255 && o2 <= 255 && o3 <= 255 && o4 <= 255 )); then
					api_vip=$2
				else
					echo_red "Invalid IPv4 address [$2]" >&2
					exit 1
				fi
			else
				echo_red "Argument invalid [$2] after option: $1" >&2
				exit 1
			fi
			shift
		fi

		# If conf file is available, edit the value
		if [ -f cluster.conf ]; then
			replace-value-conf -n api_vip -v "$api_vip" -f cluster.conf
		else
			BUILD_COMMAND="$BUILD_COMMAND api_vip=$api_vip"
		fi
		shift
	elif [ "$1" = "--ingress-vip" -o "$1" = "-YYYYY" ]; then # FIXME: opt?
		# If arg ip addr replace value in cluster.conf
		# If arg missing remove from cluster.conf
		ingress_vip=
		# If arg is available and not an opt
		##if [ "$2" ] && ! echo "$2" | grep -q "^-"; then
		if [[ -n $2 && $2 != -* ]]; then
			# If arg is an ip addr
			if [[ $2 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
				IFS=. read -r o1 o2 o3 o4 <<< "$2"
				if (( o1 <= 255 && o2 <= 255 && o3 <= 255 && o4 <= 255 )); then
					ingress_vip=$2
				else
					echo_red "Invalid IPv4 address [$2]" >&2
					exit 1
				fi
			else
				echo_red "Argument invalid [$2] after option: $1" >&2
				exit 1
			fi
			shift
		fi
		# If conf file is available, edit the value
		if [ -f cluster.conf ]; then
			replace-value-conf -n ingress_vip -v "$ingress_vip" -f cluster.conf
			##echo done $*
		else
			BUILD_COMMAND="$BUILD_COMMAND ingress_vip=$ingress_vip"
		fi
		shift
	elif [ "$1" = "--ports" -o "$1" = "-PP" ]; then #FIXME: opt name?
		# If arg missing remove from aba.conf
		# Check arg after --ports, if "empty" then remove value from cluster.conf
		ports_vals=""
		# While there is a valid arg...
		while [ "$2" ] && ! echo "$2" | grep -q -e "^-"
		do
			[ "$ports_vals" ] && ports_vals="$ports_vals,$2" || ports_vals="$2"
			shift	
		done
		BUILD_COMMAND="$BUILD_COMMAND ports='$ports_vals'"
		shift 
	elif [ "$1" = "--platform" -o "$1" = "-p" ]; then
		[[ "$2" =~ ^- || -z "$2" ]] && echo_red "Error: Missing argument after option $1" >&2 && exit 1
		replace-value-conf -n platform -v "$2" -f $ABA_PATH/aba.conf
		shift 2
	elif [ "$1" = "--op-sets" -o "$1" = "-P" ]; then
		# If no arg after --op-sets
		if [[ "$2" =~ ^- || -z "$2" ]]; then
			# Remove value
			replace-value-conf -n op_sets -v -f $ABA_PATH/aba.conf
			shift
		else
			shift
			# Step through non-opt params, check the set exists and add to the list ...
			#while [ "$1" ] && ! echo "$1" | grep -q -e "^-"
			while [[ -n "$1" && "$1" != -* ]]; do
				if [ -s "$ABA_PATH/templates/operator-set-$1" -o "$1" = "all" ]; then
					[ "$op_set_list" ] && op_set_list="$op_set_list,$1" || op_set_list=$1
				else
					echo_red "No such operator set: $1" >&2
					echo_white -n "Available operator sets are: " >&2
					ls templates/operator-set-* -1| cut -d- -f3| tr "\n" " " >&2
					echo_white "(as defined in files: aba/templates/operator-sets-*)" >&2

					exit 1
				fi
				shift
			done
			replace-value-conf -n op_sets -v $op_set_list -f $ABA_PATH/aba.conf
		fi
	elif [ "$1" = "--ops" -o "$1" = "-O" ]; then
		if [[ "$2" =~ ^- || -z "$2" ]]; then
			# Remove value
			replace-value-conf -n ops -v  -f $ABA_PATH/aba.conf
			shift
		else
			shift
			while [[ -n "$1" && "$1" != -* ]]; do ops_list="$ops_list $1"; shift; done
			ops_list=$(echo $ops_list | xargs | tr -s " " | tr " " ",")  # Trim white space and add ','
			replace-value-conf -n ops -v $ops_list -f $ABA_PATH/aba.conf
		fi
	elif [ "$1" = "--incl-platform" ]; then  # FIXME: Only have "--excl-platform" option and add true or false (remove: --incl-platform ??)
		replace-value-conf -n excl_platform -v "false" -f $ABA_PATH/aba.conf
		shift
	elif [ "$1" = "--excl-platform" ]; then
		replace-value-conf -n excl_platform -v "true" -f $ABA_PATH/aba.conf
		shift
	elif [ "$1" = "--editor" -o "$1" = "-e" ]; then
		[[ "$2" =~ ^- || -z "$2" ]] && echo_red "Error: Missing argument after option $1" >&2 && exit 1
		editor="$2"
		replace-value-conf -n editor -v $editor -f $ABA_PATH/aba.conf
		shift 2
	elif [ "$1" = "--pull-secret" -o "$1" = "-S" ]; then
		[[ "$2" =~ ^- || -z "$2" ]] && echo_red "Error: Missing argument after option $1" >&2 && exit 1
		replace-value-conf -n pull_secret_file -v "$2" -f $ABA_PATH/aba.conf
		shift 2
	elif [ "$1" = "--vmware" -o "$1" = "--vmw" -o "$1" = "-V" ]; then
		[[ "$2" =~ ^- || -z "$2" ]] && echo_red "Error: Missing argument after option $1" >&2 && exit 1
		[ -s $1 ] && cp "$2" vmware.conf
		shift 2
	elif [ "$1" = "-y" -o "$1" = "--yes" ]; then  # One off, accept the default answer to all prompts for this invocation
		export ASK_OVERRIDE=1  # For this invocation only, -y will overwide ask=true in aba.conf
		shift 
	elif [ "$1" = "-Y" ]; then  # One off, accept the default answer to all prompts for this invocation
		export ASK_OVERRIDE=1  
		replace-value-conf -n ask -v false -f $ABA_PATH/aba.conf  # And make permanent change
		shift 
	elif [ "$1" = "--ask" -o "$1" = "-a" ]; then
		replace-value-conf -n ask -v true -f $ABA_PATH/aba.conf
		shift 
	elif [ "$1" = "--noask" -o "$1" = "-A" ]; then  # FIXME: make -y work only for a single command execution (not write into file)
		replace-value-conf -n ask -v false -f $ABA_PATH/aba.conf
		shift 
	elif [ "$1" = "--mcpu" -o "$1" = "--master-cpu" ]; then  # FIXME opt.
		[[ "$2" =~ ^- || -z "$2" ]] && echo_red "Error: Missing argument after option $1" >&2 && exit 1
		if echo "$2" | grep -q -E '^[0-9]+$'; then
			if [ -f cluster.conf ]; then
				replace-value-conf -n master_cpu -v $2 -f cluster.conf
			else
				BUILD_COMMAND="$BUILD_COMMAND master_cpu_count=$2"
			fi
		else
			echo_red "Argument invalid [$2] after option $1" >&2
		fi
		shift 2
	elif [ "$1" = "--mmem" -o "$1" = "--master-memory" ]; then  # FIXME opt.
		[[ "$2" =~ ^- || -z "$2" ]] && echo_red "Error: Missing argument after option $1" >&2 && exit 1
		if echo "$2" | grep -q -E '^[0-9]+$'; then
			if [ -f cluster.conf ]; then
				replace-value-conf -n master_mem -v $2 -f cluster.conf
			else
				BUILD_COMMAND="$BUILD_COMMAND master_mem=$2"
			fi
		else
			echo_red "Argument invalid [$2] after option $1" >&2
		fi
		shift 2
	elif [ "$1" = "--wcpu" -o "$1" = "--worker-cpu" ]; then  # FIXME opt.
		[[ "$2" =~ ^- || -z "$2" ]] && echo_red "Error: Missing argument after option $1" >&2 && exit 1
		if echo "$2" | grep -q -E '^[0-9]+$'; then
			if [ -f cluster.conf ]; then
				replace-value-conf -n worker_cpu -v $2 -f cluster.conf
			else
				BUILD_COMMAND="$BUILD_COMMAND worker_cpu_count=$2"
			fi
		else
			echo_red "Argument invalid [$2] after option $1" >&2
		fi
		shift 2
	elif [ "$1" = "--wmem" -o "$1" = "--worker-memory" ]; then  # FIXME opt.
		[[ "$2" =~ ^- || -z "$2" ]] && echo_red "Error: Missing argument after option $1" >&2 && exit 1
		if echo "$2" | grep -q -E '^[0-9]+$'; then
			if [ -f cluster.conf ]; then
				replace-value-conf -n worker_mem -v $2 -f cluster.conf
			else
				BUILD_COMMAND="$BUILD_COMMAND worker_mem=$2"
			fi
		else
			echo_red "Argument invalid [$2] after option $1" >&2
		fi
		shift 2
	elif [ "$1" = "--starting-ip" -o "$1" = "-i" ]; then
		[[ "$2" =~ ^- || -z "$2" ]] && echo_red "Error: Missing argument after option $1" >&2 && exit 1
		if echo "$2" | grep -q -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
			BUILD_COMMAND="$BUILD_COMMAND starting_ip='$2'"  # FIXME: This is confusing and prone to error
		else
			echo_red "Argument invalid [$2] after option $1" >&2
		fi
		shift 2
	elif [ "$1" = "--data-disk" -o "$1" = "-dd" ]; then
		if echo "$2" | grep -q -E '^[0-9]+$'; then
			if [ -f cluster.conf ]; then
				replace-value-conf -n data_disk -v $2 -f cluster.conf
			else
				BUILD_COMMAND="$BUILD_COMMAND data_disk=$2"
			fi
		else
			echo_red "Argument invalid [$2] after option $1" >&2
		fi
		shift 2
	elif [ "$1" = "--int-connection" -o "$1" = "-I" ]; then
		# If arg ip addr replace value in cluster.conf
		# If arg missing remove from cluster.conf
		int_connection=
		# If arg is available and not an opt
		if [ "$2" ] && ! echo "$2" | grep -q "^-"; then
			# If arg is an ip addr
			if echo "$2" | grep -q -E '^(proxy|p|direct|d)$'; then
				int_connection=$2
				[ "$2" = "p" ] && int_connection=proxy
				[ "$2" = "d" ] && int_connection=direct
			else
				echo_red "Argument invalid [$int_connection] after option: $1" >&2
				exit 1
			fi
			shift
		else
			# Do nothing, remove value in cluster.conf
			:
		fi
		# If conf file is available, edit the value
		if [ -f cluster.conf ]; then
			replace-value-conf -n int_connection -v "$int_connection" -f cluster.conf
			##echo done $*
		else
			BUILD_COMMAND="$BUILD_COMMAND int_connection=$int_connection"
		fi
		shift
	elif [ "$1" = "--name" -o "$1" = "-n" ]; then
		[[ "$2" =~ ^- || -z "$2" ]] && echo_red "Error: Missing argument after option $1" >&2 && exit 1
		if [ "$cur_target" = "cluster" ]; then
			BUILD_COMMAND="$BUILD_COMMAND name='$2'"  # FIXME: This is confusing and prone to error
		else
			echo_red "Can only use option $1 after target 'cluster'.  See aba cluster -h" >&2

			exit 1
		fi

		shift 2
	elif [ "$1" = "--type" -o "$1" = "-t" ]; then
		[[ "$2" =~ ^- || -z "$2" ]] && echo_red "Error: Missing argument after option $1" >&2 && exit 1
		# If there's another arg and it's an expected cluster type, accept it, otherwise error.
		if echo "$2" | grep -qE "^sno$|^compact$|^standard$"; then
			if [ "$cur_target" = "cluster" ]; then
				BUILD_COMMAND="$BUILD_COMMAND type='$2'"
				shift 2
			else
				echo_red "Can only use option $1 after target 'cluster'.  See aba cluster -h" >&2
				exit 1
			fi
		else
			echo_red "Error: Missing or incorrect argument (sno|compact|standard) after option $1" >&2
			exit 1
		fi
	elif [ "$1" = "--step" -o "$1" = "-s" ]; then
		[[ "$2" =~ ^- || -z "$2" ]] && echo_red "Error: Missing argument after option $1" >&2 && exit 1
		# If there's another arg and it's NOT an option (^-) then accept it, otherwise error
		BUILD_COMMAND="$BUILD_COMMAND target='$2'"  # FIXME: Also confusing, similar to --name
		shift 2
	elif [ "$1" = "--retry" -o "$1" = "-r" ]; then
		# If there's another arg and it's a number then accept it
		if [ "$2" ] && echo "$2" | grep -qE "^[0-9]+$"; then
			BUILD_COMMAND="$BUILD_COMMAND retry='$2'"
			[ "$DEBUG_ABA" ] && echo $0: Adding retry=$2 to BUILD_COMMAND >&2
			shift 2
		# In all other cases, use '3' 
		else
			BUILD_COMMAND="$BUILD_COMMAND retry=2"  # FIXME: Also confusing, similar to --name
			[ "$DEBUG_ABA" ] && echo $0: Setting $1 to 3 >&2
			shift
		fi
	elif [ "$1" = "--force" -o "$1" = "-f" ]; then
		shift
		BUILD_COMMAND="$BUILD_COMMAND force=1"  # FIXME: Should only allow force=1 after the appropriate target
	elif [ "$1" = "--wait" -o "$1" = "-w" ]; then
		shift
		BUILD_COMMAND="$BUILD_COMMAND wait=1"  #FIXME: Should only allow this after the appropriate target
	elif [ "$1" = "--workers" ]; then
		BUILD_COMMAND="$BUILD_COMMAND workers=1"
		shift
	elif [ "$1" = "--masters" ]; then
		BUILD_COMMAND="$BUILD_COMMAND masters=1"
		shift
	elif [ "$1" = "--cmd" ]; then
		# Note, -c is used for --channel
		cmd=
		shift 
		echo "$1" | grep -q "^-" || cmd="$1"
		[ "$cmd" ] && shift || cmd="get co" # Set default command here

		if [[ "$BUILD_COMMAND" =~ "ssh" ]]; then
			BUILD_COMMAND="$BUILD_COMMAND cmd='$cmd'"
			[ "$DEBUG_ABA" ] && echo $0: BUILD_COMMAND=$BUILD_COMMAND >&2
		elif [[ "$BUILD_COMMAND" =~ "cmd" ]]; then
			BUILD_COMMAND="$BUILD_COMMAND cmd='$cmd'"
			[ "$DEBUG_ABA" ] && echo $0: BUILD_COMMAND=$BUILD_COMMAND >&2
		else
			# Assume it's a kube command by default
			BUILD_COMMAND="$BUILD_COMMAND cmd cmd='$cmd'"
			[ "$DEBUG_ABA" ] && echo $0: BUILD_COMMAND=$BUILD_COMMAND >&2
		fi
	else
		if echo "$1" | grep -q "^-"; then
			echo_red "$(basename $0): Error: no such option $1" >&2
			exit 1
		else
			#if [ "$1" = "cluster" ]; then
			#	cur_target=$1
			#	# Do not append "cluster" to $BUILD_COMMAND
			#else
				# Assume any other args are "commands", e.g. 'cluster', 'verify', 'mirror', 'ssh', 'cmd' etc 
				# Gather options and args not recognized above and pass them to "make"... yes, we're using make! 
			cur_target=$1
			BUILD_COMMAND="$BUILD_COMMAND $1"
			[ "$DEBUG_ABA" ] && echo $0: Command added: BUILD_COMMAND=$BUILD_COMMAND >&2
		fi
		shift 
	fi

	[ "$DEBUG_ABA" ] && echo "$0: BUILD_COMMAND=$BUILD_COMMAND" >&2
done

[ "$DEBUG_ABA" ] && echo DEBUG: $0: interactive_mode=[$interactive_mode] >&2

# Sanitize $BUILD_COMMAND
BUILD_COMMAND=$(echo "$BUILD_COMMAND" | tr -s " " | sed -E -e "s/^ //g" -e "s/ $//g")

[ "$DEBUG_ABA" ] &&  echo "$0: ABA_PATH=[$ABA_PATH]" >&2
[ "$DEBUG_ABA" ] &&  echo "$0: BUILD_COMMAND=[$BUILD_COMMAND]" >&2

# We want interactive mode if aba is running at the top of the repo and without any args
[ ! "$BUILD_COMMAND" -a "$ABA_PATH" = "." ] && interactive_mode=1

#if [ ! "$interactive_mode" -a -z "$interactive_mode_none" ]; then
if [ ! "$interactive_mode" ]; then
	[ "$DEBUG_ABA" ] && echo "DEBUG: $0: Running: \"make $BUILD_COMMAND\" from dir $PWD" >&2

	# eval is needed here since $BUILD_COMMAND should not be evaluated/processed (it may have ' or " in it)
	[ "$DEBUG_ABA" ] && eval make $BUILD_COMMAND || eval make -s $BUILD_COMMAND

	exit 
fi

##################################################################
# We don't want interactive mode if there were args in the command
#[ "$interactive_mode_none" ] && echo Exiting ... >&2 && exit 
[ "$interactive_mode_none" ]                          && exit 

# Change to the top level repo directory
cd $ABA_PATH


# ###########################################
# From now on it's all considered INTERACTIVE

# If in interactive mode then ensure all prompts are active!
### replace-value-conf aba.conf ask true   # Do not make this permanent!
source <(normalize-aba-conf)
export ask=1

#verify-aba-conf || exit 1  # Can't verify here 'cos aba.conf likely has no ocp_version or channel defined

cat others/message.txt

##############################################################################################################################
# Determine if this is an "aba bundle" or just a clone from GitHub

if [ ! -f .bundle ]; then
	# Fresh GitHub clone of Aba repo detected!

	##############################################################################################################################
	# Determine OCP channel

	[ "$ocp_channel" = "eus" ] && ocp_channel=stable  # btw .../ocp/eus/release.txt does not exist!

	if [ "$ocp_channel" ]; then
		echo_cyan "OpenShift update channel is defined in aba.conf as '$ocp_channel'."
	else

		echo_white -n "Checking Internet connectivity ..."
		if ! release_text=$(curl -f --connect-timeout 20 --retry 3 -sSL https://mirror.openshift.com/pub/openshift-v4/$arch_sys/clients/ocp/stable/release.txt); then
			[ "$TERM" ] && tput el1 && tput cr
			echo_red "Cannot access https://mirror.openshift.com/.  Ensure you have Internet access to download the required images." >&2
			echo_red "To get started with Aba run it on a connected workstation/laptop with Fedora, RHEL or Centos Stream and try again." >&2

			exit 1
		fi

		[ "$TERM" ] && tput el1 && tput cr

		echo_cyan -n "Which OpenShift update channel do you want to use? (f)ast, (s)table, or (c)andidate) [s]: "
		read ans
		[ ! "$ans" ] && ocp_channel=stable
		[ "$ans" = "f" ] && ocp_channel=fast
		[ "$ans" = "s" ] && ocp_channel=stable
		#[ "$ans" = "e" ] && ocp_channel=eus
		[ "$ans" = "c" ] && ocp_channel=candidate

		replace-value-conf -n ocp_channel -v $ocp_channel -f aba.conf
		echo_cyan "'ocp_channel' set to '$ocp_channel' in aba.conf"

		chan=$ocp_channel # Used below
	fi

	sleep 0.3

	##############################################################################################################################
	# Determine OCP version 

	if [ "$ocp_version" ]; then
		echo_cyan "OpenShift version is defined in aba.conf as '$ocp_version'."
	else
		##############################################################################################################################
		# Fetch release.txt

		echo_white -n "Fetching available versions ..."

		if ! release_text=$(curl -f --connect-timeout 30 --retry 3 -sSL https://mirror.openshift.com/pub/openshift-v4/$arch_sys/clients/ocp/$ocp_channel/release.txt); then
			[ "$TERM" ] && tput el1 && tput cr
			echo_red "Failed to access https://mirror.openshift.com" >&2

			exit 1
		fi

		## Get the latest stable OCP version number, e.g. 4.14.6
		channel_ver=$(echo "$release_text" | grep -E -o "Version: +[0-9]+\.[0-9]+\.[0-9]+" | awk '{print $2}')
		default_ver=$channel_ver

		# Extract the previous stable point version, e.g. 4.13.23
		major_ver=$(echo $channel_ver | grep ^[0-9] | cut -d\. -f1)
		channel_ver_point=`expr $(echo $channel_ver | grep ^[0-9] | cut -d\. -f2) - 1`
		[ "$channel_ver_point" ] && \
			channel_ver_prev=$(oc-mirror list releases --channel=${chan}-${major_ver}.${channel_ver_point} 2>/dev/null | tail -1)  # better way to fetch newest previous version!

		# Determine any already installed tool versions
		which openshift-install >/dev/null 2>&1 && cur_ver=$(openshift-install version | grep ^openshift-install | grep -E -o "[0-9]+\.[0-9]+\.[0-9]+")

		# If openshift-install is already installed, then offer that version also
		[ "$cur_ver" ] && or_ret="or [current version] " && default_ver=$cur_ver

		[ "$TERM" ] && tput el1 && tput cr

		echo "Which version of OpenShift do you want to install?"

		target_ver=
		while true
		do
			# Exit loop if release version exists
			if [ "$target_ver" ]; then
				if echo "$target_ver" | grep -E -q "^[0-9]+\.[0-9]+\.[0-9]+$"; then
					url="https://mirror.openshift.com/pub/openshift-v4/$arch_sys/clients/ocp/$target_ver/release.txt"
					if curl -f --connect-timeout 60 --retry 3 -sSL -o /dev/null -w "%{http_code}\n" $url| grep -q ^200$; then
						break
					else
						echo_red "Error: Failed to fetch release.txt file from $url" >&2
					fi
				else
					echo_red "Invalid input. Enter a valid OpenShift version (e.g., 4.18.10 or 4.17)." >&2
				fi
			fi

			[ "$channel_ver" ] && or_s="or $channel_ver (l)atest "
			[ "$channel_ver_prev" ] && or_p="or $channel_ver_prev (p)revious "

			echo_cyan -n "Enter x.y.z or x.y version $or_s$or_p$or_ret(<version>/l/p/Enter) [$default_ver]: "

			read target_ver

			[ ! "$target_ver" ] && target_ver=$default_ver          # use default
			[ "$target_ver" = "l" -a "$channel_ver" ] && target_ver=$channel_ver       # latest
			[ "$target_ver" = "p" -a "$channel_ver_prev" ] && target_ver=$channel_ver_prev  # previous latest

			# If user enters just a point version, x.y, fetch the latest .z value for that point version of OCP
			echo $target_ver | grep -E -q "^[0-9]+\.[0-9]+$" && target_ver=$(fetch_latest_z_version "$chan" "$target_ver" "$arch_sys")
		done

		# Update the conf file
		#sed -i "s/ocp_version=[^ \t]*/ocp_version=$target_ver /g" aba.conf
		replace-value-conf -n ocp_version -v $target_ver -f aba.conf
		echo_cyan "'ocp_version' set to '$target_ver' in aba.conf"

		sleep 0.3
	fi

	sleep 0.3

	# Just in case, check the target ocp version in aba.conf matches any existing versions defined in oc-mirror imageset config files. 
	# FIXME: Any better way to do this?! .. or just keep this check in 'aba -d mirror sync' and 'aba -d mirror save' (i.e. before we d/l the images
	(
		install_rpms make || exit 1
		make -s -C mirror checkversion 
	) || exit 

	##############################################################################################################################
	source <(normalize-aba-conf)
	verify-aba-conf || exit 1

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

		##sed -E -i -e 's/^editor=[^ \t]+/editor=/g' -e "s/^editor=([[:space:]]+)/editor=$new_editor\1/g" aba.conf
		replace-value-conf -n editor -v "$new_editor" -f aba.conf
		export editor=$new_editor
		echo_cyan "'editor' set to '$new_editor' in aba.conf"

		sleep 0.3
	fi

	##############################################################################################################################
	# Allow edit of aba.conf

	if [ ! -f .aba.conf.seen ]; then
		if edit_file aba.conf "Edit aba.conf to set global values, e.g. platform, pull secret, default base domain & net address, dns & ntp etc (if known)"; then
			# If edited/seen, no need to ask again.
			touch .aba.conf.seen
		fi
	fi

	# make & jq are needed below and in the next steps 
	scripts/install-rpms.sh external 

	# Now we have the required ocp version, we can fetch the operator indexes (in the background to save time).
	( make -s catalog bg=true & ) & 

	##############################################################################################################################
	# Determine pull secret

	if grep -qi "registry.redhat.io" $pull_secret_file 2>/dev/null; then
		if jq empty $pull_secret_file; then
			[ "$INFO_ABA" ] && echo_cyan "Pull secret found at '$pull_secret_file'."

			# Now we have the required ocp version, we can fetch the operator index in the background (to save time).
			#### FIXME ( make -s -C mirror catalog bg=true & ) & 

			sleep 0.3
		else
			echo
			echo_red "Error: Pull secret file sytax error: $pull_secret_file!" >&2
			echo

			exit 1
		fi
	else
		echo
		echo_red "Error: No Red Hat pull secret file found at '$pull_secret_file'!" >&2
		echo_white "To allow access to the Red Hat image registry, download your Red Hat pull secret and store it in the file '$pull_secret_file' and try again!" >&2
		echo_white "Get your pull secret from: https://console.redhat.com/openshift/downloads#tool-pull-secret (select 'Tokens' in the pull-down)" >&2
		echo_white "Note that, if needed, the location of your pull secret file can be changed in 'aba.conf'." >&2
		echo

		exit 1
	fi

	##############################################################################################################################
	# Determine air-gapped

	echo
	echo       "Fully Disconnected (air-gapped)"
	echo_white "If you plan to install OpenShift in a fully disconnected (air-gapped) environment, Aba can download all required components—including"
	echo_white "the Quay mirror registry install file, container images, and CLI install files—and package them into an install bundle that you can"
	echo_white "transfer into your disconnected environment."
	#echo_white "If you intend to install OpenShift into a fully disconnected (i.e. air-gapped) environment, Aba can download all required software"
	#echo_white "(Quay mirror registry install file, container images and CLI install files) and create a 'install bundle' for you to transfer into your disconnected environment."
	if ask "Install OpenShift into a fully disconnected network environment"; then
		echo
		echo_yellow Instructions for a fully disconnected installation
		echo
		echo "Run: aba bundle --out /path/to/portable/media             # to save all images to local disk & then create the install bundle"
		echo "                                                          # (size ~20-30GB for a base installation)."
		echo "     aba bundle --out - | ssh user@remote -- tar xvf -    # Stream the archive to a remote host and unpack it there."
		echo "     aba bundle --out - | split -b 10G - ocp_             # Stream the archive and split it into several, more manageable files."
		echo "                                                          # Unpack the files on the internal bastion with: cat ocp_* | tar xvf - "
		echo

		exit 0
	fi
	
	##############################################################################################################################
	# Determine online installation (e.g. via a proxy/NAT)

	echo
	echo "Partially Disconnected"
	echo_white "A mirror registry can be synchronized directly from the Internet, allowing OpenShift to be installed from the mirrored content."
	if ask "Install OpenShift from a mirror registry that is synchonized directly from the Internet"; then

		echo 
		echo_yellow Instructions for synchronizing images directly to a mirror registry
		echo 
		echo "Action required: Set up the mirror registry and sync it with the necessary container images."
		echo
		echo "To store container images, Aba can install the Quay mirror appliance or you can use an existing container registry."
		echo
		echo "Run:"
		echo "  aba -d mirror install              # to configure and/or install Quay."
		echo "  aba -d mirror sync --retry <count> # to synchronize all container images - from the Internet - into your registry."
		echo
		echo "Or run:"
		echo "  aba -d mirror sync --retry <count> # to complete both actions and ensure any image synchronization issues are retried."
		echo

		echo "Once the images are stored in the mirror registry, you can proceed with the OpenShift installation by following the instructions provided."
		echo

		exit 0
	fi

	echo 
	echo_yellow Instructions for installing from the Internet
	echo
	echo_white "Configure the installation to use a proxy or NAT (optional)."
	echo
	echo_white "Run: aba cluster --name myclustername [--type <sno|compact|standard>] [--step <command>] [--starting-ip <ip>] [--api-vip <ip>] [--ingress-vip <ip>] [--int-connection <proxy|direct>]"
	echo_white "See aba cluster -help for more"
	echo 

else
	# aba is running on the internal bastion, in 'bundle mode'.

	# make & jq are needed below and in the next steps. Best to install all at once.
	scripts/install-rpms.sh internal

	echo
	echo_yellow "Aba bundle detected! This aba bundle is ready to install OpenShift version '$ocp_version' in your disconnected environment!"
	
	# Check if tar files are already in place
	if [ ! "$(ls mirror/save/mirror_*tar 2>/dev/null)" ]; then
		echo
		echo_magenta "IMPORTANT: The image set tar files (created in the previous step with 'aba bundle' or 'aba -d mirror save') MUST BE" >&2
		echo_magenta "           copied or moved to the 'aba/mirror/save' directory before following the instructions below!" >&2
		echo_magenta "           For example, run the command: cp /path/to/portable/media/mirror_*tar aba/mirror/save" >&2
	fi

	echo 
	echo_yellow Instructions
	echo 
	echo_magenta "IMPORTANT: Check the values in aba.conf and ensure they are all complete and match your disconnected environment."

	echo_white "Current values in aba.conf:"
	to_output=$(normalize-aba-conf | sed -e "s/^export //g" -e "/^pull_secret_file=.*/d")  # In disco env, no need to show pull-secret.
	output_table 3 "$to_output"

	echo
	echo "Set up the mirror registry and load it with the necessary container images from disk."
	echo
	echo "To store container images, Aba can install the Quay mirror appliance or you can use an existing container registry."
	echo
	echo "To install the registry on the local machine, accessible via registry.example.com, run:"
	echo "  aba -d mirror load -H registry.example.com --retry 8"
	echo
	echo "To install the registry on a remote host, specify the SSH key (and optionally the remote user) to access the host, run:"
	echo "  aba -d mirror load -H registry.example.com -k '~/.ssh/id_rsa' -U user --retry"
	echo
	echo "If unsure, run:"
	echo "  aba -d mirror install                 # to configure and/or install Quay."
	echo
	echo "Once the mirror registry is installed/configured, verify authentication with:"
	echo "  aba -d mirror verify"
	echo
	echo "For more, run: aba load --help"
fi


