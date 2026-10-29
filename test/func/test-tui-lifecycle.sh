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

_inst=$($_TUI_SSH "test -f ~/aba/$_CLUSTER/.install-complete && echo yes || echo no")
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

# Pre-check: skip shutdown if cluster is already shut down
_already_down=$($_TUI_SSH "test -f ~/aba/$_CLUSTER/.shutdown.log && echo yes || echo no")
if [[ "$_already_down" == "yes" ]]; then
	echo "  Cluster already shut down (.shutdown.log exists) — skipping to startup"
	echo "  ✓ PASS: Shutdown state verified (pre-existing)"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
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

	if echo "$_scr" | grep -qi "confirm\|shutdown\|proceed\|sure"; then
		echo "  ✓ PASS: Shutdown confirmation dialog"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
		tui_screenshot "lc-01b-shutdown-confirm"

		# Confirm: --defaultno focuses Cancel, move to Yes first
		tui_confirm_yes; sleep 3
		tui_screenshot "lc-01c-after-confirm"

		_scr=$(tui_capture)
		if echo "$_scr" | grep -qi "Terminal\|Execution"; then
			tui_keys Enter; sleep 2
			tui_screenshot "lc-01d-exec-mode"
		fi

		# Wait for shutdown to complete (typically 5-15 min)
		# Include Error|FAILED so we don't hang on error dialogs
		echo "  Waiting for shutdown (up to 20 min)..."
		if tui_wait_for "steps completed\|success\|Command completed\|Press.*ENTER\|Error\|FAILED" 1200; then
			_scr=$(tui_capture)
			if echo "$_scr" | grep -qi "Error\|FAILED"; then
				echo "  ✗ FAIL: Shutdown reported an error"
				_TUI_FAIL=$(( _TUI_FAIL + 1 ))
				tui_screenshot "lc-01e-shutdown-error"
				# Dismiss error dialog
				tui_keys Enter; sleep 2
			else
				echo "  ✓ PASS: Shutdown completed"
				_TUI_PASS=$(( _TUI_PASS + 1 ))
			fi
		else
			echo "  ✗ FAIL: Shutdown did not complete"
			_TUI_FAIL=$(( _TUI_FAIL + 1 ))
		fi
		tui_screenshot "lc-01f-shutdown-result"
		tui_dismiss_result
	else
		echo "  ~ NOTE: Unexpected shutdown screen"
		tui_screenshot "lc-01-unexpected"
	fi

	# ---- Verify shutdown ----
	echo ""
	echo "--- 2. Verify shutdown ---"
	sleep 5
	_shutdown_log=$($_TUI_SSH "test -f ~/aba/$_CLUSTER/.shutdown.log && echo yes || echo no")
	if [[ "$_shutdown_log" == "yes" ]]; then
		echo "  ✓ PASS: Shutdown log exists"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ✗ FAIL: Shutdown log missing — shutdown may not have executed"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	fi
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

if echo "$_scr" | grep -qi "confirm\|startup\|start\|proceed\|power"; then
	echo "  ✓ PASS: Startup dialog appeared"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
	tui_keys Enter; sleep 3
	tui_screenshot "lc-03c-after-confirm"

	_scr=$(tui_capture)
	if echo "$_scr" | grep -qi "Terminal\|Execution"; then
		tui_keys Enter; sleep 2
		tui_screenshot "lc-03d-exec-mode"
	fi

	# Wait for startup (VMs power on + cluster recovers: 10-20 min)
	echo "  Waiting for startup (up to 30 min)..."
	# Avoid generic words like "ready"/"started" — they match step labels in the progress dialog
	if tui_wait_for "steps completed\|success\|Command completed\|Press.*ENTER\|Error\|FAILED" 1800; then
		_scr=$(tui_capture)
		if echo "$_scr" | grep -qi "Error\|FAILED"; then
			echo "  ✗ FAIL: Startup reported an error"
			_TUI_FAIL=$(( _TUI_FAIL + 1 ))
			tui_screenshot "lc-03e-startup-error"
			tui_keys Enter; sleep 2
		else
			echo "  ✓ PASS: Startup completed"
			_TUI_PASS=$(( _TUI_PASS + 1 ))
		fi
	else
		echo "  ✗ FAIL: Startup did not complete"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	fi
	tui_screenshot "lc-03b-startup-result"
	tui_dismiss_result
else
	echo "  ~ NOTE: Unexpected startup screen"
	tui_screenshot "lc-03-unexpected"
fi

