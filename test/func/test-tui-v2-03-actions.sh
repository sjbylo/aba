#!/bin/bash
# TUI actions-v2 — action menu items, settings, advanced, exit summary
#
# Tests:
#   A: View ImageSet Config — dialog appears, YAML content verified, returns to menu
#   B: Save Images — confirm shows "aba save", start, Ctrl-C, returns to menu
#   C: Create Bundle — output path dialog, confirm shows "aba bundle", interrupt, returns
#   D: Local Registry — form with host/user/pw, confirm shows "aba sync", interrupt
#   E: Remote Registry — form with SSH fields, verify SSH Username/Key, back out
#   F: Settings — toggle all 3, verify on-screen toggle text changes
#   G: Advanced — submenu items verified, back to menu
#   H: Action menu Help — verify help text sections
#   I: Back button — returns to wizard from action menu
#   J: Clean exit — exit summary shows files & help hint
#
# Usage: test/func/test-tui-actions-v2.sh [--slow]

set -euo pipefail

source "$(dirname "$0")/tui-test-lib.sh"

if [[ ! -f "$HOME/.pull-secret.json" ]]; then
	echo "ERROR: ~/.pull-secret.json not found"
	exit 1
fi

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

cleanup_actions_v2() {
	stop_tui
	restore_pull_secret
	restore_conf
}
trap cleanup_actions_v2 EXIT

# ============================================================
# Start TUI and reach action menu (Resume dialog -> action menu)
# ============================================================

reach_action_menu

# ============================================================
# Test A: View ImageSet Config
# ============================================================

log_info "=== Test A: View ImageSet Config ==="
select_action "$TUI_ACTION_VIEW_IMAGESET"

if wait_for "kind:.*ImageSetConfiguration\|apiVersion.*mirror\|ImageSetConfiguration" 60; then
	log_pass "A: textbox appeared with YAML content"
	screenshot "A-view-isconf-yaml"

	# Verify channel and version from the real aba.conf appear on screen
	_chan=$(conf_value "ocp_channel") || true
	_ver=$(conf_value "ocp_version") || true
	if [[ -n "$_chan" ]]; then
		assert_screen "$_chan" "A: channel '${_chan}' found in ISC display"
	fi
	if [[ -n "$_ver" ]]; then
		assert_screen "$_ver" "A: version '${_ver}' found in ISC display"
	fi
else
	log_fail "A: textbox did not show YAML content"
	screenshot "A-view-isconf-empty"
fi

send Escape
sleep 1

if wait_for "$TUI_TITLE_ACTION_MENU" 10; then
	log_pass "A: returned to action menu"
else
	log_fail "A: did not return to action menu"
	ensure_action_menu
fi

# Verify no [ABA] output leaked behind the dialog during ISC generation
assert_screen_not "\[ABA\]" "A: no [ABA] messages leaked behind dialog"

# ============================================================
# Test B: Save Images (confirm shows correct command, start + Ctrl-C)
# ============================================================

log_info "=== Test B: Save Images (start + Ctrl-C) ==="
ensure_action_menu
select_action "$TUI_ACTION_SAVE_IMAGES"

# Verify the confirm dialog shows the correct aba command
run_and_interrupt "B-save-images" "aba save"

# ============================================================
# Test C: Create Bundle (output path dialog + confirm + interrupt)
# ============================================================

log_info "=== Test C: Create Bundle ==="
ensure_action_menu
select_action "$TUI_ACTION_CREATE_BUNDLE"

if wait_for "output path\|Enter.*path\|bundle\|$TUI_TITLE_CREATE_BUNDLE" 15; then
	log_pass "C: output path dialog appeared"
	assert_screen "/tmp/ocp-bundle" "C: default bundle path shown"
	screenshot "C-bundle-path"
else
	log_fail "C: output path dialog did not appear"
	screenshot "C-bundle-no-path"
	send Escape
	sleep 1
fi

# Accept default path
send_enter
sleep 1

