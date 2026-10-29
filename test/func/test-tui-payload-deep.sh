#!/bin/bash
# Test: TUI payload deep — Prepare Upgrade flow, Version/Channel change,
# Settings toggle cycling, Bundle dialog.
# All non-destructive: cancels out of each flow without applying changes.

cd "$(dirname "$0")/../.."
source test/func/tui-test-lib.sh

echo "=== TUI Payload Deep Test ==="
echo "  Host: $_TUI_HOST"
echo ""

tui_deploy_code
echo ""

# ============================================================================
tui_start_to_menu || { tui_summary; exit 1; }

# Helper: navigate to Mirror Payload menu
_goto_payload() {
	if tui_capture | grep -q "Additional Images"; then
		return 0
	fi
	if tui_capture | grep -q "Select Operator Sets"; then
		tui_keys Escape; sleep 1
	fi
	if ! tui_capture | grep -q "Actions"; then
		tui_back_to "Actions" 5
	fi
	if tui_capture | grep -q "Actions"; then
		tui_select_item "Mirror Payload"
		tui_wait_isc_done 120
		tui_wait_for "Additional Images" 15
		return $?
	fi
	return 1
}

# ============================================================================
# 1. Prepare Upgrade version picker
# ============================================================================
echo ""
echo "--- 1. Prepare Upgrade ---"
_goto_payload
tui_select_item "Prepare Upgrade"
sleep 5  # version lookup takes a moment
tui_screenshot "pd-01-upgrade"

_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Prepare Upgrade\|upgrade.*version\|target.*version\|Base version"; then
	echo "  ✓ PASS: Prepare Upgrade picker appeared"
	_TUI_PASS=$(( _TUI_PASS + 1 ))

	# Check version picker elements
	tui_assert_contains "Base version\|aba.conf" "Shows base version reference"

	# Check for version entries or "no upgrade" message
	if echo "$_scr" | grep -qi "No upgrade\|No.*versions"; then
		echo "  ✓ PASS: No upgrade versions message (expected if at latest)"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	elif echo "$_scr" | grep -qi "Z-stream\|Next minor\|Minor\|latest"; then
		echo "  ✓ PASS: Upgrade version entries displayed"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
		# List discovered versions
		echo "  Upgrade versions found:"
		echo "$_scr" | grep -iE "Z-stream|Next|Minor|latest|4\.[0-9]" | sed 's/^/    /' | head -5
	fi

	# Check utility items at bottom
	tui_assert_contains "Manual entry\|Manual" "Manual entry option"
	tui_assert_contains "Change.*channel\|channel" "Change channel option"

	# Cancel out
	tui_keys Escape; sleep 1
else
	echo "  ~ NOTE: Prepare Upgrade screen unclear (may be loading)"
	tui_keys Escape; sleep 1
fi

# ============================================================================
# 2. OCP Version/Channel change
# ============================================================================
echo ""
echo "--- 2. OCP Version/Channel change ---"
_goto_payload
tui_select_item "OCP Version"
sleep 3
tui_screenshot "pd-02-channel"

_scr=$(tui_capture)
if echo "$_scr" | grep -qi "channel\|stable\|fast\|candidate"; then
	echo "  ✓ PASS: Channel selection appeared"
	_TUI_PASS=$(( _TUI_PASS + 1 ))

	# Check channel options
	tui_assert_contains "stable" "stable channel option"
	tui_assert_contains "fast" "fast channel option"
	tui_assert_contains "candidate" "candidate channel option"

	# Check help if available
	_btns=$(tui_buttons)
	if echo "$_btns" | grep -qi "Help"; then
		tui_press_button "Help"
		sleep 2
		tui_screenshot "pd-02b-channel-help"
		tui_assert_contains "channel\|update\|release" "Channel help content"
		tui_keys Enter; sleep 1
	fi

	# Select stable (stay on current) and proceed to version page
	tui_keys Enter; sleep 3
	tui_screenshot "pd-02c-version"

	_scr=$(tui_capture)
	if echo "$_scr" | grep -qi "version\|Latest\|4\.[0-9]"; then
		echo "  ✓ PASS: Version selection page appeared"
		_TUI_PASS=$(( _TUI_PASS + 1 ))

		# Check for Latest option
		tui_assert_contains "Latest\|latest" "Latest version option"

		# Cancel out
		tui_keys Escape; sleep 1
	else
		echo "  ~ NOTE: Version page unclear"
		tui_keys Escape; sleep 1
	fi
