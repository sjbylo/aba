#!/bin/bash
# Test: TUI cluster upgrade — reuses the already-installed cluster
# Resolves a valid upgrade target from the OCP release graph, syncs upgrade
# images via TUI, runs day2 via TUI, then upgrades via TUI.
#
# DESTRUCTIVE: modifies mirror.conf (ocp_upgrade_to), re-syncs mirror,
# runs day2, and upgrades the cluster to a newer version.
#
# Prereqs: installed cluster (from test-tui-cluster.sh), synced mirror.

cd "$(dirname "$0")/../.."
source test/func/tui-test-lib.sh

_CLUSTER="${TUI_CLUSTER_NAME:-sno}"

echo "=== TUI Upgrade Workflow Test ==="
echo "  Host: $_TUI_HOST"
echo "  Cluster: $_CLUSTER"
echo ""

tui_deploy_code
tui_pre_cleanup
echo ""

# ============================================================================
# 0. Verify cluster is installed and get current version
# ============================================================================
echo "--- 0. Verify cluster and resolve upgrade target ---"

_inst=$($_TUI_SSH "test -f ~/aba/$_CLUSTER/.install-complete && echo yes || echo no")
if [[ "$_inst" != "yes" ]]; then
	echo "  ✗ FAIL: Cluster '$_CLUSTER' not installed — cannot run upgrade test"
	_TUI_FAIL=1; tui_summary; exit 1
fi

