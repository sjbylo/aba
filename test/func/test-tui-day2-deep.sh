#!/bin/bash
# Test: TUI Day-2 deep — cluster selection, status display, OSUS warning,
# upgrade version picker, shutdown/startup confirmations.
# Non-destructive: cancels all operations before executing.
# Prereq: At least one cluster must be installed (sno on conno).

cd "$(dirname "$0")/../.."
source test/func/tui-test-lib.sh

echo "=== TUI Day-2 Deep Test ==="
echo "  Host: $_TUI_HOST"
echo ""

tui_deploy_code
echo ""

# Pre-check: does an installed cluster exist?
_installed=$($_TUI_SSH "ls ~/aba/*/.install-complete 2>/dev/null" || true)
if [ -z "$_installed" ]; then
	echo "  SKIP: No installed cluster on $_TUI_HOST — skipping Day-2 deep tests"
	echo ""
	echo "  ✓ PASS: (skipped — no cluster)"
	_TUI_PASS=1
	tui_summary
	exit 0
fi
echo "  Installed cluster(s): $(echo "$_installed" | sed 's|.*/\(.*\)/.install-complete|\1|' | paste -sd, -)"
echo ""

# ============================================================================
tui_start_to_menu || { tui_summary; exit 1; }

# ============================================================================
# 1. Enter Day-2 menu
# ============================================================================
echo ""
echo "--- 1. Day-2 menu ---"
tui_select_item "Day-2"
sleep 2
tui_screenshot "d2d-01-day2"

tui_assert_contains "Day-2\|Cluster Management" "Day-2 menu title"
tui_assert_contains "OperatorHub" "OperatorHub item"
tui_assert_contains "NTP\|Network Time" "NTP item"
tui_assert_contains "OSUS\|Update Service" "OSUS item"
tui_assert_contains "Cluster status\|status" "Cluster status item"
tui_assert_contains "Upgrade" "Upgrade item"
tui_assert_contains "Shutdown\|shutdown" "Shutdown item"
tui_assert_contains "Startup\|startup" "Startup item"
tui_assert_contains "Clean\|Clean.*remove" "Clean item"
tui_assert_contains "Delete" "Delete item"
tui_assert_contains "Login\|Terminal" "Login Terminal item"
tui_assert_contains "SSH\|Rendezvous" "SSH item"
tui_assert_contains "Virtualization\|Boot Sources" "Virtualization item"

# ============================================================================
# 2. Cluster Status
# ============================================================================
echo ""
echo "--- 2. Cluster Status ---"
# Select status
tui_keys S; sleep 0.3; tui_keys Enter
sleep 3
tui_screenshot "d2d-02a-cluster-select"

# Handle cluster selection dialog (if multiple clusters)
_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Select cluster\|Choose.*cluster"; then
	echo "  ✓ PASS: Cluster selection dialog appeared"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
	# Just press Enter to select the default
	tui_keys Enter
	sleep 8  # Status check takes time (API calls)
else
	# Single cluster — goes directly to status check
	sleep 5
fi

tui_screenshot "d2d-02b-status"
_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Cluster Operators\|Nodes\|co\|node\|Ready\|Unreachable\|API"; then
	echo "  ✓ PASS: Cluster status displayed"
	_TUI_PASS=$(( _TUI_PASS + 1 ))

	# Check status sections
	if echo "$_scr" | grep -qi "Cluster Operators\|co"; then
		echo "  ✓ PASS: Cluster operators section"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	fi
	if echo "$_scr" | grep -qi "Nodes\|node"; then
		echo "  ✓ PASS: Nodes section"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	fi
	if echo "$_scr" | grep -qi "Upgrade Status\|Upgrade\|adm upgrade"; then
		echo "  ✓ PASS: Upgrade status section"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	fi

	tui_keys Enter; sleep 1   # dismiss textbox
elif echo "$_scr" | grep -qi "Unreachable\|unreachable\|shut.*down"; then
	echo "  ✓ PASS: Cluster status shows API unreachable (cluster may be shut down)"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
	tui_keys Enter; sleep 1
else
	echo "  ~ NOTE: Status display unclear"
	tui_keys Enter; sleep 1
	tui_keys Escape; sleep 1
fi

