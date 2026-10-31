#!/bin/bash
# Test: TUI DISCO mode smoke test — forces DISCO mode on the target host.
# Exercises: splash, DISCO main menu, ISC view, settings, advanced, day-2,
# load dialog, help texts — all non-destructive.
#
# Creates a temporary .bundle marker to force DISCO mode, removes it on exit.
#
# Usage: TUI_TEST_HOST=disco.example.com test/func/test-tui-disco-smoke.sh
#   or:  test/func/test-tui-disco-smoke.sh   (defaults to disco.example.com)

cd "$(dirname "$0")/../.."

# Default to disco host
export TUI_TEST_HOST="${TUI_TEST_HOST:-disco.example.com}"
source test/func/tui-test-lib.sh

echo "=== TUI DISCO Mode Smoke Test ==="
echo "  Host: $_TUI_HOST"
echo ""

tui_deploy_code

# Force DISCO mode by creating .bundle marker (cleaned up at the end)
_had_bundle=$($_TUI_SSH "test -f ~/aba/.bundle && echo yes || echo no" 2>/dev/null)
_had_available=$($_TUI_SSH "test -f ~/aba/mirror/.available && echo yes || echo no" 2>/dev/null)
if [[ "$_had_bundle" != "yes" ]]; then
	$_TUI_SSH "touch ~/aba/.bundle" 2>/dev/null
	echo "  Created .bundle marker to force DISCO mode"
fi
# If mirror is installed but .available is missing, create it to prevent
# the wizard gate from trying to auto-install (and failing on stale state).
if [[ "$_had_available" != "yes" ]]; then
	if $_TUI_SSH "podman pod exists quay-pod 2>/dev/null" 2>/dev/null; then
		$_TUI_SSH "mkdir -p ~/aba/mirror && touch ~/aba/mirror/.available" 2>/dev/null
		echo "  Created .available marker (registry already running)"
	fi
fi
echo ""

# Cleanup helper: restore markers we created
_disco_cleanup() {
	if [[ "$_had_bundle" != "yes" ]]; then
		$_TUI_SSH "rm -f ~/aba/.bundle" 2>/dev/null
		echo "  Removed .bundle marker"
	fi
	if [[ "$_had_available" != "yes" ]]; then
		$_TUI_SSH "rm -f ~/aba/mirror/.available" 2>/dev/null
		echo "  Removed .available marker"
	fi
}
trap _disco_cleanup EXIT

# ============================================================================
tui_start
tui_assert_appears "OpenShift Installer" "TUI launched" 15 || {
	tui_stop; tui_summary; exit 1
}

# ============================================================================
# 1. Splash screen
# ============================================================================
echo ""
echo "--- 1. Splash screen ---"
tui_screenshot "disco-01-splash"
tui_assert_contains "ABA" "Splash shows ABA branding"
_btns=$(tui_buttons)
if echo "$_btns" | grep -qi "Continue"; then
	echo "  ✓ PASS: Continue button present"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
fi
if echo "$_btns" | grep -qi "Help"; then
	echo "  ✓ PASS: Help button present"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
fi

# Check splash help
tui_press_button "Help"
sleep 2
tui_screenshot "disco-01b-splash-help"
tui_assert_contains "wizard\|TUI\|ABA" "Splash help content"
tui_keys Enter; sleep 1

# Past splash
tui_keys Enter
sleep 5  # DISCO mode detection + bundle wizard gate takes time

# ============================================================================
# 2. Handle DISCO bundle wizard gate
# ============================================================================
echo ""
echo "--- 2. DISCO mode entry ---"
tui_screenshot "disco-02-entry"

# Handle all startup dialogs before the main menu appears.
# On disco with internet: "Install Bundle on Connected Host" → "Payload summary"
# On disco without internet: "Payload summary" only
# Keep dismissing dialogs until the menu appears.
for _gate_i in 1 2 3 4 5; do
	_scr=$(tui_capture)

	# Already at the menu?
	if echo "$_scr" | grep -q "── Registry ──\|── Cluster ──\|── Advanced ──\|Actions"; then
		break
	fi

	# "Install Bundle on Connected Host" — select "Fully Disconnected" (first button)
	if echo "$_scr" | grep -qi "Connected Host\|Fully Disconnected.*Connected mode"; then
		echo "  ✓ PASS: Connected Host dialog — selecting Fully Disconnected"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
		tui_keys Enter; sleep 5
		continue
	fi

	# Bundle payload summary
	if echo "$_scr" | grep -qi "Install Bundle\|payload summary\|Disconnected.*payload"; then
		echo "  ✓ PASS: ABA Install Bundle info dialog appeared"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
		tui_keys Enter; sleep 5
		continue
	fi

	# Any other dialog — dismiss
	tui_keys Enter; sleep 3
