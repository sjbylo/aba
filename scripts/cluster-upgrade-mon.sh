#!/bin/bash
# =============================================================================
# INTENT:      Monitor an in-progress OpenShift upgrade until completion.
#              Polls cluster version and operator status, shows live progress,
#              and prints post-upgrade next steps on completion.
# CALLED BY:   aba.sh (upgrade-mon command, or upgrade --wait flag)
# CWD:         Cluster directory (e.g. ~/aba/sno/)
# REQUIRES:    include_all.sh, oc (with valid kubeconfig)
# SIDE EFFECTS: None (read-only monitoring). Ctrl-C exits cleanly without
#              affecting the upgrade — it continues in the background.
# =============================================================================

[ ! -f scripts/include_all.sh ] && echo "Error: Cluster directory $PWD not yet initialized! See: aba cluster --help" >&2 && exit 1
source scripts/include_all.sh

aba_debug "Starting: $0 $* from $PWD"

[ ! -f cluster.conf ] && aba_abort "$PWD/cluster.conf file missing! Cluster directory $PWD not yet initialized! See: aba cluster --help"

# Parse optional --to <version> to know what we're waiting for.
# If not provided, read the desired version from the cluster itself.
_target_ver=""
while [ "${1:-}" ]; do
	case "$1" in
		--to) _target_ver="$2"; shift 2 ;;
		*) shift ;;
	esac
done

source <(normalize-aba-conf)
source <(normalize-cluster-conf)

ensure_oc

# Kubeconfig: prefer externalized state, fall back to local
KUBECONFIG=$(cluster_kubeconfig)
if [ -z "$KUBECONFIG" ]; then
	aba_abort "kubeconfig not found. Expected at ~/.aba/clusters/$cluster_name.$base_domain/kubeconfig or iso-agent-based/auth/kubeconfig"
fi
export KUBECONFIG

aba_info "Checking cluster access ..." >&2
cluster_api_reachable "$KUBECONFIG" || aba_abort "Cluster API is not reachable. Is the cluster running?"
if ! oc whoami --request-timeout='20s' >/dev/null; then
	aba_abort "Cannot access the cluster. Check KUBECONFIG=$KUBECONFIG"
fi

# Determine target version: from --to flag, or from the cluster's desired version
if [ -z "$_target_ver" ]; then
	_target_ver=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null) || true
fi

if [ -z "$_target_ver" ]; then
	aba_abort "Cannot determine upgrade target version." \
		"Specify it with: aba upgrade-mon --to <version>"
fi

_current_ver=$(oc get clusterversion version -o jsonpath='{.status.history[0].version}' 2>/dev/null) || _current_ver="unknown"

# Check if already at target (no upgrade in progress)
_cv_init=$(oc get clusterversion version -o json 2>/dev/null) || true
_cv_ver=$(echo "$_cv_init" | jq -r '.status.desired.version // empty' 2>/dev/null)
_cv_prog=$(echo "$_cv_init" | jq -r '.status.conditions[] | select(.type=="Progressing") | .status // empty' 2>/dev/null)

if [ "$_cv_ver" = "$_target_ver" ] && [ "$_cv_prog" = "False" ]; then
	aba_success "Cluster is already at version $_target_ver (no upgrade in progress)"
	echo
	aba_info "If CatalogSources need updating, run: aba -d $(basename "$PWD") day2"
	exit 0
fi

# --- Monitoring loop --------------------------------------------------------
#
# Polls every 30s. Shows a compact status line with:
#   - Elapsed time
#   - Current cluster version state (progressing / available)
#   - Operator progress (X of Y updated)
# Ctrl-C exits the monitor — the upgrade continues in the background.

_interval=30
_start_ts=$(date +%s)

# Trap Ctrl-C for a clean exit message
trap '_on_interrupt' INT
_on_interrupt() {
	echo
	echo
	aba_info "Monitor interrupted — the upgrade continues in the background."
	aba_info "Resume monitoring:  aba -d $(basename "$PWD") upgrade-mon"
	aba_info "Check status:       oc adm upgrade status"
	exit 0
}

echo
aba_info "Monitoring upgrade → $_target_ver (Ctrl-C to detach)"
aba_info "Polling every ${_interval}s ..."
echo

while true; do
	_elapsed=$(( $(date +%s) - _start_ts ))
	_elapsed_fmt=$(_aba_format_elapsed "$_elapsed")

	# Read cluster version state in a single API call
	_cv_json=$(oc get clusterversion version -o json 2>/dev/null) || _cv_json=""
	if [ "$_cv_json" ]; then
		_cv_ver=$(echo "$_cv_json" | jq -r '.status.desired.version // empty')
		_cv_prog=$(echo "$_cv_json" | jq -r '.status.conditions[] | select(.type=="Progressing") | .status // empty')
		_cv_avail=$(echo "$_cv_json" | jq -r '.status.conditions[] | select(.type=="Available") | .status // empty')
		_cv_deg=$(echo "$_cv_json" | jq -r '.status.conditions[] | select(.type=="Degraded") | .status // empty')
	else
		_cv_ver="" _cv_prog="" _cv_avail="" _cv_deg=""
	fi

	# Count operator progress in a single API call
	_co_json=$(oc get co -o json 2>/dev/null) || _co_json=""
	_co_total=0 _co_updated=0 _co_progressing=0 _co_degraded=0
	if [ "$_co_json" ]; then
		while IFS=' ' read -r _a _p _d; do
			[ -z "$_a" ] && continue
			_co_total=$(( _co_total + 1 ))
			[ "$_a" = "True" ] && [ "$_p" = "False" ] && _co_updated=$(( _co_updated + 1 ))
			[ "$_p" = "True" ] && _co_progressing=$(( _co_progressing + 1 ))
			[ "$_d" = "True" ] && _co_degraded=$(( _co_degraded + 1 ))
		done < <(echo "$_co_json" | jq -r '.items[] | "\(.status.conditions[] | select(.type=="Available") | .status) \(.status.conditions[] | select(.type=="Progressing") | .status) \(.status.conditions[] | select(.type=="Degraded") | .status)"' 2>/dev/null)
	fi

	# Build status line
	_status="[${_elapsed_fmt}] Operators: ${_co_updated}/${_co_total} updated"
	[ "$_co_progressing" -gt 0 ] && _status="$_status, ${_co_progressing} progressing"
	[ "$_co_degraded" -gt 0 ] && _status="$_status, ${_co_degraded} degraded"

	# Check for completion
	if [ "$_cv_ver" = "$_target_ver" ] && [ "$_cv_avail" = "True" ] && [ "$_cv_prog" = "False" ]; then
		echo "$_status"
		echo
		aba_success "Upgrade complete! Cluster is now at version $_target_ver (${_elapsed_fmt})"
		echo
		oc adm upgrade status 2>/dev/null || oc get clusterversion 2>/dev/null
		echo
		aba_info "Next step: run 'aba -d $(basename "$PWD") day2' to update CatalogSources for v$(_ver_minor "$_target_ver")"
		exit 0
	fi

	# Show status line
	echo "$_status"

	# Warn on degraded operators (informational — upgrades can recover)
	if [ "$_co_degraded" -gt 0 ]; then
		aba_debug "Degraded operators detected (may recover during upgrade)"
	fi

	sleep "$_interval"
done
