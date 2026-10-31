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

tui_deploy_code
tui_pre_cleanup
echo ""

# Pre-check: pull secret
_ps=$($_TUI_SSH "test -f ~/.pull-secret.json && echo ok" 2>/dev/null)
if [[ "$_ps" != "ok" ]]; then
	echo "  ✗ FAIL: No pull-secret.json on $_TUI_HOST — cannot run mirror test"
	_TUI_FAIL=1; tui_summary; exit 1
fi

# ============================================================================
tui_start_to_menu || { tui_summary; exit 1; }

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

_mirr_avail=$($_TUI_SSH "test -f ~/aba/mirror/.available && echo yes || echo no" 2>/dev/null)

if [[ "$_mirr_avail" == "yes" ]]; then
	echo "  Mirror already installed — skipping install step"
	echo "  ✓ PASS: Mirror was already installed"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	# Verify the config menu UI (first time only)
	tui_select_item "Install Mirror"
	sleep 2
	tui_screenshot "mirr-02-install-choice"

	tui_assert_contains "locally\|Local\|this host" "Local install option"
	tui_assert_contains "remote\|Remote\|SSH" "Remote install option"

	tui_keys Enter
	sleep 2
	tui_screenshot "mirr-02b-config-menu"

	_scr=$(tui_capture)
	if ! echo "$_scr" | grep -qi "Hostname\|Port\|Username\|Vendor"; then
		echo "  ✗ FAIL: Expected mirror config menu"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
		tui_back_to "Actions" 5
	else
		echo "  ✓ PASS: Mirror config menu appeared"
		_TUI_PASS=$(( _TUI_PASS + 1 ))

		tui_assert_contains "Hostname" "Hostname field"
		tui_assert_contains "Port" "Port field"
		tui_assert_contains "Vendor" "Vendor field"

		# Navigate to install and start it
		_nav_mirror_install() {
			tui_back_to "Actions" 5
			tui_select_item "Install Mirror"
			sleep 2
			tui_keys Enter; sleep 2    # select "locally"
			tui_press_button "Next"
			sleep 3
		}

		tui_screenshot "mirr-02c-installing"

		if tui_run_operation "mirr-install" _nav_mirror_install 3 600; then
			echo "  ✓ PASS: Mirror install completed"
			_TUI_PASS=$(( _TUI_PASS + 1 ))
			tui_screenshot "mirr-02d-result"
			tui_dismiss_result
		else
			echo "  ✗ FAIL: Mirror install did not complete after retries"
			_TUI_FAIL=$(( _TUI_FAIL + 1 ))
		fi
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

# Navigate to sync, confirm, and start it
_nav_sync() {
	tui_back_to "Actions" 5
	tui_select_item "Sync"
	sleep 1
	tui_wait_isc_done 180
	tui_wait_for "Continue\|OCP" 30

	_scr=$(tui_capture)
	if echo "$_scr" | grep -qi "not installed\|no mirror"; then
		echo "  ~ SKIP: Mirror reported as not installed for sync"
		return 1
	fi

	tui_screenshot "mirr-04-sync"
	tui_press_button "Continue"
	sleep 5
	tui_screenshot "mirr-04b-syncing"
}

# First pass: verify the sync confirmation dialog content
tui_back_to "Actions" 5
tui_select_item "Sync"
sleep 1
tui_wait_isc_done 180
tui_wait_for "Continue\|OCP" 30

_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Sync\|OCP\|Continue"; then
	echo "  ✓ PASS: Sync confirmation dialog appeared"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
	if echo "$_scr" | grep -qi "4\.[0-9]"; then
		echo "  ✓ PASS: Sync shows OCP version"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	fi
fi

# Start sync and wait with retry
tui_press_button "Continue"
sleep 5
tui_screenshot "mirr-04b-syncing"

if tui_wait_for_progress "mirr-sync" 2700; then
	echo "  ✓ PASS: Sync completed successfully"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
	tui_screenshot "mirr-04c-result"
	tui_dismiss_result
else
	# First attempt failed — use tui_run_operation for full outer retry
	echo "  Sync failed on first attempt — retrying with full re-navigation..."
	tui_dismiss_error
	sleep 3

	if tui_run_operation "mirr-sync" _nav_sync 2 2700; then
		echo "  ✓ PASS: Sync completed on retry"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
		tui_screenshot "mirr-04c-result"
		tui_dismiss_result
	else
		echo "  ✗ FAIL: Sync did not complete after retries"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	fi
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
