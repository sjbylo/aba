#!/bin/bash
# Start here, run this script to get going!

ABA_VERSION=20251105113802
# Sanity check
echo -n $ABA_VERSION | grep -qE "^[0-9]{14}$" || { echo "ABA_VERSION in $0 is incorrect [$ABA_VERSION]! Fix the format to YYYYMMDDhhmmss and try again!" >&2 && exit 1; }

arch_sys=$(uname -m)

uname -o | grep -q "^Darwin$" && echo "Run aba on RHEL, Fedora or even in a Centos-Stream container. Most tested is RHEL 9 (no oc-mirror for Mac OS!)." >&2 && exit 1

SUDO=
which sudo 2>/dev/null >&2 && SUDO=sudo

# Check we have sudo or root access 
[ "$SUDO" ] && [ "$(sudo id -run)" != "root" ] && echo "Configure passwordless sudo OR run aba as root, then try again!" >&2 && exit 1

WORK_DIR=$PWD # Remember so can change config file here 

## Change dir if asked
# Keep these lines, ready for the below lines of code #FIXME: Use well-known loaction for static files, e.g. /opt/aba
if [ "$1" = "--dir" -o "$1" = "-d" ]; then
	[ ! "$2" ] && echo "Error: directory path expected after option $1" >&2 && exit 1
	[ ! -e "$2" ] && echo "Error: directory $2 does not exist!" >&2 && exit 1
	[ ! -d "$2" ] && echo "Error: cannot change to $2: not a directory!" >&2 && exit 1

	[ "$DEBUG_ABA" ] && echo "$0: changing dir to: \"$2\"" >&2 # Keep this line as is
	cd "$2"
	shift 2

	WORK_DIR=$PWD # Remember so can change config file here - can override existing value (set above)
fi

# Check the repo location
# Need to be sure location of the top of the repo in order to find the important files
# FIXME: Place the files (scripts and templates etc) into a well known location, e.g. /opt/aba/...
if [ -s Makefile ] && grep -q "Top level Makefile" Makefile; then
	ABA_ROOT=$PWD
elif [ -s ../Makefile ] && grep -q "Top level Makefile" ../Makefile; then
	ABA_ROOT=$(realpath "..")
elif [ -s ../../Makefile ] && grep -q "Top level Makefile" ../../Makefile; then
	ABA_ROOT=$(realpath "../..")
elif [ -s ../../../Makefile ] && grep -q "Top level Makefile" ../../../Makefile; then
	ABA_ROOT=$(realpath "../../..")
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

## install will check if aba needs to be updated, if so it will return 2 ... so we re-execute it!
if [ ! "$ABA_DO_NOT_UPDATE" ]; then
	$ABA_ROOT/install -q   # Only aba iself should use the flag -q
	if [ $? -eq 2 ]; then
		export ABA_DO_NOT_UPDATE=1
		$0 "$@"  # This means aba was updated and needs to be called again
		exit
	fi
fi

source $ABA_ROOT/scripts/include_all.sh

# This will be the actual 'make' command that will eventually be run
BUILD_COMMAND=

# Init aba.conf
if [ ! -f $ABA_ROOT/aba.conf ]; then

	# Determine resonable defaults for ...
	export domain=$(get_domain)
	export machine_network=$(get_machine_network)
	export dns_servers=$(get_dns_servers)
	export next_hop_address=$(get_next_hop)
	export ntp_servers=$(get_ntp_servers)

	scripts/j2 templates/aba.conf.j2 > $ABA_ROOT/aba.conf
else
	# If the bundle has empty network valus in aba.conf, add defaults - as now is the best time (on internal network).
	# For pre-created bundles, aba.conf will exist but these values will be missing... so attempt to fill them in. 
	source <(normalize-aba-conf)
	# Determine resonable defaults for ...
	[ ! "$domain" ]			&& replace-value-conf -q -n domain		-v $(get_domain)		-f aba.conf
	[ ! "$machine_network" ]	&& replace-value-conf -q -n machine_network	-v $(get_machine_network)	-f aba.conf
	[ ! "$dns_servers" ]		&& replace-value-conf -q -n dns_servers		-v $(get_dns_servers)		-f aba.conf
	[ ! "$next_hop_address" ]	&& replace-value-conf -q -n next_hop_address	-v $(get_next_hop)		-f aba.conf
	[ ! "$ntp_servers" ]		&& replace-value-conf -q -n ntp_servers		-v $(get_ntp_servers)		-f aba.conf
fi

# Fetch any existing values (e.e. ocp_channel is used later for '-v')
source <(normalize-aba-conf)

interactive_mode=1
#interactive_mode_none=1
#[ "$*" ] && interactive_mode_none=1 && interactive_mode=
[ "$*" ] && interactive_mode=

cur_target=   # Can be 'cluster', 'mirror', 'save', 'load' etc 

############ NEW #########


DIR_SCRIPTS=$ABA_ROOT/scripts
DIR_TEMPLATES=$ABA_ROOT/templates
DIR_CLI=$ABA_ROOT/cli
DIR_OTHERS=$ABA_ROOT/others