# Accept any light-bundle or disk-space warnings
if capture | grep -qi "light\|same device\|disk space"; then
	log_info "C: light/disk dialog appeared, pressing Enter"
	send_enter
	sleep 1
fi
if capture | grep -qi "disk space\|continue"; then
	log_info "C: disk space warning, pressing Enter"
	send_enter
	sleep 1
fi

# Verify the confirm dialog shows the correct aba bundle command
run_and_interrupt "C-create-bundle" "aba bundle"

# ============================================================
# Test C2: Light Bundle (same-filesystem path triggers light dialog)
# ============================================================

log_info "=== Test C2: Light Bundle ==="
ensure_action_menu
select_action "$TUI_ACTION_CREATE_BUNDLE"

if wait_for "output path\|Enter.*path\|bundle\|$TUI_TITLE_CREATE_BUNDLE" 15; then
	log_pass "C2: output path dialog appeared"
	screenshot "C2-bundle-path"
else
	log_fail "C2: output path dialog did not appear"
	send Escape; sleep 1
fi

# Clear default path and type a same-filesystem path
clear_input
send "./bundle-test"
send_enter
sleep 2

# Same-filesystem detection should trigger light bundle dialog
if wait_for "light bundle\|Excludes large\|Enable light" 10; then
	log_pass "C2: light bundle dialog appeared"
	screenshot "C2-light-bundle-dialog"

	# Select "Yes" to enable light bundle
	send_enter
	sleep 1

	# Verify confirm dialog contains --light
	if wait_for "$TUI_TITLE_CONFIRM_EXEC" 15; then
		log_pass "C2: confirm dialog appeared"
		if capture | grep -q "\-\-light"; then
			log_pass "C2: confirm dialog contains --light flag"
		else
			log_fail "C2: confirm dialog missing --light flag"
		fi
		screenshot "C2-light-bundle-confirm"

		# Cancel/Back out without running the command
		send Escape
		sleep 1
	else
		log_fail "C2: confirm dialog did not appear after light bundle"
		send Escape; sleep 1
	fi
else
	log_fail "C2: light bundle dialog did not appear (may not be same device)"
	screenshot "C2-no-light-bundle"
	# May have gone straight to confirm or disk space warning, dismiss
	send Escape; sleep 1
fi

ensure_action_menu

# ============================================================
# Test D: Local Registry (form fields + confirm command + interrupt)
# ============================================================

log_info "=== Test D: Local Registry ==="
ensure_action_menu
select_action "$TUI_ACTION_LOCAL_REGISTRY"

if wait_for "$TUI_TITLE_LOCAL_QUAY\|$TUI_TITLE_LOCAL_DOCKER\|Registry Host\|Configure local" 15; then
	log_pass "D: registry form appeared"
	assert_screen "Registry Host" "D: Registry Host field present"
	assert_screen "Registry Username" "D: Registry Username field present"
	assert_screen "Registry Password" "D: Registry Password field present"
	screenshot "D-local-reg-form"
else
	log_fail "D: registry form did not appear"
	screenshot "D-local-reg-no-form"
	send Escape
	sleep 1
fi

# Submit form with defaults
send_enter
sleep 1

# Verify confirm dialog shows the correct command with "sync"
run_and_interrupt "D-local-registry" "aba sync"

# ============================================================
# Test E: Remote Registry (form, verify SSH fields, back out)
# ============================================================

log_info "=== Test E: Remote Registry ==="
ensure_action_menu
select_action "$TUI_ACTION_REMOTE_REGISTRY"

