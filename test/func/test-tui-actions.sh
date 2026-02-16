#!/bin/bash
# TUI action menu tests — exercises every action menu item
# For command actions: starts the command via "Run in TUI", then Ctrl-C to
# interrupt, and verifies the failure dialog appears correctly.
#
# Prerequisites:
#   - tmux installed
#   - aba.conf exists with valid config (channel, version, pull secret, domain)
#   - Run from aba root directory
#
# Usage: test/func/test-tui-actions.sh

set -euo pipefail

# Source shared test library (also cd's to aba root)
source "$(dirname "$0")/tui-test-lib.sh"

# --- Precondition checks ---

if [[ ! -f aba.conf ]]; then
	echo "ERROR: aba.conf not found — need existing config for action tests"
	exit 1
fi

# --- Backup aba.conf ---

_CONF_BACKUP=""

backup_conf() {
	_CONF_BACKUP=$(mktemp /tmp/tui-test-conf-XXXXXX)
	cp aba.conf "$_CONF_BACKUP"
	log_info "Backed up aba.conf to $_CONF_BACKUP"
}

restore_conf() {
	if [[ -n "$_CONF_BACKUP" ]] && [[ -f "$_CONF_BACKUP" ]]; then
		cp "$_CONF_BACKUP" aba.conf
		rm -f "$_CONF_BACKUP"
		log_info "Restored aba.conf"
	fi
}

backup_conf

# --- Cleanup on exit ---
cleanup_actions_test() {
	stop_tui
	restore_conf
}
trap cleanup_actions_test EXIT

# --- Helper: check if tmux session is alive ---
session_alive() {
	tmux has-session -t "$SESSION" 2>/dev/null
}

# --- Helper: navigate to action menu from TUI start ---
reach_action_menu() {
	if session_alive; then
		stop_tui
		sleep 1
	fi
	start_tui
	dismiss_welcome || { log_fail "Could not dismiss welcome"; return 1; }

	# Resume dialog -> Continue
	if wait_for "$TUI_TITLE_RESUME" 15; then
		send Enter
		sleep 2
	fi

	if ! wait_for "$TUI_TITLE_ACTION_MENU" 20; then
		log_fail "Could not reach action menu"
		return 1
	fi
}

# --- Helper: ensure we're at action menu, restarting TUI if needed ---
ensure_action_menu() {
	if ! session_alive; then
		log_info "TUI session died, restarting"
		reach_action_menu
		return $?
	fi
	if wait_for "$TUI_TITLE_ACTION_MENU" 5; then
		return 0
	fi
	log_info "Not at action menu, restarting TUI"
	reach_action_menu
}

# --- Helper: select an action menu item by number ---
select_action() {
	local item="$1"
	send "$item" Enter
	sleep 2
}

# --- Helper: at confirm_and_execute, select "Run in TUI", wait for start,
#     Ctrl-C, and verify failure dialog ---
run_and_interrupt() {
	local action_name="$1"

	# Should be at confirm_and_execute dialog
	if ! wait_for "$TUI_TITLE_CONFIRM_EXEC" 10; then
		log_fail "$action_name: confirm_and_execute dialog did not appear"
		screenshot "${action_name}-no-confirm"
		return 1
	fi
	log_pass "$action_name: confirm_and_execute dialog appeared"
	screenshot "${action_name}-confirm"

	# Give dialog time to finish rendering and become interactive
	sleep 1

	# Explicitly select "1" (Run in TUI) then press Enter to confirm
	send "1"
	sleep 0.5
	send Enter
	sleep 2

	# Wait for the progressbox ("Executing"), a fast failure ("Failed"),
	# or a fast success ("Success").
	local _state=""
	local _elapsed=0
	while [[ $_elapsed -lt 15 ]]; do
		local _screen
		_screen=$(capture)
		if echo "$_screen" | grep -qi "Failed"; then
			_state="failed"; break
		fi
		if echo "$_screen" | grep -qi "Success"; then
			_state="success"; break
		fi
		if echo "$_screen" | grep -qi "Executing"; then
			_state="executing"; break
		fi
		sleep 1
		_elapsed=$((_elapsed + 1))
	done

	case "$_state" in
		failed)
			log_pass "$action_name: command failed quickly (as expected)"
			screenshot "${action_name}-result"
			;;
		success)
			log_pass "$action_name: command completed successfully"
			screenshot "${action_name}-result"
			;;
		executing)
			# Command is running in progressbox — send Ctrl-C to interrupt
			sleep 1
			send C-c
			sleep 3

			# After Ctrl-C, expect either Failed or Success (if it finished just before)
			if wait_for "Failed\|Success" 15; then
				log_pass "$action_name: result dialog appeared after Ctrl-C"
				screenshot "${action_name}-result"
			else
				log_fail "$action_name: no result dialog appeared after Ctrl-C"
				screenshot "${action_name}-no-result"
				send Escape
				sleep 2
				return 1
			fi
			;;
		*)
			log_fail "$action_name: no Executing/Failed/Success appeared (timeout)"
			screenshot "${action_name}-timeout"
			return 1
			;;
	esac

	# Dismiss result dialog — Escape or Enter both go "Back to Menu"
	send Escape
	sleep 2

	# Should be back at action menu
	if wait_for "$TUI_TITLE_ACTION_MENU" 10; then
		log_pass "$action_name: returned to action menu"
	else
		log_info "$action_name: not at action menu after dismiss (may need restart)"
	fi
}

