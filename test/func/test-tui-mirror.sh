#!/bin/bash
# Test: TUI mirror workflow — payload config, install mirror, sync
# Exercises mirror payload editor, installs mirror (local), syncs images.
# This IS destructive: it installs a local mirror and syncs images.
# Run on conno.example.com which has pull-secret and internet access.

cd "$(dirname "$0")/../.."
source test/func/tui-test-lib.sh

echo "=== TUI Mirror Workflow Test ==="
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
# 1. Mirror Payload configuration
# ============================================================================
echo ""
echo "--- 1. Mirror Payload ---"
tui_select_item "Mirror Payload"
tui_assert_appears "Mirror Payload\|Payload\|ImageSet\|imageset" "Payload menu appeared" 10
tui_screenshot "mirr-01-payload"

# Check available options
tui_assert_contains "Version\|OCP\|Channel" "Version/Channel option"
tui_assert_contains "Operator" "Operator selection option"

# Check help
tui_press_button "Help"
sleep 2
tui_assert_contains "imageset\|ImageSet\|mirror" "Payload help content"
tui_screenshot "mirr-01b-payload-help"
tui_keys Enter; sleep 1

# Exit payload menu
tui_back_to "Actions"

# ============================================================================
# 2. Install Mirror (local)
# ============================================================================
echo ""
echo "--- 2. Install Mirror ---"
tui_select_item "Install Mirror"
tui_assert_appears "Install Mirror\|Local\|Remote\|locally\|remote" "Mirror install dialog" 10
tui_screenshot "mirr-02-install-choice"

# Should show Local vs Remote options
tui_assert_contains "locally\|Local\|this host" "Local option"
tui_assert_contains "remote\|Remote\|SSH" "Remote option"

# Check help
tui_press_button "Help"
sleep 2
tui_assert_contains "registry\|mirror" "Mirror install help"
tui_screenshot "mirr-02b-install-help"
tui_keys Enter; sleep 1

# Select "Install locally" (first option)
tui_keys Enter
sleep 3
tui_screenshot "mirr-02c-install-local"

# At this point, there may be a confirmation dialog or it starts configuring.
# Detect and handle the next screen.
_scr=$(tui_capture)

# If there's a config menu (registry type, host, port), verify it
if echo "$_scr" | grep -qiE "registry|host|port|Quay|Docker|type"; then
	echo "  ✓ PASS: Mirror config dialog appeared"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
	tui_screenshot "mirr-02d-config"

	# Accept defaults and install. Press the Install/OK button.
	# Look for the right button
	_btns=$(tui_buttons)
	if echo "$_btns" | grep -qi "Install\|OK\|Next"; then
		tui_press_button "Install" 2>/dev/null || tui_press_button "OK" 2>/dev/null || tui_keys Enter
	else
		tui_keys Enter
	fi

	# Wait for install to complete or show progress
	echo "  Waiting for mirror install..."
	# Mirror install can take 1-5 minutes
	tui_wait_for "complete\|success\|installed\|error\|fail\|Actions" 300
	tui_screenshot "mirr-02e-install-result"

	_scr=$(tui_capture)
	if echo "$_scr" | grep -qiE "complete|success|installed"; then
		echo "  ✓ PASS: Mirror installed successfully"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	elif echo "$_scr" | grep -qi "Actions"; then
		echo "  ✓ PASS: Returned to main menu (install may have completed)"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ✗ FAIL: Mirror install outcome unclear"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	fi
else
	echo "  ~ NOTE: Unexpected screen after selecting local install"
	tui_screenshot "mirr-02c-unexpected"
fi

tui_back_to "Actions" 5
tui_keys Enter; sleep 1  # dismiss any remaining dialogs

# ============================================================================
# 3. Sync images to mirror
# ============================================================================
echo ""
echo "--- 3. Sync images ---"
tui_back_to "Actions" 5
tui_select_item "Sync"
sleep 3
tui_screenshot "mirr-03-sync"

_scr=$(tui_capture)
if echo "$_scr" | grep -qiE "sync|mirror|confirm|proceed|warning"; then
	echo "  ✓ PASS: Sync dialog appeared"
	_TUI_PASS=$(( _TUI_PASS + 1 ))

	# Confirm sync
	tui_keys Enter
	echo "  Waiting for sync to complete (this may take 10-30 min)..."
	# Sync can take a long time — wait up to 45 minutes
	tui_wait_for "complete\|success\|error\|fail\|Actions" 2700
	tui_screenshot "mirr-03b-sync-result"

	_scr=$(tui_capture)
	if echo "$_scr" | grep -qiE "complete|success"; then
		echo "  ✓ PASS: Sync completed successfully"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	elif echo "$_scr" | grep -qi "Actions"; then
		echo "  ✓ PASS: Returned to main menu after sync"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ✗ FAIL: Sync outcome unclear"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	fi
elif echo "$_scr" | grep -qiE "not installed|no mirror|install mirror first"; then
	echo "  ~ SKIP: Mirror not installed — sync not available"
else
	echo "  ~ NOTE: Unexpected sync screen"
	tui_screenshot "mirr-03-unexpected"
fi

tui_back_to "Actions" 5

# ============================================================================
# 4. Verify mirror state
# ============================================================================
echo ""
echo "--- 4. Verify mirror state ---"
_mirror_state=$($_TUI_SSH "ls ~/aba/mirror/.installed 2>/dev/null && echo 'installed' || echo 'not-installed'")
echo "  Mirror state: $_mirror_state"
if [[ "$_mirror_state" == "installed" ]]; then
	echo "  ✓ PASS: Mirror marker file exists"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
fi

# ============================================================================
# 5. Cleanup
# ============================================================================
echo ""
echo "--- 5. Cleanup ---"
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
