#!/bin/bash
# Comprehensive TUI wizard test — v2
# Covers: early exit, 3 negative pull secret tests, full wizard flow with ISC
# verification for empty basket, help buttons, and back navigation.
#
# Prerequisites:
#   - tmux installed
#   - ~/.pull-secret.json exists (will be backed up and removed)
#   - Internet access (version fetch + pull secret validation)
#   - Run from aba root directory
#
# Usage: test/func/test-tui-wizard-v2.sh

set -euo pipefail

source "$(dirname "$0")/tui-test-lib.sh"

if [[ ! -f "$HOME/.pull-secret.json" ]]; then
	echo "ERROR: ~/.pull-secret.json not found — needed for pull secret paste test"
	exit 1
fi

# --- Setup ---
# This is the "scene setter" test — it resets everything and runs the full
# wizard to build realistic cached state (catalogs, oc-mirror, ISC, etc.)
# for all subsequent tests.  The wizard-produced aba.conf and cached state
# are intentionally LEFT IN PLACE after this test completes.

backup_pull_secret
reset_test_state

cleanup_wizard_v2() {
	stop_tui
	restore_pull_secret
	# NOTE: do NOT restore aba.conf — the wizard-produced config and all
	# cached state must persist for subsequent tests (basket-v2, actions-v2, etc.)
}
trap cleanup_wizard_v2 EXIT

rm -f "$HOME/.pull-secret.json"
log_info "=== Setup: removed ~/.pull-secret.json (aba.conf removed by reset) ==="

# ============================================================
# Test A: Early exit cleanup
# ============================================================

log_info "=== Test A: Early exit cleanup ==="
start_tui

if ! wait_for "$TUI_TITLE_WELCOME" 15; then
	log_fail "A: Welcome dialog did not appear"; report_results; exit 1
fi
log_pass "A: Welcome dialog appeared"
send_enter
sleep 1

if ! wait_for "$TUI_TITLE_PULL_SECRET_REQUIRED" 15; then
	log_fail "A: Pull secret required dialog did not appear"; report_results; exit 1
fi
log_pass "A: Pull secret required dialog appeared"

send Escape
sleep 1

if wait_for "$TUI_TITLE_CONFIRM_EXIT" 15; then
	log_pass "A: Confirm exit dialog appeared"
	send_enter
	sleep 3
else
	log_fail "A: Confirm exit dialog did not appear"
fi

if ! session_alive; then
	log_pass "A: TUI session ended"
else
	log_fail "A: TUI session still alive after exit"
	stop_tui
	sleep 1
fi

if [[ ! -f aba.conf ]]; then
	log_pass "A: aba.conf deleted on early exit (auto-created conf cleaned up)"
else
	log_fail "A: aba.conf still exists after early exit"
	rm -f aba.conf
fi

# ============================================================
# Test B: Negative — invalid pull secret (bad JSON)
# ============================================================

log_info "=== Test B: Negative — invalid JSON pull secret ==="
start_tui
dismiss_welcome || { log_fail "B: Could not dismiss welcome"; report_results; exit 1; }

if ! wait_for "$TUI_TITLE_PULL_SECRET_REQUIRED" 15; then
	log_fail "B: Pull secret required dialog did not appear"; report_results; exit 1
fi

# Tab to "Paste" (Extra button)
send_tab_enter
sleep 1

if ! wait_for "$TUI_TITLE_PULL_SECRET_PASTE" 5; then
	log_fail "B: Pull secret editbox did not appear"; report_results; exit 1
fi
log_pass "B: Pull secret editbox appeared"

# Paste bad JSON via tmux buffer
local_bad_json=$(mktemp)
echo '{invalid json content' > "$local_bad_json"
tmux load-buffer "$local_bad_json"
tmux paste-buffer -t "$SESSION"
rm -f "$local_bad_json"
sleep 1

# Submit (Tab to OK, Enter)
send_tab_enter
sleep 2

if capture | grep -qi "Invalid JSON Format"; then
	log_pass "B: 'Invalid JSON Format' error appeared"
else
	log_fail "B: Expected 'Invalid JSON Format' error on screen"
fi
screenshot "bad-json-error"

# Dismiss error and verify editbox reappears
send_enter
sleep 1

# ============================================================
# Test C: Negative — empty pull secret paste
# ============================================================

log_info "=== Test C: Negative — empty pull secret paste ==="