# --- Dummy functions ---
update_global_conf() {
	echo_debug DUMMY Updating $PWD/aba.conf
}

update_mirror_conf() {
	echo_debug DUMMY Updating $PWD/mirrror.conf
}

update_cluster_conf() {
	if [ "$name" ]; then
		# Create cluster dir and cluster.conf
		echo_debug scripts/setup-cluster.sh name=$name type=$type target=$target starting_ip=$starting_ip ports=$ports_vals ingress_vip=$ingress_vip int_connection=$int_connection master_cpu_count=$master_cpu_count master_mem=$master_mem worker_cpu_count=$worker_cpu_count worker_mem=$worker_mem data_disk=$data_disk api_vip=$api_vip step=$step
		scripts/setup-cluster.sh name=$name type=$type target=$target starting_ip=$starting_ip ports=$ports_vals ingress_vip=$ingress_vip int_connection=$int_connection master_cpu_count=$master_cpu_count master_mem=$master_mem worker_cpu_count=$worker_cpu_count worker_mem=$worker_mem data_disk=$data_disk api_vip=$api_vip step=$step
	else
		echo_red "Error: Must provide at least --name after 'cluster'" >&2

		exit 1
	fi
}

update_bundle_conf() {
	if [ "$bundle_dest_path" ]; then
		$DIR_SCRIPTS/make-bundle.sh "$bundle_dest_path" "$force"
	else
		echo_error "Error: Must provide at least --out|-o after 'cluster'"
	fi
}

# Set defaults
type=standard

context=global

