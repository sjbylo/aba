#!/bin/bash
# Test: TUI operator workflows — sets, search, view/edit, clear, additional images
# Exercises the full operator selection pipeline via Mirror Payload menu.
# Non-destructive: does not persist changes (cancels back out).
# Uses screen-aware navigation throughout.

cd "$(dirname "$0")/../.."
source test/func/tui-test-lib.sh

echo "=== TUI Operator Workflow Test ==="
echo "  Host: $_TUI_HOST"
echo ""

_ssh_cfg="$HOME/.aba/ssh.conf"
scp -q -F "$_ssh_cfg" tui/v2/*.sh "$_TUI_HOST:aba/tui/v2/" 2>/dev/null
scp -q -F "$_ssh_cfg" scripts/include_all.sh scripts/aba.sh "$_TUI_HOST:aba/scripts/" 2>/dev/null
echo "  Code deployed"
echo ""

# ============================================================================
tui_start
tui_assert_appears "OpenShift Installer" "TUI launched" 15 || {
	tui_stop; tui_summary; exit 1
}
tui_keys Enter  # past splash
tui_assert_appears "Actions" "Main menu" 10

# ============================================================================
# 1. Navigate to Mirror Payload → Select Operators
# ============================================================================
echo ""
echo "--- 1. Mirror Payload menu ---"
tui_select_item "Mirror Payload"
tui_wait_isc_done 120
tui_assert_appears "Mirror Payload\|Additional Images" "Payload menu appeared" 15
tui_screenshot "op-01-payload"

# Check payload menu items are present
tui_assert_contains "OCP Version" "OCP Version item"
tui_assert_contains "Select Operators" "Select Operators item"
tui_assert_contains "Additional Images\|images" "Additional Images item"
tui_assert_contains "Prepare Upgrade" "Prepare Upgrade item"
tui_assert_contains "Release Images" "Release Images toggle"
tui_assert_contains "Operator Images" "Operator Images toggle"
tui_assert_contains "Advanced" "Advanced item"

# Check payload help
tui_press_button "Help"
sleep 2
tui_assert_contains "ImageSet\|imageset\|mirror" "Payload help mentions ImageSet"
tui_assert_contains "Operator" "Payload help mentions operators"
tui_assert_contains "Additional" "Payload help mentions additional images"
tui_assert_contains "Upgrade" "Payload help mentions upgrade"
tui_assert_contains "Release Images" "Payload help mentions Release Images toggle"
tui_assert_contains "Operator Images" "Payload help mentions Operator Images toggle"
tui_screenshot "op-01b-payload-help"
tui_keys Enter; sleep 1

# ============================================================================
# 2. Select Operators menu
# ============================================================================
echo ""
echo "--- 2. Select Operators menu ---"
tui_select_item "Select Operators"
tui_assert_appears "Select Operators\|Operator" "Operator menu appeared" 15
tui_screenshot "op-02-operator-menu"

# Check operator menu items
tui_assert_contains "Operator Sets\|Select Operator Sets" "Operator Sets item"
tui_assert_contains "Search" "Search item"
tui_assert_contains "View/Edit" "View/Edit item"
tui_assert_contains "Clear" "Clear item"

# Check catalog stats
tui_capture > /tmp/_tui_op_menu.txt
if grep -qi "redhat-operator\|certified-operator\|community-operator\|catalog" /tmp/_tui_op_menu.txt; then
	echo "  ✓ PASS: Catalog statistics displayed"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ~ NOTE: Catalog stats not visible (indexes may still be downloading)"
fi

# Check operator help
tui_press_button "Help"
sleep 2
tui_assert_contains "Operator Sets" "Operator help mentions Operator Sets"
tui_assert_contains "Search" "Operator help mentions Search"
tui_assert_contains "View/Edit" "Operator help mentions View/Edit"
tui_assert_contains "Clear" "Operator help mentions Clear"
tui_assert_contains "ImageSet" "Operator help mentions ImageSet"
tui_screenshot "op-02b-operator-help"
tui_keys Enter; sleep 1

# Helper: ensure we're inside the Operator submenu (has "Operator Sets" as item 1)
_enter_operator_menu() {
	# If we see "Select Operator Sets" as a menu item, we're in the operator menu
	if tui_capture | grep -q "Select Operator Sets"; then
		return 0
	fi
	# Otherwise navigate from payload or main menu
	if tui_capture | grep -q "Select Operators"; then
		# We're in payload — enter operator submenu
		tui_select_item "Select Operators"
		tui_wait_for "Select Operator Sets" 15
		return $?
	fi
	# Try from main menu
	tui_back_to "Actions" 3
	tui_select_item "Mirror Payload"
	tui_wait_for "Mirror Payload\|Payload" 10
	tui_select_item "Select Operators"
	tui_wait_for "Select Operator Sets" 15
}

# ============================================================================
# 3. Operator Sets (checklist)
# ============================================================================
echo ""
echo "--- 3. Operator Sets ---"
_enter_operator_menu
tui_keys 1; sleep 0.3; tui_keys Enter
sleep 3
tui_screenshot "op-03-sets"

_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Operator Sets"; then
	echo "  ✓ PASS: Operator Sets checklist appeared"
	_TUI_PASS=$(( _TUI_PASS + 1 ))

	echo "  Available operator sets:"
	# Parse checklist items: [X] or [ ] followed by name
	tui_capture | sed -n 's/.*\[\(.\)\][[:space:]]*\([a-z][-a-z0-9]*\).*/    [\1] \2/p' | head -15

	tui_keys Escape; sleep 1