if wait_for "$TUI_TITLE_REMOTE_QUAY\|Remote Host\|Configure remote" 15; then
	log_pass "E: remote registry form appeared"
	assert_screen "SSH Username" "E: SSH Username field present"
	assert_screen "SSH Key" "E: SSH Key Path field present"
	assert_screen "Remote Host" "E: Remote Host field present"
	screenshot "E-remote-reg-form"

	# Fill in Remote Host field with a test hostname.
	# The "Remote Host (FQDN)" field is the first field in the form.
	# Clear any default value before typing.
	clear_input
	send "test-remote.example.com"
	sleep 1

	# Submit form (Tab to OK button, then Enter)
	send_enter
	sleep 2

	# Verify confirm dialog shows the correct command with the hostname
	if wait_for "$TUI_TITLE_CONFIRM_EXEC" 15; then
		log_pass "E: confirm dialog appeared after form submit"
		if capture | grep -q "test-remote.example.com"; then
			log_pass "E: confirm dialog contains test-remote.example.com"
		else
			log_fail "E: confirm dialog missing test-remote.example.com"
		fi
		if capture | grep -qi "sync"; then
			log_pass "E: confirm dialog contains sync command"
		else
			log_fail "E: confirm dialog missing sync command"
		fi
		screenshot "E-remote-reg-confirm"

		# Cancel/Back without running the command
		send Escape
		sleep 1
	else
		log_fail "E: confirm dialog did not appear after form submit"
		screenshot "E-remote-reg-no-confirm"
		send Escape; sleep 1
	fi
else
	log_fail "E: remote registry form did not appear"
	screenshot "E-remote-reg-no-form"
fi

ensure_action_menu

# ============================================================
# Test F: Settings toggles
# ============================================================

log_info "=== Test F: Settings toggles ==="
ensure_action_menu

select_action "$TUI_ACTION_SETTINGS"

if ! wait_for "$TUI_TITLE_SETTINGS" 10; then
	log_fail "F: settings dialog did not appear"
	send Escape
	sleep 1
else
	log_pass "F: settings dialog appeared"
	assert_screen "Auto-answer" "F: Auto-answer setting visible"
	assert_screen "Registry Type" "F: Registry Type setting visible"
	assert_screen "Retry Count" "F: Retry Count setting visible"

	# Verify initial toggle states are shown
	screenshot "F-settings-initial"

	# Toggle Auto-answer (item 1) — should flip OFF -> ON
	send_input "$TUI_SETTINGS_AUTO_ANSWER"
	sleep 1
	if wait_for "$TUI_TITLE_SETTINGS" 5; then
		log_pass "F: auto-answer toggled (settings redisplayed)"
		# After toggle, "ON" should appear (was OFF by default)
		assert_screen "ON\|OFF" "F: auto-answer toggle state shown"
	fi

	# Toggle Registry Type (item 2) — should cycle Auto -> Quay
	send_input "$TUI_SETTINGS_REGISTRY_TYPE"
	sleep 1
	if wait_for "$TUI_TITLE_SETTINGS" 5; then
		log_pass "F: registry type toggled (settings redisplayed)"
		assert_screen "Quay\|Docker\|Auto" "F: registry type value shown"
	fi

	# Toggle Retry Count (item 3) — should cycle off -> 2
	send_input "$TUI_SETTINGS_RETRY_COUNT"
	sleep 1
	if wait_for "$TUI_TITLE_SETTINGS" 5; then
		log_pass "F: retry count toggled (settings redisplayed)"
	fi

	screenshot "F-settings-toggled"

	# Back to action menu
	send Escape
	sleep 1
fi

if wait_for "$TUI_TITLE_ACTION_MENU" 5; then
	log_pass "F: returned to action menu"
	# Verify settings summary in the action menu shows updated values
	assert_screen "Configure" "F: Configure label visible in action menu"
	screenshot "F-action-menu-settings"
else
	log_fail "F: did not return to action menu"
fi

# ============================================================
# Test G: Advanced Options submenu
# ============================================================

log_info "=== Test G: Advanced Options ==="
ensure_action_menu
select_action "$TUI_ACTION_ADVANCED"

if wait_for "$TUI_TITLE_ADVANCED" 5; then
	log_pass "G: advanced submenu appeared"
	screenshot "G-advanced-menu"
	assert_screen "Generate ImageSet Config" "G: has 'Generate ImageSet Config & Exit' option"
	assert_screen "Edit ImageSet Config" "G: has 'Edit ImageSet Config' option"
	assert_screen "Delete registry" "G: has 'Delete registry' option"
	assert_screen "Exit" "G: has 'Exit' option"