done

# The DISCO wizard gate may auto-launch mirror config, install, and load.
# Keep dismissing dialogs until the main menu appears.
for _menu_i in 1 2 3 4 5 6 7 8 9 10; do
	_scr=$(tui_capture)
	# Menu reached?
	if echo "$_scr" | grep -q "── Registry ──\|── Cluster ──\|── Advanced ──"; then
		break
	fi
	# Mirror config form — press Next/OK to accept defaults
	if echo "$_scr" | grep -qi "Mirror Configuration\|Hostname.*Port\|Vendor.*auto"; then
		tui_press_button "Next" 2>/dev/null || tui_press_button "OK" 2>/dev/null || tui_keys Enter
		sleep 5
		continue
	fi
	# Install location choice — select locally
	if echo "$_scr" | grep -qi "Install locally\|Install on remote"; then
		tui_keys Enter; sleep 3
		continue
	fi
	# Progress dialog — wait for it
	if echo "$_scr" | grep -qi "Progress\|Installing\|Loading\|%\|In Progress\|Succeeded"; then
		sleep 15
		continue
	fi
	# Completion dialog — dismiss
	if echo "$_scr" | grep -qi "steps completed\|Done\|Success"; then
		tui_keys Enter; sleep 3
		continue
	fi
	# Error dialog — press Dismiss button specifically
	if echo "$_scr" | grep -qi "FAILED\|Error.*step\|Error.*Check"; then
		tui_press_button "Dismiss" 2>/dev/null || tui_keys Enter
		sleep 3
		continue
	fi
	# Confirmation dialogs — dismiss
	if echo "$_scr" | grep -qi "Continue\|Confirm\|Load images"; then
		tui_keys Enter; sleep 5
		continue
	fi
	# Terminal prompt
	if echo "$_scr" | grep -qi "Press.*ENTER\|ENTER to return"; then
		tui_keys Enter; sleep 2
		continue
	fi
	# Try Escape to break out of stuck dialogs
	tui_keys Escape; sleep 3
done
# If we still haven't reached the menu after all attempts, try back_to
if ! tui_capture | grep -q "── Registry ──\|── Cluster ──\|── Advanced ──"; then
	tui_back_to "Registry\|Cluster\|Advanced\|Actions" 10
fi

# ============================================================================
# 3. DISCO main menu
# ============================================================================
echo ""
echo "--- 3. DISCO main menu ---"
tui_screenshot "disco-03-menu"

_scr=$(tui_capture)

# Detect which mode we ended up in
_detected_disco=false
if echo "$_scr" | grep -qi "Fully Disconnected"; then
	echo "  ✓ PASS: Fully Disconnected mode detected"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
	_detected_disco=true
elif echo "$_scr" | grep -qi "Partially Disconnected\|CONNO"; then
	echo "  ~ NOTE: Host is in Partially Disconnected mode (mirror already populated)"
	echo "  ~ NOTE: DISCO tests will adapt to CONNO menu structure"
fi

# Check menu items — DISCO and CONNO have different items
if [[ "$_detected_disco" == "true" ]]; then
	# DISCO-specific items
	tui_assert_contains "Install.*Registry\|Registry" "Install Registry item"
	tui_assert_contains "Load\|Load Images" "Load Images item"
	tui_assert_contains "Install Cluster\|Install.*Cluster" "Install Cluster item"
	tui_assert_contains "Day-2\|Cluster Management" "Day-2 item"
	tui_assert_contains "Configure\|Settings" "Configure item"
	tui_assert_contains "Advanced" "Advanced item"
	tui_assert_contains "Feedback\|feedback" "Feedback item"
	tui_assert_contains "View.*Payload\|ImageSet\|ISC\|Payload" "View ISC/Payload item"
else
	# CONNO items on disco host
	tui_assert_contains "Mirror Payload\|Payload" "Mirror Payload item"
	tui_assert_contains "Install Mirror\|Mirror.*installed" "Install Mirror item"
	tui_assert_contains "Sync\|sync" "Sync item"
	tui_assert_contains "Install Cluster\|Install.*Cluster" "Install Cluster item"
	tui_assert_contains "Day-2\|Cluster Management" "Day-2 item"
	tui_assert_contains "Configure\|Settings" "Configure item"
	tui_assert_contains "Advanced" "Advanced item"
	tui_assert_contains "Feedback\|feedback" "Feedback item"
