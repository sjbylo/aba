#!/bin/bash
# Test: TUI smoke test — splash, main menu, submenus, exit
# Uses screen-aware navigation: reads menu items and buttons dynamically.

cd "$(dirname "$0")/../.."
source test/func/tui-test-lib.sh

echo "=== TUI Smoke Test ==="
echo "  Host: $_TUI_HOST"
echo ""

tui_deploy_code
echo ""

# Splash is drawn once, when abatui starts. A session already on the main
# menu is that same process — killing it only to see the splash again is
# what forces the next test to launch from scratch (~20s).
_smoke_reuse=0
if tui_session_alive; then
	if tui_on_main_menu || { tui_leave_on_menu && tui_on_main_menu; }; then
		echo "  Reusing TUI session — splash already passed in this process"
		trap 'tui_leave_on_menu 2>/dev/null' EXIT
		_smoke_reuse=1
	fi
fi

# ============================================================================
# 1. Splash screen
# ============================================================================
if [[ "$_smoke_reuse" -eq 0 ]]; then
echo "--- 1. Splash screen ---"
tui_start
tui_assert_appears "OpenShift Installer" "Splash screen appeared" 15 || {
	tui_screenshot "splash-fail"; tui_leave_on_menu 2>/dev/null || true; tui_summary; exit 1
}
tui_assert_title "OpenShift Installer\|ABA" "Splash screen title"
tui_assert_contains "ABA v" "Version string present"
# Check buttons dynamically
_splash_btns=$(tui_buttons | tr '\n' ', ')
echo "  Buttons found: $_splash_btns"
tui_assert_contains "Continue" "Continue button present"
tui_assert_contains "Exit" "Exit button present"
tui_assert_contains "Help" "Help button present"
tui_screenshot "01-splash"

# ============================================================================
# 2. Splash Help (navigate by button label)
# ============================================================================
echo ""
echo "--- 2. Splash Help ---"
tui_press_button "Help"
tui_assert_appears "Quick Guide" "Splash help appeared" 5
tui_assert_contains "wizard" "Help mentions wizard"
tui_assert_contains "Pull secret" "Help mentions pull secret"
tui_assert_contains "Mirror" "Help mentions mirror"
tui_assert_contains "Navigation" "Help has navigation section"
tui_assert_contains "ESC" "Help mentions ESC key"
tui_screenshot "02-splash-help"
tui_keys Enter; sleep 1

# ============================================================================
# 3. Main menu
# ============================================================================
echo ""
echo "--- 3. Main menu ---"
# Enter leaves the splash. On a reused session it would open the highlighted item.
[[ "$_smoke_reuse" -eq 0 ]] && tui_keys Enter
else
echo "--- 1-2. Splash skipped (session already on the main menu) ---"
echo ""
echo "--- 3. Main menu ---"
fi
tui_assert_appears "Actions" "Main menu appeared" 10
tui_assert_title "Partially Disconnected\|Fully Disconnected\|Fully Connected" "Main menu title"
tui_screenshot "03-main-menu"

# Dynamically discover all menu items
echo "  Menu items discovered:"
tui_menu_items | while IFS=$'\t' read -r key label; do
	echo "    [$key] $label"
done

# Check expected items are present (by label, not by key)
tui_assert_contains "Mirror Payload" "Mirror Payload item"
tui_assert_contains "Install Mirror" "Install Mirror item"
tui_assert_contains "Sync" "Sync item present"
tui_assert_contains "Bundle" "Bundle item present"
tui_assert_contains "Save" "Save item present"
tui_assert_contains "Install Cluster" "Install Cluster item"
tui_assert_contains "Day-2" "Day-2 item present"
tui_assert_contains "Configure" "Configure item present"
tui_assert_contains "Wizard" "Wizard item present"
tui_assert_contains "Advanced" "Advanced item present"
tui_assert_contains "Feedback" "Feedback item present"

# ============================================================================
# 4. Main menu Help (navigate by button label)
# ============================================================================
echo ""
echo "--- 4. Main menu Help ---"
tui_press_button "Help"
tui_assert_appears "Partially Disconnected" "Main help appeared" 5
tui_screenshot "04-main-help"
tui_assert_contains "Mirror Payload" "Help mentions Mirror Payload"
tui_assert_contains "Install Mirror" "Help mentions Install Mirror"
tui_assert_contains "Sync" "Help mentions Sync"
tui_assert_contains "Bundle" "Help mentions Bundle"
tui_assert_contains "Save" "Help mentions Save"
tui_assert_contains "Install Cluster" "Help mentions Install Cluster"
tui_assert_contains "Day-2" "Help mentions Day-2"
tui_assert_contains "Configure" "Help mentions Configure"
tui_assert_contains "Wizard" "Help mentions Wizard"
tui_assert_contains "Advanced" "Help mentions Advanced"
tui_assert_contains "Feedback" "Help mentions Feedback"
tui_assert_contains "Navigation" "Help has navigation section"
tui_assert_contains "ESC" "Help mentions ESC"
tui_keys Enter; sleep 1

