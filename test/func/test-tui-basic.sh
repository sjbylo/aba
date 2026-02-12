#!/bin/bash
# Basic TUI automated test using tmux
# Tests the resume dialog and action menu navigation
#
# Prerequisites:
#   - tmux installed
#   - aba.conf exists with valid config (channel, version, pull secret, domain)
#   - Run from aba root directory
#
# Usage: test/func/test-tui-basic.sh

set -euo pipefail

# Source shared test library (also cd's to aba root)
source "$(dirname "$0")/tui-test-lib.sh"

# --- Precondition checks ---

if [[ ! -f aba.conf ]]; then
	echo "ERROR: aba.conf not found — need existing config for resume test"
	exit 1
fi

# --- Cleanup on exit ---
trap stop_tui EXIT

# --- Start TUI ---
start_tui

# ============================================================
# Test 0: Welcome dialog appears
# ============================================================

log_info "Test 0: Welcome dialog should appear"
if wait_for "OpenShift Installer" 15; then
	log_pass "Welcome dialog appeared"
	screenshot "welcome"
else
	log_fail "Welcome dialog did not appear"
	exit 1
fi
send Enter
sleep 2

# ============================================================
# Test 1: Resume dialog appears (config already exists)
# ============================================================

log_info "Test 1: Resume dialog should appear"
if wait_for "Existing Configuration Found" 15; then
	log_pass "Resume dialog appeared"
	screenshot "resume-dialog"
else
	# Config might not be complete — might go straight to wizard
	if capture | grep -qi "channel"; then
		log_info "No resume dialog — config may be incomplete, wizard started"
		log_pass "Wizard started (resume skipped — config incomplete)"
		echo ""
		echo "(Resume dialog not shown — remaining tests skipped)"
		report_results
		exit $?
	fi
	log_fail "Resume dialog did not appear"
	exit 1
fi

# Verify config summary is displayed
assert_screen "Channel:" "Config summary shows Channel"
assert_screen "Version:" "Config summary shows Version"
assert_screen "Domain:" "Config summary shows Domain"

# ============================================================
# Test 2: Press Continue -> action menu appears
# ============================================================

log_info "Test 2: Press Continue to reach action menu"
send Enter
sleep 2

if wait_for "Choose Next Action" 20; then
	log_pass "Action menu appeared"
	screenshot "action-menu"
else
	log_fail "Action menu did not appear"
	exit 1
fi

# Verify key menu items are present
for item in "View Generated ImageSet" "Air-Gapped" "Connected" "Rerun Wizard" "Settings" "Advanced" "Exit"; do
	assert_screen "$item" "Menu item present: $item"
done

# ============================================================
# Test 3: Open Settings sub-menu and return
# ============================================================

log_info "Test 3: Navigate to Settings sub-menu"
send "7" Enter
sleep 1

if wait_for "Settings" 5; then
	log_pass "Settings dialog appeared"
	screenshot "settings"
else
	log_fail "Settings dialog did not appear"
fi

assert_screen "Auto-answer" "Settings shows Auto-answer toggle"

# Press Back to return
send Escape
sleep 1

if wait_for "Choose Next Action" 5; then
	log_pass "Returned to action menu from Settings"
else
	log_fail "Did not return to action menu from Settings"
fi

# ============================================================
# Test 4: Exit TUI cleanly
# ============================================================

log_info "Test 4: Exit TUI cleanly"
send "9" Enter
sleep 2

# Check if session ended
if ! tmux has-session -t "$SESSION" 2>/dev/null; then
	log_pass "TUI session ended (clean exit)"
else
	log_fail "TUI did not exit cleanly"
fi

# ============================================================
# Summary
# ============================================================

report_results