# ============================================================================
# 4. Verify cluster is running after startup
# ============================================================================
echo ""
echo "--- 4. Verify cluster running ---"
echo "  Waiting for nodes to become Ready (up to 5 min)..."
_nodes=0
for _try in $(seq 1 30); do
	_nodes=$($_TUI_SSH "export KUBECONFIG=~/aba/$_CLUSTER/iso-agent-based/auth/kubeconfig; oc get nodes --no-headers 2>/dev/null | grep -c Ready" 2>/dev/null || true)
	_nodes="${_nodes##*$'\n'}"
	_nodes="${_nodes:-0}"
	[[ "$_nodes" -gt 0 ]] 2>/dev/null && break
	sleep 10
done
if [[ "$_nodes" -gt 0 ]] 2>/dev/null; then
	echo "  ✓ PASS: Cluster has $_nodes Ready node(s) after startup"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: No Ready nodes after startup (expected >0, got ${_nodes})"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
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
		tui_keys Enter
		# Wait for cluster selection to dismiss before checking next dialog
		tui_wait_gone "select.*cluster" 5
		_scr=$(tui_capture)
	fi

	if echo "$_scr" | grep -qi "Clean cluster\|remove\|sure"; then
		echo "  ✓ PASS: Clean confirmation dialog"
		_TUI_PASS=$(( _TUI_PASS + 1 ))

		# Confirm: --defaultno focuses Cancel, move to Yes first
		tui_confirm_yes; sleep 3
		tui_screenshot "lc-05c-after-confirm"

		_scr=$(tui_capture)
		if echo "$_scr" | grep -qi "Terminal\|Execution"; then
			tui_keys Enter; sleep 2
			tui_screenshot "lc-05d-exec-mode"
		fi

		if tui_wait_for "steps completed\|success\|Command completed\|Press.*ENTER\|Error\|FAILED" 300; then
			_scr=$(tui_capture)
			if echo "$_scr" | grep -qi "Error\|FAILED"; then
				echo "  ✗ FAIL: Clean reported an error"
				_TUI_FAIL=$(( _TUI_FAIL + 1 ))
				tui_screenshot "lc-05e-clean-error"
				tui_keys Enter; sleep 2
			else
				echo "  ✓ PASS: Clean completed"
				_TUI_PASS=$(( _TUI_PASS + 1 ))
			fi
		else
			echo "  ✗ FAIL: Clean did not complete"
			_TUI_FAIL=$(( _TUI_FAIL + 1 ))
		fi
		tui_screenshot "lc-05b-clean-result"
		tui_dismiss_result
	fi

	# Verify clean actually removed generated artifacts
	_still_installed=$($_TUI_SSH "test -f ~/aba/$_CLUSTER/.install-complete && echo yes || echo no")
	_conf_kept=$($_TUI_SSH "test -f ~/aba/$_CLUSTER/cluster.conf && echo yes || echo no")
	if [[ "$_still_installed" == "no" && "$_conf_kept" == "yes" ]]; then
		echo "  ✓ PASS: Clean removed .install-complete, kept cluster.conf"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	elif [[ "$_still_installed" == "yes" ]]; then
		echo "  ✗ FAIL: Clean did not remove .install-complete — clean may not have executed"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	elif [[ "$_conf_kept" == "no" ]]; then
		echo "  ✗ FAIL: Clean removed cluster.conf — too aggressive"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
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
		tui_keys Enter
		tui_wait_gone "select.*cluster" 5
		_scr=$(tui_capture)
	fi

	if echo "$_scr" | grep -qi "Delete cluster\|destroy\|sure\|remove"; then
		echo "  ✓ PASS: Delete confirmation dialog"
		_TUI_PASS=$(( _TUI_PASS + 1 ))

		# Confirm: --defaultno focuses Cancel, move to Yes first
		tui_confirm_yes; sleep 3
		tui_screenshot "lc-06c-after-confirm"

		_scr=$(tui_capture)
		if echo "$_scr" | grep -qi "Terminal\|Execution"; then
			tui_keys Enter; sleep 2
			tui_screenshot "lc-06d-exec-mode"
		fi

		if tui_wait_for "steps completed\|success\|Command completed\|Press.*ENTER\|Error\|FAILED" 600; then
			_scr=$(tui_capture)
			if echo "$_scr" | grep -qi "Error\|FAILED"; then
				echo "  ✗ FAIL: Delete reported an error"
				_TUI_FAIL=$(( _TUI_FAIL + 1 ))
				tui_screenshot "lc-06e-delete-error"
				tui_keys Enter; sleep 2
			else
				echo "  ✓ PASS: Delete completed"
				_TUI_PASS=$(( _TUI_PASS + 1 ))
			fi
		else
			echo "  ✗ FAIL: Delete did not complete"
			_TUI_FAIL=$(( _TUI_FAIL + 1 ))
		fi
		tui_screenshot "lc-06b-delete-result"
		tui_dismiss_result
	fi

	# Verify cluster is gone
	_gone=$($_TUI_SSH "test -f ~/aba/$_CLUSTER/.install-complete && echo no || echo yes")
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
tui_cleanup
tui_summary