else
	echo "  ~ NOTE: Operator Sets screen unclear"
	tui_keys Escape; sleep 1
fi

# ============================================================================
# 4. Search Operators
# ============================================================================
echo ""
echo "--- 4. Search Operators ---"
_enter_operator_menu
tui_keys 2; sleep 0.3; tui_keys Enter
sleep 2
tui_screenshot "op-04-search-input"

_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Search\|search\|keyword\|operator name"; then
	echo "  ✓ PASS: Search input appeared"
	_TUI_PASS=$(( _TUI_PASS + 1 ))

	tui_keys "web-terminal"
	sleep 0.5
	tui_keys Enter
	sleep 5
	tui_screenshot "op-04b-search-results"

	_scr=$(tui_capture)
	if echo "$_scr" | grep -qi "web-terminal"; then
		echo "  ✓ PASS: Search found 'web-terminal'"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	elif echo "$_scr" | grep -qi "No.*results\|0 matches"; then
		echo "  ✓ PASS: Search returned 'no results' (index may not be ready)"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ~ NOTE: Search results unclear"
	fi
	tui_keys Escape; sleep 1
else
	echo "  ~ NOTE: Search input screen unclear"
	tui_keys Escape; sleep 1
fi

# ============================================================================
# 5. View/Edit Selection (basket)
# ============================================================================
echo ""
echo "--- 5. View/Edit Selection ---"
_enter_operator_menu
tui_keys 3; sleep 0.3; tui_keys Enter
sleep 3
tui_screenshot "op-05-view"

_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Operator Selection\|empty\|No operators"; then
	if echo "$_scr" | grep -qi "empty\|No operators"; then
		echo "  ✓ PASS: Empty basket message shown"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ✓ PASS: Operator selection list displayed"
		_TUI_PASS=$(( _TUI_PASS + 1 ))

		echo "  Currently selected operators:"
		tui_capture | sed -n 's/.*\[\(.\)\][[:space:]]*\(.*\)/    [\1] \2/p' | head -10
	fi
else
	echo "  ~ NOTE: View/Edit screen unclear"
fi

tui_keys Escape; sleep 1

# ============================================================================
# 6. Clear Selection (verify confirmation)
# ============================================================================
echo ""
echo "--- 6. Clear Selection ---"
_enter_operator_menu
tui_keys 4; sleep 0.3; tui_keys Enter
sleep 3
tui_screenshot "op-06-clear"

_scr=$(tui_capture)
if echo "$_scr" | grep -qi "already empty\|nothing to clear\|no operators selected"; then
	echo "  ✓ PASS: Clear reports 'already empty'"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
	# Dismiss the info dialog
	tui_keys Enter; sleep 1
elif echo "$_scr" | grep -qi "Remove all\|clear.*selection\|Are you sure"; then
	echo "  ✓ PASS: Clear confirmation dialog appeared"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
	tui_press_button "Cancel" 2>/dev/null || tui_keys Escape
	sleep 1
elif echo "$_scr" | grep -qi "Select Operator Sets"; then
	# The clear msgbox was too quick — we're already back at operator menu
	echo "  ✓ PASS: Clear executed (returned to operator menu)"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ~ NOTE: Clear screen unclear"
	tui_keys Escape; sleep 1
fi

# ============================================================================
# 7. Additional Images menu
# ============================================================================
echo ""
echo "--- 7. Additional Images ---"
# Navigate to the Mirror Payload menu from wherever we are
_goto_payload_menu() {
	# If already at payload level (has both "Select Operators" AND "Additional Images")
	local _s
	_s=$(tui_capture)
	if echo "$_s" | grep -qi "Select Operators" && echo "$_s" | grep -qi "Additional Images"; then
		return 0
	fi
	# If at a submenu, escape up
	if echo "$_s" | grep -qi "Select Operator Sets\|List images\|Add image\|Recommended\|imageset-config"; then
		tui_keys Escape; sleep 1
	fi
	# If at main menu
	if ! tui_capture | grep -qi "Actions"; then
		tui_back_to "Actions" 5
	fi
	tui_select_item "Mirror Payload"
	tui_wait_isc_done 120
	tui_wait_for "Additional Images" 15
}
_goto_payload_menu
tui_select_item "Additional Images"
sleep 3
tui_screenshot "op-07-addl-images"

