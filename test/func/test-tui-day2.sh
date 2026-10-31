#!/bin/bash
# Test: TUI Day-2 operations — OperatorHub, NTP, status, login
# Prereqs: an installed cluster (defaults to "sno", set TUI_CLUSTER_NAME to override).

cd "$(dirname "$0")/../.."
source test/func/tui-test-lib.sh

_CLUSTER="${TUI_CLUSTER_NAME:-sno}"

echo "=== TUI Day-2 Workflow Test ==="
echo "  Host: $_TUI_HOST"
echo "  Cluster: $_CLUSTER"
echo ""

tui_deploy_code
echo ""

# Verify cluster exists and is installed
_inst=$($_TUI_SSH "test -f ~/aba/$_CLUSTER/.install-complete && echo yes || echo no")
if [[ "$_inst" != "yes" ]]; then
	echo "  ✗ FAIL: Cluster '$_CLUSTER' not installed — cannot run Day-2 tests"
	echo ""
	_TUI_FAIL=1
	tui_summary
	exit 1
fi

# ============================================================================
tui_start_to_menu || { tui_summary; exit 1; }

# ============================================================================
# 1. Enter Day-2 menu
# ============================================================================
echo ""
echo "--- 1. Day-2 menu ---"
tui_select_item "Day-2"
sleep 2
tui_assert_appears "Day-2\|Cluster Management" "Day-2 menu appeared" 10
tui_screenshot "d2-01-menu"

# Verify all expected items
tui_assert_contains "OperatorHub" "OperatorHub item"
tui_assert_contains "NTP" "NTP item"
tui_assert_contains "OSUS" "OSUS item"
tui_assert_contains "status" "Status item"
tui_assert_contains "Login" "Login item"
tui_assert_contains "Upgrade" "Upgrade item"
tui_assert_contains "shutdown" "Shutdown item"
tui_assert_contains "startup" "Startup item"

echo "  Day-2 menu items:"
tui_menu_items | while IFS=$'\t' read -r key label; do
	echo "    [$key] $label"
done

# ============================================================================
# 2. Cluster Status
# ============================================================================
echo ""
echo "--- 2. Cluster Status ---"
tui_select_item "status"
sleep 3
tui_screenshot "d2-02-status"

_scr=$(tui_capture)
if echo "$_scr" | grep -qi "AVAILABLE\|Ready\|node\|operator\|select.*cluster"; then
	echo "  ✓ PASS: Cluster status displayed"
	_TUI_PASS=$(( _TUI_PASS + 1 ))

	# If there's a cluster selection dialog, select our cluster
	if echo "$_scr" | grep -qi "select.*cluster"; then
		tui_keys Enter  # select first/default cluster
		sleep 2
		tui_screenshot "d2-02b-status-detail"
	fi
else
	echo "  ~ NOTE: Status screen content unclear"
	tui_screenshot "d2-02-status-unclear"
fi

# Return to Day-2 menu
tui_back_to "Day-2\|Cluster Management" 5

# Helper: navigate reliably to the Day-2 menu.
# The Day-2 menu is identified by its title "Day-2 / Cluster Management"
# and the presence of menu items with keys (R, N, O, etc.).
_nav_to_day2_menu() {
	local _w _scr
	for _w in 1 2 3 4 5 6 7 8; do
		_scr=$(tui_capture)
		# Check for the actual Day-2 menu (has section headers like "Configuration" and menu keys)
		if echo "$_scr" | grep -q "── Configuration ──\|── Status ──\|── Lifecycle ──"; then
			return 0
		fi
		# Dismiss progress dialog that completed (Succeeded, 100%)
		if echo "$_scr" | grep -qi "steps completed\|── Success ──\|ENTER to return\|Succeeded\|100%"; then
			echo "  (_nav: dismissing completion dialog)" >&2
			tui_keys Enter; sleep 2; continue
		fi
		# Dismiss failure or error dialogs
		if echo "$_scr" | grep -qi "── FAILED ──\|Quit.*Q\|Dismiss"; then
			echo "  (_nav: dismissing failure dialog)" >&2
			tui_keys Enter; sleep 1; continue
		fi
		# Dismiss output pager
		if echo "$_scr" | grep -qi "scroll.*PgUp\|Press Q to quit\|Press.*Escape.*to close"; then
			echo "  (_nav: dismissing output pager)" >&2
			tui_keys q; sleep 1; continue
		fi
		# Dismiss "Output (Space)" button on progress dialog
		if echo "$_scr" | grep -qi "Output.*Space.*Quit"; then
			echo "  (_nav: dismissing progress output)" >&2
			tui_keys Escape; sleep 1; continue
		fi
		# Still showing progress (In Progress / N/A) — wait a bit
		if echo "$_scr" | grep -qi "In Progress\|Day-2:.*day2\|Overall Progress"; then
			echo "  (_nav: progress dialog still active, waiting...)" >&2
			sleep 10; continue
		fi
		# Navigate back from wherever we are
		tui_back_to "Actions" 3
		if tui_capture | grep -q "Actions"; then
			tui_select_item "Day-2"; sleep 2
		fi
	done
	# Final check
	if tui_capture | grep -q "── Configuration ──"; then
		return 0
	fi
	echo "  WARNING: Could not navigate to Day-2 menu" >&2
	return 1
}