# --- Parse all arguments ---
while [ $# -gt 0 ]; do
	echo_debug "$0: Start of opt loop: \$* = " $* " context=[$context] cwd=$PWD"
	#echo "\$* = $*  context=$context" >&2

	case "$context" in
	global|cluster|mirror|bundle)
		echo_debug "parsing in context global with args: $* in $PWD"

		case "$1" in
		--help | -h)
			[ ! "$cur_target" ] && cur_target=$context

			case "$cur_target" in
				mirror|save|load|sync)
					cat $ABA_ROOT/others/help-mirror.txt ;;
				cluster)
					cat $ABA_ROOT/others/help-cluster.txt ;;
				bundle)
					cat $ABA_ROOT/others/help-bundle.txt ;;
				*)
					# If some other target, then show the main help
					cat $ABA_ROOT/others/help-aba.txt ;;
			esac

			exit 0
			;;
		-y | --yes)     # One off, accept the default answer to all prompts for this invocation
			export ASK_OVERRIDE=1  # For this invocation only, -y will overwide ask=true in aba.conf
			shift 
			;;
		-Y)  # One off, accept the default answer to all prompts for this invocation
			export ASK_OVERRIDE=1  
			replace-value-conf -n ask -v false -f $ABA_ROOT/aba.conf  # And make permanent change
			shift 
			;;
		--ask | -a) # FIXME remoe and use for other ops.
			replace-value-conf -n ask -v true -f $ABA_ROOT/aba.conf
			shift 
			;;
		--noask | -A) # FIXME: Remove!
			replace-value-conf -n ask -v false -f $ABA_ROOT/aba.conf
			shift 
			;;
		--editor | -e)
			[[ "$2" =~ ^- || -z "$2" ]] && echo_red "Error: Missing argument after option $1" >&2 && exit 1
			editor="$2"
			replace-value-conf -n editor -v $editor -f $ABA_ROOT/aba.conf
			shift 2
			;;
		--pull-secret | -S)
			[[ "$2" =~ ^- || -z "$2" ]] && echo_red "Error: Missing argument after option $1" >&2 && exit 1
			replace-value-conf -n pull_secret_file -v "$2" -f $ABA_ROOT/aba.conf
			shift 2
			;;
		--vmware | --vmw | -V)
			[[ "$2" =~ ^- || -z "$2" ]] && echo_red "Error: Missing argument after option $1" >&2 && exit 1
			[ -s $1 ] && cp "$2" vmware.conf
			shift 2
			;;
		--interactive)
			interactive_mode=1
			#interactive_mode_none=
			# If the user explicitly wants interactive mode, then ensure we make it interactive with "ask=true"
			replace-value-conf -n ask -v true -f $ABA_ROOT/aba.conf
			shift
			;;
		--info)
			export INFO_ABA=1
			shift 
			;;
		--debug | -D)
			export DEBUG_ABA=1
			export INFO_ABA=1
			shift 
			;;
		--channel | -c)
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
			replace-value-conf -n ocp_channel -v $chan -f $ABA_ROOT/aba.conf 
			ocp_channel=$chan
			shift 2
			;;
		--version | -v)
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
			echo $ver | grep -q -E "^[0-9]+\.[0-9]+$" && ver=$(fetch_latest_z_version "$ocp_channel" "$ver" "$arch_sys")
	
			# Extract only the full major.minor.patch version if present
			ver=$(echo "$ver" | grep -Eo '^[0-9]+\.[0-9]+\.[0-9]+$' || true)
	
			# As far as possible, always ensure there is a valid value in aba.conf
			[ ! "$ver" ] && echo_red "Failed to look up the latest version for [$2] after option $opt" >&2 && exit 1
	
			# ver should now be x.y.z format
			! echo $ver | grep -q -E "^[0-9]+\.[0-9]+\.[0-9]+$" && echo_red "Error: incorrect version format: [$ver] from arg [$2] after option $opt" >&2 && exit 1
	
			replace-value-conf -n ocp_version -v $ver -f $ABA_ROOT/aba.conf
	
			# Now we have the required ocp version, we can fetch the operator index in the background (to save time).
			echo_debug $0: Downloading operator index for version $ver
	
			( make -s -C $ABA_ROOT catalog bg=true & ) & 
	
			shift 2
			ocp_version=$ver
			;;
		--platform | -p)
			[[ "$2" =~ ^- || -z "$2" ]] && echo_red "Error: Missing argument after option $1" >&2 && exit 1
			replace-value-conf -n platform -v "$2" -f $ABA_ROOT/aba.conf
			shift 2
			;;
		--op-sets | -P)
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
						echo_red "No such operator set: $1" >&2
						echo_white -n "Available operator sets are: " >&2
						ls templates/operator-set-* -1| cut -d- -f3| tr "\n" " " >&2
						echo_white "(as defined in files: aba/templates/operator-sets-*)" >&2
	
						exit 1
					fi
					shift
				done
				replace-value-conf -n op_sets -v $op_set_list -f $ABA_ROOT/aba.conf
			fi
			;;
		--ops | -O)
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
			;;
		--incl-platform)
			replace-value-conf -n excl_platform -v "false" -f $ABA_ROOT/aba.conf
			shift
			;;
		--excl-platform)
			replace-value-conf -n excl_platform -v "true" -f $ABA_ROOT/aba.conf
			shift
			;;
		--base-domain | -b)
			[[ "$2" =~ ^- || -z "$2" ]] && echo_red "Error: Missing argument after option $1" >&2 && exit 1
			#domain=$(echo "$2" | grep -Eo '([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}')
			[[ $2 =~ ([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}$ ]] && domain=${BASH_REMATCH[0]}  # no need for grep
			[ ! "$domain" ] && echo_red "Error: Domain format incorrect [$2]" >&2 && exit 1
			replace-value-conf -n domain -v "$domain" -f $WORK_DIR/cluster.conf $ABA_ROOT/aba.conf
			shift 2
			;;
		--machine-network | -M)
			[[ "$2" =~ ^- || -z "$2" ]] && echo_red "Error: Missing argument after option $1" >&2 && exit 1
			if echo "$2" | grep -q -E '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$'; then
				replace-value-conf -n machine_network -v "$2" -f $WORK_DIR/cluster.conf $ABA_ROOT/aba.conf
			else
				echo_red "Error: Invalid CIDR [$2]" >&2
				exit 1
			fi
			shift 2
			;;
		--dns | -N)
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
			replace-value-conf -n dns_servers -v "$dns_ips" -f $WORK_DIR/cluster.conf $ABA_ROOT/aba.conf
			shift 
			;;
		--ntp | -T)
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
			;;
		--default-route | -R)
			# If arg missing remove from aba.conf
			shift 
			def_route_ip=
			if [[ -n $1 && $1 != -* && $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
				def_route_ip=$1
			fi
			replace-value-conf -n next_hop_address -v "$def_route_ip" -f $WORK_DIR/cluster.conf $ABA_ROOT/aba.conf
			shift 

			;;

		--retry | -r)
			# If there's another arg and it's a number then accept it
			if [ "$2" ] && echo "$2" | grep -qE "^[0-9]+$"; then
				BUILD_COMMAND="$BUILD_COMMAND retry='$2'"
				echo_debug $0: Adding retry=$2 to BUILD_COMMAND
				shift 2
			# In all other cases, use '3' 
			else
				BUILD_COMMAND="$BUILD_COMMAND retry=2"  # FIXME: Also confusing, similar to --name
				echo_debug $0: Setting $1 to 3
				shift
			fi
			;;

		--force | -f)
			shift
			BUILD_COMMAND="$BUILD_COMMAND force=1"  # FIXME: Should only allow force=1 after the appropriate target
			;;

		--wait | -w)
			shift
			BUILD_COMMAND="$BUILD_COMMAND wait=1"  #FIXME: Should only allow this after the appropriate target
			;;
	
		--workers)
			BUILD_COMMAND="$BUILD_COMMAND workers=1"
			shift
			;;

		--masters)
			BUILD_COMMAND="$BUILD_COMMAND masters=1"
			shift
			;;

		--cmd)
			# Note, -c is used for --channel
			cmd=
			shift 
			echo "$1" | grep -q "^-" || cmd="$1"
			[ "$cmd" ] && shift || cmd="get co" # Set default command here
	
			if [[ "$BUILD_COMMAND" =~ "ssh" ]]; then
				BUILD_COMMAND="$BUILD_COMMAND cmd='$cmd'"
				echo_debug $0: BUILD_COMMAND=$BUILD_COMMAND
			elif [[ "$BUILD_COMMAND" =~ "cmd" ]]; then
				BUILD_COMMAND="$BUILD_COMMAND cmd='$cmd'"
				echo_debug $0: BUILD_COMMAND=$BUILD_COMMAND
			else
				# Assume it's a kube command by default
				BUILD_COMMAND="$BUILD_COMMAND cmd cmd='$cmd'"
				echo_debug $0: BUILD_COMMAND=$BUILD_COMMAND
			fi
			;;

		create) # In global context
			shift
			;;

		--dir | -d)
			echo_debug update_global_conf
			update_global_conf
	
			# If there are commands/targets to execute in the CWD, do it...
			BUILD_COMMAND=$(echo "$BUILD_COMMAND" | tr -s " " | sed -E -e "s/^ //g" -e "s/ $//g")
			if [ "$BUILD_COMMAND" ]; then
				if [ "$DEBUG_ABA" ]; then
					echo_debug "In folder $PWD: Running make $BUILD_COMMAND"
					read -t 3 || true
					eval make $BUILD_COMMAND
				else
					# Eval used here as some variable may need evaluation from bash
					eval make -s $BUILD_COMMAND
				fi
	
				# Remove already executed targets 
				BUILD_COMMAND=
			fi
	
			# If no directory path provided, assume it's ".", i.e. $ABA_ROOT/.
			# If dir path arg privided, then shift
			provided_dir="$2"
			if [[ "$2" =~ ^- || -z "$2" ]]; then
				provided_dir=.
				context=global
			else
				[ "$2" = "." ] && context=global || context=$2
				shift
			fi
	
			# FIXME: Simplify this!  Put all static files into well-known location?
			#[ ! "$2" ] && echo "Error: directory path expected after option $1" >&2 && exit 1
			[ ! -e "$ABA_ROOT/$provided_dir" ] && echo "Error: directory $ABA_ROOT/$provided_dir does not exist!" >&2 && exit 1
			[ ! -d "$ABA_ROOT/$provided_dir" ] && echo "Error: cannot change to $ABA_ROOT/$provided_dir: not a directory!" >&2 && exit 1
	
			WORK_DIR="$ABA_ROOT/$provided_dir"  # dir should always be relative from Aba repo's root dir
	
			echo_debug "$0: changing to \"$WORK_DIR\""
			cd "$WORK_DIR" || exit 
			shift
			echo_debug "$0: switching to context \"$context\""
			;;

		mirror) # In global context
			echo_debug eval update_global_conf
			eval update_global_conf

			context=mirror
			shift
			;;

		cluster) # In global context
			echo_debug eval update_global_conf
			eval update_global_conf

			context=cluster
			shift
			;;
		bundle) # In context global 
			echo_debug eval update_global_conf
			eval update_global_conf

			context=bundle
			shift
			;;
		-*)
			echo_red "Skipping unknown global argument [$1]" >&2
			# Contineu matching the others.... bundle, cluster, mirror etc
			#exit 1
			;;
		*)
			echo run: make $1 from $PWD
			make $1
			shift
			;;
		esac
		;;&  # This means continue matching

		# Finish global context #

	bundle) # Context 
		echo_debug "parsing in context bundle with args: $* in $PWD"

		case "$1" in
			--out | -o)
            			shift
            			if [ -n "$1" ]; then
                			export bundle_dest_path="$1"
					echo_debug bundle_dest_path=$bundle_dest_path
                			shift
            			else
                			echo_error "Error: $1 requires a file path or '-'"
            			fi
				;;
			--force | -f)
            			if [ "$1" = "true" ] || [ "$1" = "false" ]; then
                			export force="$1"
					echo_debug force=$force
                			shift
            			else
                			echo_error "Error: --force requires true or false"
            			fi
				;;
			cluster | mirror)
				update_bundle_conf
				context=$1
				;;
			-*)
				echo_warn "Unknown argument [$1] in after command: bundle"
				shift
				;;
			*)
				echo run: make $1 from $PWD
				make $1
				shift
				;;
		esac
		;;&  # This means continue matching

	cluster) # context 
		echo_debug "parsing in context cluster with args: $* in $PWD"

		case "$1" in
			--help | -h)
				cat $ABA_ROOT/others/help-cluster.txt

				exit 0
				;;

			--name | -n)
				[[ -z "$2" || "$2" =~ ^- ]] && echo_red "Error: Missing argument after option $1" >&2 && exit 1
				export name="$2"
				is_valid_dns_label $name
				shift 2
				echo_debug name=$name
				;;
			--type | -t)
				[[ -z "$2" || "$2" =~ ^- ]] && echo_red "Error: Missing argument after option $1" >&2 && exit 1
				case "$2" in
					sno|compact|standard)
						export type=$2
					;;
					*)
						echo_red "Error: Invalid type '$2'. Expected one of: sno, compact, standard." >&2
						exit 1
					;;
				esac
				shift 2
				echo_debug type=$type
				;;
			--api-vip | XXXXX)
				# If arg ip addr then replace value in cluster.conf
				# If arg missing remove from cluster.conf
				export api_vip=
				# If arg is available and not an opt
				if [[ -n $2 && $2 != -* ]]; then
					if [[ $2 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
						IFS=. read -r o1 o2 o3 o4 <<< "$2"
						if (( o1 <= 255 && o2 <= 255 && o3 <= 255 && o4 <= 255 )); then
							export api_vip=$2
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
	
				## If conf file is available, edit the value
				#if [ -f cluster.conf ]; then
				#	replace-value-conf -n api_vip -v "$api_vip" -f cluster.conf
				#else
				#	BUILD_COMMAND="$BUILD_COMMAND api_vip=$api_vip"
				#fi

				shift
				;;
			--ingress-vip | -YYYYY)
				# If arg ip addr replace value in cluster.conf
				# If arg missing remove from cluster.conf
				export ingress_vip=
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
				## If conf file is available, edit the value
				#if [ -f cluster.conf ]; then
				#	replace-value-conf -n ingress_vip -v "$ingress_vip" -f cluster.conf
				#	##echo done $*
				#else
				#	BUILD_COMMAND="$BUILD_COMMAND ingress_vip=$ingress_vip"
				#fi

				shift
				;;
			--starting-ip | -i)
				[[ -z "$2" || "$2" =~ ^- ]] && echo_red "Error: Missing argument after option $1" >&2 && exit 1
				# FIXME: check format
				export starting_ip="$2"
				shift 2
				echo_debug starting_ip=$starting_ip
				;;
			--step | -s)
				[[ -z "$2" || "$2" =~ ^- ]] && echo_red "Error: Missing argument after option $1" >&2 && exit 1
				export step="$2"
				shift 2
				echo_debug step=$step
				;;
			--ports | -p)
				shift
				export ports_vals=
				# While there is a valid arg (not an opt)...
				while [[ ! (-z "$1" || "$1" =~ ^-) ]]
				do
					[ "$ports_vals" ] && ports_vals="$ports_vals,$1" || ports_vals="$1"
					echo_debug ports_vals=$ports_vals
					shift	
				done
				echo_debug ports_vals=$ports_vals
				;;
			--int-connection | -I)
				# Optional argument: connection method (proxy|direct)
				export int_connection=

				# Check if next arg exists and is not another option (starting with '-')
				if [[ -n "$2" && "$2" != -* ]]; then
					case "$2" in
						proxy|p)
							int_connection="proxy"
							;;
						direct|d)
							int_connection="direct"
							;;
						*)
							echo_red "Error: Invalid argument [$2] after option '$1'. Expected one of: proxy, direct." >&2
							exit 1
							;;
					esac
					shift
				else
					# No argument provided — clear existing value in cluster.conf
					int_connection=""
				fi
				shift
				echo_debug int_connection=$int_connection
				;;
			--mmem | --master-memory)
				[[ "$2" =~ ^- || -z "$2" ]] && echo_red "Error: Missing argument after option $1" >&2 && exit 1
				if echo "$2" | grep -q -E '^[0-9]+$'; then
					export master_mem=$2
				else
					echo_red "$(basename $0): Error: no such option for command cluster: $1" >&2
					exit 1
				fi
				shift 2

				echo_debug master_mem=$master_mem
				;;
			--mcpu | --master-cpu)
				[[ "$2" =~ ^- || -z "$2" ]] && echo_red "Error: Missing argument after option $1" >&2 && exit 1
				if echo "$2" | grep -q -E '^[0-9]+$'; then
					export master_cpu_count=$2
				else
					echo_red "$(basename $0): Error: no such option for command cluster: $1" >&2
					exit 1
				fi
				shift 2
				echo_debug master_cpu_count=$master_cpu_count
				;;
			--wcpu | --worker-cpu)
				[[ "$2" =~ ^- || -z "$2" ]] && echo_red "Error: Missing argument after option $1" >&2 && exit 1
				if echo "$2" | grep -q -E '^[0-9]+$'; then
					export worker_cpu=$2
				#	if [ -f cluster.conf ]; then
				#		replace-value-conf -n worker_cpu -v $2 -f cluster.conf
				#	else
				#		BUILD_COMMAND="$BUILD_COMMAND worker_cpu_count=$2"
				#	fi
				#else
				#	echo_red "Argument invalid [$2] after option $1" >&2
				fi
				echo_debug worker_cpu=$worker_cpu
				shift 2
				;;
			--wmem | --worker-memory)
				[[ "$2" =~ ^- || -z "$2" ]] && echo_red "Error: Missing argument after option $1" >&2 && exit 1
				if echo "$2" | grep -q -E '^[0-9]+$'; then
					export worker_mem=$2
				#	if [ -f cluster.conf ]; then
				#		replace-value-conf -n worker_mem -v $2 -f cluster.conf
				#	else
				#		BUILD_COMMAND="$BUILD_COMMAND worker_mem=$2"
				#	fi
				#else
				#	echo_red "Argument invalid [$2] after option $1" >&2
				fi
				shift 2
				echo_debug worker_mem=$worker_mem
				;;
			--dir | -d)
				echo_debug update_cluster_conf
				update_cluster_conf
	
				# If there are commands/targets to execute in the CWD, do it...
				BUILD_COMMAND=$(echo "$BUILD_COMMAND" | tr -s " " | sed -E -e "s/^ //g" -e "s/ $//g")
				if [ "$BUILD_COMMAND" ]; then
					if [ "$DEBUG_ABA" ]; then
						echo_debug "In folder $PWD: Running make $BUILD_COMMAND"
						read -t 3 || true
						eval make $BUILD_COMMAND
					else
						# Eval used here as some variable may need evaluation from bash
						eval make -s $BUILD_COMMAND
					fi
		
					# Remove already executed targets 
					BUILD_COMMAND=
				fi
		
				# If no directory path provided, assume it's ".", i.e. $ABA_ROOT/.
				# If dir path arg privided, then shift
				provided_dir="$2"
				if [[ "$2" =~ ^- || -z "$2" ]]; then
					provided_dir=.
					context=global
				else
					[ "$2" = "." ] && context=global || context=$2
					shift
				fi
		
				# FIXME: Simplify this!  Put all static files into well-known location?
				#[ ! "$2" ] && echo_error "Error: directory path expected after option $1" >&2 && exit 1
				[ ! -e "$ABA_ROOT/$provided_dir" ] && echo_error "directory $ABA_ROOT/$provided_dir does not exist!"
				[ ! -d "$ABA_ROOT/$provided_dir" ] && echo_error "cannot change to $ABA_ROOT/$provided_dir: not a directory!"
		
				WORK_DIR="$ABA_ROOT/$provided_dir"  # dir should always be relative from Aba repo's root dir
		
				echo_debug "$0: changing to \"$WORK_DIR\""
				cd "$WORK_DIR" || exit 
				shift

				echo_debug "$0: switching to context \"$context\""
				;;
			mirror) # in cluster context
				echo_debug Switch to mirror context
				echo_debug Run eval update_cluster_conf
				eval update_cluster_conf
				# process aba.conf
				context=mirror
				shift
				cd ../mirror
				;;

			cluster) # in cluster context
				echo_debug ignore 
				:
				#mkdir -p $ABA_ROOT/$dir_path
				#cd $ABA_ROOT/$dir_path
				#context=cluster
				;;

			-*)
				echo_red "Unknown argument [$1] in after command: cluster" >&2
				exit 1
				;;
			*)
				echo run: make $1 from $PWD
				make $1
				shift
				;;

			esac

		## Process "cluster" command args ##

		;;&  # This means continue matching

	mirror) # Context
		echo_debug "parsing in context mirror with args: $* in $PWD"

		case "$1" in
		--mirror-hostname | -H)
			[[ "$2" =~ ^- || -z "$2" ]] && echo_red "Error: Missing argument after option $1" >&2 && exit 1
			# force will skip over asking to edit the conf file
			make -sC $ABA_ROOT/mirror mirror.conf force=yes
			replace-value-conf -n reg_host -v "$2" -f $ABA_ROOT/mirror/mirror.conf
			shift 2
			;;
		--reg-ssh-key | -k)
			# The ssh key used to access the linux registry host
			# If no value, remove from mirror.conf
			#[[ "$2" =~ ^- || -z "$2" ]] && echo_red "Error: Missing argument after option $1" >&2 && exit 1  # FIXME
			[[ "$2" =~ ^- || -z "$2" ]] && reg_ssh_key= || { reg_ssh_key=$2; shift; }
			# force will skip over asking to edit the conf file
			make -sC $ABA_ROOT/mirror mirror.conf force=yes
			replace-value-conf -n reg_ssh_key -v "$reg_ssh_key" -f $ABA_ROOT/mirror/mirror.conf
			shift
			;;
		--reg-ssh-user | -U)
			# The ssh username used to access the linux registry host
			# If no value, remove from mirror.conf
			#[[ "$2" =~ ^- || -z "$2" ]] && echo_red "Error: Missing argument after option $1" >&2 && exit 1  # FIXME
			[[ "$2" =~ ^- || -z "$2" ]] && reg_ssh_user_val= || { reg_ssh_user_val=$2; shift; }
			# force will skip over asking to edit the conf file
			make -sC $ABA_ROOT/mirror mirror.conf force=yes
			replace-value-conf -n reg_ssh_user -v "$reg_ssh_user_val" -f $ABA_ROOT/mirror/mirror.conf
			shift
			;;
		--data-dir)
			[[ "$2" =~ ^- || -z "$2" ]] && echo_red "Error: Missing argument after option $1" >&2 && exit 1
			# force will skip over asking to edit the conf file
			make -sC $ABA_ROOT/mirror mirror.conf force=yes
			replace-value-conf -n data_dir -v "$2" -f $ABA_ROOT/mirror/mirror.conf
			shift 2
			;;
		--reg-user)
			# The username used to access the mirror registry 
			[[ "$2" =~ ^- || -z "$2" ]] && echo_red "Error: Missing argument after option $1" >&2 && exit 1
			# force will skip over asking to edit the conf file
			make -sC $ABA_ROOT/mirror mirror.conf force=yes
			replace-value-conf -n reg_user -v "$2" -f $ABA_ROOT/mirror/mirror.conf
			shift 2
			;;
		--reg-password)
			# The password used to access the mirror registry 
			# Add a password in ='password'
			#[[ "$2" =~ ^- || -z "$2" ]] && echo_red "Error: Missing argument after option $1" >&2 && exit 1
			[[ "$2" =~ ^- || -z "$2" ]] && reg_pw_value= || { reg_pw_value="$2"; shift; }
			# force will skip over asking to edit the conf file
			make -sC $ABA_ROOT/mirror mirror.conf force=yes
			replace-value-conf -n reg_pw -v "'$reg_pw_value'" -f $ABA_ROOT/mirror/mirror.conf
			shift
			;;
		--reg-path)
			[[ "$2" =~ ^- || -z "$2" ]] && echo_red "Error: Missing argument after option $1" >&2 && exit 1
			# force will skip over asking to edit the conf file
			make -sC $ABA_ROOT/mirror mirror.conf force=yes
			replace-value-conf -n reg_path -v "$2" -f $ABA_ROOT/mirror/mirror.conf
			shift 2
			;;
		--data-disk | -dd)
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
			;;
		cluster)  # In mirror context
			update_mirror_conf
			context=cluster
			cd $ABA_ROOT  # Don't knoe the dir to go to
			shift
			;;
		mirror)  # In mirror context
			:
			shift
			;; # repeated mirror, ignore
		-*)
			echo "Unknown argument [$1] in after command: mirror" >&2
			exit 1
			;;
		*)
			echo run: make $1 from $PWD
			make $1
			shift
			;;
		esac

