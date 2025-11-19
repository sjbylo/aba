# Code that all scripts need.  Ensure this script does not create any std output.
# Add any arg1 to turn off the below Error trap

# Strict mode:
# -e : exit immediately if a command fails
# -u : treat unset variables as an error
# -o pipefail : catch errors in any part of a pipeline
#set -euo pipefail
#set -o pipefail

BASE_NAME=$(basename "${BASH_SOURCE[0]}")  # Needed in case this file is sourced from int. bash shell

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
		n_opt=
		if [ "$1" = "-n" ]; then
			n_opt="-n"
			shift
		fi
		text="$*"
	else
		text="$(cat)"
	fi

	# Apply color only if stdout is a terminal and terminal supports >= 8 colors
	if [ -t 1 ] && [ "$(tput colors 2>/dev/null)" -ge 8 ] && [ ! "$PLAIN_OUTPUT" ]; then
		tput setaf "$color"
		echo -e $n_opt "$text"
		tput sgr0
	else
		echo -e $n_opt "$text"
	fi

	return 0
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
    echo_bright_black   "bright black (gray)"
    echo_red         "red"
    echo_bright_red     "bright red"
    echo_green       "green"
    echo_bright_green   "bright green"
    echo_yellow      "yellow"
    echo_bright_yellow  "bright yellow"
    echo_blue        "blue"
    echo_bright_blue    "bright blue"
    echo_magenta     "magenta"
    echo_bright_magenta "bright magenta"
    echo_cyan        "cyan"
    echo_bright_cyan    "bright cyan"
    echo_white       "white"
    echo_bright_white   "bright white"
}

#echo_error() {
#	echo_red "Error: $@" >&2
#	exit 1
#}

aba_info() {
	[ ! "$INFO_ABA" ] && return 0

	if [ "$1" = "-n" ]; then
		shift
		echo_white -n "[ABA] $@"
	else
		echo_white "[ABA] $@"
	fi
}

aba_info_ok() {
	if [ "$1" = "-n" ]; then
		shift
		echo_green -n "[ABA] $@"
	else
		echo_green "[ABA] $@"
	fi
}

echo_warn() {
	if [ "$1" = "-n" ]; then
		shift
		echo_red -n "Warning: $@" >&2
	else
		echo_red "Warning: $@" >&2
	fi
}

aba_debug() {
    local newline=1

    [ ! "$DEBUG_ABA" ] && return 0

    # Erase to col1 and return
    [ "$TERM" ] && tput el1 && tput cr

    # Detect and consume "-n" if it's the first argument
    if [[ "$1" == "-n" ]]; then
        newline=0
        shift
    fi

    local timestamp
    timestamp="$(date +%H:%M:%S)"

    if (( newline )); then
        echo_magenta    "[ABA_DEBUG] ${timestamp}: $*" >&2
    else
        echo_magenta -n "[ABA_DEBUG] ${timestamp}: $*" >&2
    fi
}

aba_abort() {
	local main_msg="$1"
	shift

	echo >&2

	# Main error message in red to stderr
	echo_red "[ABA] Error: $main_msg" >&2

	# Indented follow-up lines, also red, to stderr
	for line in "$@"; do
		echo_red "[ABA]        $line" >&2
	done
	echo >&2

	sleep 1

	# FIXME: Have a way to exit a diff. value
        exit 1
}

aba_warning() {
	local main_msg="$1"
	shift

#	echo >&2

	# Main error message in red to stderr
	echo_red "[ABA] Warning: $main_msg" >&2

	# Indented follow-up lines, also red, to stderr
	for line in "$@"; do
		echo_red "[ABA]          $line" >&2
	done

#	echo >&2

	sleep 1
}


####################

if ! [[ "$PATH" =~ "$HOME/bin:" ]]; then
	aba_debug "$0: Adding $HOME/bin to \$PATH for user $(whoami)" >&2
	PATH="$HOME/bin:$PATH"
fi

umask 077

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
#[ ! "$1" ] && trap 'show_error' ERR
# If no first argument is provided, set a trap for errors
[ -z "${1-}" ] && trap 'show_error' ERR