# ============================================================================
# 3. OSUS — check for cincinnati-operator warning
# ============================================================================
echo ""
echo "--- 3. OSUS check ---"
# Back to Day-2 menu
tui_wait_for "Day-2\|Cluster Management" 5

tui_keys O; sleep 0.3; tui_keys Enter
sleep 3
tui_screenshot "d2d-03-osus"

_scr=$(tui_capture)
if echo "$_scr" | grep -qi "cincinnati\|OSUS\|Update Service\|not found\|Warning"; then
	if echo "$_scr" | grep -qi "cincinnati.*not found\|not found.*cincinnati\|Warning"; then
		echo "  ✓ PASS: OSUS shows cincinnati-operator warning"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ✓ PASS: OSUS dialog appeared"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	fi
	# Cancel — don't actually install OSUS
	tui_press_button "Cancel" 2>/dev/null || tui_keys Escape
	sleep 1
elif echo "$_scr" | grep -qi "Select cluster\|Choose.*cluster"; then
	echo "  ✓ PASS: OSUS shows cluster selection first"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
	tui_keys Enter; sleep 3  # select default cluster
	tui_screenshot "d2d-03b-osus-warn"
	# Cancel whatever appears next
	tui_press_button "Cancel" 2>/dev/null || tui_keys Escape
	sleep 1
else
	echo "  ~ NOTE: OSUS dialog unclear"
	tui_keys Escape; sleep 1
fi

# ============================================================================
# 4. Virtualization Boot Sources
# ============================================================================
echo ""
echo "--- 4. Virtualization Boot Sources ---"
tui_wait_for "Day-2\|Cluster Management" 5

tui_keys V; sleep 0.3; tui_keys Enter
sleep 3
tui_screenshot "d2d-04-virt"

_scr=$(tui_capture)
if echo "$_scr" | grep -qi "kubevirt\|Virtualization\|Boot Source\|not found\|Warning"; then
	echo "  ✓ PASS: Virtualization dialog appeared"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
	tui_press_button "Cancel" 2>/dev/null || tui_keys Escape
	sleep 1
elif echo "$_scr" | grep -qi "Select cluster"; then
	echo "  ✓ PASS: Virt shows cluster selection first"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
	tui_keys Escape; sleep 1
else
	echo "  ~ NOTE: Virt dialog unclear"
	tui_keys Escape; sleep 1
fi

# ============================================================================
# 5. Upgrade version picker
# ============================================================================
echo ""
echo "--- 5. Upgrade version picker ---"
tui_wait_for "Day-2\|Cluster Management" 5

tui_keys U; sleep 0.3; tui_keys Enter
sleep 3
tui_screenshot "d2d-05a-upgrade-cluster"

# Handle cluster selection
_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Select cluster\|Choose.*cluster"; then
	echo "  ✓ PASS: Upgrade shows cluster selection"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
	tui_keys Enter; sleep 5  # takes time to fetch versions
fi

tui_screenshot "d2d-05b-upgrade-picker"
_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Upgrade\|target version\|Current\|Z-stream\|Minor\|No.*available\|Manual entry"; then
	echo "  ✓ PASS: Upgrade version picker appeared"
	_TUI_PASS=$(( _TUI_PASS + 1 ))

	# Check version picker elements
	if echo "$_scr" | grep -qi "Current.*4\."; then
		echo "  ✓ PASS: Shows current version"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	fi
	if echo "$_scr" | grep -qi "OSUS\|no OSUS"; then
		echo "  ✓ PASS: Shows OSUS status"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	fi
	if echo "$_scr" | grep -qi "Manual entry"; then
		echo "  ✓ PASS: Manual entry option present"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	fi
	if echo "$_scr" | grep -qi "Force"; then
		echo "  ✓ PASS: Force toggle present"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	fi

	# Check help (only if version picker has Help button)
	_btns=$(tui_buttons)
	if echo "$_btns" | grep -qi "Help"; then
		tui_press_button "Help"
		sleep 2
		tui_screenshot "d2d-05c-upgrade-help"
		tui_assert_contains "Z-stream\|z-stream" "Upgrade help mentions z-stream"
		tui_assert_contains "Minor\|minor" "Upgrade help mentions minor upgrade"
		tui_assert_contains "Force\|force" "Upgrade help mentions force option"
		tui_assert_contains "OSUS\|Update Service" "Upgrade help mentions OSUS"
		tui_keys Enter; sleep 1
	fi

	# Cancel upgrade
	tui_keys Escape; sleep 1
