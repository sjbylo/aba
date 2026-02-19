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

# Map uname -m to OpenShift download architecture names.
# x86_64 -> amd64, aarch64 -> arm64, s390x/ppc64le stay as-is (match OpenShift naming).
export ARCH=$(uname -m)
[ "$ARCH" = "aarch64" ] && export ARCH=arm64  # ARM
[ "$ARCH" = "x86_64" ] && export ARCH=amd64   # Intel
# s390x and ppc64le: no mapping needed — OpenShift uses the raw uname -m value

# ===========================
# Color Echo Functions
# ===========================

_color_echo() {
    local color="$1"; shift
    local n_opt=
    local text

    # Handle -n option if present
    if [ "$1" = "-n" ]; then
        n_opt="-n"
        shift
    fi

    # Determine input source: arguments or stdin
    if [ $# -gt 0 ]; then
        text="$*"
        # Process each line (in case args contain newlines)
        while IFS= read -r line; do
            _print_colored "$color" "$n_opt" "$line"
        done <<< "$text"
    else
        # Read from stdin line by line
        while IFS= read -r line; do
            _print_colored "$color" "$n_opt" "$line"
        done
    fi
}

# Helper function to handle color and terminal checks
_print_colored() {
    local color="$1"; shift
    local n_opt="$1"; shift
    local line="$*"

    if [ -t 1 ] && [ "$(tput colors 2>/dev/null)" -ge 8 ] && [ -z "${PLAIN_OUTPUT:-}" ]; then
        tput setaf "$color"
        echo -e $n_opt "$line"
        tput sgr0
    else
        echo -e $n_opt "$line"
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

aba_info() {
	[ ! "${INFO_ABA:-}" ] && return 0

	if [ "$1" = "-n" ]; then
		shift
		echo_white -n "[ABA] $@"
	else
		echo_white "[ABA] $@"
	fi
}

# Same as aba_info, but green
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

    [ ! "${DEBUG_ABA:-}" ] && return 0

    # Erase to col1 and return
    [ "$TERM" ] && { tput el1 && tput cr; } >&2

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
        local prefix="Warning"
	local newline=
	local col=red

	# Parse optional -p PREFIX
	while [ $# -gt 0 ]
	do
		if [ "$1" = "-p" ]; then
			prefix="$2"
			shift 
		elif [ "$1" = "-c" ]; then
			col=$2
			shift
		elif [ "$1" = "-n" ]; then
			newline='-n'
		else
			break
		fi
		shift
	done

	local main_msg="$1"
	shift

	# Calculate indent based on prefix length plus the "[ABA] " part
	# "[ABA] " = 6 chars, ": " = 2 chars
	#local indent_len=$((6 + ${#prefix} + 2))
	local indent_len=$((${#prefix} + 2))
	local indent
	printf -v indent "%*s" "$indent_len" ""

	# Print main message
	echo_$col $newline "[ABA] $prefix: $main_msg" >&2

	#[ "$*" ] && newline=  # Note, '-n' only make sense for a single line

	# Print follow-up lines with calculated indentation
	for line in "$@"; do
		echo_$col "[ABA] ${indent}${line}" >&2
	done

	sleep 1
}

#aba_warning() {
#	local prefix=Warning
#	[ "$1" = "-p" ] && prefix="$2" && shift 2
#	local main_msg="$1"
#	shift
#
#	# Main error message in red to stderr
#	echo_red "[ABA] $prefix: $main_msg" >&2
#
#	# Indented follow-up lines, also red, to stderr
#	for line in "$@"; do
#		echo_red "[ABA]          $line" >&2
#	done
#
#	sleep 1
#}


if ! [[ "$PATH" =~ "$HOME/bin:" ]]; then
	aba_debug "$0: Adding $HOME/bin to \$PATH for user $(whoami)" >&2
	PATH="$HOME/bin:$PATH"
fi

umask 077

# Function to display an error message and the last executed command
show_error() {
	local exit_code=$?
	echo 
	echo_red "Script error at $(date) in directory $PWD: " >&2
	echo_red "Error occurred in command: '$BASH_COMMAND'" >&2
	echo_red "Error code: $exit_code" >&2

	exit $exit_code
}

# Set the trap to call the show_error function on ERR signal
# If no first argument is provided, set a trap for errors
[ -z "${1-}" ] && trap 'show_error' ERR && [ "${DEBUG_ABA:-}" ] && echo Error trap set >&2

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
	[ "${ASK_OVERRIDE:-}" ] && echo export ask= || true  # If -y provided, then override the value of ask= in aba.conf
	# "true" needed, otherwise this function returns non-zero (error)
}

verify-aba-conf() {
	[ ! "$verify_conf" ] && return 0
	[ -f aba.conf -a ! -s aba.conf ] && echo_red "$PWD/aba.conf file is empty!" && return 1
	[ ! -s aba.conf ] && return 0

	local ret=0
	local REGEX_VERSION='[0-9]+\.[0-9]+\.[0-9]+'
	local REGEX_BASIC_DOMAIN='^[A-Za-z0-9.-]+\.[A-Za-z]{1,}$'

	echo $ocp_version | grep -q -E $REGEX_VERSION || { echo_red "Error: ocp_version incorrectly set or missing in aba.conf.  See: aba --help" >&2; ret=1; }
	echo $ocp_channel | grep -q -E "fast|stable|candidate|eus" || { echo_red "Error: ocp_channel incorrectly set or missing in aba.conf.  See: aba --help" >&2; ret=1; }
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
	# If the file exists and is empty?
	#[ -f mirror.conf -a ! -s mirror.conf ] && echo_red "$PWD/mirror.conf file is empty!" && return 1  # Causes error when installing cluster directly form internet
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

# -----------------------------------------------------------------------------
# IP Address Math Helpers (pure bash, no external dependencies)
# -----------------------------------------------------------------------------

# Convert dotted-quad IP to a 32-bit integer: ip_to_int 10.0.2.12 => 167772684
ip_to_int() {
	local IFS='.'
	local -a o=($1)
	echo $(( (o[0] << 24) + (o[1] << 16) + (o[2] << 8) + o[3] ))
}

# Convert 32-bit integer back to dotted-quad: int_to_ip 167772684 => 10.0.2.12
int_to_ip() {
	local n=$1
	echo "$(( (n >> 24) & 255 )).$(( (n >> 16) & 255 )).$(( (n >> 8) & 255 )).$(( n & 255 ))"
}

# Check if an IP is within a CIDR: ip_in_cidr 10.0.2.12 10.0.0.0 20
# Args: IP  NETWORK_ADDR  PREFIX_LEN
# Returns 0 if IP is within the CIDR, 1 otherwise.
ip_in_cidr() {
	local ip_int=$(ip_to_int "$1")
	local net_int=$(ip_to_int "$2")
	local prefix=$3
	local mask=$(( 0xFFFFFFFF << (32 - prefix) & 0xFFFFFFFF ))
	[[ $(( ip_int & mask )) -eq $(( net_int & mask )) ]]
}

# Compute the broadcast (last) address of a CIDR: cidr_last_ip 10.0.2.200 30 => 10.0.2.203
cidr_last_ip() {
	local net_int=$(ip_to_int "$1")
	local prefix=$2
	local host_bits=$(( 32 - prefix ))
	local last=$(( net_int | ((1 << host_bits) - 1) ))
	int_to_ip $last
}

# Return the number of usable host addresses in a CIDR (excludes network + broadcast)
cidr_host_count() {
	local prefix=$1
	if (( prefix >= 31 )); then
		echo 0
	else
		echo $(( (1 << (32 - prefix)) - 2 ))
	fi
}

verify-cluster-conf() {
	[ ! "$verify_conf" ] && return 0
	[ -f cluster.conf -a ! -s cluster.conf ] && echo_red "$PWD/cluster.conf file is empty!" && return 1
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

		# Validate starting_ip falls within machine_network CIDR
		if [[ $ret -eq 0 ]] && echo "$machine_network" | grep -q -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
			local cidr_first_ip=$(int_to_ip $(( $(ip_to_int "$machine_network") + 1 )))
			local cidr_last=$(cidr_last_ip "$machine_network" "$prefix_length")
			local cidr_range="Valid range: $cidr_first_ip - $cidr_last"

			if ! ip_in_cidr "$starting_ip" "$machine_network" "$prefix_length"; then
				echo_red "Error: starting_ip ($starting_ip) is outside the machine_network ($machine_network/$prefix_length). $cidr_range" >&2
				ret=1
			fi

			# Validate all nodes fit within the CIDR
			local total_nodes=$(( num_masters + num_workers ))
			if (( total_nodes > 0 )); then
				local start_int=$(ip_to_int "$starting_ip")
				local last_node_int=$(( start_int + total_nodes - 1 ))
				local last_node_ip=$(int_to_ip $last_node_int)
				if ! ip_in_cidr "$last_node_ip" "$machine_network" "$prefix_length"; then
					echo_red "Error: not all $total_nodes nodes fit in machine_network ($machine_network/$prefix_length)." \
						"Last node IP would be $last_node_ip. $cidr_range" >&2
					ret=1
				fi
			fi

			# For non-SNO: check VIPs are within CIDR too
			if (( num_masters > 1 )); then
				if [ -n "${api_vip:-}" ] && echo "$api_vip" | grep -q -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
					if ! ip_in_cidr "$api_vip" "$machine_network" "$prefix_length"; then
						echo_red "Error: api_vip ($api_vip) is outside the machine_network ($machine_network/$prefix_length). $cidr_range" >&2
						ret=1
					fi
				fi
				if [ -n "${ingress_vip:-}" ] && echo "$ingress_vip" | grep -q -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
					if ! ip_in_cidr "$ingress_vip" "$machine_network" "$prefix_length"; then
						echo_red "Error: ingress_vip ($ingress_vip) is outside the machine_network ($machine_network/$prefix_length). $cidr_range" >&2
						ret=1
					fi
				fi
			fi
		fi
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
	# FIXME: Is this the right place to check?!
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
		echo "Installing required rpm packages:$rpms_to_install (logging to .dnf-install.log). Please wait!" >&2  # send to stderr so this can be seen during "aba bundle -o -"
		if ! $SUDO dnf install $rpms_to_install -y >> .dnf-install.log 2>&1; then
			aba_warning \
				"an error occurred during rpm installation. See the logs at .dnf-install.log." \
				"If dnf cannot be used to install rpm packages, please install the following packages manually and try again!" 
			aba_info $rpms_to_install

			return 1
		fi
	fi
}

ask() {
	aba_debug $0: aba.conf ask=$ask ASK_OVERRIDE=${ASK_OVERRIDE:-}
	local ret_default=

	if [ ! "$ASK_ALWAYS" ]; then  # FIXME: Simplify all this!
		[ "${ASK_OVERRIDE:-}" ] && ret_default="-y" #return 0  # reply "default reply"
		source <(normalize-aba-conf)  # if aba.conf does not exist, this outputs 'ask=true' to be on the safe side.
		aba_debug $0: aba.conf ask=$ask ASK_OVERRIDE=${ASK_OVERRIDE:-}
		[ ! "$ret_default" ] && [ ! "$ask" ] && ret_default="aba.conf:ask=false" #return 0  # reply "default reply"
	fi

	# Default reply is 'yes' (or 'no') and return 0
	yn_opts="(Y/n)"
	def_response=y
	[ "$1" == "-n" ] && def_response=n && yn_opts="(y/N)" && shift
	[ "$1" == "-y" ] && def_response=y && yn_opts="(Y/n)" && shift
	timer=
	[ ! "$ret_default" ] && [ "$1" == "-t" ] && timer="-t $2" && shift 2

	#echo
 	echo_yellow -n "[ABA] $@? $yn_opts: "
	[ "$ret_default" ] && echo_white "<default answer provided due to '$ret_default'>" && return 0
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
			echo_yellow "The file '$PWD/$conf_file' has been created (editor=none in aba.conf). Please edit it & repeat the same command."

			return 1
		else
			ask "$msg" || return 1
			$editor $conf_file
		fi
	else
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

	echo  >>.cmd.out 
	echo cmd $* >>.cmd.out 
	while ! eval $* >>.cmd.out 2>&1
	do
		if [ $count -ge $total ]; then
			[ ! "$quiet" ] && echo_red "Giving up on command \"$*\"" >&2
			# Return non-zero
			return 1
		fi

		[ ! "$quiet" ] && aba_info Pausing $pause seconds ...
		sleep $pause

		let pause=$pause+$backoff
		let count=$count+1

		[ ! "$quiet" ] && aba_info "Attempt $count/$total of command: \"$*\""
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


# Cincinnati API endpoint
ABA_GRAPH_API="https://api.openshift.com/api/upgrades_info/v1/graph"

# Architecture: default is amd64
ARCH="${ARCH:-amd64}"
[[ "$ARCH" == "x86_64" ]] && ARCH="amd64"

# Cache settings
ABA_CACHE_DIR="${ABA_CACHE_DIR:-$HOME/.aba/cache}"
ABA_CACHE_TTL="${ABA_CACHE_TTL:-6000}"	# seconds
# Note: Cache directory is created lazily when first needed

############################################
# Helpers (best-effort, no error output)
############################################

_now() {
	date +%s
}

_cache_fresh() {
	local file="$1" ttl="$2"
	[[ -s "$file" ]] || return 1
	local age
	age=$(( $(_now) - $(stat -c %Y "$file" 2>/dev/null || echo 0) ))
	(( age < ttl ))
}

# safe fetch:
# - only replaces cache on successful fetch + optional validator
# - never prints errors; returns 0 if cache exists (fresh or stale), 1 only if nothing usable
_fetch_cached() {
	local url="$1" cache_file="$2" ttl="$3" validator_fn="${4:-}"

	if _cache_fresh "$cache_file" "$ttl"; then
		return 0
	fi

	# Lazy creation: ensure cache directory exists before creating temp files
	mkdir -p "$(dirname "$cache_file")" 2>/dev/null || true

	local tmp
	tmp="$(mktemp "${cache_file}.XXXXXX")" || true

	# Let curl errors show (don't suppress stderr)
	if [[ -n "$tmp" ]] && curl -f -sS "$url" > "$tmp"; then
		if [[ -n "$validator_fn" ]]; then
			if "$validator_fn" "$tmp"; then
				mv -f "$tmp" "$cache_file"
			else
				rm -f "$tmp"
			fi
		else
			mv -f "$tmp" "$cache_file"
		fi
	else
		rm -f "$tmp" 2>/dev/null || true
	fi

	[[ -s "$cache_file" ]]
}

_validate_json_file() {
	jq -c '.' "$1" >/dev/null 2>&1
}

_is_ga_version() {
	[[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# decrement minor: "4.21" -> "4.20" ; "4.0" -> "" (no prev)
_prev_minor() {
	local minor="$1"
	local x y
	x="${minor%%.*}"
	y="${minor#*.}"
	[[ "$y" =~ ^[0-9]+$ ]] || { echo ""; return 0; }
	(( y > 0 )) || { echo ""; return 0; }
	echo "${x}.$((y - 1))"
}

# return 0 if v contains prerelease suffix (has '-') else 1
_is_prerelease() {
	[[ "$1" == *-* ]]
}

############################################
# Fetch latest minor (GA-aware)
# Returns MAJOR.MINOR (e.g. 4.20)
# If mirror reports prerelease (e.g. 4.21.0-rc.1), returns previous minor (e.g. 4.20)
############################################
fetch_latest_minor_version() {
	local channel="${1:-stable}"
	local url="https://mirror.openshift.com/pub/openshift-v4/${ARCH}/clients/ocp/${channel}/release.txt"
	local cache_file="${ABA_CACHE_DIR}/release_${channel}_${ARCH}.txt"
	local latest_ver minor prev

	_fetch_cached "$url" "$cache_file" "$ABA_CACHE_TTL" "" || { echo ""; return 0; }

	latest_ver="$(grep -Eo 'Version: +[0-9]+\.[0-9]+\..+' "$cache_file" 2>/dev/null | awk '{print $2}' | head -n1)"
	[[ -n "$latest_ver" ]] || { echo ""; return 0; }

	minor="$(echo "$latest_ver" | cut -d. -f1,2)"

	# If the "latest" is prerelease, ignore that minor until GA exists
	if _is_prerelease "$latest_ver"; then
		prev="$(_prev_minor "$minor")"
		[[ -n "$prev" ]] && { echo "$prev"; return 0; }
	fi

	echo "$minor"
}

############################################
# Internal: Fetch + cache Cincinnati graph JSON for channel-minor
# Args:
#	$1 = channel base (e.g. stable)
#	$2 = minor (e.g. 4.20) [optional]
# Output:
#	Prints JSON (cached)
############################################
_fetch_graph_cached() {
	local channel="${1:-stable}"
	local minor="$2"
	local chann_minor url cache_file

	[[ -n "$minor" ]] || minor="$(fetch_latest_minor_version "$channel")"
	[[ -n "$minor" ]] || return 0

	chann_minor="${channel}-${minor}"
	cache_file="${ABA_CACHE_DIR}/graph_${chann_minor}_${ARCH}.json"
	url="${ABA_GRAPH_API}?channel=${chann_minor}&arch=${ARCH}"

	_fetch_cached "$url" "$cache_file" "$ABA_CACHE_TTL" _validate_json_file || return 0
	cat "$cache_file"
}

############################################
# Fetch GA versions in channel-minor (sorted)
# Args:
#	$1 = channel base (e.g. stable)
#	$2 = minor (e.g. 4.20) [optional]
############################################
fetch_all_versions() {
	local channel="${1:-stable}"
	local minor="$2"

	set -o pipefail
	_fetch_graph_cached "$channel" "$minor" \
		| jq -r '.nodes[].version' \
		| grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
		| sort -V
}

############################################
# Fetch latest GA version (best-effort fallback)
# Strategy:
#	1) latest minor (GA-aware) -> latest z
#	2) if no GA nodes found, try previous minor
############################################
fetch_latest_version() {
	local channel="${1:-stable}"
	local minor v prev

	minor="$(fetch_latest_minor_version "$channel")"
	[[ -n "$minor" ]] || { echo ""; return 0; }

	v="$(fetch_all_versions "$channel" "$minor" | tail -n1)"
	if [[ -n "$v" ]]; then
		echo "$v"
		return 0
	fi

	prev="$(_prev_minor "$minor")"
	[[ -n "$prev" ]] || { echo ""; return 0; }

	v="$(fetch_all_versions "$channel" "$prev" | tail -n1)"
	[[ -n "$v" ]] && echo "$v"
	return 0
}

############################################
# Fetch latest GA z-stream within a minor (best-effort fallback)
# Args:
#	$1 = channel base (e.g. stable)
#	$2 = minor (e.g. 4.20) [optional]
# If requested minor has no GA, fall back to previous minor.
############################################
fetch_latest_z_version() {
	local channel="${1:-stable}"
	local minor="$2"
	local v prev

	[[ -n "$minor" ]] || minor="$(fetch_latest_minor_version "$channel")"
	[[ -n "$minor" ]] || { echo ""; return 0; }

	v="$(fetch_all_versions "$channel" "$minor" | tail -n1)"
	if [[ -n "$v" ]]; then
		echo "$v"
		return 0
	fi

	prev="$(_prev_minor "$minor")"
	[[ -n "$prev" ]] || { echo ""; return 0; }

	v="$(fetch_all_versions "$channel" "$prev" | tail -n1)"
	[[ -n "$v" ]] && echo "$v"
	return 0
}

############################################
# Fetch latest version of previous minor
# Example: if latest minor is 4.20 -> return latest 4.19.z
############################################
fetch_previous_version() {
	local channel="${1:-stable}"
	local minor prev v

	minor="$(fetch_latest_minor_version "$channel")"
	[[ -n "$minor" ]] || { echo ""; return 0; }

	prev="$(_prev_minor "$minor")"
	[[ -n "$prev" ]] || { echo ""; return 0; }

	v="$(fetch_all_versions "$channel" "$prev" | tail -n1)"
	[[ -n "$v" ]] && echo "$v"
	return 0
}

############################################
# Fetch latest version of N-2 minor (older)
# Example: if latest minor is 4.21 -> return latest 4.19.z
############################################
fetch_older_version() {
	local channel="${1:-stable}"
	local minor prev older v

	minor="$(fetch_latest_minor_version "$channel")"
	[[ -n "$minor" ]] || { echo ""; return 0; }

	prev="$(_prev_minor "$minor")"
	[[ -n "$prev" ]] || { echo ""; return 0; }

	older="$(_prev_minor "$prev")"
	[[ -n "$older" ]] || { echo ""; return 0; }

	v="$(fetch_all_versions "$channel" "$older" | tail -n1)"
	[[ -n "$v" ]] && echo "$v"
	return 0
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
				[[ -z "$2" || "$2" =~ ^- ]] && aba_abort "Missing arg after [$1]"
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

		# If value already in file (along with the optional, expected chars after the value, e.g. space/tab/# or EOL), then
		# ... change nothing!
		if grep -q -E "^$name=$value[[:space:]]*(#.*)?$" $f; then
			#if [ ! "$quiet" ]; then
				#[ "$value" ] && aba_info_ok "Value ${name}=${value} already exists in file $f" >&2 || aba_info_ok "Value ${name} is already undefined in file $f" >&2
			[ "$value" ] && aba_debug "Value ${name}=${value} already exists in file $f" || aba_debug "Value ${name} is already undefined in file $f"
			# Only need to send to debug output 
			#fi

			return 0
		else
			sed -i "s|^[# \t]*${name}=[^ \t]*\(.*\)|${name}=${value}\1|g" $f

			if [ ! "$quiet" ]; then
				[ "$value" ] && aba_info_ok "Added value ${name}=${value} to file $f" >&2 || aba_info_ok "Undefining value ${name} in file $f" >&2 
			else
				[ "$value" ] && aba_debug "Added value ${name}=${value} to file $f"     || aba_debug "Undefining value ${name} in file $f"
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

	echo "$*" | grep -Eq '^([a-zA-Z_]\w*=?[^ ]*)( [a-zA-Z_]\w*=?[^ ]*)*$' || aba_abort "invalid params [$*], not key=value pairs"
	# eval all key value args
	#[ "$*" ] && . <(echo $* | tr " " "\n")  # Get $name, $type etc from here
	#echo $* | tr " " "\n"  # Get $name, $type etc from here
	echo $* | tr " " "\n" | sed 's/^/export /'
	shift $#
}

# Track anonymous install events
aba-track() {
    # Note this tracker has only one counter: 'installed'
    [ "$ABA_TESTING" ] && return 0

    (
        curl \
          --fail \
          --silent \
          --retry 999 \
          --retry-delay 30 \
          --retry-max-time 10800 \
          --connect-timeout 10 \
          --max-time 20 \
          https://abacus.jasoncameron.dev/hit/bylo.de-aba/installed \
          >/dev/null 2>&1
    ) & disown
}

#aba-track() {
#	# Note this tracker has only one counter: 'installed'
#	[ ! "$ABA_TESTING" ] && ( curl --retry 20 --fail -s https://abacus.jasoncameron.dev/hit/bylo.de-aba/installed >/dev/null 2>&1 & disown ) & disown
#}

# ===========================================================
# Deduce reasonable defaults for OpenShift cluster net config
# ===========================================================

# Pick the "install interface" for best-guess defaults:
# 1) ABA_INSTALL_IFACE if set and usable (exists + UP + has IPv4)
# 2) otherwise first "real" UP interface with IPv4 (exclude container/virtual)
_pick_install_iface() {
	local ifc=

	# Helper: is interface "usable" (exists, UP, has IPv4)
	_is_usable_iface() {
		local i="$1"
		ip link show dev "$i" >/dev/null 2>&1 || return 1
		ip link show dev "$i" 2>/dev/null | grep -q "state UP" || return 1
		ip -o -4 addr show dev "$i" 2>/dev/null | grep -q "inet " || return 1
		return 0
	}

	# 1) User override
	if [[ -n "${ABA_INSTALL_IFACE:-}" ]]; then
		if _is_usable_iface "$ABA_INSTALL_IFACE"; then
			echo "$ABA_INSTALL_IFACE"
			return 0
		fi
	fi

	# 2) First "real" UP iface with IPv4 (exclude common virtual/container interfaces)
	# Note: keep this filter conservative; better to return nothing than a wrong veth/bridge.
	while read -r ifc; do
		# Exclude obvious virtual/container patterns
		echo "$ifc" | grep -Eq '^(lo|docker|podman|cni|virbr|br-|veth|tun|tap|zt|wg|flannel|cilium|kube|ovs|vnet|vmnet|dummy|sit|ip6tnl|gre)' && continue
		if _is_usable_iface "$ifc"; then
			echo "$ifc"
			return 0
		fi
	done < <(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | cut -d@ -f1)

	return 1
}

# Get base domain
get_domain() {
	local d fqdn

	# 1) domain from hostname -d
	d=$(hostname -d 2>/dev/null || true)

	# 2) derive from FQDN if empty
	if [[ -z "${d:-}" ]]; then
		fqdn=$(hostname -f 2>/dev/null || true)
		if echo "$fqdn" | grep -q '\.'; then
			d="${fqdn#*.}"
		fi
	fi

	# 3) resolv.conf search/domain as fallback
	if [[ -z "${d:-}" ]] && [[ -r /etc/resolv.conf ]]; then
		d=$(awk '
			$1=="search" && NF>=2 {print $2; exit}
			$1=="domain" && NF>=2 {print $2; exit}
		' /etc/resolv.conf 2>/dev/null || true)
	fi

	echo "${d:-example.com}"
}

# Get the default gateway / next hop (best guess for install interface, not system default)
get_next_hop() {
	local gw ifc cidr ip prefix a b c d ip_int mask net_int gw_int

	ifc=$(_pick_install_iface 2>/dev/null || true)

	# 1) If this iface has a default route, use its gateway
	if [[ -n "${ifc:-}" ]]; then
		gw=$(ip route show default dev "$ifc" 2>/dev/null \
			| awk '/default/ {for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}')
	fi

	# 2) No default route: compute network_base+1 from iface CIDR (subnet-aware)
	if [[ -z "${gw:-}" ]] && [[ -n "${ifc:-}" ]]; then
		cidr=$(ip -o -4 addr show dev "$ifc" 2>/dev/null | awk '{print $4; exit}')
		ip=${cidr%/*}
		prefix=${cidr#*/}

		if [[ -n "$ip" && -n "$prefix" ]]; then
			# Convert IP to 32-bit integer, mask to network base, add 1
			IFS=. read -r a b c d <<< "$ip"
			ip_int=$(( (a << 24) + (b << 16) + (c << 8) + d ))
			mask=$(( 0xFFFFFFFF << (32 - prefix) & 0xFFFFFFFF ))
			net_int=$(( ip_int & mask ))
			gw_int=$(( net_int + 1 ))
			gw="$(( (gw_int >> 24) & 0xFF )).$(( (gw_int >> 16) & 0xFF )).$(( (gw_int >> 8) & 0xFF )).$(( gw_int & 0xFF ))"
		fi
	fi

	# Validate IPv4
	echo "${gw:-}" | grep -q -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || gw=

	echo "${gw:-10.0.0.1}"
}

# Get machine network (CIDR of the chosen install interface)
# Get machine network (CIDR of the chosen install interface)
get_machine_network() {
	local ifc cidr net ip prefix

	ifc=$(_pick_install_iface 2>/dev/null || true)

	# 1) Best: ask the kernel for the connected (scope link) route on that iface
	if [[ -n "${ifc:-}" ]]; then
		net=$(ip -o -4 route list dev "$ifc" proto kernel scope link 2>/dev/null \
			| awk '$1 ~ "/" {print $1; exit}')
	fi

	# 2) Fallback: derive from iface IPv4/prefix (if route output not present)
	if [[ -z "${net:-}" ]] && [[ -n "${ifc:-}" ]]; then
		cidr=$(ip -o -4 addr show dev "$ifc" 2>/dev/null | awk '{print $4; exit}')
		ip=${cidr%/*}
		prefix=${cidr#*/}

		# If python3 exists, use it for portable CIDR math
		if command -v python3 >/dev/null 2>&1; then
			net=$(python3 - <<-PY 2>/dev/null
				import ipaddress
				ip="${ip}"
				pfx=int("${prefix}")
				print(str(ipaddress.ip_network(f"{ip}/{pfx}", strict=False)))
			PY
			)
		fi
	fi

	# 3) Fallback: first RFC1918 connected route not associated with container/VM bridges
	if [[ -z "${net:-}" ]]; then
		net=$(ip -o -4 route list proto kernel scope link 2>/dev/null \
			| awk '$1 ~ "/" && $0 !~ /(docker|podman|cni|virbr|br-|veth|tun|tap)/ {print $1}' \
			| awk '/^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.)/ {print; exit}')
	fi

	# Validate CIDR
	echo "${net:-}" | grep -q -E '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$' || net=

	echo "${net:-10.0.0.0/20}"
}


# Get DNS servers (comma-separated)
get_dns_servers() {
	local dns= ifc=

	ifc=$(_pick_install_iface 2>/dev/null || true)

	# 1) NetworkManager per-interface (RHEL / most accurate)
	if [[ -n "${ifc:-}" ]] && command -v nmcli >/dev/null 2>&1; then
		dns=$(nmcli -t -f IP4.DNS dev show "$ifc" 2>/dev/null \
			| cut -d: -f2 \
			| grep -E '^[0-9.]+' \
			| sort -u \
			| paste -sd,)
	fi

	# 2) NetworkManager global (fallback)
	if [[ -z "${dns:-}" ]] && command -v nmcli >/dev/null 2>&1; then
		dns=$(nmcli -t -f IP4.DNS dev show 2>/dev/null \
			| cut -d: -f2 \
			| grep -E '^[0-9.]+' \
			| sort -u \
			| paste -sd,)
	fi

	# 3) systemd-resolved only if active (Fedora/Ubuntu)
	if [[ -z "${dns:-}" ]] && command -v resolvectl >/dev/null 2>&1; then
		if systemctl is-active systemd-resolved >/dev/null 2>&1; then
			dns=$(resolvectl dns 2>/dev/null \
				| awk '{print $2}' \
				| grep -E '^[0-9.]+' \
				| sort -u \
				| paste -sd,)
		fi
	fi

	# 4) resolv.conf fallback
	if [[ -z "${dns:-}" ]] && [[ -r /etc/resolv.conf ]]; then
		dns=$(awk '/^nameserver/ {print $2}' /etc/resolv.conf 2>/dev/null \
			| grep -E '^[0-9.]+' \
			| sort -u \
			| paste -sd,)
	fi

	# Validate IPv4 list
	echo "${dns:-}" | grep -q -E '^([0-9]{1,3}(\.[0-9]{1,3}){3})(,([0-9]{1,3}(\.[0-9]{1,3}){3}))*$' || dns=

	echo "${dns:-8.8.8.8,1.1.1.1}"
}

# Get NTP servers (comma-separated)
get_ntp_servers() {
	local ntp=

	# chrony configs can be in /etc/chrony.conf and /etc/chrony.d/*.conf
	ntp=$(awk '
		$1=="server" && NF>=2 {print $2}
		$1=="pool"   && NF>=2 {print $2}
	' /etc/chrony.conf /etc/chrony.d/*.conf 2>/dev/null \
		| grep -v '^\s*#' \
		| sort -u \
		| paste -sd,)

	# Validate list of IPv4 and/or domain names
	echo "${ntp:-}" | grep -q -E '^(([0-9]{1,3}(\.[0-9]{1,3}){3})|([A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*))(,(([0-9]{1,3}(\.[0-9]{1,3}){3})|([A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*)))*$' || ntp=

	# No forced public fallback: many environments require internal NTP.
	# If you really want a fallback, uncomment:
	#echo "${ntp:-pool.ntp.org}"
	echo "${ntp:-}"
}


trust_root_ca() {
	if [ -s $1 ]; then
		if $SUDO diff $1 /etc/pki/ca-trust/source/anchors/rootCA.pem >/dev/null 2>&1; then
			aba_info "$1 already in system trust"
		else
			$SUDO cp $1 /etc/pki/ca-trust/source/anchors/ 
			$SUDO update-ca-trust extract
			aba_info "Cert 'regcreds/rootCA.pem' updated in system trust"
		fi
	else
		aba_info "No $1 cert file found" 
	fi

	return 0
}

is_valid_dns_label() {
	local name="$1"

	if [[ "$name" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]; then
		[ "$ABA_INFO" ] && aba_info "Valid DNS label" >&2
		return 0
	else
		echo_red "Invalid DNS label: $name" >&2
		return 1
	fi
}

calculate_and_show_completion() {
    local num_masters=$1
    local num_workers=$2
    
    # 1. Validation: Check if a number was provided
    if [[ -z "$num_masters" || -z "$num_workers" ]]; then
        echo "Error: Please provide the number of masters and workers."
        echo "Usage: calculate_completion <number_of_masters> <number_of_workers>"
        return 1
    fi

    # 2. Rough math: 36 mins base + (4 mins * nodes) + (1 min per worker)
    local base_mins=36
    local master_node_mins=4
    local worker_node_mins=1
    local total_duration=$(( base_mins + (master_node_mins * num_masters) + ( worker_node_mins * num_workers)))

    # 3. Date Formatting
    # %b = Abbreviated month (e.g., Jan)
    # %e = Day of month, space padded (e.g.,  6)
    # %H:%M = 24-hour time
    local time_format="+%b %e %H:%M"

    # Get current time
    local start_time=$(date "$time_format")

    # Calculate future time (Linux GNU date syntax)
    # We use -d to describe the time offset
    local end_time=$(date -d "+${total_duration} minutes" "$time_format")

    # 4. Output
    aba_info_ok "Installation started at ${start_time} — estimated completion: ${end_time} (${total_duration} minutes)"
}


# Run long-running tasks in the backhground.

#!/usr/bin/env bash
# TAB-indented runner (no timeout option)

run_once() {
	local mode="start"
	local work_id=""
	local purge=false
	local reset=false
	local global_clean=false
	local global_failed_clean=false
	local ttl=""
	local wait_timeout=""
	local waiting_message=""
	local quiet_wait=false
	local skip_validation=false
	local OPTIND=1

	# Allow override for tests
	local WORK_DIR="${RUN_ONCE_DIR:-$HOME/.aba/runner}"
	mkdir -p "$WORK_DIR"

	while getopts "swi:cprGFt:eoEW:m:qS" opt; do
		case "$opt" in
			s) mode="start" ;;
			w) mode="wait" ;;
			i) work_id=$OPTARG ;;
			c) purge=true ;;
			p) mode="peek" ;;
			r) reset=true ;;
			G) global_clean=true ;;
			F) global_failed_clean=true ;;
			t) ttl=$OPTARG ;;
			e) mode="get_error" ;;
			o) mode="get_output" ;;
			E) mode="get_exit" ;;
			W) wait_timeout=$OPTARG ;;
			m) waiting_message=$OPTARG ;;
			q) quiet_wait=true ;;
			S) skip_validation=true ;;
			*) return 1 ;;
		esac
	done
	shift $((OPTIND-1))
	local command=("$@")

	_kill_id() {
		local id="$1"
		local id_dir="$WORK_DIR/${id}"
		local pid_file="$id_dir/pid"
		local lock_file="$id_dir/lock"
		local exit_file="$id_dir/exit"
		local log_out_file="$id_dir/log.out"
		local log_err_file="$id_dir/log.err"
		local cmd_file="$id_dir/cmd"

		if [[ -f "$pid_file" ]]; then
			local old_pid
			old_pid="$(cat "$pid_file" 2>/dev/null || true)"
			if [[ -n "$old_pid" ]]; then
				# We run the job under setsid, so PGID==PID; kill the whole group.
				kill -TERM -"$old_pid" 2>/dev/null || true
				sleep 0.2
				kill -KILL -"$old_pid" 2>/dev/null || true

				# Last-resort: also try PID itself
				kill -KILL "$old_pid" 2>/dev/null || true
			fi
		fi

		rm -rf "$id_dir"
	}

	# --- GLOBAL CLEAN ---
	if [[ "$global_clean" == true ]]; then
		local d id
		shopt -s nullglob
		for d in "$WORK_DIR"/*/; do
			id="$(basename "$d")"
			_kill_id "$id"
		done
		shopt -u nullglob
		rm -rf "$WORK_DIR"/* 2>/dev/null || true
		return 0
	fi

	# --- GLOBAL FAILED-ONLY CLEAN ---
	if [[ "$global_failed_clean" == true ]]; then
		local d id exitf rc
		shopt -s nullglob
		for d in "$WORK_DIR"/*/; do
			id="$(basename "$d")"
			exitf="$d/exit"
			if [[ -f "$exitf" ]]; then
			rc="$(cat "$exitf" 2>/dev/null || echo 1)"
			if [[ "$rc" -ne 0 ]]; then
				_kill_id "$id"
				fi
			fi
		done
		shopt -u nullglob
		return 0
	fi

	if [[ -z "$work_id" ]]; then
		echo "Error: Work ID (-i) is required." >&2
		return 1
	fi

	local id_dir="$WORK_DIR/${work_id}"
	local lock_file="$id_dir/lock"
	local exit_file="$id_dir/exit"
	local log_out_file="$id_dir/log.out"
	local log_err_file="$id_dir/log.err"
	local cmd_file="$id_dir/cmd"
	local pid_file="$id_dir/pid"
	local history_file="$id_dir/history"

	# Append a timestamped one-line entry to the task history file
	_log_history() {
		echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$history_file"
	}

	# Create the task directory
	mkdir -p "$id_dir"
	chmod 711 "$id_dir"  # Make directory traversable (execute-only for group/others)
	
	# --- GET ERROR MODE (stderr) ---
	if [[ "$mode" == "get_error" ]]; then
		[[ -f "$log_err_file" ]] && cat "$log_err_file"
		return 0
	fi

	# --- GET OUTPUT MODE (stdout) ---
	if [[ "$mode" == "get_output" ]]; then
		[[ -f "$log_out_file" ]] && cat "$log_out_file"
		return 0
	fi

	# --- GET EXIT CODE MODE ---
	# Prints exit code to stdout if task completed, returns 0.
	# Returns 1 (prints nothing) if task has not completed.
	if [[ "$mode" == "get_exit" ]]; then
		if [[ -f "$exit_file" ]]; then
			cat "$exit_file"
			return 0
		fi
		return 1
	fi

	# --- TTL CHECK ---
	# If TTL specified and exit file exists, check if it's expired
	if [[ -n "$ttl" && -f "$exit_file" ]]; then
		local now=$(date +%s)
		local exit_mtime=$(stat -c %Y "$exit_file" 2>/dev/null || stat -f %m "$exit_file" 2>/dev/null)
		
		if [[ -n "$exit_mtime" ]]; then
			local age=$((now - exit_mtime))
			if [[ $age -gt $ttl ]]; then
				# Task output is stale, reset it
				_log_history "TTL_EXPIRED age=${age}s ttl=${ttl}s"
				_kill_id "$work_id"
				mkdir -p "$id_dir"
				chmod 711 "$id_dir"  # Make directory traversable (execute-only for group/others)
			fi
		fi
	fi

	# --- RESET/KILL ---
	if [[ "$reset" == true ]]; then
		_log_history "RESET"
		_kill_id "$work_id"
		return 0
	fi

	# --- PEEK ---
	if [[ "$mode" == "peek" ]]; then
		[[ -f "$exit_file" ]] && return 0 || return 1
	fi

	_start_task() {
		local is_fg="$1"
		local lock_held="${2:-false}"

		if [[ "$lock_held" != "true" ]]; then
			# Acquire lock via FD 9; lock remains held while subshell keeps FD open
			exec 9>>"$lock_file"
			if ! flock -n 9; then
				exec 9>&-
				return 0
			fi
		fi

		# Rotate non-empty logs before truncating (keep one previous copy for debugging)
		[[ -s "$log_out_file" ]] && mv "$log_out_file" "${log_out_file}.1"
		[[ -s "$log_err_file" ]] && mv "$log_err_file" "${log_err_file}.1"

		# Initialize log files
		: >"$log_out_file"
		: >"$log_err_file"
		rm -f "$exit_file"

		_log_history "STARTED cmd=\"$(printf '%s ' "${command[@]}")\""
		
		# Save command in two formats:
		# 1. cmd.sh - Machine-readable (declare -p) for reliable re-execution
		#    Preserves exact array structure including spaces, quotes, special chars
		# 2. cmd - Human-readable (one line) for debugging/troubleshooting
		declare -p command > "$id_dir/cmd.sh"
		printf '%s ' "${command[@]}" > "$cmd_file"
		echo >> "$cmd_file"  # trailing newline
		
		# Save current working directory for re-execution (self-healing validation)
		# Commands with relative paths need the same CWD to work correctly
		pwd > "$id_dir/cwd"
		
		# Backward compatibility: create symlink for old scripts that reference 'log'
		ln -sf log.out "$id_dir/log" 2>/dev/null || true

		(
			# Keep FD 9 open in this subshell so lock remains held until it exits.
			# Use setsid to create a new session/process group (PGID==PID we capture).
			local rc=0

			if [[ "$is_fg" == "true" ]]; then
				# Foreground-ish: stream + log
				# Capture stderr separately, combined to stdout for display
				setsid "${command[@]}" 2> >(tee -a "$log_err_file" >&2) | tee -a "$log_out_file"
				rc="${PIPESTATUS[0]}"
				echo "$rc" >"$exit_file"
				_log_history "COMPLETE rc=$rc"
				exit "$rc"
			fi

			# Background: log.out gets stdout+stderr, log.err gets only stderr
			# Close inherited stdout/stderr first so this background subshell
			# doesn't hold a parent pipeline (e.g. `cmd | tee`) open.
			exec >/dev/null 2>&1
			setsid "${command[@]}" 2> >(tee -a "$log_err_file" >> "$log_out_file") >> "$log_out_file" &
			echo $! >"$pid_file"
		chmod 644 "$pid_file"  # Make PID file readable so run_once -w can display it
			wait $!
			rc=$?
			echo "$rc" >"$exit_file"
			_log_history "COMPLETE rc=$rc"
			exit "$rc"
		) &

		# Parent closes FD; background subshell retains the lock
		exec 9>&-
		return 0
	}

	# --- start mode ---
	if [[ "$mode" == "start" ]]; then
		if [[ ${#command[@]} -eq 0 ]]; then
			echo "Error: start mode requires a command." >&2
			return 1
		fi
		
		# If exit file exists (task already completed), skip
		if [[ -f "$exit_file" ]]; then
			return 0
		fi
		
		_start_task "false"
		return 0
	fi

	# --- wait mode ---
	if [[ "$mode" == "wait" ]]; then
		# Check if exit file exists and if task was killed by signal
		if [[ -f "$exit_file" ]]; then
			local exit_code
			exit_code="$(cat "$exit_file" 2>/dev/null || echo 1)"
			
			# Exit codes 128-165 indicate termination by signal (kill, Ctrl-C, etc.)
			# These are interruptions, not legitimate failures, so treat as crash and retry
			if [[ $exit_code -ge 128 && $exit_code -le 165 ]]; then
				_log_history "SIGNAL rc=$exit_code (restarting)"
				aba_debug "Task $work_id was killed by signal (exit $exit_code), restarting..."
				rm -rf "$id_dir"
				mkdir -p "$id_dir"
				chmod 711 "$id_dir"  # Make directory traversable (execute-only for group/others)
				# Fall through to restart logic below
			fi
		fi
		
		if [[ ! -f "$exit_file" ]]; then
			exec 9>>"$lock_file"
			if flock -n 9; then
				# Lock is free => not running => implicitly start (requires command)
				# Keep FD 9 open -- lock transfers to _start_task's subshell
				if [[ ${#command[@]} -eq 0 ]]; then
					exec 9>&-   # Release lock on error path
					# Only show internal diagnostic when not in quiet mode;
					# callers that check rc already have their own error messages.
					[[ "$quiet_wait" != true ]] && \
						echo "Error: Task not started and no command provided." >&2
					return 1
				fi
				_start_task "true" "true"
				wait $!
			else
				# Running elsewhere => block until lock released
				exec 9>&-
			
			# Build and display waiting message (unless quiet mode)
			if [[ "$quiet_wait" != true ]]; then
				local msg=""
				if [[ -n "$waiting_message" ]]; then
					msg="$waiting_message"
				else
					msg="Waiting for task: $work_id"
				fi
				
				# Add PID if available
				if [[ -f "$pid_file" ]]; then
					local pid=$(<"$pid_file")
					if [[ -n "$pid" ]]; then
						msg="$msg (PID: $pid)"
					fi
				fi
				
				# Display message
				aba_info "$msg"
			fi
				
				if [[ -n "$wait_timeout" ]]; then
					# Wait with timeout
					if ! flock -w "$wait_timeout" -x "$lock_file" -c "true"; then
						echo "Error: Timeout waiting for task $work_id after ${wait_timeout}s" >&2
						return 124  # Standard timeout exit code
					fi
				else
					# Wait indefinitely
					flock -x "$lock_file" -c "true"
				fi
			fi
		fi

	local exit_code
	exit_code="$(cat "$exit_file" 2>/dev/null || echo 1)"
	# Guard against empty exit_file (concurrent write in progress)
	[[ -z "$exit_code" ]] && exit_code=1

	# --- SELF-HEALING VALIDATION ---
	# If no command provided but task previously succeeded, load saved command
	# This allows validation even when wait is called without explicit command
	if [[ $exit_code -eq 0 && ${#command[@]} -eq 0 && -f "$id_dir/cmd.sh" ]]; then
		source "$id_dir/cmd.sh"  # Reconstructs command array via declare -p
		aba_debug "Loaded saved command for validation: ${command[*]}"
	fi

	# Self-healing: re-run successful tasks to verify outputs still exist
	# Tasks are idempotent - they check their artifacts and exit quickly if valid
	# If artifacts missing (e.g. user deleted files), task recreates them automatically
	# This prevents "file not found" errors from stale cached success states
	if [[ $exit_code -eq 0 && ${#command[@]} -gt 0 && "$skip_validation" != true ]]; then
		# Check if task is currently running (lock held)
		exec 9>>"$lock_file"
		if flock -n 9; then
			# Lock acquired - safe to validate
			aba_debug "Task $work_id completed successfully, running validation..."
			
			# Restore original CWD if saved (needed for relative paths in commands)
			local saved_cwd original_cwd
			original_cwd="$(pwd)"
			if [[ -f "$id_dir/cwd" ]]; then
				saved_cwd="$(cat "$id_dir/cwd")"
				cd "$saved_cwd" || aba_debug "Warning: Could not restore CWD to $saved_cwd"
			fi
			
			# Run validation command directly (keep lock held to prevent races)
			# NOTE: Do NOT delete exit_file before validation — concurrent readers
			# at line 1676 would see it missing and get exit_code=1 (TOCTOU race).
			# Validation runs synchronously while we hold the lock
			# Rotate non-empty logs before validation (keep previous run for debugging)
			[[ -s "$log_out_file" ]] && mv "$log_out_file" "${log_out_file}.1"
			[[ -s "$log_err_file" ]] && mv "$log_err_file" "${log_err_file}.1"
			
			"${command[@]}" >"$log_out_file" 2>"$log_err_file"
			local validation_rc=$?
			# Atomic write: rename is atomic on same filesystem, avoids
			# concurrent readers seeing a truncated (empty) file
			echo "$validation_rc" > "${exit_file}.tmp" && mv -f "${exit_file}.tmp" "$exit_file"
			exit_code="$validation_rc"
			_log_history "VALIDATE rc=$validation_rc"
			
			# Restore current CWD
			cd "$original_cwd" || true
			
			# Release lock after validation complete
			exec 9>&-
			
			aba_debug "Task $work_id validation completed with exit code: $exit_code"
		else
			# Lock held - another process is running this task, skip validation
			exec 9>&-
			aba_debug "Task $work_id is currently running, skipping validation"
		fi
	fi

	if [[ "$purge" == true ]]; then
		rm -rf "$id_dir"
	fi
	return "$exit_code"
	fi

	echo "Error: Unknown mode." >&2
	return 1
}

# --- Catalog Download Helpers ---

# Download all 3 operator catalogs using run_once, throttled by CATALOG_MAX_PARALLEL
# Usage: download_all_catalogs <version_short> [ttl_seconds]
# Example: download_all_catalogs "4.19" 86400
download_all_catalogs() {
	local version_short="${1}"
	local ttl="${2:-86400}"  # Default: 1 day (86400 seconds)

	if [[ -z "$version_short" ]]; then
		echo_red "[ABA] Error: download_all_catalogs requires version (e.g., 4.19)" >&2
		return 1
	fi

	# Max concurrent catalog downloads (default: 3 = all parallel)
	# User can set CATALOG_MAX_PARALLEL=1 in ~/.aba/config for sequential
	local max_parallel="${CATALOG_MAX_PARALLEL:-3}"
	if [[ -f "$HOME/.aba/config" ]]; then
		source "$HOME/.aba/config"
		max_parallel="${CATALOG_MAX_PARALLEL:-3}"
	fi

	local catalogs=(redhat-operator certified-operator community-operator)
	local running=0

	aba_debug "Starting catalog downloads for OCP $version_short (max_parallel=$max_parallel, TTL: ${ttl}s)"

	for catalog in "${catalogs[@]}"; do
		# If at max capacity, wait for the earliest to finish before launching next
		if (( running >= max_parallel )); then
			local wait_idx=$(( running - max_parallel ))
			run_once -q -w -i "catalog:${version_short}:${catalogs[$wait_idx]}"
		fi

		run_once -i "catalog:${version_short}:${catalog}" -t "$ttl" -- \
			scripts/download-catalog-index.sh "$catalog" "$version_short"
		(( ++running ))
	done

	aba_debug "Catalog download tasks started (max_parallel=$max_parallel)"
}

# Wait for all 3 catalog downloads to complete (all required)
# Wait for all catalog downloads to complete
# Usage: wait_for_all_catalogs <version_short>
# Example: wait_for_all_catalogs "4.19"
#
# NOTE: This function is called from add-operators-to-imageset.sh where stdout
#       is redirected to YAML file. ALL user messages MUST use >&2 (stderr)!
wait_for_all_catalogs() {
	local version_short="${1}"
	
	if [[ -z "$version_short" ]]; then
		echo_red "[ABA] Error: wait_for_all_catalogs requires version (e.g., 4.19)" >&2
		return 1
	fi
	
	# Read timeout from user config (default: 20 minutes)
	local timeout_mins=20
	if [[ -f "$HOME/.aba/config" ]]; then
		source "$HOME/.aba/config"
		timeout_mins="${CATALOG_DOWNLOAD_TIMEOUT_MINS:-20}"
	fi
	local timeout_secs=$((timeout_mins * 60))
	
	aba_debug "wait_for_all_catalogs: Called for OCP $version_short (timeout: ${timeout_mins} minutes)"
	
	aba_debug "wait_for_all_catalogs: About to call run_once -w for redhat-operator"
	
	if ! run_once -w -W "$timeout_secs" -m "Waiting for redhat-operator catalog download to complete" -i "catalog:${version_short}:redhat-operator"; then
		echo_red "[ABA] Error: Failed to download redhat-operator catalog for OCP $version_short" >&2
		return 1
	fi
	aba_debug "redhat-operator catalog ready"
	
	if ! run_once -w -W "$timeout_secs" -m "Waiting for certified-operator catalog download to complete" -i "catalog:${version_short}:certified-operator"; then
		echo_red "[ABA] Error: Failed to download certified-operator catalog for OCP $version_short" >&2
		return 1
	fi
	aba_debug "certified-operator catalog ready"
	
	if ! run_once -w -W "$timeout_secs" -m "Waiting for community-operator catalog download to complete" -i "catalog:${version_short}:community-operator"; then
		echo_red "[ABA] Error: Failed to download community-operator catalog for OCP $version_short" >&2
		return 1
	fi
	aba_debug "community-operator catalog ready"
	
	# Must use stderr since stdout may be redirected to YAML file
	aba_info_ok "All catalog downloads completed for OCP $version_short" >&2
}

# --- Aba-facing cleanup ---
# Note: No automatic cleanup on Ctrl-C. Background tasks continue naturally.
# Use 'aba reset' to explicitly kill all background tasks and clean up.

# -----------------------------------------------------------------------------
# HTTP/HTTPS Probing
# -----------------------------------------------------------------------------

# Probe HTTP/HTTPS endpoint with sensible timeouts
# Usage: probe_host <url> [description]
# Returns: 0 if reachable, 1 if not
# Errors shown naturally by curl to stderr
#
# Examples:
#   probe_host "https://api.openshift.com/"
#   probe_host "https://registry:8443/health/instance" "Quay registry"
probe_host() {
	local url="$1"
	local desc="${2:-$url}"
	
	aba_debug "Probing $desc"
	
	# -s: silent (no progress bar)
	# -S: show errors even when silent
	# -f: fail on HTTP errors (4xx, 5xx)
	# Result: Errors shown, but no progress bars!
	if curl -sSf \
		--connect-timeout 5 \
		--max-time 15 \
		--retry 2 \
		-ILk \
		"$url" >/dev/null; then
		return 0
	fi
	
	return 1
}

# -----------------------------------------------------------------------------
# Validation Functions for TUI inputs
# -----------------------------------------------------------------------------

# Validate IPv4 address
# Usage: validate_ip "192.168.1.1" && echo "valid"
# Returns: 0 if valid, 1 if invalid
validate_ip() {
	local ip="$1"
	local IFS='.'
	local -a octets
	
	# Empty is invalid
	[[ -z "$ip" ]] && return 1
	
	# Split into octets
	read -ra octets <<< "$ip"
	
	# Must have exactly 4 octets
	[[ ${#octets[@]} -ne 4 ]] && return 1
	
	# Each octet must be 0-255
	for octet in "${octets[@]}"; do
		# Must be numeric
		[[ ! "$octet" =~ ^[0-9]+$ ]] && return 1
		# Must be in range 0-255
		[[ $octet -lt 0 || $octet -gt 255 ]] && return 1
		# No leading zeros (except "0" itself)
		[[ ${#octet} -gt 1 && ${octet:0:1} == "0" ]] && return 1
	done
	
	return 0
}

# Validate comma-separated IP list
# Usage: validate_ip_list "8.8.8.8,1.1.1.1" && echo "valid"
# Returns: 0 if valid, 1 if invalid
validate_ip_list() {
	local ip_list="$1"
	local IFS=','
	local -a ips
	
	# Empty is invalid
	[[ -z "$ip_list" ]] && return 1
	
	# Split by comma
	read -ra ips <<< "$ip_list"
	
	# Validate each IP
	for ip in "${ips[@]}"; do
		# Trim whitespace
		ip="${ip##[[:space:]]}"
		ip="${ip%%[[:space:]]}"
		
		# Validate this IP
		validate_ip "$ip" || return 1
	done
	
	return 0
}

# Validate CIDR notation (IPv4 only)
# Usage: validate_cidr "10.0.0.0/24" && echo "valid"
# Returns: 0 if valid, 1 if invalid
validate_cidr() {
	local cidr="$1"
	local ip prefix
	
	# Empty is invalid
	[[ -z "$cidr" ]] && return 1
	
	# Must contain exactly one slash
	[[ ! "$cidr" =~ ^[^/]+/[^/]+$ ]] && return 1
	
	# Split into IP and prefix
	ip="${cidr%/*}"
	prefix="${cidr#*/}"
	
	# Validate IP part
	validate_ip "$ip" || return 1
	
	# Validate prefix part (must be numeric 0-32)
	[[ ! "$prefix" =~ ^[0-9]+$ ]] && return 1
	[[ $prefix -lt 0 || $prefix -gt 32 ]] && return 1
	
	return 0
}

# Validate pull secret by testing authentication with registry.redhat.io
# Usage: validate_pull_secret "/path/to/pull-secret.json" && echo "valid"
# Returns: 0 if valid, 1 if invalid
validate_pull_secret() {
	local pull_secret_file="$1"
	
	if [[ ! -f "$pull_secret_file" ]]; then
		echo_red "[ABA] Error: Pull secret file not found: $pull_secret_file" >&2
		return 1
	fi
	
	# Check that pull secret contains registry.redhat.io
	if ! jq -e '.auths["registry.redhat.io"]' "$pull_secret_file" >/dev/null 2>&1; then
		echo_red "[ABA] Error: No registry.redhat.io entry in pull secret" >&2
		return 1
	fi
	
	aba_debug "Validating pull secret by testing authentication with registry.redhat.io"
	
	# Use skopeo login --get-login to quickly test credentials (much faster than inspect)
	# This returns the username if auth succeeds, non-zero if auth fails
	local error_output
	
	error_output=$(skopeo login --authfile "$pull_secret_file" --get-login registry.redhat.io 2>&1)
	local rc=$?
	
	if [[ $rc -eq 0 ]]; then
		aba_info_ok "Pull secret validated successfully"
		return 0
	else
		echo_red "[ABA] Error: Pull secret validation failed" >&2
		echo_red "[ABA]        Could not authenticate with registry.redhat.io" >&2
		
		# Parse common error messages
		if echo "$error_output" | grep -qi "unauthorized\|authentication\|credentials\|invalid"; then
			echo_red "[ABA]        Invalid credentials or expired token" >&2
		elif echo "$error_output" | grep -qi "no such host\|network\|connection"; then
			echo_red "[ABA]        Network/DNS issue (not a pull secret problem)" >&2
		fi
		
		return 1
	fi
}

# Validate domain name (basic validation)
# Usage: validate_domain "example.com" && echo "valid"
# Returns: 0 if valid, 1 if invalid
validate_domain() {
	local domain="$1"
	
	# Empty is invalid
	[[ -z "$domain" ]] && return 1
	
	# Must not start or end with dot or hyphen
	[[ "$domain" =~ ^[.-] || "$domain" =~ [.-]$ ]] && return 1
	
	# Must contain only valid characters (alphanumeric, dots, hyphens)
	[[ ! "$domain" =~ ^[a-zA-Z0-9.-]+$ ]] && return 1
	
	# Must not contain consecutive dots
	[[ "$domain" =~ \.\. ]] && return 1
	
	# Length check (1-253 chars for full domain)
	[[ ${#domain} -gt 253 ]] && return 1
	
	# Each label (part between dots) must be 1-63 chars and not start/end with hyphen
	local IFS='.'
	local -a labels
	read -ra labels <<< "$domain"
	
	for label in "${labels[@]}"; do
		# Length check
		[[ ${#label} -eq 0 || ${#label} -gt 63 ]] && return 1
		# Must not start or end with hyphen
		[[ "$label" =~ ^- || "$label" =~ -$ ]] && return 1
		# Must contain only alphanumeric and hyphens
		[[ ! "$label" =~ ^[a-zA-Z0-9-]+$ ]] && return 1
	done
	
	return 0
}

# Validate comma-separated list of NTP servers (IPs or hostnames)
# Usage: validate_ntp_servers "pool.ntp.org,time.google.com,192.168.1.1" && echo "valid"
# Returns: 0 if valid, 1 if invalid
validate_ntp_servers() {
	local server_list="$1"
	local IFS=','
	local -a servers
	
	# Empty is invalid
	[[ -z "$server_list" ]] && return 1
	
	# Split by comma
	read -ra servers <<< "$server_list"
	
	# Validate each server (must be valid IP OR valid domain/hostname)
	for server in "${servers[@]}"; do
		# Trim whitespace
		server="${server##[[:space:]]}"
		server="${server%%[[:space:]]}"
		
		# Try to validate as IP first, then as domain/hostname
		if ! validate_ip "$server" && ! validate_domain "$server"; then
			# Special case: single-label hostnames without dots are OK
			# (e.g., "ntp", "timeserver", "localhost")
			if [[ "$server" =~ ^[a-zA-Z0-9-]+$ ]] && [[ ! "$server" =~ ^- ]] && [[ ! "$server" =~ -$ ]] && [[ ${#server} -le 63 ]]; then
				continue  # Valid single-label hostname
			fi
			return 1  # Invalid
		fi
	done
	
	return 0
}


# ============================================
# CLI Tool Management Functions
# Centralized task IDs and installation logic
# ============================================

# Task IDs (single source of truth)
# Guard against re-declaration when include_all.sh is sourced multiple times
if [[ -z "${TASK_OC_MIRROR+x}" ]]; then
	readonly TASK_OC_MIRROR="cli:install:oc-mirror"
	readonly TASK_OC="cli:install:oc"
	readonly TASK_OPENSHIFT_INSTALL="cli:install:openshift-install"
	readonly TASK_GOVC="cli:install:govc"
	readonly TASK_BUTANE="cli:install:butane"
	readonly TASK_QUAY_REG_DOWNLOAD="mirror:reg:download"
	readonly TASK_QUAY_REG="mirror:reg:install"
fi

# Start all CLI tarball downloads (parallel, non-blocking)
start_all_cli_downloads() {
	scripts/cli-download-all.sh
}

# Wait for all CLI tarball downloads to complete
wait_all_cli_downloads() {
	scripts/cli-download-all.sh --wait
}

# Ensure oc-mirror is installed in ~/bin
ensure_oc_mirror() {
	# Wait for oc-mirror download to complete before extracting
	# (cli-download-all.sh starts downloads in background; extracting a
	#  partially-downloaded tarball causes "gzip: unexpected end of file" errors)
	run_once -q -w -i "cli:download:oc-mirror"
	run_once -w -m "Installing oc-mirror to ~/bin" -i "$TASK_OC_MIRROR" -- make -sC cli oc-mirror
}

# Ensure oc CLI is installed in ~/bin
ensure_oc() {
	if [[ -z "${ocp_version:-}" ]]; then
		aba_debug "ensure_oc: ocp_version not set, skipping"
		return 0
	fi
	run_once -q -w -i "cli:download:oc:${ocp_version}"
	run_once -w -m "Installing oc to ~/bin" -i "$TASK_OC" -- make -sC cli oc
}

# Ensure openshift-install is installed in ~/bin
ensure_openshift_install() {
	if [[ -z "${ocp_version:-}" ]]; then
		aba_debug "ensure_openshift_install: ocp_version not set, skipping"
		return 0
	fi
	run_once -q -w -i "cli:download:openshift-install:${ocp_version}"
	run_once -w -m "Installing openshift-install to ~/bin" -i "$TASK_OPENSHIFT_INSTALL" -- make -sC cli openshift-install
}

# Ensure govc is installed in ~/bin
ensure_govc() {
	run_once -q -w -i "cli:download:govc"
	run_once -w -m "Installing govc to ~/bin" -i "$TASK_GOVC" -- make -sC cli govc
}

# Ensure butane is installed in ~/bin
ensure_butane() {
	run_once -q -w -i "cli:download:butane"
	run_once -w -m "Installing butane to ~/bin" -i "$TASK_BUTANE" -- make -sC cli butane
}

# Ensure mirror-registry (Quay) is installed (extracted)
ensure_quay_registry() {
	# Note: Download should already be started (like CLI tools)
	# Called via ensure-cli.sh which cds to ABA_ROOT, so use -C mirror
	run_once -w -m "Installing mirror-registry" -i "$TASK_QUAY_REG" -- make -sC mirror mirror-registry
}

# Get error output from a task (helper for error messages)
get_task_error() {
	local task_id="$1"
	run_once -e -i "$task_id"
}

# Check internet connectivity to required sites
# Usage: check_internet_connectivity <prefix> [quiet]
#   prefix: Task ID prefix (e.g., "cli" or "tui")
#   quiet:  If "true", suppress checking message (default: false)
# Returns: 0 if all sites accessible, 1 if any failed
# Sets global variables: FAILED_SITES, ERROR_DETAILS (for caller to handle)
check_internet_connectivity() {
	local prefix="$1"
	local quiet="${2:-false}"
	
	# Check if we need to run the checks (not cached)
	local need_check=false
	if ! run_once -p -i "${prefix}:check:api.openshift.com" >/dev/null 2>&1 || \
	   ! run_once -p -i "${prefix}:check:mirror.openshift.com" >/dev/null 2>&1 || \
	   ! run_once -p -i "${prefix}:check:registry.redhat.io" >/dev/null 2>&1; then
		need_check=true
	fi
	
	# Start all three checks in parallel (lightweight curl HEAD requests, 5-min TTL)
	run_once -t 300 -i "${prefix}:check:api.openshift.com" -- curl -sL --head --connect-timeout 5 --max-time 10 https://api.openshift.com/
	run_once -t 300 -i "${prefix}:check:mirror.openshift.com" -- curl -sL --head --connect-timeout 5 --max-time 10 https://mirror.openshift.com/
	run_once -t 300 -i "${prefix}:check:registry.redhat.io" -- curl -sL --head --connect-timeout 5 --max-time 10 https://registry.redhat.io/
	
	# Now wait for all three and check results (quietly, no waiting messages)
	FAILED_SITES=""
	ERROR_DETAILS=""
	
	if ! run_once -w -q -S -i "${prefix}:check:api.openshift.com"; then
		FAILED_SITES="api.openshift.com"
		local err_msg=$(run_once -e -i "${prefix}:check:api.openshift.com" | head -1)
		[[ -z "$err_msg" ]] && err_msg="Connection failed"
		ERROR_DETAILS="api.openshift.com: $err_msg"
	fi
	
	if ! run_once -w -q -S -i "${prefix}:check:mirror.openshift.com"; then
		[[ -n "$FAILED_SITES" ]] && FAILED_SITES="$FAILED_SITES, "
		FAILED_SITES="${FAILED_SITES}mirror.openshift.com"
		local err_msg=$(run_once -e -i "${prefix}:check:mirror.openshift.com" | head -1)
		[[ -z "$err_msg" ]] && err_msg="Connection failed"
		[[ -n "$ERROR_DETAILS" ]] && ERROR_DETAILS="$ERROR_DETAILS"$'\n'"  "
		ERROR_DETAILS="${ERROR_DETAILS}mirror.openshift.com: $err_msg"
	fi
	
	if ! run_once -w -q -S -i "${prefix}:check:registry.redhat.io"; then
		[[ -n "$FAILED_SITES" ]] && FAILED_SITES="$FAILED_SITES, "
		FAILED_SITES="${FAILED_SITES}registry.redhat.io"
		local err_msg=$(run_once -e -i "${prefix}:check:registry.redhat.io" | head -1)
		[[ -z "$err_msg" ]] && err_msg="Connection failed"
		[[ -n "$ERROR_DETAILS" ]] && ERROR_DETAILS="$ERROR_DETAILS"$'\n'"  "
		ERROR_DETAILS="${ERROR_DETAILS}registry.redhat.io: $err_msg"
	fi
	
	# Return status
	[[ -z "$FAILED_SITES" ]] && return 0 || return 1
}