normalize-aba-conf() {
	# Normalize or sanitize the config file
	# Remove all chars from lines with <white-space>#<anything>
	# Remove all white-space lines
	# Remove all commends after just ONE "#" ->  's/^(([^"]*"[^"]*")*[^"]*)#.*/\1/' \
	# Remove all leading and trailing white-space
	# Remove all #commends except for pass="b#c" values -> 's/^(([^"]*"[^"]*")*[^"]*)#.*/\1/'
	# Correct ask=? which must be either =1 or = (empty)
	# Extract machine_network and prefix_length from the CIDR notation
	# Ensure only one arg after 'export'
	# Prepend "export "
	[ ! -s aba.conf ] && echo "ask=true" && return 0  # if aba.conf is missing, output a safe default, "ask=true"

	cat aba.conf | \
		sed -E	\
			-e "s/^\s*#.*//g" \
			-e '/^[ \t]*$/d' -e "s/^[ \t]*//g" -e "s/[ \t]*$//g" \
			-e "s/^(([^']*'[^']*')*[^']*)#.*$/\1/" \
			-e "s/ask=0\b/ask=/g" -e "s/ask=false/ask=/g" \
			-e "s/ask=1\b/ask=true/g" \
			-e "s/excl_platform=0\b/excl_platform=/g" -e "s/excl_platform=false/excl_platform=/g" \
			-e "s/verify_conf=0\b/verify_conf=/g" -e "s/verify_conf=false/verify_conf=/g" \
			-e "s/verify_conf=1\b/verify_conf=true/g" \
			-e 's#(machine_network=[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/#\1\nprefix_length=#g' | \
		awk '{print $1}' | \
		sed	-e "s/^/export /g";

			#-e 's/^(([^"]*"[^"]*")*[^"]*)#.*/\1/' \
	[ "$ASK_OVERRIDE" ] && echo export ask= || true  # If -y provided, then override the value of ask= in aba.conf
	# "true" needed, otherwise this function returns non-zero (error)
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
			[ "$f" = "all" ] && continue # Skip checking this since 'all' means all operators
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
	PERL_DNS_IP_REGEX='^(?:25[0-5]|2[0-4]\d|1\d{2}|[0-9]{1,2})(?:\.(?:25[0-5]|2[0-4]\d|1\d{2}|[0-9]{1,2})){3}(?:,(?:25[0-5]|2[0-4]\d|1\d{2}|[0-9]{1,2})(?:\.(?:25[0-5]|2[0-4]\d|1\d{2}|[0-9]{1,2})){3})*$'
	#[ "$dns_servers" ] && echo $dns_servers | grep -q -E '^([0-9]{1,3}\.){3}[0-9]{1,3}(,([0-9]{1,3}\.){3}[0-9]{1,3})*$' || { echo_red "Error: dns_servers is invalid in aba.conf [$dns_servers]" >&2; ret=1; }
	[ "$dns_servers" ] && ! echo $dns_servers | grep -q -P $PERL_DNS_IP_REGEX && { echo_red "Error: dns_servers is invalid in aba.conf [$dns_servers]" >&2; ret=1; }
	[ "$next_hop_address" ] && ! echo $next_hop_address | grep -q -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' && { echo_red "Error: next_hop_address is invalid in aba.conf [$next_hop_address]" >&2; ret=1; }

	echo $oc_mirror_version | grep -q -E '^v[12]$' || { echo_red "Error: oc_mirror_version is invalid in aba.conf [$oc_mirror_version]" >&2; ret=1; }

	return $ret
}

