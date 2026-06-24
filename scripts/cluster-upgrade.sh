#!/bin/bash -e
# Upgrade an OCP cluster to a target version using the local mirror registry.
# Runs day2 (signatures, IDMS, catalogs), resolves the release digest, and
# triggers 'oc adm upgrade --to-image' for disconnected environments.

[ ! -f scripts/include_all.sh ] && echo "Error: Cluster directory $PWD not yet initialized! See: aba cluster --help" >&2 && exit 1
source scripts/include_all.sh

aba_debug "Starting: $0 $* from $PWD"

aba_warning "'aba upgrade' is in BETA and may change in future releases."

[ ! -f cluster.conf ] && aba_abort "$PWD/cluster.conf file missing! Cluster directory $PWD not yet initialized! See: aba cluster --help"

# Parse flags
target_ver=
opt_force=
opt_dry_run=
opt_skip_day2=

while [ $# -gt 0 ]; do
	case "$1" in
		--to)
			[[ "$2" =~ ^- || -z "$2" ]] && aba_abort "missing argument after option $1"
			target_ver="$2"
			shift 2
			;;
		--force)
			opt_force="--force"
			shift
			;;
		--dry-run)
			opt_dry_run=1
			shift
			;;
		--skip-day2)
			opt_skip_day2=1
			shift
			;;
		*)
			aba_abort "Unknown option: $1. See: aba -d <cluster> upgrade --help"
			;;
	esac
done

source <(normalize-aba-conf)
source <(normalize-cluster-conf)
export regcreds_dir=$HOME/.aba/mirror/$mirror_name
source <(normalize-mirror-conf)

# Ensure container auth is configured (skopeo needs mirror creds in ~/.docker/config.json)
scripts/create-containers-auth.sh --load >/dev/null

# Preflight: kubeconfig (prefer externalized state, fall back to local)
KUBECONFIG=$(cluster_kubeconfig)
if [ -z "$KUBECONFIG" ]; then
	aba_abort "kubeconfig not found. Expected at ~/.aba/clusters/$cluster_name.$base_domain/kubeconfig or iso-agent-based/auth/kubeconfig"
fi
export KUBECONFIG

# Preflight: cluster access
aba_info "Checking cluster access ..."
aba_debug "Running: oc whoami --request-timeout='20s'"
if ! oc whoami --request-timeout='20s' >/dev/null; then
	aba_abort "Cannot access the cluster. Check KUBECONFIG=$KUBECONFIG"
fi

# Preflight: get current COMPLETED version from live cluster
# Use history[Completed] not desired.version — desired flips immediately when an upgrade is requested
aba_debug "Running: oc get clusterversion version (completed history)"
current_ver=$(oc get clusterversion version \
	-o jsonpath='{.status.history[?(@.state=="Completed")].version}' 2>/dev/null \
	| awk '{print $1}') || current_ver=""
[ ! "$current_ver" ] && aba_abort "Cannot determine current cluster version (no completed version in history)"
aba_info "Current cluster version: $current_ver"

# Query available versions from mirror.
# Tags follow the pattern: <version>-<arch> (e.g. 4.21.12-x86_64)
_list_mirror_versions() {
	local repo="$reg_host:$reg_port$reg_path/openshift/release-images"
	local arch
	arch=$(uname -m)
	skopeo list-tags "docker://$repo" 2>/dev/null \
		| grep -oP '"(\d+\.\d+\.\d+(?:-[a-z]+\.\d+)?)-'"$arch"'"' \
		| tr -d '"' | sed "s/-${arch}$//" | sort -V
}

# Version-discovery mode: --dry-run without --to just lists what's available
if [ "$opt_dry_run" ] && [ ! "$target_ver" ]; then
	osus_upstream=$(oc get clusterversion version -o jsonpath='{.spec.upstream}' 2>/dev/null) || true
	echo
	aba_info "=== DRY RUN ==="
	aba_info "Current version:  $current_ver"
	[ "$osus_upstream" ] && aba_info "Update graph:     $osus_upstream"
	echo
	aba_info "Versions in mirror (higher than $current_ver):"
	_avail_found=
	while IFS= read -r v; do
		[ -z "$v" ] && continue
		higher_v=$(printf '%s\n%s' "$current_ver" "$v" | sort -V | tail -1)
		if [ "$higher_v" = "$v" ] && [ "$v" != "$current_ver" ]; then
			aba_info "  $v"
			_avail_found=1
		fi
	done < <(_list_mirror_versions)
	[ ! "$_avail_found" ] && aba_info "  (none — run 'aba -d mirror sync' or 'aba -d mirror load' first)"
	echo
	exit 0