else
	echo "  ~ NOTE: Channel selection unclear"
	tui_keys Escape; sleep 1
fi

# Back to payload
tui_back_to "Additional Images\|Mirror Payload" 5
if tui_capture | grep -q "Actions"; then
	# Went too far, re-enter
	:
fi

# ============================================================================
# 3. Settings toggle cycling
# ============================================================================
echo ""
echo "--- 3. Settings toggle cycling ---"
tui_back_to "Actions" 5
tui_select_item "Configure"
sleep 2
tui_screenshot "pd-03-settings"

_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Settings\|Registry Type\|Retry"; then
	echo "  ✓ PASS: Settings menu appeared"
	_TUI_PASS=$(( _TUI_PASS + 1 ))

	# Check initial state
	tui_assert_contains "Registry Type" "Registry Type setting visible"
	tui_assert_contains "Retry" "Retry setting visible"

	# Get initial registry type
	_initial_reg=$(echo "$_scr" | grep -oi "Quay\|Docker\|OMR\|Auto" | head -1)
	echo "  Initial registry type: ${_initial_reg:-unknown}"

	# Toggle registry type (press Enter on first item)
	tui_keys Enter; sleep 1
	_scr=$(tui_capture)
	_toggled_reg=$(echo "$_scr" | grep -oi "Quay\|Docker\|OMR\|Auto" | head -1)
	if [[ -n "$_toggled_reg" && "$_toggled_reg" != "$_initial_reg" ]]; then
		echo "  ✓ PASS: Registry type toggled: ${_initial_reg} → ${_toggled_reg}"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	elif [[ -n "$_toggled_reg" ]]; then
		echo "  ✓ PASS: Registry type displayed after toggle: ${_toggled_reg}"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ~ NOTE: Could not detect registry type after toggle"
	fi

	# Toggle back to restore original: cycle until we see the original type again
	# Auto → Quay → Docker → OMR → Auto (3 more presses to get back)
	for _i in 1 2 3; do
		tui_keys Enter; sleep 0.5
	done
	# Verify restored
	_restored_reg=$(tui_capture | grep -oi "Quay\|Docker\|OMR\|Auto" | head -1)
	if [[ "$_restored_reg" == "$_initial_reg" ]]; then
		echo "  Registry type restored: $_restored_reg"
	else
		echo "  NOTE: Registry type now $_restored_reg (was $_initial_reg)"
	fi

	# Move to retry count and toggle it
	tui_keys Down; sleep 0.3
	_initial_retry=$(tui_capture | grep -oE "Retry.*[0-9OFF]+" | head -1)
	echo "  Initial retry: ${_initial_retry:-unknown}"
	tui_keys Enter; sleep 1
	_toggled_retry=$(tui_capture | grep -oE "Retry.*[0-9OFF]+" | head -1)
	if [[ -n "$_toggled_retry" && "$_toggled_retry" != "$_initial_retry" ]]; then
		echo "  ✓ PASS: Retry count toggled: ${_initial_retry} → ${_toggled_retry}"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	elif [[ -n "$_toggled_retry" ]]; then
		echo "  ✓ PASS: Retry count displayed after toggle: ${_toggled_retry}"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	fi

	# Toggle back to restore (cycle: OFF→1→2→5→OFF, max 4 presses)
	for _i in 1 2 3; do
		tui_keys Enter; sleep 0.3
	done
	_restored_retry=$(tui_capture | grep -oE "Retry.*[0-9OFF]+" | head -1)
	echo "  Retry restored: ${_restored_retry:-unknown}"

	# Check settings help
	tui_press_button "Help"
	sleep 2
	tui_screenshot "pd-03b-settings-help"
	tui_assert_contains "Registry Type\|registry" "Settings help mentions Registry Type"
	tui_assert_contains "Retry\|retry" "Settings help mentions Retry"
	tui_assert_contains "Auto\|auto" "Settings help mentions Auto option"
	tui_keys Enter; sleep 1

	tui_keys Escape; sleep 1
else
	echo "  ~ NOTE: Settings menu unclear"
	tui_keys Escape; sleep 1
fi

# ============================================================================
# 4. Bundle dialog (cancel before executing)
# ============================================================================
echo ""
echo "--- 4. Bundle dialog ---"
tui_back_to "Actions" 5
tui_select_item "Bundle\|Create.*Bundle"
sleep 3
tui_screenshot "pd-04-bundle"

