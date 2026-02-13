#!/bin/bash
# Start here, run this script to get going!

# Semantic version (updated by build/release.sh at release time)
ABA_VERSION=0.9.3

# Build timestamp (updated by build/pre-commit-checks.sh)
ABA_BUILD=20260208234722

# Sanity check build timestamp
# FIXME: Can only use 'echo' here since can't locate the include_all.sh file yet
echo -n $ABA_BUILD | grep -qE "^[0-9]{14}$" || { echo "ABA_BUILD in $0 is incorrect [$ABA_BUILD]! Fix the format to YYYYMMDDhhmmss and try again!" >&2 && exit 1; }

ARCH=$(uname -m)
[ "$ARCH" = "aarch64" ] && export ARCH=arm64  # ARM
[ "$ARCH" = "x86_64" ] && export ARCH=amd64   # Intel

uname -o | grep -q "^Darwin$" && echo "Run aba on RHEL, Fedora or even in a Centos-Stream container. Most tested is RHEL 9 (no oc-mirror for Mac OS!)." >&2 && exit 1

# Handle --aba-version early (before sudo check)
if [ "$1" = "--aba-version" ]; then
	echo "aba version $ABA_VERSION (build $ABA_BUILD)"
	git_branch=$(git branch --show-current 2>/dev/null)
	git_commit=$(git rev-parse --short HEAD 2>/dev/null)
	[ "$git_branch" -a "$git_commit" ] && echo "Git: $git_branch @ $git_commit"
	exit 0
fi

SUDO=
which sudo 2>/dev/null >&2 && SUDO=sudo

# Check we have sudo or root access 
[ "$SUDO" ] && [ "$(sudo id -run)" != "root" ] && echo "Configure passwordless sudo OR run aba as root, then try again!" >&2 && exit 1

WORK_DIR=$PWD # Remember so can change config file here 


# Pre-process ALL arguments to extract --dir/-d (first only) and --debug/-D (anywhere)
# This scans through all arguments and filters out these special options
new_args=()           # Array to collect arguments we want to keep
dir_already_set=false # Only process first --dir/-d
i=1

while [ $i -le $# ]; do
	arg="${!i}"  # Get the i-th argument (indirect expansion: if i=1, get $1)

	case "$arg" in
		--dir|-d)
			if [ "$dir_already_set" = false ]; then
				dir_already_set=true
				i=$((i + 1))  # Move to next arg (the directory value)
				target_dir="${!i}"

				# Validate directory argument
				[ -z "$target_dir" ] && echo "Error: directory path expected after option $arg" >&2 && exit 1
				target_dir=$(eval echo "$target_dir")  # Expand ~ in path
				[ ! -e "$target_dir" ] && echo "Error: directory $target_dir does not exist!" >&2 && exit 1
				[ ! -d "$target_dir" ] && echo "Error: cannot change to $target_dir: not a directory!" >&2 && exit 1

				[ "$DEBUG_ABA" ] && echo "Changing dir to: $target_dir"

				if ! cd "$target_dir" 2>/dev/null; then
					echo "Error: cannot change to directory $target_dir (permission denied)" >&2
					exit 1
				fi

				WORK_DIR=$PWD # Remember so can change config file here - can override existing value (set above)
			else
				# Skip subsequent --dir/-d and their values
				i=$((i + 1))
			fi
			;;

		--debug|-D)
			export DEBUG_ABA=1
			;;

		*)
			# Keep all other arguments
			new_args+=("$arg")
			;;
	esac

	i=$((i + 1))
done

# Replace $1, $2, etc. with filtered arguments
set -- "${new_args[@]}"

export INFO_ABA=1
export ABA_ROOT
interactive_mode=1


# Check the repo location
# Need to be sure location of the top of the repo in order to find the important files
# FIXME: Place the files (scripts and templates etc) into a well known location, e.g. /opt/aba/...
if [ -s Makefile ] && grep -q "Top level Makefile" Makefile; then
	ABA_ROOT=$PWD
	#ABA_ROOT='.'
	###interactive_mode=1
elif [ -s ../Makefile ] && grep -q "Top level Makefile" ../Makefile; then
	ABA_ROOT=$(realpath "..")
	interactive_mode=
elif [ -s ../../Makefile ] && grep -q "Top level Makefile" ../../Makefile; then
	ABA_ROOT=$(realpath "../..")
	interactive_mode=
elif [ -s ../../../Makefile ] && grep -q "Top level Makefile" ../../../Makefile; then
	ABA_ROOT=$(realpath "../../..")
	interactive_mode=
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

# Do not do this.  CWD must be the user proivided dir
##cd $ABA_ROOT

# install will check if aba needs to be updated, if so it will return 3 ... so we re-execute it!
if [ ! "$ABA_DO_NOT_UPDATE" ]; then
	$ABA_ROOT/install -q   # Only aba iself should use the flag -q
	if [ $? -eq 2 ]; then
		export ABA_DO_NOT_UPDATE=1
		$0 "$@"  # This means aba was updated and needs to be called again
		exit
	fi
fi

source $ABA_ROOT/scripts/include_all.sh
aba_debug "Sourced file $ABA_ROOT/scripts/include_all.sh"
# Note: No automatic cleanup on Ctrl-C. Background tasks continue naturally.
[ ! "$RUN_ONCE_CLEANED" ] && run_once -F # Clean out only the previously failed tasks
export RUN_ONCE_CLEANED=1 # Be sure it's only run once!

aba_debug DEBUG_ABA=$DEBUG_ABA
aba_debug "Starting: $0 $*"
aba_debug "ABA_ROOT=[$ABA_ROOT]"

# This will be the actual 'make' command that will eventually be run
BUILD_COMMAND=

# Init aba.conf
if [ ! -s $ABA_ROOT/aba.conf ]; then
	aba_debug Adding network values to $ABA_ROOT/aba.conf

	# Determine resonable defaults for ...
	export domain=$(get_domain)
	export machine_network=$(get_machine_network)
	export dns_servers=$(get_dns_servers)
	export next_hop_address=$(get_next_hop)
	export ntp_servers=$(get_ntp_servers)

	aba_debug domain:		$domain
	aba_debug machine_network:	$machine_network
	aba_debug dns_servers:		$dns_servers
	aba_debug next_hop_address:	$next_hop_address
	aba_debug ntp_servers:		$ntp_servers

	$ABA_ROOT/scripts/j2 $ABA_ROOT/templates/aba.conf.j2 > $ABA_ROOT/aba.conf
