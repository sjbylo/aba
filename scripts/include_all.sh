# =============================================================================
# INTENT:      Shared functions and setup for all ABA scripts.
#              Provides: color output, config normalize/verify, IP math,
#              run_once, ensure_* tool installers, cluster state helpers
#              (ADR-007), HTTP probing, TUI validation, CLI tool management.
# CALLED BY:   Every script via 'source scripts/include_all.sh'
# CWD:         Varies (caller's working directory)
# REQUIRES:    Nothing (self-contained)
# PRODUCES:    No stdout (only function definitions and variable setup)
# SIDE EFFECTS: Sets ARCH, SUDO, sources ~/.aba/config if present
# IDEMPOTENT:  Yes (safe to source multiple times via _INCLUDE_ALL_LOADED guard)
# ENV:         DEBUG_ABA (optional), ABA_TTY_FD (optional), PLAIN_OUTPUT (optional)
# =============================================================================
# Ensure this script does not create any std output.
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

# Source user overrides (e.g. OC_MIRROR_IMAGE_TIMEOUT) if present
[[ -f "$HOME/.aba/config" ]] && source "$HOME/.aba/config"

# Per-user temp directory for all ABA internal temp files (flag files, caches, debug logs)
ABA_TMP="/tmp/.aba-${USER:-$(id -un)}"
mkdir -p "$ABA_TMP"

_ABA_CONF_ERR="Invalid or incomplete aba.conf. Check the errors above, fix aba.conf or run aba or ./abatui."

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

    if [ -t "${ABA_TTY_FD:-1}" ] && [ "$(tput colors 2>/dev/null)" -ge 8 ] && [ -z "${PLAIN_OUTPUT:-}" ]; then
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

_aba_debug_last=
aba_debug() {
    local newline=1

    # Suppress consecutive duplicate messages (e.g. polling loops)
    [ "$*" = "$_aba_debug_last" ] && return 0
    _aba_debug_last="$*"

    # Detect and consume "-n" if it's the first argument
    if [[ "$1" == "-n" ]]; then
        newline=0
        shift
    fi

    local timestamp
    timestamp="$(date +%H:%M:%S)"

    if [ "${DEBUG_ABA:-}" ]; then
        # Debug mode: write to terminal (stderr). The exec tee in aba.sh
        # will also capture this into the trace file -- no direct write needed.
        [ "$TERM" ] && { tput el1 && tput cr; } >&2
        if (( newline )); then
            echo_magenta    "[ABA_DEBUG] ${timestamp}: $*" >&2
        else
            echo_magenta -n "[ABA_DEBUG] ${timestamp}: $*" >&2
        fi
    elif [ -n "${ABA_TRACE_FILE:-}" ] && [ -w "${ABA_TRACE_FILE:-}" ]; then
        # Non-debug mode: write directly to trace file only (not visible on terminal)
        if (( newline )); then
            echo "[ABA_DEBUG] ${timestamp}: $*" >> "$ABA_TRACE_FILE"
        else
            echo -n "[ABA_DEBUG] ${timestamp}: $*" >> "$ABA_TRACE_FILE"
        fi
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

# Non-fatal error (like aba_abort but does NOT exit)
aba_error() {
	echo_red "[ABA] Error: $*" >&2
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

vm_name() {
	# For SNO the hostname equals the cluster name; avoid doubling (e.g. sno1-sno1)
	local cluster=$1 host=$2
	[ "${CP_REPLICAS:-${num_masters:-0}}" = "1" ] && [ "${WORKER_REPLICAS:-${num_workers:-0}}" = "0" ] && echo "$host" || echo "${cluster}-${host}"
}

_vm_annotation() {
	local role=$1
	local cluster_type
	if [ "${CP_REPLICAS:-3}" = "1" ] && [ "${WORKER_REPLICAS:-0}" = "0" ]; then
		cluster_type=sno
	elif [ "${WORKER_REPLICAS:-0}" = "0" ]; then
		cluster_type=compact
	else
		cluster_type=standard
	fi
	local aba_ver
	aba_ver="$(cat "${ABA_ROOT:-..}/VERSION" 2>/dev/null || echo unknown)"
	local role_label
	[ "$role" = "control" ] && role_label="Control" || role_label="Worker"
	cat <<-EOF
	OpenShift ${role_label} Node (${cluster_type}), initial version v${ocp_version}
	Installed by ABA v${aba_ver} (github.com/sjbylo/aba) on $(date)
	Console: https://console-openshift-console.apps.${CLUSTER_NAME}.${base_domain}
	API: https://api.${CLUSTER_NAME}.${base_domain}:6443
	Manage from $(hostname):${PWD} — aba -d ${CLUSTER_NAME} [info|startup|shutdown|delete]
	EOF
}

# Select which VM hosts to operate on based on workers=/masters= args.
# Sets the caller's $hosts variable. Defaults to all VMs (workers + masters).
_select_vm_hosts() {
	if [ "${workers:-}" ]; then
		hosts="$WORKER_NAMES"
	elif [ "${masters:-}" ]; then
		hosts="$CP_NAMES"
	else
		hosts="${WORKER_NAMES:+$WORKER_NAMES }$CP_NAMES"
	fi
	if [ -z "$hosts" ]; then
		hosts="$CP_NAMES"
	fi
	return 0
}

# Output names of VMs that are currently poweredOn (VMware).
# Requires: govc, jq, $CLUSTER_NAME, vm_name()
vmw_running_vms() {
	local name vm power_state
	for name in "$@"; do
		vm=$(vm_name "$CLUSTER_NAME" "$name")
		power_state=$(govc vm.info -json "$vm" 2>/dev/null | jq -r '.virtualMachines[0].runtime.powerState' || true)
		if [ "$power_state" = "poweredOn" ]; then
			echo "$name"
		fi
	done
}

# Output names of VMs that are currently running (KVM).
# Requires: virsh, $CLUSTER_NAME, $LIBVIRT_URI, vm_name()
kvm_running_vms() {
	local name vm _state
	for name in "$@"; do
		vm=$(vm_name "$CLUSTER_NAME" "$name")
		_state=$(virsh -c "$LIBVIRT_URI" domstate "$vm" 2>/dev/null || true)
		if [ "$_state" = "running" ]; then
			echo "$name"
		fi
	done
}

# Shared sanitizer for normalize-*-conf() pipelines.  Reads config lines from
# stdin, cleans them up, and prepends "export " to each line.
#
# Steps:
#   1. Remove full-line comments (lines starting with optional whitespace then #)
#   2. Delete blank/whitespace-only lines
#   3. Strip leading whitespace (config files may be indented)
#   4. Strip trailing whitespace
#   5. Strip trailing comments outside single-quoted values
#      e.g. reg_pw='pass#word' # comment  ->  reg_pw='pass#word'
#      The regex skips over paired single-quote groups so # inside quotes is preserved
#   6. Strip trailing whitespace again (residue left after comment removal)
#   7. Prepend "export " to each surviving line
_normalize_export() {
	sed -E \
		-e "s/^\s*#.*//g" \
		-e '/^[ \t]*$/d' \
		-e "s/^[ \t]*//g" \
		-e "s/[ \t]*$//g" \
		-e "s/^(([^']*'[^']*')*[^']*)#.*$/\1/" \
		-e "s/[ \t]*$//g" \
		-e "s/^/export /"
}

normalize-aba-conf() {
	# Output only the values from aba.conf (with defaults for backwards compat).
	# Derived/computed values belong in the calling script, not here.
	[ ! -s aba.conf ] && echo "ask=true" && return 0  # if aba.conf is missing, output a safe default, "ask=true"

	# Sanitize config, normalize boolean flags (users may write =0/=1/=true/=false),
	# and split machine_network CIDR into two vars (machine_network + prefix_length).
	_normalize_export < aba.conf | \
		sed -E	\
			-e "s/ask=0\b/ask=/g" -e "s/ask=false/ask=/g" \
			-e "s/ask=1\b/ask=true/g" \
			-e "s/excl_platform=0\b/excl_platform=/g" -e "s/excl_platform=false/excl_platform=/g" \
			-e "s/verify_conf=0\b/verify_conf=off/g" -e "s/verify_conf=false/verify_conf=off/g" \
			-e "s/verify_conf=1\b/verify_conf=all/g" -e "s/verify_conf=true/verify_conf=all/g" \
			-e 's#(machine_network=[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/#\1\nexport prefix_length=#g'

	# Resolve derived values immediately — deferred expansion like ${ocp_version%%.*}
	# breaks when callers use eval "$(normalize-aba-conf)" because the shell expands
	# the ${} before eval processes the exports.
	local _ocp_ver
	_ocp_ver=$(sed -n 's/^[[:space:]]*ocp_version=//p' aba.conf | sed -E 's/[[:space:]]*#.*//; s/[[:space:]]*$//' | head -1)

	# Default verify_conf to "all" if not set or empty in config
	grep -q '^verify_conf=\S' aba.conf 2>/dev/null || echo "export verify_conf=all"

	[ "${ASK_OVERRIDE:-}" ] && echo export ask= || true  # If -y provided, then override the value of ask= in aba.conf
	# "true" needed, otherwise this function returns non-zero (error)

	# Derived variable: OCP major version number (e.g. "4" from "4.21.14", "5" from "5.0.3").
	# Used for CDN paths (openshift-v4/, openshift-v5/), art-dev repos, registry paths, etc.
	[ "$_ocp_ver" ] && echo "export ocp_major=${_ocp_ver%%.*}"
}

warn_if_cluster_unstable() {
	local _co_unavail
	aba_debug "Running: oc get co --no-headers (cluster stability check)"
	_co_unavail=$(oc get co --no-headers 2>/dev/null | awk '$3 != "True" { printf "%s ", $1 }')
	if [ -n "${_co_unavail% }" ]; then
		aba_warning "Cluster is still reconciling -- some ClusterOperators are not yet available: ${_co_unavail% }. Check: oc get co"
	fi

	aba_debug "Running: oc get mcp (MCP update check)"
	if oc get mcp -o jsonpath='{.items[*].status.conditions[?(@.type=="Updating")].status}' 2>/dev/null \
		| grep -q True; then
		aba_warning "MachineConfigPool is updating -- nodes may be restarting. If this fails, retry after: oc wait mcp --all --for=condition=Updated"
	fi
}

# Check if the cluster install is truly complete (all three success criteria).
# Returns 0 if ready, 1 if not. Requires oc to be authenticated.
# Criteria: ClusterVersion Available=True, Progressing=False, no Degraded operators.
cluster_is_ready() {
	local _cv_available _cv_progressing _degraded_count

	aba_debug "Running: oc get clusterversion (readiness check)"

	_cv_available=$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)
	[ "$_cv_available" = "True" ] || return 1

	_cv_progressing=$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null)
	[ "$_cv_progressing" = "False" ] || return 1

	_degraded_count=$(oc get co -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Degraded")].status}{"\n"}{end}' 2>/dev/null | grep -c "True" || true)
	[ "$_degraded_count" -eq 0 ] || return 1

	return 0
}

# Relaxed health check: only verifies the cluster API is reachable and functional.
# Use for upgrade pre-checks where "Available=True" is sufficient — a cluster with
# Progressing operators or a flapping Degraded operator can still accept upgrades.
# Reserve cluster_is_ready() for install-completion detection (strict).
cluster_is_accessible() {
	local _cv_available

	aba_debug "Running: oc get clusterversion (accessibility check)"

	_cv_available=$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)
	[ "$_cv_available" = "True" ] || return 1

	return 0
}