normalize-mirror-conf()
{
	# Normalize or sanitize the config file
	# Ensure any ~/ is masked, e.g. \~/ ('cos ~ may need to be expanded on remote host)
	# Ensure data_disk has ~ masked in each case of: ^data_dir=$ ^data_disk=~ ^data_disk=  
	# Ensure reg_ssh_user has a value
	# Remove all commends after just ONE "#" ->  's/^(([^"]*"[^"]*")*[^"]*)#.*/\1/' \
	# Ensure only one arg after 'export'   # Note that all values are now single string, e.g. single value or comma-sep list (one string)
	# Verify oc_mirror_version exists and is somewhat correct and defaults to v1
	# Prepend "export "
	# reg_path must not start with a /, if so, remove it
	# Force tls_verify=true 
	# Fix reg_path if it a) does not start with / or starts with anything other than space or tab, then prepend a '/'

	[ ! -s mirror.conf ] &&                                                              return 0

	(
		cat mirror.conf | \
			sed -E	\
				-e "s/^\s*#.*//g" \
				-e '/^[ \t]*$/d' -e "s/^[ \t]*//g" -e "s/[ \t]*$//g" \
				-e "s/^(([^']*'[^']*')*[^']*)#.*$/\1/" \
				-e 's/^(data_dir=)([[:space:]].*|#.*|~|$)/\1\\~/' \
				-e 's/^oc_mirror_version=[^v].*/oc_mirror_version=v1/g' \
				-e 's/^oc_mirror_version=v[^12].*/oc_mirror_version=v1/g' \
				-e 's#^reg_path=([^/ \t])#reg_path=/\1#g' \
				| \
			awk '{print $1}' | \
			sed	-e "s/^/export /g"

		# Append always
		#echo export tls_verify=true
	)
}

				#-e "s/^reg_ssh_user=([[:space:]]+|$)/reg_ssh_user=$(whoami) /g" \
				#-e "s/^#reg_ssh_user=([[:space:]]+|$)/reg_ssh_user=$(whoami) /g" \

verify-mirror-conf() {
	[ ! "$verify_conf" ] && return 0
	[ ! -s mirror.conf ] && return 0

	local ret=0

	echo $reg_host | grep -q -E '^[A-Za-z0-9.-]+\.[A-Za-z]{1,}$' || { echo_red "Error: reg_host is invalid in mirror.conf [$reg_host]" >&2; ret=1; }
	[ ! "$reg_host" ] && echo_red "Error: reg_host value is missing in mirror.conf" >&2 && ret=1

	####[ ! "$reg_ssh_user" ] && echo_red "Error: reg_ssh_user not defined!" >&2 && ret=1   # This should never happen as the user name (whoami) is added above if its empty.

	[ "$reg_root" ] && [ ! "$data_dir" ] &&  echo_red "Error: 'reg_root' is reprecated. Use 'data_dir' instead in 'mirror/mirror.conf'" >&2 && ret=1 

	REGEX_ABS_PATH='^(~(/([A-Za-z0-9._-]+(/)?)*|$)|/([A-Za-z0-9._-]+(/)?)*$)'

	[ "$data_dir" ] && { echo $data_dir | grep -Eq "$REGEX_ABS_PATH" || { echo_red "Error: data_dir is invalid in mirror.conf [$data_dir]" >&2; ret=1; }; }

	[ "$reg_path" ] && { echo $reg_path | grep -Eq "$REGEX_ABS_PATH" || { echo_red "Error: reg_path is invalid in mirror.conf [$reg_path]" >&2; ret=1; }; }

	[ "$reg_ssh_key" ] && { echo $reg_ssh_key | grep -Eq "$REGEX_ABS_PATH" || { echo_red "Error: reg_ssh_key is invalid in mirror.conf [$reg_ssh_key]" >&2; ret=1; }; }

	return $ret
}