else
	# If the repo has empty network values in aba.conf, add defaults - as now is the best time (on internal network).
	# For pre-created bundles, aba.conf will exist but these values will be empty ... so attempt to fill them in. 
	source <(cd $ABA_ROOT && normalize-aba-conf)
	# Determine resonable defaults for the following ... and add to conf file if value exists ...
	# This will always try to add sensible default values from the local network config. if not already set in the config file.
	[ ! "$domain" ]			&& v=$(get_domain)		&& [ "$v" ] && replace-value-conf -n domain		-v "$v"	-f $ABA_ROOT/aba.conf && aba_debug Add: domain=$domain
	[ ! "$machine_network" ]	&& v=$(get_machine_network) 	&& [ "$v" ] && replace-value-conf -n machine_network	-v "$v"	-f $ABA_ROOT/aba.conf && aba_debug Add: machine_network=$machine_network
	[ ! "$dns_servers" ]		&& v=$(get_dns_servers)		&& [ "$v" ] && replace-value-conf -n dns_servers	-v "$v"	-f $ABA_ROOT/aba.conf && aba_debug Add: dns_servers=$dns_servers
	[ ! "$next_hop_address" ]	&& v=$(get_next_hop)		&& [ "$v" ] && replace-value-conf -n next_hop_address	-v "$v"	-f $ABA_ROOT/aba.conf && aba_debug Add: next_hop_address=$next_hop_address
	[ ! "$ntp_servers" ]		&& v=$(get_ntp_servers) 	&& [ "$v" ] && replace-value-conf -n ntp_servers	-v "$v"	-f $ABA_ROOT/aba.conf && aba_debug Add: ntp_servers=$ntp_servers

	aba_debug domain:		$domain
	aba_debug machine_network:	$machine_network
	aba_debug dns_servers:		$dns_servers
	aba_debug next_hop_address:	$next_hop_address
	aba_debug ntp_servers:		$ntp_servers
fi

# Fetch any existing values (e.e. ocp_channel is used later for '-v')
source <(cd $ABA_ROOT && normalize-aba-conf)

# Interactive mode is used when no args are suplied
[ "$*" ] && interactive_mode= && have_args=1

# For non-interactive mode (aba bundle, aba -d mirror save, etc.):
# Start CLI downloads early to maximize parallel download time
# For interactive mode: Wait until after user input (line ~1152) to avoid
# bandwidth contention that could slow down reaching the user prompts
if [ ! "$interactive_mode" ]; then
	aba_debug "Non-interactive mode detected - starting CLI downloads early"
	$ABA_ROOT/scripts/cli-download-all.sh
fi

cur_target=   # Can be 'cluster', 'mirror', 'save', 'load' etc 

while [ "$*" ] 
do
	aba_debug "Args: [$@]"
	aba_debug "BUILD_COMMAND=[$BUILD_COMMAND]" 

	if [ "$1" = "--help" -o "$1" = "-h" ]; then
		if [ ! "$cur_target" ]; then
			cat $ABA_ROOT/others/help-aba.txt
		elif [ "$cur_target" = "mirror" -o "$cur_target" = "save" -o "$cur_target" = "load" -o "$cur_target" = "sync" ]; then
			cat $ABA_ROOT/others/help-mirror.txt
		elif [ "$cur_target" = "cluster" ]; then
			cat $ABA_ROOT/others/help-cluster.txt
		elif [ "$cur_target" = "bundle" ]; then
			cat $ABA_ROOT/others/help-bundle.txt
		else
			# If some other target, then show the main help
			cat $ABA_ROOT/others/help-aba.txt
		fi

		exit 0
	elif [ "$1" = "--interactive" ]; then
		interactive_mode=1
		# If the user explicitly wants interactive mode, then ensure we make it interactive with "ask=true"
		replace-value-conf -n ask -v true -f $ABA_ROOT/aba.conf
		export ask=1
		shift
	elif [ "$1" = "--quiet" -o "$1" = "-q" ]; then
		export INFO_ABA=
		shift 
	elif [ "$1" = "--info" ]; then
		export INFO_ABA=1
		shift 
	elif [ "$1" = "--debug" -o "$1" = "-D" ]; then
		export DEBUG_ABA=1
	export INFO_ABA=1
	shift 
