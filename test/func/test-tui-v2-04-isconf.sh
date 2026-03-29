#!/bin/bash
# TUI ISC integrity test — v2
# Covers: ISC regeneration after operator change, user-edit protection,
# channel/version change, empty operators, resume with external aba.conf edits,
# dynamic View label, Edit ISC via Advanced, and Reset ISC.
#
# Tests:
#   A: ISC regeneration after operator change — add operators, verify ISC updates
#   B: ISC user-edit protection — manually edit ISC, verify TUI preserves edits
#   C: ISC content for different channel/version — switch to fast, verify ISC
#   D: ISC with no operators — clear basket, verify no operators: section
#   E: Resume with externally modified aba.conf — edit aba.conf, restart TUI, verify
#   F: ISC ownership label — dynamic View/User-Edited label, conditional Reset item
#   G: Edit ISC via Advanced Options — open editbox, cancel without saving
#   H: Reset ISC to auto-generated — verify label reverts and user edits removed
#
# Prerequisites:
#   - tmux installed
#   - ~/.pull-secret.json exists
#   - Internet access
#   - Run from aba root directory
#   - test-tui-v2-01-wizard.sh must have run first (primed state)
#
# Usage: test/func/test-tui-v2-04-isconf.sh [--slow]

set -euo pipefail

source "$(dirname "$0")/tui-test-lib.sh"

if [[ ! -f "$HOME/.pull-secret.json" ]]; then
	echo "ERROR: ~/.pull-secret.json not found"
	exit 1
fi

if [[ ! -f aba.conf ]]; then
	echo "ERROR: aba.conf not found — run test-tui-v2-01-wizard.sh first to prime state"
	exit 1
fi

# --- Setup ---
backup_pull_secret
backup_conf

cleanup_isconf_v2() {
	stop_tui
	restore_pull_secret
	restore_conf
}
trap cleanup_isconf_v2 EXIT

# ============================================================
# Test A: ISC regeneration after operator change
# ============================================================

log_info "=== Test A: ISC regeneration after operator change ==="

reach_action_menu || { log_fail "Could not reach action menu"; report_results; exit 1; }

# Verify current ISC has no operators (primed state from 01-wizard)
A_VER=$(conf_value ocp_version)
log_info "A: Verifying ISC starts with no operators (channel=stable version=$A_VER)..."
verify_isconf_screen --channel stable --version "$A_VER" --no-operators

# Rerun wizard to add operators
select_action "$TUI_ACTION_RERUN_WIZARD"
wizard_to_operators || { log_fail "A: Could not reach operators"; report_results; exit 1; }

# Add an operator set (option 1 — OperatorSets checklist)
send_input "1"
sleep 1

if wait_for "$TUI_TITLE_OPERATOR_SETS\|spacebar\|Add to Basket" 15; then
	log_pass "A: OperatorSets checklist appeared"
	# Toggle first item
	send Space
	send_enter
	sleep 1
else
	log_fail "A: OperatorSets checklist did not appear"
fi

if ! wait_for "$TUI_TITLE_OPERATORS" 10; then
	log_fail "A: Did not return to operators menu"
fi

