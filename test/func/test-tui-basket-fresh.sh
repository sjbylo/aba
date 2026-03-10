#!/bin/bash
# Test basket filling from a truly clean state (no cached indexes).
# Simulates a fresh install by removing .index/ and runner markers,
# then walks through the wizard and attempts to fill the basket.
#
# This is the SLOW test -- catalogs must be downloaded from scratch.
#
# Prerequisites:
#   - tmux, internet access
#   - ~/.pull-secret.json exists
set -euo pipefail

source "$(dirname "$0")/tui-test-lib.sh"

TIMEOUT=120

if [[ ! -f "$HOME/.pull-secret.json" ]]; then
	echo "ERROR: ~/.pull-secret.json not found"
	exit 1
fi

# --- Backups ---
backup_pull_secret

cleanup() {
	stop_tui
	restore_pull_secret
}
trap cleanup EXIT

# --- Full reset to simulate fresh install ---
log_info "=== Setup: full aba reset ==="
log_info "Running: aba reset -f"
make -s reset force=force 2>&1 | while IFS= read -r line; do
	log_info "  reset: $line"
done || true

# Remove the top-level .index/ entirely (simulates fresh clone)
if [[ -d .index ]]; then
	rm -rf .index
	log_info "Removed .index/ directory (simulating fresh clone)"
fi

# Remove catalog runner markers so TUI re-downloads
rm -rf "$HOME/.aba/runner/catalog:"* 2>/dev/null || true
log_info "Removed catalog runner markers"

log_info "Running: ./install"
sudo ./install -q 2>&1 | while IFS= read -r line; do
	log_info "  install: $line"
done || true

rm -f "$HOME/.pull-secret.json"
log_info "Removed ~/.pull-secret.json for paste test"