elif [ "$1" = "--light" ]; then
	export opt_light="--light"  # if "aba bundle", then leave out the image-set archive file(s) from the bundle
	#BUILD_COMMAND="$BUILD_COMMAND light=light"  # FIXME: Should only allow force=1 after the appropriate target
	shift
	elif [ "$1" = "ocp-versions" -o "$1" = "ocp-ver" ]; then
		shift
		echo_yellow "Available OpenShift versions:"
		echo_white  "Latest stable:      $(fetch_latest_version stable)"
		echo_white  "Latest fast:        $(fetch_latest_version fast)"
		echo_white  "Latest candidate:   $(fetch_latest_version candidate)"
		echo
		echo_white  "Previous stable:    $(fetch_previous_version stable)"
		echo_white  "Previous fast:      $(fetch_previous_version fast)"
		echo_white  "Previous candidate: $(fetch_previous_version candidate)"

		which openshift-install >/dev/null 2>&1 && os_inst=$(openshift-install version | grep ^openshift-install | grep -E -o "[0-9]+\.[0-9]+\.[0-9]+")
		[ "$os_inst" ] && \
			echo && \
			echo_white  "openshift-install:  $os_inst"

		exit 0
	elif [ "$1" = "--out" -o "$1" = "-o" ]; then
		shift
		if [ "$1" = "-" ]; then
			BUILD_COMMAND="$BUILD_COMMAND out=-"  # FIXME: This only works if command=bundle
			opt_out="--out -"
		else
			echo "$1" | grep -q "^-" && aba_abort "in parsing --out path argument"
			[ "$1" ] && [ ! -d $(dirname $1) ] && aba_abort "directory: [$(dirname $1)] incorrect or missing!"
			[ -f "$1.tar" ] && aba_abort "install bundle file [$1.tar] already exists!"

			BUILD_COMMAND="$BUILD_COMMAND out='$1'"
			opt_out="--out '$1'"
		fi
		shift
	elif [ "$1" = "--channel" -o "$1" = "-c" ]; then
		opt=$1
		# Be strict if arg missing
		[[ "$2" =~ ^- || -z "$2" ]] && aba_abort "missing argument after option $opt"
		chan=$2  # This $chan var can be used below for "--version"
		# As far as possible, always ensure there is a valid value in aba.conf
		case "$chan" in
			stable | s)	chan=stable ;;
			fast | f)	chan=fast ;;
			eus | e)	chan=eus ;;
			candidate | c)	chan=candidate ;;
			*)
				aba_abort "wrong value [$chan] after option $opt" 
				;;
		esac
		replace-value-conf -n ocp_channel -v $chan -f $ABA_ROOT/aba.conf 
		ocp_channel=$chan
		shift 2
	elif [ "$1" = "--version" -o "$1" = "-v" ]; then
		opt=$1
		# Be strict if arg missing
		[[ "$2" =~ ^- || -z "$2" ]] && aba_abort "missing argument after option $opt"
		arg=$2
		ver=$arg
		[ ! "$chan" ] && chan=$ocp_channel  # Prioritize the $chan var (from above) or fetch from aba.conf file
		tmp_out=
		case "$arg" in
			latest | l)
				tmp_out="latest "
				ver=$(fetch_latest_version "$chan")
			;;
			previous | p)
				tmp_out="previous "
				ver=$(fetch_previous_version "$chan")
			;;
		esac

		# Expand ver to latest, if it's just a point version (x.y)
		echo $ver | grep -q -E "^[0-9]+\.[0-9]+$" && ver=$(fetch_latest_z_version "$ocp_channel" "$ver")

		# Extract only the full major.minor.patch version if present
		ver=$(echo "$ver" | grep -Eo '^[0-9]+\.[0-9]+\.[0-9]+$' || true)

		# As far as possible, always ensure there is a valid value in aba.conf
		[ ! "$ver" ] && aba_abort "failed to look up the$tmp_out version for channel [$chan] after option [$opt $arg]" 

		# ver should now be x.y.z format
		! echo $ver | grep -q -E "^[0-9]+\.[0-9]+\.[0-9]+$" && aba_abort "incorrect version format: [$ver] for channel [$chan] after option [$opt $arg]" 

		replace-value-conf -n ocp_version -v $ver -f $ABA_ROOT/aba.conf

	# Now we have the required ocp version, we can fetch the operator index in the background (to save time).
	aba_debug Downloading operator index for version $ver 

	# Use new helper function for parallel catalog downloads
	ver_short="${ver%.*}"  # Extract major.minor (e.g., 4.20.8 -> 4.20)
	download_all_catalogs "$ver_short" 86400  # 1-day TTL

		shift 2
		ocp_version=$ver
	elif [ "$1" = "--mirror-hostname" -o "$1" = "-H" ]; then
		[[ "$2" =~ ^- || -z "$2" ]] && aba_abort "missing argument after option $1" 
		# force will skip over asking to edit the conf file
		make -sC $ABA_ROOT/mirror mirror.conf force=yes
		replace-value-conf -n reg_host -v "$2" -f $ABA_ROOT/mirror/mirror.conf
		shift 2
	elif [ "$1" = "--reg-ssh-key" -o "$1" = "-k" ]; then
		# The ssh key used to access the linux registry host
		# If no value, remove from mirror.conf
		[[ "$2" =~ ^- || -z "$2" ]] && reg_ssh_key= || { reg_ssh_key=$2; shift; }
		# force will skip over asking to edit the conf file
		make -sC $ABA_ROOT/mirror mirror.conf force=yes
		replace-value-conf -n reg_ssh_key -v "$reg_ssh_key" -f $ABA_ROOT/mirror/mirror.conf
		shift
	elif [ "$1" = "--reg-ssh-user" -o "$1" = "-U" ]; then
		# The ssh username used to access the linux registry host
		# If no value, remove from mirror.conf
		[[ "$2" =~ ^- || -z "$2" ]] && reg_ssh_user_val= || { reg_ssh_user_val=$2; shift; }
		# force will skip over asking to edit the conf file
		make -sC $ABA_ROOT/mirror mirror.conf force=yes
		replace-value-conf -n reg_ssh_user -v "$reg_ssh_user_val" -f $ABA_ROOT/mirror/mirror.conf
		shift
	elif [ "$1" = "--data-dir" ]; then
		[[ "$2" =~ ^- || -z "$2" ]] && aba_abort "missing argument after option $1"
		# force will skip over asking to edit the conf file
		make -sC $ABA_ROOT/mirror mirror.conf force=yes
		replace-value-conf -n data_dir -v "$2" -f $ABA_ROOT/mirror/mirror.conf
		shift 2
	elif [ "$1" = "--reg-user" ]; then
		# The username used to access the mirror registry 
		[[ "$2" =~ ^- || -z "$2" ]] && aba_abort "missing argument after option $1" 
		# force will skip over asking to edit the conf file
		make -sC $ABA_ROOT/mirror mirror.conf force=yes
		replace-value-conf -n reg_user -v "$2" -f $ABA_ROOT/mirror/mirror.conf
		shift 2
	elif [ "$1" = "--reg-password" ]; then
		# The password used to access the mirror registry 
		# Add a password in ='password'
		[[ "$2" =~ ^- || -z "$2" ]] && reg_pw_value= || { reg_pw_value="$2"; shift; }
		# force will skip over asking to edit the conf file
		make -sC $ABA_ROOT/mirror mirror.conf force=yes
		replace-value-conf -n reg_pw -v "'$reg_pw_value'" -f $ABA_ROOT/mirror/mirror.conf
		shift
	elif [ "$1" = "--reg-path" ]; then
		[[ "$2" =~ ^- || -z "$2" ]] && aba_abort "missing argument after option $1" >&2 
		# force will skip over asking to edit the conf file
		make -sC $ABA_ROOT/mirror mirror.conf force=yes
		replace-value-conf -n reg_path -v "$2" -f $ABA_ROOT/mirror/mirror.conf
		shift 2
	elif [ "$1" = "--base-domain" -o "$1" = "-b" ]; then
		[[ "$2" =~ ^- || -z "$2" ]] && aba_abort "missing argument after option $1" 
		#domain=$(echo "$2" | grep -Eo '([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}')
		[[ $2 =~ ([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}$ ]] && domain=${BASH_REMATCH[0]}  # no need for grep
		[ ! "$domain" ] && aba_abort "domain format incorrect [$2]" 
		replace-value-conf -n domain -v "$domain" -f $WORK_DIR/cluster.conf $ABA_ROOT/aba.conf
		shift 2
	elif [ "$1" = "--machine-network" -o "$1" = "-M" ]; then
		[[ "$2" =~ ^- || -z "$2" ]] && aba_abort "missing argument after option $1" 
		if echo "$2" | grep -q -E '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$'; then
			replace-value-conf -n machine_network -v "$2" -f $WORK_DIR/cluster.conf $ABA_ROOT/aba.conf
		else
			aba_abort "invalid CIDR [$2]" 
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
				aba_abort "skipping invalid IP address [$2]"
			fi
			shift
		done
		replace-value-conf -n dns_servers -v "$dns_ips" -f $WORK_DIR/cluster.conf $ABA_ROOT/aba.conf
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
		replace-value-conf -n ntp_servers -v "$ntp_vals" -f $WORK_DIR/cluster.conf $ABA_ROOT/aba.conf
		shift 
	elif [ "$1" = "--gateway-ip" -o "$1" = "-g" ]; then
		# If arg missing remove from aba.conf
		shift 
		gw_ip=
		if [[ -n $1 && $1 != -* && $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
			gw_ip=$1
		fi
	#	if [ "$1" ] && ! echo "$1" | grep -q "^-"; then
	#		gw_ip=$(echo $1 | grep -Eo '^([0-9]{1,3}\.){3}[0-9]{1,3}$')
	#	fi
		replace-value-conf -n next_hop_address -v "$gw_ip" -f $WORK_DIR/cluster.conf $ABA_ROOT/aba.conf
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
					aba_abort "invalid IPv4 address [$2]" 
				fi
			else
				aba_abort "argument invalid [$2] after option: $1" 
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
					aba_abort "invalid IPv4 address [$2]" 
				fi
			else
				aba_abort "argument invalid [$2] after option: $1" 
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
		[[ "$2" =~ ^- || -z "$2" ]] && aba_abort "missing argument after option $1" 
		replace-value-conf -n platform -v "$2" -f $ABA_ROOT/aba.conf
		shift 2
	elif [ "$1" = "--op-sets" -o "$1" = "-P" ]; then
		# If no arg after --op-sets
		if [[ "$2" =~ ^- || -z "$2" ]]; then
			# Remove value
			replace-value-conf -n op_sets -v -f $ABA_ROOT/aba.conf
			shift
		else
			shift
			# Step through non-opt params, check the set exists and add to the list ...
			#while [ "$1" ] && ! echo "$1" | grep -q -e "^-"
			while [[ -n "$1" && "$1" != -* ]]; do
				if [ -s "$ABA_ROOT/templates/operator-set-$1" -o "$1" = "all" ]; then
					[ "$op_set_list" ] && op_set_list="$op_set_list,$1" || op_set_list=$1
				else
					aba_warning "No such operator set: $1" >&2
					aba_info -n "Available operator sets are: " >&2
					ls templates/operator-set-* -1| cut -d- -f3| tr "\n" " " >&2
					aba_info "(as defined in files: aba/templates/operator-sets-*)" >&2

					exit 1
				fi
				shift
			done
			replace-value-conf -n op_sets -v $op_set_list -f $ABA_ROOT/aba.conf
		fi
	elif [ "$1" = "--ops" -o "$1" = "-O" ]; then
		if [[ "$2" =~ ^- || -z "$2" ]]; then
			# Remove value
			replace-value-conf -n ops -v  -f $ABA_ROOT/aba.conf
			shift
		else
			shift
			while [[ -n "$1" && "$1" != -* ]]; do ops_list="$ops_list $1"; shift; done
			ops_list=$(echo $ops_list | xargs | tr -s " " | tr " " ",")  # Trim white space and add ','
			replace-value-conf -n ops -v $ops_list -f $ABA_ROOT/aba.conf
		fi
	elif [ "$1" = "--incl-platform" ]; then  # FIXME: Only have "--excl-platform" option and add true or false (remove: --incl-platform ??)
		replace-value-conf -n excl_platform -v "false" -f $ABA_ROOT/aba.conf
		shift
	elif [ "$1" = "--excl-platform" ]; then
		replace-value-conf -n excl_platform -v "true" -f $ABA_ROOT/aba.conf
		shift
	elif [ "$1" = "--editor" -o "$1" = "-e" ]; then
		[[ "$2" =~ ^- || -z "$2" ]] && aba_abort "missing argument after option $1" 
		editor="$2"
		replace-value-conf -n editor -v $editor -f $ABA_ROOT/aba.conf
		shift 2
	elif [ "$1" = "--pull-secret" -o "$1" = "-S" ]; then
		[[ "$2" =~ ^- || -z "$2" ]] && aba_abort "missing argument after option $1" 
		replace-value-conf -n pull_secret_file -v "$2" -f $ABA_ROOT/aba.conf
		shift 2
	elif [ "$1" = "--vmware" -o "$1" = "--vmw" -o "$1" = "-V" ]; then
		[[ "$2" =~ ^- || -z "$2" ]] && aba_abort "missing argument after option $1" 
		[ -s $1 ] && cp "$2" vmware.conf
		shift 2
	elif [ "$1" = "-y" -o "$1" = "--yes" ]; then  # One off, accept the default answer to all prompts for this invocation
		export ASK_OVERRIDE=1  # For this invocation only, -y will overwide ask=true in aba.conf
		export ask=1
		shift 
	elif [ "$1" = "-Y" ]; then  # One off, accept the default answer to all prompts for this invocation
		export ASK_OVERRIDE=1  
		replace-value-conf -n ask -v false -f $ABA_ROOT/aba.conf  # And make permanent change
		export ask=
		shift 
	elif [ "$1" = "--ask" -o "$1" = "-a" ]; then
		replace-value-conf -n ask -v true -f $ABA_ROOT/aba.conf
		export ask=1
		shift 
	elif [ "$1" = "--noask" -o "$1" = "-A" ]; then  # FIXME: make -y work only for a single command execution (not write into file)
		replace-value-conf -n ask -v false -f $ABA_ROOT/aba.conf
		export ask=
		shift 
	elif [ "$1" = "--mcpu" -o "$1" = "--master-cpu" ]; then  # FIXME opt.
		[[ "$2" =~ ^- || -z "$2" ]] && aba_abort "missing argument after option $1" 
		if echo "$2" | grep -q -E '^[0-9]+$'; then
			if [ -f cluster.conf ]; then
				replace-value-conf -n master_cpu -v $2 -f cluster.conf
			else
				BUILD_COMMAND="$BUILD_COMMAND master_cpu_count=$2"
			fi
		else
			aba_abort "argument invalid [$2] after option $1" 
		fi
		shift 2
	elif [ "$1" = "--mmem" -o "$1" = "--master-memory" ]; then  # FIXME opt.
		[[ "$2" =~ ^- || -z "$2" ]] && aba_abort "missing argument after option $1"
		if echo "$2" | grep -q -E '^[0-9]+$'; then
			if [ -f cluster.conf ]; then
				replace-value-conf -n master_mem -v $2 -f cluster.conf
			else
				BUILD_COMMAND="$BUILD_COMMAND master_mem=$2"
			fi
		else
			aba_abort "argument invalid [$2] after option $1" 
		fi
		shift 2
	elif [ "$1" = "--wcpu" -o "$1" = "--worker-cpu" ]; then  # FIXME opt.
		[[ "$2" =~ ^- || -z "$2" ]] && aba_abort "missing argument after option $1"
		if echo "$2" | grep -q -E '^[0-9]+$'; then
			if [ -f cluster.conf ]; then
				replace-value-conf -n worker_cpu -v $2 -f cluster.conf
			else
				BUILD_COMMAND="$BUILD_COMMAND worker_cpu_count=$2"
			fi
		else
			aba_abort "argument invalid [$2] after option $1" 
		fi
		shift 2
	elif [ "$1" = "--wmem" -o "$1" = "--worker-memory" ]; then  # FIXME opt.
		[[ "$2" =~ ^- || -z "$2" ]] && aba_abort "missing argument after option $1" 
		if echo "$2" | grep -q -E '^[0-9]+$'; then
			if [ -f cluster.conf ]; then
				replace-value-conf -n worker_mem -v $2 -f cluster.conf
			else
				BUILD_COMMAND="$BUILD_COMMAND worker_mem=$2"
			fi
		else
			aba_abort "argument invalid [$2] after option $1" 
		fi
		shift 2
	elif [ "$1" = "--starting-ip" -o "$1" = "-i" ]; then
		[[ "$2" =~ ^- || -z "$2" ]] && aba_abort "missing argument after option $1" 
		if echo "$2" | grep -q -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
			if [ -f cluster.conf ]; then
				replace-value-conf -n starting_ip -v $2 -f cluster.conf
			else
				BUILD_COMMAND="$BUILD_COMMAND starting_ip='$2'" # FIXME: Still needed?
			fi
		else
			aba_abort "argument invalid [$2] after option $1" 
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
			aba_abort "argument invalid [$2] after option $1" 
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
				aba_abort "argument invalid [$int_connection] after option: $1" 
				exit 1
			fi
			shift
		else
			# Do nothing, remove value in cluster.conf?
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
		[[ "$2" =~ ^- || -z "$2" ]] && aba_abort "missing argument after option $1" 
		if [ "$cur_target" = "cluster" ]; then
			BUILD_COMMAND="$BUILD_COMMAND name='$2'"  # FIXME: This is confusing and prone to error
		else
			aba_abort "can only use option $1 after target 'cluster'.  See aba cluster -h" 

			exit 1
		fi

		shift 2
	elif [ "$1" = "--type" -o "$1" = "-t" ]; then
		[[ "$2" =~ ^- || -z "$2" ]] && aba_abort "missing argument after option $1" 
		# If there's another arg and it's an expected cluster type, accept it, otherwise error.
		if echo "$2" | grep -qE "^sno$|^compact$|^standard$"; then
			if [ "$cur_target" = "cluster" ]; then
				BUILD_COMMAND="$BUILD_COMMAND type='$2'"
				shift 2
			else
				aba_abort "can only use option $1 after target 'cluster'.  See aba cluster -h" 
			fi
		else
			aba_abort "missing or incorrect argument (sno|compact|standard) after option $1" 
		fi
	elif [ "$1" = "--step" -o "$1" = "-s" ]; then
		[[ "$2" =~ ^- || -z "$2" ]] && aba_abort "missing argument after option $1" 
		# If there's another arg and it's NOT an option (^-) then accept it, otherwise error
		BUILD_COMMAND="$BUILD_COMMAND target='$2'"  # FIXME: Also confusing, similar to --name
		shift 2
	elif [ "$1" = "--retry" -o "$1" = "-r" ]; then
		# If there's another arg and it's a number then accept it
		if [ "$2" ] && echo "$2" | grep -qE "^[0-9]+$"; then
			BUILD_COMMAND="$BUILD_COMMAND retry='$2'"
			aba_debug "Adding retry=$2 to BUILD_COMMAND"
			shift 2
		# In all other cases, use '3' 
		else
			BUILD_COMMAND="$BUILD_COMMAND retry=2"  # FIXME: Also confusing, similar to --name
			aba_debug Setting $1 to 3 
			shift
		fi
	elif [ "$1" = "--force" -o "$1" = "-f" ]; then
		shift
		opt_force="--force"
		BUILD_COMMAND="$BUILD_COMMAND force=force"  # FIXME: Should only allow force=1 after the appropriate target
	elif [ "$1" = "--wait" -o "$1" = "-w" ]; then
		shift
		BUILD_COMMAND="$BUILD_COMMAND wait=1"  #FIXME: Should only allow this after the appropriate target
	elif [ "$1" = "--workers" ]; then
		BUILD_COMMAND="$BUILD_COMMAND workers=1"
		shift
	elif [ "$1" = "--masters" ]; then
		BUILD_COMMAND="$BUILD_COMMAND masters=1"
		shift
	elif [ "$1" = "--start" ]; then
		BUILD_COMMAND="$BUILD_COMMAND start=--start"
		shift
	elif [ "$1" = "--cmd" ]; then
		# Note, -c is used for --channel
		cmd=
		shift 
		echo "$1" | grep -q "^-" || cmd="$1"
		[ "$cmd" ] && shift || cmd="get co" # Set default command here
	else
		if echo "$1" | grep -q "^-"; then
			aba_abort "$(basename $0): Error: no such option $1" 
		else
			cur_target=$1

			case $cur_target in
				ssh|run|bundle)
					# FIXME: Add more here: day2 day2-ntp day2-osus shell login etc  (all items without any deps)
					# These are now all processed once, in code below
					:
					;;
				*)
					BUILD_COMMAND="$BUILD_COMMAND $1"
					aba_debug Command added: BUILD_COMMAND=$BUILD_COMMAND 
					;;
			esac
			#fi
		fi
		shift 
	fi
done

if [ "$cur_target" ]; then
	aba_debug cur_target=$cur_target
	case $cur_target in
		ssh)
			trap - ERR  # No need for this anymore
			$ABA_ROOT/scripts/ssh-rendezvous.sh "$cmd"
			exit 
		;;
		run)
			trap - ERR  # No need for this anymore
			$ABA_ROOT/scripts/oc-command.sh "$cmd"
			exit 
		;;
	bundle)
		trap - ERR  # No need for this anymore
		aba_debug Running: $ABA_ROOT/scripts/make-bundle.sh -o "$opt_out" $opt_force $opt_light
		eval $ABA_ROOT/scripts/make-bundle.sh $opt_out $opt_force $opt_light
		exit 
	;;
	esac