# Parse operator names from basket view so we can assert each appears in ISC
A_ISC_OPS=()
send_input "3"
sleep 1
if wait_for "Basket\|Apply\|spacebar" 10; then
	A_cap=$(capture)
	while read -r n; do
		[[ -n "$n" ]] && A_ISC_OPS+=("$n")
	done < <(parse_basket_operator_names "$A_cap")
	if [[ ${#A_ISC_OPS[@]} -gt 0 ]]; then
		log_pass "A: Parsed ${#A_ISC_OPS[@]} operator name(s) from basket"
	else
		log_fail "A: No operator names parsed from basket"
	fi
	send Escape
	sleep 1
else
	log_fail "A: Could not open basket to parse operator names"
fi
if ! wait_for "$TUI_TITLE_OPERATORS" 5; then
	send Escape
	sleep 1
fi

# Continue to action menu
send_tab_enter
sleep 1
if capture | grep -qi "$TUI_TITLE_EMPTY_BASKET"; then
	log_fail "A: Unexpected empty basket warning after adding operators"
	send_enter
	sleep 1
else
	log_pass "A: No empty basket warning (operators selected)"
fi

if ! wait_for "$TUI_TITLE_ACTION_MENU" 60; then
	log_fail "A: Action menu did not appear"; report_results; exit 1
fi
log_pass "A: Action menu reached"

# Verify ISC now has operators (same names we saw in basket)
log_info "A: Verifying ISC contains parsed operators (${#A_ISC_OPS[@]} from basket)..."
A_verify_args=(--channel stable --version "$A_VER" --has-operators)
for op in "${A_ISC_OPS[@]}"; do A_verify_args+=(--has "$op"); done
verify_isconf_screen "${A_verify_args[@]}"

# ============================================================
# Test B: ISC user-edit protection
# ============================================================

log_info "=== Test B: ISC user-edit protection ==="
ensure_action_menu

ISC_FILE="mirror/data/imageset-config.yaml"

if [[ ! -f "$ISC_FILE" ]]; then
	log_fail "B: ISC file not found at $ISC_FILE"
else
	# Capture MD5 before edit
	md5_before=$(md5sum "$ISC_FILE" | cut -d' ' -f1)
	log_info "B: ISC MD5 before edit: $md5_before"

	# Manually append a comment (simulates user edit)
	echo "# user-edit-marker-B" >> "$ISC_FILE"

	md5_edited=$(md5sum "$ISC_FILE" | cut -d' ' -f1)
	log_info "B: ISC MD5 after edit: $md5_edited"

	if [[ "$md5_before" != "$md5_edited" ]]; then
		log_pass "B: ISC file was modified (MD5 changed)"
	else
		log_fail "B: ISC file MD5 unchanged after edit"
	fi

	# Touch the file to ensure it's newer than .created (triggering the guard)
	touch "$ISC_FILE"

	# Trigger ISC regeneration via wizard rerun (change operators slightly)
	select_action "$TUI_ACTION_RERUN_WIZARD"
	wizard_to_operators || { log_fail "B: Could not reach operators"; report_results; exit 1; }

	# Search for a different operator to trigger a basket change
	send_input "2"
	sleep 1
	if wait_for "Search operator names\|min 2 chars" 10; then
		send_input "openshift-gitops"
		sleep 1
		if wait_for "$TUI_TITLE_SELECT_OPERATORS\|Add to Basket\|spacebar" 15; then
			send Space
			send_enter
			sleep 1
		fi
	fi

	if wait_for "$TUI_TITLE_OPERATORS" 10; then
		send_tab_enter
		sleep 1
	fi
	# Basket has operators from Test A — empty basket warning should NOT appear
	if capture | grep -qi "$TUI_TITLE_EMPTY_BASKET"; then
		send_enter
		sleep 1
	fi

	if ! wait_for "$TUI_TITLE_ACTION_MENU" 60; then
		log_fail "B: Action menu did not appear after wizard"; report_results; exit 1
	fi

	# Verify the user-edit marker is preserved
	if grep -q "user-edit-marker-B" "$ISC_FILE"; then
		log_pass "B: User edit preserved (marker comment still in ISC)"
	else
		log_fail "B: User edit was overwritten (marker comment gone)"
	fi

	md5_after_regen=$(md5sum "$ISC_FILE" | cut -d' ' -f1)
	if [[ "$md5_edited" == "$md5_after_regen" ]]; then
		log_pass "B: ISC MD5 unchanged after wizard rerun (user edit protected)"
	else
		log_fail "B: ISC MD5 changed after wizard rerun (user edit NOT protected)"
	fi
fi

# ============================================================
# Test C: ISC content for different channel/version
# ============================================================

log_info "=== Test C: ISC content for different channel/version ==="
ensure_action_menu

# Remove the user-edit marker so ISC will be regenerated this time
if [[ -f "$ISC_FILE" ]]; then
	sed -i '/user-edit-marker-B/d' "$ISC_FILE"
	# Reset the timestamp so ISC is NOT newer than .created
	if [[ -f mirror/data/.created ]]; then
		touch mirror/data/.created
		sleep 1
	fi
fi

select_action "$TUI_ACTION_RERUN_WIZARD"

# Select 'fast' channel
if wait_for "$TUI_TITLE_CHANNEL" 10; then
	send_input "f"
	sleep 1
fi

# Select Previous version (different from Latest for variety)
if wait_for "$TUI_TITLE_VERSION" 20; then
	send_input "p"
	sleep 1
fi

# Confirm and capture version for ISC verification
if wait_for "$TUI_TITLE_CONFIRM" 15; then
	C_confirm_cap=$(capture)
	C_OCP_VER=$(parse_version_from_capture "$C_confirm_cap")
	if [[ -n "$C_OCP_VER" ]]; then
		log_pass "C: Parsed version $C_OCP_VER from confirmation"
	else
		log_fail "C: Could not parse version from confirmation"
	fi
	send_enter
	sleep 1
elif wait_for "Verifying" 5; then
	if wait_for "$TUI_TITLE_CONFIRM" 30; then
		C_confirm_cap=$(capture)
		C_OCP_VER=$(parse_version_from_capture "$C_confirm_cap")
		if [[ -n "$C_OCP_VER" ]]; then
			log_pass "C: Parsed version $C_OCP_VER from confirmation (after verify)"
		else
			log_fail "C: Could not parse version from confirmation"
		fi
	fi
	send_enter
	sleep 1
fi

# Platform
if wait_for "$TUI_TITLE_PLATFORM" 10; then
	send_tab_enter
	sleep 1
fi

# Operators — skip (basket still has operators from A/B)
if wait_for "$TUI_TITLE_OPERATORS" 120; then
	send_tab_enter
	sleep 1
fi
# Basket has operators — empty basket warning should NOT appear
if capture | grep -qi "$TUI_TITLE_EMPTY_BASKET"; then
	send_enter
	sleep 1
fi

if ! wait_for "$TUI_TITLE_ACTION_MENU" 60; then
	log_fail "C: Action menu did not appear"; report_results; exit 1
fi
log_pass "C: Action menu reached with fast channel"

# Verify ISC reflects new channel and version (fast + Previous)
verify_isconf_screen --channel fast --version "$C_OCP_VER"

# ============================================================
# Test D: ISC with no operators (clear basket first)
# ============================================================

log_info "=== Test D: ISC with no operators ==="
ensure_action_menu

# Rerun wizard and clear the basket at the operators screen
select_action "$TUI_ACTION_RERUN_WIZARD"

# Accept defaults through channel/version/platform
if wait_for "$TUI_TITLE_CHANNEL" 10; then
	send_enter
	sleep 1
fi
if wait_for "$TUI_TITLE_VERSION" 20; then
	send_enter
	sleep 1
fi
if wait_for "$TUI_TITLE_CONFIRM" 15; then
	send_enter
	sleep 1
elif wait_for "Verifying" 5; then
	wait_for "$TUI_TITLE_CONFIRM" 30
	send_enter
	sleep 1
fi
if wait_for "$TUI_TITLE_PLATFORM" 10; then
	send_tab_enter
	sleep 1
fi

if ! wait_for "$TUI_TITLE_OPERATORS" 120; then
	log_fail "D: Could not reach operators"; report_results; exit 1
fi

# Clear basket (option 4)
send_input "4"
sleep 1
if capture | grep -qi "clear\|empty\|remove\|confirm"; then
	send_enter
	sleep 1
fi

if capture | grep -qiE 'Basket \(0 operators\)|Basket.*empty'; then
	log_pass "D: Basket cleared"
else
	log_info "D: Basket may already be empty or clear had no confirmation"
fi

# Continue to action menu (should get empty basket warning now)
send_tab_enter
sleep 1
if wait_for "$TUI_TITLE_EMPTY_BASKET" 5; then
	log_pass "D: Empty basket warning appeared"
	send_enter
	sleep 1
fi

if ! wait_for "$TUI_TITLE_ACTION_MENU" 60; then
	log_fail "D: Action menu did not appear"; report_results; exit 1
fi
log_pass "D: Action menu reached with empty basket"

# Verify ISC has no operators (channel/version from wizard defaults)
D_VER=$(conf_value ocp_version)
D_CHAN=$(conf_value ocp_channel)
verify_isconf_screen --channel "$D_CHAN" --version "$D_VER" --no-operators

# ============================================================
# Test E: Resume with externally modified aba.conf
# ============================================================

log_info "=== Test E: Resume with externally modified aba.conf ==="

# Exit TUI cleanly
exit_tui
sleep 1

# Wait for TUI to exit
_wait_exit=0
while session_alive && [[ $_wait_exit -lt 10 ]]; do
	sleep 1
	_wait_exit=$((_wait_exit + 1))
done

if session_alive; then
	stop_tui
	sleep 1
fi

# Modify aba.conf externally — change channel to candidate
if [[ -f aba.conf ]]; then
	_old_channel=$(conf_value ocp_channel)
	log_info "E: Current channel in aba.conf: $_old_channel"

	sed -i 's/^ocp_channel=.*/ocp_channel=candidate/' aba.conf
	_new_channel=$(conf_value ocp_channel)
	log_info "E: Changed channel in aba.conf to: $_new_channel"

	if [[ "$_new_channel" == "candidate" ]]; then
		log_pass "E: aba.conf externally modified to candidate"
	else
		log_fail "E: Failed to modify aba.conf channel"
	fi
else
	log_fail "E: aba.conf not found for external modification"
	report_results
	exit 1
fi

# Start TUI fresh — should detect existing config and show Resume dialog
start_tui
dismiss_welcome || { log_fail "E: Could not dismiss welcome"; report_results; exit 1; }

if wait_for "$TUI_TITLE_RESUME" 30; then
	log_pass "E: Resume dialog appeared (detected external aba.conf)"
	send_enter
	sleep 1
else
	log_fail "E: Resume dialog did not appear"
fi

if ! wait_for "$TUI_TITLE_ACTION_MENU" 60; then
	log_fail "E: Action menu did not appear after resume"; report_results; exit 1
fi
log_pass "E: Action menu reached after resume with external aba.conf edit"

# Verify ISC reflects the externally modified channel (version unchanged in aba.conf)
E_VER=$(conf_value ocp_version)
log_info "E: Verifying ISC reflects candidate channel and version $E_VER..."
verify_isconf_screen --channel candidate --version "$E_VER"

# Verify aba.conf still has candidate (TUI didn't overwrite it)
_final_channel=$(conf_value ocp_channel)
if [[ "$_final_channel" == "candidate" ]]; then
	log_pass "E: aba.conf preserved external edit (channel=candidate)"
else
	log_fail "E: aba.conf channel changed to '$_final_channel' (expected candidate)"
fi

# ============================================================
# Test F: ISC ownership label — dynamic View label
# ============================================================

log_info "=== Test F: ISC ownership label (dynamic View label) ==="
ensure_action_menu

ISC_FILE="mirror/data/imageset-config.yaml"

# First ensure ISC is auto-generated (not user-owned)
if [[ -f mirror/data/.created ]]; then
	touch mirror/data/.created
	sleep 1
fi

# Re-enter action menu to pick up the label change
select_action "$TUI_ACTION_RERUN_WIZARD"
if wait_for "$TUI_TITLE_CHANNEL" 10; then
	send_enter
	sleep 1
fi
if wait_for "$TUI_TITLE_VERSION" 20; then
	send_enter
	sleep 1
fi
if wait_for "$TUI_TITLE_CONFIRM" 15; then
	send_enter
	sleep 1
elif wait_for "Verifying" 5; then
	wait_for "$TUI_TITLE_CONFIRM" 30
	send_enter
	sleep 1
fi
if wait_for "$TUI_TITLE_PLATFORM" 10; then
	send_tab_enter
	sleep 1
fi
if wait_for "$TUI_TITLE_OPERATORS" 120; then
	send_tab_enter
	sleep 1
fi
if wait_for "$TUI_TITLE_EMPTY_BASKET" 5; then
	send_enter
	sleep 1
fi
if ! wait_for "$TUI_TITLE_ACTION_MENU" 60; then
	log_fail "F: Action menu did not appear"; report_results; exit 1
fi

# When auto-generated, label should say "View Generated ImageSet Config"
if assert_screen "$TUI_ACTION_TEXT_VIEW_IMAGESET" "F: View label shows 'Generated' when auto-owned"; then
	:
fi

# Now make ISC user-owned by touching it newer than .created
if [[ -f "$ISC_FILE" ]]; then
	sleep 1
	touch "$ISC_FILE"
	# Force menu refresh — navigate away and back
	select_action "$TUI_ACTION_RERUN_WIZARD"
	if wait_for "$TUI_TITLE_CHANNEL" 10; then
		send_enter
		sleep 1
	fi
	if wait_for "$TUI_TITLE_VERSION" 20; then
		send_enter
		sleep 1
	fi
	if wait_for "$TUI_TITLE_CONFIRM" 15; then
		send_enter
		sleep 1
	elif wait_for "Verifying" 5; then
		wait_for "$TUI_TITLE_CONFIRM" 30
		send_enter
		sleep 1
	fi
	if wait_for "$TUI_TITLE_PLATFORM" 10; then
		send_tab_enter
		sleep 1
	fi
	if wait_for "$TUI_TITLE_OPERATORS" 120; then
		send_tab_enter
		sleep 1
	fi
	if wait_for "$TUI_TITLE_EMPTY_BASKET" 5; then
		send_enter
		sleep 1
	fi
	if ! wait_for "$TUI_TITLE_ACTION_MENU" 60; then
		log_fail "F: Action menu did not appear after making ISC user-owned"
		report_results; exit 1
	fi

	# When user-owned, label should say "View User-Edited ImageSet Config"
	assert_screen "$TUI_ACTION_TEXT_VIEW_IMAGESET_USER" "F: View label shows 'User-Edited' when user-owned"

	# Also verify the Reset item appeared
	assert_screen "$TUI_ACTION_TEXT_RESET_IMAGESET" "F: Reset item visible when ISC is user-owned"
else
	log_fail "F: ISC file not found at $ISC_FILE"
fi

# ============================================================
# Test G: Edit ISC via Advanced Options
# ============================================================

log_info "=== Test G: Edit ISC via Advanced Options ==="
ensure_action_menu

# Reset ISC to auto-generated first
if [[ -f mirror/data/.created ]]; then
	touch mirror/data/.created; sleep 1
fi

select_action "$TUI_ACTION_ADVANCED"
sleep 1

if ! wait_for "Advanced" 10; then
	log_fail "G: Advanced submenu did not appear"
else
	# Select "Edit ImageSet Config" (item 2)
	send_input "2"
	sleep 2

	if wait_for "ImageSetConfiguration\|imageset-config\|apiVersion\|editbox\|SAVE" 15; then
		log_pass "G: Edit ISC dialog appeared"
		# Press Escape to cancel editing (don't save)
		send Escape
		sleep 1
	else
		log_fail "G: Edit ISC dialog did not appear"
		screenshot "G-no-edit-dialog"
		send Escape
		sleep 1
	fi

	# Back out of Advanced submenu
	if wait_for "Advanced" 5; then
		send Escape
		sleep 1
	fi
fi

ensure_action_menu

# ============================================================
# Test H: Reset ISC to auto-generated
# ============================================================

log_info "=== Test H: Reset ISC to auto-generated ==="
ensure_action_menu

# Make ISC user-owned
if [[ -f "$ISC_FILE" ]]; then
	sleep 1
	touch "$ISC_FILE"
	echo "# user-edit-marker-H" >> "$ISC_FILE"
fi

# Refresh menu to show the Reset item
select_action "$TUI_ACTION_RERUN_WIZARD"
if wait_for "$TUI_TITLE_CHANNEL" 10; then
	send_enter
	sleep 1
fi
if wait_for "$TUI_TITLE_VERSION" 20; then
	send_enter
	sleep 1
fi
if wait_for "$TUI_TITLE_CONFIRM" 15; then
	send_enter
	sleep 1
elif wait_for "Verifying" 5; then
	wait_for "$TUI_TITLE_CONFIRM" 30
	send_enter
	sleep 1
fi
if wait_for "$TUI_TITLE_PLATFORM" 10; then
	send_tab_enter
	sleep 1
fi
if wait_for "$TUI_TITLE_OPERATORS" 120; then
	send_tab_enter
	sleep 1
fi
if wait_for "$TUI_TITLE_EMPTY_BASKET" 5; then
	send_enter
	sleep 1
fi
if ! wait_for "$TUI_TITLE_ACTION_MENU" 60; then
	log_fail "H: Action menu did not appear"; report_results; exit 1
fi

# Verify Reset item is visible (ISC is user-owned)
assert_screen "$TUI_ACTION_TEXT_RESET_IMAGESET" "H: Reset item visible before reset"

# Select the Reset action
select_action "$TUI_ACTION_RESET_IMAGESET"

# Dismiss the "ImageSet Config Reset" confirmation dialog
if wait_for "ImageSet Config Reset\|reset to auto-generated" 10; then
	log_pass "H: Reset confirmation dialog appeared"
	send_enter
	sleep 1
else
	log_info "H: No reset confirmation dialog (may have gone straight to menu)"
fi

# After reset, the menu should refresh with "Generated" label
if wait_for "$TUI_TITLE_ACTION_MENU" 60; then
	assert_screen "$TUI_ACTION_TEXT_VIEW_IMAGESET" "H: View label reverted to 'Generated' after reset"
else
	log_fail "H: Action menu did not reappear after reset"
fi

# Trigger ISC regeneration by viewing it (reset defers rewrite until needed)
select_action "$TUI_ACTION_VIEW_IMAGESET"
if wait_for "ImageSetConfiguration\|kind:" 15; then
	log_pass "H: ISC view appeared (triggering regeneration)"
	send Escape
	sleep 1
else
	log_fail "H: ISC view did not appear after reset"
fi
if ! wait_for "$TUI_TITLE_ACTION_MENU" 10; then
	log_fail "H: Action menu did not reappear after ISC view"
fi

# Verify the user-edit marker is gone (ISC was regenerated)
if [[ -f "$ISC_FILE" ]] && ! grep -q "user-edit-marker-H" "$ISC_FILE"; then
	log_pass "H: User edit marker removed after reset"
elif [[ -f "$ISC_FILE" ]]; then
	log_fail "H: User edit marker still present after reset"
fi

# ============================================================
# Restore: set channel back to stable for subsequent tests
# ============================================================

log_info "=== Restoring stable channel ==="
ensure_action_menu
select_action "$TUI_ACTION_RERUN_WIZARD"

if wait_for "$TUI_TITLE_CHANNEL" 10; then
	send_input "s"
	sleep 1
fi
if wait_for "$TUI_TITLE_VERSION" 20; then
	send_input "l"
	sleep 1
fi
if wait_for "$TUI_TITLE_CONFIRM" 15; then
	send_enter
	sleep 1
elif wait_for "Verifying" 5; then
	wait_for "$TUI_TITLE_CONFIRM" 30
	send_enter
	sleep 1
fi
if wait_for "$TUI_TITLE_PLATFORM" 10; then
	send_tab_enter
	sleep 1
fi
if wait_for "$TUI_TITLE_OPERATORS" 120; then
	send_tab_enter
	sleep 1
fi
if wait_for "$TUI_TITLE_EMPTY_BASKET" 5; then
	send_enter
	sleep 1
fi

if wait_for "$TUI_TITLE_ACTION_MENU" 20; then
	log_pass "Stable channel restored"
else
	log_fail "Could not restore stable channel"
fi

# Final ISC verification
verify_isconf_screen --channel stable --no-operators

# Clean exit
exit_tui
sleep 1

# ============================================================
# Summary
# ============================================================

report_results
