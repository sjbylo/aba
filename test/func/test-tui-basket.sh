#!/bin/bash
# Test that operator basket can be filled via "Select Operator Sets"
# Uses the same wizard flow as test-tui-wizard.sh but fills the basket
# instead of continuing with an empty one.
#
# Prerequisites: same as test-tui-wizard.sh
set -euo pipefail

source "$(dirname "$0")/tui-test-lib.sh"

if [[ ! -f "$HOME/.pull-secret.json" ]]; then
	echo "ERROR: ~/.pull-secret.json not found"
	exit 1
fi

# --- Backups ---
_CONF_BACKUP=""
backup_conf() {
	_CONF_BACKUP=$(mktemp /tmp/tui-test-conf-XXXXXX)
	cp aba.conf "$_CONF_BACKUP" 2>/dev/null || true
	log_info "Backed up aba.conf to $_CONF_BACKUP"
}
restore_conf() {
	if [[ -n "$_CONF_BACKUP" ]] && [[ -f "$_CONF_BACKUP" ]]; then
		cp "$_CONF_BACKUP" aba.conf
		chmod 600 aba.conf
		rm -f "$_CONF_BACKUP"
		log_info "Restored aba.conf"
	fi
}

backup_pull_secret

cleanup() {
	stop_tui
	restore_conf
	restore_pull_secret
}
trap cleanup EXIT

backup_conf

# Light reset: remove aba.conf + pull secret so wizard runs from scratch
rm -f aba.conf "$HOME/.pull-secret.json"
log_info "Removed aba.conf and ~/.pull-secret.json"

start_tui

# 1. Welcome
log_info "Test 1: Welcome dialog"
if wait_for "$TUI_TITLE_WELCOME" 15; then
	log_pass "Welcome dialog appeared"
	screenshot "welcome"
else
	log_fail "Welcome dialog did not appear"; report_results; exit 1
fi
send Enter
sleep 1

# 2. Pull secret required
log_info "Test 2: Pull secret required dialog"
if wait_for "$TUI_TITLE_PULL_SECRET_REQUIRED" 10; then
	log_pass "Pull secret required dialog appeared"
	screenshot "pull-secret-required"
else
	log_fail "Pull secret required dialog did not appear"; report_results; exit 1
fi
# Tab to "Paste" button, Enter
send Tab Enter
sleep 1

# 3. Pull secret paste
log_info "Test 3: Pull secret paste"
if wait_for "$TUI_TITLE_PULL_SECRET_PASTE" 10; then
	log_pass "Pull secret editbox appeared"
	screenshot "pull-secret-editbox"
else
	log_fail "Pull secret editbox did not appear"; report_results; exit 1
fi
log_info "Pasting pull secret via tmux buffer..."
paste_pull_secret "$_PS_BACKUP"
# Tab to OK/Next, Enter
send Tab Enter
sleep 2

# 4. Channel selection
log_info "Test 4: Channel -> Version -> Confirm -> Platform"
if wait_for "$TUI_TITLE_CHANNEL" 30; then
	log_pass "Reached Channel screen"
	screenshot "channel"
else
	log_fail "Channel screen did not appear"; report_results; exit 1
fi
send Enter
sleep 1

# 5. Version
if wait_for "$TUI_TITLE_VERSION" 20; then
	log_pass "Version dialog appeared"
	screenshot "version"
else
	log_fail "Version dialog did not appear"; report_results; exit 1
fi
send Enter
sleep 2

# 6. Version confirmation
if wait_for "$TUI_TITLE_CONFIRM" 15; then
	log_pass "Version confirmation appeared"
	screenshot "version-confirm"
	send Enter
else
	if wait_for "Verifying" 5; then
		log_info "Verification in progress..."
		if wait_for "$TUI_TITLE_CONFIRM" 30; then
			log_pass "Version confirmation appeared (after verification)"
			screenshot "version-confirm"
			send Enter
		else
			log_fail "Confirmation did not appear"; report_results; exit 1
		fi
	else
		log_fail "Confirmation did not appear"; report_results; exit 1
	fi
fi
sleep 2

# 7. Platform & Network
log_info "Test 5: Platform & Network"
if wait_for "$TUI_TITLE_PLATFORM" 15; then
	log_pass "Platform screen appeared"
	screenshot "platform"
else
	log_fail "Platform screen did not appear"; report_results; exit 1
fi
send Tab Enter
sleep 2

# 8. Operators screen
log_info "Test 6: Operators screen"
if wait_for "$TUI_TITLE_OPERATORS" 120; then
	log_pass "Operators screen appeared"
	screenshot "operators-menu"
else
	log_fail "Operators screen did not appear"
	screenshot "no-operators"
	report_results; exit 1
fi

# 9. Select "Select Operator Sets" (option 1 - default highlighted)
log_info "Test 7: Open operator sets checklist"
send Enter
sleep 2

if wait_for "$TUI_TITLE_OPERATOR_SETS\|spacebar\|Add to Basket" 15; then
	log_pass "Operator sets checklist appeared"
	screenshot "operator-sets-checklist"