# ============================================================================
# 5. Settings submenu (navigate by item label)
# ============================================================================
echo ""
echo "--- 5. Settings submenu ---"
# Esc from the main menu opens Confirm Exit; recover before Configure.
tui_back_to "Actions" 8 || true
_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Confirm Exit\|Exit ABA"; then
	echo "  (dismissing Confirm Exit before Settings)"
	tui_press_button "Continue" 2>/dev/null || { tui_keys Tab; sleep 0.2; tui_keys Enter; }
	sleep 1
fi
tui_select_item "Configure"
tui_assert_appears "Settings" "Settings dialog appeared" 5
tui_assert_title "Settings" "Settings dialog title"
tui_assert_contains "Registry Type" "Registry Type setting"
tui_assert_contains "Retry" "Retry setting"
tui_screenshot "05-settings"

tui_press_button "Help"
sleep 2
tui_screenshot "05b-settings-help"
tui_capture > /tmp/_tui_settings_help.txt
if grep -qiE "toggle|setting" /tmp/_tui_settings_help.txt; then
	tui_pass "Settings help appeared"
else
	echo "  ✗ FAIL: Settings help content unclear"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi
tui_keys Enter; sleep 1
tui_back_to "Actions"

# ============================================================================
# 6. Advanced submenu (navigate by item label)
# ============================================================================
echo ""
echo "--- 6. Advanced submenu ---"
tui_select_item "Advanced"
tui_assert_appears "Advanced" "Advanced menu appeared" 5
tui_assert_title "Advanced" "Advanced menu title"
tui_assert_contains "Platform Settings" "Platform Settings item"
tui_assert_contains "Switch Mode" "Switch Mode section"
tui_assert_contains "Danger Zone" "Danger Zone section"
tui_screenshot "06-advanced"

echo "  Advanced menu items:"
tui_menu_items | while IFS=$'\t' read -r key label; do
	echo "    [$key] $label"
done

tui_press_button "Help"
tui_assert_appears "Advanced Menu Help" "Advanced help appeared" 5
tui_assert_contains "Platform Settings" "Help mentions Platform Settings"
tui_assert_contains "Switch Mode" "Help mentions Switch Mode"
tui_assert_contains "Clean ABA" "Help mentions Clean ABA"
tui_screenshot "06b-advanced-help"
tui_keys Enter; sleep 1
tui_back_to "Actions"

# ============================================================================
# 7. Day-2 submenu (navigate by item label)
# ============================================================================
echo ""
echo "--- 7. Day-2 submenu ---"
tui_select_item "Day-2"
sleep 2
tui_screenshot "07-day2"
tui_capture > /tmp/_tui_day2_check.txt
if grep -qiE "No clusters configured" /tmp/_tui_day2_check.txt; then
	tui_pass "Day-2 shows 'No clusters configured' (expected — no cluster installed)"
	tui_keys Enter; sleep 1
	tui_back_to "Actions"
elif grep -qiE "Day-2|Cluster Management" /tmp/_tui_day2_check.txt; then
	tui_pass "Day-2 menu reached"

	echo "  Day-2 menu items:"
	tui_menu_items | while IFS=$'\t' read -r key label; do
		echo "    [$key] $label"
	done

	sleep 1
	tui_press_button "Help"
	sleep 2
	tui_assert_appears "Configuration" "Day-2 help appeared" 10
	tui_assert_contains "OperatorHub" "Help mentions OperatorHub"
	tui_assert_contains "NTP" "Help mentions NTP"
	tui_assert_contains "OSUS" "Help mentions OSUS"
	tui_assert_contains "Lifecycle" "Help mentions Lifecycle section"
	tui_assert_contains "Upgrade" "Help mentions Upgrade"
	tui_assert_contains "Shutdown" "Help mentions Shutdown"
	tui_assert_contains "Startup" "Help mentions Startup"
	tui_assert_contains "Cleanup" "Help mentions Cleanup section"
	tui_assert_contains "Navigation" "Help has navigation section"
	tui_screenshot "07b-day2-help"
	tui_keys Enter; sleep 1
	tui_back_to "Actions"
else
	echo "  ✗ FAIL: Day-2 menu not reached"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

# ============================================================================
# 8. Clean exit
# ============================================================================
echo ""
echo "--- 8. Clean exit ---"
tui_screenshot "08-exit"

echo ""
echo "--- 9. Stray process check ---"
tui_cleanup
tui_summary
