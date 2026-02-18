#!/bin/bash
# Full clean-slate TUI test using tmux
# Runs 'aba reset -f && ./install' then walks through the entire wizard.
# This is the slow test — downloads oc-mirror, fetches versions from scratch.
#
# Prerequisites:
#   - tmux installed
#   - ~/.pull-secret.json exists (will be backed up, removed, and pasted)
#   - Internet access (downloads, version fetch, pull secret validation)
#   - Run from aba root directory
#
# Usage: test/func/test-tui-fresh.sh
#
# Estimated time: 2-5 minutes (depends on download speed)

set -euo pipefail

# Source shared test library (also cd's to aba root)
source "$(dirname "$0")/tui-test-lib.sh"

# Longer timeouts for the full reset test
TIMEOUT=60

# --- Precondition checks ---

if [[ ! -f "$HOME/.pull-secret.json" ]]; then
	echo "ERROR: ~/.pull-secret.json not found — needed for pull secret paste test"
	exit 1
fi

# --- Cleanup on exit ---

cleanup_fresh_test() {
	stop_tui
	restore_pull_secret
}
trap cleanup_fresh_test EXIT

# --- Setup: full reset ---

log_info "=== Setup: full aba reset ==="
backup_pull_secret

log_info "Running: aba reset -f"
make -s reset force=force 2>&1 | while IFS= read -r line; do
	log_info "  reset: $line"
done || true

log_info "Running: ./install"
sudo ./install -q 2>&1 | while IFS= read -r line; do
	log_info "  install: $line"
done || true

rm -f "$HOME/.pull-secret.json"
log_info "Removed ~/.pull-secret.json for paste test"

# --- Start TUI ---
start_tui

# ============================================================
# Test 1: Welcome dialog appears
# ============================================================

log_info "Test 1: Welcome dialog"
if wait_for "$TUI_TITLE_WELCOME" 15; then
	log_pass "Welcome dialog appeared"
	screenshot "welcome"
else
	log_fail "Welcome dialog did not appear"
	exit 1
fi
send Enter
sleep 2

# ============================================================
# Test 2: Pull secret instructions (first wizard step)
# ============================================================

log_info "Test 2: Pull secret instructions (fresh — no resume possible)"
if wait_for "$TUI_TITLE_PULL_SECRET" 20; then
	log_pass "Pull secret instructions appeared (fresh start)"
	screenshot "pull-secret-instructions"
else
	log_fail "Pull secret instructions did not appear"
	log_info "Screen dump:"
	capture
	exit 1
fi

# Press Continue
send Enter
sleep 1

# ============================================================
# Test 3: Pull secret paste
# ============================================================

log_info "Test 3: Pull secret paste (editbox)"
if wait_for "$TUI_TITLE_PULL_SECRET_PASTE" 5; then
	log_pass "Pull secret editbox appeared"
	screenshot "pull-secret-editbox"
else
	log_fail "Pull secret editbox did not appear"
	exit 1
fi

log_info "Pasting pull secret via tmux buffer..."
paste_pull_secret "$_PS_BACKUP"

# Tab to OK/Next button, Enter
send Tab Enter
sleep 2

# ============================================================
# Test 4: Pull secret validation -> Channel selection
# ============================================================

log_info "Test 4: Pull secret validation -> Channel selection"
if wait_for "$TUI_TITLE_CHANNEL" 45; then
	log_pass "Reached Channel screen (pull secret validated)"
	screenshot "channel"
else
	if capture | grep -qi "failed\|error\|invalid"; then
		log_fail "Pull secret validation failed"
		log_info "Screen:"
		capture | head -20
		exit 1
	fi
	log_fail "Did not reach Channel screen"
	exit 1
fi

assert_screen "stable" "Channel option: stable"

# Accept default (stable) — OK/Next
send Enter
sleep 1

# ============================================================
# Test 5: Version selection (may be slow — fetching from API)
# ============================================================

log_info "Test 5: Version selection (may take time — fetching from Red Hat)"

# Might see "Fetching" or "Please wait" first
if wait_for "$TUI_TITLE_VERSION" 60; then
	log_pass "Version dialog appeared"
	screenshot "version"
