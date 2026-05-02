#!/bin/bash -e
# Upgrade an OCP cluster to a target version using the local mirror registry.
# Resolves the release digest, auto-runs day2 if IDMS is missing, and triggers
# 'oc adm upgrade --to-image' for disconnected environments.

[ ! -f scripts/include_all.sh ] && echo "Error: Cluster directory $PWD not yet initialized! See: aba cluster --help" >&2 && exit 1
source scripts/include_all.sh

aba_debug "Starting: $0 $* from $PWD"

[ ! -f cluster.conf ] && aba_abort "$PWD/cluster.conf file missing! Cluster directory $PWD not yet initialized! See: aba cluster --help"

# Parse flags
target_ver=
opt_force=
opt_dry_run=
opt_monitor_timeout=120
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
		--monitor-timeout)
			[[ "$2" =~ ^- || -z "$2" ]] && aba_abort "missing argument after option $1"
			opt_monitor_timeout="$2"
			shift 2
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
! echo "$target_ver" | grep -q -E "^[0-9]+\.[0-9]+\.[0-9]+$" && \
	aba_abort "Invalid target version format: [$target_ver]. Expected x.y.z (e.g. 4.19.28)"

# Preflight: kubeconfig
export KUBECONFIG=$PWD/iso-agent-based/auth/kubeconfig
if [ ! -f "$KUBECONFIG" ]; then
	aba_abort "kubeconfig not found at $KUBECONFIG. Place your kubeconfig there first."
fi

# Preflight: cluster access
aba_info "Checking cluster access ..."
if ! oc whoami --request-timeout='20s' >/dev/null; then
	aba_abort "Cannot access the cluster. Check KUBECONFIG=$KUBECONFIG"
fi

# Preflight: get current version from live cluster
current_ver=$(oc get clusterversion version -o jsonpath='{.status.desired.version}') || current_ver=""
[ ! "$current_ver" ] && aba_abort "Cannot determine current cluster version"
aba_info "Current cluster version: $current_ver"
aba_info "Target cluster version:  $target_ver"

# Preflight: compare versions (simple string comparison — both are semver x.y.z)
if [ "$current_ver" = "$target_ver" ]; then
	aba_abort "Cluster is already at version $target_ver — nothing to upgrade"
fi

# Version comparison: check target > current using sort -V
higher=$(printf '%s\n%s' "$current_ver" "$target_ver" | sort -V | tail -1)
if [ "$higher" != "$target_ver" ]; then
	aba_abort "Target version $target_ver is not higher than current version $current_ver"
fi

# Construct mirror release image reference
# Release images are tagged with raw kernel arch (x86_64, aarch64, s390x, ppc64le) — not Go-style (amd64)
release_arch=$(uname -m)
mirror_image="$reg_host:$reg_port$reg_path/openshift/release-images:$target_ver-$release_arch"
aba_info "Mirror release image: $mirror_image"

# Preflight: verify image exists in mirror
aba_info "Verifying release image exists in mirror ..."
if ! skopeo inspect --tls-verify=false "docker://$mirror_image" >/dev/null; then
	aba_abort "Release image not found in mirror: $mirror_image\nRun 'aba -d mirror load' first to load the target version images."
fi

# Preflight: check IDMS
aba_info "Checking for ImageDigestMirrorSet ..."
idms_count=$(oc get imagedigestmirrorset --no-headers --ignore-not-found 2>&1 | wc -l)
if [ "$idms_count" -eq 0 ] && [ ! "$opt_skip_day2" ]; then
	aba_info "No IDMS found. Running 'aba day2' to configure mirror resources ..."
	scripts/day2.sh
elif [ "$idms_count" -eq 0 ] && [ "$opt_skip_day2" ]; then
	aba_warning "No IDMS found and --skip-day2 specified. Upgrade may fail without mirror configuration."
fi

# Get release digest from mirror
aba_info "Resolving release image digest ..."
release_info=$(oc adm release info "$mirror_image") || aba_abort "Failed to query release info for $mirror_image"
digest=$(echo "$release_info" | grep "^Digest:" | awk '{print $2}')
[ ! "$digest" ] && aba_abort "Failed to extract digest from release info for $mirror_image"
aba_info "Release digest: $digest"

# Construct the digest-based image reference
mirror_image_by_digest="$reg_host:$reg_port$reg_path/openshift/release-images@$digest"

# Dry-run: show plan and exit
if [ "$opt_dry_run" ]; then
	echo
	aba_info "=== DRY RUN ==="
	aba_info "Current version:  $current_ver"
	aba_info "Target version:   $target_ver"
	aba_info "Mirror image:     $mirror_image"
	aba_info "Digest:           $digest"
	aba_info "Command that would be executed:"
	aba_info "  oc adm upgrade --to-image=$mirror_image_by_digest --allow-explicit-upgrade $opt_force"
	echo
	exit 0
fi

# Execute upgrade
aba_info "Triggering cluster upgrade: $current_ver → $target_ver ..."
oc adm upgrade \
	--to-image="$mirror_image_by_digest" \
	--allow-explicit-upgrade \
	$opt_force

aba_info_ok "Upgrade command accepted by cluster"

# Monitor upgrade progress
aba_info "Monitoring upgrade progress (timeout: ${opt_monitor_timeout}m) ..."
aba_info "Press Ctrl-C to stop monitoring (upgrade continues in background)"
echo

end_time=$(( $(date +%s) + opt_monitor_timeout * 60 ))
while [ "$(date +%s)" -lt "$end_time" ]; do
	cv_version=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || echo "unknown")
	cv_available=$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "unknown")
	cv_progressing=$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null || echo "unknown")
	cv_message=$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Progressing")].message}' 2>/dev/null || echo "")

	if [ "$cv_version" = "$target_ver" ] && [ "$cv_available" = "True" ] && [ "$cv_progressing" = "False" ]; then
		echo
		aba_info_ok "Upgrade complete! Cluster is now at version $target_ver"
		aba_info "Run 'aba run --cmd \"oc get co\"' to verify all cluster operators are healthy."
		exit 0
	fi

	printf "\r[ABA] Upgrading: version=%s available=%s progressing=%s  " "$cv_version" "$cv_available" "$cv_progressing"
	[ "$cv_message" ] && aba_debug "Progress: $cv_message"
	sleep 60
done

echo
aba_warning "Monitoring timed out after ${opt_monitor_timeout} minutes."
aba_warning "The upgrade is still in progress. Check with: aba run --cmd 'oc get clusterversion'"
exit 1