fi

aba_debug "interactive_mode=[$interactive_mode]"

# Sanitize $BUILD_COMMAND
BUILD_COMMAND=$(echo "$BUILD_COMMAND" | tr -s " " | sed -E -e "s/^ //g" -e "s/ $//g")

aba_debug "ABA_ROOT=[$ABA_ROOT]" 
aba_debug "BUILD_COMMAND=[$BUILD_COMMAND]" 

# Do not execute interactive mode if args are provided and no make command to run.
# FIXME: Would it be better to run interactive mode before the 2nd while loop at the top?!
[ "$have_args" -a ! "$BUILD_COMMAND" ] && exit 0

# We want interactive mode if aba is running at the top of the repo and without any args
[ ! "$BUILD_COMMAND" -a "$ABA_ROOT" = "." ] && interactive_mode=1

if [ ! "$interactive_mode" ]; then
	# Only run make if there's a target
	if [ "$BUILD_COMMAND" ]; then
		if [ "$DEBUG_ABA" ]; then
			aba_debug ask=$ask DEBUG_ABA=$DEBUG_ABA INFO_ABA=$INFO_ABA
			aba_debug "Running: \"make $BUILD_COMMAND\" from directory: $PWD" 
			aba_debug -n "Pausing 5s ... [Return to continue]:"
			read -t 5 || echo

			# eval is needed here since $BUILD_COMMAND should not be evaluated/processed (it may have ' or " in it)
			eval make $BUILD_COMMAND
		else
			# eval needed since $BUILD_COMMAND should not be evaluated/processed (it may have ' or " in it)
			# Run make in silent mode
			aba_debug ask=$ask
			aba_debug "Running: \"make -s $BUILD_COMMAND\" from directory: $PWD" 
			eval make -s $BUILD_COMMAND
		fi
	fi
	ret=$?
	aba_debug "Exiting $0 with code $ret"
	exit $ret # Important that we exit here with exit code from the above make command