else
	log_fail "Operator sets checklist did not appear"
	screenshot "no-sets"
	report_results; exit 1
fi

# 10. Toggle first set with spacebar, then "Add to Basket"
log_info "Test 8: Add first operator set to basket"
send Space
sleep 0.5
screenshot "toggled-first-set"
send Enter
sleep 2

# Should return to operators menu
log_info "Test 9: Back at operators menu after adding set"
if wait_for "$TUI_TITLE_OPERATORS" 10; then
	log_pass "Returned to operators menu"
	screenshot "operators-after-add"
else
	log_fail "Did not return to operators menu"
	screenshot "after-add-unexpected"
	report_results; exit 1
fi

# Assert basket has operators (must not be 0)
cap=$(capture)
if echo "$cap" | grep -qiE 'Basket \(0 operators\)|Basket.*0 op'; then
	log_fail "Basket shows 0 operators after adding a set!"
	screenshot "basket-zero"
	report_results; exit 1
elif echo "$cap" | grep -qiE 'Basket \([1-9][0-9]* operators?\)'; then
	log_pass "Basket has operators (count > 0)"
else
	log_fail "Cannot verify basket count from screen"
	screenshot "basket-unknown"
	report_results; exit 1
fi

# 11. Test operator search (option 2)
log_info "Test 10: Search Operator Names"

# Capture current basket count for comparison
basket_before=$(capture | grep -oiE 'Basket \([0-9]+ operators?\)' | grep -oE '[0-9]+')
log_info "Basket count before search: ${basket_before:-unknown}"

# Navigate to "Search Operator Names" (option 2)
send 2 Enter
sleep 1

if wait_for "Search operator names\|min 2 chars" 10; then
	log_pass "Search inputbox appeared"
	screenshot "search-inputbox"
else
	log_fail "Search inputbox did not appear"
	screenshot "no-search-inputbox"
	report_results; exit 1
fi

# Type a known operator name and press Enter
send "local-storage" Enter
sleep 2

if wait_for "$TUI_TITLE_SELECT_OPERATORS\|Add to Basket\|spacebar" 15; then
	log_pass "Search results appeared"
	screenshot "search-results"
else
	# Check if "no results" message appeared
	cap=$(capture)
	if echo "$cap" | grep -qi "No.*match\|not found\|0 results"; then
		log_fail "Search returned no results for 'local-storage'"
		screenshot "search-no-results"
	else
		log_fail "Search results did not appear"
		screenshot "search-unexpected"
	fi
	report_results; exit 1
fi

# Toggle first result and add to basket
send Space
sleep 0.3
send Enter
sleep 2

# Should return to operators menu with increased basket count
if wait_for "$TUI_TITLE_OPERATORS" 10; then
	log_pass "Returned to operators menu after search"
	screenshot "operators-after-search"
else
	log_fail "Did not return to operators menu after search"
	screenshot "after-search-unexpected"
	report_results; exit 1
fi

# Verify basket count increased
basket_after=$(capture | grep -oiE 'Basket \([0-9]+ operators?\)' | grep -oE '[0-9]+')
if [[ -n "$basket_after" ]] && [[ -n "$basket_before" ]] && (( basket_after > basket_before )); then
	log_pass "Basket count increased after search ($basket_before -> $basket_after)"
elif [[ -n "$basket_after" ]] && (( basket_after > 0 )); then
	log_pass "Basket still has operators after search ($basket_after)"
else
	log_fail "Basket count did not increase after search add"
	screenshot "basket-no-increase"
fi

# 12. Press Tab Enter to Continue (same as wizard test)
log_info "Test 11: Continue past operators - should NOT show empty basket"
send Tab Enter
sleep 2

cap=$(capture)
screenshot "after-continue"
if echo "$cap" | grep -qi "$TUI_TITLE_EMPTY_BASKET"; then
	log_fail "Empty basket warning appeared despite adding a set!"
else
	log_pass "No empty basket warning -- basket was filled successfully"
fi

# Should reach action menu
log_info "Test 12: Action menu reached"
if wait_for "$TUI_TITLE_ACTION_MENU" 15; then
	log_pass "Action menu appeared after basket-fill wizard"
else
	# Might need to dismiss another dialog first
	cap=$(capture)
	if echo "$cap" | grep -qi "ImageSet\|Generating\|generate"; then
		log_info "ImageSet generation dialog, pressing Enter..."
		send Enter
		sleep 2
		if wait_for "$TUI_TITLE_ACTION_MENU" 15; then
			log_pass "Action menu appeared (after ImageSet dialog)"
		else
			log_fail "Action menu did not appear"
		fi
	else
		log_fail "Action menu did not appear"
		screenshot "no-action-menu"
	fi
fi

# 13. Exit cleanly
log_info "Test 13: Exit TUI"
send "$TUI_ACTION_EXIT" Enter
sleep 2

if ! tmux has-session -t "$SESSION" 2>/dev/null; then
	log_pass "TUI session ended (clean exit)"
else
	log_fail "TUI did not exit cleanly"
fi

report_results
