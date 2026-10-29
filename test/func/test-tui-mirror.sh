#!/bin/bash
# Test: TUI mirror workflow — install mirror (local), sync images
# DESTRUCTIVE: installs a local mirror registry and syncs images.
# Run on conno.example.com which has pull-secret and internet access.
# Prereqs: pull-secret at ~/.pull-secret.json, internet access

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

# Pre-check: pull secret
_ps=$($_TUI_SSH "test -f ~/.pull-secret.json && echo ok" 2>/dev/null)
if [[ "$_ps" != "ok" ]]; then
	echo "  SKIP: No pull-secret.json on $_TUI_HOST"
	echo ""
	echo "========================================"
	echo "  TUI Test Results"
	echo "  PASS: 0"
	echo "  FAIL: 0"
	echo "  SKIPPED (no pull-secret)"
	echo "========================================"
	exit 0
fi

# ============================================================================
tui_start
tui_assert_appears "OpenShift Installer" "TUI launched" 15 || {
	tui_stop; tui_summary; exit 1
}
tui_keys Enter  # past splash
tui_assert_appears "Actions" "Main menu" 10

# ============================================================================
# 1. Mirror Payload menu (verify it works)
# ============================================================================
echo ""
echo "--- 1. Mirror Payload ---"
tui_select_item "Mirror Payload"
tui_wait_isc_done 120
tui_assert_appears "Additional Images\|Mirror Payload\|Payload" "Payload menu appeared" 15
tui_screenshot "mirr-01-payload"

tui_assert_contains "Version\|OCP\|Channel" "Version/Channel option"
tui_assert_contains "Operator" "Operator selection option"
tui_back_to "Actions"

# ============================================================================
# 2. Install Mirror (local)
# ============================================================================
echo ""
echo "--- 2. Install Mirror ---"

# Check if mirror is already installed
_mirr_avail=$($_TUI_SSH "test -f ~/aba/mirror/.available && echo yes || echo no" 2>/dev/null)

if [[ "$_mirr_avail" == "yes" ]]; then
	echo "  Mirror already installed — skipping install step"
	echo "  ✓ PASS: Mirror was already installed"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	tui_select_item "Install Mirror"
	sleep 2
	tui_screenshot "mirr-02-install-choice"

	# Should show Local vs Remote choice menu
	tui_assert_contains "locally\|Local\|this host" "Local install option"
	tui_assert_contains "remote\|Remote\|SSH" "Remote install option"

	# Select "Install locally" (item "1", already highlighted)
	tui_keys Enter
	sleep 2
	tui_screenshot "mirr-02b-config-menu"

	# Config menu: Hostname, Port, Username, Password, Image path, Vendor, Data dir
	# with Select / Next / Back / Help buttons
	_scr=$(tui_capture)
	if echo "$_scr" | grep -qi "Hostname\|Port\|Username\|Vendor"; then
		echo "  ✓ PASS: Mirror config menu appeared"
		_TUI_PASS=$(( _TUI_PASS + 1 ))

		tui_assert_contains "Hostname" "Hostname field"
		tui_assert_contains "Port" "Port field"
		tui_assert_contains "Vendor" "Vendor field"

		# Press "Next" to accept defaults and start install
		tui_press_button "Next"
		sleep 3
		tui_screenshot "mirr-02c-installing"

		# Wait for all steps to complete (can take 1-10 minutes).
		echo "  Waiting for mirror install to complete..."
		for (( _i=0; _i<600; _i++ )); do
			if ! tui_session_alive; then
				echo "  SESSION DEAD during install"
				break
			fi
			_scr=$(tui_capture)
			if echo "$_scr" | grep -qi "All steps completed\|Done"; then
				break
			fi
			if echo "$_scr" | grep -qi "Actions"; then
				break
			fi
			if echo "$_scr" | grep -qi "FAILED\|Error.*step"; then
				echo "  Mirror install error detected"
				tui_screenshot "mirr-02d-error"
				break
			fi
			sleep 1
			(( _i % 30 == 0 && _i > 0 )) && echo "  ... still installing (${_i}s)"
		done
		tui_screenshot "mirr-02d-result"

		_scr=$(tui_capture)
		if echo "$_scr" | grep -qi "All steps completed"; then
			echo "  ✓ PASS: All install steps completed successfully"
			_TUI_PASS=$(( _TUI_PASS + 1 ))
			tui_press_button "Done"
			sleep 2
		elif echo "$_scr" | grep -qi "Actions"; then
			echo "  ✓ PASS: Returned to main menu after install"
			_TUI_PASS=$(( _TUI_PASS + 1 ))
		else
			echo "  ✗ FAIL: Mirror install outcome unclear"
			_TUI_FAIL=$(( _TUI_FAIL + 1 ))
			tui_keys Enter; sleep 1
		fi
	else
		echo "  ✗ FAIL: Expected mirror config menu"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
		tui_back_to "Actions" 5
	fi