fi

# Change to the top level repo directory
cd $ABA_ROOT

aba_debug "Running aba interactive mode ..."

# ###########################################
# From now on it's all considered INTERACTIVE

# If in interactive mode then ensure all prompts are active!
### replace-value-conf aba.conf ask true   # Do not make this permanent!
source <(normalize-aba-conf)
export ask=1  # In interactive mode let's use the safe option!
export ASK_OVERRIDE=  # Do NOT override $ask, even if $ask is false (re-read from aba.conf - omg this needs to be simplified!)
export ASK_ALWAYS=1   # Force to always ask, no matter the $ask or $ASK_OVERRIDE !!

#verify-aba-conf || exit 1  # Can't verify here 'cos aba.conf likely has no ocp_version or channel defined

sed "s/VERSION/v$ABA_VERSION/" others/message.txt

##############################################################################################################################
# Determine if this is an "aba bundle" or just a clone from GitHub

if [ -f .bundle ]; then
	# aba is running on the internal bastion, in 'bundle mode'.

	# make & jq are needed below and in the next steps. Best to install all at once.
	scripts/install-rpms.sh internal

	# Start extracting all CLI binaries and mirror-registry in parallel (tarballs already in bundle)
	# These run in background and will be ready when user runs commands that need them
	
	scripts/cli-install-all.sh                                    # Start CLI extractions (background)
	run_once -i "$TASK_QUAY_REG" -- make -sC mirror mirror-registry  # Start mirror-registry extraction (background)

	echo_yellow "Aba install bundle detected for OpenShift v$ocp_version."

	# Check if tar files are already in place
	if [ ! "$(ls mirror/save/mirror_*tar 2>/dev/null)" ]; then
		{
			echo
			aba_warning -p "IMPORANT" \
				"The Image-set archive file(s) (ISA image payload) are not included in this install bundle." \
				"The ISA file(s) were left out of the install bundle during its creation and *must be*" \
				"moved or copied into the install bundle under the aba/mirror/save directory before continuing!"
			echo
			echo_white "Example (copy ISA from portable media):" 
			echo_white "  cp /path/to/portable/media/mirror_*.tar aba/mirror/save/" 
			echo_white "Run aba again for further instructions." 
		} >&2

		exit 0
	else
		{
			echo 
			echo_yellow "This bundle is ready to install OpenShift in your disconnected environment." 
		} >&2
	fi

	echo 
	echo_yellow "Instructions"
	echo
	echo_yellow "IMPORTANT: Review the values in aba.conf and update them to ensure they are complete and correctly match your disconnected environment."

	echo_white "Existing values in aba.conf:"
	to_output=$(normalize-aba-conf | sed -e "s/^export //g" -e "/^pull_secret_file=.*/d")  # In disco env, no need to show pull-secret.
	output_table 3 "$to_output"

	echo
	echo_white "Next steps:"
	echo_white "Set up a mirror registry and load it with the required container images from this install bundle."
	echo_white "Aba can deploy the 'Mirror Registry for Red Hat OpenShift' (Quay) or use an existing container registry."
	echo_white "As an alternative, Aba can also install a Docker registry. See the README.md FAQ for instructions."

	[ ! "$domain" ] && domain=example.com  # Just in case
	echo
	echo_white "Examples:"
	echo_white "To install the registry on the local machine, accessible via $(hostname -s).$domain, run:"
	echo_white "  aba -d mirror load -H $(hostname -s).$domain --retry 8"
	echo
	echo_white "To install the registry on a remote host, specify the SSH key (and optionally the remote user) to access the host, run:"
	echo_white "  aba -d mirror load -H remote-registry.$domain -k '~/.ssh/id_rsa' -U user --retry"
	echo
	echo_white "If unsure, run:"
	echo_white "  aba -d mirror install                 # to configure and/or install Quay."
	echo
	echo_white "Once the mirror registry is installed/configured, verify authentication with:"
	echo_white "  aba -d mirror verify"
	echo
	echo_white "For more, run: aba load --help"

	exit 0