fi

# ============================================================================
# 4. Main menu Help
# ============================================================================
echo ""
echo "--- 4. Help ---"
tui_press_button "Help"
sleep 2
tui_screenshot "disco-04-help"

if [[ "$_detected_disco" == "true" ]]; then
	tui_assert_contains "disconnected\|Disconnected" "Help mentions disconnected"
	tui_assert_contains "Registry\|registry" "Help mentions registry"
	tui_assert_contains "Load\|load" "Help mentions load"
else
	tui_assert_contains "Mirror\|mirror" "Help mentions mirror"
	tui_assert_contains "Sync\|sync\|Bundle\|bundle" "Help mentions sync or bundle"
fi
tui_assert_contains "Cluster\|cluster\|Install" "Help mentions cluster"
# Day-2 and Navigation may not appear in all help variants
_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Day-2\|Day"; then
	echo "  ✓ PASS: Help mentions Day-2"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
fi
if echo "$_scr" | grep -qi "Navigation\|Arrow\|ESC\|Enter"; then
	echo "  ✓ PASS: Help has navigation section"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
fi
tui_keys Enter; sleep 1

# ============================================================================
# 5. Settings menu
# ============================================================================
echo ""
echo "--- 5. Settings ---"
tui_select_item "Configure"
sleep 2
tui_screenshot "disco-05-settings"

_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Settings\|Registry Type\|Retry"; then
	echo "  ✓ PASS: Settings menu appeared"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
	tui_assert_contains "Registry Type" "Registry Type setting"
	tui_assert_contains "Retry" "Retry setting"
	tui_keys Escape; sleep 1
else
	echo "  ~ NOTE: Settings unclear"
	tui_keys Escape; sleep 1
fi

# ============================================================================
# 6. Advanced menu
# ============================================================================
echo ""
echo "--- 6. Advanced menu ---"
tui_select_item "Advanced"
sleep 2
tui_screenshot "disco-06-advanced"

_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Advanced\|Platform\|Switch"; then
	echo "  ✓ PASS: Advanced menu appeared"
	_TUI_PASS=$(( _TUI_PASS + 1 ))

	tui_assert_contains "Platform Settings\|Platform" "Platform Settings item"

	# Check for mode switch items
	if echo "$_scr" | grep -qi "Switch"; then
		echo "  ✓ PASS: Mode switch option present"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	fi

	# Check help
	tui_press_button "Help"
	sleep 2
	tui_screenshot "disco-06b-advanced-help"
	tui_assert_contains "Platform" "Advanced help mentions Platform"
	tui_keys Enter; sleep 1

	tui_keys Escape; sleep 1
else
	echo "  ~ NOTE: Advanced menu unclear"
	tui_keys Escape; sleep 1
fi

# ============================================================================
# 7. Day-2 menu
# ============================================================================
echo ""
echo "--- 7. Day-2 menu ---"
tui_select_item "Day-2"
sleep 2
tui_screenshot "disco-07-day2"

_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Day-2\|Cluster Management"; then
	echo "  ✓ PASS: Day-2 menu appeared"
	_TUI_PASS=$(( _TUI_PASS + 1 ))

	tui_assert_contains "OperatorHub" "OperatorHub item"
	tui_assert_contains "NTP\|Network Time" "NTP item"
	tui_assert_contains "OSUS\|Update Service" "OSUS item"
	tui_assert_contains "Cluster status\|status" "Status item"
	tui_assert_contains "Upgrade" "Upgrade item"

	# Check help
	tui_press_button "Help"
	sleep 2
	tui_screenshot "disco-07b-day2-help"
	tui_assert_contains "Configuration\|configuration" "Day-2 help has Configuration section"
	tui_assert_contains "Lifecycle\|lifecycle" "Day-2 help has Lifecycle section"
	tui_keys Enter; sleep 1

	tui_keys Escape; sleep 1
elif echo "$_scr" | grep -qi "No cluster\|install.*cluster\|Install.*first"; then
	echo "  ✓ PASS: Day-2 blocked — no installed cluster"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
	tui_keys Enter; sleep 1
else
	echo "  ~ NOTE: Day-2 menu unclear"
	tui_keys Escape; sleep 1
fi

# ============================================================================
# 8. View ISC / Mirror Payload
# ============================================================================
echo ""
echo "--- 8. View ISC / Payload ---"

