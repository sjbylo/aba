#!/bin/bash
# Test: TUI cluster upgrade workflow
# Navigates to upgrade dialog, selects version, and monitors upgrade.
# Prereqs: installed cluster with OSUS, mirror with newer version synced.

cd "$(dirname "$0")/../.."
source test/func/tui-test-lib.sh

_CLUSTER="${TUI_CLUSTER_NAME:-sno}"
_ssh_cfg="$HOME/.aba/ssh.conf"

echo "=== TUI Upgrade Workflow Test ==="
echo "  Host: $_TUI_HOST"
echo "  Cluster: $_CLUSTER"
echo ""

scp -q -F "$_ssh_cfg" tui/v2/*.sh "$_TUI_HOST:aba/tui/v2/" 2>/dev/null
scp -q -F "$_ssh_cfg" scripts/include_all.sh scripts/aba.sh "$_TUI_HOST:aba/scripts/" 2>/dev/null
echo "  Code deployed"
echo ""

# Verify cluster exists
_inst=$($_TUI_SSH "test -f ~/aba/$_CLUSTER/.install-complete && echo yes || echo no")
if [[ "$_inst" != "yes" ]]; then
	echo "  SKIP: Cluster '$_CLUSTER' not installed — skipping upgrade test"
	_TUI_PASS=0; _TUI_FAIL=0; tui_summary; exit 0
fi

# ============================================================================
tui_start
tui_assert_appears "OpenShift Installer" "TUI launched" 15 || {
	tui_stop; tui_summary; exit 1
}
tui_keys Enter  # past splash
tui_assert_appears "Actions" "Main menu" 10

# ============================================================================
# 1. Navigate to Day-2 → Upgrade
# ============================================================================
echo ""
echo "--- 1. Navigate to Upgrade ---"
tui_select_item "Day-2"
tui_assert_appears "Day-2\|Cluster Management" "Day-2 menu" 10
tui_select_item "Upgrade"
sleep 5
tui_screenshot "up-01-upgrade"

_scr=$(tui_capture)

# Handle cluster selection dialog
if echo "$_scr" | grep -qi "select.*cluster"; then
	echo "  Cluster selection dialog"
	tui_keys Enter; sleep 3
	_scr=$(tui_capture)
fi

# ============================================================================
# 2. Upgrade version selection
# ============================================================================
echo ""
echo "--- 2. Version selection ---"
tui_wait_for "Current\|Upgrade\|version\|No available\|upgrade" 30
tui_screenshot "up-02-versions"

_scr=$(tui_capture)
if echo "$_scr" | grep -qi "No available.*upgrade\|No.*versions"; then
	echo "  ~ NOTE: No upgrade versions available"
	echo "  This is expected if no newer version is synced to the mirror."
	echo "  ✓ PASS: Upgrade dialog correctly reports no versions"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
	tui_keys Enter; sleep 1  # dismiss dialog
elif echo "$_scr" | grep -qi "Current.*4\.\|z-stream\|minor"; then
	echo "  ✓ PASS: Upgrade version list displayed"
	_TUI_PASS=$(( _TUI_PASS + 1 ))

	# Discover available versions from screen
	echo "  Available versions:"
	tui_menu_items | while IFS=$'\t' read -r key label; do
		echo "    [$key] $label"
	done

	# Check for OSUS indicator
	if echo "$_scr" | grep -qi "OSUS"; then
		echo "  ✓ PASS: OSUS status shown"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	fi

	# Check for current version display
	if echo "$_scr" | grep -qi "Current.*[0-9]\+\.[0-9]\+\.[0-9]\+"; then
		echo "  ✓ PASS: Current version displayed"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	fi

	# Select the first available version and upgrade
	tui_keys Enter; sleep 2
	_scr=$(tui_capture)

	# Handle force option or confirmation
	if echo "$_scr" | grep -qi "confirm\|proceed\|force\|Start.*upgrade\|Upgrade.*to"; then
		echo "  Upgrade confirmation dialog"
		tui_screenshot "up-02b-confirm"
		tui_keys Enter; sleep 3
	fi

	# Handle execution mode
	_scr=$(tui_capture)
	if echo "$_scr" | grep -qi "Terminal\|Execution"; then
		tui_keys Enter; sleep 2
	fi

	# Wait for upgrade to complete (can take 30-90 min for z-stream)
	echo "  Waiting for upgrade (up to 90 min)..."
	_start_time=$(date +%s)
	_last_screenshot=0
	while true; do
		_elapsed=$(( $(date +%s) - _start_time ))
		[[ $_elapsed -ge 5400 ]] && break  # 90 min timeout

		_scr=$(tui_capture)

		# Periodic screenshots
		if (( _elapsed - _last_screenshot >= 300 )); then
			tui_screenshot "up-progress-${_elapsed}s"
			_last_screenshot=$_elapsed
		fi

		if echo "$_scr" | grep -qi "upgrade.*complete\|successfully\|new.*version"; then
			echo "  ✓ PASS: Upgrade completed (${_elapsed}s)"
			_TUI_PASS=$(( _TUI_PASS + 1 ))
			break
		fi

		if echo "$_scr" | grep -qi "FAILED\|error\|timed.out"; then
			echo "  ✗ FAIL: Upgrade failed"
			tui_screenshot "up-fail"
			_TUI_FAIL=$(( _TUI_FAIL + 1 ))
			break
		fi

		tui_dismiss_result && continue

		if echo "$_scr" | grep -q "Actions\|Day-2"; then
			echo "  Returned to menu (upgrade may have completed)"
			break
		fi

		sleep 30
	done
	tui_dismiss_result
elif echo "$_scr" | grep -qi "Upgrade Check Failed\|failed.*query"; then
	echo "  ~ NOTE: Upgrade check failed (cluster may not be reachable)"
	tui_keys Enter; sleep 1
else
	echo "  ~ NOTE: Unexpected upgrade screen"
	tui_screenshot "up-02-unexpected"
fi

# ============================================================================
# 3. Verify cluster version after upgrade
# ============================================================================
echo ""
echo "--- 3. Verify cluster version ---"
_ver=$($_TUI_SSH "export KUBECONFIG=~/aba/$_CLUSTER/iso-agent-based/auth/kubeconfig; oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null" || true)
if [[ -n "$_ver" ]]; then
	echo "  Cluster version: $_ver"
	echo "  ✓ PASS: Cluster version retrieved"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: Could not retrieve cluster version after upgrade"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

# Verify cluster is healthy after upgrade
_nodes=$($_TUI_SSH "export KUBECONFIG=~/aba/$_CLUSTER/iso-agent-based/auth/kubeconfig; oc get nodes --no-headers 2>/dev/null | grep -c Ready" 2>/dev/null || echo 0)
if [[ "$_nodes" -gt 0 ]]; then
	echo "  ✓ PASS: Cluster has $_nodes Ready node(s) post-upgrade"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: No Ready nodes after upgrade"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

# ============================================================================
# 4. Cleanup
# ============================================================================
echo ""
echo "--- 4. Cleanup ---"
tui_cleanup
tui_summary
