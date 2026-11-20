#!/bin/bash
# Test: TUI setup wizard — channel, version, platform, operators
# Navigates each wizard page, verifies content, and exercises field editing.
# Non-destructive: doesn't change aba.conf (cancels at the end).

cd "$(dirname "$0")/../.."
source test/func/tui-test-lib.sh

# Rename the pull secret out of the way, then put it back with mv.
_WIZ_PS=
_wiz_ps_restore() {
	[ -n "${_WIZ_PS:-}" ] || return 0
	local _away _orig
	_away=$(printf '%q' "${_WIZ_PS}.tui-away")
	_orig=$(printf '%q' "$_WIZ_PS")
	$_TUI_SSH "if [ -f $_away ]; then mv $_away $_orig; fi" || return 1
	if $_TUI_SSH "test -f $_orig"; then
		_WIZ_PS=
		return 0
	fi
	return 1
}
_wiz_ps_hide() {
	# Do not use an unquoted ~ in the remote case pattern. Bash expands it
	# before the match, so ~/.pull-secret.json never hits ~/*.
	_WIZ_PS=$($_TUI_SSH 'f=$(grep "^pull_secret_file=" "$HOME/aba/aba.conf" | head -1 | cut -d= -f2- | tr -d "\"'\''[:space:]"); [ -n "$f" ] || f="~/.pull-secret.json"; if [ "${f:0:2}" = "~/" ]; then f="$HOME/${f:2}"; elif [ "$f" = "~" ]; then f="$HOME"; fi; [ -f "$f" ] || exit 1; mv "$f" "$f.tui-away"; printf "%s\n" "$f"') || return 1
	[ -n "$_WIZ_PS" ]
}
trap '_wiz_ps_restore || true' EXIT

echo "=== TUI Wizard Test ==="
echo "  Host: $_TUI_HOST"
echo ""

tui_deploy_code
echo ""

# ============================================================================
tui_start_to_menu || { tui_summary; exit 1; }

# ============================================================================
# 1. Enter the wizard via "Rerun Wizard"
# ============================================================================
echo ""
echo "--- 1. Launch wizard ---"
if ! _wiz_ps_hide; then
	echo "  ✗ FAIL: could not rename the pull secret file"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	tui_summary
	exit 1
fi
echo "  Pull secret moved aside: $_WIZ_PS"
tui_select_item "Wizard"
sleep 3
tui_screenshot "wiz-01-start"

# The wizard may show "Resume Configuration" if aba.conf is already set up.
# Press "Reconfigure" to enter the wizard pages.
_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Resume Configuration\|Continue with this"; then
	tui_pass "Resume Configuration dialog appeared" "$_scr"
	tui_assert_contains "Channel" "Shows current channel"
	tui_assert_contains "Version" "Shows current version"
	tui_assert_contains "Platform" "Shows current platform"
	# Press Reconfigure (second button)
	tui_press_button "Reconfigure"
	sleep 3
fi

# The file is missing, so the wizard must show the pull-secret dialog.
# Submit the old path, require the not-found error, mv the file back,
# then submit the path again and continue.
if ! tui_wait_for "pull secret is required\|Pull Secret" 25; then
	echo "  ✗ FAIL: pull secret dialog did not appear"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	tui_screenshot "wiz-ps-missing-dialog"
	_wiz_ps_restore || true
	tui_summary
	exit 1
fi
tui_pass "Pull secret required dialog" "$(tui_capture)"
tui_press_button "Enter file path" || tui_keys Enter
sleep 1
tui_keys Enter
sleep 1
if tui_capture | grep -qi "File not found"; then
	tui_pass "Pull secret file-not-found dialog" "$(tui_capture)"
else
	echo "  ✗ FAIL: expected File not found after the pull secret was renamed"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	tui_screenshot "wiz-ps-no-error"
fi
if ! _wiz_ps_restore; then
	echo "  ✗ FAIL: could not move the pull secret back"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	tui_summary
	exit 1
fi
tui_keys Enter
sleep 1
tui_keys Enter
sleep 2

# ============================================================================
# 2. Channel selection page
# ============================================================================
echo ""
echo "--- 2. Channel selection ---"
tui_wait_for "Channel\|channel" 10
tui_assert_title "Channel" "Channel dialog title"
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
# "Fetching versions" contains the word version. Wait for the list itself.
tui_wait_for "Latest\|Manual entry" 60
tui_assert_title "Version" "Version dialog title"
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
tui_wait_for "Platform\|platform\|Bare\|metal\|VMware\|KVM" 30
tui_assert_title "Platform" "Platform dialog title"
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
# Fresh hosts (or broken registries.d) can interpose Podman Preflight Warning
# before Select Operators. Continue anyway — smoke already covers that dialog.
for _pw in 1 2 3; do
	_scr=$(tui_capture)
	if echo "$_scr" | grep -qi "Podman Preflight"; then
		echo "  Dismissing Podman Preflight Warning (Continue anyway)"
		tui_keys Enter; sleep 2
		continue
	fi
	break
done
# "Downloading operator catalog indexes" contains the word operator.
# Wait for the menu itself.
tui_wait_for "Select Operators\|Operator Sets" 120
tui_assert_title "Select Operators" "Operator selection dialog title"
tui_screenshot "wiz-05-operators"

# Should show operator sets, search, view options
_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Select Operators\|Operator Sets"; then
	tui_pass "Operator selection page reached" "$_scr"

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