# Auto-detect that a cluster install has completed.
# If kubeconfig exists but .install-complete is missing, probe the cluster API.
# If the cluster is ready, create the marker and externalize state.
# Usage: auto_complete_install <cluster-dir>  (absolute or relative to ABA_ROOT)
auto_complete_install() {
	local dir="${1:?usage: auto_complete_install <dir>}"
	local abs_dir

	# Resolve to absolute path
	if [[ "$dir" == /* ]]; then
		abs_dir="$dir"
	else
		abs_dir="${ABA_ROOT:-$PWD}/$dir"
	fi

	# Already completed — nothing to do
	[[ -f "$abs_dir/.install-complete" ]] && return 0

	# Find kubeconfig — check externalized state first, then local path
	local kc
	kc=$(cd "$abs_dir" && cluster_kubeconfig 2>/dev/null) || true
	[[ -z "$kc" ]] && kc="$abs_dir/iso-agent-based/auth/kubeconfig"
	[[ -f "$kc" ]] || return 1

	# Probe the cluster with a short timeout
	local saved_kc="${KUBECONFIG:-}"
	export KUBECONFIG="$kc"

	# Quick connectivity check — bail fast if API is unreachable
	oc version --request-timeout=5s >/dev/null 2>&1 || {
		[[ -n "$saved_kc" ]] && export KUBECONFIG="$saved_kc" || unset KUBECONFIG
		return 1
	}

	if cluster_is_ready; then
		touch "$abs_dir/.install-complete"
		aba_info "Cluster install completed — created .install-complete marker."
		# Externalize state if not already done
		if [[ ! -L "$abs_dir/clusterstate" ]]; then
			( cd "$abs_dir" && externalize_cluster_state ) || true
		fi
	fi

	# Restore KUBECONFIG
	if [[ -n "$saved_kc" ]]; then
		export KUBECONFIG="$saved_kc"
	else
		unset KUBECONFIG
	fi
}

verify-aba-conf() {
	[ "$verify_conf" = "off" ] && return 0
	[ -f aba.conf -a ! -s aba.conf ] && echo_red "$PWD/aba.conf file is empty!" && return 1
	[ ! -s aba.conf ] && return 0

	local ret=0
	local REGEX_VERSION='[0-9]+\.[0-9]+\.[0-9]+(-[a-z]+\.[0-9]+)?'
	local REGEX_BASIC_DOMAIN='^[A-Za-z0-9.-]+\.[A-Za-z]{1,}$'

	echo $ocp_version | grep -q -E $REGEX_VERSION || { echo_red "Error: ocp_version incorrectly set or missing in aba.conf.  Run aba or aba --help" >&2; ret=1; }
	echo $ocp_channel | grep -q -E "fast|stable|candidate|eus" || { echo_red "Error: ocp_channel incorrectly set or missing in aba.conf.  Run aba or aba --help" >&2; ret=1; }
	echo $platform    | grep -q -E "bm|vmw|kvm" || { echo_red "Error: platform incorrectly set or missing in aba.conf: [$platform]" >&2; ret=1; }
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

_expand_tilde() {
	case "$1" in
		"~/"*) echo "$HOME/${1#\~/}" ;;
		"~")   echo "$HOME" ;;
		*)     echo "$1" ;;
	esac
}

normalize-mirror-conf()
{
	# Output only the values from mirror.conf (with defaults for backwards compat).
	# Derived/computed values (e.g. regcreds_dir) belong in the calling script, not here.

	grep -q '^reg_vendor=' mirror.conf 2>/dev/null	|| echo export reg_vendor=auto

	[ ! -s mirror.conf ] &&                                                              return 0

	(
		# Sanitize config, then:
		#   - Mask empty/~/whitespace data_dir to \~ (expanded on remote host later)
		#   - Ensure reg_path starts with / (user convenience: reg_path=mypath -> /mypath)
		_normalize_export < mirror.conf | \
			sed -E	\
				-e 's/^(export data_dir=)([[:space:]].*|#.*|~|$)/\1\\~/' \
				-e 's#^(export reg_path=)([^/ \t])#\1/\2#g'
	)

	# Phase 3 (ADR-007): override immutable fields from installed state
	local _mn
	_mn=$(basename "$PWD")
	if [ -s "$HOME/.aba/mirror/$_mn/state.sh" ]; then
		_state_override_mirror "$_mn"
	fi
}

verify-mirror-conf() {
	[ "$verify_conf" = "off" ] && return 0
	# If the file exists and is empty?
	#[ -f mirror.conf -a ! -s mirror.conf ] && echo_red "$PWD/mirror.conf file is empty!" && return 1  # Causes error when installing cluster directly form internet
	[ ! -s mirror.conf ] && return 0

	local ret=0

	echo $reg_host | grep -q -E '^[A-Za-z0-9.-]+\.[A-Za-z]{1,}$' || { echo_red "Error: reg_host is invalid in mirror.conf [$reg_host]" >&2; ret=1; }
	[ ! "$reg_host" ] && echo_red "Error: reg_host value is missing in mirror.conf" >&2 && ret=1

	####[ ! "$reg_ssh_user" ] && echo_red "Error: reg_ssh_user not defined!" >&2 && ret=1   # This should never happen as the user name (whoami) is added above if its empty.

	[ "$reg_root" ] && [ ! "$data_dir" ] &&  echo_red "Error: 'reg_root' is deprecated. Use 'data_dir' instead in 'mirror/mirror.conf'" >&2 && ret=1 

	REGEX_ABS_PATH='^(~(/([A-Za-z0-9._-]+(/)?)*|$)|/([A-Za-z0-9._-]+(/)?)*$)'

	[ "$data_dir" ] && { echo $data_dir | grep -Eq "$REGEX_ABS_PATH" || { echo_red "Error: data_dir is invalid in mirror.conf [$data_dir]" >&2; ret=1; }; }

	[ "$reg_path" ] && { echo $reg_path | grep -Eq "$REGEX_ABS_PATH" || { echo_red "Error: reg_path is invalid in mirror.conf [$reg_path]" >&2; ret=1; }; }

	[ "$reg_ssh_key" ] && { echo $reg_ssh_key | grep -Eq "$REGEX_ABS_PATH" || { echo_red "Error: reg_ssh_key is invalid in mirror.conf [$reg_ssh_key]" >&2; ret=1; }; }

	[ "$reg_vendor" ] && { echo "$reg_vendor" | grep -qE '^(auto|quay|docker|existing)$' || { echo_red "Error: reg_vendor must be auto, quay, docker, or existing in mirror.conf [$reg_vendor]" >&2; ret=1; }; }

	# Quay's mirror-registry passes the password through shell+Ansible without escaping.
	# These chars break install or silently corrupt the password (upstream bug).
	if [ "$reg_pw" ] && [ "${reg_vendor:-auto}" != "docker" ]; then
		case "$reg_pw" in
			*\`*) echo_red "Error: reg_pw contains a backtick (\`) which breaks Quay install. Remove it or use reg_vendor=docker." >&2; ret=1 ;;
			*'"'*) echo_red "Error: reg_pw contains a double-quote (\") which breaks Quay install. Remove it or use reg_vendor=docker." >&2; ret=1 ;;
			*"'"*) echo_red "Error: reg_pw contains a single-quote (') which breaks Quay install. Remove it or use reg_vendor=docker." >&2; ret=1 ;;
			*'$'*) echo_red "Error: reg_pw contains a dollar sign (\$) which breaks Quay install. Remove it or use reg_vendor=docker." >&2; ret=1 ;;
		esac
	fi

	return $ret
}

normalize-cluster-conf()
{
	# Output only the values from cluster.conf (with defaults for backwards compat).
	# Derived/computed values (e.g. regcreds_dir) belong in the calling script, not here.

	grep -q ^mirror_name= cluster.conf 2>/dev/null	|| echo export mirror_name=mirror

	[ ! -s cluster.conf ] &&                                                               return 0

	# Sanitize config, then:
	#   - Split machine_network CIDR (e.g. 10.0.1.0/24) into machine_network + prefix_length
	#   - Normalize old int_connection=none to empty (backward compat)
	_normalize_export < cluster.conf | \
		sed -E	\
			-e 's#(machine_network=[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/#\1\nexport prefix_length=#g' \
			-e 's/^(export )int_connection=none/\1int_connection= /g'

	# Add any missing default values, mainly for backwards compat.
	grep -q ^hostPrefix= cluster.conf	|| echo export hostPrefix=23
	# If int_connection does not exist or has no value and proxy is available, then output int_connection=proxy
	grep -q "^int_connection=\S*" cluster.conf || { grep -E -q "^proxy=\S" cluster.conf	&& echo export int_connection=proxy; }

	# Phase 3 (ADR-007): override immutable fields from installed state
	local _cn _sd_candidate
	_cn=$(grep '^cluster_name=' cluster.conf 2>/dev/null | head -1 | sed 's/[[:space:]]*#.*//' | cut -d= -f2 | xargs)
	if [ "$_cn" ]; then
		for _sd_candidate in "$HOME/.aba/clusters/${_cn}."*; do
			if [ -s "$_sd_candidate/state.sh" ]; then
				local _bd_state
				_bd_state=$(grep '^base_domain=' "$_sd_candidate/state.sh" 2>/dev/null | head -1 | cut -d= -f2)
				[ "$_bd_state" ] && _state_override_cluster "$_cn" "$_bd_state"
				break
			fi
		done
	fi
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

# Suggest a sensible starting IP for cluster nodes within a CIDR.
# Picks network_base + 100 to skip common infra addresses (routers, DNS, DHCP).
# If the range is too small for +100, falls back to 75% through the usable range.
# Args: NETWORK_ADDR  PREFIX_LEN
# Example: suggest_starting_ip 10.0.0.0 20 => 10.0.0.100
suggest_starting_ip() {
	local net_addr="$1" prefix="$2"
	local net_int=$(ip_to_int "$net_addr")
	local host_count=$(cidr_host_count "$prefix")
	[ "$host_count" -eq 0 ] && return 1
	local offset=100
	[ $offset -gt $host_count ] && offset=$(( host_count * 3 / 4 ))
	[ $offset -lt 1 ] && offset=1
	int_to_ip $(( net_int + offset ))
}

# -----------------------------------------------------------------------------
# Cluster State Helpers (ADR-007: unified state management)
# Scripts use these instead of hard-coding ~/.aba/ paths.
# Convenience symlinks (clusterstate) exist for humans; scripts use these.
# -----------------------------------------------------------------------------

# Returns path to the external state dir for a cluster.
# Key is cluster_name.base_domain (e.g. sno.example.com) for global uniqueness.
# Usage: cluster_state_dir [name [domain]]
cluster_state_dir() {
	local name="${1:-${cluster_name:-${CLUSTER_NAME:-}}}"
	local domain="${2:-${base_domain:-${BASE_DOMAIN:-}}}"
	[ -z "$name" ] && return 1
	[ -z "$domain" ] && return 1
	echo "$HOME/.aba/clusters/$name.$domain"
}

# Returns path to kubeconfig (prefers external state, falls back to local)
cluster_kubeconfig() {
	local _sd
	_sd=$(cluster_state_dir "$@") || return 1
	local local_path="iso-agent-based/auth/kubeconfig"
	if [[ -f "$_sd/kubeconfig" ]]; then
		echo "$_sd/kubeconfig"
	elif [[ -f "$local_path" ]]; then
		echo "$PWD/$local_path"
	fi
}

# Check if a cluster has externalized state (installed at least once)
cluster_is_installed() {
	local _sd
	_sd=$(cluster_state_dir "$@") || return 1
	[[ -s "$_sd/state.sh" ]]
}

# Externalize cluster state to ~/.aba/clusters/<name>.<domain>/
# Copies auth, config backups, and creates clusterstate symlink.
# Must be called from the cluster directory (e.g. ~/aba/sno/).
# Requires: normalize-aba-conf and normalize-cluster-conf already sourced,
#           or will source them itself.
externalize_cluster_state() {
	[ -z "${cluster_name:-}" ] && source <(normalize-cluster-conf)
	[ -z "${platform:-}" ] && source <(normalize-aba-conf)

	[ -z "${cluster_name:-}" ] && aba_warning "externalize_cluster_state: cluster_name not set" && return 1
	[ -z "${base_domain:-}" ] && aba_warning "externalize_cluster_state: base_domain not set" && return 1

	local _assets_dir="${ASSETS_DIR:-iso-agent-based}"

	# Derive cluster_type from replica counts
	local _cluster_type
	if [ "${num_masters:-3}" = "1" ] && [ "${num_workers:-0}" = "0" ]; then
		_cluster_type=sno
	elif [ "${num_workers:-0}" = "0" ]; then
		_cluster_type=compact
	else
		_cluster_type=standard
	fi

	local _state_dir
	_state_dir=$(cluster_state_dir "$cluster_name" "$base_domain")
	mkdir -p "$_state_dir/backup"
	chmod 700 "$_state_dir"
	chmod 700 "$(dirname "$_state_dir")"

	# Write state.sh (lowercase vars, sourceable)
	cat > "$_state_dir/state.sh" <<-EOF
	cluster_name=$cluster_name
	base_domain=$base_domain
	cluster_type=$_cluster_type
	platform=${platform:-bm}
	starting_ip=${starting_ip:-}
	machine_network=${machine_network:-}
	prefix_length=${prefix_length:-}
	cp_names="${cp_names:-}"
	worker_names="${worker_names:-}"
	mirror_name=${mirror_name:-mirror}
	installed_from="$PWD"
	installed_on="$(date -Iseconds)"
	EOF

	# Copy auth files
	[ -f "$_assets_dir/auth/kubeconfig" ] && cp -p "$_assets_dir/auth/kubeconfig" "$_state_dir/"
	[ -f "$_assets_dir/auth/kubeadmin-password" ] && cp -p "$_assets_dir/auth/kubeadmin-password" "$_state_dir/"

	# Backup config files (preserve timestamps for Make)
	[ -f cluster.conf ] && cp -p cluster.conf "$_state_dir/backup/"
	[ -f install-config.yaml ] && cp -p install-config.yaml "$_state_dir/backup/"
	[ -f agent-config.yaml ] && cp -p agent-config.yaml "$_state_dir/backup/"
	[ -f macs.conf ] && cp -p macs.conf "$_state_dir/backup/"

	# Backup marker/flag files
	local _flag
	for _flag in .install-complete .init .preflight-done .bm-message .bm-nextstep .autopoweroff .autoupload .autorefresh .auto-agent-up .bootstrap-complete; do
		[ -f "$_flag" ] && cp -p "$_flag" "$_state_dir/backup/"
	done

	# Convenience symlink
	ln -sfn "$_state_dir" clusterstate

	aba_info "Cluster state saved to $_state_dir/"
}

# Emit export lines that override immutable cluster fields from state.sh.
# Called at the end of normalize-cluster-conf() so state wins over config.
# Drift (config != state) triggers a visible warning — cluster.conf should
# NOT be edited for immutable fields after install.  Delete cluster first.
_state_override_cluster() {
	local _name="$1" _domain="$2"
	local _state="$HOME/.aba/clusters/$_name.$_domain/state.sh"
	local _immutable="cluster_name base_domain starting_ip cluster_type machine_network prefix_length platform"
	local _warn_fields="cluster_name base_domain starting_ip cluster_type platform"
	local _field _sval _cval

	for _field in $_immutable; do
		_sval=$(grep "^${_field}=" "$_state" 2>/dev/null | head -1 | cut -d= -f2-)
		[ -z "$_sval" ] && continue
		case " $_warn_fields " in
			*" $_field "*)
				_cval=$(grep "^${_field}=" cluster.conf 2>/dev/null | head -1 | cut -d= -f2- | sed 's/[[:space:]]*#.*//')
				if [ "$_cval" ] && [ "$_cval" != "$_sval" ]; then
					aba_warning \
						"cluster.conf has '${_field}=${_cval}' but installed cluster has '${_field}=${_sval}'." \
						"Using installed value. If needed, run 'aba -d $_name delete' before changing cluster.conf."
				fi
				;;
		esac
		echo "export ${_field}=${_sval}"
	done
}

# Emit export lines that override immutable mirror fields from state.sh.
# Called at the end of normalize-mirror-conf() so state wins over config.
# Drift (config != state) triggers a visible warning — mirror.conf should
# NOT be edited after install.  Uninstall first, then change mirror.conf.
# Warning is shown once per process to avoid noisy repeated output.
_state_override_mirror() {
	local _name="$1" _state="$HOME/.aba/mirror/$1/state.sh"
	local _immutable="reg_host reg_port reg_vendor reg_root reg_user reg_pw"
	local _field _sval _cval _drifted=""

	for _field in $_immutable; do
		_sval=$(grep "^${_field}=" "$_state" 2>/dev/null | head -1 | cut -d= -f2-)
		[ -z "$_sval" ] && continue
		_cval=$(grep "^${_field}=" mirror.conf 2>/dev/null | head -1 | cut -d= -f2- | sed 's/[[:space:]]*#.*//')
		if [ "$_cval" ] && [ "$_cval" != "$_sval" ]; then
			_drifted="${_drifted:+$_drifted, }${_field}=${_cval} (installed: ${_sval})"
		fi
		echo "export ${_field}=${_sval}"
	done

	# Show drift warning once per aba invocation (file flag using parent PID)
	if [ -n "$_drifted" ] && [ ! -f "$ABA_TMP/drift.$$" ]; then
		touch "$ABA_TMP/drift.$$"
		aba_warning \
			"mirror.conf differs from installed registry: $_drifted" \
			"Using installed values. To change, run 'aba -d $(basename "$PWD") uninstall' first, then edit mirror.conf."
	fi
}

# Recreate a deleted cluster directory from externalized state backup.
# Returns 0 if successfully recreated, 1 if no backup exists.
# backup/ holds everything needed: configs, markers, macs.conf.
_recreate_cluster_dir() {
	local _name="$1" _domain="$2"
	local _state_dir="$HOME/.aba/clusters/$_name.$_domain"
	local _backup="$_state_dir/backup"

	[ -s "$_state_dir/state.sh" ] || return 1
	[ -s "$_backup/cluster.conf" ] || return 1

	aba_info "Recreating cluster directory '$_name' from state backup"

	mkdir -p "$_name"
	cp -pa "$_backup/." "$_name/"
	ln -fs ../templates/Makefile.cluster "$_name/Makefile"
	rm -f "$_name/.init"
	make -s -C "$_name" init 2>/dev/null || true
	ln -sfn "$_state_dir" "$_name/clusterstate"

	return 0
}

# Validate a cluster name: DNS label rules + reserved ABA directory names.
# Returns 0 if valid, 1 if invalid (error on stderr).
_valid_cluster_name() {
	local name="$1"
	[ -z "$name" ] && echo_red "Error: cluster name is empty" >&2 && return 1

	if [[ ${#name} -gt 63 || ! "$name" =~ ^[a-z]([a-z0-9-]*[a-z0-9])?$ ]]; then
		echo_red "Error: invalid cluster name '$name' — must be a DNS label (lowercase letters, digits, hyphens; start with letter; max 63 chars)" >&2
		return 1
	fi

	# Reserved ABA directories that must never be used as cluster names
	case "$name" in
		mirror|scripts|cli|templates|tui|build|others|test|ai|tools|rpms|images|catalogs|bundles|docs|devel)
			echo_red "Error: '$name' is a reserved ABA directory name — choose a different cluster name" >&2
			return 1
			;;
	esac

	return 0
}

verify-cluster-conf() {
	[ "$verify_conf" = "off" ] && return 0
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
	if [ ! -n $ports ]; then
		echo_red "Error: ports value is missing in cluster.conf" >&2
		ret=1;
	else
		[[ $ports =~ ^[a-zA-Z0-9_.-]+(,[a-zA-Z0-9_.-]+)*$ ]] || { echo_red "Error: ports list is invalid in cluster.conf: [$ports]" >&2; ret=1; }
	fi

	[[ -z "$vlan" || ( "$vlan" =~ ^[0-9]+$ && vlan -ge 1 && vlan -le 4094 ) ]] || { echo_red "Error: vlan is invalid in cluster.conf: [$vlan]" >&2; ret=1; }

	[ "$int_connection" ] && { echo "$int_connection" | grep -qxE "none|proxy|direct" || { echo_red "Error: int_connection incorrectly set [$int_connection] in cluster.conf" >&2; ret=1; }; }

	# Match a mac *prefix*, e.g. 00:52:11:00:xx: (x is replaced by random number)
	[ "$mac_prefix" ] && ! echo $mac_prefix | grep -q -E '^([0-9A-Fa-fXx]{2}:){5}$' && { aba_warning -p "Error" "mac_prefix is invalid in cluster.conf: [$mac_prefix]" "Expected: 5 octets + trailing colon, e.g. 52:54:00:1a:2b: (use 'x' for random hex, e.g. 52:54:00:xx:xx:)"; ret=1; }

	# mac_prefix is required for virtual platforms (VMs need unique MACs)
	[[ "$platform" == "vmw" || "$platform" == "kvm" ]] && [ -z "$mac_prefix" ] && { aba_warning -p "Error" "mac_prefix is required for platform=$platform in cluster.conf"; ret=1; }

	[ "$master_cpu_count" ] && ! echo $master_cpu_count | grep -q -E '^[0-9]+$' && { echo_red "Error: master_cpu_count is invalid in cluster.conf: [$master_cpu_count]" >&2; ret=1; }
	[ "$master_mem" ] && ! echo $master_mem | grep -q -E '^[0-9]+$' && { echo_red "Error: master_mem is invalid in cluster.conf: [$master_mem]" >&2; ret=1; }

	[ "$worker_cpu_count" ] && ! echo $worker_cpu_count | grep -q -E '^[0-9]+$' && { echo_red "Error: worker_cpu_count is invalid in cluster.conf: [$worker_cpu_count]" >&2; ret=1; }
	[ "$worker_mem" ] && ! echo $worker_mem | grep -q -E '^[0-9]+$' && { echo_red "Error: worker_mem is invalid in cluster.conf: [$worker_mem]" >&2; ret=1; }

	[ "$data_disk" ] && ! echo $data_disk | grep -q -E '^[0-9]+$' && { echo_red "Error: data_disk is invalid in cluster.conf: [$data_disk]" >&2; ret=1; }

	return $ret
}

normalize-vmware-conf()
{
	# Determine if ESXi or vCenter and adjust VC_FOLDER accordingly

	[ ! -s vmware.conf ] &&                                                              return 0  # vmware.conf can be empty

	vars=$(_normalize_export < vmware.conf)
	eval "$vars"

	# Temporarily unset datacenter/cluster before ESXi detection.
	# Template defaults (GOVC_DATACENTER=Datacenter, GOVC_CLUSTER=Cluster) cause
	# 'govc about' to fail on standalone ESXi where these objects don't exist,
	# preventing the HostAgent grep from ever matching.
	local _saved_dc="${GOVC_DATACENTER:-}" _saved_cl="${GOVC_CLUSTER:-}"
	unset GOVC_DATACENTER GOVC_CLUSTER

	aba_debug "Running: govc about (ESXi detection)"
	if govc about 2>/dev/null | grep -q "^API type:.*HostAgent$"; then
		echo "$vars" | sed -e "s#VC_FOLDER.*#VC_FOLDER=/ha-datacenter/vm#g" -e "/GOVC_DATACENTER/d" -e "/GOVC_CLUSTER/d"
		echo "$vars" | grep -q "VC_FOLDER" || echo "export VC_FOLDER=/ha-datacenter/vm"
		echo export VC=
	else
		# Restore for vCenter path
		GOVC_DATACENTER="$_saved_dc"
		GOVC_CLUSTER="$_saved_cl"
		echo "$vars"
		echo export VC=1
		# Resolve $GOVC_DATACENTER and $GOVC_CLUSTER placeholders in GOVC_RESOURCE_POOL.
		# Users can write e.g. '/$GOVC_DATACENTER/host/$GOVC_CLUSTER/Resources' in vmware.conf
		# and ABA expands it to the absolute path openshift-install requires.
		# ${var//pattern/replacement} replaces all occurrences of pattern in var.
		# The \$ in the pattern matches a literal '$' character.
		if [ -n "$GOVC_RESOURCE_POOL" ]; then
			local _rp="${GOVC_RESOURCE_POOL//\$GOVC_DATACENTER/$GOVC_DATACENTER}"
			_rp="${_rp//\$GOVC_CLUSTER/$GOVC_CLUSTER}"
			echo "export GOVC_RESOURCE_POOL='$_rp'"
		fi
	fi
}

# Resolve the resource-pool path used by the vSphere preflight RES-06 check (Phase 2).
# When GOVC_RESOURCE_POOL is set and non-empty, echo it unchanged - normalize-vmware-conf
# has already expanded any $GOVC_DATACENTER / $GOVC_CLUSTER placeholders inside the value.
# When unset or empty, echo the implicit per-cluster default path that vSphere always
# provisions: /<DC>/host/<Cluster>/Resources. Callers pass the result to
# `govc object.collect -s "<path>" name` to probe existence.
#
# This lives OUTSIDE normalize-vmware-conf because the default-path computation is a
# DERIVED value; normalize-*-conf helpers emit only file/default VALUES (CLAUDE.md +
# Phase 1 carry-forward). Placeholder expansion of an explicit value is a separate
# concern, already handled inside normalize-vmware-conf.
resolve-default-resource-pool() {
	if [ -n "${GOVC_RESOURCE_POOL:-}" ]; then
		echo "$GOVC_RESOURCE_POOL"
	else
		echo "/$GOVC_DATACENTER/host/$GOVC_CLUSTER/Resources"
	fi
}

normalize-kvm-conf()
{
	[ ! -s kvm.conf ] && return 0

	local vars
	vars=$(_normalize_export < kvm.conf)
	eval "$vars"
	echo "$vars"

	# Extract KVM_HOST (user@host) from LIBVIRT_URI for scp/ssh
	local kvm_host
	kvm_host=$(echo "$LIBVIRT_URI" | sed -E 's|^[^:]+://([^/]+)/.*|\1|')
	echo "export KVM_HOST=$kvm_host"
}

install_rpms() {
	# Try to install the RPMs only if they are missing
	# On RHEL 8, `rpm -q python3` fails even after `dnf install python3`
	# because the actual RPM is `python36` (or `python3.11`, etc.).
	# DNF resolves the virtual provide, but rpm -q does not.
	# Check for /usr/bin/python3 instead to avoid re-running dnf every time.
	local rpms_to_install=

	for rpm in $@
	do
		# Skip python3 RPM check if the binary already exists (RHEL 8 compat)
		[ "$rpm" = "python3" ] && [ -x /usr/bin/python3 ] && continue
		# Check if each rpm is already installed.  Don't run dnf unless we have to.
		rpm -q --quiet $rpm || rpms_to_install="$rpms_to_install $rpm" 
	done

	if [ "$rpms_to_install" ]; then
		echo "Installing required rpm packages:$rpms_to_install (logging to .dnf-install.log). Please wait!" >&2  # send to stderr so this can be seen during "aba bundle -o -"
		if ! $SUDO dnf install $rpms_to_install -y >> .dnf-install.log 2>&1; then
			aba_warning \
				"an error occurred during rpm installation. See the logs at .dnf-install.log." \
				"If dnf cannot be used to install rpm packages, please install the following packages manually and try again!" 
			aba_info $rpms_to_install >&2

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
		[ ! "$ret_default" ] && [ ! "$ask" ] && ret_default="ask=false" #return 0  # reply "default reply"
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
	[ "$ret_default" ] && echo_white "[default: $ret_default]" && return 0
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
			if [ -n "${ABA_TTY_FD:-}" ]; then
				$editor $conf_file >&${ABA_TTY_FD} 2>&1
			else
				$editor $conf_file
			fi
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

# Compact elapsed for aba_wait_show: "45s" if <1m; "4m" or "4m20s" if >=1m (no spaces).
_aba_format_elapsed() {
	local s=$1
	local m=$(( s / 60 ))
	local r=$(( s % 60 ))
	if [ "$s" -lt 60 ]; then
		printf '%ds' "$s"
	elif [ "$r" -eq 0 ]; then
		printf '%dm' "$m"
	else
		printf '%dm%ds' "$m" "$r"
	fi
}

# Poll until command succeeds or wall-clock budget is exhausted.
# Usage: aba_wait_show <message> <interval_sec> <max_sec> <command>
# Evaluates <command> each iteration; exit 0 => success. Always prints progress (not gated by INFO_ABA).
# The spinner runs in the background so it keeps updating even when the
# check command blocks (e.g. curl --connect-timeout 10).  The check command
# runs via eval so caller-defined functions are available.
# TTY: spinner refreshes every 0.2s. Non-TTY: one elapsed tick per check cycle.
#
# Uses ( ) function body so job table, traps, and set options are isolated.
aba_wait_show() (
	msg=$1
	interval=$2
	max=$3
	shift 3
	check_cmd=$*
	max_fmt=$(_aba_format_elapsed "$max")

	if ! [[ "$interval" =~ ^[0-9]+$ ]] || ! [[ "$max" =~ ^[0-9]+$ ]]; then
		echo_red "[ABA] aba_wait_show: interval and max_sec must be non-negative integers" >&2
		return 2
	fi

	set +m
	trap - ERR

	use_tty=0
	[ -t "${ABA_TTY_FD:-1}" ] && [ -z "${PLAIN_OUTPUT:-}" ] && use_tty=1

	# Check command output goes to a debug log (not /dev/null) so failures
	# are diagnosable.  Truncated on each aba_wait_show invocation.
	_wait_log="$HOME/.aba/logs/.aba-wait-show.log"
	mkdir -p "$(dirname "$_wait_log")"
	: > "$_wait_log"

	start_ts=$(date +%s)
	_spinner_pid=
	hdr_done=

	# Launch a background spinner that updates every 0.5s (TTY only).
	_start_spinner() {
		[ "$use_tty" -eq 0 ] && return
		[ -n "$_spinner_pid" ] && return
		(
			_frames=( '|' '/' '-' '\' )
			_s=0
			while true; do
				_e=$(( $(date +%s) - start_ts ))
				printf '\r[ABA] %s  %s  %s (max %s)\033[K' "$msg" "${_frames[$(( _s % 4 ))]}" "$(_aba_format_elapsed "$_e")" "$max_fmt"
				_s=$(( _s + 1 ))
				sleep 0.2
			done
		) &
		_spinner_pid=$!
	}

	_stop_spinner() {
		[ -z "$_spinner_pid" ] && return
		kill "$_spinner_pid" 2>/dev/null
		wait "$_spinner_pid" 2>/dev/null || true
		_spinner_pid=
	}

	_cleaned=
	_cleanup() {
		[ -n "$_cleaned" ] && return
		_cleaned=1
		_stop_spinner
		if [ "$use_tty" -eq 1 ]; then
			_final=$(( $(date +%s) - start_ts ))
			printf '\r[ABA] %s     %s (max %s)\033[K\n' "$msg" "$(_aba_format_elapsed "$_final")" "$max_fmt"
		elif [ -n "$hdr_done" ]; then
			printf '\n'
		fi
	}
	trap '_cleanup; exit 130' INT
	trap '_cleanup; exit 143' TERM

	_rc=1
	_start_spinner

	while true; do
		elapsed=$(( $(date +%s) - start_ts ))
		[ "$elapsed" -ge "$max" ] && break

		# Run check command via eval in a forked subshell so caller-defined
		# functions are available (bash -c would start a fresh process
		# without them).  The subshell is killed if it exceeds the
		# remaining wall-clock budget.  Output goes to debug log.
		remaining=$(( max - elapsed ))
		cmd_rc=0
		( eval "$check_cmd" ) >> "$_wait_log" 2>&1 &
		_cmd_pid=$!
		_deadline=$(( $(date +%s) + remaining ))
		while kill -0 "$_cmd_pid" 2>/dev/null; do
			[ "$(date +%s)" -ge "$_deadline" ] && { kill "$_cmd_pid" 2>/dev/null; break; }
			sleep 0.2
		done
		wait "$_cmd_pid" 2>/dev/null || cmd_rc=$?

		elapsed=$(( $(date +%s) - start_ts ))
		[ "$cmd_rc" -eq 0 ] && { _rc=0; break; }
		[ "$elapsed" -ge "$max" ] && break

		# Non-TTY: print elapsed tick after each failed check
		if [ "$use_tty" -eq 0 ]; then
			[ -z "$hdr_done" ] && { printf '[ABA] %s (max %s) ... ' "$msg" "$max_fmt"; hdr_done=1; }
			printf '%s ' "$(_aba_format_elapsed "$elapsed")"
		fi

		# Sleep for the interval (or remaining budget, whichever is less)
		remaining=$(( max - elapsed ))
		wait_secs=$(( interval < remaining ? interval : remaining ))
		[ "$wait_secs" -gt 0 ] && sleep "$wait_secs" 2>/dev/null || true
	done

	_cleanup
	return "$_rc"
)

# Check if version1 is strictly greater than version2 (semver-aware).
# sort -V puts pre-release suffixes above bare versions (wrong for semver);
# the -zzz trick makes GA sort after its pre-release siblings.
is_version_greater() {
	local version1=$1
	local version2=$2

	local sorted_versions=$(printf "%s\n%s" "$version1" "$version2" \
		| sed 's/^\([0-9]*\.[0-9]*\.[0-9]*\)$/\1-zzz/' \
		| sort -V \
		| sed 's/-zzz$//' \
		| tr "\n" "|")

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

oc_mirror_version() {
	oc-mirror version --output json 2>/dev/null | jq -r '.clientVersion.gitVersion' | cut -d- -f1
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


# Cincinnati API endpoint -- same URL for OCP 4.x and 5.x (confirmed Apr 2026).
# Channel names follow the pattern: stable-X.Y, fast-X.Y, candidate-X.Y
ABA_GRAPH_API="https://api.openshift.com/api/upgrades_info/v1/graph"

# Architecture: default is amd64
ARCH="${ARCH:-amd64}"
[[ "$ARCH" == "x86_64" ]] && ARCH="amd64"

# Cache settings
ABA_CACHE_DIR="${ABA_CACHE_DIR:-$HOME/.aba/cache}"
ABA_CACHE_TTL="${ABA_CACHE_TTL:-100m}"
# Note: Cache directory is created lazily when first needed

# Convert human-readable duration string to seconds (e.g. 30m, 12h, 1d, 300s, or bare integer)
parse_duration() {
	local val="$1"
	case "$val" in
		*d) echo $(( ${val%d} * 86400 )) ;;
		*h) echo $(( ${val%h} * 3600 )) ;;
		*m) echo $(( ${val%m} * 60 )) ;;
		*s) echo $(( ${val%s} )) ;;
		*)  echo "$val" ;;
	esac
}

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

# Extract major.minor from any version string, stripping pre-release suffix.
# e.g. "4.22.0-rc.1" → "4.22", "5.0.3" → "5.0", "4.20.20" → "4.20"
_ver_minor() {
	echo "${1%%-*}" | cut -d. -f1-2
}

############################################
# Fetch latest minor (GA-aware)
# Returns MAJOR.MINOR (e.g. 4.20)
# If mirror reports prerelease (e.g. 4.21.0-rc.1), returns previous minor (e.g. 4.20)
############################################
fetch_latest_minor_version() {
	local channel="${1:-stable}"
	# CDN uses per-major layout: openshift-v4/, openshift-v5/, etc.
	local url="https://mirror.openshift.com/pub/openshift-v${ocp_major:-4}/${ARCH}/clients/ocp/${channel}/release.txt"
	local cache_file="${ABA_CACHE_DIR}/release_${channel}_${ARCH}.txt"
	local latest_ver minor prev

	_fetch_cached "$url" "$cache_file" "$(parse_duration "$ABA_CACHE_TTL")" "" || { echo ""; return 0; }

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

	_fetch_cached "$url" "$cache_file" "$(parse_duration "$ABA_CACHE_TTL")" _validate_json_file || return 0
	cat "$cache_file"
}

############################################
# Fetch all versions in channel-minor (semver-sorted: ec < rc < GA)
# Args:
#	$1 = channel base (e.g. stable)
#	$2 = minor (e.g. 4.20) [optional]
# sort -V puts pre-release suffixes ABOVE bare versions (wrong for semver).
# The -zzz trick tags GA versions so they sort after their pre-release siblings.
############################################
fetch_all_versions() {
	local channel="${1:-stable}"
	local minor="$2"

	set -o pipefail
	_fetch_graph_cached "$channel" "$minor" \
		| jq -r '.nodes[].version' \
		| grep "^${minor}\." \
		| sed 's/^\([0-9]*\.[0-9]*\.[0-9]*\)$/\1-zzz/' \
		| sort -V \
		| sed 's/-zzz$//'
}

############################################
# Fetch latest version (includes pre-release on candidate channel)
# Uses two data sources:
#   - CDN release.txt: discovers the "recommended" minor (e.g. 4.22)
#   - Cincinnati graph: provides the actual version list per channel-minor
# On candidate, the CDN may lag behind Cincinnati — newer pre-release minors
# (e.g. 5.0) exist in the graph but aren't advertised by the CDN. Discovery
# via fetch_latest_prerelease_version() bridges this gap.
############################################
fetch_latest_version() {
	local channel="${1:-stable}"
	local minor v prev prerel

	minor="$(fetch_latest_minor_version "$channel")"
	[[ -n "$minor" ]] || { echo ""; return 0; }

	v="$(fetch_all_versions "$channel" "$minor" | tail -n1)"
	if [[ -z "$v" ]]; then
		prev="$(_prev_minor "$minor")"
		[[ -n "$prev" ]] || { echo ""; return 0; }
		v="$(fetch_all_versions "$channel" "$prev" | tail -n1)"
	fi

	# On candidate, a newer pre-release may exist on a higher minor
	if [[ "$channel" = "candidate" && -n "$v" ]]; then
		prerel=$(fetch_latest_prerelease_version "$channel" 2>/dev/null)
		if [[ -n "$prerel" ]] && is_version_greater "$prerel" "$v"; then
			echo "$prerel"
			return 0
		fi
	fi

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
# On candidate: if latest is pre-release from higher minor, "previous" is the GA latest.
############################################
fetch_previous_version() {
	local channel="${1:-stable}"
	local minor prev v

	minor="$(fetch_latest_minor_version "$channel")"
	[[ -n "$minor" ]] || { echo ""; return 0; }

	# On candidate, if a newer pre-release exists, "previous" is the CDN GA latest
	if [[ "$channel" = "candidate" ]]; then
		local prerel ga_latest
		prerel=$(fetch_latest_prerelease_version "$channel" 2>/dev/null)
		if [[ -n "$prerel" ]]; then
			ga_latest="$(fetch_all_versions "$channel" "$minor" | tail -n1)"
			[[ -n "$ga_latest" ]] && { echo "$ga_latest"; return 0; }
		fi
	fi

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


############################################
# Fetch latest pre-release version (candidate channel only).
# Discovery is needed because the CDN release.txt only advertises one "recommended"
# minor (e.g. 4.22), while newer pre-release minors (e.g. 5.0) exist only in the
# Cincinnati graph. Cincinnati requires a specific channel-minor pair — there is no
# "give me all minors" query. So we probe: try next minor (4.23), then next major.0 (5.0).
# Returns the latest pre-release version or empty string.
############################################
fetch_latest_prerelease_version() {
	local channel="${1:-candidate}"
	local minor v next_minor next_major

	minor="$(fetch_latest_minor_version "$channel")"
	[[ -n "$minor" ]] || return 0

	# Try next minor in same major (e.g. 4.22 → 4.23)
	local x="${minor%%.*}" y="${minor#*.}"
	next_minor="${x}.$((y + 1))"
	v="$(fetch_all_versions "$channel" "$next_minor" 2>/dev/null | tail -n1)"
	if [[ -n "$v" ]] && _is_prerelease "$v"; then
		echo "$v"
		return 0
	fi

	# Try next major.0 (e.g. 4.22 → 5.0)
	next_major="$((x + 1)).0"
	v="$(fetch_all_versions "$channel" "$next_major" 2>/dev/null | tail -n1)"
	if [[ -n "$v" ]] && _is_prerelease "$v"; then
		echo "$v"
		return 0
	fi

	return 0
}

############################################
# Verify a release version exists in the Cincinnati graph.
# Used as a pre-flight before oc-mirror to avoid wasted time on non-existent versions.
# Args:
#	$1 = version (e.g. 4.22.2 or 4.22.0-rc.1)
#	$2 = channel base (e.g. fast, stable, candidate) [optional, default: from aba.conf]
# Returns: 0 if version found, 1 if not
############################################
verify_release_version_exists() {
	local ver="${1:-}"
	local channel="${2:-${ocp_channel:-fast}}"

	[[ -z "$ver" ]] && return 1

	# Extract minor (e.g. 4.22 from 4.22.2 or 4.22.0-rc.1)
	local minor="${ver%.*}"
	[[ "$ver" == *-* ]] && minor="${ver%%-*}" && minor="${minor%.*}"

	# Pre-release versions (rc/ec) only exist in candidate channel
	if [[ "$ver" == *-rc.* || "$ver" == *-ec.* ]]; then
		channel="candidate"
	fi

	local all_versions
	all_versions=$(_fetch_graph_cached "$channel" "$minor" 2>/dev/null | jq -r '.nodes[].version' 2>/dev/null) || return 1

	if echo "$all_versions" | grep -qxF "$ver"; then
		return 0
	fi

	return 1
}

# Escape characters that are special in sed replacement strings.
# Must be called before interpolating user values into sed 's|...|...|' commands.
_sed_escape_replacement() {
	# Order matters: escape \ first (otherwise later escapes get double-escaped).
	# & → \&  (& means "entire matched text" in sed replacement)
	# | → \|  (| is our sed delimiter in replace-value-conf)
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/[&|]/\\&/g'
}

# Replace a value in a conf file, taking care of white-space and optional commented ("#") values
replace-value-conf() {
	# -n <string> : name of value to change
	# -v <string> : new value. If missing, remove the value
	# -f <files>
	# -q          : quiet (debug-level messages only)
	#
	# Handles single-quoted old values (e.g. reg_pw='p4ssw0rd').
	# Auto-quotes new values that contain spaces or '#'.
	# If the caller already pre-quotes (e.g. -v "'password'"), no double-quoting occurs.

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

	# Auto-quote values containing spaces or '#' (unquoted '#' starts a comment in bash).
	# Skip if the caller already pre-quoted (value starts and ends with single quote).
	local _write_value="$value"
	if [ -n "$value" ]; then
		if [[ "$value" == \'*\' ]]; then
			# Already single-quoted by caller (e.g. -v "'password'")
			_write_value="$value"
		elif [[ "$value" == *[[:space:]]* || "$value" == *"#"* ]]; then
			_write_value="'$value'"
		fi
	fi

	# Step through the files by priority...
	local _first_file=
	for f in $files
	do
		[ ! -s "$f" ] && continue # Try next file
		[ ! "$_first_file" ] && _first_file="$f"

		aba_debug "Replacing config value [$name] with [$_write_value] in file: $f" >&2

		# Idempotency: if the file already has the desired state, skip the write.
		# Uses grep -F (fixed string) first so regex chars in values (e.g. passwords) don't cause false matches.
		if [ "$value" ]; then
			if grep -q -F "${name}=${_write_value}" "$f" && \
			   grep -q "^${name}=${_write_value}[[:space:]]*\(#.*\)\?$" "$f"; then
				aba_debug "Value ${name}=${_write_value} already exists in file $f"
				return 0
			fi
		else
			# Empty value means "comment out" — check if already commented
			if grep -q -E "^[#[:space:]]*${name}=" "$f" && ! grep -q "^${name}=" "$f"; then
				aba_debug "Value ${name} is already commented out in file $f"
				return 0
			fi
		fi

		# Key must exist in file (active or commented out) for sed to work
		if ! grep -q -E "^[#[:space:]]*${name}=" "$f"; then
			aba_debug "Key [$name] not found in file $f — skipping" >&2
			continue
		fi

		if [ "$value" ]; then
			# Escape sed-special chars (&, \, |) in the replacement value
			local _sed_safe
			_sed_safe=$(_sed_escape_replacement "$_write_value")

			# Match old value: either single-quoted ('...') or unquoted (up to space/tab).
			# Trailing whitespace + comment is captured in \1 and preserved.
			# Uses | as sed delimiter (| is forbidden in config values).
			if grep -q -E "^[#[:space:]]*${name}='" "$f"; then
				sed -i --follow-symlinks "s|^[# \t]*${name}='[^']*'\(.*\)|${name}=${_sed_safe}\1|g" "$f"
			else
				sed -i --follow-symlinks "s|^[# \t]*${name}=[^ \t]*\(.*\)|${name}=${_sed_safe}\1|g" "$f"
			fi
		else
			# Empty value: comment out the line (preserve existing value for easy revert)
			sed -i --follow-symlinks "s|^\([#[:space:]]*\)\?${name}=|#${name}=|" "$f"
		fi

		if [ ! "$quiet" ]; then
			[ "$value" ] && aba_info_ok "Added value ${name}=${_write_value} to file $f" >&2 || aba_info_ok "Commenting out ${name} in file $f" >&2 
		else
			[ "$value" ] && aba_debug "Added value ${name}=${_write_value} to file $f"     || aba_debug "Commenting out ${name} in file $f"
		fi

		return 0
	done

	# Key not found in any file — append to the first valid file
	if [ "$_first_file" ] && [ "$value" ]; then
		echo "${name}=${_write_value}" >> "$_first_file"
		if [ ! "$quiet" ]; then
			aba_info_ok "Added value ${name}=${_write_value} to file $_first_file" >&2
		else
			aba_debug "Added value ${name}=${_write_value} to file $_first_file"
		fi
		return 0
	fi

	return 1 # Files do not exist or no value to write
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

	echo "${gw:-}"
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

	echo "${net:-}"
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

	echo "${dns:-}"
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
			aba_debug "$1 already in system trust"
		else
			$SUDO install -m 644 $1 /etc/pki/ca-trust/source/anchors/ 
			$SUDO update-ca-trust extract
			aba_info "Cert '${regcreds_display:-regcreds}/rootCA.pem' updated in system trust"
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

	while getopts "swi:cprAGFt:eoEW:m:qS" opt; do
		case "$opt" in
			s) mode="start" ;;
			w) mode="wait" ;;
			i) work_id=$OPTARG ;;
			c) purge=true ;;
			p) mode="peek" ;;
			A) mode="active" ;;
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

		# Surgical cleanup: remove runtime/cached state but preserve task identity
		# Identity files (cmd.sh, cmd, cwd) allow run_once -w to reload and
		# re-execute a task after TTL expiry without the caller providing a command.
		rm -f "$id_dir"/{pid,lock,exit}
		# Rotate logs for one generation of diagnostic history
		[[ -f "$id_dir/log.out" ]] && mv -f "$id_dir/log.out" "$id_dir/log.out.prev" || true
		[[ -f "$id_dir/log.err" ]] && mv -f "$id_dir/log.err" "$id_dir/log.err.prev" || true
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
		local d id exitf lockf rc
		shopt -s nullglob
		for d in "$WORK_DIR"/*/; do
			id="$(basename "$d")"
			exitf="$d/exit"
			lockf="$d/lock"
			if [[ -f "$exitf" ]]; then
				rc="$(cat "$exitf" 2>/dev/null || echo 1)"
			if [[ "$rc" -ne 0 ]]; then
				aba_debug "Cleaning failed task: $id (exit code: $rc)"
				_kill_id "$id"
				rm -f "$d"/{cmd.sh,cmd,cwd}   # Full clean (like explicit -r)
			fi
		elif [[ -e "$d" ]]; then
			# Zombie task: directory exists but no exit file.
			# Caused by SIGKILL, OOM, or machine crash killing the
			# subshell before it could write the exit file.
			# Only clean if the lock is free (process is definitely dead).
			if ( exec 9>>"$lockf" && flock -n 9 ); then
				aba_debug "Cleaning zombie task: $id (no exit file, lock free)"
				_kill_id "$id"
				rm -f "$d"/{cmd.sh,cmd,cwd}   # Full clean (like explicit -r)
				else
					aba_debug "Skipping task: $id (no exit file, lock held — still running)"
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
	# Full clean slate: _kill_id removes runtime state (pid, lock, exit, logs)
	# but preserves identity files (cmd.sh, cmd, cwd) for TTL re-execution.
	# Explicit reset also removes identity files -- "forget everything."
	if [[ "$reset" == true ]]; then
		_log_history "RESET"
		_kill_id "$work_id"
		rm -f "$id_dir"/{cmd.sh,cmd,cwd}
		return 0
	fi

	# --- PEEK ---
	if [[ "$mode" == "peek" ]]; then
		[[ -f "$exit_file" ]] && return 0 || return 1
	fi

	# --- ACTIVE (running or completed) ---
	if [[ "$mode" == "active" ]]; then
		[[ -f "$exit_file" ]] && return 0
		# Check if lock is currently held (task running)
		if [[ -f "$lock_file" ]]; then
			exec 9>>"$lock_file"
			if flock -n 9; then
				exec 9>&-
				return 1  # lock free — not running
			fi
			exec 9>&-
			return 0  # lock held — running
		fi
		return 1  # no lock file — never started
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

		# Normalize whitespace in command args (tabs→spaces, collapse runs)
		# so that cmd.sh is deterministic regardless of caller formatting
		local _i
		for _i in "${!command[@]}"; do
			command[$_i]="${command[$_i]//$'\t'/ }"
		done

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
			# Disable set -e: callers may have it on, and we must always write the
			# exit file even when the command fails (wait returns non-zero).
			set +e
			local rc=0

			if [[ "$is_fg" == "true" ]]; then
				# Foreground-ish: stream + log
				# Capture stderr separately, combined to stdout for display
				setsid "${command[@]}" 9>&- 2> >(tee -a "$log_err_file" >&2) | tee -a "$log_out_file"
				rc="${PIPESTATUS[0]}"
				echo "$rc" >"$exit_file"
				_log_history "COMPLETE rc=$rc"
				exit "$rc"
			fi

			# Background: log.out gets stdout+stderr, log.err gets only stderr
			# Close inherited stdout/stderr first so this background subshell
			# doesn't hold a parent pipeline (e.g. `cmd | tee`) open.
			exec >/dev/null 2>&1
			# 9>&- closes the lock FD in the child so only this subshell holds
			# the lock. If this subshell is killed, the lock releases immediately
			# instead of being held by the orphaned child until it finishes.
			setsid "${command[@]}" 9>&- 2> >(tee -a "$log_err_file" >> "$log_out_file") >> "$log_out_file" &
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
				# Surgical cleanup: preserve cmd.sh/cmd/cwd so wait can reload the command
				rm -f "$id_dir"/{pid,lock,exit}
				[[ -f "$id_dir/log.out" ]] && mv -f "$id_dir/log.out" "$id_dir/log.out.prev" || true
				[[ -f "$id_dir/log.err" ]] && mv -f "$id_dir/log.err" "$id_dir/log.err.prev" || true
				# Fall through to restart logic below
			fi
		fi

		if [[ ! -f "$exit_file" ]]; then
			exec 9>>"$lock_file"
			if flock -n 9; then
				# Lock is free => not running => implicitly start
				# Keep FD 9 open -- lock transfers to _start_task's subshell
				if [[ ${#command[@]} -eq 0 ]]; then
					# No command on CLI -- try reloading from saved cmd.sh
					if [[ -f "$id_dir/cmd.sh" ]]; then
						source "$id_dir/cmd.sh"
						aba_debug "Reloaded saved command for restart: ${command[*]}"
					fi
				fi
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
				cd "$saved_cwd" 2>/dev/null || aba_debug "Warning: Could not restore CWD to $saved_cwd"
			fi

			# Use saved command for validation (it was recorded with the saved CWD)
			# Callers may pass a different command with different relative paths
			if [[ -f "$id_dir/cmd.sh" ]]; then
				source "$id_dir/cmd.sh"
				aba_debug "Loaded saved command for validation: ${command[*]}"
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

	# Show error context and recovery guidance on failure
	if [[ $exit_code -ne 0 && "$quiet_wait" != true ]]; then
		if [[ -s "$log_err_file" ]]; then
			tail -5 "$log_err_file" >&2
		fi
		echo_yellow "[ABA] If this problem persists, re-run './install' from the ABA directory to clear the task cache." >&2
		aba_debug "Failed task ID: $work_id (exit code: $exit_code)"
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

# Return space-separated list of major.minor versions needing catalog downloads.
# Always includes the current ocp_version; adds ocp_version_target's major.minor
# when it differs (cross-minor upgrade).  Expects ocp_version (and optionally
# ocp_version_target) to be set in the environment.
_catalog_versions_to_mirror() {
	local _cur=$(_ver_minor "$ocp_version")
	local _versions=("$_cur")
	if [ "${ocp_version_target:-}" ] && [ "$ocp_version_target" != "$ocp_version" ]; then
		local _tgt=$(_ver_minor "$ocp_version_target")
		[ "$_tgt" != "$_cur" ] && _versions+=("$_tgt")
	fi
	echo "${_versions[*]}"
}

# Download all 3 operator catalogs using run_once, throttled by CATALOG_MAX_PARALLEL
# Usage: download_all_catalogs <version_short> [ttl_seconds]
# Example: download_all_catalogs "4.19"          (uses CATALOG_CACHE_TTL from ~/.aba/config)
# Example: download_all_catalogs "4.19" 5        (explicit TTL override, e.g. for tests)
download_all_catalogs() {
	local version_short="${1}"
	local ttl="${2:-}"

	if [[ -z "$version_short" ]]; then
		echo_red "[ABA] Error: download_all_catalogs requires version (e.g., 4.19)" >&2
		return 1
	fi

	# Read user config for TTL and parallelism (defaults: 12h TTL, 3 parallel)
	local max_parallel="${CATALOG_MAX_PARALLEL:-3}"
	if [[ -f "$HOME/.aba/config" ]]; then
		source "$HOME/.aba/config"
		max_parallel="${CATALOG_MAX_PARALLEL:-3}"
	fi
	[[ -z "$ttl" ]] && ttl="$(parse_duration "${CATALOG_CACHE_TTL:-12h}")"

	local catalogs=(redhat-operator certified-operator community-operator)
	local running=0

	aba_debug "Starting catalog downloads for OCP $version_short (max_parallel=$max_parallel, TTL: ${ttl}s)"

	# Start: catalog downloads in background (with optional throttle-wait inline).
	# Wait: wait_for_all_catalogs() below, or download-catalogs-wait.sh (via Makefile)
	for catalog in "${catalogs[@]}"; do
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
	
	# Read timeout from user config (default: 20m)
	if [[ -f "$HOME/.aba/config" ]]; then
		source "$HOME/.aba/config"
	fi
	local timeout_secs
	timeout_secs="$(parse_duration "${CATALOG_INDEX_DOWNLOAD_TIMEOUT:-20m}")"
	
	aba_debug "wait_for_all_catalogs: Called for OCP $version_short (timeout: ${timeout_secs}s)"
	
	# Wait: block for catalogs started by download_all_catalogs() above
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

# Copy shipped catalog indexes into .index/ if live versions don't exist yet.
# Gives the TUI instant operator browsing before background downloads complete.
_populate_shipped_indexes() {
	local f target
	for f in catalogs/*-operator-index-v*; do
		[[ -s "$f" ]] || continue
		target=".index/$(basename "$f")"
		[[ -s "$target" ]] && continue
		cp "$f" "$target"
	done
}

# Prefetch catalog indexes for current and previous minor versions.
# Called by scripts/prefetch-catalogs.sh and TUI v2 for early background catalog fetching.
# Requires: ocp_version and/or ocp_channel from aba.conf (or callers set them beforehand).
aba_prefetch_catalogs() {
	# Populate .index/ from shipped catalogs (instant fallback for TUI)
	_populate_shipped_indexes

	local _ver="${ocp_version:-}"
	local _channel="${ocp_channel:-stable}"

	# If no version set, try to determine latest z for channel
	if [[ -z "$_ver" ]]; then
		_ver=$(fetch_latest_z_version "$_channel" "" 2>/dev/null) || return 0
	fi

	[[ -n "$_ver" ]] || return 0

	# Minor x.y — download_all_catalogs uses catalog:${minor}:* task IDs (not patch z)
	local _minor=$(_ver_minor "$_ver")

	download_all_catalogs "$_minor"
	wait_for_all_catalogs "$_minor" || return 0

	# Previous minor line (same major): x.(y-1)
	local _major="${_minor%%.*}"
	local _minor_num="${_minor##*.}"
	if [[ "$_minor_num" -gt 0 ]]; then
		local _prev_minor="$_major.$((_minor_num - 1))"
		local _prev_ver
		_prev_ver=$(fetch_latest_z_version "$_channel" "$_prev_minor" 2>/dev/null) || true
		if [[ -n "$_prev_ver" ]]; then
			download_all_catalogs "$(_ver_minor "$_prev_ver")"
		fi
	fi
}

# --- Aba-facing cleanup ---
# Note: No automatic cleanup on Ctrl-C. Background tasks continue naturally.
# Use 'aba reset' to explicitly kill all background tasks and clean up.

# -----------------------------------------------------------------------------
# HTTP/HTTPS Probing
# -----------------------------------------------------------------------------

# Probe HTTP/HTTPS endpoint with sensible timeouts

# --- Catalog digest pinning (oc-mirror upstream-contact workaround) ----------
#
# oc-mirror v2 resolves catalog tags at runtime, contacting registry.redhat.io
# even during disk2mirror (load) on disconnected hosts (OCPBUGS-81712).
# Pinning catalogs by digest in the ISC prevents this. The user's ISC is never
# modified -- we produce a separate imageset-config-digest.yaml for oc-mirror.
#
# Disable with: OC_MIRROR_PIN_CATALOGS=0 in ~/.aba/config (or env)
# Remove once oc-mirror fixes upstream tag resolution in air-gap (OCPBUGS-81712).
#
# Usage: _oc_mirror_pin_catalogs_by_digest <isc_file> <ocp_ver_major>
#   isc_file:       basename of ISC relative to data/ (e.g. "imageset-config.yaml")
#   ocp_ver_major:  e.g. "4.20"
# Returns: filename to use (original or "imageset-config-digest.yaml") on stdout.

_oc_mirror_pin_catalogs_by_digest() {
	local isc_file="$1"
	local ocp_ver_major="$2"
	local digest_isc=".imageset-config-digest.yaml"
	local sed_args=()

	for catalog_name in redhat-operator certified-operator community-operator; do
		local digest_file="../.index/.${catalog_name}-index-v${ocp_ver_major}.digest"
		[ -s "$digest_file" ] || continue
		local digest
		digest=$(cat "$digest_file")
		sed_args+=(-e "s|${catalog_name}-index:v${ocp_ver_major}|${catalog_name}-index@${digest}  # was :v${ocp_ver_major}|g")
		aba_debug "Will pin $catalog_name catalog: :v${ocp_ver_major} -> @${digest}"
	done

	if [ ${#sed_args[@]} -gt 0 ]; then
		sed "${sed_args[@]}" "$isc_file" > "$digest_isc"
		aba_debug "Catalog tags resolved to digests in $digest_isc (ensures air-gap compatibility)"
		echo "$digest_isc"
	else
		aba_debug "No catalog digests found -- using original ISC"
		echo "$isc_file"
	fi
}

# --- oc-mirror retry loop (shared by reg-save.sh, reg-sync.sh, reg-load.sh) ---
#
# Usage: _run_oc_mirror_with_retry <action> <try_tot> <oc_mirror_cmd>
#   action:    "save", "sync", or "load" (for log messages)
#   try_tot:   total attempts (1 = no retry)
#   oc_mirror_cmd: the oc-mirror command WITHOUT tuning flags (those are appended)
#
# Reads from environment: OC_MIRROR_PARALLEL_IMAGES, OC_MIRROR_IMAGE_TIMEOUT, OC_MIRROR_FLAGS
# Exits the calling script with 0 on success or 1 on failure.
_oc_mirror_decode_exit() {
	local code=$1
	local parts=""
	[ $(( code & 2 )) -ne 0 ] && parts="${parts}release "
	[ $(( code & 4 )) -ne 0 ] && parts="${parts}operator "
	[ $(( code & 8 )) -ne 0 ] && parts="${parts}additional-image "
	[ $(( code & 16 )) -ne 0 ] && parts="${parts}helm "
	if [ -n "$parts" ]; then
		echo "${parts% }"
	elif [ "$code" -eq 1 ]; then
		echo "generic/pre-batch"
	else
		echo "unknown($code)"
	fi
}

_run_oc_mirror_with_retry() {
	local action="$1"
	local try_tot="$2"
	local base_cmd="$3"

	# Pin catalog tags to digests unless disabled (OC_MIRROR_PIN_CATALOGS=0)
	if [ "${OC_MIRROR_PIN_CATALOGS:-1}" != "0" ]; then
		local _ocp_ver_major
		_ocp_ver_major=$(echo "$ocp_version" | cut -d. -f1-2)
		local _config_file
		_config_file=$( cd data && _oc_mirror_pin_catalogs_by_digest "imageset-config.yaml" "$_ocp_ver_major" )
		if [ "$_config_file" != "imageset-config.yaml" ]; then
			base_cmd="${base_cmd/--config imageset-config.yaml/--config $_config_file}"
		fi
	fi

	local parallel_images="${OC_MIRROR_PARALLEL_IMAGES:-8}"
	local retry_delay=2
	local retry_times=2
	local image_timeout="${OC_MIRROR_IMAGE_TIMEOUT:-30m}"
	aba_debug "Initial tuning: parallel_images=$parallel_images retry_delay=$retry_delay retry_times=$retry_times image_timeout=$image_timeout"

	local try=1
	local failed=1
	local exit_history=""
	aba_debug "Starting retry loop: try_tot=$try_tot"

	while [ $try -le $try_tot ]; do
		[[ -f "$HOME/.aba/config" ]] && source "$HOME/.aba/config"
		aba_debug "Attempt $try/$try_tot: parallel_images=$parallel_images retry_delay=$retry_delay retry_times=$retry_times"

		local cmd="$base_cmd --image-timeout $image_timeout --parallel-images $parallel_images --retry-delay ${retry_delay}s --retry-times $retry_times ${OC_MIRROR_FLAGS-}"

		echo
		aba_info -n "Attempt ($try/$try_tot)."
		[ $try_tot -le 1 ] && echo_white " Set number of retries with 'aba -d mirror $action --retry <count>'" || echo
		aba_info "Running: cd data && umask 0022 && $cmd"

		aba_debug "Running oc-mirror $action"
		( cd data && umask 0022 && eval "$cmd" )
		local ret=$?
		aba_debug "oc-mirror $action exit code: $ret"

		if [ $ret -eq 0 ]; then
			aba_debug "$action completed successfully (ret=0)"
			failed=
			break
		fi

		# Decode the bitmask exit code for user feedback
		local decoded
		decoded=$(_oc_mirror_decode_exit $ret)
		exit_history="${exit_history:+$exit_history, }$ret"

		# Reduce oc-mirror parallelism and increase retry backoff on failure
		parallel_images=$(( parallel_images - 2 < 2 ? 2 : parallel_images - 2 ))
		retry_delay=$(( retry_delay + 2 > 10 ? 10 : retry_delay + 2 ))
		retry_times=$(( retry_times + 2 > 10 ? 10 : retry_times + 2 ))
		aba_debug "New tuning: parallel_images=$parallel_images retry_delay=$retry_delay retry_times=$retry_times"

		try=$(( try + 1 ))
		if [ $try -le $try_tot ]; then
			echo_red "[ABA] oc-mirror $action failed (exit=$ret: $decoded) -- history: [$exit_history] ... Trying again." >&2
		fi
	done

	if [ "$failed" ]; then
		try=$(( try - 1 ))
		aba_warning -n "Image $action aborted ..." >&2
		[ $try_tot -gt 1 ] && echo_white " (after $try/$try_tot attempts, history: [$exit_history])" || echo
		aba_warning \
			"Long-running processes, copying large amounts of data are prone to error! Resolve any issues (if needed) and try again." \
			"View https://status.redhat.com/ for any current issues or planned maintenance."
		[ $try_tot -eq 1 ] && echo_red "         Consider using the --retry option!" >&2

		return 1
	fi

	echo
	local _past="${action}ed"; [ "$action" = "save" ] && _past="saved"
	aba_info_ok -n "Images $_past successfully!"
	[ $try_tot -gt 1 ] && [ $try -gt 1 ] && echo_white " (after $try attempts!)" || echo

	return 0
}

# Usage: probe_host [--quick] [--any] <url> [description]
# Returns: 0 if reachable, 1 if not
#   --any:   accept any HTTP response (including 401); only fail on connection errors
#   --quick: short timeout, no retries (for interactive/TUI paths)
#
# Examples:
#   probe_host "https://api.openshift.com/"
#   probe_host --quick --any "https://registry:8443/v2/" "registry"
probe_host() {
	local _pf="-f" _connect_timeout=5 _max_time=15 _retry=2

	while true; do
		case "${1:-}" in
			--any)   _pf=""; shift ;;
			--quick) _connect_timeout=3; _max_time=5; _retry=0; shift ;;
			*)       break ;;
		esac
	done

	local url="$1"
	local desc="${2:-$url}"

	aba_debug "Probing $desc (timeout=${_connect_timeout}s, retries=$_retry)"

	# -k: skip TLS verification — probe_host checks unknown/untrusted hosts
	# (e.g. hairpin NAT diagnostics via localhost). Not used for primary verification.
	if curl -s $_pf \
		--connect-timeout "$_connect_timeout" \
		--max-time "$_max_time" \
		--retry "$_retry" \
		-ILk \
		"$url" >/dev/null 2>&1; then
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
if [[ -z "${TASK_INST_OC_MIRROR+x}" ]]; then
	# Install task IDs (TASK_INST_* to distinguish from TASK_DL_* download tasks)
	readonly TASK_INST_OC_MIRROR="cli:install:oc-mirror"
	readonly TASK_INST_OC="cli:install:oc"
	readonly TASK_INST_OPENSHIFT_INSTALL="cli:install:openshift-install"
	readonly TASK_INST_GOVC="cli:install:govc"
	readonly TASK_INST_BUTANE="cli:install:butane"
	readonly TASK_INST_QUAY_REG="mirror:reg:install"

	# Download task IDs (TASK_DL_*)
	readonly TASK_DL_OC_MIRROR="cli:download:oc-mirror"
	readonly TASK_DL_GOVC="cli:download:govc"
	readonly TASK_DL_BUTANE="cli:download:butane"
	readonly TASK_DL_QUAY_REG="mirror:reg:download"

	# Download commands (arrays)
	CMD_DL_OC=(make -sC cli download-oc)
	CMD_DL_OC_MIRROR=(make -sC cli download-oc-mirror)
	CMD_DL_OPENSHIFT_INSTALL=(make -sC cli download-openshift-install)
	CMD_DL_GOVC=(make -sC cli download-govc)
	CMD_DL_BUTANE=(make -sC cli download-butane)

	# Install commands (arrays) — plain make, no nesting
	CMD_INST_OC=(make -sC cli oc)
	CMD_INST_OC_MIRROR=(make -sC cli oc-mirror)
	CMD_INST_OPENSHIFT_INSTALL=(make -sC cli openshift-install)
	CMD_INST_GOVC=(make -sC cli govc)
	CMD_INST_BUTANE=(make -sC cli butane)

	# Mirror registry commands (arrays)
	CMD_DL_QUAY_REG=(make -sC mirror download-registries)
	CMD_INST_QUAY_REG=(make -sC mirror mirror-registry)
fi

# Download task IDs -- version-dependent (functions, return full ID with version)
task_dl_oc()                { echo "cli:download:oc:${ocp_version:?ocp_version not set}"; }
task_dl_openshift_install() { echo "cli:download:openshift-install:${ocp_version:?ocp_version not set}"; }

# Start all CLI tarball downloads (parallel, non-blocking)
start_all_cli_downloads() {
	scripts/cli-download-all.sh
}

# Wait for all CLI tarball downloads to complete
wait_all_cli_downloads() {
	scripts/cli-download-all.sh --wait
}

# Ensure the mirror registry has sigstore writes enabled in registries.d.
# Without this, oc-mirror fails with "writing sigstore attachments is disabled"
# when loading or syncing images whose source had use-sigstore-attachments: true.
# Creates a per-mirror file so multiple mirrors each get their own entry.
ensure_sigstore_mirror_config() {
	local mirror_host_port="$1"
	local sigstore_dir="$HOME/.config/containers/registries.d"

	[ -f "$sigstore_dir/aba-sigstore.yaml" ] || return 0

	# Replace colon with dash for safe filename (e.g. "mirror.example.com:8443" → "mirror.example.com-8443")
	local safe_name="${mirror_host_port//:/-}"
	local mirror_file="$sigstore_dir/aba-sigstore-mirror-${safe_name}.yaml"

	mkdir -p "$sigstore_dir"
	printf 'docker:\n    %s:\n        use-sigstore-attachments: true\n' \
		"$mirror_host_port" > "$mirror_file"

	aba_debug "Sigstore mirror config: $mirror_file ($mirror_host_port)"
}

# Ensure oc-mirror is installed in ~/bin
ensure_oc_mirror() {
	aba_debug "ensure_oc_mirror: downloading and installing oc-mirror"
	# Liberal bg kick-off (idempotent — fast no-op if already running/done)
	run_once -i "$TASK_DL_OC_MIRROR" -- "${CMD_DL_OC_MIRROR[@]}"
	# Targeted fg wait (no command — reloads from cmd.sh)
	run_once -q -w -i "$TASK_DL_OC_MIRROR"

	run_once -i "$TASK_INST_OC_MIRROR" -- "${CMD_INST_OC_MIRROR[@]}"
	run_once -w -m "Installing oc-mirror" -i "$TASK_INST_OC_MIRROR"
}

# Ensure oc CLI is installed in ~/bin
ensure_oc() {
	if [[ -z "${ocp_version:-}" ]]; then
		aba_debug "ensure_oc: ocp_version not set, skipping"
		return 0
	fi
	local task_dl
	task_dl=$(task_dl_oc)
	# Liberal bg kick-off (idempotent)
	run_once -i "$task_dl" -- "${CMD_DL_OC[@]}"
	# Targeted fg wait
	run_once -q -w -i "$task_dl"

	run_once -i "$TASK_INST_OC" -- "${CMD_INST_OC[@]}"
	run_once -w -m "Installing oc" -i "$TASK_INST_OC"
}

# Ensure openshift-install is installed in ~/bin
ensure_openshift_install() {
	if [[ -z "${ocp_version:-}" ]]; then
		aba_debug "ensure_openshift_install: ocp_version not set, skipping"
		return 0
	fi
	local task_dl
	task_dl=$(task_dl_openshift_install)
	# Liberal bg kick-off (idempotent)
	run_once -i "$task_dl" -- "${CMD_DL_OPENSHIFT_INSTALL[@]}"
	# Targeted fg wait
	run_once -q -w -i "$task_dl"

	run_once -i "$TASK_INST_OPENSHIFT_INSTALL" -- "${CMD_INST_OPENSHIFT_INSTALL[@]}"
	run_once -w -m "Installing openshift-install" -i "$TASK_INST_OPENSHIFT_INSTALL"
}

# Check if the OCP release image is available in the mirror registry.
# Pure curl — no skopeo or openshift-install needed.
# Handles both Docker (Basic auth) and Quay (Bearer token exchange).
# Two-phase check (run in parallel for speed):
#   Phase 1: GET /v2/ — verifies connectivity + TLS + credentials
#   Phase 2: GET /v2/.../manifests/<tag> — verifies the release image exists
# Requires: ocp_version (from normalize-aba-conf)
# Requires: reg_host, reg_port, reg_path, regcreds_dir (from normalize-mirror-conf)
# Returns: 0 if available, 1 if not.
# Sets: _release_ver, _release_http_code, _release_check_err, _release_check_extra[], _registry_auth_ok
check_release_image() {
	local _tag="${ocp_version:?ocp_version not set}-$(uname -m)"
	local _authfile="${regcreds_dir}/pull-secret-mirror.json"
	local _cacert="${regcreds_dir}/rootCA.pem"
	local _repo="${reg_path#/}/openshift/release-images"
	local _v2_url="https://$reg_host:$reg_port/v2/"
	local _manifest_url="https://$reg_host:$reg_port/v2/$_repo/manifests/$_tag"
	local _accept="Accept: application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json"

	_release_ver="$ocp_version"
	_release_http_code=""
	_release_check_err=""
	_release_check_extra=()
	_registry_auth_ok=false

	local _b64auth _userpass _curl_opts
	aba_debug "Running: jq -r '.auths[\"$reg_host:$reg_port\"].auth' $_authfile"
	_b64auth=$(jq -r ".auths[\"$reg_host:$reg_port\"].auth" "$_authfile" 2>/dev/null)

	# Guard: if pull secret has no entry for this hostname, fail fast with 401.
	# Without this, base64 -d of "null" produces garbage without a colon, causing
	# curl -u to prompt interactively for a password — hanging indefinitely (Bug #396).
	if [ -z "$_b64auth" ] || [ "$_b64auth" = "null" ]; then
		_release_http_code="401"
		_release_check_err="no credentials in pull secret for $reg_host:$reg_port"
		# Show what the pull secret actually contains to reveal hostname mismatches
		local _available_hosts
		_available_hosts=$(jq -r '.auths | keys[]' "$_authfile" 2>/dev/null | paste -sd ', ')
		if [ -n "$_available_hosts" ]; then
			_release_check_extra+=("Pull secret has credentials for: $_available_hosts")
			# Suggest fix if there's exactly one entry on the same port
			local _same_port
			_same_port=$(jq -r ".auths | keys[] | select(endswith(\":$reg_port\"))" "$_authfile" 2>/dev/null)
			if [ -n "$_same_port" ] && [ "$(echo "$_same_port" | wc -l)" -eq 1 ]; then
				_release_check_extra+=("Did you mean reg_host=${_same_port%:*} in mirror.conf?")
			fi
		fi
		_release_check_extra+=("Config: ${mirror_name:-mirror}/mirror.conf (reg_host=$reg_host)")
		_release_check_extra+=("Pull secret: ${regcreds_display:-$regcreds_dir}/pull-secret-mirror.json")
		return 1
	fi

	_userpass=$(echo "$_b64auth" | base64 -d)
	_curl_opts="--cacert $_cacert --connect-timeout 3 --max-time 10 --retry 1"

	local _td="$ABA_TMP/cri.$$"
	mkdir -p "$_td"

	# --- Fire Phase 1 (/v2/) and Phase 2 (manifest) in parallel with Basic auth ---
	aba_debug "Parallel check: Phase 1 ($_v2_url) + Phase 2 ($_manifest_url)"

	curl -sS -o "$_td/p1.body" -w "%{http_code}" \
		$_curl_opts -H "Authorization: Basic $_b64auth" \
		"$_v2_url" 2>"$_td/p1.err" > "$_td/p1.code" &
	local _pid1=$!

	curl -sS -o "$_td/p2.body" -w "%{http_code}" \
		$_curl_opts -H "Authorization: Basic $_b64auth" \
		-H "$_accept" \
		"$_manifest_url" 2>"$_td/p2.err" > "$_td/p2.code" &
	local _pid2=$!

	wait "$_pid1" "$_pid2" 2>/dev/null || true

	local _p1_code _p2_code
	_p1_code=$(cat "$_td/p1.code" 2>/dev/null)
	_p2_code=$(cat "$_td/p2.code" 2>/dev/null)

	aba_debug "Parallel Basic auth results: Phase 1=$_p1_code Phase 2=$_p2_code"

	# --- Fast path: Docker registry where Basic auth works for both ---
	if [ "$_p1_code" = "200" ]; then
		_registry_auth_ok=true
		if [ "$_p2_code" = "200" ]; then
			rm -rf "$_td"
			return 0
		fi
	fi

	# --- Quay path: both return 401 with Basic, need Bearer token exchange ---
	# A successful token exchange proves credentials are valid (no separate /v2/ check needed).
	if [ "$_p1_code" = "401" ]; then
		local _token_url="https://$reg_host:$reg_port/v2/auth?service=$reg_host:$reg_port&scope=repository:$_repo:pull"
		aba_debug "Running: curl -s $_curl_opts -u <redacted> $_token_url"
		local _token
		_token=$(curl -s $_curl_opts \
			-u "$_userpass" \
			"$_token_url" 2>/dev/null \
			| jq -r '.token // empty' 2>/dev/null)

		if [ -n "$_token" ]; then
			_registry_auth_ok=true
			aba_debug "Bearer token obtained — credentials valid, checking manifest"
			aba_debug "Running: curl -sS -w %{http_code} $_curl_opts -H 'Authorization: Bearer <redacted>' -H '$_accept' $_manifest_url"
			_p2_code=$(curl -sS -o "$_td/p2.body" -w "%{http_code}" \
				$_curl_opts \
				-H "Authorization: Bearer $_token" \
				-H "$_accept" \
				"$_manifest_url" 2>"$_td/p2.err") || true

			aba_debug "Bearer manifest result: HTTP $_p2_code"
			if [ "$_p2_code" = "200" ]; then
				rm -rf "$_td"
				return 0
			fi
		fi
	fi

	# --- Failure: extract error details ---
	if [ "$_registry_auth_ok" = "false" ]; then
		# Phase 1 failed — report /v2/ error
		_release_http_code="${_p1_code:-000}"
		_release_check_err=$(cat "$_td/p1.err" 2>/dev/null)
		if [ -s "$_td/p1.body" ]; then
			local _body_err
			_body_err=$(jq -r '.errors[0].message // empty' "$_td/p1.body" 2>/dev/null)
			if [ -n "$_body_err" ]; then
				_release_check_err="$_body_err"
			elif [ "$_p1_code" != "000" ]; then
				_release_check_err=$(head -c 200 "$_td/p1.body")
			fi
		fi
	else
		# Phase 1 passed but Phase 2 failed — report manifest error
		_release_http_code="${_p2_code:-000}"
		_release_check_err=$(cat "$_td/p2.err" 2>/dev/null)
		if [ -s "$_td/p2.body" ]; then
			local _body_err
			_body_err=$(jq -r '.errors[0].message // empty' "$_td/p2.body" 2>/dev/null)
			if [ -n "$_body_err" ]; then
				_release_check_err="$_body_err"
			elif [ "$_p2_code" != "000" ]; then
				_release_check_err=$(head -c 200 "$_td/p2.body")
			fi
		fi
	fi

	rm -rf "$_td"
	aba_debug "FAILED: auth_ok=$_registry_auth_ok HTTP $_release_http_code — $_release_check_err"

	return 1
}

# =============================================================================
# Background task wrappers (for TUI and CLI callers)
# =============================================================================
# These wrap run_once() so callers don't need to know task IDs or flags.

# --- Mirror check-image (release image present in registry?) ---

# Start check-image in background (non-blocking)
aba_mirror_verify_start() {
	run_once -i "aba:mirror:check-image" -- bash -lc "cd '${ABA_ROOT:-.}' && make -sC mirror check-image"
}

# Re-trigger after sync/load (invalidate old result, start fresh check)
aba_mirror_verify_refresh() {
	run_once -r -i "aba:mirror:check-image" 2>/dev/null || true
	aba_mirror_verify_start
}

# Wait for check-image to complete (blocking). For use after sync/load/install.
# Uses -S (skip validation) because _invalidate_mirror_cache already started a
# fresh check — re-running it would add a redundant 4-5s delay.
aba_mirror_verify_wait() {
	run_once -q -w -S -i "aba:mirror:check-image" 2>/dev/null || true
}

# Get cached exit code (non-blocking, for menu rendering). Echoes exit code.
aba_mirror_verify_exit() {
	run_once -E -i "aba:mirror:check-image" 2>/dev/null
}

# --- Internet connectivity ---

# Start internet check in background (non-blocking)
aba_inet_check_start() {
	run_once -i "aba:check:internet" -- \
		bash -lc "source '${ABA_ROOT:-.}/scripts/include_all.sh' && check_internet_connectivity aba quiet"
}

# Wait for internet check result (blocking)
aba_inet_check_wait() {
	run_once -q -w -i "aba:check:internet" 2>/dev/null || true
}

# Wait and return success/failure (for mode detection)
aba_inet_check_wait_status() {
	run_once -q -w -S -i "aba:check:internet" 2>/dev/null || true
}

# Reset cached internet check (use at TUI startup to force a fresh probe)
aba_inet_check_reset() {
	run_once -r -i "aba:check:internet"
	# Also reset per-site caches (300s TTL) so a fresh probe doesn't reuse stale failures
	run_once -r -i "aba:check:api.openshift.com" 2>/dev/null || true
	run_once -r -i "aba:check:mirror.openshift.com" 2>/dev/null || true
	run_once -r -i "aba:check:registry.redhat.io" 2>/dev/null || true
}

# Re-check internet with TTL cache (returns cached result within TTL seconds)
aba_inet_check_cached() {
	local ttl="${1:-30}"
	run_once -i "aba:check:internet" -t "$ttl" -- \
		bash -lc "source '${ABA_ROOT:-.}/scripts/include_all.sh' && check_internet_connectivity aba quiet" 2>/dev/null
	# If no result exists yet (first call or after TTL expiry), wait for the check to complete.
	# Uses -S: TTL already ensures freshness — self-healing validation is redundant here.
	if ! run_once -p -i "aba:check:internet" 2>/dev/null; then
		run_once -q -w -S -i "aba:check:internet" 2>/dev/null || true
	fi
	run_once -E -i "aba:check:internet" 2>/dev/null | grep -q '^0$'
}

# --- OCP version fetch ---

# Start version fetches for all channels in background (non-blocking).
# Stable/stable-channel graph data is warmed early; prefetch uses fetch_latest_z_version
# (shared Cincinnati cache via _fetch_graph_cached) when aba.conf has no ocp_version yet.
aba_version_fetch_start() {
	local _ch
	for _ch in stable fast candidate; do
		run_once -i "ocp:${_ch}:latest_version"          -- bash -lc "source ./scripts/include_all.sh; fetch_latest_version $_ch"
		run_once -i "ocp:${_ch}:latest_version_previous" -- bash -lc "source ./scripts/include_all.sh; fetch_previous_version $_ch"
		run_once -i "ocp:${_ch}:latest_version_older"    -- bash -lc "source ./scripts/include_all.sh; fetch_older_version $_ch"
	done
}

# --- ISC generation ---

# Start ISC generation in background (non-blocking)
# Uses make directly to avoid aba.sh's CLI download side-effects (SIGPIPE race condition)
aba_isconf_generate_start() {
	run_once -i "aba:isconf:generate" -- \
		make -sC "${ABA_ROOT:-.}/mirror" isconf
}

# --- Cleanup ---

# Clean up failed/stale run_once tasks
aba_bg_cleanup() {
	run_once -F 2>/dev/null || true
}

# Ensure govc is installed in ~/bin
ensure_govc() {
	aba_debug "ensure_govc: downloading and installing govc"
	# Liberal bg kick-off (idempotent)
	run_once -i "$TASK_DL_GOVC" -- "${CMD_DL_GOVC[@]}"
	# Targeted fg wait
	run_once -q -w -i "$TASK_DL_GOVC"

	run_once -i "$TASK_INST_GOVC" -- "${CMD_INST_GOVC[@]}"
	run_once -w -m "Installing govc" -i "$TASK_INST_GOVC"
}

ensure_virsh() {
	install_rpms libvirt-client virt-install
}

# Ensure butane is installed in ~/bin
ensure_butane() {
	aba_debug "ensure_butane: downloading and installing butane"
	# Liberal bg kick-off (idempotent)
	run_once -i "$TASK_DL_BUTANE" -- "${CMD_DL_BUTANE[@]}"
	# Targeted fg wait
	run_once -q -w -i "$TASK_DL_BUTANE"

	run_once -i "$TASK_INST_BUTANE" -- "${CMD_INST_BUTANE[@]}"
	run_once -w -m "Installing butane" -i "$TASK_INST_BUTANE"
}

# Ensure mirror-registry (Quay) is installed (extracted)
# Wait: aba.sh starts $TASK_INST_QUAY_REG and $TASK_DL_QUAY_REG in background
ensure_quay_registry() {
	aba_debug "ensure_quay_registry: installing mirror-registry"
	run_once -i "$TASK_DL_QUAY_REG" -- "${CMD_DL_QUAY_REG[@]}"
	run_once -q -w -i "$TASK_DL_QUAY_REG"

	run_once -i "$TASK_INST_QUAY_REG" -- "${CMD_INST_QUAY_REG[@]}"
	run_once -w -m "Installing mirror-registry" -i "$TASK_INST_QUAY_REG"
}

# Get error output from a task (helper for error messages)
get_task_error() {
	local task_id="$1"
	run_once -e -i "$task_id"
}

# Check if running from an ABA bundle (disconnected/DISCO environment).
# The .bundle flag file is created by backup.sh when building the archive.
# Returns: 0 if in bundle mode, 1 otherwise.
is_bundle_mode() {
	[ -f "${ABA_ROOT:-.}/.bundle" ]
}

# Check internet connectivity to required sites
# Usage: check_internet_connectivity <prefix> [quiet]
#   prefix: Task ID prefix (e.g., "aba" for shared CLI/TUI probes)
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
	
	# Start: 3 connectivity checks in parallel (5-min TTL). Wait: immediately below.
	run_once -t 300 -i "${prefix}:check:api.openshift.com" -- curl -sL --head --connect-timeout 5 --max-time 10 https://api.openshift.com/
	run_once -t 300 -i "${prefix}:check:mirror.openshift.com" -- curl -sL --head --connect-timeout 5 --max-time 10 https://mirror.openshift.com/
	run_once -t 300 -i "${prefix}:check:registry.redhat.io" -- curl -sL --head --connect-timeout 5 --max-time 10 https://registry.redhat.io/
	
	# Wait: block for the 3 checks started above
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

# Pre-flight check for commands that require internet + pull secret (save, sync).
# Checks both conditions and reports ALL issues at once so the user can fix everything in one pass.
# Usage: require_internet_and_pull_secret
# Requires: $pull_secret_file set (from normalize-aba-conf)
require_internet_and_pull_secret() {
	local errors=()
	local has_internet=true

	# Check internet (quick probe, 5s timeout)
	if ! curl -sILk --connect-timeout 5 --max-time 10 https://registry.redhat.io/v2/ >/dev/null 2>&1; then
		has_internet=false
		errors+=("No internet access (cannot reach registry.redhat.io)")
	fi

	# Check pull secret
	if [ ! -s "$pull_secret_file" ]; then
		errors+=("Pull secret not found at $pull_secret_file")
	elif ! grep -q registry.redhat.io "$pull_secret_file"; then
		errors+=("Pull secret at $pull_secret_file does not contain registry.redhat.io credentials")
	elif ! jq empty "$pull_secret_file" 2>/dev/null; then
		errors+=("Pull secret at $pull_secret_file has invalid JSON syntax")
	fi

	# All good
	[ ${#errors[@]} -eq 0 ] && return 0

	# Report all issues
	if [ ${#errors[@]} -eq 1 ]; then
		if [ "$has_internet" = "false" ]; then
			aba_abort "${errors[0]}" \
				"The 'save' and 'sync' commands require a connected host with internet access."
		else
			aba_abort "${errors[0]}" \
				"Fetch your pull secret from https://console.redhat.com/openshift/downloads#tool-pull-secret (select 'Tokens' in the pull-down)" \
				"and save it to $pull_secret_file"
		fi
	else
		aba_abort "Cannot proceed — the following issues must be resolved:" \
			"  1. ${errors[0]}" \
			"  2. ${errors[1]}" \
			"" \
			"The 'save' and 'sync' commands require a connected host with internet access." \
			"Fetch your pull secret from https://console.redhat.com/openshift/downloads#tool-pull-secret (select 'Tokens' in the pull-down)" \
			"and save it to $pull_secret_file"
	fi
}
