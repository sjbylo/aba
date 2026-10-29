#!/bin/bash
# Test: TUI setup wizard — channel, version, platform, operators
# Navigates each wizard page, verifies content, and exercises field editing.
# Non-destructive: doesn't change aba.conf (cancels at the end).

cd "$(dirname "$0")/../.."
source test/func/tui-test-lib.sh

echo "=== TUI Wizard Test ==="
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
# 1. Enter the wizard via "Rerun Wizard"
# ============================================================================
echo ""
echo "--- 1. Launch wizard ---"
tui_select_item "Wizard"
sleep 3
tui_screenshot "wiz-01-start"

# The wizard may show "Resume Configuration" if aba.conf is already set up.
# Press "Reconfigure" to enter the wizard pages.
_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Resume Configuration\|Continue with this"; then
	echo "  ✓ PASS: Resume Configuration dialog appeared"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
	tui_assert_contains "Channel" "Shows current channel"
	tui_assert_contains "Version" "Shows current version"
	tui_assert_contains "Platform" "Shows current platform"
	# Press Reconfigure (second button)
	tui_press_button "Reconfigure"
	sleep 3
fi

# If pull-secret page appears (first run or no pull-secret)
_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Pull Secret"; then
	echo "  ✓ PASS: Pull Secret page appeared"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
	tui_keys Enter
	sleep 2
fi

# ============================================================================
# 2. Channel selection page
# ============================================================================
echo ""
echo "--- 2. Channel selection ---"
tui_wait_for "Channel\|channel" 10
tui_screenshot "wiz-02-channel"
tui_assert_contains "stable" "stable channel option"
tui_assert_contains "fast" "fast channel option"
tui_assert_contains "candidate" "candidate channel option"

# Check help
tui_press_button "Help"
sleep 2
tui_assert_contains "stable" "Channel help mentions stable"
tui_assert_contains "production" "Channel help mentions production"
tui_screenshot "wiz-02b-channel-help"
tui_keys Enter; sleep 1

# Accept current channel (stable) — press Next/OK
_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Channel\|channel"; then
	tui_keys Enter; sleep 2
fi

# ============================================================================
# 3. Version selection page
# ============================================================================
echo ""
echo "--- 3. Version selection ---"
tui_wait_for "Version\|version" 15
tui_screenshot "wiz-03-version"
# Should show Latest, Previous, Older, Manual options
tui_assert_contains "Latest\|latest" "Latest version option"

# Check help
tui_press_button "Help"
sleep 2
tui_assert_contains "Latest\|Manual\|release" "Version help content"
tui_screenshot "wiz-03b-version-help"
tui_keys Enter; sleep 1

# Accept current version
_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Version\|version"; then
	tui_keys Enter; sleep 2
fi

# Handle any intermediate confirmation dialogs
_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Confirm\|Proceed"; then
	echo "  Configuration confirmation dialog — accepting"
	tui_keys Enter; sleep 3
fi

# ============================================================================
# 4. Platform selection page
# ============================================================================
echo ""
echo "--- 4. Platform selection ---"
tui_wait_for "Platform\|platform\|Bare\|metal\|VMware\|KVM" 10
tui_screenshot "wiz-04-platform"
tui_assert_contains "Bare\|bare" "Bare metal option"
tui_assert_contains "VMware\|vSphere\|vmw" "VMware option"
tui_assert_contains "KVM\|kvm\|libvirt" "KVM option"

# Check help
tui_press_button "Help"
sleep 2
tui_assert_contains "Bare metal\|physical" "Platform help mentions bare metal"
tui_assert_contains "VMware\|vSphere\|vCenter" "Platform help mentions VMware"
tui_screenshot "wiz-04b-platform-help"
tui_keys Enter; sleep 1

# Accept current platform
_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Platform\|platform\|Bare"; then
	tui_keys Enter; sleep 2
fi

# ============================================================================
# 5. Operator selection page
# ============================================================================
echo ""
echo "--- 5. Operator selection ---"
# This page may take time (catalog indexes)
tui_wait_for "Operator\|operator" 30
tui_screenshot "wiz-05-operators"

# Should show operator sets, search, view options
_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Operator"; then
	echo "  ✓ PASS: Operator selection page reached"
	_TUI_PASS=$(( _TUI_PASS + 1 ))

	# Check help
	tui_press_button "Help"
	sleep 2
	tui_assert_contains "Operator\|operator" "Operator help content"
	tui_screenshot "wiz-05b-operator-help"
	tui_keys Enter; sleep 1
fi

# ============================================================================
# 6. Cancel wizard (don't change config)
# ============================================================================
echo ""
echo "--- 6. Cancel wizard ---"
# Press Done/Back/Escape to exit without saving
tui_back_to "Actions" 8

# Verify we're back on main menu
tui_assert_contains "Actions" "Back on main menu after wizard cancel"
tui_screenshot "wiz-06-back"

# ============================================================================
# 7. Cleanup
# ============================================================================
echo ""
echo "--- 7. Cleanup ---"
tui_cleanup
tui_summary
