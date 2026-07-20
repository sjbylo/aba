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
[ "$1" ] && [ $1 -gt 0 ] && try_tot=$(( $1 + 1 )) && aba_info "Attempting $try_tot times to sync the images to the registry."    # If the retry value exists and it's a number
aba_debug "try_tot=$try_tot"

umask 077

aba_debug "Loading configuration files"
source <(normalize-aba-conf)
source <(normalize-mirror-conf)
export regcreds_dir=$HOME/.aba/mirror/$(basename "$PWD")

verify-aba-conf || aba_abort "$_ABA_CONF_ERR"
verify-mirror-conf || aba_abort "Invalid or incomplete mirror.conf. Check the errors above and fix mirror/mirror.conf."
aba_debug "Configuration validated"

# Pre-flight: verify internet access and pull secret before proceeding.
# Pass mirror-specific pull secret as fallback for hosts without a global pull secret.
require_internet_and_pull_secret "$regcreds_dir/pull-secret-mirror.json"

# Pre-flight: verify release version(s) exist in Cincinnati graph before running oc-mirror
aba_info "Verifying release image availability for v${ocp_version} ..."
if ! verify_release_version_exists "$ocp_version"; then
	aba_abort \
		"Release version $ocp_version not found in '${ocp_channel}' channel (arch: ${ARCH:-amd64})." \
		"This version may not have been released yet, or the channel may be wrong." \
		"Use 'aba ocp-versions' to list available versions."
fi
if [ "${ocp_upgrade_to:-}" ] && [ "$ocp_upgrade_to" != "$ocp_version" ]; then
	aba_info "Verifying release image availability for upgrade target v${ocp_upgrade_to} ..."
	if ! verify_release_version_exists "$ocp_upgrade_to"; then
		aba_abort \
			"Upgrade target version $ocp_upgrade_to not found in '${ocp_channel}' channel (arch: ${ARCH:-amd64})." \
			"This version may not have been released yet, or the channel may be wrong." \
			"Use 'aba ocp-versions' to list available versions."
	fi
	# Fail fast: verify upgrade path exists before starting downloads
	_path_diag=""
	if ! _path_diag=$(verify_upgrade_path_exists "$ocp_version" "$ocp_upgrade_to" "$ocp_channel" 2>&1); then
		_tgt_ch="${_path_diag#*|}" && _tgt_ch="${_tgt_ch%%|*}"   # middle field (target channel)
		_lowest="${_path_diag##*|}"                              # last field (lowest entry point)
		aba_abort \
			"Cannot upgrade directly from $ocp_version to $ocp_upgrade_to." \
			"Version $ocp_version is not in channel ${_tgt_ch} (lowest entry: ${_lowest:-unknown})." \
			"You need to upgrade to at least ${_lowest:-a version in ${_tgt_ch}} first." \
			"" \
			"Verify upgrade paths at: https://access.redhat.com/labs/ocpupgradegraph/update_path/"
	fi

	# Auto-fix: upgrade requires release images — excl_platform=true would omit them
	if [ "${excl_platform:-}" = "true" ]; then
		aba_warn "Upgrade target set (${ocp_upgrade_to}) but excl_platform=true — release images would be missing." \
			"Switching excl_platform=false in aba.conf to include release images."
		replace-value-conf -n excl_platform -v "false" -f "$ABA_ROOT/aba.conf"
		excl_platform=false
	fi
fi

# Be sure a download has started ..
aba_debug "Ensuring oc-mirror is available"
if ! PLAIN_OUTPUT=1 ensure_oc_mirror; then
	error_msg=$(get_task_error "$TASK_INST_OC_MIRROR")
	aba_abort "Downloading oc-mirror binary failed:\n$error_msg\n\nPlease check network and try again."
fi
aba_debug "oc-mirror is ready"

# Check for mirror-specific pull secret override
pull_secret_mirror_file=pull-secret-mirror.json
if [ -s $pull_secret_mirror_file ]; then
	aba_info Using $pull_secret_mirror_file ...
	aba_debug "Using mirror-specific pull secret"
elif [ -s $pull_secret_file ]; then
	aba_debug "Using default pull secret: $pull_secret_file"
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
elif probe_host --any "$reg_url/v2/" "Docker registry API"; then
	aba_debug "Docker/OCI registry detected and accessible"
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
aba_info "Using oc-mirror version $(oc_mirror_version)"
aba_info "Now syncing (mirror2mirror) images from external network to registry $reg_host:$reg_port$reg_path. "

# Check if *aba installed Quay* (if so, show warning) or it's an existing reg. (no need to show warning)
if [ -s ./reg-uninstall.sh ]; then
	aba_warn \
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

# After successful sync: update state.sh with mirror facts.
# mirror_ocp_version tracks what's actually in the mirror (highest synced version).
# mirror_ocp_upgrade_from tracks the source version of an upgrade sync.
_synced_ver="${ocp_upgrade_to:-$ocp_version}"
replace-value-conf -q -n ocp_version -v "$_synced_ver" -f "$regcreds_dir/state.sh"
replace-value-conf -q -n mirror_ocp_version -v "$_synced_ver" -f "$regcreds_dir/state.sh"
if [ "${ocp_upgrade_to:-}" ] && [ "$ocp_upgrade_to" != "$ocp_version" ]; then
	replace-value-conf -q -n mirror_ocp_upgrade_from -v "$ocp_version" -f "$regcreds_dir/state.sh"
else
	replace-value-conf -q -n mirror_ocp_upgrade_from -v "" -f "$regcreds_dir/state.sh"
fi
replace-value-conf -q -n last_action -v "sync" -f "$regcreds_dir/state.sh"
replace-value-conf -q -n last_action_at -v "$(date '+%Y-%m-%d %H:%M:%S')" -f "$regcreds_dir/state.sh"
if [ "$_synced_ver" != "$ocp_version" ]; then
	aba_info "Mirror state updated: mirror_ocp_version $ocp_version → $_synced_ver"
fi

echo
if [ ! "${ABA_SUPPRESS_WARNINGS:-}" ]; then
	# Context-aware next steps: upgrade sync vs initial sync
	_is_upgrade=""
	[ "${ocp_upgrade_to:-}" ] && [ "$ocp_upgrade_to" != "$ocp_version" ] && _is_upgrade=1

	if have_installed_clusters=$(echo ../*/.install-complete) && [ "$have_installed_clusters" != "../*/.install-complete" ]; then
		if [ "$_is_upgrade" ]; then
			aba_info "Next steps for upgrade ($ocp_version → $ocp_upgrade_to):"
			aba_info "  1. aba -d <cluster> day2       (apply updated CatalogSources/IDMS)"
			aba_info "  2. aba -d <cluster> upgrade --to $ocp_upgrade_to"
		else
			aba_info "Next steps:"
			aba_info "  a) Install a new cluster:  aba cluster --name <name> --type <sno|compact|standard>"
			aba_info "  b) Update an existing cluster:  aba -d <cluster> day2"
		fi
	else
		aba_info "Next: aba cluster --name <name> --type <sno|compact|standard> (or run abatui)"
		aba_info "Run 'aba cluster --help' for more information about installing clusters."
	fi
	echo
fi

exit 0