#	clusterOLD) # Context
#		case "$1" in
#
#
#		mirror)
#			update_cluster_conf
#			context="mirror"
#			;;
#		cluster)
#			:
#			;; # repeated cluster, ignore
#		*)
#			# Check is $1 starts with a - -> Error
#			#if $1 mirror|cluster then call eval update_$1_conf()
#			if [[ "$1" =~ ^(mirror|cluster)$ ]]; then
#				eval "update_${1}_conf"
#				context="$1"
#			else
#				echo "Unknown cluster argument: $1" >&2 
#			fi
#			;;
#		esac # End cluster options
#		;;
#	*)
#		#echo_red "Error: incorrect option [$1] in context [$context]" >&2
#		#exit 
#		:
#		;;
##	*)
#		echo "\$\* = $*" >&2
#
#		if echo "$1" | grep -q "^-"; then
#			echo_red "$(basename $0): Error: no such option $1" >&2
##			exit 1
#		else
#			#if [ "$1" = "cluster" ]; then
#			#	cur_target=$1
#			#	# Do not append "cluster" to $BUILD_COMMAND
#			#else
#				# Assume any other args are "commands", e.g. 'cluster', 'verify', 'mirror', 'ssh', 'cmd' etc 
#				# Gather options and args not recognized above and pass them to "make"... yes, we're using make! 
#			cur_target=$1
#			BUILD_COMMAND="$BUILD_COMMAND $1"
#			echo_debug $0: Command added: BUILD_COMMAND=$BUILD_COMMAND
#		fi
#		shift 

