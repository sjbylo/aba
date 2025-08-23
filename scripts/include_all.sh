# Code that all scripts need.  Ensure this script does not create any std output.
# Add any arg1 to turn off the below Error trap

# Check is sudo exists 
SUDO=
which sudo 2>/dev/null >&2 && SUDO=sudo

# Set up the arch vars
export arch_sys=$(uname -m)
export arch_short=amd64
[ "$arch_sys" = "aarch64" -o "$arch_sys" = "arm64" ] && export arch_short=arm64  # ARM
#[ "$arch_sys" = "x86_64" ]	&& export arch_short=amd64   # Intel

# ===========================
# Color Echo Functions
# ===========================

_color_echo() {
    local color="$1"; shift
    local text

    # Collect input from args or stdin
    if [ $# -gt 0 ]; then
        text="$*"
    else
        text="$(cat)"
    fi

    # Apply color only if stdout is a terminal and terminal supports >= 8 colors
    if [ -t 1 ] && [ "$(tput colors 2>/dev/null)" -ge 8 ]; then
        tput setaf "$color"
        echo -e "$text"
        tput sgr0
    else
        echo -e "$text"
    fi
}

# Standard 8 colors
echo_black()   { _color_echo 0 "$@"; }
echo_red()     { _color_echo 1 "$@"; }
echo_green()   { _color_echo 2 "$@"; }
echo_yellow()  { _color_echo 3 "$@"; }
echo_blue()    { _color_echo 4 "$@"; }
echo_magenta() { _color_echo 5 "$@"; }
echo_cyan()    { _color_echo 6 "$@"; }
echo_white()   { _color_echo 7 "$@"; }

# Bright colors (8–15)
echo_bright_black()   { _color_echo 8 "$@"; }
echo_bright_red()     { _color_echo 9 "$@"; }
echo_bright_green()   { _color_echo 10 "$@"; }
echo_bright_yellow()  { _color_echo 11 "$@"; }
echo_bright_blue()    { _color_echo 12 "$@"; }
echo_bright_magenta() { _color_echo 13 "$@"; }
echo_bright_cyan()    { _color_echo 14 "$@"; }
echo_bright_white()   { _color_echo 15 "$@"; }

# ===========================
# Demo (optional)
# ===========================
color_demo() {
    echo_black       "black"
    echo_red         "red"
    echo_green       "green"
    echo_yellow      "yellow"
    echo_blue        "blue"
    echo_magenta     "magenta"
    echo_cyan        "cyan"
    echo_white       "white"
    echo_bright_black   "bright black (gray)"
    echo_bright_red     "bright red"
    echo_bright_green   "bright green"
    echo_bright_yellow  "bright yellow"
    echo_bright_blue    "bright blue"
    echo_bright_magenta "bright magenta"
    echo_bright_cyan    "bright cyan"
    echo_bright_white   "bright white"
}

#####################

#echo_black()	{ [ "$TERM" ] && tput setaf 0; echo -e "$@"; [ "$TERM" ] && tput sgr0; }
#echo_red()	{ [ "$TERM" ] && tput setaf 1; echo -e "$@"; [ "$TERM" ] && tput sgr0; }
#echo_green()	{ [ "$TERM" ] && tput setaf 2; echo -e "$@"; [ "$TERM" ] && tput sgr0; }
#echo_yellow()	{ [ "$TERM" ] && tput setaf 3; echo -e "$@"; [ "$TERM" ] && tput sgr0; }
#echo_blue()	{ [ "$TERM" ] && tput setaf 4; echo -e "$@"; [ "$TERM" ] && tput sgr0; }
#echo_magenta()	{ [ "$TERM" ] && tput setaf 5; echo -e "$@"; [ "$TERM" ] && tput sgr0; }
#echo_cyan()	{ [ "$TERM" ] && tput setaf 6; echo -e "$@"; [ "$TERM" ] && tput sgr0; }
#echo_white()	{ [ "$TERM" ] && tput setaf 7; echo -e "$@"; [ "$TERM" ] && tput sgr0; }

#cat_cyan()	{ [ "$TERM" ] && tput setaf 6; cat; [ "$TERM" ] && tput sgr0; }
#cat_red()	{ [ "$TERM" ] && tput setaf 1; cat; [ "$TERM" ] && tput sgr0; }

cat_cyan()	{ echo_cyan; }
cat_red()	{ echo_red; }

####################

if ! [[ "$PATH" =~ "$HOME/bin:" ]]; then
	[ "$DEBUG_ABA" ] && echo "$0: Adding $HOME/bin to \$PATH for user $(whoami)" >&2
	PATH="$HOME/bin:$PATH"
fi

umask 077

#if [ ! "$tmp_dir" ]; then
#	export tmp_dir=$(mktemp -d /tmp/.aba.$(whoami).XXXX)
#	mkdir -p $tmp_dir 
#	cleanup() {
#		[ "$DEBUG_ABA" ] && echo "$0: Cleaning up temporary directory [$tmp_dir] ..." >&2
#		rm -rf "$tmp_dir"
#	}
#	
#	# Set up the trap to call cleanup on script exit or termination
#	trap cleanup EXIT
#fi

# Function to display an error message and the last executed command
show_error() {
	local exit_code=$?
	echo 
	echo_red "Script error: " >&2
	echo_red "Error occurred in command: '$BASH_COMMAND'" >&2
	echo_red "Error code: $exit_code" >&2

	exit $exit_code
}

# Set the trap to call the show_error function on ERR signal
[ ! "$1" ] && trap 'show_error' ERR


normalize-aba-conf() {
	# Normalize or sanitize the config file
	# Remove all chars from lines with <white-space>#<anything>
	# Remove all white-space lines
	# Remove all leading and trailing white-space
	# Correct ask=? which must be either =1 or = (empty)
	# Extract machine_network and prefix_length from the CIDR notation
	# Ensure only one arg after 'export'
	# Prepend "export "
	[ ! -s aba.conf ] && echo "ask=true" && return 0  # if aba.conf is missing, output a safe default, "ask=true"

	cat aba.conf | \
		sed -E	\
			-e "s/^\s*#.*//g" \
			-e '/^[ \t]*$/d' -e "s/^[ \t]*//g" -e "s/[ \t]*$//g" \
			-e "s/ask=0\b/ask=/g" -e "s/ask=false/ask=/g" \
			-e "s/ask=1\b/ask=true/g" \
			-e "s/verify_conf=0\b/verify_conf=/g" -e "s/verify_conf=false/verify_conf=/g" \
			-e "s/verify_conf=1\b/verify_conf=true/g" \
			-e 's#(machine_network=[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/#\1\nprefix_length=#g' | \
		awk '{print $1}' | \
		sed	-e "s/^/export /g";

}

verify-aba-conf() {
	[ ! "$verify_conf" ] && return 0
	[ ! -s aba.conf ] && return 0

	local ret=0
	local REGEX_VERSION='[0-9]+\.[0-9]+\.[0-9]+'
	local REGEX_BASIC_DOMAIN='^[A-Za-z0-9.-]+\.[A-Za-z]{1,}$'

	echo $ocp_version | grep -q -E $REGEX_VERSION || { echo_red "Error: ocp_version incorrectly set or missing in aba.conf" >&2; ret=1; }
	echo $ocp_channel | grep -q -E "fast|stable|candidate|eus" || { echo_red "Error: ocp_channel incorrectly set or missing in aba.conf" >&2; ret=1; }
	echo $platform    | grep -q -E "bm|vmw" || { echo_red "Error: platform incorrectly set or missing in aba.conf: [$platform]" >&2; ret=1; }
	[ ! "$pull_secret_file" ] && { echo_red "Error: pull_secret_file missing in aba.conf" >&2; ret=1; }

	if [ "$op_sets" ]; then
		echo $op_sets | grep -q -E "^[a-z,]+" || { echo_red "Error: op_sets invalid in aba.conf: [$op_sets]" >&2; ret=1; }
		for f in $(echo $op_sets | tr , " ")
		do
			test -s templates/operator-set-$f || { echo_red "Error: No such operator set [templates/operator-set-$f]!" >&2; ret=1; }
		done
	fi

	if [ "$ops" ]; then
		echo $ops | grep -q -E "^[a-z,]+" || { echo_red "Error: ops invalid in aba.conf: [$ops]" >&2; ret=1; }
	fi

	# Check for a domain name in less strict way
	#[ "$domain" ] && ! echo $domain | grep -q -E '^[A-Za-z0-9.-]+\.[A-Za-z]{1,}$' && { echo_red "Error: domain is invalid in aba.conf [$domain]" >&2; ret=1; }
	[ "$domain" ] && ! echo $domain | grep -q -E "$REGEX_BASIC_DOMAIN" && { echo_red "Error: domain is invalid in aba.conf [$domain]" >&2; ret=1; }

	# Check for ip addr
	[ "$machine_network" ] && ! echo $machine_network | grep -q -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' && { echo_red "Error: machine_network is invalid in aba.conf" >&2; ret=1; }
	# Check for number between 0 and 32
	[ "$prefix_length" ] && ! echo $prefix_length | grep -q -E '^([0-9]|[1-2][0-9]|3[0-2])$' && { echo_red "Error: machine_network is invalid in aba.conf" >&2; ret=1; }
	# Check for comma separated list of either IPs or domains/hostnames
	[ "$ntp_servers" ] && ! echo $ntp_servers | grep -q -E '^([A-Za-z0-9.-]+|\b([0-9]{1,3}\.){3}[0-9]{1,3}\b)(,([A-Za-z0-9.-]+|\b([0-9]{1,3}\.){3}[0-9]{1,3}\b))*$' && \
			{ echo_red "Error: ntp_servers is invalid in aba.conf [$ntp_servers]" >&2; ret=1; }

	REGEX='^(([A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,})|([A-Za-z0-9-]+)|([0-9]{1,3}(\.[0-9]{1,3}){3}))(,(([A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,})|([A-Za-z0-9-]+)|([0-9]{1,3}(\.[0-9]{1,3}){3})))*$'
	#[ "$dns_servers" ] && echo $dns_servers | grep -q -E '^([0-9]{1,3}\.){3}[0-9]{1,3}(,([0-9]{1,3}\.){3}[0-9]{1,3})*$' || { echo_red "Error: dns_servers is invalid in aba.conf [$dns_servers]" >&2; ret=1; }
	[ "$dns_servers" ] && ! echo $dns_servers | grep -q -E $REGEX && { echo_red "Error: dns_servers is invalid in aba.conf [$dns_servers]" >&2; ret=1; }
	[ "$next_hop_address" ] && ! echo $next_hop_address | grep -q -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' && { echo_red "Error: next_hop_address is invalid in aba.conf [$next_hop_address]" >&2; ret=1; }

	echo $oc_mirror_version | grep -q -E '^v[12]$' || { echo_red "Error: oc_mirror_version is invalid in aba.conf [$oc_mirror_version]" >&2; ret=1; }

	return $ret
}

normalize-mirror-conf()
{
	# Normalize or sanitize the config file
	# Ensure any ~/ is masked, e.g. \~/ ('cos ~ may need to be expanded on remote host)
	# Ensure reg_ssh_user has a value
	# Ensure only one arg after 'export'   # Note that all values are now single string, e.g. single value or comma-sep list (one string)
	# Verify oc_mirror_version exists and is somewhat correct and defaults to v1
	# Prepend "export "
	# reg_path must not start with a /, if so, remove it
	# Force tls_verify=true 

	[ ! -s mirror.conf ] &&                                                              return 0

	(
		cat mirror.conf | \
			sed -E	-e "s/^\s*#.*//g" \
				-e "s/^reg_ssh_user=([[:space:]]+|$)/reg_ssh_user=$(whoami) /g" \
				-e '/^[ \t]*$/d' -e "s/^[ \t]*//g" -e "s/[ \t]*$//g" \
				-e 's/^reg_root=~/reg_root=\\~/g' \
				-e 's/^oc_mirror_version=[^v].*/oc_mirror_version=v1/g' \
				-e 's/^oc_mirror_version=v[^12].*/oc_mirror_version=v1/g' \
				-e 's#^reg_path=/#reg_path=#g' \
				| \
			awk '{print $1}' | \
			sed	-e "s/^/export /g"

		# Append always
		echo export tls_verify=true
	)

	# FIXME: delete
	#		-e "s/^tls_verify=0\b/tls_verify= /g" -e "s/tls_verify=false/tls_verify= /g" \
	#		-e "s/^tls_verify=1\b/tls_verify=true /g" \
}

verify-mirror-conf() {
	[ ! "$verify_conf" ] && return 0
	[ ! -s mirror.conf ] && return 0

	local ret=0

	#echo $reg_host | grep -q -E '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]{2,})+$' || { echo_red "Error: reg_host is invalid in mirror.conf [$reg_host]" >&2; ret=1; }
	echo $reg_host | grep -q -E '^[A-Za-z0-9.-]+\.[A-Za-z]{1,}$' || { echo_red "Error: reg_host is invalid in mirror.conf [$reg_host]" >&2; ret=1; }
	[ ! "$reg_host" ] && echo_red "Error: reg_host is missing in mirror.conf" >&2 && ret=1

	[ ! "$reg_ssh_user" ] && echo_red "Error: reg_ssh_user not defined!" >&2 && ret=1   # This should never happen as the user name (whoami) is added above if its empty.

	return $ret
}

normalize-cluster-conf()
{
	# Normalize or sanitize the config file
	# Remove all chars from lines with <white-space>#<anything>
	# Remove all white-space lines
	# Remove all leading and trailing white-space
	# Extract machine_network and prefix_length from the CIDR notation
	# Ensure only one arg after 'export'
	# Prepend "export "
	# Adjust new int_connection value for compatibility

	[ ! -s cluster.conf ] &&                                                               return 0

	cat cluster.conf | \
		sed -E	-e "s/^\s*#.*//g" \
			-e '/^[ \t]*$/d' -e "s/^[ \t]*//g" -e "s/[ \t]*$//g" \
			-e 's#(machine_network=[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/#\1\nprefix_length=#g' \
			-e 's/^int_connection=none/int_connection= /g' | \
		awk '{print $1}' | \
		sed -e "s/^/export /g";

	# Add any missing default values, mainly for backwards compat.
	grep -q ^hostPrefix= cluster.conf	|| echo export hostPrefix=23
	grep -q ^port0= cluster.conf 		|| echo export port0=eth0
	# If int_connection does not exist or has no value and proxy is available, then output int_connection=proxy
	grep -q "^int_connection=\S*" cluster.conf || { grep -E -q "^proxy=\S" cluster.conf	&& echo export int_connection=proxy; }
}

verify-cluster-conf() {
	[ ! "$verify_conf" ] && return 0
	[ ! -s cluster.conf ] && return 0

	local ret=0
	local REGEX_BASIC_DOMAIN='^[A-Za-z0-9.-]+\.[A-Za-z]{1,}$'

	echo $cluster_name | grep -q -E -i '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$' || { echo_red "Error: cluster_name incorrectly set or missing in cluster.conf" >&2; ret=1; }

	#echo $base_domain | grep -q -E '^[A-Za-z0-9.-]+\.[A-Za-z]{1,}$' || { echo_red "Error: base_domain is invalid in cluster.conf [$base_domain]" >&2; ret=1; }
	echo $base_domain | grep -q -E "$REGEX_BASIC_DOMAIN" || { echo_red "Error: base_domain is invalid in cluster.conf [$base_domain]" >&2; ret=1; }

	# Note that machine_network is split into machine_network (ip) and prefix_length (4 bit number).
	echo $machine_network | grep -q -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || { echo_red "Error: machine_network is invalid in cluster.conf" >&2; ret=1; }
	echo $prefix_length | grep -q -E '^([0-9]|[1-2][0-9]|3[0-2])$' || { echo_red "Error: machine_network is invalid in cluster.conf" >&2; ret=1; }

	echo $starting_ip | grep -q -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || { echo_red "Error: starting_ip is invalid in cluster.conf. Try using --starting-ip option." >&2; ret=1; }

	echo $hostPrefix | grep -q -E '^([0-9]|[1-2][0-9]|3[0-2])$' || { echo_red "Error: hostPrefix is invalid in cluster.conf" >&2; ret=1; }

	echo $master_prefix | grep -q -E '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$' || { echo_red "Error: master_prefix is invalid in cluster.conf" >&2; ret=1; }
	echo $worker_prefix | grep -q -E '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$' || { echo_red "Error: worker_prefix is invalid in cluster.conf" >&2; ret=1; }

	echo $num_masters | grep -q -E '^[0-9]+$' || { echo_red "Error: num_masters is invalid in cluster.conf" >&2; ret=1; }
	echo $num_workers | grep -q -E '^[0-9]+$' || { echo_red "Error: num_workers is invalid in cluster.conf" >&2; ret=1; }

	REGEX='^(([A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,})|([A-Za-z0-9-]+)|([0-9]{1,3}(\.[0-9]{1,3}){3}))(,(([A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,})|([A-Za-z0-9-]+)|([0-9]{1,3}(\.[0-9]{1,3}){3})))*$'
	echo $dns_servers | grep -q -E $REGEX || { echo_red "Error: dns_servers is invalid in cluster.conf [$dns_servers]" >&2; ret=1; }

	echo $next_hop_address | grep -q -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || { echo_red "Error: next_hop_address is invalid in cluster.conf" >&2; ret=1; }

	# The next few values are all optional
	[ "$port0" ] && ! echo $port0 | grep -q -E '^[a-zA-Z0-9_.-]+$' && { echo_red "Error: port0 is invalid in cluster.conf: [$port0]" >&2; ret=1; }
	[ "$port1" ] && ! echo $port1 | grep -q -E '^[a-zA-Z0-9_.-]+$' && { echo_red "Error: port1 is invalid in cluster.conf: [$port1]" >&2; ret=1; }

	[[ -z "$vlan" || ( "$vlan" =~ ^[0-9]+$ && vlan -ge 1 && vlan -le 4094 ) ]] || { echo_red "Error: vlan is invalid in cluster.conf: [$vlan]" >&2; ret=1; }

	[ "$int_connection" ] && { echo $int_connection | grep -q -E "none|proxy|direct" || { echo_red "Error: int_connection incorrectly set [$int_connection] in cluster.conf" >&2; ret=1; }; }

	# Match a mac *prefix*, e.g. 00:52:11:00:xx: (x is replaced by random number)
	[ "$mac_prefix" ] && ! echo $mac_prefix | grep -q -E '^([0-9A-Fa-fXx]{2}:){5}$' && { echo_red "Error: mac_prefix is invalid in cluster.conf: [$mac_prefix]" >&2; ret=1; }

	[ "$master_cpu_count" ] && ! echo $master_cpu_count | grep -q -E '^[0-9]+$' && { echo_red "Error: master_cpu_count is invalid in cluster.conf: [$master_cpu_count]" >&2; ret=1; }
	[ "$master_mem" ] && ! echo $master_mem | grep -q -E '^[0-9]+$' && { echo_red "Error: master_mem is invalid in cluster.conf: [$master_cpu_count]" >&2; ret=1; }

	[ "$worker_cpu_count" ] && ! echo $worker_cpu_count | grep -q -E '^[0-9]+$' && { echo_red "Error: worker_cpu_count is invalid in cluster.conf: [$worker_cpu_count]" >&2; ret=1; }
	[ "$worker_mem" ] && ! echo $worker_mem | grep -q -E '^[0-9]+$' && { echo_red "Error: worker_mem is invalid in cluster.conf: [$worker_cpu_count]" >&2; ret=1; }

	[ "$data_disk" ] && ! echo $data_disk | grep -q -E '^[0-9]+$' && { echo_red "Error: data_disk is invalid in cluster.conf: [$data_disk]" >&2; ret=1; }

	return $ret
}

normalize-vmware-conf()
{
        # Normalize or sanitize the config file
	# Determine if ESXi or vCenter
	# Ensure only one arg after 'export'
	# Prepend "export "
	# Convert VMW_FOLDER to VC_FOLDER for backwards compat!

	# Removed this line since GOVC_PASSWORD='<my password here>' was getting cut and failing to parse
	#awk '{print $1}' | \

	[ ! -s vmware.conf ] &&                                                              return 0  # vmware.conf can be empty

        vars=$(cat vmware.conf | \
		sed -E	-e "s/^\s*#.*//g" \
			-e '/^[ \t]*$/d' -e "s/^[ \t]*//g" -e "s/[ \t]*$//g" \
			-e "s/^VMW_FOLDER=/VC_FOLDER=/g" | \
                sed	-e "s/^/export /g")
	eval "$vars"
	# Detect if ESXi is used and set the VC_FOLDER that ESXi prefers, and ignore GOVC_DATACENTER and GOVC_CLUSTER. 
        if govc about | grep -q "^API type:.*HostAgent$"; then
		echo "$vars" | sed -e "s#VC_FOLDER.*#VC_FOLDER=/ha-datacenter/vm#g" -e "/GOVC_DATACENTER/d" -e "/GOVC_CLUSTER/d"
		echo export VC=
	else
		echo "$vars"
		echo export VC=1
	fi
}

install_rpms() {
	# Try to install the RPMs only if they are missing
	local rpms_to_install=

	for rpm in $@
	do
		# Check if each rpm is already installed.  Don't run dnf unless we have to.
		rpm -q --quiet $rpm || rpms_to_install="$rpms_to_install $rpm" 
	done

	# Add the correct python3 package name depending on rhel8 or rhel9
	rpm -q --quiet python3 || rpm -q --quiet python36 || rpms_to_install=" python3$rpms_to_install"

	if [ "$rpms_to_install" ]; then
		echo "Installing required rpms:$rpms_to_install (logging to .dnf-install.log). Please wait!" >&2  # send to stderr so this can be seen during "aba bundle -o -"
		if ! $SUDO dnf install $rpms_to_install -y >> .dnf-install.log 2>&1; then
			echo_red "Warning: an error occurred during rpm installation. See the logs at .dnf-install.log." >&2
			echo_red "If dnf cannot be used to install rpm packages, please install the following packages manually and try again!" >&2
			echo_magenta $rpms_to_install

			return 1
		fi
	fi
}

ask() {
	source <(normalize-aba-conf)  # if aba.conf does not exist, this outputs 'ask=true' to be on the safe side.
	[ ! "$ask" ] && return 0  # reply "default reply"

	# Default reply is 'yes' (or 'no') and return 0
	yn_opts="(Y/n)"
	def_response=y
	[ "$1" == "-n" ] && def_response=n && yn_opts="(y/N)" && shift
	[ "$1" == "-y" ] && def_response=y && yn_opts="(Y/n)" && shift
	timer=
	[ "$1" == "-t" ] && timer="-t $1" && shift && shift 

	echo_yellow -n "$@? $yn_opts: "
	read $timer yn

	# Return default response, 0
	[ ! "$yn" ] && return 0

	[ "$def_response" == "y" ] && [ "$yn" == "y" -o "$yn" == "Y" ] && return 0
	[ "$def_response" == "n" ] && [ "$yn" == "n" -o "$yn" == "N" ] && return 0

	# return "non-default" response 
	return 1

#	if [ "$def_response" == "y" ]; then
#		[ ! "$yn" -o "$yn" == "y" -o "$yn" == "Y" ] && return 0
#	else
#		# Return default response
#		[ ! "$yn" ] && return 0
#		[ "$yn" == "n" -o "$yn" == "N" ] && return 0 
#		[ "$yn" != "y" -a "$yn" != "Y" ] && return 0
#	fi
#
#	# return "non-default" response 
#	return 1
}

edit_file() {
	conf_file=$1
	shift
	msg="$*"

	if [ "$ask" ]; then
		if [ ! "$editor" -o "$editor" == "none" ]; then
			echo
			echo_yellow "The file '$PWD/$conf_file' has been created. Please edit/verify it & continue/try again."

			return 1
		else
			ask "$msg" || return 1
			$editor $conf_file
		fi
	else
		#echo_yellow "$msg? (auto answered, ask=$ask)"
		echo_yellow "'$conf_file' has been created for you (skipping edit since ask=false in aba.conf)."
	fi

	return 0
}

try_cmd() {
	# Run a command, if it fails, try again after 'pause' seconds
	# Usage: try_cmd [-q] <pause> <backoff> <total>
	local quiet=
	[ "$1" = "-q" ] && local quiet=1 && local out=">/dev/null 2>&1" && shift
	local pause=$1; shift		# initial pause time in sec
	local backoff=$1; shift		# add backoff time to pause time
	local total=$1; shift		# total number of tries

	local count=1

	[ ! "$quiet" ] && echo_cyan "Attempt $count/$total of command: \"$*\""

	#echo DEBUG: eval "$*" "$out"
	#while ! eval $* $out
	echo  >>.cmd.out 
	echo cmd $* >>.cmd.out 
	while ! eval $* >>.cmd.out 2>&1
	do
		if [ $count -ge $total ]; then
			[ ! "$quiet" ] && echo_red "Giving up on command \"$*\"" >&2
			# Return non-zero
			return 1
		fi

		[ ! "$quiet" ] && echo Pausing $pause seconds ...
		sleep $pause

		let pause=$pause+$backoff
		let count=$count+1

		[ ! "$quiet" ] && echo_cyan "Attempt $count/$total of command: \"$*\""
		#echo DEBUG: eval "$*" "$out"
		echo cmd $* >>.cmd.out 
	done
}

# Function to check if a version is greater than another version
is_version_greater() {
    local version1=$1
    local version2=$2

    # Sort the versions
    local sorted_versions=$(printf "%s\n%s" "$version1" "$version2" | sort -V | tr "\n" "|")

    # Check if version1 is the last one in the sorted list
     [[ "$sorted_versions" != "$version1|$version2|" ]]
}

output_error() { echo_red "$@" >&2; }

longest_line() {
    # Calculate the longest line from stdin
    awk '{
        if (length($0) > max) {
            max = length($0)
            longest = $0
        }
    } END {
        print max
    }'
}

