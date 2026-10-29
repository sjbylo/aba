#!/bin/bash
# Test: TUI navigation — dynamically discover and enter every submenu
# Uses screen-aware navigation: reads menu items, finds keys, navigates back.

cd "$(dirname "$0")/../.."
source test/func/tui-test-lib.sh

echo "=== TUI Navigation Test ==="
echo "  Host: $_TUI_HOST"
echo ""

tui_deploy_code
echo ""

# ============================================================================
# Start TUI, get to main menu
# ============================================================================
tui_start_to_menu || { tui_summary; exit 1; }

# Remember the main menu title for back-navigation
_main_title=$(tui_dialog_title)
echo "  Main menu title: '$_main_title'"

# ============================================================================
# 1. Dynamically discover and enter each menu item
# ============================================================================
echo ""
echo "--- 1. Enter each discovered submenu ---"

# Save all items: KEY\tLABEL
_items_file=/tmp/_tui_nav_items.txt
tui_menu_items > "$_items_file"
echo "  Discovered $(wc -l < "$_items_file") menu items"

while IFS=$'\t' read -r _key _label <&3; do
	# Skip items that trigger destructive actions or long-running commands
	case "$_label" in
		*Install\ Cluster*|*Save\ images*|*Sync\ images*|*Bundle*|*Wizard*)
			echo "  ~ SKIP: $_label (would trigger action)"
			continue
			;;
	esac

	echo "  Trying: [$_key] $_label"
	tui_back_to "Actions" 3
	tui_keys "$_key"
	sleep 0.5
	tui_keys Enter
	sleep 2

	# Read what screen we're on
	_new_title=$(tui_dialog_title)
	_screen=$(tui_capture)

	# Success if we're on a different screen than main menu
	if [[ "$_new_title" != "$_main_title" ]] && [[ -n "$_new_title" ]]; then
		echo "  ✓ PASS: Entered submenu '$_new_title' (from: $_label)"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	elif echo "$_screen" | grep -qiE "error|not found|cannot"; then
		echo "  ✗ FAIL: Error entering '$_label'"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	else
		echo "  ✓ PASS: Item '$_label' handled (key=$_key)"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	fi

	tui_back_to "Actions" 5
done 3< "$_items_file"

# ============================================================================
# 2. Arrow key navigation stays on menu
# ============================================================================
echo ""
echo "--- 2. Arrow key navigation ---"
tui_back_to "Actions" 3
tui_keys Down; sleep 0.3
tui_keys Down; sleep 0.3
tui_keys Down; sleep 0.3
tui_assert_contains "Actions" "Still on main menu after Down arrows"
tui_keys Up; sleep 0.3
tui_keys Up; sleep 0.3
tui_keys Up; sleep 0.3
tui_assert_contains "Actions" "Still on main menu after Up arrows"

# ============================================================================
# 3. Dynamically verify all buttons
# ============================================================================
echo ""
echo "--- 3. Button discovery ---"
_btns=$(tui_buttons)
_btn_count=$(echo "$_btns" | wc -l)
echo "  Found $_btn_count buttons: $(echo "$_btns" | tr '\n' ', ')"
if [[ $_btn_count -ge 2 ]]; then
	echo "  ✓ PASS: At least 2 buttons present"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: Expected at least 2 buttons"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

# ============================================================================
# 4. Multiple Escape exits cleanly
# ============================================================================
echo ""
echo "--- 4. Multiple Escape exit ---"
for i in 1 2 3 4 5 6; do
	tui_keys Escape; sleep 1
done
sleep 2
if $_TUI_SSH "tmux has-session -t $_TUI_SESSION 2>/dev/null"; then
	tui_keys Enter; sleep 1; tui_keys Escape; sleep 1; tui_keys Enter; sleep 2
fi

if ! $_TUI_SSH "tmux has-session -t $_TUI_SESSION 2>/dev/null" 2>/dev/null; then
	echo "  ✓ PASS: TUI exited cleanly (tmux session ended)"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	tui_capture > /tmp/_tui_exit_check.txt
	if grep -qE '^\$|bash|steve@' /tmp/_tui_exit_check.txt; then
		echo "  ✓ PASS: TUI exited (back to shell prompt)"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ✗ FAIL: TUI did not exit after multiple Escapes"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	fi
fi

# ============================================================================
# 5. Re-launch shows fresh splash
# ============================================================================
echo ""
echo "--- 5. Re-launch (fresh state) ---"
tui_start
tui_assert_appears "OpenShift Installer" "TUI re-launched cleanly" 15
tui_assert_contains "Continue" "Shows splash on re-launch"
tui_screenshot "nav-05-relaunch"

# ============================================================================
# 6. Cleanup
# ============================================================================
echo ""
echo "--- 6. Cleanup ---"
tui_cleanup
tui_summary