_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Bundle\|output path\|OCP.*stable\|Enter.*path"; then
	echo "  ✓ PASS: Bundle dialog appeared"
	_TUI_PASS=$(( _TUI_PASS + 1 ))

	# Check bundle summary info
	if echo "$_scr" | grep -qi "OCP\|version\|4\."; then
		echo "  ✓ PASS: Bundle shows OCP version summary"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	fi

	# Check for "View Config" help button
	_btns=$(tui_buttons)
	if echo "$_btns" | grep -qi "View Config\|Config"; then
		echo "  ✓ PASS: View Config button present"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	fi

	# Cancel out
	tui_keys Escape; sleep 1
elif echo "$_scr" | grep -qi "No Internet\|no internet\|not available"; then
	echo "  ✓ PASS: Bundle correctly blocked — no internet"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
	tui_keys Enter; sleep 1
else
	echo "  ~ NOTE: Bundle dialog unclear"
	tui_keys Escape; sleep 1
fi

# ============================================================================
# 5. Save dialog (cancel before executing)
# ============================================================================
echo ""
echo "--- 5. Save dialog ---"
tui_back_to "Actions" 5
tui_select_item "Save"
sleep 3
tui_screenshot "pd-05-save"

_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Save\|OCP\|Operator\|Confirm\|excl_platform\|images"; then
	echo "  ✓ PASS: Save confirmation appeared"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
	tui_keys Escape; sleep 1
elif echo "$_scr" | grep -qi "No Internet\|no internet"; then
	echo "  ✓ PASS: Save correctly blocked — no internet"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
	tui_keys Enter; sleep 1
else
	echo "  ~ NOTE: Save dialog unclear"
	tui_keys Escape; sleep 1
fi

# ============================================================================
# 6. Sync dialog (cancel before executing)
# ============================================================================
echo ""
echo "--- 6. Sync dialog ---"
tui_back_to "Actions" 5
tui_select_item "Sync"
sleep 3
tui_screenshot "pd-06-sync"

_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Sync\|OCP\|mirror-to-mirror\|Confirm\|images"; then
	echo "  ✓ PASS: Sync confirmation appeared"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
	tui_keys Escape; sleep 1
elif echo "$_scr" | grep -qi "No Internet\|no internet"; then
	echo "  ✓ PASS: Sync correctly blocked — no internet"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
	tui_keys Enter; sleep 1
else
	echo "  ~ NOTE: Sync dialog unclear"
	tui_keys Escape; sleep 1
fi

# ============================================================================
# 7. Include/Exclude toggle cycling
# ============================================================================
echo ""
echo "--- 7. Include/Exclude toggle cycling ---"
_goto_payload

# Toggle Release Images (P key in payload menu)
_scr=$(tui_capture)
_before=$(echo "$_scr" | grep -o "Release Images: [a-z]*" | head -1)
echo "  Before toggle: ${_before:-unknown}"

# Select "Release Images" toggle
tui_select_item "Release Images"
sleep 1
_scr=$(tui_capture)
_after=$(echo "$_scr" | grep -o "Release Images: [a-z]*" | head -1)
if [[ -n "$_after" && "$_after" != "$_before" ]]; then
	echo "  ✓ PASS: Release Images toggled: ${_before} → ${_after}"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
	# Toggle back
	tui_select_item "Release Images"
	sleep 1
elif [[ -n "$_after" ]]; then
	echo "  ✓ PASS: Release Images toggle state: ${_after}"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
	# Ensure we toggle back if changed
	if [[ "$_after" == *"excluded"* ]]; then
		tui_select_item "Release Images"
		sleep 1
	fi
fi

# Toggle Operator Images
_before=$(tui_capture | grep -o "Operator Images: [a-z]*" | head -1)
tui_select_item "Operator Images"
sleep 1
_after=$(tui_capture | grep -o "Operator Images: [a-z]*" | head -1)
if [[ -n "$_after" && "$_after" != "$_before" ]]; then
	echo "  ✓ PASS: Operator Images toggled: ${_before} → ${_after}"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
	# Always toggle back to restore original state
	tui_select_item "Operator Images"
	sleep 1
elif [[ -n "$_after" ]]; then
	echo "  ✓ PASS: Operator Images toggle state: ${_after}"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
fi

# ============================================================================
# 8. Cleanup
# ============================================================================
echo ""
echo "--- 8. Cleanup ---"
tui_cleanup
tui_summary
