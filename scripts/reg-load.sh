#!/bin/bash
# INTENT:      Load saved images from mirror/data/ into the mirror registry via oc-mirror
# CALLED BY:   mirror/Makefile (load target)
# CWD:         mirror/ (oc-mirror runs from mirror/data/)
# ARGS:        [retry_count] number of retries on failure (default: 1 attempt)
# REQUIRES:    oc-mirror binary, mirror_*.tar in data/, data/imageset-config.yaml,
#              registry installed and reachable (reg_host:reg_port from mirror.conf)
# PRODUCES:    Images pushed to registry; data/working-dir/ populated by oc-mirror
# SIDE EFFECTS:
#   - After successful load: touches data/.created (unlocks ISC) unless data/.isc-pinned exists
#   - Removes ../.bundle and data/.isc-pinned (bundle phase complete, repo becomes normal)
#   - Sets TMPDIR and OC_MIRROR_CACHE to data_dir if configured
# IDEMPOTENT:  Yes (oc-mirror skips images already present in the registry)
# ENV:         INFO_ABA (default: 1 when called from make)

# Load the registry with images from the local disk

# CWD is set by mirror/Makefile to the correct mirror directory

# Enable INFO messages by default when called directly from make
# (unless explicitly disabled by parent process via --quiet)
[ -z "${INFO_ABA+x}" ] && export INFO_ABA=1

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

try_tot=1  # def. value
[ "$1" == "y" ] && set -x && shift  # If the debug flag is "y"
[ "$1" ] && [ $1 -gt 0 ] && try_tot=`expr $1 + 1` && echo "[ABA] Attempting $try_tot times to load the images into the registry."    # If the retry value exists and it's a number
aba_debug "try_tot=$try_tot"

umask 077

aba_debug "Loading configuration files"
source <(normalize-aba-conf)
source <(normalize-mirror-conf)
export regcreds_dir=$HOME/.aba/mirror/$(basename "$PWD")
export regcreds_display="regcreds"

verify-aba-conf || aba_abort "$_ABA_CONF_ERR"
verify-mirror-conf || aba_abort "Invalid or incomplete mirror.conf. Check the errors above and fix mirror/mirror.conf."
aba_debug "Configuration validated"

# Be sure a download has started ..
#PLAIN_OUTPUT=1 run_once    -i cli:install:oc-mirror -- make -sC cli oc-mirror
aba_debug "Ensuring oc-mirror is available"
if ! ensure_oc_mirror; then
	error_msg=$(get_task_error "$TASK_INST_OC_MIRROR")
	aba_abort "Downloading oc-mirror binary failed:\n$error_msg\n\nPlease check network and try again."
fi
aba_debug "oc-mirror is ready"


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
		"Registry must be accessible before loading images" \
		"Tried: /health/instance (Quay), /v2/ (Docker), / (generic)"
fi

aba_debug "Creating containers auth file for load operation"
scripts/create-containers-auth.sh --load || exit 1   # --load option indicates that the public pull secret is NOT needed.

# Check if the cert needs to be updated
aba_debug "Checking for root CA certificate"
if [ -s "$regcreds_dir/rootCA.pem" ]; then
	aba_debug "Installing root CA certificate"
	trust_root_ca "$regcreds_dir/rootCA.pem" # FIXME: Is this required here since the rootCA.pem is installed after reg install?
else
	aba_warning "No $regcreds_display/rootCA.pem cert file found (skipTLS=$skipTLS)" 
fi

[ ! "$data_dir" ] && data_dir=\~
reg_root=$data_dir/quay-install
aba_debug "data_dir=$data_dir reg_root=$reg_root"

if [ ! -d data ]; then
	aba_abort "Error: Missing 'mirror/data' directory!  For air-gapped environments, run 'aba -d mirror save' first on an external (Internet connected) bastion/laptop" 
fi
aba_debug "data/ directory exists"

ensure_sigstore_mirror_config "$reg_host:$reg_port"

echo
aba_info "Using oc-mirror version $(oc-mirror version 2>&1 | grep 'environment version:' | sed 's/.*environment version: //' | cut -d. -f1-3 | sed 's/\(-[0-9]*\).*/\1/')"
aba_info "Now loading (disk2mirror) the images from mirror/data/ directory to registry $reg_host:$reg_port$reg_path."
echo

# Check if *aba installed Quay* (if so, show warning) or it's an existing reg. (no need to show warning)
if [ -s ./reg-uninstall.sh ]; then
	aba_warning \
		"Ensure there is enough disk space under $reg_root." \
		"This can take 5 to 20 minutes to complete or even longer if Operator images are being loaded!"
fi
echo

# Now using data_dir so reg_root=$data_dir/quay-install
# Set TMPDIR and OC_MIRROR_CACHE paths (defer mkdir to just before oc-mirror needs them)
[[ ! "$TMPDIR" && "$data_dir" ]] && export TMPDIR="$(_expand_tilde "$data_dir")/.tmp" && aba_debug "TMPDIR=$TMPDIR"
# Note that the cache is always used except for mirror-to-mirror (sync) workflows!
# Place the '.oc-mirror/.cache' into a location where there should be more space, i.e. $data_dir.
[[ ! "$OC_MIRROR_CACHE" && "$data_dir" ]] && export OC_MIRROR_CACHE="$(_expand_tilde "$data_dir")" && aba_debug "OC_MIRROR_CACHE=$OC_MIRROR_CACHE"

# --v2 is an oc-mirror CLI flag (not related to OCP version). May become default in future releases.
base_cmd="oc-mirror --v2 --config imageset-config.yaml --from file://. docker://$reg_host:$reg_port$reg_path"

[ "$TMPDIR" ] && mkdir -p "$TMPDIR"
[ "$OC_MIRROR_CACHE" ] && mkdir -p "$OC_MIRROR_CACHE"

if ! _run_oc_mirror_with_retry "load" "$try_tot" "$base_cmd"; then
	exit 1
fi

# Bundle phase complete: unlock ISC so future config changes trigger regeneration.
# touch .created makes it newer than ISC → reg-create-imageset-config.sh will regenerate.
# Skip if .isc-pinned exists — user hand-edited the ISC and wants it preserved permanently.
# Remove .bundle and .isc-pinned: this repo is now a normal disconnected tree.
if [ ! -f data/.isc-pinned ]; then
	touch data/.created
fi
rm -f ../.bundle data/.isc-pinned

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