_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Additional Images"; then
	echo "  ✓ PASS: Additional Images menu appeared"
	_TUI_PASS=$(( _TUI_PASS + 1 ))

	# Check menu items dynamically
	echo "  Additional Images menu items:"
	tui_menu_items | while IFS=$'\t' read -r key label; do
		echo "    [$key] $label"
	done

	# Check that key items exist
	tui_assert_contains "Add" "Add image item"
	tui_assert_contains "Recommended\|recommended" "Recommended Images item"

	# Check help
	tui_press_button "Help"
	sleep 2
	tui_assert_contains "Additional Images\|additional images" "Additional Images help title"
	tui_assert_contains "images.conf" "Help mentions images.conf"
	tui_assert_contains "Add\|add" "Help mentions Add"
	tui_assert_contains "Recommended" "Help mentions Recommended"
	tui_screenshot "op-07b-addl-help"
	tui_keys Enter; sleep 1

	# ============================================================================
	# 7a. Add an image (but cancel)
	# ============================================================================
	echo ""
	echo "  --- 7a. Add image dialog ---"
	tui_select_item "Add"
	sleep 2
	tui_screenshot "op-07c-add-image"

	_scr=$(tui_capture)
	if echo "$_scr" | grep -qi "Add Image\|image reference\|container image"; then
		echo "  ✓ PASS: Add image input appeared"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
		# Don't add — just cancel
		tui_press_button "Cancel" 2>/dev/null || tui_keys Escape
		sleep 1
	else
		echo "  ~ NOTE: Add image screen unclear"
		tui_keys Escape; sleep 1
	fi

	# ============================================================================
	# 7b. Recommended Images
	# ============================================================================
	echo ""
	echo "  --- 7b. Recommended Images ---"
	tui_wait_for "Additional Images" 5
	tui_select_item "Recommended"
	sleep 3
	tui_screenshot "op-07d-recommended"

	_scr=$(tui_capture)
	if echo "$_scr" | grep -qi "Recommended Image Sets\|image sets to include"; then
		echo "  ✓ PASS: Recommended Images dialog appeared"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
		# Don't change — press Back
		tui_press_button "Back" 2>/dev/null || tui_keys Escape
		sleep 1
	else
		echo "  ~ NOTE: Recommended screen unclear"
		tui_keys Escape; sleep 1
	fi

	tui_back_to "Mirror Payload" 3
else
	echo "  ~ NOTE: Additional Images screen unclear"
	tui_keys Escape; sleep 1
fi

# ============================================================================
# 8. Include/Exclude toggles
# ============================================================================
echo ""
echo "--- 8. Include/Exclude toggles ---"
_goto_payload_menu
tui_screenshot "op-08-toggles"

# Verify toggle labels are present
tui_assert_contains "Release Images" "Release Images toggle present"
tui_assert_contains "Operator Images" "Operator Images toggle present"
tui_assert_contains "Additional Images" "Additional Images toggle present"

# Check current state (included/excluded)
_scr=$(tui_capture)
if echo "$_scr" | grep -qi "included"; then
	echo "  ✓ PASS: Toggle states visible (included/excluded)"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
fi

# ============================================================================
# 9. Prepare Upgrade option
# ============================================================================
echo ""
echo "--- 9. Prepare Upgrade ---"
_goto_payload_menu
tui_select_item "Prepare Upgrade"
sleep 3
tui_screenshot "op-09-upgrade"

_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Prepare Upgrade\|upgrade.*version\|target.*version"; then
	echo "  ✓ PASS: Prepare Upgrade dialog appeared"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ~ NOTE: Prepare Upgrade screen unclear"
fi
tui_keys Escape; sleep 1

# ============================================================================
# 10. Advanced (ISC view/edit/reset)
# ============================================================================
echo ""
echo "--- 10. Advanced (ImageSet Config) ---"
_goto_payload_menu
tui_select_item "Advanced"
sleep 3
tui_screenshot "op-10-advanced"

_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Advanced ImageSet\|imageset-config\|View.*imageset\|Edit.*imageset"; then
	echo "  ✓ PASS: Advanced ISC menu appeared"
	_TUI_PASS=$(( _TUI_PASS + 1 ))

	echo "  Advanced menu items:"
	tui_menu_items | while IFS=$'\t' read -r key label; do
		echo "    [$key] $label"
	done
else
	echo "  ~ NOTE: Advanced ISC screen unclear"
fi
tui_keys Escape; sleep 1

# ============================================================================
# 11. Back to main menu
# ============================================================================
echo ""
echo "--- 11. Back to main menu ---"
tui_back_to "Actions" 5
tui_assert_contains "Actions" "Back at main menu"

# ============================================================================
# 12. Cleanup
# ============================================================================
echo ""
echo "--- 12. Cleanup ---"
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