normalize-cluster-conf()
{
	# Normalize or sanitize the config file
	# Remove all chars from lines with <white-space>#<anything>
	# Remove all white-space lines
	# Remove all leading and trailing white-space
	# Remove all commends after just ONE "#" ->  's/^(([^"]*"[^"]*")*[^"]*)#.*/\1/' \
	# Extract machine_network and prefix_length from the CIDR notation
	# Ensure only one arg after 'export'
	# Prepend "export "
	# Adjust new int_connection value for compatibility

	[ ! -s cluster.conf ] &&                                                               return 0

	cat cluster.conf | \
		sed -E	\
			-e "s/^\s*#.*//g" \
			-e '/^[ \t]*$/d' -e "s/^[ \t]*//g" -e "s/[ \t]*$//g" \
			-e "s/^(([^']*'[^']*')*[^']*)#.*$/\1/" \
			-e 's#(machine_network=[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/#\1\nprefix_length=#g' \
			-e 's/^int_connection=none/int_connection= /g' | \
		awk '{print $1}' | \
		sed -e "s/^/export /g";

	#	awk -F= '{printf sep $2; sep=","} END {print ""}' ports.conf | sed 's/^/ports=/' | \

	# Add any missing default values, mainly for backwards compat.
	grep -q ^hostPrefix= cluster.conf	|| echo export hostPrefix=23
	grep -q ^port0= cluster.conf 		|| echo export port0=eth0
	# Convert 'port0/1=' to 'ports=' for backwards compatibility
	#grep -q ^ports= cluster.conf 		|| echo export ports=$(cat cluster.conf | sed -n '/^port[0-9]=/s/.*=//p' | awk '{print $1}' | paste -sd, -)
	grep -q ^ports= cluster.conf 		|| echo export ports=$(grep -E "^port[01]=\S" cluster.conf | cut -d= -f2 | awk '{print $1}' | paste -sd, -)
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

	if [ "$starting_ip" = "ADD-IP-ADDR-HERE" ]; then
		echo_red "Warning: Starting IP address needs to be set in $PWD/cluster.conf.  Try using --starting-ip option." >&2
	else
		echo $starting_ip | grep -q -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || { echo_red "Error: starting_ip is invalid in cluster.conf. Try using --starting-ip option." >&2; ret=1; }
	fi

	echo $hostPrefix | grep -q -E '^([0-9]|[1-2][0-9]|3[0-2])$' || { echo_red "Error: hostPrefix is invalid in cluster.conf" >&2; ret=1; }

	echo $master_prefix | grep -q -E '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$' || { echo_red "Error: master_prefix is invalid in cluster.conf" >&2; ret=1; }
	echo $worker_prefix | grep -q -E '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$' || { echo_red "Error: worker_prefix is invalid in cluster.conf" >&2; ret=1; }

	echo $num_masters | grep -q -E '^[0-9]+$' || { echo_red "Error: num_masters is invalid in cluster.conf" >&2; ret=1; }
	echo $num_workers | grep -q -E '^[0-9]+$' || { echo_red "Error: num_workers is invalid in cluster.conf" >&2; ret=1; }

	REGEX='^(([A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,})|([A-Za-z0-9-]+)|([0-9]{1,3}(\.[0-9]{1,3}){3}))(,(([A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,})|([A-Za-z0-9-]+)|([0-9]{1,3}(\.[0-9]{1,3}){3})))*$'
	PERL_DNS_IP_REGEX='^(?:25[0-5]|2[0-4]\d|1\d{2}|[0-9]{1,2})(?:\.(?:25[0-5]|2[0-4]\d|1\d{2}|[0-9]{1,2})){3}(?:,(?:25[0-5]|2[0-4]\d|1\d{2}|[0-9]{1,2})(?:\.(?:25[0-5]|2[0-4]\d|1\d{2}|[0-9]{1,2})){3})*$'
	#! echo $dns_servers | grep -q -P $PERL_DNS_IP_REGEX && { echo_red "Error: dns_servers is invalid in cluster.conf [$dns_servers]" >&2; ret=1; }
	[ "$dns_servers" ] && ! echo $dns_servers | grep -q -P $PERL_DNS_IP_REGEX && { echo_red "Error: dns_servers is invalid in aba.conf [$dns_servers]" >&2; ret=1; }

	echo $next_hop_address | grep -q -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || { echo_red "Error: next_hop_address is invalid in cluster.conf" >&2; ret=1; }

	# The next few values are all optional
	#[ "$port0" ] && ! echo $port0 | grep -q -E '^[a-zA-Z0-9_.-]+$' && { echo_red "Error: port0 is invalid in cluster.conf: [$port0]" >&2; ret=1; }
	#[ "$port1" ] && ! echo $port1 | grep -q -E '^[a-zA-Z0-9_.-]+$' && { echo_red "Error: port1 is invalid in cluster.conf: [$port1]" >&2; ret=1; }
	if [ ! -n $ports ]; then
		echo_red "Error: ports value is missing in cluster.conf" >&2
		ret=1;
	else
		[[ $ports =~ ^[a-zA-Z0-9_.-]+(,[a-zA-Z0-9_.-]+)*$ ]] || { echo_red "Error: ports list is invalid in cluster.conf: [$ports]" >&2; ret=1; }
	fi

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
	# Remove all commends after just ONE "#" ->  's/^(([^"]*"[^"]*")*[^"]*)#.*/\1/' \
	# Ensure only one arg after 'export'
	# Prepend "export "
	# Convert VMW_FOLDER to VC_FOLDER for backwards compat!

	# Removed this line since GOVC_PASSWORD='<my password here>' was getting cut and failing to parse
	#awk '{print $1}' | \

	[ ! -s vmware.conf ] &&                                                              return 0  # vmware.conf can be empty

        vars=$(cat vmware.conf | \
		sed -E	\
			-e "s/^\s*#.*//g" \
			-e '/^[ \t]*$/d' -e "s/^[ \t]*//g" -e "s/[ \t]*$//g" \
			-e "s/^(([^']*'[^']*')*[^']*)#.*$/\1/" \
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
	[ "$1" == "-t" ] && timer="-t $2" && shift 2

	echo_yellow -n "$@? $yn_opts: "
	read $timer yn

	# Return default response, 0
	[ ! "$yn" ] && return 0

	[ "$def_response" == "y" ] && [ "$yn" == "y" -o "$yn" == "Y" ] && return 0
	[ "$def_response" == "n" ] && [ "$yn" == "n" -o "$yn" == "N" ] && return 0

	# return "non-default" response 
	return 1
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

	[ ! "$quiet" ] && aba_info "Attempt $count/$total of command: \"$*\""

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

		[ ! "$quiet" ] && aba_info "Attempt $count/$total of command: \"$*\""
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

# Helper: download and return release.txt content
_fetch_release_txt() {
    local chan="$1" arch_sys="$2" url
    url="https://mirror.openshift.com/pub/openshift-v4/${arch_sys}/clients/ocp/${chan}/release.txt"

    curl -fsSL --connect-timeout 30 --retry 8 "$url" 2>/dev/null || {
        echo "Error: failed to fetch release info from $url" >&2
        return 1
    }
}

# Helper: extract version string (x.y.z) from release.txt
_extract_version() {
    grep -Eo "Version: +[0-9]+\.[0-9]+\.[0-9]+" | awk '{print $2}'
}


# ------------------------------------------------------------------------------
# Fetch the latest OpenShift version from a channel (e.g. stable, fast)
# Example: fetch_latest_version stable x86_64 → 4.15.13
# ------------------------------------------------------------------------------
fetch_latest_version() {
    local chan="${1:-stable}"              # stable, fast, candidate, eus
    local arch_sys="${2:-x86_64}"          # x86_64, arm64, etc.
    local rel_txt ver

    # EUS fallback — release.txt not provided for eus
    [[ "$chan" == "eus" ]] && chan="stable"

    rel_txt=$(_fetch_release_txt "$chan" "$arch_sys") || return 1
    ver=$(_extract_version <<<"$rel_txt")

    if [[ -z "$ver" ]]; then
        echo_white "Error: could not extract version from $chan release data" >&2
        return 1
    fi

    echo "$ver"
}

_install_oc_mirror() {
    if ! which oc-mirror >/dev/null 2>&1; then
        make -s -C "$1/cli" oc-mirror >&2 || {
            echo_white "Error: failed to build oc-mirror" >&2
            return 1
        }
    fi
}


# ------------------------------------------------------------------------------
# Fetch the previous OpenShift version (e.g. 4.19.10 → 4.18.x)
# Requires oc-mirror to list previous channel releases.
# ------------------------------------------------------------------------------
fetch_previous_version() {
    local chan="${1:-stable}"
    local arch_sys="${2:-x86_64}"
    local ver major minor patch prev_minor prev_ver

    [[ "$chan" == "eus" ]] && chan="stable"

    ver=$(fetch_latest_version "$chan" "$arch_sys") || return 1

    # Split into parts: 4.19.10 → major=4, minor=19, patch=10
    IFS=. read -r major minor patch <<<"$ver"

    # Handle edge cases: avoid negative or missing minor version
    if (( minor <= 0 )); then
        echo_white "Error: cannot compute previous version from $ver" >&2
        return 1
    fi
    prev_minor=$((minor - 1))

    _install_oc_mirror $ABA_ROOT >/dev/null 2>&1

    # Query the previous channel via oc-mirror
    prev_ver=$(oc-mirror list releases --channel="${chan}-${major}.${prev_minor}" 2>/dev/null | tail -n1)

    # Try again?
    [ ! "$prev_ver" ] && sleep 8 && prev_ver=$(oc-mirror list releases --channel="${chan}-${major}.${prev_minor}" 2>/dev/null | tail -n1)

    if [[ -z "$prev_ver" ]]; then
        echo_white "Error: no previous version found for ${chan}-${major}.${prev_minor}" >&2
        return 1
    fi

    echo "$prev_ver"
}


# ------------------------------------------------------------------------------
# Fetch the latest z-stream version for a given x.y series
# Example: fetch_latest_z_version stable 4.19 x86_64 → 4.19.32
# ------------------------------------------------------------------------------
fetch_latest_z_version() {
    local chan="${1:-stable}"
    local base_ver="$2"             # e.g. 4.19
    local arch_sys="${3:-x86_64}"
    local rel_txt ver url

    if [[ -z "$base_ver" ]]; then
        base_ver=$(fetch_latest_version "$chan" "$arch_sys") || return 1
        base_ver="${base_ver%.*}"   # Trim to x.y
    fi

    [[ "$chan" == "eus" ]] && chan="stable"

    url="https://mirror.openshift.com/pub/openshift-v4/${arch_sys}/clients/ocp/${chan}-${base_ver}/release.txt"
    rel_txt=$(curl -fsSL --connect-timeout 20 --retry 8 "$url" 2>/dev/null)

    if [[ -z "$rel_txt" ]]; then
        echo_white "Error: failed to fetch release info for ${chan}-${base_ver}" >&2
        return 1
    fi

    ver=$(_extract_version <<<"$rel_txt")

    if [[ -z "$ver" ]]; then
        echo_white "Error: could not extract z-stream version for ${chan}-${base_ver}" >&2
        return 1
    fi

    echo "$ver"
}



# Replace a value in a conf file, taking care of white-space and optional commented ("#") values
replace-value-conf() {
	# -n <string> : name of value to change
	# -v <string> : new value. If missing, remove the value
	# -f <files>

	aba_debug "Calling: replace-value-conf() $*"

	local quiet=

	while [ $# -gt 0 ]; do
		case "$1" in
			-n)
				# If arg missing?
				[[ -z "$2" || "$2" =~ ^- ]] && echo_red "Missing arg after [$1]" >&2 && exit 1
				local name="$2"
				shift 2
				;;
			-v)
				if [[ -z "$2" || "$2" =~ ^- ]]; then
					local value=
				else
					local value="$2"
					shift
				fi
				shift
				;;
			-f)
				shift
				local files="$@"
				break
				;;
			-q)
				local quiet=1
				shift
				;;
			*)
				local files="$files $1"
				shift
				;;
		esac
	done

	# Step through the files by priority...
	for f in $files
	do
		[ ! -s "$f" ] && continue # Try next file

		aba_debug "Replacing config value [$name] with [$value] in file: $f" >&2

		# Check if the value is already in the file along with the expected chars after the value, e.g. space/tab/# or EOL
		if grep -q -E "^$name=$value[[:space:]]*(#.*)?$" $f; then
			if [ ! "$quiet" ]; then
				[ "$value" ] && aba_info_ok "Value ${name}=${value} already exists in file $f" >&2 || aba_info_ok "Value ${name} is already undefined in file $f" >&2
			fi

			return 0
		else
			sed -i "s|^[# \t]*${name}=[^ \t]*\(.*\)|${name}=${value}\1|g" $f

			if [ ! "$quiet" ]; then
				[ "$value" ] && aba_info_ok "Added value ${name}=${value} to file $f" >&2 || aba_info_ok "Undefining value ${name} in file $f" >&2 
			fi

			return 0
		fi
	done

	return 1 # Files do not exist!
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