if wait_for "$TUI_TITLE_PULL_SECRET_PASTE" 5; then
	log_pass "C: Editbox reappeared after bad JSON"
else
	log_fail "C: Editbox did not reappear after bad JSON error"
fi

# Submit empty (just Tab Enter without pasting)
send_tab_enter
sleep 2

if capture | grep -qi "Pull secret is empty"; then
	log_pass "C: 'Pull secret is empty' error appeared"
else
	log_fail "C: Expected 'Pull secret is empty' error"
fi
screenshot "empty-ps-error"

send_enter
sleep 1

# ============================================================
# Test D: Negative — pull secret missing registry.redhat.io
# ============================================================

log_info "=== Test D: Negative — missing registry.redhat.io ==="

if wait_for "$TUI_TITLE_PULL_SECRET_PASTE" 5; then
	log_pass "D: Editbox reappeared after empty PS error"
else
	log_fail "D: Editbox did not reappear"
fi

# Paste valid JSON without registry.redhat.io
local_bad_ps=$(mktemp)
echo '{"auths":{"example.com":{"auth":"dGVzdA=="}}}' > "$local_bad_ps"
tmux load-buffer "$local_bad_ps"
tmux paste-buffer -t "$SESSION"
rm -f "$local_bad_ps"
sleep 1

send_tab_enter
sleep 2

if capture | grep -qi "registry.redhat.io"; then
	log_pass "D: Error about missing registry.redhat.io appeared"
else
	log_fail "D: Expected error about registry.redhat.io"
fi
screenshot "missing-registry-error"

send_enter
sleep 1

# ============================================================
# Test E: Full wizard — empty basket path with ISC verification
# ============================================================

log_info "=== Test E: Full wizard — empty basket ==="

if ! wait_for "$TUI_TITLE_PULL_SECRET_PASTE" 5; then
	log_fail "E: Editbox did not reappear"; report_results; exit 1
fi

log_info "E: Pasting valid pull secret..."
paste_pull_secret "$_PS_BACKUP"
send_tab_enter
sleep 1

# Channel screen
if ! wait_for "$TUI_TITLE_CHANNEL" 30; then
	log_fail "E: Channel screen did not appear"; report_results; exit 1
fi
log_pass "E: Channel screen appeared"
assert_screen "stable" "E: Channel option: stable"
assert_screen "fast" "E: Channel option: fast"
assert_screen "candidate" "E: Channel option: candidate"
screenshot "wizard-channel"

# Select 'fast' channel by tag letter
send_input "f"
sleep 1

# Version screen
if ! wait_for "$TUI_TITLE_VERSION" 20; then
	log_fail "E: Version screen did not appear"; report_results; exit 1
fi
log_pass "E: Version screen appeared"
assert_screen "Latest" "E: Version option: Latest"
assert_screen "Previous" "E: Version option: Previous"
assert_screen "Older" "E: Version option: Older"
screenshot "wizard-version"

# Select 'Previous' version by tag letter
send_input "p"
sleep 1

# Version confirmation
if ! wait_for "$TUI_TITLE_CONFIRM" 15; then
	if wait_for "Verifying" 5; then
		log_info "E: Version verification in progress..."
		if ! wait_for "$TUI_TITLE_CONFIRM" 30; then
			log_fail "E: Version confirmation did not appear after verification"; report_results; exit 1
		fi
	else
		log_fail "E: Version confirmation did not appear"; report_results; exit 1
	fi
fi
log_pass "E: Version confirmation appeared"
assert_screen "Channel:" "E: Confirmation shows Channel"
assert_screen "Version:" "E: Confirmation shows Version"
screenshot "wizard-version-confirm"
E_confirm_cap=$(capture)
E_OCP_VER=$(parse_version_from_capture "$E_confirm_cap")
if [[ -n "$E_OCP_VER" ]]; then
	log_pass "E: Parsed version $E_OCP_VER from confirmation"
else
	log_fail "E: Could not parse version from confirmation"
fi

send_enter
sleep 1

# Platform (TUI runs cli-download-all.sh after version confirm, so allow time for that)
if ! wait_for "$TUI_TITLE_PLATFORM" 120; then
	log_fail "E: Platform screen did not appear"; report_results; exit 1
