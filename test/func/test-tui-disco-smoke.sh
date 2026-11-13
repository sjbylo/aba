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

# Force DISCO only when a real payload exists (imageset + mirror_*.tar).
# After a host wipe, .bundle alone → "Bundle incomplete" or "Image Archives
# Needed" → Exit kills the TUI. Smoke then runs in native CONNO mode (lab
# disco has internet). DISCO Workflow covers the full air-gap path.
_had_bundle=$($_TUI_SSH "test -f ~/aba/.bundle && echo yes || echo no" 2>/dev/null)
_had_available=$($_TUI_SSH "test -f ~/aba/mirror/.available && echo yes || echo no" 2>/dev/null)
_has_archives=$($_TUI_SSH "ls ~/aba/mirror/data/mirror_*.tar >/dev/null 2>&1 && echo yes || echo no" 2>/dev/null)
_has_isc=$($_TUI_SSH "test -s ~/aba/mirror/data/imageset-config.yaml && echo yes || echo no" 2>/dev/null)
_force_disco=no
if [[ "$_has_archives" == "yes" && "$_has_isc" == "yes" ]]; then
	_force_disco=yes
	if [[ "$_had_bundle" != "yes" ]]; then
		$_TUI_SSH "touch ~/aba/.bundle" 2>/dev/null
		echo "  Created .bundle marker to force DISCO mode (archives present)"
	fi
else
	echo "  No mirror archives on disco — smoke runs in native mode (no forced .bundle)"
	# Drop a stale .bundle left from a prior wipe so TUI does not abort
	if [[ "$_had_bundle" == "yes" && "$_has_archives" != "yes" ]]; then
		$_TUI_SSH "rm -f ~/aba/.bundle" 2>/dev/null
		echo "  Removed stale .bundle (no archives)"
		_had_bundle=no
	fi
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
	if [[ "$_force_disco" == "yes" && "$_had_bundle" != "yes" ]]; then
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

	# Light bundle / wipe: no mirror_*.tar — Exit and continue in native mode
	if echo "$_scr" | grep -qi "Image Archives Needed\|mirror_\*\.tar\|light\* install bundle"; then
		echo "  Image Archives Needed — Exit to native mode (Workflow transfers archives)"
		tui_press_button "Exit" 2>/dev/null || tui_keys Tab Enter
		sleep 2
		$_TUI_SSH "rm -f ~/aba/.bundle" 2>/dev/null || true
		tui_stop 2>/dev/null || true
		tui_start
		tui_keys Enter; sleep 3
		continue
	fi

	# Bundle incomplete after wipe
	if echo "$_scr" | grep -qi "Cannot Proceed\|Bundle incomplete\|no imageset-config"; then
		echo "  Bundle incomplete — clearing .bundle and relaunching native"
		tui_keys Enter; sleep 1
		$_TUI_SSH "rm -f ~/aba/.bundle" 2>/dev/null || true
		tui_stop 2>/dev/null || true
		tui_start
		tui_keys Enter; sleep 3
		continue
	fi

	# Bundle payload summary (title "ABA Install Bundle", not "install bundle was detected")
	if echo "$_scr" | grep -qi "ABA Install Bundle\|payload summary\|Disconnected.*payload summary"; then
		echo "  ✓ PASS: ABA Install Bundle info dialog appeared"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
		tui_keys Enter; sleep 5
		continue
	fi

	# Any other dialog — dismiss
	tui_keys Enter; sleep 3
done