fi


# Fresh GitHub clone of Aba repo detected!

##############################################################################################################################
# Determine OpenShift channel

[ "$ocp_channel" = "eus" ] && ocp_channel=stable  # btw .../ocp/eus/release.txt does not exist!

#if [ "$ocp_channel" ]; then
#	#echo_white "OpenShift update channel is defined in aba.conf as '$ocp_channel'."
#	echo_white "OpenShift update channel is set to '$ocp_channel' in aba.conf."
#else

	aba_debug "Fetching OpenShift version data in background ..."
	# Download openshift version data in the background.  'bash -lc ...' used here 'cos can't setsid a function.
	run_once -i ocp:stable:latest_version			-- bash -lc 'source ./scripts/include_all.sh; fetch_latest_version	stable'
	run_once -i ocp:stable:latest_version_previous		-- bash -lc 'source ./scripts/include_all.sh; fetch_previous_version	stable'
	run_once -i ocp:fast:latest_version			-- bash -lc 'source ./scripts/include_all.sh; fetch_latest_version	fast'
	run_once -i ocp:fast:latest_version_previous		-- bash -lc 'source ./scripts/include_all.sh; fetch_previous_version	fast'
	run_once -i ocp:candidate:latest_version			-- bash -lc 'source ./scripts/include_all.sh; fetch_latest_version	candidate'
	run_once -i ocp:candidate:latest_version_previous	-- bash -lc 'source ./scripts/include_all.sh; fetch_previous_version	candidate'

	aba_debug "Downloading oc-mirror in the background ..."
	PLAIN_OUTPUT=1 run_once -i "$TASK_OC_MIRROR"			-- make -sC cli oc-mirror

	# Check Internet connectivity to required sites (using shared function)
	aba_info "Checking Internet connectivity to required sites..."
	
	if ! check_internet_connectivity "cli"; then
		aba_abort \
			"Cannot access required sites: $FAILED_SITES" \
			"" \
			"Error details:" \
			"  $ERROR_DETAILS" \
			"" \
			"Ensure you have Internet access to download the required images." \
			"To get started with Aba run it on a connected workstation/laptop with Fedora, RHEL or Centos Stream and try again." \
			"" \
			"Required sites:                                Other sites:" \
			"   mirror.openshift.com                           docker.io" \
			"   api.openshift.com                              docker.com" \
			"   registry.redhat.io                             hub.docker.com" \
			"   quay.io and *.quay.io                          index.docker.io" \
			"   console.redhat.com" \
			"   registry.access.redhat.com"
	fi
	
	# Only show success message if we actually checked (not from cache)
	if [[ "$checking_connectivity" == "true" ]]; then
		aba_debug "Connectivity check passed - all sites accessible"
		aba_info "  ✓ All required sites accessible"
	else
		aba_debug "Connectivity check skipped - using cached results"
	fi

	[ "$ocp_channel" ] && ch_def=${ocp_channel:0:1} || ch_def=s  # Set the default 

	while true; do
		aba_info -n "Which OpenShift update channel do you want to use? (c)andidate, (f)ast or (s)table [$ch_def]: "
		read -r ans

		[ ! "$ans" ] && ans=$ch_def

		case "$ans" in
			"s"|"S")
			        ocp_channel="stable"
				break
			;;
			"f"|"F")
				ocp_channel="fast"
				break
			;;
			"c"|"C")
				ocp_channel="candidate"
				break
			;;
			*)
				echo_red "Invalid choice. Please enter f, s, or c."
			;;
		esac
	done

	replace-value-conf -q -n ocp_channel -v $ocp_channel -f aba.conf
	aba_info "'ocp_channel' set to '$ocp_channel' in aba.conf"

#fi

##############################################################################################################################
# Determine OpenShift version 

#if [ "$ocp_version" ]; then
#	#echo_white "OpenShift version is defined in aba.conf as '$ocp_version'."
#	echo_white "OpenShift version is set to '$ocp_version' in aba.conf."
#else

	echo_white -n "Fetching available versions ..."
	# Wait for only the data we need (quietly - message already shown above)
	if ! run_once -w -q -i ocp:$ocp_channel:latest_version; then
		error_msg=$(run_once -e -i ocp:$ocp_channel:latest_version)
		aba_abort "Failed to fetch latest OCP version from Cincinnati API:\n$error_msg\n\nPlease check network/DNS and try again."
	fi
	
	if ! run_once -w -q -i ocp:$ocp_channel:latest_version_previous; then
		error_msg=$(run_once -e -i ocp:$ocp_channel:latest_version_previous)
		aba_abort "Failed to fetch previous OCP version from Cincinnati API:\n$error_msg\n\nPlease check network/DNS and try again."
	fi