#		echo_debug "$0: BUILD_COMMAND=$BUILD_COMMAND"
#	;;

	esac # End contaxt case
	echo_debug "End of loop Args = $*"
done

echo_debug while loop done

# --- Process final context at the end ---
case "$context" in
	cluster) update_cluster_conf ;;
	global) update_global_conf ;;
	mirror) update_mirror_conf ;;
	bundle) update_bundle_conf ;;
esac

echo_debug Parsing args complete

############ NEW #########

#while [ "$*" ] 
#do
#done

echo_debug $0: interactive_mode=[$interactive_mode]

# Sanitize $BUILD_COMMAND
BUILD_COMMAND=$(echo "$BUILD_COMMAND" | tr -s " " | sed -E -e "s/^ //g" -e "s/ $//g")

echo_debug "$0: ABA_ROOT=[$ABA_ROOT]" 
echo_debug "$0: BUILD_COMMAND=[$BUILD_COMMAND]" 

# We want interactive mode if aba is running at the top of the repo and without any args
[ ! "$BUILD_COMMAND" -a "$ABA_ROOT" = "." ] && interactive_mode=1

if [ ! "$interactive_mode" ]; then
	# eval is needed here since $BUILD_COMMAND should not be evaluated/processed (it may have ' or " in it)
	# Only run make if there's a target
	if [ "$BUILD_COMMAND" ]; then
		echo_debug "$0: Running: \"make $BUILD_COMMAND\" from dir $PWD"

		[ "$DEBUG_ABA" ] && eval make $BUILD_COMMAND || eval make -s $BUILD_COMMAND
	fi

	exit 