else
	log_fail "Version dialog did not appear (timeout 60s)"
	log_info "Screen:"
	capture | head -25
	exit 1
fi

assert_screen "Latest" "Version option: Latest"

# Accept default (Latest) — OK/Next
send Enter
sleep 2

# ============================================================
# Test 6: Version confirmation
# ============================================================

log_info "Test 6: Version confirmation"
# Version verification might take time on fresh start
if wait_for "$TUI_TITLE_CONFIRM" 45; then
	log_pass "Version confirmation appeared"
	screenshot "version-confirm"
else
	if wait_for "Verifying" 5; then
		log_info "Version verification in progress..."
		if wait_for "$TUI_TITLE_CONFIRM" 60; then
			log_pass "Version confirmation appeared (after verification)"
			screenshot "version-confirm"
		else
			log_fail "Version confirmation did not appear after verification"
			exit 1
		fi
	else
		log_fail "Version confirmation did not appear"
		exit 1
	fi
fi

# Accept — Yes/Next
send Enter
sleep 2

# ============================================================
# Test 7: Platform & Network
# ============================================================

log_info "Test 7: Platform & Network"
if wait_for "$TUI_TITLE_PLATFORM" 10; then
	log_pass "Reached Platform screen"
else
	log_fail "Did not reach Platform screen after version confirmation"
	exit 1
fi

# ============================================================
# Test 8: Platform & Network (details)
# ============================================================

log_info "Test 8: Platform & Network details"
screenshot "platform"
assert_screen "$TUI_TITLE_PLATFORM" "Platform & Network dialog present"
assert_screen "Base Domain" "Shows Base Domain field"

# Tab from menu lands on Extra (Next) button, press Enter
send Tab Enter
sleep 2

# ============================================================
# Test 9: Operators
# ============================================================

log_info "Test 9: Operators"
# On fresh start, might need to wait for catalog download
if wait_for "$TUI_TITLE_OPERATORS" 120; then
	log_pass "Operators dialog appeared"
	screenshot "operators"
else
	# Check if waiting for catalogs
	if capture | grep -qi "catalog\|Downloading\|Installing"; then
		log_info "Waiting for background downloads..."
		if wait_for "$TUI_TITLE_OPERATORS" 180; then
			log_pass "Operators dialog appeared (after downloads)"
			screenshot "operators"
		else
			log_fail "Operators dialog did not appear (timeout 180s)"
			exit 1
		fi
	else
		log_fail "Operators dialog did not appear"
		exit 1
	fi
fi

# Tab from menu lands on Extra (Next) button, press Enter
send Tab Enter
sleep 1

# ============================================================
# Test 10: Empty basket warning
# ============================================================

log_info "Test 10: Empty basket warning"
if wait_for "$TUI_TITLE_EMPTY_BASKET" 5; then
	log_pass "Empty basket warning appeared"
	screenshot "empty-basket"
else
	if capture | grep -qi "$TUI_TITLE_ACTION_MENU"; then
		log_pass "Skipped to action menu"
	else
		log_fail "Empty basket warning did not appear"
	fi
fi

# Accept — Continue Anyway
send Enter
sleep 2

# ============================================================
# Test 11: Action menu
# ============================================================

log_info "Test 11: Action menu"
if wait_for "$TUI_TITLE_ACTION_MENU" 30; then
	log_pass "Action menu appeared — full fresh wizard complete!"
	screenshot "action-menu"
else
	log_fail "Action menu did not appear"
	log_info "Screen:"
	capture | head -25
	exit 1
fi

for item in "$TUI_ACTION_LABEL_VIEW_IMAGESET" "Air-Gapped" "Connected" "$TUI_ACTION_LABEL_RERUN_WIZARD" "$TUI_TITLE_SETTINGS" "$TUI_ACTION_LABEL_EXIT"; do
	assert_screen "$item" "Menu item present: $item"
done

# ============================================================
# Test 12: Exit TUI cleanly
# ============================================================

log_info "Test 12: Exit TUI cleanly"
send "$TUI_ACTION_EXIT" Enter
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