#	if [ "$ocp_channel" = "stable" ]; then
#		run_once -w -i ocp:stable:latest_version
#		run_once -w -i ocp:stable:latest_version_previous
#	elif [ "$ocp_channel" = "fast" ]; then
#		run_once -w -i ocp:fast:latest_version
#		run_once -w -i ocp:fast:latest_version_previous
#	elif [ "$ocp_channel" = "candidate" ]; then
#		run_once -w -i ocp:candidate:latest_version
#		run_once -w -i ocp:candidate:latest_version_previous
#	fi

	##############################################################################################################################
	# Fetch release.txt

#	aba_debug "Looking up release at https://mirror.openshift.com/pub/openshift-v4/$ARCH/clients/ocp/$ocp_channel/release.txt"

#	if ! release_text=$(curl -f --connect-timeout 30 --retry 8 -sSL https://mirror.openshift.com/pub/openshift-v4/$ARCH/clients/ocp/$ocp_channel/release.txt); then
#		[ "$TERM" ] && tput el1 && tput cr
#		aba_abort "failed to access https://mirror.openshift.com/pub/openshift-v4/$ARCH/clients/ocp/$ocp_channel/release.txt" 
#	fi

	## Get the latest stable OpenShift version number, e.g. 4.14.6
	#channel_ver=$(echo "$release_text" | grep -E -o "Version: +[0-9]+\.[0-9]+\.[0-9]+" | awk '{print $2}')
	aba_debug "Looking up latest version using fetch_latst_version() $ocp_channel"
	channel_ver=$(fetch_latest_version "$ocp_channel")
	default_ver=$channel_ver

	aba_debug "Looking up previous version using fetch_previous_version() $ocp_channel"

	channel_ver_prev=$(fetch_previous_version "$ocp_channel")

	# Determine any already installed tool versions
	which openshift-install >/dev/null 2>&1 && cur_ver=$(openshift-install version | grep ^openshift-install | grep -E -o "[0-9]+\.[0-9]+\.[0-9]+")
	[ "$ocp_version" ] && cur_ver=$ocp_version  # prioritize the current version as defined in aba.conf

	# If openshift-install is already installed, then offer that version also
	[ "$cur_ver" ] && or_ret="or [current version] " && default_ver=$cur_ver

	[ "$TERM" ] && tput el1 && tput cr

	aba_info "Which version of OpenShift do you want to install?"

	target_ver=
	while true
	do
		# Exit loop if release version exists
		if [ "$target_ver" ]; then
			aba_debug "Validating user input: target_ver=[$target_ver]"
			if echo "$target_ver" | grep -E -q "^[0-9]+\.[0-9]+\.[0-9]+$"; then
				# Validate x.y.z using Cincinnati graph (cached)
				minor="${target_ver%.*}"  # 4.18.10 → 4.18
				aba_debug "Detected x.y.z format, extracting minor: $minor"
				
				# Fetch all versions for this channel-minor (may fail if minor doesn't exist)
				aba_debug "Fetching all versions for $ocp_channel/$minor"
				if all_versions=$(fetch_all_versions "$ocp_channel" "$minor" 2>/dev/null) && [ -n "$all_versions" ]; then
					aba_debug "Successfully fetched version list ($(echo "$all_versions" | wc -l) versions)"
					if echo "$all_versions" | grep -qx "$target_ver"; then
						aba_debug "Version $target_ver validated successfully"
						break
					else
						aba_debug "Version $target_ver not found in version list"
						echo_red "Version $target_ver not found in $ocp_channel channel" >&2
						echo_red "" >&2
						echo_red "This version is either invalid or has reached End-of-Life." >&2
						echo_red "" >&2
						echo_red "Try:" >&2
						[ -n "$channel_ver" ] && echo_red "  • Latest: $channel_ver (press 'l')" >&2
						[ -n "$channel_ver_prev" ] && echo_red "  • Previous: $channel_ver_prev (press 'p')" >&2
						echo_red "  • List all: aba ocp-versions" >&2
						target_ver=""  # Reset to loop again
					fi
				else
					aba_debug "Failed to fetch versions for $ocp_channel/$minor (minor doesn't exist)"
					echo_red "Version $target_ver not found in $ocp_channel channel" >&2
					echo_red "" >&2
					echo_red "OpenShift $minor does not exist or has reached End-of-Life." >&2
					echo_red "" >&2
					echo_red "Try:" >&2
					[ -n "$channel_ver" ] && echo_red "  • Latest: $channel_ver (press 'l')" >&2
					[ -n "$channel_ver_prev" ] && echo_red "  • Previous: $channel_ver_prev (press 'p')" >&2
					echo_red "  • List all: aba ocp-versions" >&2
					target_ver=""  # Reset to loop again
				fi
			else
				aba_debug "Invalid format: $target_ver (not x.y or x.y.z)"
				echo_red "Invalid input. Enter a valid OpenShift version (e.g., 4.18.10 or 4.18)." >&2
				target_ver=""  # Reset to loop again
			fi
		fi

		[ "$channel_ver" ] && or_s="or $channel_ver (l)atest "
		[ "$channel_ver_prev" ] && or_p="or $channel_ver_prev (p)revious "

		#aba_info -n "Enter x.y.z or x.y version $or_s$or_p$or_ret(<version>/l/p/Enter) [$default_ver]: "
		aba_info -n "Enter x.y.z or x.y version $or_s$or_p(<version>/l/p/Enter) [$default_ver]: "
		read target_ver

		[ ! "$target_ver" ] && target_ver=$default_ver && aba_debug "Using default: $default_ver"
		[ "$target_ver" = "l" -a "$channel_ver" ] && target_ver=$channel_ver && aba_debug "User selected latest: $channel_ver"
		[ "$target_ver" = "p" -a "$channel_ver_prev" ] && target_ver=$channel_ver_prev && aba_debug "User selected previous: $channel_ver_prev"

		# If user enters just a point version, x.y, fetch the latest .z value for that point version of OpenShift
		if echo $target_ver | grep -E -q "^[0-9]+\.[0-9]+$"; then
			aba_debug "Detected x.y format, resolving to latest z-stream: $target_ver"
			resolved_ver=$(fetch_latest_z_version "$ocp_channel" "$target_ver")
			if [ -n "$resolved_ver" ]; then
				aba_debug "Resolved $target_ver -> $resolved_ver"
				target_ver="$resolved_ver"
			else
				aba_debug "Failed to resolve $target_ver (minor doesn't exist)"
				echo_red "Version $target_ver not found in $ocp_channel channel" >&2
				echo_red "" >&2
				echo_red "This version is either invalid or has reached End-of-Life." >&2
				echo_red "" >&2
				echo_red "Try:" >&2
				[ -n "$channel_ver" ] && echo_red "  • Latest: $channel_ver (press 'l')" >&2
				[ -n "$channel_ver_prev" ] && echo_red "  • Previous: $channel_ver_prev (press 'p')" >&2
				echo_red "  • List all: aba ocp-versions" >&2
				target_ver=""  # Reset to loop again
			fi
		fi
	done

	# Update the conf file
	aba_debug "Updating aba.conf with validated version: $target_ver"
	replace-value-conf -q -n ocp_version -v $target_ver -f aba.conf
	aba_info "'ocp_version' set to '$target_ver' in aba.conf"