fi
log_pass "E: Platform screen appeared"
assert_screen "Base Domain" "E: Shows Base Domain"
assert_screen "Machine Network" "E: Shows Machine Network"
screenshot "wizard-platform"

send_tab_enter
sleep 1

# Operators
if ! wait_for "$TUI_TITLE_OPERATORS" 120; then
	log_fail "E: Operators screen did not appear"; report_results; exit 1
fi
log_pass "E: Operators screen appeared"
assert_screen "Select Operator" "E: Shows operator actions"
screenshot "wizard-operators"

# Skip operators (Tab to Next/Extra)
send_tab_enter
sleep 1

# Empty basket warning
if ! wait_for "$TUI_TITLE_EMPTY_BASKET" 5; then
	if capture | grep -qi "$TUI_TITLE_ACTION_MENU"; then
		log_pass "E: Skipped to action menu (operators may have been pre-selected)"
	else
		log_fail "E: Empty basket warning did not appear"
	fi
else
	log_pass "E: Empty basket warning appeared"
	screenshot "wizard-empty-basket"
	send_enter
	sleep 1
fi

# Action menu
if ! wait_for "$TUI_TITLE_ACTION_MENU" 20; then
	log_fail "E: Action menu did not appear"; report_results; exit 1
fi
log_pass "E: Action menu appeared — wizard complete"
screenshot "wizard-action-menu"

# Verify menu item labels (dialog strips \Zu/\Zn, so use plain-text versions)
for label in "$TUI_ACTION_TEXT_VIEW_IMAGESET" "Install Bundle" \
	"Save Images" "Local Registry" \
	"Remote Registry" "Wizard" \
	"onfigure" "ptions"; do
	assert_screen "$label" "E: Menu label: $label"
done

# ISC verification via dialog screen (empty basket — no operators)
log_info "E: Verifying ISC via View ImageSet Config (channel=fast, version=$E_OCP_VER)..."
verify_isconf_screen --channel fast --version "$E_OCP_VER" --no-operators

# aba.conf verification
if [[ -f aba.conf ]]; then
	_ch=$(conf_value ocp_channel)
	if [[ "$_ch" == "fast" ]]; then
		log_pass "E: aba.conf ocp_channel=fast"
	else
		log_fail "E: aba.conf ocp_channel='$_ch' (expected 'fast')"
	fi

	_mn=$(conf_value machine_network)
	_dns=$(conf_value dns_servers)
	_gw=$(conf_value next_hop_address)
	_ntp=$(conf_value ntp_servers)
	if [[ -z "$_mn" && -z "$_dns" && -z "$_gw" && -z "$_ntp" ]]; then
		log_pass "E: Network values empty (auto-detect preserved)"
	else
		log_fail "E: Network values were filled: mn=$_mn dns=$_dns gw=$_gw ntp=$_ntp"
	fi
else
	log_fail "E: aba.conf not found after wizard"
fi

# ============================================================
# Test F: Help buttons
# ============================================================

log_info "=== Test F: Help buttons ==="
ensure_action_menu
select_action "$TUI_ACTION_RERUN_WIZARD"

# Channel screen — press Help (3 Tabs + Enter)
if wait_for "$TUI_TITLE_CHANNEL" 10; then
	log_pass "F: At Channel screen"
	send_tab_tab_tab_enter
	sleep 1
	if capture | grep -qi "Update Channels\|Recommended\|stable.*fast.*candidate"; then
		log_pass "F: Channel help dialog appeared"
	else
		log_fail "F: Channel help dialog content not found"
	fi
	screenshot "help-channel"
	send_enter
	sleep 1

	if wait_for "$TUI_TITLE_CHANNEL" 5; then
		log_pass "F: Returned to Channel after help"
	else
		log_fail "F: Did not return to Channel after help"
	fi
else
	log_fail "F: Channel screen did not appear for help test"
fi

# Accept channel, go to version
send_enter
sleep 1

# Version screen — press Help
if wait_for "$TUI_TITLE_VERSION" 20; then
	log_pass "F: At Version screen"
	send_tab_tab_tab_enter
	sleep 1
	if capture | grep -qi "Version Selection\|Latest.*release\|Previous"; then
		log_pass "F: Version help dialog appeared"
	else
		log_fail "F: Version help dialog content not found"
	fi
	screenshot "help-version"
	send_enter
	sleep 1
else
	log_fail "F: Version screen did not appear for help test"
fi