# The DISCO wizard gate may auto-launch mirror config, install, and load.
# Smoke is non-destructive: a full image load takes hours, so Quit long-running
# Load/Install progress and land on the main menu. DISCO Workflow covers load.
for _menu_i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
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
	# Load (or long install) progress — Quit so smoke can exercise the menu.
	# Wizard shows "One moment please" first, then the progress frame with Quit.
	if echo "$_scr" | grep -qiE "Load images to mirror|Overall Progress|One moment please"; then
		if echo "$_scr" | grep -qiE "Quit.*Q|Q/ESC|In Progress"; then
			echo "  Wizard auto-load/install in progress — Quitting for smoke (Workflow covers load)"
			tui_keys q; sleep 1
			_scr=$(tui_capture)
			if echo "$_scr" | grep -qiE "Stopped|Dismiss|Continue"; then
				tui_press_button "Dismiss" 2>/dev/null || tui_keys Enter
				sleep 2
			fi
			continue
		fi
		# Spinner before progress keys exist — wait briefly for Quit to appear
		sleep 3
		continue
	fi
	# Short registry install progress — wait a bit
	if echo "$_scr" | grep -qi "Progress\|Installing\|Loading\|%\|In Progress\|Succeeded"; then
		sleep 10
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
	# Confirmation dialogs — dismiss (Enter accepts Load; smoke will Quit progress above)
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
# If we still haven't reached the menu after all attempts, try back_to / Quit once more
if ! tui_capture | grep -q "── Registry ──\|── Cluster ──\|── Advanced ──"; then
	_scr=$(tui_capture)
	if echo "$_scr" | grep -qiE "Overall Progress|Load images to mirror|Quit.*Q"; then
		tui_keys q; sleep 1
		tui_press_button "Dismiss" 2>/dev/null || tui_keys Enter
		sleep 2
	fi
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
	echo "  ✓ PASS: Host is in Partially Disconnected mode — adapting to CONNO menu structure"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
fi

# Check menu items — DISCO and CONNO have different items
tui_assert_title "Disconnected\|Connected\|Actions" "DISCO main menu title"

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
	echo "  ✗ FAIL: Settings unclear"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
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
	echo "  ✗ FAIL: Advanced menu unclear"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
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
	echo "  ✗ FAIL: Day-2 menu unclear"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
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
	echo "  ✗ FAIL: ISC/Payload view unclear"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
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
		echo "  ✗ FAIL: Could not navigate to Day-2 menu on disco host"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	else

	# Prefer full label — bare "status" can miss when focus is on OK.
	# Retry if we are still on the Day-2 menu.
	_left_menu=0
	for _try in 1 2 3; do
		if ! tui_select_item "Cluster status\|Status"; then
			tui_keys S; sleep 0.3; tui_keys Enter
		fi
		sleep 2
		_scr=$(tui_capture)
		if ! echo "$_scr" | grep -qi "Cluster Management\|Select operation"; then
			_left_menu=1
			break
		fi
		echo "  Still on Day-2 menu after status select (try $_try) — retrying"
		# Move focus back into the list before the next hotkey attempt
		tui_keys Up; sleep 0.2
	done
	if [[ "$_left_menu" -ne 1 ]]; then
		echo "  ✗ FAIL: Could not open Cluster status from Day-2 menu"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
		tui_screenshot "disco-10-status-still-menu"
	else
	tui_pick_cluster "${TUI_CLUSTER_NAME:-sno}" 2>/dev/null || tui_dismiss_cluster_select || true
	_status_ok=0
	for _sw in $(seq 1 45); do
		_scr=$(tui_capture)
		if echo "$_scr" | grep -qiE "Select cluster|select.*cluster|Detecting installation"; then
			tui_pick_cluster "${TUI_CLUSTER_NAME:-sno}" 2>/dev/null || true
			sleep 1
			continue
		fi
		if echo "$_scr" | grep -qi "Fetching status"; then
			sleep 2
			continue
		fi
		if echo "$_scr" | grep -qi "Cluster Operators\|Nodes\|node\|Ready\|Unreachable\|API\|AVAILABLE\|One moment please"; then
			_status_ok=1
			break
		fi
		# Returned to Day-2 unexpectedly
		if echo "$_scr" | grep -qi "Cluster Management\|Select operation"; then
			echo "  WARNING: back on Day-2 during status wait (iter $_sw)"
			tui_select_item "status" || { tui_keys S; sleep 0.3; tui_keys Enter; }
			sleep 2
			continue
		fi
		sleep 2
	done
	tui_screenshot "disco-10-status"
	if [[ "$_status_ok" -eq 1 ]]; then
		echo "  ✓ PASS: Cluster status displayed on disco host"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ✗ FAIL: Status unclear on disco host"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
		tui_screenshot "disco-10-status-unclear"
	fi
	tui_keys Enter; sleep 1  # dismiss textbox
	fi  # end of left-menu block
	tui_keys Escape; sleep 1  # back from Day-2
	fi  # end of "could navigate to Day-2" block
else
	echo "  ✓ PASS: No installed cluster on disco host (status N/A)"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
fi

# ============================================================================
# 11. Cleanup
# ============================================================================
echo ""
echo "--- 11. Cleanup ---"
tui_cleanup
tui_summary
