#!/bin/bash
# Test: TUI help text consistency
# Verifies that every menu's Help text accurately describes the actual menu items.
# Uses screen-aware navigation — reads items and buttons dynamically.

cd "$(dirname "$0")/../.."
source test/func/tui-test-lib.sh

echo "=== TUI Help Text Consistency Test ==="
echo "  Host: $_TUI_HOST"
echo ""

_ssh_cfg="$HOME/.aba/ssh.conf"
scp -q -F "$_ssh_cfg" tui/v2/*.sh "$_TUI_HOST:aba/tui/v2/" 2>/dev/null
scp -q -F "$_ssh_cfg" scripts/include_all.sh scripts/aba.sh "$_TUI_HOST:aba/scripts/" 2>/dev/null
echo "  Code deployed"
echo ""

# Cross-check: every keyword must appear in BOTH menu and help captures.
# $1 = label, $2 = menu file, $3 = help file, $4... = keywords
_cross_check_help() {
	local label="$1" menu_file="$2" help_file="$3"
	shift 3
	echo "  --- Cross-check: $label ---"
	for kw in "$@"; do
		if ! grep -qi "$kw" "$help_file"; then
			echo "  ✗ FAIL: Help for '$label' missing keyword: $kw"
			_TUI_FAIL=$(( _TUI_FAIL + 1 ))
			continue
		fi
		if ! grep -qi "$kw" "$menu_file"; then
			echo "  ✗ FAIL: Menu '$label' missing item that Help mentions: $kw"
			_TUI_FAIL=$(( _TUI_FAIL + 1 ))
			continue
		fi
		echo "  ✓ PASS: '$kw' consistent between menu and help"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	done
}

# Reverse check: extract items from the menu and verify each is in help.
# $1 = label, $2 = menu file, $3 = help file
_reverse_check_items_in_help() {
	local label="$1" menu_file="$2" help_file="$3"
	echo "  --- Reverse check: every $label menu item mentioned in help ---"
	tui_menu_items | while IFS=$'\t' read -r _key _label; do
		# Extract first meaningful word (skip generic words)
		local _word
		_word=$(echo "$_label" | sed 's/(.*)//g; s/\[.*\]//g' | awk '{print $1}')
		[[ -z "$_word" || ${#_word} -lt 3 ]] && continue
		if grep -qi "$_word" "$help_file"; then
			echo "  ✓ PASS: Help covers menu item '$_word' (from: $_label)"
			_TUI_PASS=$(( _TUI_PASS + 1 ))
		else
			echo "  ✗ FAIL: Help MISSING menu item '$_word' (from: $_label)"
			_TUI_FAIL=$(( _TUI_FAIL + 1 ))
		fi
	done
}

# ============================================================================
tui_start
tui_assert_appears "OpenShift Installer" "TUI launched" 15 || {
	tui_stop; tui_summary; exit 1
}

# ============================================================================
# 1. Splash: menu vs help
# ============================================================================
echo ""
echo "--- 1. Splash screen vs Help ---"
tui_capture > /tmp/_hc_splash_menu.txt
tui_press_button "Help"
tui_wait_for "Quick Guide" 5
tui_capture > /tmp/_hc_splash_help.txt
tui_screenshot "hc-01-splash-help"

_cross_check_help "Splash" \
	/tmp/_hc_splash_menu.txt /tmp/_hc_splash_help.txt \
	"ABA" "Tab"

tui_assert_contains "wizard" "Splash help mentions wizard workflow"
tui_assert_contains "Pull secret" "Splash help mentions pull secret step"
tui_assert_contains "Version" "Splash help mentions version step"
tui_assert_contains "Platform" "Splash help mentions platform step"
tui_assert_contains "Operators" "Splash help mentions operators step"
tui_assert_contains "Mirror" "Splash help mentions mirror step"
tui_assert_contains "Cluster" "Splash help mentions cluster step"
tui_assert_contains "Upgrade" "Splash help mentions upgrade"
tui_assert_contains "Day-2" "Splash help mentions Day-2"
tui_assert_contains "CLI" "Splash help mentions CLI alternative"

tui_keys Enter; sleep 1
tui_keys Enter
tui_wait_for "Actions" 10

# ============================================================================
# 2. Main Menu: menu vs help
# ============================================================================
echo ""
echo "--- 2. Main menu vs Help ---"
tui_capture > /tmp/_hc_main_menu.txt

tui_press_button "Help"
tui_wait_for "Partially Disconnected" 5
tui_capture > /tmp/_hc_main_help.txt
tui_screenshot "hc-02-main-help"

_cross_check_help "Main Menu (Conno)" \
	/tmp/_hc_main_menu.txt /tmp/_hc_main_help.txt \
	"Mirror Payload" "Install Mirror" "Sync" \
	"Bundle" "Save" \
	"Install Cluster" "Day-2" \
	"Configure" "Wizard" "Advanced" "Feedback"

tui_assert_contains "Navigation" "Main help has Navigation section"
tui_assert_contains "ESC" "Main help mentions ESC"
tui_assert_contains "Enter" "Main help mentions Enter"
tui_assert_contains "Arrow" "Main help mentions Arrow keys"

tui_keys Enter; sleep 1

# ============================================================================
# 3. Settings: menu vs help
# ============================================================================
echo ""
echo "--- 3. Settings vs Help ---"
tui_back_to "Actions" 3
tui_select_item "Configure"
tui_wait_for "Settings" 5
tui_capture > /tmp/_hc_settings_menu.txt

tui_press_button "Help"
sleep 2
tui_capture > /tmp/_hc_settings_help.txt
tui_screenshot "hc-03-settings-help"

_cross_check_help "Settings" \
	/tmp/_hc_settings_menu.txt /tmp/_hc_settings_help.txt \
	"Toggle"

tui_keys Enter; sleep 1
tui_back_to "Actions"

# ============================================================================
# 4. Advanced: menu vs help
# ============================================================================
echo ""
echo "--- 4. Advanced vs Help ---"
tui_select_item "Advanced"
tui_wait_for "Advanced" 5
tui_capture > /tmp/_hc_adv_menu.txt
tui_screenshot "hc-04-adv-menu"

tui_press_button "Help"
tui_wait_for "Advanced Menu Help" 5
tui_capture > /tmp/_hc_adv_help.txt
tui_screenshot "hc-04-adv-help"

_cross_check_help "Advanced" \
	/tmp/_hc_adv_menu.txt /tmp/_hc_adv_help.txt \
	"Platform Settings" "Switch Mode" "Clean ABA"

tui_assert_contains "vmware.conf" "Help mentions vmware.conf"
tui_assert_contains "kvm.conf" "Help mentions kvm.conf"
tui_assert_contains "Uninstall" "Help mentions Uninstall"

tui_keys Enter; sleep 1
tui_back_to "Actions"

# ============================================================================
# 5. Day-2: menu vs help
# ============================================================================
echo ""
echo "--- 5. Day-2 vs Help ---"
tui_select_item "Day-2"
sleep 2
tui_capture > /tmp/_hc_day2_menu.txt
tui_screenshot "hc-05-day2-menu"

if grep -qi "Day-2\|Cluster Management" /tmp/_hc_day2_menu.txt; then
	tui_press_button "Help"
	sleep 2
	tui_capture > /tmp/_hc_day2_help.txt
	tui_screenshot "hc-05-day2-help"

	_cross_check_help "Day-2" \
		/tmp/_hc_day2_menu.txt /tmp/_hc_day2_help.txt \
		"OperatorHub" "NTP" "OSUS" "Upgrade" "Shutdown" "Startup"

	tui_assert_contains "Configuration" "Day-2 help has Configuration section"
	tui_assert_contains "Lifecycle" "Day-2 help has Lifecycle section"
	tui_assert_contains "Cleanup" "Day-2 help has Cleanup section"
	tui_assert_contains "Navigation" "Day-2 help has Navigation section"

	# Reverse check: every item on the Day-2 menu should be in help
	_d2_items=$(grep -oE '(OperatorHub|NTP|OSUS|Virtualization|Status|Login|SSH|Upgrade|Shutdown|Startup|Clean|Delete)' /tmp/_hc_day2_menu.txt | sort -u)
	for _item in $_d2_items; do
		if grep -qi "$_item" /tmp/_hc_day2_help.txt; then
			echo "  ✓ PASS: Day-2 help covers menu item: $_item"
			_TUI_PASS=$(( _TUI_PASS + 1 ))
		else
			echo "  ✗ FAIL: Day-2 help MISSING menu item: $_item"
			_TUI_FAIL=$(( _TUI_FAIL + 1 ))
		fi
	done

	tui_keys Enter; sleep 1
	tui_back_to "Actions"
else
	echo "  ~ SKIP: Day-2 menu not reached"
fi

# ============================================================================
# 6. Help text quality
# ============================================================================
echo ""
echo "--- 6. Help text quality ---"
for _hf in /tmp/_hc_*_help.txt; do
	_hf_label=$(basename "$_hf" .txt | sed 's/_hc_//; s/_help//')
	if grep -q '\.\.\.more\.\.\.\|TRUNCATED\|scroll' "$_hf" 2>/dev/null; then
		echo "  ✗ FAIL: Help '$_hf_label' appears truncated"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	else
		echo "  ✓ PASS: Help '$_hf_label' not truncated"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	fi
done

# ============================================================================
# 7. Cleanup
# ============================================================================
echo ""
echo "--- 7. Cleanup ---"
tui_cleanup
tui_summary