# Accept version, confirm, go to platform
send_enter
sleep 1
if wait_for "$TUI_TITLE_CONFIRM" 15; then
	send_enter
	sleep 1
elif wait_for "Verifying" 5; then
	wait_for "$TUI_TITLE_CONFIRM" 30
	send_enter
	sleep 1
fi

# Platform screen — press Help (allow time like full wizard; version confirm runs CLI downloads)
if wait_for "$TUI_TITLE_PLATFORM" 120; then
	log_pass "F: At Platform screen"
	# Platform has cancel-label "Back", help-button, ok-label "Select", extra-button "Next"
	# Tab order from menu: Extra(Next) -> Cancel(Back) -> Help -> OK(Select)
	send_tab_tab_tab_enter
	sleep 1
	if capture | grep -qi "Platform.*Network\|Base Domain\|Machine Network\|auto-detect"; then
		log_pass "F: Platform help dialog appeared"
	else
		log_fail "F: Platform help dialog content not found"
	fi
	screenshot "help-platform"
	send_enter
	sleep 1
else
	log_fail "F: Platform screen did not appear for help test"
fi

# Escape out of wizard (allow time for dialog to process ESC and show confirm)
send Escape
sleep 2
if wait_for "$TUI_TITLE_CONFIRM_EXIT" 15; then
	send_enter
	sleep 1
fi

# ============================================================
# Test G: Back navigation
# ============================================================

log_info "=== Test G: Back navigation ==="

# TUI may have exited — restart
if ! session_alive; then
	start_tui
	dismiss_welcome
	if wait_for "$TUI_TITLE_RESUME" 15; then
		send_enter
		sleep 1
	fi
	if ! wait_for "$TUI_TITLE_ACTION_MENU" 20; then
		log_fail "G: Could not reach action menu"; report_results; exit 1
	fi
fi
ensure_action_menu

select_action "$TUI_ACTION_RERUN_WIZARD"

# Channel -> select 'candidate' by tag letter
if wait_for "$TUI_TITLE_CHANNEL" 10; then
	send_input "c"
	sleep 1
fi

# Version -> press Back (Tab Enter = Extra/Back button)
if wait_for "$TUI_TITLE_VERSION" 20; then
	log_pass "G: At Version screen"
	send_tab_enter
	sleep 1
	if wait_for "$TUI_TITLE_CHANNEL" 5; then
		log_pass "G: Back from Version returned to Channel"
	else
		log_fail "G: Back from Version did not return to Channel"
	fi
else
	log_fail "G: Version screen did not appear"
fi

# Forward again: channel (candidate retained) -> version (select Older by tag)
send_enter
sleep 1
if wait_for "$TUI_TITLE_VERSION" 20; then
	send_input "o"
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

# Operators -> press Back -> should return to Platform
if wait_for "$TUI_TITLE_OPERATORS" 120; then
	log_pass "G: At Operators screen"
	# Cancel button = Back in operators (cancel-label "Back")
	# Tab order: Extra(Next) -> Cancel(Back)
	send_tab_tab_enter
	sleep 1
	if wait_for "$TUI_TITLE_PLATFORM" 5; then
		log_pass "G: Back from Operators returned to Platform"
	else
		log_fail "G: Back from Operators did not return to Platform"
	fi
else
	log_fail "G: Operators screen did not appear"
fi

# Platform -> press Back -> should return to Version
if wait_for "$TUI_TITLE_PLATFORM" 5; then
	# Cancel button = Back for platform (cancel-label "Back")
	send_tab_tab_enter
	sleep 1
	if wait_for "$TUI_TITLE_VERSION" 5; then
		log_pass "G: Back from Platform returned to Version"
	else
		log_fail "G: Back from Platform did not return to Version"
	fi
fi

# Final forward pass: switch to stable + Latest for the primed state.
# We're at Version after back-nav. Go Back to Channel first.
send_tab_enter
sleep 1
if wait_for "$TUI_TITLE_CHANNEL" 5; then
	log_info "G: At Channel, selecting stable for final state"
	send_input "s"
	sleep 1
fi
if wait_for "$TUI_TITLE_VERSION" 20; then
	log_info "G: At Version, selecting Latest for final state"
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
	log_pass "G: Action menu reappeared after back navigation"
else
	log_fail "G: Action menu did not reappear after back navigation"
fi

# Clean exit from Test G
exit_tui
sleep 1

