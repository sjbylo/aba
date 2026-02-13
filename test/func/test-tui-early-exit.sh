#!/bin/bash
# Test: Early wizard exit cleans up auto-created aba.conf
#
# Verifies that when aba.conf is freshly created by the TUI and the user
# quits before completing the wizard, the auto-created aba.conf is deleted
# (leaving a clean slate for the next run).
#
# This tests the _TUI_FRESH_CONF flag mechanism:
#   - Set in resume_from_conf() when aba.conf is created from template
#   - Cleared in summary_apply() when the wizard is completed
#   - Checked in _show_exit_summary() to decide whether to delete aba.conf
#
# Prerequisites:
#   - tmux installed
#   - Internet access (TUI startup fetches versions)
#   - Run from aba root directory
#
# Usage: test/func/test-tui-early-exit.sh

set -euo pipefail

# Source shared test library (also cd's to aba root)
source "$(dirname "$0")/tui-test-lib.sh"

# --- Backups ---

_CONF_BACKUP=""

backup_conf() {
	if [[ -f aba.conf ]]; then
		_CONF_BACKUP=$(mktemp /tmp/tui-test-conf-XXXXXX)
		cp aba.conf "$_CONF_BACKUP"
		log_info "Backed up aba.conf to $_CONF_BACKUP"
	fi
}

restore_conf() {
	if [[ -n "$_CONF_BACKUP" ]] && [[ -f "$_CONF_BACKUP" ]]; then
		cp "$_CONF_BACKUP" aba.conf
		rm -f "$_CONF_BACKUP"
		log_info "Restored aba.conf"
	fi
}

# --- Cleanup on exit ---

cleanup_early_exit_test() {
	stop_tui
	restore_conf
}
trap cleanup_early_exit_test EXIT

# --- Setup ---

log_info "=== Setup: remove aba.conf for fresh start ==="
backup_conf
rm -f aba.conf
log_info "Removed aba.conf"

# ============================================================
# Test 1: Start TUI, verify wizard starts (no resume dialog)
# ============================================================

start_tui

log_info "Test 1: Welcome dialog"
if wait_for "$TUI_TITLE_WELCOME" 15; then
	log_pass "Welcome dialog appeared"
else
	log_fail "Welcome dialog did not appear"
	exit 1
fi
send Enter
sleep 2

log_info "Test 2: Channel dialog (resume skipped)"
if wait_for "$TUI_TITLE_CHANNEL" 20; then
	log_pass "Channel dialog appeared (fresh start, no resume)"
else
	log_fail "Channel dialog did not appear"
	exit 1
fi

# ============================================================
# Test 3: Verify aba.conf was auto-created by the TUI
# ============================================================

log_info "Test 3: aba.conf auto-created during startup"
if [[ -f aba.conf ]]; then
	log_pass "aba.conf exists (auto-created by TUI)"
else
	log_fail "aba.conf was not created by TUI"
	exit 1
fi

# ============================================================
# Test 4: Quit early (ESC from channel dialog)
# ============================================================

log_info "Test 4: Quit early from channel dialog (ESC)"
send Escape
sleep 1

# Confirm quit dialog should appear
if wait_for "$TUI_TITLE_CONFIRM_EXIT" 5; then
	log_pass "Confirm exit dialog appeared"
else
	log_fail "Confirm exit dialog did not appear"
	exit 1
fi

# Press "Exit" (OK button — Enter confirms exit)
send Enter
sleep 3

# ============================================================
# Test 5: TUI session ended
# ============================================================

log_info "Test 5: TUI session ended"
if ! tmux has-session -t "$SESSION" 2>/dev/null; then
	log_pass "TUI session ended (clean exit)"
else
	log_fail "TUI did not exit cleanly"
fi

# ============================================================
# Test 6: aba.conf was deleted (early exit cleanup)
# ============================================================

log_info "Test 6: aba.conf should be deleted after early exit"
if [[ ! -f aba.conf ]]; then
	log_pass "aba.conf was deleted (early exit cleanup worked)"
else
	log_fail "aba.conf still exists after early exit (should have been deleted)"
	log_info "Contents:"
	head -5 aba.conf
fi

# ============================================================
# Summary
# ============================================================

report_results