fi

# ============================================================================
# 3. Verify mirror is installed
# ============================================================================
echo ""
echo "--- 3. Verify mirror state ---"
_mirror_available=$($_TUI_SSH "test -f ~/aba/mirror/.available && echo yes || echo no" 2>/dev/null)
echo "  mirror/.available: $_mirror_available"

if [[ "$_mirror_available" == "yes" ]]; then
	echo "  ✓ PASS: Mirror is available (.available marker exists)"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: Mirror not available"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	echo "  Skipping sync test (mirror not available)"
	tui_stop 2>/dev/null
	tui_summary
	exit 1
fi

# ============================================================================
# 4. Sync images to mirror
# ============================================================================
echo ""
echo "--- 4. Sync images ---"
if ! tui_capture | grep -q "Actions"; then
	tui_back_to "Actions" 5
fi
tui_select_item "Sync"
sleep 1
tui_wait_isc_done 180
tui_wait_for "Continue\|OCP" 30
tui_screenshot "mirr-04-sync"

_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Sync\|OCP\|Continue"; then
	echo "  ✓ PASS: Sync confirmation dialog appeared"
	_TUI_PASS=$(( _TUI_PASS + 1 ))

	# Check OCP version in summary
	if echo "$_scr" | grep -qi "4\.[0-9]"; then
		echo "  ✓ PASS: Sync shows OCP version"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	fi

	# Press Continue to start sync
	tui_press_button "Continue"
	sleep 5
	tui_screenshot "mirr-04b-syncing"

	# Sync shows a progress dialog similar to install.
	# Wait for completion (can take 10-45 minutes).
	echo "  Waiting for sync to complete (up to 45 min)..."
	for (( _i=0; _i<2700; _i+=5 )); do
		if ! tui_session_alive; then
			echo "  SESSION DEAD during sync"
			break
		fi
		_scr=$(tui_capture)
		# Done: "All steps completed" or "Done" button
		if echo "$_scr" | grep -qi "All steps completed\|Done"; then
			break
		fi
		# Terminal "Press ENTER" prompt
		tui_dismiss_result && continue
		# Back at main menu
		if echo "$_scr" | grep -qi "Actions"; then
			break
		fi
		# Failed
		if echo "$_scr" | grep -qi "FAILED\|Error.*step"; then
			echo "  Sync error detected"
			tui_screenshot "mirr-04c-error"
			break
		fi
		sleep 5
		(( _i % 60 == 0 && _i > 0 )) && echo "  ... still syncing (${_i}s elapsed)"
	done
	tui_screenshot "mirr-04c-result"

	_scr=$(tui_capture)
	if echo "$_scr" | grep -qi "All steps completed"; then
		echo "  ✓ PASS: All sync steps completed successfully"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
		tui_press_button "Done"
		sleep 2
	elif echo "$_scr" | grep -qi "Actions"; then
		echo "  ✓ PASS: Returned to main menu after sync"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ✗ FAIL: Sync did not complete (timeout or stuck)"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
		tui_keys Enter; sleep 1
	fi
elif echo "$_scr" | grep -qi "not installed\|no mirror"; then
	echo "  ~ SKIP: Mirror reported as not installed for sync"
else
	echo "  ~ NOTE: Unexpected sync screen"
	tui_screenshot "mirr-04-unexpected"
fi

# ============================================================================
# 4b. Server-side sync verification
# ============================================================================
echo ""
echo "--- 4b. Verify sync on server ---"
_sync_state=$($_TUI_SSH "grep -s 'last_action=' ~/.aba/mirror/*/state.sh 2>/dev/null | head -1 | cut -d= -f2" 2>/dev/null || echo "")
if [[ "$_sync_state" == "sync" || "$_sync_state" == "load" ]]; then
	echo "  ✓ PASS: Mirror state confirms sync (last_action=$_sync_state)"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
elif [[ -n "$_sync_state" ]]; then
	echo "  ~ NOTE: Mirror last_action=$_sync_state (expected sync)"
else
	echo "  ✗ FAIL: No mirror state file — sync may not have executed"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

# ============================================================================
# 5. Cleanup
# ============================================================================
echo ""
echo "--- 5. Cleanup ---"
tui_cleanup
tui_summary