fi

# Resolve target version: --to flag > mirror.conf:ocp_version_target > error
if [ ! "$target_ver" ]; then
	if [ "$ocp_version_target" ]; then
		target_ver="$ocp_version_target"
		aba_info "Using target version from mirror.conf: $target_ver"
	else
		aba_abort "No target version specified. Use: aba -d <cluster> upgrade --to <version>"
	fi
fi

# Validate target version format
! echo "$target_ver" | grep -q -E "^[0-9]+\.[0-9]+\.[0-9]+(-[a-z]+\.[0-9]+)?$" && \
	aba_abort "Invalid target version format: [$target_ver]. Expected x.y.z or x.y.z-suffix.N (e.g. 4.19.28, 4.22.0-rc.1)"

aba_info "Target cluster version:  $target_ver"

# Idempotency: if already at target version, succeed silently (check BEFORE health)
if [ "$current_ver" = "$target_ver" ] && [ ! "$opt_dry_run" ]; then
	aba_info_ok "Cluster is already at version $target_ver — nothing to do."
	exit 0
fi

# Preflight: cluster accessibility — only needs API reachable (Available=True).
# A cluster with Progressing operators or a Degraded operator can still accept upgrades.
if ! cluster_is_accessible; then
	aba_warning \
		"The cluster API is not reachable (ClusterVersion Available != True)." \
		"To investigate: oc get clusterversion"
	ask "Continue with upgrade anyway" || exit 1
fi

# Idempotency: if an upgrade to the same target is already in progress, fall through to monitoring
upgrade_already_running=
cv_progressing=$(oc get clusterversion version \
	-o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null) || true
if [ "$cv_progressing" = "True" ]; then
	cv_message=$(oc get clusterversion version \
		-o jsonpath='{.status.conditions[?(@.type=="Progressing")].message}' 2>/dev/null) || true
	cv_desired=$(oc get clusterversion version \
		-o jsonpath='{.status.desired.version}' 2>/dev/null) || true
	if [ "$cv_desired" = "$target_ver" ] && [ ! "$opt_dry_run" ]; then
		aba_info_ok "Upgrade to $target_ver is already in progress."
		upgrade_already_running=1
	elif [ "$cv_desired" != "$target_ver" ] && [ ! "$opt_dry_run" ]; then
		aba_abort \
			"An upgrade is already in progress (to $cv_desired): $cv_message" \
			"Wait for the current upgrade to complete before starting a new one." \
			"Check with: oc adm upgrade status"
	fi
fi

# Version comparison: check target > current using sort -V (skip in dry-run to show available list)
if [ ! "$opt_dry_run" ]; then
	higher=$(printf '%s\n%s' "$current_ver" "$target_ver" | sort -V | tail -1)
	if [ "$higher" != "$target_ver" ]; then
		aba_abort "Target version $target_ver is not higher than current version $current_ver"
	fi
fi

# Construct mirror release image reference
# Release images are tagged with raw kernel arch (x86_64, aarch64, s390x, ppc64le) — not Go-style (amd64)
release_arch=$(uname -m)
mirror_image="$reg_host:$reg_port$reg_path/openshift/release-images:$target_ver-$release_arch"
aba_info "Mirror release image: $mirror_image"

# Check if OSUS is configured (local update graph available).
osus_upstream=$(oc get clusterversion version -o jsonpath='{.spec.upstream}' 2>/dev/null) || true

# Preflight: verify image exists in mirror
aba_info "Verifying release image exists in mirror ..."
aba_debug "Running: skopeo inspect docker://$mirror_image"
target_in_mirror=1
if ! skopeo inspect "docker://$mirror_image" >/dev/null 2>&1; then
	target_in_mirror=
	if [ ! "$opt_dry_run" ]; then
		aba_abort "Release image not found in mirror: $mirror_image\nRun 'aba -d mirror sync' or 'aba -d mirror load' first to sync/load the target version images."
	fi
fi

