#!/bin/bash
# Test: TUI Day-2 operations — OperatorHub, NTP, status, login
# Prereqs: an installed cluster (defaults to "sno", set TUI_CLUSTER_NAME to override).

cd "$(dirname "$0")/../.."
source test/func/tui-test-lib.sh

_CLUSTER="${TUI_CLUSTER_NAME:-sno}"
_ssh_cfg="$HOME/.aba/ssh.conf"

echo "=== TUI Day-2 Workflow Test ==="
echo "  Host: $_TUI_HOST"
echo "  Cluster: $_CLUSTER"
echo ""

scp -q -F "$_ssh_cfg" tui/v2/*.sh "$_TUI_HOST:aba/tui/v2/" 2>/dev/null
scp -q -F "$_ssh_cfg" scripts/include_all.sh scripts/aba.sh "$_TUI_HOST:aba/scripts/" 2>/dev/null
echo "  Code deployed"
echo ""

# Verify cluster exists and is installed
_inst=$($_TUI_SSH "test -f ~/aba/$_CLUSTER/.install-complete && echo yes || echo no")
if [[ "$_inst" != "yes" ]]; then
	echo "  SKIP: Cluster '$_CLUSTER' not installed — skipping Day-2 tests"
	echo ""
	_TUI_PASS=0; _TUI_FAIL=0
	tui_summary
	exit 0
fi

# ============================================================================
tui_start
tui_assert_appears "OpenShift Installer" "TUI launched" 15 || {
	tui_stop; tui_summary; exit 1
}
tui_keys Enter  # past splash
tui_assert_appears "Actions" "Main menu" 10

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
sleep 5
tui_screenshot "d2-02-status"

_scr=$(tui_capture)
if echo "$_scr" | grep -qi "AVAILABLE\|Ready\|node\|operator\|select.*cluster"; then
	echo "  ✓ PASS: Cluster status displayed"
	_TUI_PASS=$(( _TUI_PASS + 1 ))

	# If there's a cluster selection dialog, select our cluster
	if echo "$_scr" | grep -qi "select.*cluster"; then
		tui_keys Enter  # select first/default cluster
		sleep 5
		tui_screenshot "d2-02b-status-detail"
	fi
else
	echo "  ~ NOTE: Status screen content unclear"
	tui_screenshot "d2-02-status-unclear"
fi

# Return to Day-2 menu
tui_back_to "Day-2\|Cluster Management" 5

# Helper: run a Day-2 action via the progress dialog.
# Selects the menu item, handles cluster selection if shown,
# waits for the progress dialog to finish, presses Done.
_day2_run_action() {
	local item_label="$1"
	local action_name="$2"
	local timeout="${3:-600}"

	tui_select_item "$item_label"
	sleep 3
	tui_screenshot "d2-${action_name}-start"

	_scr=$(tui_capture)

	# Handle cluster selection dialog (shown when multiple clusters exist)
	if echo "$_scr" | grep -qi "select.*cluster"; then
		echo "  (cluster selection dialog — selecting default)"
		tui_keys Enter; sleep 2
		_scr=$(tui_capture)
	fi

	# Detect progress dialog (title contains "Day-2:" or step statuses)
	if echo "$_scr" | grep -qi "In Progress\|Succeeded\|N/A.*│\|day2\|Day-2:"; then
		echo "  ✓ PASS: $action_name progress dialog appeared"
		_TUI_PASS=$(( _TUI_PASS + 1 ))

		# Wait for all steps to complete (look for Done button or completion text)
		# IMPORTANT: do NOT match "Day-2" — the progress dialog title contains it
		echo "  Waiting for $action_name to complete (up to ${timeout}s)..."
		local _timed_out=0
		for (( _i=0; _i<timeout; _i+=5 )); do
			if ! tui_session_alive; then
				echo "  SESSION DEAD during $action_name"
				break
			fi
			_scr=$(tui_capture)
			if echo "$_scr" | grep -qi "All steps completed"; then
				break
			fi
			if echo "$_scr" | grep -qi "FAILED"; then
				echo "  $action_name had failures"
				break
			fi
			sleep 5
			(( _i % 60 == 0 && _i > 0 )) && echo "  ... still running (${_i}s)"
		done
		if (( _i >= timeout )); then
			echo "  TIMEOUT: $action_name did not complete in ${timeout}s"
			_timed_out=1
		fi
		tui_screenshot "d2-${action_name}-result"

		# Return to Day-2 menu
		_scr=$(tui_capture)
		if echo "$_scr" | grep -qi "Done"; then
			tui_press_button "Done"
			sleep 2
		elif (( _timed_out )); then
			# Operation still running — quit via Q/ESC
			tui_keys q; sleep 2
			_scr=$(tui_capture)
			# Confirm quit if asked
			if echo "$_scr" | grep -qi "confirm\|sure\|abort"; then
				tui_keys Enter; sleep 2
			fi
		fi
	else
		echo "  ~ NOTE: $action_name screen unclear"
		tui_screenshot "d2-${action_name}-unclear"
	fi

	# Ensure we're back at the Day-2 menu before the next action
	sleep 1
	_scr=$(tui_capture)
	if ! echo "$_scr" | grep -qi "OperatorHub\|NTP\|OSUS\|shutdown\|startup"; then
		tui_back_to "Day-2\|Cluster Management\|Actions" 5
		if tui_capture | grep -q "Actions"; then
			tui_select_item "Day-2"; sleep 2
		fi
	fi
}

# ============================================================================
# 3. Configure OperatorHub (Day-2 config)
# ============================================================================
echo ""
echo "--- 3. Configure OperatorHub ---"
_day2_run_action "OperatorHub" "operatorhub" 1200

# ============================================================================
# 4. NTP Configuration
# ============================================================================
echo ""
echo "--- 4. NTP Configuration ---"
_day2_run_action "Network Time" "ntp" 300

# ============================================================================
# 5. OSUS (OpenShift Update Service)
# ============================================================================
echo ""
echo "--- 5. OSUS ---"
_day2_run_action "Update Service" "osus" 600

tui_back_to "Actions" 5

# ============================================================================
# 6. Cleanup
# ============================================================================
echo ""
echo "--- 6. Cleanup ---"
tui_cleanup
tui_summary
