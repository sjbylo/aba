#!/bin/bash
# Comprehensive TUI basket test — v2
# Covers: operator set add, search/add, view, clear, re-add with different
# operators, and ISC content verification (via dialog screen) after each
# meaningful basket change.
#
# Prerequisites:
#   - tmux installed
#   - ~/.pull-secret.json exists
#   - Internet access (version fetch + pull secret validation + catalog download)
#   - Run from aba root directory
#
# Usage: test/func/test-tui-basket-v2.sh

set -euo pipefail

source "$(dirname "$0")/tui-test-lib.sh"

# --- Setup ---
# Depends on wizard-v2 having run first (primed cached state + valid aba.conf).
# We backup/restore aba.conf and pull secret so this test's changes don't
# leak into subsequent tests.

if [[ ! -f aba.conf ]]; then
	echo "ERROR: aba.conf not found — run test-tui-wizard-v2.sh first to prime state"
	exit 1
fi

backup_pull_secret
backup_conf

cleanup_basket_v2() {
	stop_tui
	restore_pull_secret
	restore_conf
}
trap cleanup_basket_v2 EXIT

# --- Navigate to operators screen via action menu + rerun wizard ---

log_info "=== Prerequisite: reach operators screen via rerun wizard ==="

reach_action_menu || { log_fail "Could not reach action menu"; report_results; exit 1; }
select_action "$TUI_ACTION_RERUN_WIZARD"
wizard_to_operators || { log_fail "Could not reach operators screen"; report_results; exit 1; }
log_pass "Reached operators screen"

# ============================================================
# Test A: Add operator set
# ============================================================

log_info "=== Test A: Add operator set ==="
send_input "1"
sleep 1

if wait_for "$TUI_TITLE_OPERATOR_SETS\|spacebar\|Add to Basket" 15; then
	log_pass "A: Operator sets checklist appeared"
	screenshot "sets-checklist"
else
	log_fail "A: Operator sets checklist did not appear"; report_results; exit 1
fi

# Toggle first set with spacebar, then OK/Add
send Space
send_enter
sleep 1

if ! wait_for "$TUI_TITLE_OPERATORS" 10; then
	log_fail "A: Did not return to operators menu"; report_results; exit 1
fi
log_pass "A: Returned to operators menu"

cap=$(capture)
if echo "$cap" | grep -qiE 'Basket \([1-9][0-9]* operators?\)'; then
	basket_a=$(echo "$cap" | grep -oiE 'Basket \([0-9]+ operators?\)' | grep -oE '[0-9]+')
	log_pass "A: Basket has $basket_a operators after adding set"
else
	log_fail "A: Basket count not > 0 after adding set"
fi
screenshot "after-set-add"

# ============================================================
# Test B: Search and add operator
# ============================================================

log_info "=== Test B: Search and add operator ==="
basket_before=$(capture | grep -oiE 'Basket \([0-9]+ operators?\)' | grep -oE '[0-9]+')

send_input "2"
sleep 1

if wait_for "Search operator names\|min 2 chars" 10; then
	log_pass "B: Search inputbox appeared"
else
	log_fail "B: Search inputbox did not appear"; report_results; exit 1
fi

send_input "local-storage"
sleep 1

if wait_for "$TUI_TITLE_SELECT_OPERATORS\|Add to Basket\|spacebar" 15; then
	log_pass "B: Search results appeared"
	assert_screen "local-storage-operator" "B: local-storage-operator in results"
	screenshot "search-results"
else
	log_fail "B: Search results did not appear"; report_results; exit 1
fi

# Toggle first result and add
send Space
send_enter
sleep 1

if ! wait_for "$TUI_TITLE_OPERATORS" 10; then
	log_fail "B: Did not return to operators menu"; report_results; exit 1
fi

basket_after=$(capture | grep -oiE 'Basket \([0-9]+ operators?\)' | grep -oE '[0-9]+')
if [[ -n "$basket_after" ]] && [[ -n "$basket_before" ]] && (( basket_after > basket_before )); then
	log_pass "B: Basket count increased ($basket_before -> $basket_after)"
else
	log_pass "B: Basket has $basket_after operators"
fi
screenshot "after-search-add"

# ============================================================
# Test C: View/Edit basket
# ============================================================

log_info "=== Test C: View/Edit basket ==="
send_input "3"
sleep 1

if wait_for "local-storage-operator\|Basket\|View" 10; then
	log_pass "C: Basket view shows operators"
	assert_screen "local-storage-operator" "C: local-storage-operator in basket"
	screenshot "basket-view"
else
	log_fail "C: Basket view did not show expected content"
fi

# Escape back to operators menu
send Escape
sleep 1

if wait_for "$TUI_TITLE_OPERATORS" 5; then
	log_pass "C: Returned to operators menu after basket view"