# ============================================================
# Test H: Manual version entry (positive + negative)
# ============================================================

log_info "=== Test H: Manual version entry ==="

# TUI exited at end of Test G — restart
if ! session_alive; then
	start_tui
	dismiss_welcome
	if wait_for "$TUI_TITLE_RESUME" 15; then
		send_enter
		sleep 1
	fi
	if ! wait_for "$TUI_TITLE_ACTION_MENU" 20; then
		log_fail "H: Could not reach action menu"; report_results; exit 1
	fi
fi
ensure_action_menu

select_action "$TUI_ACTION_RERUN_WIZARD"

# Accept channel (stable)
if wait_for "$TUI_TITLE_CHANNEL" 10; then
	send_input "s"
	sleep 1
fi

# Version -> select Manual entry (m)
if ! wait_for "$TUI_TITLE_VERSION" 20; then
	log_fail "H: Version screen did not appear"; report_results; exit 1
fi
log_pass "H: At Version screen, selecting Manual entry"
send_input "m"
sleep 1

# --- H1: Invalid format ---
if ! wait_for "Enter OpenShift version" 10; then
	log_fail "H1: Manual entry inputbox did not appear"; report_results; exit 1
fi
log_pass "H1: Manual entry inputbox appeared"
screenshot "manual-entry-inputbox"

clear_input
send_input "abc"
sleep 2

if capture | grep -qi "Invalid version format"; then
	log_pass "H1: 'Invalid version format' error appeared"
else
	log_fail "H1: Expected 'Invalid version format' error"
fi
screenshot "manual-entry-bad-format"

send_enter
sleep 1

# --- H2: Non-existent version (x.y format) ---
if wait_for "Enter OpenShift version" 10; then
	log_pass "H2: Inputbox reappeared after format error"
else
	log_fail "H2: Inputbox did not reappear"
fi

clear_input
send_input "9.99"
sleep 5

if capture | grep -qi "Version not found\|does not exist"; then
	log_pass "H2: 'Version not found' error appeared for 9.99"
else
	if wait_for "Version not found\|does not exist" 30; then
		log_pass "H2: 'Version not found' error appeared for 9.99 (after wait)"
	else
		log_fail "H2: Expected 'Version not found' error for 9.99"
	fi
fi
screenshot "manual-entry-nonexistent"

send_enter
sleep 1

# --- H3: Valid x.y version ---
if wait_for "Enter OpenShift version" 10; then
	log_pass "H3: Inputbox reappeared after non-existent error"
else
	log_fail "H3: Inputbox did not reappear"
fi

clear_input
send_input "4.17"
sleep 1

# Should show "Resolving" then confirmation
if wait_for "Resolving\|$TUI_TITLE_CONFIRM" 60; then
	if capture | grep -qi "Resolving"; then
		log_pass "H3: 'Resolving' dialog appeared for 4.17"
		if ! wait_for "$TUI_TITLE_CONFIRM" 60; then
			log_fail "H3: Confirmation did not appear after resolution"
		else
			log_pass "H3: Confirmation appeared after resolution"
		fi
	else
		log_pass "H3: Confirmation appeared (resolution was instant)"
	fi
else
	log_fail "H3: Neither Resolving nor Confirmation appeared for 4.17"
fi

if capture | grep -qE '4\.17\.[0-9]+'; then
	log_pass "H3: Resolved version matches 4.17.z pattern"
else
	log_fail "H3: Resolved version not visible on confirmation screen"
fi
screenshot "manual-entry-resolved"

# Accept confirmation and complete wizard to action menu
send_enter
sleep 1

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
	log_pass "H: Action menu appeared after manual version wizard"
else
	log_fail "H: Action menu did not appear"
fi

# ISC verification: channel should be stable, version should be 4.17.z
verify_isconf_screen --channel stable --no-operators

# ============================================================
# Restore primed state: stable + Latest
# ============================================================

log_info "=== Restoring primed state: stable + Latest ==="
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
	log_pass "Primed state restored (stable + Latest)"
else
	log_fail "Could not restore primed state"
fi

# Verify final ISC reflects primed state before exiting
log_info "Final ISC verification (stable + Latest, no operators)..."
verify_isconf_screen --channel stable --no-operators

# Final clean exit
exit_tui
sleep 1

# ============================================================
# Summary
# ============================================================

report_results
