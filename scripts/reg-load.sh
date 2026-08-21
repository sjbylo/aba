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

# Transfer bundle path (used in both early-exit and normal flow)
_transfer_tar="data/aba-transfer.tar"

# --- Guard: archive files must be present ---
# Config-only transfers (aba-transfer-configs.tar without mirror_*.tar) are valid.
# Extract configs and exit gracefully if no images to load.
if ! ls data/mirror_*.tar >/dev/null 2>&1; then
	_has_configs=""
	[ -f "data/aba-transfer-configs.tar" ] && _has_configs=1
	[ -f "$_transfer_tar" ] && _has_configs=1

	if [ "$_has_configs" ]; then
		# Extract transfer tars (configs only, no images)
		if [ -f "data/aba-transfer-configs.tar" ]; then
			aba_info "Found config-only transfer: data/aba-transfer-configs.tar"
			if ! ( cd .. && tar xf "mirror/data/aba-transfer-configs.tar" ); then
				aba_abort "Failed to unpack aba-transfer-configs.tar. The file may be corrupt."
			fi
			aba_info "Config transfer extracted (cluster directories updated)."
		fi
		if [ -f "$_transfer_tar" ]; then
			aba_debug "Found transfer config: $_transfer_tar"
			rm -f data/aba-transfer-metadata.json \
				data/imageset-config.yaml \
				data/imageset-config-digest.yaml
			if ! ( cd .. && tar xf "mirror/$_transfer_tar" ); then
				aba_abort "Failed to unpack transfer config ($_transfer_tar)."
			fi
			aba_debug "Transfer config applied."
		fi
		aba_info "Config-only transfer: no images to load. Done."
		exit 0
	fi

	aba_abort "No mirror_*.tar archive files found in mirror/data/." \
		"Copy the archive files from the connected host first:" \
		"  cp <source>/mirror/data/*.tar mirror/data/"
fi

# Unpack transfer bundle if present (always contains ISC; for upgrades also
# includes CLI tarballs and metadata).  Created by 'aba save' so that
# 'cp mirror/data/*.tar' transfers the correct ISC to the disconnected host.
# Tar paths are relative to aba root (mirror/data/*, cli/*), so unpack from aba root.
_transfer_meta_ver=""
_transfer_meta_chan=""

# --- Guard: warn if transfer tar is missing (user may have copied only mirror_*.tar) ---
if [ ! -f "$_transfer_tar" ]; then
	aba_warn "No aba-transfer.tar found alongside mirror_*.tar archives." \
		"This file contains the matching config and metadata." \
		"Ensure you copied ALL *.tar files from mirror/data/." \
		"Continuing with existing local ISC."
fi

if [ -f "$_transfer_tar" ]; then
	aba_debug "Found transfer config: $_transfer_tar"

	# Drop leftovers from a prior load before unpack. Non-upgrade transfer tars
	# omit metadata (and sometimes the digest ISC); tar xf will not remove
	# pre-existing files, so a stale aba-transfer-metadata.json would be
	# validated against the newly unpacked digest ISC (false checksum mismatch).
	rm -f data/aba-transfer-metadata.json \
		data/imageset-config.yaml \
		data/imageset-config-digest.yaml

	# Unpack from aba root (CWD is mirror/, aba root is ..)
	if ! ( cd .. && tar xf "mirror/$_transfer_tar" ); then
		aba_abort "Failed to unpack transfer config ($_transfer_tar)." \
			"The file may be corrupt. Re-copy mirror/data/*.tar from the connected host."
	fi

	# Read and validate metadata if present (only created for upgrade saves)
	if [ -f "data/aba-transfer-metadata.json" ]; then
		_transfer_meta_ver=$(grep '"ocp_version"' data/aba-transfer-metadata.json | sed 's/.*: *"//; s/".*//')
		_transfer_meta_chan=$(grep '"ocp_channel"' data/aba-transfer-metadata.json | sed 's/.*: *"//; s/".*//')
		_expected_sha=$(grep '"digest_isc_sha256"' data/aba-transfer-metadata.json | sed 's/.*: *"//; s/".*//')

		aba_debug "Transfer config: OCP ${_transfer_meta_ver} (${_transfer_meta_chan})"

		# Verify digest ISC integrity if checksum is available
		if [ "$_expected_sha" ] && [ -f "data/imageset-config-digest.yaml" ]; then
			_actual_sha=$(sha256sum "data/imageset-config-digest.yaml" | awk '{print $1}')
			if [ "$_actual_sha" != "$_expected_sha" ]; then
				aba_abort "imageset-config-digest.yaml checksum mismatch." \
					"The digest ISC does not match the transfer config metadata." \
					"Re-copy mirror/data/*.tar from the connected host."
			fi
			aba_debug "Digest ISC checksum verified OK"
		fi
	fi

	aba_debug "Transfer config applied."
fi

# Extract configs transfer tar if present (cluster dirs for day-N updates).
# Only runs in the normal flow (mirror_*.tar exists); the early-exit path
# above already handles the config-only case.
if [ -f "data/aba-transfer-configs.tar" ]; then
	aba_info "Found config transfer: data/aba-transfer-configs.tar"
	if ! ( cd .. && tar xf "mirror/data/aba-transfer-configs.tar" ); then
		aba_abort "Failed to unpack aba-transfer-configs.tar. The file may be corrupt."
	fi
	aba_info "Config transfer extracted (cluster directories updated)."
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
elif probe_host --any "$reg_url/v2/" "Docker registry API"; then
	# 401 is expected on /v2/ without credentials (Docker, quay-ng, GCR all behave this way)
	aba_debug "Docker/OCI registry detected and accessible"
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
	aba_warn "No $regcreds_display/rootCA.pem cert file found (skipTLS=$skipTLS)" 