# Dry-run with specific target: show plan and exit
if [ "$opt_dry_run" ]; then
	echo
	aba_info "=== DRY RUN ==="
	aba_info "Current version:  $current_ver"
	aba_info "Target version:   $target_ver"
	if [ "$target_in_mirror" ]; then
		aba_info "Mirror image:     $mirror_image"
	else
		aba_warning "Target $target_ver NOT FOUND in mirror"
	fi
	[ "$osus_upstream" ] && aba_info "Update graph:     $osus_upstream"

	echo
	aba_info "Versions in mirror (higher than $current_ver):"
	_avail_found=
	while IFS= read -r v; do
		[ -z "$v" ] && continue
		higher_v=$(printf '%s\n%s' "$current_ver" "$v" | sort -V | tail -1)
		if [ "$higher_v" = "$v" ] && [ "$v" != "$current_ver" ]; then
			marker=""
			[ "$v" = "$target_ver" ] && marker=" ← target"
			aba_info "  $v$marker"
			_avail_found=1
		fi
	done < <(_list_mirror_versions)
	[ ! "$_avail_found" ] && aba_info "  (none — run 'aba -d mirror sync' to mirror a newer version)"

	echo
	exit 0
fi

# When upgrade is already running, skip straight to monitoring
if [ ! "$upgrade_already_running" ]; then
	# Run day2 to ensure IDMS, signatures, and catalog sources are current.
	if [ ! "$opt_skip_day2" ]; then
		aba_info "Running 'aba day2' to apply mirror resources, signatures, and catalog sources ..."
		scripts/day2.sh
	else
		aba_warning "--skip-day2 specified. Skipping day2 configuration — upgrade may fail without signatures or mirror configuration."
	fi

	# Get release digest from mirror
	aba_info "Resolving release image digest ..."
	aba_debug "Running: oc adm release info $mirror_image"
	release_info=$(oc adm release info "$mirror_image") || aba_abort "Failed to query release info for $mirror_image"
	digest=$(echo "$release_info" | grep "^Digest:" | awk '{print $2}')
	[ ! "$digest" ] && aba_abort "Failed to extract digest from release info for $mirror_image"
	aba_info "Release digest: $digest"

	# Construct the digest-based image reference
	mirror_image_by_digest="$reg_host:$reg_port$reg_path/openshift/release-images@$digest"

	# When OSUS is active, use --to <version> which lets the CVO validate
	# the upgrade path via the local graph.  No --allow-explicit-upgrade needed.
	# Fall back to --to-image if the OSUS graph is unreachable (503, timeout).
	_image_cmd="oc adm upgrade --to-image=$mirror_image_by_digest --allow-explicit-upgrade $opt_force"

	if [ "$osus_upstream" ]; then
		aba_info "Local update graph detected: $osus_upstream"
		upgrade_cmd="oc adm upgrade --to $target_ver $opt_force"
	else
		upgrade_cmd="$_image_cmd"
	fi

	# Pre-flight: check for upgrade blockers that require manual admin action.
	# The output of 'oc adm upgrade' contains gate-specific instructions and links
	# that the user must follow — ABA cannot auto-apply these (the patch varies per gate).
	_adm_upgrade_out=$(oc adm upgrade 2>&1) || true
	if echo "$_adm_upgrade_out" | grep -q "Upgradeable=False"; then
		echo
		aba_warning "The cluster reports Upgradeable=False." \
			"This may require an admin acknowledgment before upgrading." \
			"Review the output below and follow any instructions or links:"
		echo
		echo "$_adm_upgrade_out"
		echo
		ask "Continue with upgrade (only if you have resolved the above)" || exit 1
	fi

	# Ensure the cluster's update channel matches the target version's major.minor.
	# Only same-channel upgrades are supported (e.g. stable-4.20 → stable-4.21).
	# The channel prefix is read from the live cluster — never from config files.
	_current_channel=$(oc get clusterversion version -o jsonpath='{.spec.channel}' 2>/dev/null) || _current_channel=""
	_target_major=$(_ver_minor "$target_ver")
	if [ -n "$_current_channel" ]; then
		_channel_prefix="${_current_channel%-*}"
	else
		_channel_prefix="${ocp_channel:-stable}"
		aba_warning "No update channel set on cluster — using '$_channel_prefix' from aba.conf"
	fi
	_required_channel="${_channel_prefix}-${_target_major}"
	_channel_changed=""
	if [ "$_current_channel" != "$_required_channel" ]; then
		aba_info "Setting upgrade channel: ${_current_channel:-<unset>} → $_required_channel"
		aba_debug "Running: oc adm upgrade channel $_required_channel"
		oc adm upgrade channel "$_required_channel"
		_channel_changed=1
	fi

	# When OSUS is active and the channel just changed, wait for the CVO to
	# refresh available updates from the new channel's graph before proceeding.
	if [ "$_channel_changed" ] && [ "$osus_upstream" ]; then
		aba_info "Waiting for update graph to refresh after channel change ..."
		_graph_ok=""
		for _try in $(seq 1 12); do
			if oc adm upgrade 2>&1 | grep -q "$target_ver"; then
				_graph_ok=1
				break
			fi
			sleep 5
		done
		if [ -z "$_graph_ok" ]; then
			aba_warning "Target $target_ver not yet visible in update graph after 60s — proceeding anyway (will fall back to --to-image if needed)"
		fi
	fi

	# Execute upgrade
	aba_info "Triggering cluster upgrade: $current_ver → $target_ver ..."
	aba_debug "Running: $upgrade_cmd"
	_upgrade_out=$($upgrade_cmd 2>&1) && _upgrade_rc=0 || _upgrade_rc=$?
	echo "$_upgrade_out"
	if [ $_upgrade_rc -ne 0 ] && echo "$_upgrade_out" | grep -q "cannot refresh available updates"; then
		aba_warning "OSUS update graph unavailable — falling back to --to-image with digest"
		aba_debug "Running: $_image_cmd"
		$_image_cmd
	elif [ $_upgrade_rc -ne 0 ]; then
		aba_abort "Upgrade command failed (exit=$_upgrade_rc): $upgrade_cmd"
	fi

	aba_info_ok "Upgrade command accepted by cluster"