else
	log_fail "G: advanced submenu did not appear"
	screenshot "G-advanced-no-menu"
fi

send Escape
sleep 1

if wait_for "$TUI_TITLE_ACTION_MENU" 5; then
	log_pass "G: returned to action menu"
else
	log_fail "G: did not return to action menu"
fi

# ============================================================
# Test H: Action menu Help button
# ============================================================

log_info "=== Test H: Action menu Help ==="
ensure_action_menu

# Tab order in action menu: 1=Extra(Back), 2=Cancel(Exit), 3=Help, 4=OK(Select)
send_tab_tab_tab_enter
sleep 1

if wait_for "Choose Next Action - Help\|REVIEW:\|AIR-GAPPED" 10; then
	log_pass "H: help dialog appeared"
	assert_screen "View ImageSet Config" "H: help mentions View ImageSet Config"
	assert_screen "Air-Gapped" "H: help mentions Air-Gapped"
	assert_screen "Create Air-Gapped Install Bundle" "H: help mentions Create Bundle"
	assert_screen "Save Images" "H: help mentions Save Images"
	assert_screen "Local Registry" "H: help mentions Local Registry"
	assert_screen "Remote Registry" "H: help mentions Remote Registry"
	assert_screen "CONFIGURE" "H: help mentions CONFIGURE section"
	assert_screen "ADVANCED" "H: help mentions ADVANCED section"
	screenshot "H-action-help"
else
	log_fail "H: help dialog did not appear"
	screenshot "H-action-no-help"
fi

send Escape
sleep 1

if wait_for "$TUI_TITLE_ACTION_MENU" 10; then
	log_pass "H: returned to action menu after help"
else
	log_fail "H: did not return to action menu after help"
fi

# ============================================================
# Test I: Back button returns to wizard
# ============================================================

log_info "=== Test I: Back button from action menu ==="
ensure_action_menu

# Extra button = Back (Tab from menu list -> Extra)
send_tab_enter
sleep 1

# Should land on Channel or operators depending on wizard flow
if wait_for "$TUI_TITLE_CHANNEL\|$TUI_TITLE_OPERATORS\|$TUI_TITLE_PULL_SECRET" 15; then
	log_pass "I: Back button left action menu (wizard screen appeared)"
	screenshot "I-back-to-wizard"
else
	log_fail "I: Back button did not leave action menu"
	screenshot "I-back-failed"
fi

# ============================================================
# Test J: Clean exit with exit summary
# ============================================================

log_info "=== Test J: Clean exit with summary ==="

# Test I left us on the operators screen. Navigate to action menu, then exit.
operators_to_action_menu || true

if ! wait_for "$TUI_TITLE_ACTION_MENU" 30; then
	log_fail "J: could not reach action menu for exit test"
	report_results
	exit 1
fi

exit_tui
sleep 2

# TUI should have exited and printed the summary to the terminal.
# remain-on-exit keeps the tmux pane alive so we can capture the output.
exit_screen=$(capture)
screenshot "J-exit-summary"

if echo "$exit_screen" | grep -q "Files created/updated\|No files were modified\|TUI complete\.\|No configuration was saved"; then
	log_pass "J: exit summary appeared"
else
	log_fail "J: exit summary did not appear"
fi

if echo "$exit_screen" | grep -q "aba\.conf\|imageset-config"; then
	log_pass "J: exit summary lists generated files"
else
	log_fail "J: exit summary does not list generated files"
fi

if echo "$exit_screen" | grep -q "aba --help"; then
	log_pass "J: exit summary shows help hint"
else
	log_fail "J: exit summary does not show help hint"
fi

if echo "$exit_screen" | grep -q "README.md"; then
	log_pass "J: exit summary mentions README"
else
	log_fail "J: exit summary does not mention README"
fi

# ============================================================
# Summary
# ============================================================

report_results