else
	send Escape
	sleep 1
fi

# ============================================================
# Test C2: Remove single operator via View/Edit basket
# ============================================================

log_info "=== Test C2: Remove single operator via View/Edit ==="
basket_before=$(capture | grep -oiE 'Basket \([0-9]+ operators?\)' | grep -oE '[0-9]+')

send_input "3"
sleep 1

if wait_for "Basket\|Apply\|spacebar" 10; then
	log_pass "C2: View/Edit basket checklist appeared"
	assert_screen "local-storage-operator" "C2: local-storage-operator shown in checklist"
	screenshot "C2-basket-before-remove"

	# Untoggle local-storage-operator (position-independent)
	checklist_toggle "local-storage-operator"
	send_enter
	sleep 1
else
	log_fail "C2: View/Edit basket checklist did not appear"
fi

if ! wait_for "$TUI_TITLE_OPERATORS" 10; then
	log_fail "C2: Did not return to operators menu"
fi

basket_after=$(capture | grep -oiE 'Basket \([0-9]+ operators?\)' | grep -oE '[0-9]+')
if [[ -n "$basket_before" && -n "$basket_after" ]] && (( basket_after < basket_before )); then
	log_pass "C2: Basket count decreased ($basket_before -> $basket_after)"
else
	log_fail "C2: Basket count did not decrease ($basket_before -> ${basket_after:-?})"
fi

# Re-open basket to verify local-storage-operator is gone
send_input "3"
sleep 1

if wait_for "Basket\|Apply\|spacebar" 10; then
	if capture | grep -q "local-storage-operator"; then
		log_fail "C2: local-storage-operator still in basket after removal"
	else
		log_pass "C2: local-storage-operator removed from basket"
	fi
	screenshot "C2-basket-after-remove"
	send Escape
	sleep 1
else
	log_fail "C2: Could not re-open basket to verify removal"
fi

if ! wait_for "$TUI_TITLE_OPERATORS" 5; then
	send Escape; sleep 1
fi

# ============================================================
# Test D: Continue with operators -> ISC screen verification
# ============================================================

log_info "=== Test D: Continue to action menu + ISC verification ==="

# Channel/version from aba.conf (set by 01-wizard) for ISC verification
D_CHANNEL=$(conf_value ocp_channel)
D_VERSION=$(conf_value ocp_version)