# ============================================================
# Start TUI and reach action menu
# ============================================================

reach_action_menu

# ============================================================
# Test 1: View ImageSet Config
# ============================================================

log_info "Test 1: View ImageSet Config"
select_action "$TUI_ACTION_VIEW_IMAGESET"

# The TUI first shows "Generating ImageSet configuration..." infobox, then a textbox.
# Wait for the ACTUAL textbox (YAML content), not the generating infobox.
if wait_for "$TUI_TITLE_IMAGESET" 30; then
	log_pass "View ImageSet: textbox appeared"
	screenshot "view-imageset"
else
	# Might be a "not found" msgbox instead
	if capture | grep -qi "not found"; then
		log_pass "View ImageSet: not-found message appeared"
	else
		log_fail "View ImageSet: no content appeared"
		screenshot "view-imageset-empty"
	fi
fi

# Give dialog time to finish rendering and become interactive
sleep 3

# dialog --textbox: Escape closes the dialog cleanly (rc=255)
# Send Escape directly via tmux to avoid any quoting issues with the send helper
log_info "Sending Escape to close textbox (session=$SESSION)"
tmux send-keys -t "$SESSION" Escape
sleep 3

if wait_for "$TUI_TITLE_ACTION_MENU" 10; then
	log_pass "View ImageSet: returned to action menu"
else
	# Retry with C-c in case Escape was lost
	log_info "Escape did not work, trying C-c"
	tmux send-keys -t "$SESSION" C-c
	sleep 2
	if wait_for "$TUI_TITLE_ACTION_MENU" 5; then
		log_pass "View ImageSet: returned to action menu (via C-c)"
	else
		log_fail "View ImageSet: did not return to action menu"
		ensure_action_menu
	fi
fi

# ============================================================
# Test 2: Save Images (simplest command action — no form)
# ============================================================

log_info "Test 2: Save Images (start + Ctrl-C)"
ensure_action_menu
select_action "$TUI_ACTION_SAVE_IMAGES"
run_and_interrupt "save-images"

# ============================================================
# Test 3: Create Bundle (has inputbox for output path)
# ============================================================

log_info "Test 3: Create Bundle (start + Ctrl-C)"
ensure_action_menu
select_action "$TUI_ACTION_CREATE_BUNDLE"

# Wait for the output path inputbox
if wait_for "output path\|Enter.*path\|bundle" 10; then
	log_pass "Create Bundle: output path dialog appeared"
	screenshot "bundle-path"
else
	log_fail "Create Bundle: output path dialog did not appear"
	screenshot "bundle-no-path"
	send Escape
	sleep 2
fi

# Accept default path (Enter)
send Enter
sleep 2

# May get a light-bundle or disk-space yesno — accept any with Enter
if capture | grep -qi "light\|same device\|disk space"; then
	log_info "Create Bundle: light/disk dialog appeared, pressing Enter"
	send Enter
	sleep 2
fi
# A second yesno may appear (disk space warning after declining light)
if capture | grep -qi "disk space\|continue"; then
	log_info "Create Bundle: disk space warning, pressing Enter"
	send Enter
	sleep 2
fi

run_and_interrupt "create-bundle"

# ============================================================
# Test 4: Local Registry (has form)
# ============================================================

log_info "Test 4: Local Registry (start + Ctrl-C)"
ensure_action_menu
select_action "$TUI_ACTION_LOCAL_REGISTRY"

# Wait for the registry form (Quay or Docker)
if wait_for "Registry\|Host\|Username\|Password\|registry" 10; then
	log_pass "Local Registry: form appeared"
	screenshot "local-reg-form"
else
	log_fail "Local Registry: form did not appear"
	screenshot "local-reg-no-form"
	send Escape
	sleep 2
fi

# Submit form with defaults — Enter from field submits in dialog --form
send Enter
sleep 2

run_and_interrupt "local-registry"

# ============================================================
# Test 5: Remote Registry (has form with SSH fields)
# ============================================================

log_info "Test 5: Remote Registry (form + confirm)"
ensure_action_menu
select_action "$TUI_ACTION_REMOTE_REGISTRY"

# Wait for the remote registry form
if wait_for "Remote\|SSH\|Host\|registry" 10; then
	log_pass "Remote Registry: form appeared"
	screenshot "remote-reg-form"
	# Verify key fields are present
	assert_screen "SSH Username" "Remote Registry: SSH Username field present"
	assert_screen "SSH Key" "Remote Registry: SSH Key field present"