# Verify .index is gone
if [[ -d .index ]] && ls .index/*-index-* &>/dev/null; then
	log_fail ".index/ still has cached data after cleanup!"
else
	log_pass ".index/ is clean (no cached catalog indexes)"
fi

# --- Start TUI ---
start_tui

# 1. Welcome
log_info "Test: Welcome dialog"
if wait_for "$TUI_TITLE_WELCOME" 15; then
	log_pass "Welcome dialog appeared"
	screenshot "welcome"
else
	log_fail "Welcome dialog did not appear"; report_results; exit 1
fi
send Enter
sleep 1

# 2. Pull secret required -> Paste
log_info "Test: Pull secret required dialog"
if wait_for "$TUI_TITLE_PULL_SECRET_REQUIRED" 10; then
	log_pass "Pull secret required dialog appeared"
	screenshot "pull-secret-required"
else
	log_fail "Pull secret required dialog did not appear"; report_results; exit 1
fi
send Tab Enter
sleep 1

log_info "Test: Pull secret paste"
if wait_for "$TUI_TITLE_PULL_SECRET_PASTE" 10; then
	log_pass "Pull secret editbox appeared"
	screenshot "pull-secret-editbox"
else
	log_fail "Pull secret editbox did not appear"; report_results; exit 1
fi
log_info "Pasting pull secret via tmux buffer..."
paste_pull_secret "$_PS_BACKUP"
send Tab Enter
sleep 2

# 3. Channel
log_info "Test: Channel selection"
if wait_for "$TUI_TITLE_CHANNEL" 30; then
	log_pass "Reached Channel screen"
	screenshot "channel"
else
	log_fail "Channel screen did not appear"; report_results; exit 1
fi
send Enter
sleep 1

# 4. Version
log_info "Test: Version selection"
if wait_for "$TUI_TITLE_VERSION" 30; then
	log_pass "Version dialog appeared"
	screenshot "version"
else
	log_fail "Version dialog did not appear"; report_results; exit 1
fi
send Enter
sleep 2

# 5. Version confirmation
log_info "Test: Version confirmation"
if wait_for "$TUI_TITLE_CONFIRM" 15; then
	log_pass "Version confirmation appeared"
	screenshot "version-confirm"
	send Enter
elif wait_for "Verifying" 5; then
	log_info "Verification in progress..."
	if wait_for "$TUI_TITLE_CONFIRM" 60; then
		log_pass "Version confirmation appeared (after verification)"
		screenshot "version-confirm"
		send Enter
	else
		log_fail "Confirmation did not appear"; report_results; exit 1
	fi
else
	log_fail "Confirmation did not appear"; report_results; exit 1
fi
sleep 2

# 6. Platform & Network
log_info "Test: Platform & Network"
if wait_for "$TUI_TITLE_PLATFORM" 15; then
	log_pass "Platform screen appeared"
	screenshot "platform"
else
	log_fail "Platform screen did not appear"; report_results; exit 1
fi
send Tab Enter
sleep 2

# 7. Operators (may take a while as catalogs download from scratch)
log_info "Test: Operators screen (catalogs downloading from scratch...)"
if wait_for "$TUI_TITLE_OPERATORS" 300; then
	log_pass "Operators screen appeared"
	screenshot "operators-fresh"
else
	log_fail "Operators screen did not appear (catalog download may have failed)"
	screenshot "no-operators-fresh"
	report_results; exit 1
fi

# 8. Select Operator Sets (option 1)
log_info "Test: Open operator sets checklist (from fresh state)"
send Enter
sleep 2

if wait_for "$TUI_TITLE_OPERATOR_SETS\|spacebar\|Add to Basket" 15; then
	log_pass "Operator sets checklist appeared (from clean state)"
	screenshot "fresh-operator-sets"
else
	log_fail "Operator sets checklist did not appear"
	screenshot "no-fresh-sets"
	report_results; exit 1
fi

# 9. Toggle first set
log_info "Test: Add first operator set to basket (from fresh catalogs)"
send Space
sleep 0.5
screenshot "fresh-toggled-set"
send Enter
sleep 2

# Should return to operators menu
log_info "Test: Verify basket has operators after fresh catalog download"
if wait_for "$TUI_TITLE_OPERATORS" 10; then
	log_pass "Returned to operators menu"
	screenshot "fresh-operators-after-add"
else
	log_fail "Did not return to operators menu"
	screenshot "fresh-after-add-unexpected"
	report_results; exit 1
fi

cap=$(capture)
if echo "$cap" | grep -qiE 'Basket \(0 operators\)|Basket.*0 op'; then
	log_fail "Basket shows 0 operators after adding a set (fresh install)!"
	screenshot "fresh-basket-zero"
	report_results; exit 1
elif echo "$cap" | grep -qiE 'Basket \([1-9][0-9]* operators?\)'; then
	log_pass "Basket has operators (count > 0, from fresh catalogs)"
else
	log_fail "Cannot verify basket count from screen (fresh install)"
	screenshot "fresh-basket-unknown"
	report_results; exit 1
fi

# 10. Continue - should NOT show empty basket
log_info "Test: Continue past operators - must NOT show empty basket"
send Tab Enter
sleep 2

cap=$(capture)
screenshot "fresh-after-continue"
if echo "$cap" | grep -qi "$TUI_TITLE_EMPTY_BASKET"; then
	log_fail "EMPTY BASKET from fresh install! Catalog download or basket validation failed!"
else
	log_pass "No empty basket warning -- fresh basket fill WORKS"
fi

# Should reach action menu
if wait_for "$TUI_TITLE_ACTION_MENU" 15; then
	log_pass "Action menu appeared"
fi

# Exit
log_info "Test: Exit TUI"
send "$TUI_ACTION_EXIT" Enter
sleep 2
if ! tmux has-session -t "$SESSION" 2>/dev/null; then
	log_pass "TUI session ended (clean exit)"
else
	log_fail "TUI did not exit cleanly"
fi

report_results