fi

##################################################################
# We don't want interactive mode if there were args in the command
#[ "$interactive_mode_none" ] && echo Exiting ... >&2 && exit 
##[ "$interactive_mode_none" ]                          && exit 

# Change to the top level repo directory
cd $ABA_ROOT


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
		#echo_cyan "OpenShift update channel is defined in aba.conf as '$ocp_channel'."
		echo_cyan "OpenShift update channel is set to '$ocp_channel' in aba.conf."
	else

		echo_white -n "Checking Internet connectivity ..."
		if ! release_text=$(curl -f --connect-timeout 20 --retry 8 -sSL https://mirror.openshift.com/pub/openshift-v4/$arch_sys/clients/ocp/stable/release.txt); then
			[ "$TERM" ] && tput el1 && tput cr
			echo_red "Cannot access https://mirror.openshift.com/.  Ensure you have Internet access to download the required images." >&2
			echo_red "To get started with Aba run it on a connected workstation/laptop with Fedora, RHEL or Centos Stream and try again." >&2

			exit 1
		fi

		[ "$TERM" ] && tput el1 && tput cr

		while true; do
			echo_cyan -n "Which OpenShift update channel do you want to use? (c)andidate, (f)ast or (s)table [s]: "
			read -r ans
			case "$ans" in
				""|"s"|"S")
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
		echo_cyan "'ocp_channel' set to '$ocp_channel' in aba.conf"

		#### chan=$ocp_channel # Used below
	fi

	sleep 0.3

	##############################################################################################################################
	# Determine OCP version 

	if [ "$ocp_version" ]; then
		#echo_cyan "OpenShift version is defined in aba.conf as '$ocp_version'."
		echo_cyan "OpenShift version is set to '$ocp_version' in aba.conf."
	else
		##############################################################################################################################
		# Fetch release.txt

		echo_white -n "Fetching available versions (please wait!) ..."

		echo_debug "Looking up release at https://mirror.openshift.com/pub/openshift-v4/$arch_sys/clients/ocp/$ocp_channel/release.txt"

		if ! release_text=$(curl -f --connect-timeout 30 --retry 8 -sSL https://mirror.openshift.com/pub/openshift-v4/$arch_sys/clients/ocp/$ocp_channel/release.txt); then
			[ "$TERM" ] && tput el1 && tput cr
			echo_red "Failed to access https://mirror.openshift.com/pub/openshift-v4/$arch_sys/clients/ocp/$ocp_channel/release.txt" >&2

			exit 1
		fi

		## Get the latest stable OCP version number, e.g. 4.14.6
		channel_ver=$(echo "$release_text" | grep -E -o "Version: +[0-9]+\.[0-9]+\.[0-9]+" | awk '{print $2}')
		default_ver=$channel_ver

		echo_debug "Looking up previous version at using fetch_previous_version $ocp_channel $arch_sys"

		channel_ver_prev=$(fetch_previous_version "$ocp_channel" "$arch_sys")

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
					if curl -f --connect-timeout 60 --retry 8 -sSL -o /dev/null -w "%{http_code}\n" $url| grep -q ^200$; then
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
			echo $target_ver | grep -E -q "^[0-9]+\.[0-9]+$" && target_ver=$(fetch_latest_z_version "$ocp_channel" "$target_ver" "$arch_sys")
		done

		# Update the conf file
		replace-value-conf -q -n ocp_version -v $target_ver -f aba.conf
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
		echo_yellow Instructions for synchronizing images directly from the Internet to a mirror registry
		echo 
		echo_white "Set up the mirror registry and sync it with the necessary container images."
		echo
		echo_white "To store container images, Aba can install the Quay mirror appliance or you can use an existing container registry."
		echo
		echo_white "Run:"
		echo_white "  aba -d mirror install              # to configure an existing registry or install Quay."
		echo_white "  aba -d mirror sync --retry <count> # to synchronize all container images - from the Internet - into your registry."
		echo
		echo_white "Or run:"
		echo_white "  aba -d mirror sync --retry <count> # to complete both actions and ensure any image synchronization issues are retried."
		echo
		echo_white "  aba mirror --help                  # See for help."

		echo_white "Once the images are stored in the mirror registry, you can proceed with the OpenShift installation by following the instructions provided."
		echo

		exit 0
	fi

	echo 
	echo "Fully Connected"
	echo_white "Optionally, configure a proxy or use direct Internet access through NAT or a transparent proxy."
	echo
	echo_yellow Instructions for installing directly from the Internet
	echo
	echo_white "Example:"
	echo_white "aba cluster --name mycluster --type sno --starting-ip 10.0.1.203 --int-connection proxy"

	##echo_white "Run: aba cluster --name myclustername [--type <sno|compact|standard>] [--step <command>] [--starting-ip <ip>] [--api-vip <ip>] [--ingress-vip <ip>] [--int-connection <proxy|direct>]"
	echo_white "See aba cluster --help for more"
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


