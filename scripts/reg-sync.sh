#!/bin/bash 
# Copy images from RH reg. into the registry.

# CWD is set by mirror/Makefile to the correct mirror directory

# Enable INFO messages by default when called directly from make
# (unless explicitly disabled by parent process via --quiet)
[ -z "${INFO_ABA+x}" ] && export INFO_ABA=1

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

try_tot=1  # def. value
#[ "$1" == "y" ] && set -x && shift  # If the debug flag is "y"
[ "$1" ] && [ $1 -gt 0 ] && try_tot=`expr $1 + 1` && aba_info "Attempting $try_tot times to sync the images to the registry."    # If the retry value exists and it's a number
aba_debug "try_tot=$try_tot"

umask 077

aba_debug "Loading configuration files"
source <(normalize-aba-conf)
source <(normalize-mirror-conf)
export regcreds_dir=$HOME/.aba/mirror/$(basename "$PWD")

verify-aba-conf || aba_abort "$_ABA_CONF_ERR"
verify-mirror-conf || aba_abort "Invalid or incomplete mirror.conf. Check the errors above and fix mirror/mirror.conf."
aba_debug "Configuration validated"

# Be sure a download has started ..
aba_debug "Ensuring oc-mirror is available"
if ! PLAIN_OUTPUT=1 ensure_oc_mirror; then
	error_msg=$(get_task_error "$TASK_OC_MIRROR")
	aba_abort "Downloading oc-mirror binary failed:\n$error_msg\n\nPlease check network and try again."
fi
aba_debug "oc-mirror is ready"

# This is a pull secret for RH registry
pull_secret_mirror_file=pull-secret-mirror.json
aba_debug "Checking pull secret files: $pull_secret_mirror_file or $pull_secret_file"

if [ -s $pull_secret_mirror_file ]; then
	aba_info Using $pull_secret_mirror_file ...
	aba_debug "Using mirror-specific pull secret"
elif [ -s $pull_secret_file ]; then
	aba_debug "Using default pull secret: $pull_secret_file"
	:
else
	aba_abort \
		"The pull secret file '$pull_secret_file' does not exist!" \
		"Download it from https://console.redhat.com/openshift/downloads#tool-pull-secret (select 'Tokens' in the pull-down)"
fi

# Check internet connection to the registries oc-mirror pulls from
aba_info "Checking Internet access to registry.redhat.io"

if ! curl -sILk --connect-timeout 10 --max-time 15 --retry 2 https://registry.redhat.io/v2/ >/dev/null 2>&1; then
	aba_abort "Cannot access https://registry.redhat.io/" \
		"Access to registry.redhat.io is required to sync images to your registry."
fi

export reg_url=https://$reg_host:$reg_port
aba_debug "reg_url=$reg_url reg_host=$reg_host reg_port=$reg_port reg_path=$reg_path"

# Adjust no_proxy if proxy is configured (duplicates are harmless for temporary export)
[ "$http_proxy" ] && export no_proxy="${no_proxy:+$no_proxy,}$reg_host" && aba_debug "Adjusted no_proxy=$no_proxy"

# Can the registry mirror already be reached?
# Support both Quay and Docker registries with different health endpoints
aba_info "Probing mirror registry at $reg_url"

if probe_host "$reg_url/health/instance" "Quay registry health endpoint"; then
	aba_debug "Quay registry detected and accessible"
elif probe_host "$reg_url/v2/" "Docker registry API"; then
	aba_debug "Docker registry detected and accessible"
elif probe_host "$reg_url/" "registry root"; then
	aba_debug "Generic registry detected and accessible"
else
	aba_abort "Cannot reach mirror registry at $reg_url" \
		"Registry must be accessible before syncing images" \
		"Tried: /health/instance (Quay), /v2/ (Docker), / (generic)"
fi

# This is needed since sometimes an existing registry may already be available
aba_debug "Creating containers auth file"
scripts/create-containers-auth.sh || exit 1

[ ! "$data_dir" ] && data_dir=\~
reg_root=$data_dir/quay-install
aba_debug "data_dir=$data_dir reg_root=$reg_root"

###[ ! "$reg_root" ] && reg_root=$HOME/quay-install  # Needed for below TMPDIR

ensure_sigstore_mirror_config "$reg_host:$reg_port"

echo
aba_info "Now syncing (mirror2mirror) images from external network to registry $reg_host:$reg_port$reg_path. "

# Check if *aba installed Quay* (if so, show warning) or it's an existing reg. (no need to show warning)
if [ -s ./reg-uninstall.sh ]; then
	aba_warning \
		"Ensure there is enough disk space under $reg_root." \
		"This can take 5 to 20 minutes to complete or even longer if Operator images are being copied!"
fi
echo

# NOTE: that the cache is always used *except* for mirror-to-mirror (sync) workflows, where it is not used! See reg-save.sh and reg-load.sh.
# Set TMPDIR path (defer mkdir to just before oc-mirror needs it)
[[ ! "$TMPDIR" && "$data_dir" ]] && export TMPDIR="$(_expand_tilde "$data_dir")/.tmp" && aba_debug "TMPDIR=$TMPDIR"

# --v2 is an oc-mirror CLI flag (not related to OCP version). May become default in future releases.
base_cmd="oc-mirror --v2 --config imageset-config.yaml --workspace file://. docker://$reg_host:$reg_port$reg_path"

[ "$TMPDIR" ] && mkdir -p "$TMPDIR"

if ! _run_oc_mirror_with_retry "sync" "$try_tot" "$base_cmd"; then
	exit 1
fi

echo
aba_info_ok "OpenShift can now be installed. From aba's top-level directory, run the command:"
aba_info_ok "  aba cluster --name mycluster [--type <sno|compact|standard>] [--starting-ip <ip>] [--api-vip <ip>] [--ingress-vip <ip>]"
aba_info_ok "Run 'aba cluster --help' for more information about installing clusters."

echo
if have_installed_clusters=$(echo ../*/.install-complete) && [ "$have_installed_clusters" != "../*/.install-complete" ]; then
	aba_warning -c magenta -p IMPORTANT \
		"If you have already installed a cluster, (re-)run the command 'aba -d <clustername> day2'" \
		"to configure/refresh OperatorHub/Catalogs, Signatures etc."
	echo
fi

exit 0
