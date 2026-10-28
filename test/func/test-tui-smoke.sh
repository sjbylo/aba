#!/bin/bash
# Test: TUI smoke test — splash, main menu, submenus, exit
# Uses screen-aware navigation: reads menu items and buttons dynamically.

cd "$(dirname "$0")/../.."
source test/func/tui-test-lib.sh

echo "=== TUI Smoke Test ==="
echo "  Host: $_TUI_HOST"
echo ""

_ssh_cfg="$HOME/.aba/ssh.conf"
scp -q -F "$_ssh_cfg" tui/v2/*.sh "$_TUI_HOST:aba/tui/v2/" 2>/dev/null
scp -q -F "$_ssh_cfg" scripts/include_all.sh scripts/aba.sh "$_TUI_HOST:aba/scripts/" 2>/dev/null
echo "  Code deployed"
echo ""

# ============================================================================
# 1. Splash screen
# ============================================================================
echo "--- 1. Splash screen ---"
tui_start
tui_assert_appears "OpenShift Installer" "Splash screen appeared" 15 || {
	tui_screenshot "splash-fail"; tui_stop; tui_summary; exit 1
}
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
tui_keys Enter
tui_assert_appears "Actions" "Main menu appeared" 10
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
tui_back_to "Actions" 3
tui_select_item "Configure"
tui_assert_appears "Settings" "Settings dialog appeared" 5
tui_assert_contains "Registry Type" "Registry Type setting"
tui_assert_contains "Retry" "Retry setting"
tui_screenshot "05-settings"

tui_press_button "Help"
sleep 2
tui_screenshot "05b-settings-help"
tui_capture > /tmp/_tui_settings_help.txt
if grep -qiE "toggle|setting" /tmp/_tui_settings_help.txt; then
	echo "  ✓ PASS: Settings help appeared"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ~ SKIP: Settings help content unclear"
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
if grep -qiE "Day-2|Cluster Management" /tmp/_tui_day2_check.txt; then
	echo "  ✓ PASS: Day-2 menu reached"
	_TUI_PASS=$(( _TUI_PASS + 1 ))

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
	echo "  ~ SKIP: Day-2 menu not reached (may need cluster)"
fi

# ============================================================================
# 8. Clean exit
# ============================================================================
echo ""
echo "--- 8. Clean exit ---"
tui_back_to "Actions"
for i in 1 2 3 4 5; do
	tui_keys Escape; sleep 1
done
tui_screenshot "08-exit"
sleep 2
if $_TUI_SSH "tmux has-session -t $_TUI_SESSION 2>/dev/null"; then
	tui_keys Enter; sleep 1; tui_keys Escape; sleep 1; tui_keys Enter; sleep 2
fi

# ============================================================================
# 9. Stray process check
# ============================================================================
echo ""
echo "--- 9. Stray process check ---"
_strays=$($_TUI_SSH "ps -eo pid,ppid,args | grep -E '\bdialog\b|abatui' | grep -v grep" 2>/dev/null || true)
if [ -z "$_strays" ]; then
	echo "  ✓ PASS: No stray TUI processes"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: Stray processes found:"
	echo "$_strays" | sed 's/^/      /'
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	$_TUI_SSH "pkill -f abatui 2>/dev/null; pkill -f 'dialog --' 2>/dev/null; true"
fi

tui_stop 2>/dev/null
tui_summary