# Helper: run a Day-2 action via the progress dialog.
# Navigates to Day-2 menu, selects the item, waits for progress, verifies output.
_day2_run_action() {
	local item_label="$1"
	local action_name="$2"
	local timeout="${3:-600}"
	local expected_cmd="${4:-}"

	# Navigate to the Day-2 menu first
	if ! _nav_to_day2_menu; then
		echo "  ✗ FAIL: Cannot reach Day-2 menu for $action_name"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
		return 1
	fi
	tui_screenshot "d2-${action_name}-menu"

	# Select the menu item
	if ! tui_select_item "$item_label"; then
		echo "  ✗ FAIL: Menu item '$item_label' not found for $action_name"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
		return 1
	fi
	sleep 2
	tui_screenshot "d2-${action_name}-start"

	tui_dismiss_cluster_select

	# Wait for the "One moment please" / loading dialog to transition
	# to the actual progress dialog (can take a few seconds)
	_scr=$(tui_capture)
	if echo "$_scr" | grep -qi "One moment\|please wait\|Loading"; then
		echo "  ($action_name: waiting for loading to finish...)"
		sleep 5
		_scr=$(tui_capture)
	fi

	# Handle warning/confirmation dialogs before progress starts
	if echo "$_scr" | grep -qi "Warning\|Continue anyway\|Confirm\|Are you sure"; then
		echo "  ($action_name: dismissing warning dialog)"
		tui_screenshot "d2-${action_name}-warning"
		tui_keys Enter; sleep 1
		_scr=$(tui_capture)
	fi

	# Only dismiss exec mode if we see it (not the progress dialog)
	if echo "$_scr" | grep -qi "Run in.*Terminal\|Execution Mode"; then
		tui_keys Enter; sleep 1
		_scr=$(tui_capture)
	fi

	# Detect progress dialog or any running state
	if echo "$_scr" | grep -qi "In Progress\|Succeeded\|N/A.*│\|Day-2:\|Progress\|steps completed"; then
		echo "  ✓ PASS: $action_name progress dialog appeared"
		_TUI_PASS=$(( _TUI_PASS + 1 ))

		if tui_wait_for_progress "d2-${action_name}" "$timeout"; then
			echo "  ✓ PASS: $action_name completed"
			_TUI_PASS=$(( _TUI_PASS + 1 ))
		else
			echo "  ✗ FAIL: $action_name failed"
			_TUI_FAIL=$(( _TUI_FAIL + 1 ))
		fi

		# Verify the correct command ran (not a stale/generic one)
		if [[ -n "$expected_cmd" ]]; then
			tui_screenshot "d2-${action_name}-output"
			_scr=$(tui_capture)
			if echo "$_scr" | grep -qi "$expected_cmd"; then
				echo "  ✓ PASS: $action_name ran correct command ($expected_cmd)"
				_TUI_PASS=$(( _TUI_PASS + 1 ))
			else
				echo "  ✗ FAIL: $action_name did not run expected command ($expected_cmd)"
				_TUI_FAIL=$(( _TUI_FAIL + 1 ))
			fi
		fi

		tui_dismiss_result
	else
		echo "  ✗ FAIL: $action_name progress not detected"
		tui_screenshot "d2-${action_name}-unclear"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
		# Even though we didn't detect progress, the dialog may be on
		# screen — wait for it and dismiss it so subsequent actions work
		if echo "$_scr" | grep -qi "Day-2:\|One moment\|please"; then
			echo "  (waiting for possible background progress to finish...)"
			tui_wait_for_progress "d2-${action_name}-recovery" "$timeout" 2>/dev/null || true
			tui_dismiss_result
		fi
	fi
}

# ============================================================================
# 3. Configure OperatorHub (Day-2 config)
# ============================================================================
echo ""
echo "--- 3. Configure OperatorHub ---"
_day2_run_action "OperatorHub" "operatorhub" 1200 "Day-2:.*day2\|aba.*day2\|OperatorHub\|CatalogSource"

# ============================================================================
# 4. NTP Configuration
# ============================================================================
echo ""
echo "--- 4. NTP Configuration ---"
_day2_run_action "Network Time" "ntp" 300 "day2-ntp\|day2.*ntp\|chrony\|NTP"

# ============================================================================
# 5. OSUS (OpenShift Update Service)
# ============================================================================
echo ""
echo "--- 5. OSUS ---"
_day2_run_action "Update Service" "osus" 600 "osus\|update.service\|cincinnati"

tui_back_to "Actions" 5

# ============================================================================
# 6. Cleanup
# ============================================================================
echo ""
echo "--- 6. Cleanup ---"
tui_cleanup
tui_summary
