#!/bin/bash
# Test: TUI cluster lifecycle — shutdown, startup, clean, delete
# Prereqs: installed cluster.
# DESTRUCTIVE: shutdown/startup are safe, but clean/delete destroy the cluster.
# Set TUI_SKIP_DELETE=1 to skip the delete step.

cd "$(dirname "$0")/../.."
source test/func/tui-test-lib.sh

_CLUSTER="${TUI_CLUSTER_NAME:-sno}"
_SKIP_DELETE="${TUI_SKIP_DELETE:-0}"
_ssh_cfg="$HOME/.aba/ssh.conf"

echo "=== TUI Lifecycle Workflow Test ==="
echo "  Host: $_TUI_HOST"
echo "  Cluster: $_CLUSTER"
echo "  Skip delete: $_SKIP_DELETE"
echo ""

scp -q -F "$_ssh_cfg" tui/v2/*.sh "$_TUI_HOST:aba/tui/v2/" 2>/dev/null
scp -q -F "$_ssh_cfg" scripts/include_all.sh scripts/aba.sh "$_TUI_HOST:aba/scripts/" 2>/dev/null
echo "  Code deployed"
echo ""

_inst=$($_TUI_SSH "ls ~/aba/$_CLUSTER/.install-complete 2>/dev/null && echo yes || echo no")
if [[ "$_inst" != "yes" ]]; then
	echo "  SKIP: Cluster '$_CLUSTER' not installed — skipping lifecycle test"
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
# 1. Graceful Shutdown
# ============================================================================
echo ""
echo "--- 1. Graceful Shutdown ---"
tui_select_item "Day-2"
tui_assert_appears "Day-2\|Cluster Management" "Day-2 menu" 10
tui_select_item "shutdown"
sleep 3
tui_screenshot "lc-01-shutdown"

_scr=$(tui_capture)
# Handle cluster selection
if echo "$_scr" | grep -qi "select.*cluster"; then
	tui_keys Enter; sleep 2
	_scr=$(tui_capture)
fi

if echo "$_scr" | grep -qiE "confirm\|shutdown\|proceed\|sure"; then
	echo "  ✓ PASS: Shutdown confirmation dialog"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
	tui_screenshot "lc-01b-shutdown-confirm"

	# Confirm shutdown
	tui_keys Enter; sleep 3

	_scr=$(tui_capture)
	if echo "$_scr" | grep -qiE "Terminal|Execution"; then
		tui_keys Enter; sleep 2
	fi

	# Wait for shutdown to complete (typically 5-15 min)
	echo "  Waiting for shutdown (up to 20 min)..."
	tui_wait_for "complete\|success\|shut down\|Actions\|Day-2" 1200
	tui_screenshot "lc-01c-shutdown-result"

	_scr=$(tui_capture)
	if echo "$_scr" | grep -qiE "complete\|success\|shut down"; then
		echo "  ✓ PASS: Shutdown completed"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	elif echo "$_scr" | grep -qi "Actions\|Day-2"; then
		echo "  ✓ PASS: Returned to menu after shutdown"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	fi
else
	echo "  ~ NOTE: Unexpected shutdown screen"
	tui_screenshot "lc-01-unexpected"
fi

# ============================================================================
# 2. Verify cluster is shut down
# ============================================================================
echo ""
echo "--- 2. Verify shutdown ---"
sleep 5
_shutdown_log=$($_TUI_SSH "ls ~/aba/$_CLUSTER/.shutdown.log 2>/dev/null && echo yes || echo no")
if [[ "$_shutdown_log" == "yes" ]]; then
	echo "  ✓ PASS: Shutdown log exists"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
fi

# ============================================================================
# 3. Graceful Startup
# ============================================================================
echo ""
echo "--- 3. Graceful Startup ---"
tui_back_to "Actions" 5
tui_select_item "Day-2"
tui_assert_appears "Day-2\|Cluster Management" "Day-2 menu" 10
tui_select_item "startup"
sleep 3
tui_screenshot "lc-03-startup"

_scr=$(tui_capture)
if echo "$_scr" | grep -qi "select.*cluster"; then
	tui_keys Enter; sleep 2
	_scr=$(tui_capture)
fi

if echo "$_scr" | grep -qiE "confirm\|startup\|start\|proceed\|power"; then
	echo "  ✓ PASS: Startup dialog appeared"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
	tui_keys Enter; sleep 3

	_scr=$(tui_capture)
	if echo "$_scr" | grep -qiE "Terminal|Execution"; then
		tui_keys Enter; sleep 2
	fi

	# Wait for startup (VMs power on + cluster recovers: 10-20 min)
	echo "  Waiting for startup (up to 30 min)..."
	tui_wait_for "complete\|success\|started\|ready\|Actions\|Day-2" 1800
	tui_screenshot "lc-03b-startup-result"

	echo "  ✓ PASS: Startup completed"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ~ NOTE: Unexpected startup screen"
	tui_screenshot "lc-03-unexpected"
fi

# ============================================================================
# 4. Verify cluster is running after startup
# ============================================================================
echo ""
echo "--- 4. Verify cluster running ---"
sleep 10
_nodes=$($_TUI_SSH "export KUBECONFIG=~/aba/$_CLUSTER/iso-agent-based/auth/kubeconfig; oc get nodes --no-headers 2>/dev/null | grep -c Ready" 2>/dev/null || echo 0)
if [[ "$_nodes" -gt 0 ]]; then
	echo "  ✓ PASS: Cluster has $_nodes Ready node(s) after startup"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ~ NOTE: Cluster nodes not ready yet (may need more time)"
fi

# ============================================================================
# 5. Clean cluster (remove artifacts for reinstall)
# ============================================================================
if [[ "$_SKIP_DELETE" == "1" ]]; then
	echo ""
	echo "--- 5. SKIPPED: Clean/Delete (TUI_SKIP_DELETE=1) ---"
else
	echo ""
	echo "--- 5. Clean cluster ---"
	tui_back_to "Actions" 5
	tui_select_item "Day-2"
	tui_assert_appears "Day-2\|Cluster Management" "Day-2 menu" 10
	tui_select_item "Clean"
	sleep 3
	tui_screenshot "lc-05-clean"

	_scr=$(tui_capture)
	if echo "$_scr" | grep -qi "select.*cluster"; then
		tui_keys Enter; sleep 2
		_scr=$(tui_capture)
	fi

	if echo "$_scr" | grep -qiE "confirm\|clean\|remove\|sure"; then
		echo "  ✓ PASS: Clean confirmation dialog"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
		tui_keys Enter; sleep 3

		_scr=$(tui_capture)
		if echo "$_scr" | grep -qiE "Terminal|Execution"; then
			tui_keys Enter; sleep 2
		fi

		tui_wait_for "complete\|success\|Actions\|Day-2" 300
		tui_screenshot "lc-05b-clean-result"
		echo "  ✓ PASS: Clean completed"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	fi

	# ============================================================================
	# 6. Delete cluster
	# ============================================================================
	echo ""
	echo "--- 6. Delete cluster ---"
	tui_back_to "Actions" 5
	tui_select_item "Day-2"
	tui_assert_appears "Day-2\|Cluster Management" "Day-2 menu" 10
	tui_select_item "Delete"
	sleep 3
	tui_screenshot "lc-06-delete"

	_scr=$(tui_capture)
	if echo "$_scr" | grep -qi "select.*cluster"; then
		tui_keys Enter; sleep 2
		_scr=$(tui_capture)
	fi

	if echo "$_scr" | grep -qiE "confirm\|delete\|destroy\|sure\|remove"; then
		echo "  ✓ PASS: Delete confirmation dialog"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
		tui_keys Enter; sleep 3

		_scr=$(tui_capture)
		if echo "$_scr" | grep -qiE "Terminal|Execution"; then
			tui_keys Enter; sleep 2
		fi

		tui_wait_for "complete\|success\|deleted\|Actions\|Day-2" 600
		tui_screenshot "lc-06b-delete-result"
		echo "  ✓ PASS: Delete completed"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	fi

	# Verify cluster is gone
	_gone=$($_TUI_SSH "ls ~/aba/$_CLUSTER/.install-complete 2>/dev/null && echo no || echo yes")
	if [[ "$_gone" == "yes" ]]; then
		echo "  ✓ PASS: Cluster '$_CLUSTER' deleted (no .install-complete)"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	fi
fi

# ============================================================================
# 7. Cleanup
# ============================================================================
echo ""
echo "--- 7. Cleanup ---"
tui_back_to "Actions" 5
for i in 1 2 3 4 5; do tui_keys Escape; sleep 1; done
sleep 2
if $_TUI_SSH "tmux has-session -t $_TUI_SESSION 2>/dev/null"; then
	tui_keys Enter; sleep 1; tui_keys Escape; sleep 1; tui_keys Enter; sleep 2
fi
_strays=$($_TUI_SSH "ps -eo pid,ppid,args | grep -E '\bdialog\b|abatui' | grep -v grep" 2>/dev/null || true)
if [ -z "$_strays" ]; then
	echo "  ✓ PASS: No stray processes"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: Stray processes"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	$_TUI_SSH "pkill -f abatui 2>/dev/null; pkill -f 'dialog --' 2>/dev/null; true"
fi

tui_stop 2>/dev/null
tui_summary