#fi

# Now we know the desired openshift version...

# Fetch the operator indexes (in the background to save time).
# Use new helper function for parallel catalog downloads (runs in background)
ocp_ver_short="${target_ver%.*}"  # Extract major.minor (e.g., 4.20.8 -> 4.20)
download_all_catalogs "$ocp_ver_short" 86400  # 1-day TTL
# Note: Catalogs wait/check happens in scripts that actually need them
# (e.g., add-operators-to-imageset.sh, download-and-wait-catalogs.sh)

# Trigger download of all CLI binaries (for interactive mode only)
# Note: Non-interactive mode already started these at line ~205
# Note: Another place this is checked is in "scripts/reg-save.sh"
scripts/cli-download-all.sh

# Initiate download of mirror-install and docker-reg image
run_once -i "$TASK_QUAY_REG_DOWNLOAD" -- make -s -C mirror download-registries

# make & jq are needed below and in the next steps 
scripts/install-rpms.sh external 

# Just in case, check the target ocp version in aba.conf matches any existing versions defined in oc-mirror imageset config files. 
# FIXME: Any better way to do this?! .. or just keep this check in 'aba -d mirror sync' and 'aba -d mirror save' (i.e. before we d/l the images
{
	install_rpms make || exit 1
	make -s -C mirror checkversion 
} || exit 

##############################################################################################################################
source <(normalize-aba-conf)
verify-aba-conf || exit 1
export ask=1 # Must set for interactive mode!

##############################################################################################################################
# Determine editor

if [ ! "$editor" ]; then
	echo
	def_editor="${EDITOR:-${VISUAL:-vi}}"

	echo    "Aba uses an editor to aid in the workflow."
	echo_yellow -n "Enter your preferred editor or set to 'none' if you prefer to edit manually! ('vi', 'emacs', 'nano' etc or 'none')? [$def_editor]: "
	read new_editor

	[ ! "$new_editor" ] && new_editor=$def_editor  # default

	if [ "$new_editor" != "none" ]; then
		if ! which $new_editor >/dev/null 2>&1; then
			aba_abort "editor '$new_editor' command not found! Please install your preferred editor and try again!" 
		fi
	fi

	replace-value-conf -n editor -v "$new_editor" -f aba.conf
	export editor=$new_editor
fi

##############################################################################################################################
# Allow edit of aba.conf

if [ ! -f .aba.conf.seen ]; then
	if edit_file aba.conf "Edit aba.conf to set global values, e.g. platform type, base domain & net addresses, dns & ntp etc (if known)"; then
		# If edited/seen, no need to ask again.
		touch .aba.conf.seen
	else
		touch .aba.conf.seen
		exit 0
	fi
fi

##############################################################################################################################
# Determine pull secret

if grep -qi "registry.redhat.io" $pull_secret_file 2>/dev/null; then
	if jq empty $pull_secret_file; then
		aba_info "Pull secret found at '$pull_secret_file'."
		
		# Validate pull secret by testing authentication with registry.redhat.io
		aba_info -n "Validating pull secret authentication..."
		if validate_pull_secret "$pull_secret_file" >/dev/null 2>&1; then
			aba_info " ✓ Authentication successful"
		else
			echo
			# validate_pull_secret already outputs detailed error with [ABA] prefix
			validate_pull_secret "$pull_secret_file" >/dev/null || true  # Show stderr, ignore exit code
			echo >&2
			aba_info "This may mean:" >&2
			aba_info "  • Pull secret is expired (download new from console.redhat.com)" >&2
			aba_info "  • Invalid credentials" >&2
			aba_info "  • Network/DNS issue" >&2
			echo >&2
			aba_info "Get your pull secret from: https://console.redhat.com/openshift/downloads#tool-pull-secret" >&2
			echo >&2
			aba_abort "Pull secret validation failed. Please fix and try again."
		fi
	else
		aba_abort "pull secret file syntax error: $pull_secret_file!" 
	fi
else
	aba_abort \
		"No Red Hat pull secret file found at '$pull_secret_file'!" \
		"" \
		"To allow access to the Red Hat image registry, download your Red Hat pull secret and store it in the file '$pull_secret_file' and try again!" \
		"Get your pull secret from: https://console.redhat.com/openshift/downloads#tool-pull-secret (select 'Tokens' in the pull-down)"
fi

##############################################################################################################################
# Determine air-gapped

echo
echo       "Fully Disconnected (air-gapped)"
echo_white "If you plan to install OpenShift in a fully disconnected (air-gapped) environment, Aba can download all required components—including"
echo_white "the Quay mirror registry install file, container images, and CLI install files—and package them into an install bundle that you can"
echo_white "transfer into your disconnected environment."

aba_debug ask=$ask ASK_OVERRIDE=$ASK_OVERRIDE

if ask "Install OpenShift into a fully disconnected network environment"; then
	echo
	echo_yellow "Instructions for a fully disconnected installation"
	echo
	echo_white "Run: aba bundle --out /path/to/portable/media             # to save all images to local disk & then create the install bundle"
	echo_white "                                                          # (size ~20-30GB for a base installation)."
	echo_white "     aba bundle --out - | ssh user@remote -- tar xvf -    # Stream the archive to a remote host and unpack it there."
	echo_white "     aba bundle --out - | split -b 10G - ocp_             # Stream the archive and split it into several, more manageable files."
	echo_white "                                                          # Unpack the files on the internal bastion with: cat ocp_* | tar xvf - "
	echo_white "     aba bundle --help                                    # See for help."
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
	echo_yellow "Instructions for synchronizing images directly from the Internet to a mirror registry"
	echo_white "Set up the mirror registry and sync it with the necessary container images."
	echo_white "To store container images, Aba can install the Quay mirror appliance or you can use an existing container registry."
	echo
	echo_white "Run:"
	echo_white "  aba -d mirror install                # to configure an existing registry or install Quay."
	echo_white "  aba -d mirror sync --retry <count>   # to synchronize all container images - from the Internet - into your registry."
	echo
	echo_white "Or run:"
	echo_white "  aba -d mirror sync --retry <count>   # to complete both actions and ensure any image synchronization issues are retried."
	echo
	echo_white "  aba mirror --help                    # See for help."

	echo_white "After the images are stored in your mirror registry, proceed with the OpenShift installation."
	echo

	exit 0
fi

echo 
echo "Fully Connected"
echo_white "Optionally, configure a proxy or use direct Internet access through NAT or a transparent proxy."
echo_yellow "Instructions for installing directly from the Internet"
echo_white "Example:"
echo_white "aba cluster --name mycluster --type sno --starting-ip 10.0.1.203 --int-connection proxy --step install"
echo_white "See aba cluster --help for more"

exit 0