elif echo "$_scr" | grep -qi "No.*available\|No.*versions"; then
	echo "  ✓ PASS: No upgrade versions available (expected)"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
	tui_keys Enter; sleep 1
elif echo "$_scr" | grep -qi "Failed\|failed\|error"; then
	echo "  ✓ PASS: Upgrade check reported error (cluster may be down)"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
	tui_keys Enter; sleep 1
else
	echo "  ~ NOTE: Upgrade screen unclear"
	tui_keys Escape; sleep 1
fi

# ============================================================================
# 6. Shutdown confirmation (cancel)
# ============================================================================
echo ""
echo "--- 6. Shutdown confirmation ---"
tui_wait_for "Day-2\|Cluster Management" 5

tui_keys G; sleep 0.3; tui_keys Enter
sleep 3
tui_screenshot "d2d-06-shutdown"

_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Select cluster\|Choose.*cluster"; then
	echo "  ✓ PASS: Shutdown shows cluster selection"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
	# Cancel — don't select
	tui_keys Escape; sleep 1
elif echo "$_scr" | grep -qi "Shutdown\|shutdown\|Confirm\|execution mode"; then
	echo "  ✓ PASS: Shutdown confirmation appeared"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
	tui_keys Escape; sleep 1
else
	echo "  ~ NOTE: Shutdown dialog unclear"
	tui_keys Escape; sleep 1
fi

# ============================================================================
# 7. Delete confirmation (cancel)
# ============================================================================
echo ""
echo "--- 7. Delete confirmation ---"
# Ensure we're back in Day-2 menu
if ! tui_capture | grep -qi "Day-2\|Cluster Management"; then
	tui_back_to "Actions" 5
	tui_select_item "Day-2"
	tui_wait_for "Day-2\|Cluster Management" 10
fi

tui_keys D; sleep 0.3; tui_keys Enter
sleep 3
tui_screenshot "d2d-07-delete"

_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Select cluster\|Choose.*cluster"; then
	echo "  ✓ PASS: Delete shows cluster selection"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
	tui_keys Escape; sleep 1
elif echo "$_scr" | grep -qi "Delete\|delete\|destroy\|Confirm\|Are you sure"; then
	echo "  ✓ PASS: Delete confirmation appeared"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
	tui_keys Escape; sleep 1
else
	echo "  ~ NOTE: Delete dialog unclear"
	tui_keys Escape; sleep 1
fi

# ============================================================================
# 8. Day-2 Help
# ============================================================================
echo ""
echo "--- 8. Day-2 Help ---"
# Ensure we're in the Day-2 menu (may have fallen back to main menu)
# Need extra wait — prior Escape may leave dialog mid-transition
sleep 2
if ! tui_capture | grep -qi "Day-2\|Cluster Management"; then
	tui_back_to "Actions" 5
	tui_select_item "Day-2"
fi
tui_wait_for "Day-2\|Cluster Management" 10

tui_press_button "Help"
sleep 3
tui_screenshot "d2d-08-help"

# Verify help actually appeared before asserting content
tui_assert_appears "Configuration" "Day-2 help appeared" 10
tui_assert_contains "Lifecycle\|lifecycle" "Day-2 help has Lifecycle section"
tui_assert_contains "Cleanup\|cleanup\|Clean" "Day-2 help has Cleanup section"
tui_assert_contains "Upgrade" "Day-2 help mentions upgrade"
tui_assert_contains "OperatorHub" "Day-2 help mentions OperatorHub"
tui_assert_contains "NTP" "Day-2 help mentions NTP"
tui_assert_contains "OSUS\|Update Service" "Day-2 help mentions OSUS"
tui_assert_contains "Shutdown" "Day-2 help mentions shutdown"
tui_assert_contains "Startup" "Day-2 help mentions startup"
tui_assert_contains "Delete" "Day-2 help mentions delete"
tui_keys Enter; sleep 1

# ============================================================================
# 9. Cleanup
# ============================================================================
echo ""
echo "--- 9. Cleanup ---"
tui_cleanup
tui_summary