files_on_same_device() {
	# Check if two file paths were provided
	if [ "$#" -ne 2 ]; then
		echo "Usage: files_on_same_device <file_path1> <file_path2>"

		return 1
	fi

	# Get the device number for each file path using 'stat'
	DIR1=$(dirname "$1")
	DIR2=$(dirname "$2")

	DEV1=$(stat -c %d "$DIR1")
	DEV2=$(stat -c %d "$DIR2")

	# Compare the device numbers
	[ "$DEV1" == "$DEV2" ] && return 0 || return 1
}

fetch_latest_version() {
	# $1 must be one of 'stable', 'fast' or 'candidate'
	local chan=stable
	local REGEX_VERSION='[0-9]+\.[0-9]+\.[0-9]+'

	[ "$1" ] && chan=$1
	[ "$chan" = "eus" ] && chan=stable   # .../ocp/eus/release.txt does not exist. FIXME: Use oc-mirror for this instead of curl?
	rel=$(curl -f --connect-timeout 10 --retry 2 -sL https://mirror.openshift.com/pub/openshift-v4/$arch_sys/clients/ocp/$chan/release.txt) || return 1
	# Get the latest OCP version number, e.g. 4.14.6
	#ver=$(echo "$rel" | grep -E -o "Version: +[0-9]+\.[0-9]+\.[0-9]+" | awk '{print $2}')
	ver=$(echo "$rel" | grep -E -o "Version: +$REGEX_VERSION" | awk '{print $2}')
	[ "$ver" ] && echo $ver || return 1
}

fetch_previous_version() {
	# $1 must be one of 'stable', 'fast' or 'candidate'
	local chan=stable
	local REGEX_VERSION='[0-9]+\.[0-9]+\.[0-9]+'

	[ "$1" ] && chan=$1
	[ "$chan" = "eus" ] && chan=stable   # .../ocp/eus/release.txt does not exist. FIXME: Use oc-mirror for this instead of curl?
	rel=$(curl -f --connect-timeout 10 --retry 2 -sL https://mirror.openshift.com/pub/openshift-v4/$arch_sys/clients/ocp/$chan/release.txt) || return 1
	# Get the previous OCP version number, e.g. 4.14.6
	stable_ver=$(echo "$rel" | grep -E -o "Version: +$REGEX_VERSION" | awk '{print $2}')

	# Extract the previous stable point version, e.g. 4.13.23
	major_ver=$(echo $stable_ver | grep ^[0-9] | cut -d\. -f1)
	stable_ver_point=`expr $(echo $stable_ver | grep ^[0-9] | cut -d\. -f2) - 1`

	# We need oc-mirror!
	which oc-mirror 2>/dev/null >&2 || { echo Installing oc-mirror ... >&2; make -s -C $ABA_PATH/cli oc-mirror >&2; }

	#[ "$stable_ver_point" ] && stable_ver_prev=$(echo "$rel"| grep -oE "${major_ver}\.${stable_ver_point}\.[0-9]+" | tail -n 1)
	stable_ver_prev=$(oc-mirror list releases --channel=${chan}-${major_ver}.${stable_ver_point} 2>/dev/null | tail -1)  # This is better way to fetch the newest previous version!

	[ "$stable_ver_prev" ] && echo $stable_ver_prev || return 1

}

# Replace a value in a conf file, taking care of white-space and optional commented ("#") values
replace-value-conf() {
	# $1 file
	# $2 is name of value to change
	# $3 new value (optional)
	[ ! -s $1 ] && echo "Error: No such file: $PWD/$1" >&2 && exit 1
	[ ! "$2" ] && echo "Error: missing value!" >&2 && exit 1
	[ "$DEBUG_ABA" ] && echo "Replacing config value [$2] with [$3] in file: $1" >&2
	sed -i "s|^[# \t]*${2}=[^ \t#]*\(.*\)|${2}=${3}\1|g" $1
}

output_table() {
	num_cols=$1
	string="$2"

	# Convert string into an array
	mapfile -t lines <<< "$string"

	# Get total lines and calculate rows
	num_lines=${#lines[@]}
	num_rows=$(( (num_lines + num_cols - 1) / num_cols ))

	# Use awk to format into 3 aligned columns
	local o=$(awk -v rows="$num_rows" -v cols="$num_cols" -v lines="${lines[*]}" '
	BEGIN {
		split(lines, arr, " ");
		for (i = 1; i <= rows; i++) {
			for (j = i; j <= length(arr); j += rows) {
				printf "%s ", arr[j];
			}
			print "";
		}
	}' <<< "$string" | column -t --output-separator " | ")

	width=$(echo "$o" | longest_line)
	printf '=%.0s' $(seq 1 "$width")
	echo
	echo "$o"
	printf '=%.0s' $(seq 1 "$width")
	echo
}

process_args() {
	[ ! "$*" ] && return 0

	echo "$*" | grep -Eq '^([a-zA-Z_]\w*=?[^ ]*)( [a-zA-Z_]\w*=?[^ ]*)*$' || { echo_red "Error: invalid params [$*], not key=value pairs"; exit 1; }
	# eval all key value args
	#[ "$*" ] && . <(echo $* | tr " " "\n")  # Get $name, $type etc from here
	echo $* | tr " " "\n"  # Get $name, $type etc from here
}

# Track anonymous events run by any aba using name "$1" (optional)
aba-track() {
	# Note this tracker has only one counter: 'installed'
	#[ ! "$1" ] && return 0
	#[ ! "$ABA_TESTING" ] && ( curl --fail --connect-timeout 8 -X GET "https://api.counterapi.dev/v1/sjbylo/aba$1/up" >/dev/null 2>&1 & disown ) & disown
	[ ! "$ABA_TESTING" ] && ( curl --retry 3 --fail -s https://abacus.jasoncameron.dev/hit/bylo.de-aba/installed >/dev/null 2>&1 & disown ) & disown
}