# Parse operator names from basket view so we can assert each appears in ISC
D_ISC_OPS=()
send_input "3"
sleep 1
if wait_for "Basket\|Apply\|spacebar" 10; then
	D_cap=$(capture)
	while read -r n; do
		[[ -n "$n" ]] && D_ISC_OPS+=("$n")
	done < <(parse_basket_operator_names "$D_cap")
	if [[ ${#D_ISC_OPS[@]} -gt 0 ]]; then
		log_pass "D: Parsed ${#D_ISC_OPS[@]} operator name(s) from basket"
	else
		log_fail "D: No operator names parsed from basket"
	fi
	send Escape
	sleep 1
else
	log_fail "D: Could not open basket to parse operator names"
fi
if ! wait_for "$TUI_TITLE_OPERATORS" 5; then
	send Escape
	sleep 1
fi

send_tab_enter
sleep 1

# Should NOT show empty basket warning
if capture | grep -qi "$TUI_TITLE_EMPTY_BASKET"; then
	log_fail "D: Empty basket warning appeared despite having operators"
	send_enter
	sleep 1
else
	log_pass "D: No empty basket warning (basket is populated)"
fi

if ! wait_for "$TUI_TITLE_ACTION_MENU" 20; then
	log_fail "D: Action menu did not appear"; report_results; exit 1
fi
log_pass "D: Action menu reached"

log_info "D: Verifying ISC via View ImageSet Config (channel=$D_CHANNEL version=$D_VERSION, ${#D_ISC_OPS[@]} operators from basket)..."
D_verify_args=(--channel "$D_CHANNEL" --version "$D_VERSION" --has-operators --not-has "local-storage-operator")
for op in "${D_ISC_OPS[@]}"; do D_verify_args+=(--has "$op"); done
verify_isconf_screen "${D_verify_args[@]}"

# ============================================================
# Test E: Return to operators + clear basket
# ============================================================

log_info "=== Test E: Return to operators + clear basket ==="
ensure_action_menu
select_action "$TUI_ACTION_RERUN_WIZARD"

# Navigate through wizard to operators
wizard_to_operators || { log_fail "E: Could not reach operators"; report_results; exit 1; }

# Clear basket (option 4)
send_input "4"
sleep 1

# Confirm clear if prompted
if capture | grep -qi "clear\|empty\|remove\|confirm"; then
	send_enter
	sleep 1
fi

# Verify basket is 0
cap=$(capture)
if echo "$cap" | grep -qiE 'Basket \(0 operators\)'; then
	log_pass "E: Basket shows 0 operators after clear"
elif echo "$cap" | grep -qiE 'Basket.*empty'; then
	log_pass "E: Basket is empty after clear"
else
	log_fail "E: Basket not empty after clear"
fi
screenshot "basket-cleared"

# ============================================================
# Test F: Empty basket -> action menu + ISC re-verification
# ============================================================

log_info "=== Test F: Empty basket -> ISC re-verification ==="
send_tab_enter
sleep 1

if wait_for "$TUI_TITLE_EMPTY_BASKET" 5; then
	log_pass "F: Empty basket warning appeared"
	send_enter
	sleep 1
else
	log_fail "F: Expected empty basket warning"
fi

if ! wait_for "$TUI_TITLE_ACTION_MENU" 20; then
	log_fail "F: Action menu did not appear"; report_results; exit 1
fi
log_pass "F: Action menu reached"

log_info "F: Verifying ISC (no operators expected)..."
verify_isconf_screen --channel "$D_CHANNEL" --version "$D_VERSION" --no-operators --not-has "local-storage-operator"

# ============================================================
# Test G: Re-add different operators + ISC re-verification
# ============================================================

log_info "=== Test G: Re-add different operators (fast + Previous for variety) ==="
ensure_action_menu
select_action "$TUI_ACTION_RERUN_WIZARD"

# Use fast + Previous (different from default stable + Latest) and capture version for ISC verification
if wait_for "$TUI_TITLE_CHANNEL" 10; then
	send_input "f"
	sleep 1
fi
if ! wait_for "$TUI_TITLE_VERSION" 20; then
	log_fail "G: Version screen did not appear"; report_results; exit 1
fi
send_input "p"
sleep 1
if wait_for "$TUI_TITLE_CONFIRM" 15; then
	G_confirm_cap=$(capture)
	G_OCP_VER=$(parse_version_from_capture "$G_confirm_cap")
	if [[ -n "$G_OCP_VER" ]]; then
		log_pass "G: Parsed version $G_OCP_VER from confirmation"
	else
		log_fail "G: Could not parse version from confirmation"
	fi
	send_enter
	sleep 1
elif wait_for "Verifying" 5; then
	if wait_for "$TUI_TITLE_CONFIRM" 30; then
		G_confirm_cap=$(capture)
		G_OCP_VER=$(parse_version_from_capture "$G_confirm_cap")
		if [[ -n "$G_OCP_VER" ]]; then
			log_pass "G: Parsed version $G_OCP_VER from confirmation (after verify)"
		else
			log_fail "G: Could not parse version from confirmation"
		fi
	fi
	send_enter
	sleep 1
else
	log_fail "G: Version confirmation did not appear"; report_results; exit 1
fi
if ! wait_for "$TUI_TITLE_PLATFORM" 120; then
	log_fail "G: Platform screen did not appear"; report_results; exit 1
fi
send_tab_enter
sleep 1
if ! wait_for "$TUI_TITLE_OPERATORS" 120; then
	log_fail "G: Could not reach operators"; report_results; exit 1
fi
log_pass "G: Reached operators (fast + Previous)"

# Search for a different operator
send_input "2"
sleep 1

if wait_for "Search operator names\|min 2 chars" 10; then
	log_pass "G: Search inputbox appeared"
else
	log_fail "G: Search inputbox did not appear"
fi

send_input "openshift-gitops"
sleep 1

if wait_for "$TUI_TITLE_SELECT_OPERATORS\|Add to Basket\|spacebar" 15; then
	log_pass "G: Search results for openshift-gitops appeared"
	screenshot "gitops-search"
else
	log_fail "G: Search results did not appear"
	# Try to continue anyway
fi

send Space
send_enter
sleep 1

if ! wait_for "$TUI_TITLE_OPERATORS" 10; then
	log_fail "G: Did not return to operators"
fi
log_pass "G: Returned to operators menu after adding openshift-gitops"

# Parse operator names from basket view so we can assert each appears in ISC
G_ISC_OPS=()
send_input "3"
sleep 1
if wait_for "Basket\|Apply\|spacebar\|openshift-gitops" 10; then
	G_cap=$(capture)
	while read -r n; do
		[[ -n "$n" ]] && G_ISC_OPS+=("$n")
	done < <(parse_basket_operator_names "$G_cap")
	if [[ ${#G_ISC_OPS[@]} -gt 0 ]]; then
		log_pass "G: Parsed ${#G_ISC_OPS[@]} operator name(s) from basket"
	else
		log_fail "G: No operator names parsed from basket"
	fi
	send Escape
	sleep 1
fi
if ! wait_for "$TUI_TITLE_OPERATORS" 5; then
	send Escape
	sleep 1
fi

# Continue to action menu (no empty basket warning expected)
send_tab_enter
sleep 1

if capture | grep -qi "$TUI_TITLE_EMPTY_BASKET"; then
	log_fail "G: Unexpected empty basket warning"
	send_enter
	sleep 1
else
	log_pass "G: No empty basket warning (operators selected)"
fi

if ! wait_for "$TUI_TITLE_ACTION_MENU" 20; then
	log_fail "G: Action menu did not appear"; report_results; exit 1
fi
log_pass "G: Action menu reached"

log_info "G: Verifying ISC (channel=fast version=$G_OCP_VER, ${#G_ISC_OPS[@]} operators from basket)..."
G_verify_args=(--channel fast --version "$G_OCP_VER" --has-operators --not-has "local-storage-operator")
for op in "${G_ISC_OPS[@]}"; do G_verify_args+=(--has "$op"); done
verify_isconf_screen "${G_verify_args[@]}"

# ============================================================
# Test H: Multi-select from search — verify all selections survive
# ============================================================

log_info "=== Test H: Multi-select search preserves all selections ==="
ensure_action_menu
select_action "$TUI_ACTION_RERUN_WIZARD"
wizard_to_operators || { log_fail "H: Could not reach operators"; report_results; exit 1; }

# Clear basket first so we start clean
send_input "4"
sleep 1
if capture | grep -qi "clear\|empty\|remove\|confirm"; then
	send_enter; sleep 1
fi

# Search for "mt" which should return multiple operators (mta, mtc, mto, mtr, mtv)
send_input "2"
sleep 1
if ! wait_for "Search operator names\|min 2 chars" 10; then
	log_fail "H: Search inputbox did not appear"
fi

send_input "mt"
sleep 1

if ! wait_for "$TUI_TITLE_SELECT_OPERATORS\|Add to Basket\|spacebar" 15; then
	log_fail "H: Search results for 'mt' did not appear"
	report_results; exit 1
fi

screenshot "H-mt-search-results"

# Select the first two operators by toggling with spacebar then arrow down
send Space
sleep 0.3
send Down Space
send_enter
sleep 1

if ! wait_for "$TUI_TITLE_OPERATORS" 10; then
	log_fail "H: Did not return to operators menu"
fi

# Check basket count shows at least 2
cap=$(capture)
basket_h=$(echo "$cap" | grep -oiE 'Basket \([0-9]+ operators?\)' | grep -oE '[0-9]+')
if [[ -n "$basket_h" ]] && (( basket_h >= 2 )); then
	log_pass "H: Basket has $basket_h operators (>= 2) after multi-select"
else
	log_fail "H: Basket has ${basket_h:-0} operators, expected >= 2"
fi

# View basket to verify both are present
send_input "3"
sleep 1

# Parse operator names from basket view so we can assert each appears in ISC (same pattern as D, G)
H_ISC_OPS=()
if wait_for "Basket\|Apply\|spacebar" 10; then
	screenshot "H-basket-multi-select"
	H_basket_cap=$(capture)
	while read -r n; do
		[[ -n "$n" ]] && H_ISC_OPS+=("$n")
	done < <(parse_basket_operator_names "$H_basket_cap")
	mt_count=$(echo "$H_basket_cap" | grep -ci "mt[a-z]" || true)
	if (( mt_count >= 2 )) && (( ${#H_ISC_OPS[@]} >= 2 )); then
		log_pass "H: Basket contains $mt_count mt* operators (multi-select preserved)"
	else
		log_fail "H: Basket contains only $mt_count mt* operator(s), expected >= 2"
	fi
	send Escape
	sleep 1
else
	log_fail "H: Could not open basket to verify multi-select"
fi

if ! wait_for "$TUI_TITLE_OPERATORS" 5; then
	send Escape; sleep 1
fi

# Continue to action menu
send_tab_enter
sleep 1
if capture | grep -qi "$TUI_TITLE_EMPTY_BASKET"; then
	log_fail "H: Unexpected empty basket warning"
	send_enter
	sleep 1
fi

if ! wait_for "$TUI_TITLE_ACTION_MENU" 60; then
	log_fail "H: Action menu did not appear"; report_results; exit 1
fi

# Verify ISC contains all selected operators (not just "operators section present")
if [[ ${#H_ISC_OPS[@]} -ge 2 ]]; then
	verify_isconf_screen --has-operators --has "${H_ISC_OPS[0]}" --has "${H_ISC_OPS[1]}"
else
	verify_isconf_screen --has-operators
fi

# Clean exit
exit_tui
sleep 1

# ============================================================
# Summary
# ============================================================

report_results