_current_ver=$($_TUI_SSH "
	export KUBECONFIG=~/aba/$_CLUSTER/iso-agent-based/auth/kubeconfig
	oc get clusterversion version -o jsonpath='{.status.history[?(@.state==\"Completed\")].version}' 2>/dev/null | awk '{print \$1}'
" 2>/dev/null || true)

if [[ -z "$_current_ver" ]]; then
	echo "  ✗ FAIL: Cannot get cluster version — cluster may not be reachable"
	_TUI_FAIL=1; tui_summary; exit 1
fi
echo "  Cluster running: $_current_ver"
echo "  ✓ PASS: Cluster is installed and reachable"
_TUI_PASS=$(( _TUI_PASS + 1 ))

# ============================================================================
# 1. Resolve upgrade target from the OCP release graph
# ============================================================================
echo ""
echo "--- 1. Resolve upgrade target ---"

_target_ver=""

# Query the OCP channel for versions that $_current_ver can upgrade to
echo "  Querying OCP release channel for upgrade targets..."
_target_ver=$($_TUI_SSH "
	cd ~/aba && source scripts/include_all.sh && . aba.conf
	_channel=\${ocp_channel:-stable}
	fetch_upgrade_targets '$_current_ver' \"\$_channel\" 2>/dev/null \
		| awk '{print \$2}' | sort -rV | head -1
" 2>/dev/null || true)

if [[ -n "$_target_ver" ]]; then
	echo "  Upgrade target from channel: $_target_ver"
else
	# Fallback: try the next z-stream
	echo "  No target from upgrade graph — trying next z-stream..."
	_major_minor=$(echo "$_current_ver" | cut -d. -f1,2)
	_patch=$(echo "$_current_ver" | cut -d. -f3)
	_next_patch=$(( _patch + 1 ))
	_candidate="${_major_minor}.${_next_patch}"
	_exists=$($_TUI_SSH "
		cd ~/aba && source scripts/include_all.sh && . aba.conf
		_channel=\${ocp_channel:-stable}
		fetch_all_versions \"\$_channel\" '$_major_minor' 2>/dev/null \
			| grep -qF '$_candidate' && echo yes || echo no
	" 2>/dev/null || echo "no")
	if [[ "$_exists" == "yes" ]]; then
		_target_ver="$_candidate"
		echo "  Next z-stream exists in channel: $_target_ver"
	fi
fi

if [[ -z "$_target_ver" ]]; then
	echo "  ✗ FAIL: Cannot resolve any upgrade target for $_current_ver"
	echo "  The cluster is at the absolute latest in its channel."
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	tui_summary; exit 1
fi

echo "  Upgrade plan: $_current_ver → $_target_ver"
echo "  ✓ PASS: Valid upgrade target resolved"
_TUI_PASS=$(( _TUI_PASS + 1 ))

# ============================================================================
# 2. Set upgrade target and sync upgrade images via TUI
# ============================================================================
echo ""
echo "--- 2. Sync upgrade images ($_target_ver) ---"

# Set ocp_upgrade_to and force-regenerate imageset-config so sync includes the target
$_TUI_SSH "cd ~/aba && aba -d mirror --upgrade-to $_target_ver && aba --force -d mirror imagesetconf" 2>&1 | tail -5
_upgrade_to=$($_TUI_SSH "grep '^ocp_upgrade_to=' ~/aba/mirror/mirror.conf | cut -d= -f2 | awk '{print \$1}'" 2>/dev/null)
if [[ "$_upgrade_to" == "$_target_ver" ]]; then
	echo "  ✓ PASS: ocp_upgrade_to=$_target_ver set in mirror.conf"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: Failed to set ocp_upgrade_to (got: $_upgrade_to)"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

# Sync upgrade images via TUI: Mirror Payload → Prepare Upgrade
tui_start_to_menu || { tui_summary; exit 1; }

_nav_prepare_upgrade() {
	tui_back_to "Actions" 5
	tui_select_item "Mirror Payload\|Payload"
	sleep 1
	tui_select_item "Prepare Upgrade\|Upgrade"
	sleep 1
	tui_wait_isc_done 180

	# Multiple dialogs may appear — handle each one
	local _s _i
	for _i in 1 2 3 4 5; do
		sleep 2
		_s=$(tui_capture)
		tui_screenshot "upg-02-nav-step${_i}"

		# Version picker: select target version then press Next
		if echo "$_s" | grep -qi "$_target_ver.*Manual\|Manual.*entry\|Change base\|Change channel"; then
			tui_select_item "$_target_ver" 2>/dev/null || tui_keys Enter
			sleep 1
			tui_press_button "Next" 2>/dev/null || tui_keys Enter
			sleep 2
			continue
		fi

		# "How to mirror" dialog: select "Sync to registry" (option 1)
		if echo "$_s" | grep -qi "Sync to registry\|Save to tar\|Set target only\|How.*mirror"; then
			tui_keys Enter
			sleep 2
			continue
		fi

		# Sync confirmation: press Continue
		if echo "$_s" | grep -qi "Continue.*sync\|Continue.*OCP\|DISK SPACE"; then
			tui_press_button "Continue" 2>/dev/null || tui_keys Enter
			sleep 3
			continue
		fi

		# Already running or at progress dialog — done navigating
		if echo "$_s" | grep -qi "Executing\|Syncing\|Progress\|steps"; then
			break
		fi

		# Generic confirmation
		if echo "$_s" | grep -qi "Continue\|Proceed\|Yes"; then
			tui_keys Enter
			sleep 2
			continue
		fi
	done
}

if tui_run_operation "upg-sync" _nav_prepare_upgrade 2 2700; then
	echo "  ✓ PASS: Upgrade images synced"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
	tui_dismiss_result
else
	echo "  ✗ FAIL: Upgrade image sync failed"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	tui_cleanup; tui_summary; exit 1
fi

# ============================================================================
# 3. Day-2 configuration (OSUS + IDMS) via TUI
# ============================================================================
echo ""
echo "--- 3. Day-2 configuration via TUI ---"

_nav_to_day2_menu() {
	if ! tui_session_alive; then
		tui_start_to_menu || return 1
	fi
	tui_back_to "Actions" 5
	tui_select_item "Day-2"
	# Wait until we see the Day-2 menu items (not a stale dialog)
	local _w
	for _w in 1 2 3 4 5; do
		sleep 2
		_scr=$(tui_capture)
		# Day-2 menu has these section headers
		if echo "$_scr" | grep -q "── Configuration ──\|── Status ──\|── Lifecycle ──\|── Cleanup ──"; then
			return 0
		fi
		# Dismiss any stale result/progress dialogs
		if echo "$_scr" | grep -qi "Quit.*Q\|Q.*ESC"; then
			tui_keys q; sleep 1; continue
		fi
		if echo "$_scr" | grep -qi "Press.*ENTER\|ENTER to return\|── Success ──\|── FAILED ──"; then
			tui_keys Enter; sleep 1; continue
		fi
	done
	# Last resort: try again
	tui_back_to "Actions" 3
	tui_select_item "Day-2"
	sleep 2
	return 0
}

# --- 3a. OperatorHub (IDMS/ITMS) ---
echo "  --- 3a. OperatorHub config ---"
_nav_to_day2_menu

tui_select_item "OperatorHub\|Configure.*OperatorHub\|Registry"
sleep 3
tui_screenshot "upg-03-day2-opshub"

_scr=$(tui_capture)
if echo "$_scr" | grep -qi "select.*cluster"; then
	tui_keys Enter; sleep 3
fi
_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Choose execution mode\|Run in Terminal\|Run in TUI"; then
	tui_keys Enter; sleep 2
fi

if tui_wait_for_progress "upg-day2" 600; then
	echo "  ✓ PASS: Day-2 OperatorHub config completed via TUI"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: Day-2 OperatorHub config failed"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi
tui_dismiss_result

# --- 3b. OSUS ---
echo "  --- 3b. OSUS config ---"

# Check if OSUS is already running on the cluster
_osus_running=$($_TUI_SSH "
	export KUBECONFIG=~/aba/$_CLUSTER/iso-agent-based/auth/kubeconfig
	oc get pods -n openshift-update-service --no-headers 2>/dev/null | grep -c Running 2>/dev/null || echo 0
" 2>/dev/null | tail -1 || echo 0)
_osus_running=${_osus_running//[^0-9]/}
: "${_osus_running:=0}"

if [[ "$_osus_running" -gt 0 ]]; then
	echo "  OSUS already running ($_osus_running pod(s)) — skipping configuration"
	echo "  ✓ PASS: OSUS is active"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	# Check if operator catalogs are mirrored (OSUS requires redhat-operators)
	_has_catalogs=$($_TUI_SSH "
		ls ~/aba/mirror/data/oc-mirror-workspace/results-*/catalogSource-*.yaml 2>/dev/null | grep -c . || echo 0
	" 2>/dev/null | tail -1 || echo 0)
	_has_catalogs=${_has_catalogs//[^0-9]/}
	: "${_has_catalogs:=0}"

	if [[ "$_has_catalogs" -eq 0 ]]; then
		echo "  No operator catalogs mirrored — OSUS cannot be installed (requires redhat-operators)"
		echo "  Skipping OSUS (upgrade will work without it using mirrored versions)"
	else
		echo "  OSUS not running — configuring via TUI..."
		_nav_to_day2_menu
		tui_screenshot "upg-03-day2-menu-for-osus"

		_scr=$(tui_capture)
		if echo "$_scr" | grep -qi "OSUS\|Update Service"; then
			tui_select_item "OSUS\|Update Service"
			sleep 3
			tui_screenshot "upg-03-osus-after-select"

			_scr=$(tui_capture)
			if echo "$_scr" | grep -qi "select.*cluster"; then
				tui_keys Enter; sleep 3
			fi
			_scr=$(tui_capture)
			if echo "$_scr" | grep -qi "Choose execution mode\|Run in Terminal\|Run in TUI"; then
				tui_keys Enter; sleep 2
			fi

			# Wait for OSUS to actually start running before checking progress
			echo "  Waiting for OSUS execution to begin..."
			for _ow in 1 2 3 4 5; do
				sleep 3
				_scr=$(tui_capture)
				if echo "$_scr" | grep -qi "Executing\|Progress.*step\|Running.*step\|steps\|── Success ──\|── FAILED ──"; then
					break
				fi
				if echo "$_scr" | grep -qi "Choose execution mode\|Run in Terminal\|Run in TUI"; then
					tui_keys Enter; sleep 2; continue
				fi
				if echo "$_scr" | grep -qi "Continue anyway\|Warning.*Continue"; then
					tui_keys Enter; sleep 2; continue
				fi
			done

			if tui_wait_for_progress "upg-osus" 600; then
				echo "  ✓ PASS: OSUS configured via TUI"
				_TUI_PASS=$(( _TUI_PASS + 1 ))
			else
				echo "  ✗ FAIL: OSUS configuration failed"
				_TUI_FAIL=$(( _TUI_FAIL + 1 ))
			fi
			tui_dismiss_result
		else
			echo "  WARNING: OSUS not found on Day-2 menu"
			tui_screenshot "upg-03-osus-not-found"
		fi

		# Verify OSUS is actually running after TUI config
		sleep 5
		_osus_running=$($_TUI_SSH "
			export KUBECONFIG=~/aba/$_CLUSTER/iso-agent-based/auth/kubeconfig
			oc get pods -n openshift-update-service --no-headers 2>/dev/null | grep -c Running 2>/dev/null || echo 0
		" 2>/dev/null | tail -1 || echo 0)
		_osus_running=${_osus_running//[^0-9]/}
		: "${_osus_running:=0}"
		if [[ "$_osus_running" -gt 0 ]]; then
			echo "  ✓ Verified: OSUS running ($_osus_running pod(s))"
		else
			echo "  ⚠ Warning: OSUS pods not running yet — upgrade may use force mode"
		fi
	fi
fi

# ============================================================================
# 4. Upgrade via TUI
# ============================================================================
echo ""
echo "--- 4. Upgrade $_current_ver → $_target_ver ---"

if ! tui_session_alive; then
	tui_start_to_menu || { tui_summary; exit 1; }
fi
tui_back_to "Actions" 5

tui_select_item "Day-2"
tui_assert_appears "Day-2\|Cluster Management" "Day-2 menu" 10
tui_select_item "Upgrade"
sleep 5
tui_screenshot "upg-04-upgrade-menu"

_scr=$(tui_capture)

# Handle cluster selection dialog
if echo "$_scr" | grep -qi "select.*cluster"; then
	tui_keys Enter; sleep 3
	_scr=$(tui_capture)
fi

# Wait for version list
tui_wait_for "Current\|Upgrade\|version\|$_target_ver" 30
tui_screenshot "upg-04b-versions"

_scr=$(tui_capture)
if echo "$_scr" | grep -qi "No available.*upgrade\|No.*versions"; then
	echo "  ✗ FAIL: No upgrade versions available (expected $_target_ver)"
	echo "  Sync or day-2 may not have made the version visible yet."
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	tui_keys Enter; sleep 1
elif echo "$_scr" | grep -qi "Current\|version"; then
	echo "  ✓ PASS: Upgrade version list displayed"
	_TUI_PASS=$(( _TUI_PASS + 1 ))

	# Show available versions (items with single-letter keys)
	echo "  Available versions:"
	tui_menu_items | while IFS=$'\t' read -r key label; do
		echo "    [$key] $label"
	done

	# Version items don't have single-letter keys — they appear bare in the list.
	# The target version should be highlighted by default (first real item).
	# Just press Enter to select it and trigger the Upgrade button action.
	echo "  Selecting version $_target_ver via Enter..."
	tui_keys Enter
	sleep 3
	tui_screenshot "upg-04c-after-enter"

	# Handle execution mode dialog if it appears
	_scr=$(tui_capture)
	if echo "$_scr" | grep -qi "Choose execution mode\|Run in Terminal\|Run in TUI"; then
		echo "  Dismissing execution mode dialog..."
		tui_keys Enter; sleep 2
	fi

	# Wait for the execution dialog to actually appear (avoid detecting
	# a brief flash of the menu between the version picker closing and
	# the confirm_and_execute dialog opening).
	echo "  Waiting for upgrade execution to start..."
	_exec_wait=""
	for _exec_wait in 1 2 3 4 5 6 7 8 9 10; do
		sleep 3
		_scr=$(tui_capture)
		tui_screenshot "upg-04d-exec-wait-${_exec_wait}"
		# Execution dialog shows scrolling output or progress steps
		if echo "$_scr" | grep -qi "Executing\|Running\|Syncing\|steps\|Progress\|upgrade\|day2\|oc adm\|clusterversion"; then
			echo "  Execution dialog detected (attempt $_exec_wait)"
			break
		fi
		# Handle execution mode dialog again if it re-appears
		if echo "$_scr" | grep -qi "Choose execution mode\|Run in Terminal\|Run in TUI"; then
			echo "  Dismissing execution mode dialog (retry)..."
			tui_keys Enter; sleep 2
			continue
		fi
		# Handle warning/confirmation dialogs
		if echo "$_scr" | grep -qi "Continue anyway\|Warning.*Continue\|Continue.*Cancel"; then
			echo "  Dismissing warning dialog..."
			tui_keys Enter; sleep 2
			continue
		fi
		# If we see Success or FAILED, the operation already completed
		if echo "$_scr" | grep -qi "── Success ──\|── FAILED ──\|All steps completed"; then
			echo "  Operation already completed"
			break
		fi
	done

	# Wait for upgrade (up to 90 min)
	echo "  Waiting for upgrade to complete (up to 90 min)..."
	if tui_wait_for_progress "upg-upgrade" 5400; then
		echo "  ✓ PASS: Upgrade completed via TUI"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ✗ FAIL: Upgrade failed or timed out"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	fi
	tui_dismiss_result
elif echo "$_scr" | grep -qi "Upgrade Check Failed\|failed.*query"; then
	echo "  ✗ FAIL: Upgrade check failed"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	tui_keys Enter; sleep 1
else
	echo "  ✗ FAIL: Unexpected upgrade screen"
	tui_screenshot "upg-04-unexpected"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

# ============================================================================
# 5. Verify cluster version after upgrade (server-side)
# ============================================================================
echo ""
echo "--- 5. Verify cluster version ---"

# Poll for the desired version to change (upgrade may take a moment to be accepted)
_new_ver=""
for _poll in 1 2 3 4 5 6; do
	sleep 10
	_new_ver=$($_TUI_SSH "
		export KUBECONFIG=~/aba/$_CLUSTER/iso-agent-based/auth/kubeconfig
		oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null
	" 2>/dev/null || true)
	[[ "$_new_ver" == "$_target_ver" ]] && break
	[[ "$_new_ver" != "$_current_ver" ]] && break
	echo "  Waiting for upgrade to be accepted... (${_poll})"
done

if [[ -n "$_new_ver" ]]; then
	echo "  Cluster desired version: $_new_ver"
	if [[ "$_new_ver" == "$_target_ver" ]]; then
		echo "  ✓ PASS: Cluster upgrading to $_target_ver"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	elif [[ "$_new_ver" != "$_current_ver" ]]; then
		echo "  ✓ PASS: Upgrade accepted (version changed: $_current_ver → $_new_ver)"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ✗ FAIL: Cluster still at $_current_ver (expected $_target_ver)"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	fi
else
	echo "  ✗ FAIL: Could not retrieve cluster version"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

# Verify cluster health
_nodes=$($_TUI_SSH "
	export KUBECONFIG=~/aba/$_CLUSTER/iso-agent-based/auth/kubeconfig
	oc get nodes --no-headers 2>/dev/null | grep -c Ready
" 2>/dev/null || echo 0)
if [[ "$_nodes" -gt 0 ]]; then
	echo "  ✓ PASS: Cluster has $_nodes Ready node(s) post-upgrade"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: No Ready nodes after upgrade"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

# ============================================================================
# 6. Cleanup
# ============================================================================
echo ""
echo "--- 6. Cleanup ---"

# Remove upgrade target from mirror.conf
$_TUI_SSH "cd ~/aba && sed -i '/^ocp_upgrade_to=/d' mirror/mirror.conf 2>/dev/null" || true
echo "  Cleared ocp_upgrade_to from mirror.conf"

tui_cleanup
tui_summary