fi

[ ! "$data_dir" ] && data_dir=\~
reg_root=$data_dir/quay-install
aba_debug "data_dir=$data_dir reg_root=$reg_root"

if [ ! -d data ]; then
	aba_abort "No mirror/data/ directory — nothing to load." \
		"Load needs image archives (mirror_*.tar) under mirror/data/." \
		"On a connected host:  aba -d mirror save" \
		"Or copy archives in:  mkdir -p mirror/data && cp <media>/*.tar mirror/data/"

fi
aba_debug "data/ directory exists"

ensure_sigstore_mirror_config "$reg_host:$reg_port"

# Reassure the user: summarize what this load will apply (tag-based ISC).
# Reuse transfer-info.sh (same parser as TUI / aba transfer-info) — do not
# invent a second ISC parser. Prefer transfer tar content when present.
echo
if _ti_out=$(scripts/transfer-info.sh --shell 2>/dev/null); then
	eval "$_ti_out"
	_load_ver="${transfer_ocp_version:-}"
	if [ -n "${transfer_upgrade_to:-}" ] && [ "$transfer_upgrade_to" != "${transfer_ocp_version:-}" ]; then
		_load_ver="${transfer_ocp_version} → ${transfer_upgrade_to}"
	fi
	aba_info "About to load:"
	if [ -n "$_load_ver" ]; then
		aba_info "  OCP: ${_load_ver} (${transfer_ocp_channel:-unknown})"
	fi
	if [ "${transfer_operator_count:-0}" -gt 0 ] 2>/dev/null; then
		_ops_preview=$(echo "${transfer_operators:-}" | sed 's/,/, /g')
		if [ "${transfer_operator_count}" -gt 8 ]; then
			_ops_preview=$(echo "${transfer_operators:-}" | cut -d, -f1-8 | sed 's/,/, /g')
			_ops_preview="${_ops_preview}, ... (+$(( transfer_operator_count - 8 )) more)"
		fi
		aba_info "  Operators (${transfer_operator_count}): ${_ops_preview}"
	else
		aba_info "  Operators: none"
	fi
	aba_info "  Registry: ${reg_host}:${reg_port}${reg_path}"
	echo
fi

aba_info "Using oc-mirror version $(oc_mirror_version)"
aba_info "Now loading (disk2mirror) the images from mirror/data/ directory to registry $reg_host:$reg_port$reg_path."
echo

# Check if *aba installed Quay* (if so, show warning) or it's an existing reg. (no need to show warning)
if [ -s ./reg-uninstall.sh ]; then
	aba_warn \
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
if [ "$_transfer_meta_ver" ]; then
	_loaded_ver="$_transfer_meta_ver"
	_loaded_chan="$_transfer_meta_chan"
	aba_debug "Version from transfer bundle metadata: ver=$_loaded_ver chan=$_loaded_chan"
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
# mirror_ocp_version tracks the highest version in the mirror.
if [ "$_loaded_ver" ]; then
	replace-value-conf -q -n ocp_version -v "$_loaded_ver" -f "$regcreds_dir/state.sh"
	replace-value-conf -q -n mirror_ocp_version -v "$_loaded_ver" -f "$regcreds_dir/state.sh"
	if [ "$_loaded_ver" != "$ocp_version" ]; then
		replace-value-conf -q -n mirror_ocp_upgrade_from -v "$ocp_version" -f "$regcreds_dir/state.sh"
	else
		replace-value-conf -q -n mirror_ocp_upgrade_from -v "" -f "$regcreds_dir/state.sh"
	fi
fi
replace-value-conf -q -n last_action -v "load" -f "$regcreds_dir/state.sh"
replace-value-conf -q -n last_action_at -v "$(date '+%Y-%m-%d %H:%M:%S')" -f "$regcreds_dir/state.sh"

echo
_loaded_display="${_loaded_ver:-$ocp_version}"
if [ "$_loaded_ver" ] && [ "$_loaded_ver" != "$ocp_version" ]; then
	aba_success "Images loaded into $reg_host:$reg_port (upgrade: $ocp_version → $_loaded_ver)"
else
	aba_success "Images loaded into $reg_host:$reg_port (OCP $_loaded_display)"
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

# Offer to delete large archive files to free disk space
_archive_files=( data/mirror_*.tar )
if [ -e "${_archive_files[0]}" ]; then
	_archive_size=$(du -sh data/mirror_*.tar 2>/dev/null | tail -1 | awk '{print $1}')
	if ask -n --auto-no "Delete mirror_*.tar files (${_archive_size:-?} total) to free disk space"; then
		rm -f data/mirror_*.tar data/aba-transfer.tar data/aba-transfer-metadata.json
		aba_info "Archive and transfer files deleted."
	else
		aba_info "Archive files kept. Delete manually when no longer needed: rm mirror/data/mirror_*.tar"
	fi
fi
echo

if [ ! "${ABA_SUPPRESS_WARNINGS:-}" ]; then
	# Context-aware next steps: upgrade load shows day2 + upgrade; initial load shows cluster creation
	_is_upgrade=""
	[ "$_loaded_ver" ] && [ "$_loaded_ver" != "$ocp_version" ] && _is_upgrade=1

	if have_installed_clusters=$(echo ../*/.install-complete) && [ "$have_installed_clusters" != "../*/.install-complete" ]; then
		if [ "$_is_upgrade" ]; then
			aba_info "Next steps for upgrade ($ocp_version → $_loaded_ver):"
			aba_info "  1. aba -d <cluster> day2       (apply updated CatalogSources/IDMS)"
			aba_info "  2. aba -d <cluster> upgrade --to $_loaded_ver"
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