else
	log_fail "Remote Registry: form did not appear"
	screenshot "remote-reg-no-form"
	send Escape
	sleep 2
fi

# Submit form with defaults
send Enter
sleep 2

# Verify confirm_and_execute dialog appears with the SSH command
if wait_for "$TUI_TITLE_CONFIRM_EXEC" 10; then
	log_pass "Remote Registry: confirm dialog appeared"
	assert_screen "sync" "Remote Registry: command contains sync"
	assert_screen "ssh\|SSH\|-k" "Remote Registry: command has SSH key flag"
	screenshot "remote-reg-confirm"
else
	log_fail "Remote Registry: confirm dialog did not appear"
	screenshot "remote-reg-no-confirm"
fi

# Press Back to return to action menu (command execution already proven in tests 2-4)
send Escape
sleep 2
ensure_action_menu

# ============================================================
# Test 6: Rerun Wizard
# ============================================================

log_info "Test 6: Rerun Wizard"
ensure_action_menu
select_action "$TUI_ACTION_RERUN_WIZARD"

# Rerun Wizard restarts the wizard — Channel dialog should appear
if wait_for "$TUI_TITLE_CHANNEL" 10; then
	log_pass "Rerun Wizard: Channel dialog appeared"
	screenshot "rerun-wizard-channel"
else
	log_fail "Rerun Wizard: Channel dialog did not appear"
	screenshot "rerun-wizard-no-channel"
fi

# Escape out -> confirm quit
send Escape
sleep 2

if wait_for "$TUI_TITLE_CONFIRM_EXIT" 5; then
	log_pass "Rerun Wizard: confirm exit appeared"
	send Enter
	sleep 2
else
	log_info "Rerun Wizard: no confirm exit, checking for action menu"
fi

# ============================================================
# Test 7: Settings toggles
# ============================================================

log_info "Test 7: Settings toggles"
# TUI may have exited after wizard escape — restart if needed
ensure_action_menu

select_action "$TUI_ACTION_SETTINGS"

if ! wait_for "$TUI_TITLE_SETTINGS" 5; then
	log_fail "Settings: dialog did not appear"
	send Escape
	sleep 1
else
	log_pass "Settings: dialog appeared"
	screenshot "settings-initial"

	# Toggle Auto-answer (item 1): should flip ON <-> OFF
	send "$TUI_SETTINGS_AUTO_ANSWER" Enter
	sleep 1
	# Settings dialog redisplays with new value
	if wait_for "Auto-answer" 5; then
		log_pass "Settings: auto-answer toggled"
		screenshot "settings-auto-toggled"
	fi

	# Toggle Registry Type (item 2): cycles Auto -> Quay -> Docker
	send "$TUI_SETTINGS_REGISTRY_TYPE" Enter
	sleep 1
	if wait_for "Registry Type" 5; then
		log_pass "Settings: registry type toggled"
		screenshot "settings-reg-toggled"
	fi

	# Toggle Retry Count (item 3): cycles off -> 2 -> 8
	send "$TUI_SETTINGS_RETRY_COUNT" Enter
	sleep 1
	if wait_for "Retry Count" 5; then
		log_pass "Settings: retry count toggled"
		screenshot "settings-retry-toggled"
	fi

	# Return to action menu
	send Escape
	sleep 1
fi

if wait_for "$TUI_TITLE_ACTION_MENU" 5; then
	log_pass "Settings: returned to action menu"
	# The Settings label should now show updated values
	assert_screen "Settings" "Settings label visible in action menu"
	screenshot "action-menu-after-settings"
else
	log_fail "Settings: did not return to action menu"
fi

# ============================================================
# Test 8: Advanced Options
# ============================================================

log_info "Test 8: Advanced Options"
ensure_action_menu
select_action "$TUI_ACTION_ADVANCED"

if wait_for "$TUI_TITLE_ADVANCED" 5; then
	log_pass "Advanced: submenu appeared"
	screenshot "advanced-menu"
	# Verify expected items
	assert_screen "ImageSet\|Generate" "Advanced: has ImageSet option"
	assert_screen "Delete\|Uninstall\|Exit\|commands" "Advanced: has other options"
else
	log_fail "Advanced: submenu did not appear"
	screenshot "advanced-no-menu"
fi

# Return to action menu
send Escape
sleep 1

if wait_for "$TUI_TITLE_ACTION_MENU" 5; then
	log_pass "Advanced: returned to action menu"
else
	log_fail "Advanced: did not return to action menu"
fi

# ============================================================
# Test 9: Clean exit
# ============================================================

log_info "Test 9: Clean exit"
ensure_action_menu
send "$TUI_ACTION_EXIT" Enter
sleep 2

if ! session_alive; then
	log_pass "TUI exited cleanly"
else
	log_fail "TUI did not exit"
fi

# ============================================================
# Summary
# ============================================================

report_results