# Turn all key=val args into $vars
process_args() {
	[ ! "$*" ] && return 0

	echo "$*" | grep -Eq '^([a-zA-Z_]\w*=?[^ ]*)( [a-zA-Z_]\w*=?[^ ]*)*$' || { echo_red "Error: invalid params [$*], not key=value pairs"; exit 1; }
	# eval all key value args
	#[ "$*" ] && . <(echo $* | tr " " "\n")  # Get $name, $type etc from here
	#echo $* | tr " " "\n"  # Get $name, $type etc from here
	echo $* | tr " " "\n" | sed 's/^/export /'
	shift $#
}

# Track anonymous events run by any aba using name "$1" (optional)
aba-track() {
	# Note this tracker has only one counter: 'installed'
	[ ! "$ABA_TESTING" ] && ( curl --retry 8 --fail -s https://abacus.jasoncameron.dev/hit/bylo.de-aba/installed >/dev/null 2>&1 & disown ) & disown
}

# =========================================================
# Deduce reasonable defaults for OpenShift cluster config
# =========================================================

# -------------------------
# Functions
# -------------------------

# Get base domain
get_domain() {
    # hostname -d gives the domain part of the FQDN
    local d
    d=$(hostname -d 2>/dev/null || true)
    # fallback default
    echo "${d:-example.com}"
}

# Get the default gateway / next hop
get_next_hop() {
    local gw
    # extract the "via" IP from the default route
    gw=$(ip route show default 2>/dev/null \
         | awk '/default/ {for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}')

    # Double check it's an IP addr
    echo $gw | grep -q -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || gw=

    # fallback
    echo "${gw:-10.0.0.1}"
}

# Get machine network (CIDR of the main interface)
get_machine_network() {
    local def_if net
    # find default network interface
    def_if=$(ip route show default 2>/dev/null \
             | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')

    # Try to get subnet CIDR of the default interface
    net=$(ip -o -4 route list dev "${def_if:-}" proto kernel scope link 2>/dev/null \
          | awk '$1 ~ "/" {print $1; exit}')

    # fallback: first RFC1918 route not associated with container/VM bridges
    if [[ -z "${net:-}" ]]; then
        net=$(ip -o -4 route list proto kernel scope link 2>/dev/null \
              | awk '$1 ~ "/" && $0 !~ /(docker|podman|cni|virbr|br-|veth|tun|tap)/ {print $1}' \
              | awk '/^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.)/ {print; exit}')
    fi

    # Double check it's a CIDR
    echo $net | grep -q -E '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$' || net=

    # final fallback
    echo "${net:-10.0.0.0/20}"
}

# Get DNS servers
get_dns_servers() {
    local dns
    # Try resolvectl first (Fedora / systemd-resolved)
    if command -v resolvectl >/dev/null 2>&1; then
        dns=$(resolvectl status \
              | awk '/DNS Servers/ {for(i=3;i<=NF;i++) printf "%s%s",$i,(i<NF?"," : "\n")}')
    fi

    # Fallback to /etc/resolv.conf if nothing found
    if [[ -z "${dns:-}" ]]; then
        dns=$(awk '/^nameserver/ {print $2}' /etc/resolv.conf | paste -sd,)
    fi

    # Double check it's a list of IP addr
    echo $dns | grep -q -E '^([0-9]{1,3}(\.[0-9]{1,3}){3})(,([0-9]{1,3}(\.[0-9]{1,3}){3}))*$' || dns=

    # Final fallback
    echo "${dns:-8.8.8.8,1.1.1.1}"
}

# Get NTP servers
get_ntp_servers() {
    local ntp
    # Read server lines from chrony.conf, join with commas
    ntp=$(awk '/^server / {print $2}' /etc/chrony.conf 2>/dev/null | paste -sd,)

    # Double check it's a list of IP and/or domain names
    echo $ntp | grep -q -E '^(([0-9]{1,3}(\.[0-9]{1,3}){3})|([A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*))(,(([0-9]{1,3}(\.[0-9]{1,3}){3})|([A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*)))*$' || ntp=

    # fallback
    echo "${ntp:-pool.ntp.org}"
}

trust_root_ca() {
	if [ -s $1 ]; then
		if $SUDO diff $1 /etc/pki/ca-trust/source/anchors/rootCA.pem >/dev/null 2>&1; then
			echo_white "$1 already in system trust"
		else
			$SUDO cp $1 /etc/pki/ca-trust/source/anchors/ 
			$SUDO update-ca-trust extract
			echo_white "Cert 'regcreds/rootCA.pem' updated in system trust"
		fi
	else
		echo_white "No $1 cert file found" 
	fi

	return 0
}

is_valid_dns_label() {
	local name="$1"

	if [[ "$name" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]; then
		[ "$ABA_INFO" ] && echo_white "Valid DNS label" >&2
		return 0
	else
		echo_red "Invalid DNS label: $name" >&2
		return 1
	fi
}