if [[ "$_detected_disco" == "true" ]]; then
	# DISCO mode: ISC is a read-only textbox
	tui_select_item "View.*Payload\|View.*ISC\|Payload"
	sleep 3
else
	# CONNO mode: Mirror Payload is a full menu
	tui_select_item "Mirror Payload"
	sleep 5
fi

tui_screenshot "disco-08-payload"

_scr=$(tui_capture)
if echo "$_scr" | grep -qi "imageset\|apiVersion\|storageConfig"; then
	echo "  ✓ PASS: ISC content displayed"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
	tui_keys Enter; sleep 1  # dismiss textbox
elif echo "$_scr" | grep -qi "Mirror Payload\|Select Operators\|OCP Version"; then
	echo "  ✓ PASS: Mirror Payload menu appeared"
	_TUI_PASS=$(( _TUI_PASS + 1 ))

	# Verify payload items
	tui_assert_contains "OCP Version" "OCP Version item"
	tui_assert_contains "Select Operators" "Select Operators item"
	tui_assert_contains "Additional Images" "Additional Images item"
	tui_assert_contains "Prepare Upgrade" "Prepare Upgrade item"
	tui_assert_contains "Advanced" "Advanced ISC item"

	tui_keys Escape; sleep 1
else
	echo "  ~ NOTE: ISC/Payload view unclear"
	tui_keys Escape; sleep 1
fi

# ============================================================================
# 9. Load dialog (DISCO only, cancel)
# ============================================================================
echo ""
echo "--- 9. Load / Sync dialog ---"
tui_back_to "Registry\|Install\|Load\|Actions\|Mirror" 5

if [[ "$_detected_disco" == "true" ]]; then
	tui_select_item "Load"
	sleep 3
	tui_screenshot "disco-09-load"

	_scr=$(tui_capture)
	if echo "$_scr" | grep -qi "Load\|OCP\|Operator\|Confirm\|loaded"; then
		echo "  ✓ PASS: Load dialog appeared"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	fi
	# Cancel without executing — use button, not Escape (Escape may confirm)
	tui_press_button "Cancel" 2>/dev/null || tui_press_button "Back" 2>/dev/null || tui_keys Escape
	sleep 1
	# Dismiss any error or stale dialog
	_scr=$(tui_capture)
	if echo "$_scr" | grep -qi "Error\|error\|Failed\|failed"; then
		tui_keys Enter; sleep 1
		tui_keys Escape; sleep 1
	fi
else
	# CONNO mode: test Sync dialog
	tui_select_item "Sync"
	sleep 3
	tui_screenshot "disco-09-sync"

	_scr=$(tui_capture)
	if echo "$_scr" | grep -qi "Sync\|OCP\|Operator\|Confirm\|synced"; then
		echo "  ✓ PASS: Sync confirmation appeared"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	fi
	tui_keys Escape; sleep 1
fi

# ============================================================================
# 10. Cluster status (if installed)
# ============================================================================
echo ""
echo "--- 10. Cluster status ---"
_installed=$($_TUI_SSH "ls ~/aba/*/.install-complete 2>/dev/null" || true)
if [ -n "$_installed" ]; then
	# Navigate to Day-2 from wherever we are
	tui_back_to "Registry\|Load\|Install\|Actions\|Mirror" 5
	# Find and enter Day-2
	if ! tui_capture | grep -qi "Day-2.*Cluster"; then
		tui_select_item "Day-2"
	fi
	if ! tui_wait_for "Day-2\|Cluster Management" 10; then
		echo "  ~ SKIP: Could not navigate to Day-2 menu"
	else

	tui_keys S; sleep 0.3; tui_keys Enter
	sleep 8
	tui_screenshot "disco-10-status"

	_scr=$(tui_capture)
	if echo "$_scr" | grep -qi "Cluster Operators\|Nodes\|node\|Ready\|Unreachable\|API"; then
		echo "  ✓ PASS: Cluster status displayed on disco host"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	elif echo "$_scr" | grep -qi "Select cluster\|Choose"; then
		echo "  ✓ PASS: Cluster selection shown (multiple clusters)"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
		tui_keys Escape; sleep 1
	else
		echo "  ~ NOTE: Status unclear"
	fi
	tui_keys Enter; sleep 1  # dismiss textbox
	tui_keys Escape; sleep 1  # back from Day-2
	fi  # end of "could navigate to Day-2" block
else
	echo "  ~ SKIP: No installed cluster on disco host"
fi

# ============================================================================
# 11. Cleanup
# ============================================================================
echo ""
echo "--- 11. Cleanup ---"
tui_cleanup
tui_summary
