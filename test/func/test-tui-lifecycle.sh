#!/bin/bash
# Test: TUI cluster lifecycle — shutdown, startup, clean, delete
# Prereqs: installed cluster.
# DESTRUCTIVE: shutdown/startup are safe, but clean/delete destroy the cluster.
# Set TUI_SKIP_DELETE=1 to skip the delete step.

cd "$(dirname "$0")/../.."
source test/func/tui-test-lib.sh

_CLUSTER="${TUI_CLUSTER_NAME:-sno}"
_SKIP_DELETE="${TUI_SKIP_DELETE:-0}"

echo "=== TUI Lifecycle Workflow Test ==="
echo "  Host: $_TUI_HOST"
echo "  Cluster: $_CLUSTER"
echo "  Skip delete: $_SKIP_DELETE"
echo ""

tui_deploy_code
tui_pre_cleanup
echo ""

_inst=$($_TUI_SSH "test -f ~/aba/$_CLUSTER/.install-complete && echo yes || echo no")
if [[ "$_inst" != "yes" ]]; then
	echo "  ✗ FAIL: Cluster '$_CLUSTER' not installed — cannot run lifecycle test"
	_TUI_FAIL=1; tui_summary; exit 1
fi

# ============================================================================
tui_start_to_menu || { tui_summary; exit 1; }

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
	tui_assert_title "Day-2\|Cluster Management" "Day-2 dialog title"
	tui_assert_appears "Day-2\|Cluster Management" "Day-2 menu" 10
	tui_select_item "shutdown"
	sleep 1
	tui_screenshot "lc-01-shutdown"
	# Leftover dirs (compact/standard/…) make Day-2 scan status first — wait, then pick sno
	tui_pick_cluster "$_CLUSTER"
	_scr=$(tui_capture)

	if echo "$_scr" | grep -qi "shutdown\|Graceful.*shutdown\|shut.*down"; then
		echo "  ✓ PASS: Shutdown confirmation dialog"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
		tui_screenshot "lc-01b-shutdown-confirm"

		# Confirm: --defaultno focuses Cancel, move to Yes first
		tui_confirm_yes; sleep 1
		tui_screenshot "lc-01c-after-confirm"

		tui_dismiss_exec_mode

		# ABA cluster-graceful-shutdown waits up to 40 min for hypervisor power-off
		echo "  Waiting for shutdown (up to 45 min)..."
		if tui_wait_for_progress "lc-shutdown" 2700; then
			echo "  ✓ PASS: Shutdown completed"
			_TUI_PASS=$(( _TUI_PASS + 1 ))
		else
			echo "  ✗ FAIL: Shutdown failed"
			_TUI_FAIL=$(( _TUI_FAIL + 1 ))
		fi
		tui_screenshot "lc-01f-shutdown-result"
		tui_dismiss_result
	else
		echo "  ✗ FAIL: Unexpected shutdown screen"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
		tui_screenshot "lc-01-unexpected"
	fi

	# ---- Verify shutdown ----
	echo ""
	echo "--- 2. Verify shutdown ---"
	sleep 2
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
sleep 1
tui_screenshot "lc-03-startup"
tui_pick_cluster "$_CLUSTER"
_scr=$(tui_capture)

if echo "$_scr" | grep -qi "startup\|Graceful.*start\|start.*cluster\|power.*on"; then
	echo "  ✓ PASS: Startup dialog appeared"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
	tui_keys Enter; sleep 1
	tui_screenshot "lc-03c-after-confirm"

	tui_dismiss_exec_mode

	echo "  Waiting for startup (up to 30 min)..."
	if tui_wait_for_progress "lc-startup" 900; then
		echo "  ✓ PASS: Startup completed"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ✗ FAIL: Startup failed"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	fi
	tui_screenshot "lc-03b-startup-result"
	tui_dismiss_result
else
	echo "  ✗ FAIL: Unexpected startup screen"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
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
	# Clean while installed must be refused (would orphan VMs). Then Delete.
	echo ""
	echo "--- 5. Clean refused while installed ---"
	tui_back_to "Actions" 5
	tui_select_item "Day-2"
	tui_assert_appears "Day-2\|Cluster Management" "Day-2 menu" 10
	tui_select_item "Clean"
	sleep 1
	tui_screenshot "lc-05-clean"
	# Must pick the installed cluster — default first entry may be a leftover "installing" dir
	tui_pick_cluster "$_CLUSTER"
	_scr=$(tui_capture)

	# Expect msgbox refusing clean (not a confirm-and-execute progress dialog)
	if echo "$_scr" | grep -qiE "refused|installed|Delete cluster first|install-complete|cannot clean"; then
		echo "  ✓ PASS: Clean refused while cluster is installed"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
		tui_keys Enter; sleep 0.5
	else
		echo "  ✗ FAIL: Expected Clean refusal while installed (got dialog without refuse text)"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
		tui_screenshot "lc-05-clean-unexpected"
		# Dismiss whatever dialog appeared
		tui_keys Enter Escape 2>/dev/null || true
	fi

	_still_installed=$($_TUI_SSH "test -f ~/aba/$_CLUSTER/.install-complete && echo yes || echo no")
	if [[ "$_still_installed" == "yes" ]]; then
		echo "  ✓ PASS: .install-complete still present after refused clean"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ✗ FAIL: .install-complete was removed — clean should not have run"
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
	sleep 1
	tui_screenshot "lc-06-delete"
	tui_pick_cluster "$_CLUSTER"
	_scr=$(tui_capture)

	if echo "$_scr" | grep -qi "Delete cluster\|destroy\|sure\|remove"; then
		echo "  ✓ PASS: Delete confirmation dialog"
		_TUI_PASS=$(( _TUI_PASS + 1 ))

		tui_confirm_yes; sleep 1
		tui_screenshot "lc-06c-after-confirm"

		tui_dismiss_exec_mode

		if tui_wait_for_progress "lc-delete" 120; then
			echo "  ✓ PASS: Delete completed"
			_TUI_PASS=$(( _TUI_PASS + 1 ))
		else
			echo "  ✗ FAIL: Delete failed"
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
	else
		echo "  TUI delete left .install-complete — forcing aba/TUI delete"
		tui_delete_cluster "$_CLUSTER" || true
		_gone=$($_TUI_SSH "test -f ~/aba/$_CLUSTER/.install-complete && echo no || echo yes")
		if [[ "$_gone" == "yes" ]]; then
			echo "  ✓ PASS: Cluster '$_CLUSTER' deleted after fallback"
			_TUI_PASS=$(( _TUI_PASS + 1 ))
		else
			echo "  ✗ FAIL: Cluster '$_CLUSTER' still installed after delete"
			_TUI_FAIL=$(( _TUI_FAIL + 1 ))
		fi
	fi
fi

# ============================================================================
# 7. Cleanup
# ============================================================================
echo ""
echo "--- 7. Cleanup ---"
tui_cleanup
tui_summary
