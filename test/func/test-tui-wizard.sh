#!/bin/bash
# Fast TUI wizard flow test using tmux
# Tests the full wizard from channel selection through to the action menu.
# Uses a light reset (remove aba.conf + pull secret) — no CLI re-downloads.
#
# Prerequisites:
#   - tmux installed
#   - ~/.pull-secret.json exists (will be backed up, removed, and pasted)
#   - Internet access (version fetch + pull secret validation)
#   - Run from aba root directory
#
# Usage: test/func/test-tui-wizard.sh

set -euo pipefail

# Source shared test library (also cd's to aba root)
source "$(dirname "$0")/tui-test-lib.sh"

# --- Precondition checks ---

if [[ ! -f "$HOME/.pull-secret.json" ]]; then
	echo "ERROR: ~/.pull-secret.json not found — needed for pull secret paste test"
	exit 1
fi

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

cleanup_wizard_test() {
	stop_tui
	restore_pull_secret
	restore_conf
}
trap cleanup_wizard_test EXIT

# --- Setup: light reset ---

log_info "=== Setup: light reset ==="
backup_pull_secret
backup_conf

rm -f aba.conf
rm -f "$HOME/.pull-secret.json"
log_info "Removed aba.conf and ~/.pull-secret.json"

# --- Start TUI ---
start_tui

# ============================================================
# Test 1: Welcome dialog appears
# ============================================================

log_info "Test 1: Welcome dialog"
dismiss_welcome

# ============================================================
# Test 2: Channel selection (no resume — config incomplete)
# ============================================================

log_info "Test 2: Channel selection (should skip resume)"
if wait_for "OpenShift Channel" 15; then
	log_pass "Channel dialog appeared (resume skipped — config incomplete)"
	screenshot "channel"
else
	log_fail "Channel dialog did not appear"
	log_info "Screen dump:"
	capture
	exit 1
fi

# Verify channel options
assert_screen "stable" "Channel option: stable"
assert_screen "fast" "Channel option: fast"
assert_screen "candidate" "Channel option: candidate"

# Accept default (stable) — OK button is "Next"
send Enter
sleep 1

# ============================================================
# Test 3: Version selection
# ============================================================

log_info "Test 3: Version selection"
if wait_for "OpenShift Version" 20; then
	log_pass "Version dialog appeared"
	screenshot "version"
else
	log_fail "Version dialog did not appear"
	exit 1
fi

assert_screen "Latest" "Version option: Latest"

# Accept default (Latest) — OK button is "Next"
send Enter
sleep 2

# ============================================================
# Test 4: Version confirmation
# ============================================================

log_info "Test 4: Version confirmation"
if wait_for "Confirm Selection" 10; then
	log_pass "Version confirmation dialog appeared"
else
	# Might show "Verifying" first
	if wait_for "Verifying" 5; then
		log_info "Version verification in progress..."
		if wait_for "Confirm Selection" 30; then
			log_pass "Version confirmation dialog appeared (after verification)"
		else
			log_fail "Version confirmation did not appear after verification"
			exit 1
		fi
	else
		log_fail "Version confirmation dialog did not appear"
		exit 1
	fi
fi

assert_screen "Channel:" "Confirmation shows Channel"
assert_screen "Version:" "Confirmation shows Version"

# Accept confirmation — Yes button is "Next"
send Enter
sleep 2

# ============================================================
# Test 5: Pull secret instructions
# ============================================================

log_info "Test 5: Pull secret instructions"
if wait_for "Red Hat Pull Secret" 10; then
	log_pass "Pull secret instructions appeared"
else
	log_fail "Pull secret instructions did not appear"
	exit 1
fi

assert_screen "pull secret" "Instructions mention pull secret"

# Press Continue
send Enter
sleep 1

# ============================================================
# Test 6: Pull secret paste (editbox)
# ============================================================

log_info "Test 6: Pull secret paste"
if wait_for "Paste JSON" 5; then
	log_pass "Pull secret editbox appeared"
else
	log_fail "Pull secret editbox did not appear"
	exit 1
fi

# Paste pull secret from backup via tmux buffer
log_info "Pasting pull secret via tmux buffer..."
paste_pull_secret "$_PS_BACKUP"

# Tab to OK/Next button, then press Enter
send Tab Enter
sleep 2

# ============================================================
# Test 7: Pull secret validation
# ============================================================

log_info "Test 7: Pull secret validation"
# May see "Validating" briefly, then auto-proceeds to Platform
# Wait for either the success flash or the Platform screen
if wait_for "Platform" 30; then
	log_pass "Reached Platform screen (pull secret validated)"
else
	# Check if validation failed
	if capture | grep -qi "failed\|error\|invalid"; then
		log_fail "Pull secret validation failed"
		log_info "Screen:"
		capture | head -20
		exit 1
	fi
	log_fail "Did not reach Platform screen after pull secret"
	exit 1
fi

# ============================================================
# Test 8: Platform & Network
# ============================================================

log_info "Test 8: Platform & Network"
screenshot "platform"
assert_screen "Platform" "Platform & Network dialog present"
assert_screen "Base Domain" "Shows Base Domain field"
assert_screen "Machine Network" "Shows Machine Network field"

# Tab from menu lands on Extra (Next) button, press Enter
send Tab Enter
sleep 2

# ============================================================
# Test 9: Operators
# ============================================================

log_info "Test 9: Operators"
if wait_for "Operators" 10; then
	log_pass "Operators dialog appeared"
	screenshot "operators"
else
	log_fail "Operators dialog did not appear"
	exit 1
fi

assert_screen "Select Operator" "Shows operator actions"

# Tab from menu lands on Extra (Next) button, press Enter
send Tab Enter
sleep 1

# ============================================================
# Test 10: Empty basket warning
# ============================================================

log_info "Test 10: Empty basket warning"
if wait_for "No operators\|Empty Basket\|empty basket" 5; then
	log_pass "Empty basket warning appeared"
else
	# Might have skipped to summary (if operators were pre-selected)
	if capture | grep -qi "Choose Next Action"; then
		log_pass "Skipped to action menu (operators may have been pre-selected)"
	else
		log_fail "Empty basket warning did not appear"
	fi
fi

# Accept — Yes button is "Continue Anyway"
send Enter
sleep 2

# ============================================================
# Test 11: Action menu appears
# ============================================================

log_info "Test 11: Action menu"
if wait_for "Choose Next Action" 20; then
	log_pass "Action menu appeared — full wizard complete!"
	screenshot "action-menu"
else
	log_fail "Action menu did not appear after wizard"
	log_info "Screen:"
	capture | head -25
	exit 1
fi

# Verify key menu items
for item in "View Generated ImageSet" "Air-Gapped" "Connected" "Rerun Wizard" "Settings" "Exit"; do
	assert_screen "$item" "Menu item present: $item"
done

# ============================================================
# Test 12: Exit TUI cleanly
# ============================================================

log_info "Test 12: Exit TUI cleanly"
send "9" Enter
sleep 2

if ! tmux has-session -t "$SESSION" 2>/dev/null; then
	log_pass "TUI session ended (clean exit)"
else
	log_fail "TUI did not exit cleanly"
fi

# ============================================================
# Summary
# ============================================================

report_results
