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
#   - Auto-updates aba.conf ocp_version/ocp_channel if ISC version differs (Bug #956)
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
[ "$1" ] && [ $1 -gt 0 ] && try_tot=$(( $1 + 1 )) && echo "[ABA] Attempting $try_tot times to load the images into the registry."    # If the retry value exists and it's a number
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

# Unpack upgrade bundle if present (contains ISC, digest ISC, CLI tarballs, metadata).
# This must happen before oc-mirror runs so the correct ISC is in place.
# Tar paths are relative to aba root (mirror/data/*, cli/*), so unpack from aba root.
_upgrade_tar="data/aba-upgrade.tar"
_upgrade_meta_ver=""
_upgrade_meta_chan=""
if [ -f "$_upgrade_tar" ]; then
	aba_info "Found upgrade bundle: $_upgrade_tar"

	# Unpack from aba root (CWD is mirror/, aba root is ..)
	if ! ( cd .. && tar xf "mirror/$_upgrade_tar" ); then
		aba_abort "Failed to unpack upgrade bundle ($_upgrade_tar)." \
			"The file may be corrupt. Re-copy mirror/data/*.tar from the connected host."
	fi

	# Read and validate metadata (unpacked to mirror/data/ by the tar)
	if [ -f "data/aba-upgrade-metadata.json" ]; then
		_upgrade_meta_ver=$(grep '"ocp_version"' data/aba-upgrade-metadata.json | sed 's/.*: *"//; s/".*//')
		_upgrade_meta_chan=$(grep '"ocp_channel"' data/aba-upgrade-metadata.json | sed 's/.*: *"//; s/".*//')
		_expected_sha=$(grep '"digest_isc_sha256"' data/aba-upgrade-metadata.json | sed 's/.*: *"//; s/".*//')

		aba_info "Upgrade bundle: OCP ${_upgrade_meta_ver} (${_upgrade_meta_chan})"

		# Verify digest ISC integrity if checksum is available
		if [ "$_expected_sha" ] && [ -f "data/imageset-config-digest.yaml" ]; then
			_actual_sha=$(sha256sum "data/imageset-config-digest.yaml" | awk '{print $1}')
			if [ "$_actual_sha" != "$_expected_sha" ]; then
				aba_abort "imageset-config-digest.yaml checksum mismatch." \
					"The digest ISC does not match the upgrade bundle metadata." \
					"Re-copy mirror/data/*.tar from the connected host."
			fi
			aba_debug "Digest ISC checksum verified OK"
		fi
	else
		aba_warning "Upgrade bundle has no metadata file — skipping version/checksum validation."
	fi

	# Remove the upgrade bundle (small, ephemeral delivery vehicle)
	rm -f "$_upgrade_tar" data/aba-upgrade-metadata.json
	aba_info "Upgrade bundle unpacked and removed."
fi

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
aba_info "Using oc-mirror version $(oc_mirror_version)"
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

# Pre-validate version before the long oc-mirror load (fail fast, not after 30 min).
# Prefer upgrade bundle metadata (explicit), fall back to ISC parsing.
_loaded_ver=""
_loaded_chan=""
if [ "$_upgrade_meta_ver" ]; then
	_loaded_ver="$_upgrade_meta_ver"
	_loaded_chan="$_upgrade_meta_chan"
	aba_debug "Version from upgrade bundle metadata: ver=$_loaded_ver chan=$_loaded_chan"
else
	_isc_file="data/imageset-config.yaml"
	if [ -f "$_isc_file" ]; then
		_loaded_ver=$(grep '^\s*maxVersion:' "$_isc_file" | head -1 | sed 's/.*maxVersion: *//')
		_loaded_chan=$(grep -E '^\s*- name: (stable|fast|candidate|eus)-[0-9]' "$_isc_file" | head -1 | sed 's/.*- name: *//; s/-[0-9].*//')
		if [ "$_loaded_ver" ] && ! echo "$_loaded_ver" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+'; then
			aba_abort "Cannot parse a valid OCP version from $_isc_file (got: '$_loaded_ver')." \
				"Check the imageset-config.yaml and try again."
		fi
		aba_debug "Version from ISC parsing: ver=$_loaded_ver chan=$_loaded_chan"
	fi
fi

if ! _run_oc_mirror_with_retry "load" "$try_tot" "$base_cmd"; then
	exit 1
fi

# After successful load: update state.sh with the loaded version.
# state.sh is the authoritative record of what the mirror actually contains.
if [ "$_loaded_ver" ]; then
	replace-value-conf -q -n ocp_version -v "$_loaded_ver" -f "$regcreds_dir/state.sh"
	if [ "$_loaded_ver" != "$ocp_version" ]; then
		aba_info "Mirror state updated: ocp_version $ocp_version → $_loaded_ver"
	fi
fi
replace-value-conf -q -n last_action -v "load" -f "$regcreds_dir/state.sh"
replace-value-conf -q -n last_action_at -v "$(date '+%Y-%m-%d %H:%M:%S')" -f "$regcreds_dir/state.sh"

# Bundle phase complete: unlock ISC so future config changes trigger regeneration.
# touch .created makes it newer than ISC → reg-create-imageset-config.sh will regenerate.
# Skip if .isc-pinned exists — user hand-edited the ISC and wants it preserved permanently.
# Remove .bundle and .isc-pinned: this repo is now a normal disconnected tree.
if [ ! -f data/.isc-pinned ]; then
	touch data/.created
fi
rm -f ../.bundle data/.isc-pinned

echo
aba_info_ok "Images loaded successfully into the registry."
aba_info_ok "The files in mirror/data/ (mirror_*.tar, imageset-config*.yaml) are no longer"
aba_info_ok "needed and can be safely deleted to free disk space, or backed up before"
aba_info_ok "copying new upgrade files into mirror/data/."
echo
aba_info_ok "To install OpenShift, from aba's top-level directory run:"
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