fi

# Wait for the upgrade to actually start (Progressing=True).
# The cluster may take a while before it begins (e.g. signature
# verification, scheduling); give it up to 5 minutes.
_upgrade_progressing() {
	local p
	p=$(oc get clusterversion version \
		-o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null) || return 1
	aba_debug "Upgrade start check: Progressing=$p"
	[ "$p" = "True" ]
}

_wait_rc=0
aba_wait_show "Waiting for upgrade to begin (Ctrl-C to skip)" 10 300 _upgrade_progressing || _wait_rc=$?
if [ "$_wait_rc" -eq 130 ] || [ "$_wait_rc" -eq 143 ]; then
	aba_info "Monitoring skipped. The upgrade continues in background."
	aba_info "Check with: aba -d $(basename "$PWD") run --cmd 'oc adm upgrade status'"
	exit 0
fi

if [ "$_wait_rc" -ne 0 ]; then
	aba_warning "Upgrade has not started progressing after 5 minutes."
	echo
	_stall_out=$(oc adm upgrade 2>&1) || true
	echo "$_stall_out"
	echo
	if echo "$_stall_out" | grep -q "ReleaseAccepted=False\|AdminAckRequired"; then
		aba_info "The cluster may require an admin acknowledgment before upgrading."
		aba_info "Review the messages above and the referenced documentation link."
		aba_info "If needed, --force can bypass precondition checks (use with caution)."
	fi
	aba_info "Check with: aba -d $(basename "$PWD") run --cmd 'oc adm upgrade'"
	exit 1
fi

# Wait for meaningful progress (operators actually updating) or
# completion, whichever comes first.  Up to 10 minutes.
_upgrade_status_ready() {
	local ver avail prog
	ver=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null) || return 1
	avail=$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null) || return 1
	prog=$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null) || return 1
	if [ "$ver" = "$target_ver" ] && [ "$avail" = "True" ] && [ "$prog" = "False" ]; then
		return 0
	fi
	# Wait until at least some operators have updated (not "0 operators updated")
	! oc adm upgrade status 2>/dev/null | grep -q "0 operators updated"
}

_wait_rc=0
aba_wait_show "Upgrading $current_ver → $target_ver (Ctrl-C to skip)" 15 600 _upgrade_status_ready || _wait_rc=$?

# Check if the upgrade finished during the wait
cv_prog=$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null) || true
cv_ver=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null) || true

echo
if [ "$cv_ver" = "$target_ver" ] && [ "$cv_prog" = "False" ]; then
	aba_info_ok "Upgrade complete! Cluster is now at version $target_ver"
	oc adm upgrade status 2>/dev/null || oc get clusterversion 2>/dev/null
	exit 0
fi

aba_info_ok "Upgrade $current_ver → $target_ver is in progress!"
echo
oc adm upgrade status 2>/dev/null || oc get clusterversion 2>/dev/null
echo
aba_info "To monitor the upgrade, run:"
aba_info "  oc adm upgrade status"
aba_info "  oc get clusterversion"

exit 0
