#!/bin/bash
# Shared helper library for TUI automated tests
# Source this file — do not execute directly.
#
# Provides:
#   start_tui / stop_tui   — tmux session management
#   capture / send          — screen interaction
#   wait_for / assert_screen — assertions
#   log_pass / log_fail / log_info — colored output
#   dismiss_welcome         — skip the welcome dialog
#   report_results          — print summary & set exit code
#   backup_pull_secret / restore_pull_secret / paste_pull_secret — pull secret helpers

# --- Abort if executed directly ---
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	echo "ERROR: This file should be sourced, not executed."
	exit 1
fi

# --- Ensure aba root ---
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
ABA_ROOT="$(pwd)"

# --- Source shared TUI constants (dialog titles, menu IDs) ---
source "$ABA_ROOT/tui/tui-strings.sh"

# --- Parse test runner flags (before sourcing scripts consume them) ---
TUI_SLOW=0
for _arg in "$@"; do
	case "$_arg" in
		--slow) TUI_SLOW=1 ;;
	esac
done

# --- Config ---
SESSION="${SESSION:-tui-test-$$}"
TUI_CMD="${TUI_CMD:-tui/abatui.sh}"
TIMEOUT="${TIMEOUT:-30}"
POLL_INTERVAL="${POLL_INTERVAL:-1}"

# ============================================================
# Test isolation — pristine starting state
# ============================================================

# Full reset to post-clone state. Call BEFORE backup_conf/backup_pull_secret
# if aba.conf and pull secret should not exist, or AFTER backup_pull_secret
# if the pull secret must be restored later.
reset_test_state() {
	log_info "=== reset_test_state: running aba reset ==="
	make reset force=1 >/dev/null 2>&1 || true
	if ! rm -rf ~/.aba/runner ~/.aba/cache ~/.aba/tmp ~/.aba/logs 2>/dev/null; then
		log_info "Warning: could not remove some ~/.aba paths (permission denied?) — continuing"
	fi
	rm -f mirror/save/.created mirror/sync/.created
	rm -rf mirror/save/working-dir mirror/sync/working-dir
	rm -rf .index
	rm -f aba.conf
	log_info "=== reset_test_state: done ==="
}

# Clean oc-mirror working dirs that may have been corrupted by Ctrl-C.
# Call after run_and_interrupt to prevent cascading failures.
clean_oc_mirror_workdirs() {
	rm -rf mirror/save/working-dir mirror/sync/working-dir 2>/dev/null || true
}

# Create a minimal but complete aba.conf so the TUI shows the Resume dialog
# and skips straight to the action menu.
create_test_conf() {
	cat > aba.conf <<-'CONF'
	ocp_channel=stable
	ocp_version=4.17.0
	platform=bm
	domain=example.com
	op_sets=
	ops=
	pull_secret_file=~/.pull-secret.json
	ask=true
	CONF
	# Strip leading tabs from heredoc indentation
	sed -i 's/^\t//' aba.conf
	log_info "Created test aba.conf (stable/4.17.0/bm)"
}

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

# --- Counters ---
PASS=0
FAIL=0

# ============================================================
# Logging
# ============================================================

log_pass() {
	echo -e "${GREEN}PASS${NC}: $1"
	PASS=$((PASS + 1))
}

log_fail() {
	echo -e "${RED}FAIL${NC}: $1"
	FAIL=$((FAIL + 1))
}

log_info() {
	echo -e "${YELLOW}INFO${NC}: $1"
}

# ============================================================
# tmux session management
# ============================================================

start_tui() {
	# Usage: start_tui [extra_env_vars...]
	# Example: start_tui "FOO=bar"
	local cmd="bash $TUI_CMD"

	if ! command -v tmux &>/dev/null; then
		echo "ERROR: tmux is required but not installed"
		exit 1
	fi

	if [[ ! -f "$TUI_CMD" ]]; then
		echo "ERROR: $TUI_CMD not found"
		exit 1
	fi

	# Kill any leftover session (e.g. dead pane kept by remain-on-exit)
	tmux kill-session -t "$SESSION" 2>/dev/null || true

	log_info "Starting TUI in tmux session: $SESSION"
	tmux new-session -d -s "$SESSION" -x 240 -y 70 "$cmd"
	tmux set-option -t "$SESSION" escape-time 0
	tmux set-option -t "$SESSION" remain-on-exit on
}

stop_tui() {
	log_info "Cleaning up tmux session: $SESSION"
	tmux kill-session -t "$SESSION" 2>/dev/null || true
}

# ============================================================
# Screen interaction
# ============================================================

# Capture current tmux pane content
capture() {
	tmux capture-pane -t "$SESSION" -p 2>/dev/null || true
}

# Send keys to the tmux session
# Usage: send Enter  |  send "7" Enter  |  send Tab Enter
#
# IMPORTANT: dialog button Tab order from menu list:
#   1 Tab → Extra button (rc=3)
#   2 Tabs → Cancel button (rc=1)
#   3 Tabs → Help button (rc=2)
#   4 Tabs → OK button (rc=0)
# This differs from the visual order! Use "send Tab Enter" to hit Extra.
send() {
	if [[ $TUI_SLOW -eq 1 ]]; then
		local _has_enter=0 _pre_args=()
		for _arg in "$@"; do
			if [[ "$_arg" == "Enter" ]]; then
				_has_enter=1
				break
			fi
			_pre_args+=("$_arg")
		done
		if [[ $_has_enter -eq 1 && ${#_pre_args[@]} -gt 0 ]]; then
			tmux send-keys -t "$SESSION" "${_pre_args[@]}"
			sleep 1
			tmux send-keys -t "$SESSION" Enter
		else
			[[ $_has_enter -eq 1 ]] && sleep 1
			tmux send-keys -t "$SESSION" "$@"
		fi
		sleep 1
	else
		tmux send-keys -t "$SESSION" "$@"
	fi
}

# ============================================================
# Assertions
# ============================================================

# Wait for a string to appear on screen, with timeout
# Usage: wait_for "expected text" [timeout_seconds]
# Returns 0 on success, 1 on timeout (also logs FAIL)
wait_for() {
	local expected="$1"
	local timeout="${2:-$TIMEOUT}"
	local elapsed=0

	while [[ $elapsed -lt $timeout ]]; do
		if capture | grep -qi "$expected"; then
			return 0
		fi
		sleep "$POLL_INTERVAL"
		elapsed=$((elapsed + POLL_INTERVAL))
	done

	log_fail "Timed out waiting for: '$expected' (${timeout}s)"
	log_info "Screen content at timeout:"
	capture | head -25
	return 1
}

# Assert that the current screen contains text (no waiting)
# Usage: assert_screen "expected text" "description"
assert_screen() {
	local expected="$1"
	local desc="${2:-Screen contains '$expected'}"

	if capture | grep -qi "$expected"; then
		log_pass "$desc"
	else
		log_fail "$desc"
	fi
}

# ============================================================
# Common navigation helpers
# ============================================================

# Dismiss the welcome dialog (wait for it, press Enter)
dismiss_welcome() {
	log_info "Waiting for welcome dialog..."
	if wait_for "$TUI_TITLE_WELCOME" 15; then
		log_pass "Welcome dialog appeared"
	else
		log_fail "Welcome dialog did not appear"
		return 1
	fi
	send_enter
	sleep 1
}

# ============================================================
# Pull secret helpers
# ============================================================

_PS_BACKUP=""

# Backup ~/.pull-secret.json to a temp file
backup_pull_secret() {
	local ps_file="$HOME/.pull-secret.json"
	if [[ -f "$ps_file" ]]; then
		_PS_BACKUP=$(mktemp /tmp/tui-test-ps-XXXXXX)
		cp "$ps_file" "$_PS_BACKUP"
		log_info "Backed up pull secret to $_PS_BACKUP"
	else
		_PS_BACKUP=""
		log_info "No pull secret to back up"
	fi
}

# Restore ~/.pull-secret.json from backup
restore_pull_secret() {
	local ps_file="$HOME/.pull-secret.json"
	if [[ -n "$_PS_BACKUP" ]] && [[ -f "$_PS_BACKUP" ]]; then
		cp "$_PS_BACKUP" "$ps_file"
		chmod 600 "$ps_file"
		rm -f "$_PS_BACKUP"
		log_info "Restored pull secret"
	else
		log_info "No pull secret backup to restore"
	fi
}

# Paste pull secret into the editbox via tmux buffer
# Formats as multi-line JSON first to avoid editbox segfault on long single lines.
# Usage: paste_pull_secret /path/to/pull-secret.json
paste_pull_secret() {
	local ps_file="$1"
	if [[ ! -f "$ps_file" ]]; then
		log_fail "Pull secret file not found: $ps_file"
		return 1
	fi
	local formatted=$(mktemp)
	jq . "$ps_file" > "$formatted"
	tmux load-buffer "$formatted"
	tmux paste-buffer -t "$SESSION"
	rm -f "$formatted"
	sleep 1
}

# ============================================================
# Screenshots
# ============================================================

SCREENSHOT_DIR="${ABA_ROOT}/test/func/screenshots"
SCREENSHOT_NUM=0

# Save a "screenshot" of the current tmux pane to a file
# Usage: screenshot "step-name"
# Files are numbered chronologically: 01-welcome.txt, 02-channel.txt, etc.
screenshot() {
	local name="$1"
	SCREENSHOT_NUM=$((SCREENSHOT_NUM + 1))
	local num
	num=$(printf "%02d" "$SCREENSHOT_NUM")
	local test_name
	test_name=$(basename "${BASH_SOURCE[1]}" .sh)
	mkdir -p "$SCREENSHOT_DIR"
	local file="${SCREENSHOT_DIR}/${test_name}-${num}-${name}.txt"
	capture > "$file"
	log_info "Screenshot saved: $file"
}

# ============================================================
# Parse operator names from basket/dialog capture
# ============================================================
# Use after capturing the basket view or a selection dialog; then verify
# each name appears in the ISC (verify_isconf_screen --has "$name" ...).
# Output: one operator name per line, sorted -u.
# Usage: parse_basket_operator_names "$capture"
parse_basket_operator_names() {
	echo "$1" | grep -oE '[a-z][a-z0-9-]*-operator' | sort -u
}

# Parse OpenShift version (4.x.y) from a dialog capture (e.g. version confirmation screen).
# Use with verify_isconf_screen --version "$(parse_version_from_capture "$cap")".
# Output: first match of 4.x.y, or empty.
# Usage: parse_version_from_capture "$capture"
parse_version_from_capture() {
	echo "$1" | grep -oE '4\.[0-9]+\.[0-9]+' | head -1
}

# ============================================================
# ISC verification via dialog screen
# ============================================================

# Open View ImageSet Config (action 1), wait for textbox, run screen checks,
# escape back to action menu.
# Usage: verify_isconf_screen [--channel CHAN] [--version VER]
#        [--has-operators] [--no-operators]
#        [--has OP_NAME ...] [--not-has OP_NAME ...]
# Must be at the action menu when called.
verify_isconf_screen() {
	local expected_channel="" expected_version=""
	local expect_operators="" expect_no_operators=""
	local -a must_have=() must_not_have=()

	while [[ $# -gt 0 ]]; do
		case "$1" in
			--channel)   expected_channel="$2"; shift 2 ;;
			--version)   expected_version="$2"; shift 2 ;;
			--has-operators)   expect_operators=1; shift ;;
			--no-operators)    expect_no_operators=1; shift ;;
			--has)       must_have+=("$2"); shift 2 ;;
			--not-has)   must_not_have+=("$2"); shift 2 ;;
		*) shift ;;
	esac
	done

	send_input "$TUI_ACTION_VIEW_IMAGESET"
	sleep 1

	# ISC generation can take a while (catalog/version work)
	if ! wait_for "ImageSetConfiguration\|apiVersion.*mirror" 120; then
		log_fail "ISC verify: textbox did not appear (no ImageSetConfiguration on screen)"
		screenshot "isconf-no-textbox"
		send Escape
		sleep 1
		return 1
	fi
	log_pass "ISC verify: textbox appeared with ImageSetConfiguration"

	# Capture top portion of the textbox
	local screen_top
	screen_top=$(capture)

	# Scroll to bottom to capture operator section
	send End
	sleep 1
	local screen_bottom
	screen_bottom=$(capture)

	# Combine both captures for comprehensive checking
	local full_screen
	full_screen=$(printf '%s\n%s' "$screen_top" "$screen_bottom")

	if [[ -n "$expected_channel" ]]; then
		if echo "$full_screen" | grep -q "${expected_channel}-"; then
			log_pass "ISC verify: channel '${expected_channel}' found"
		else
			log_fail "ISC verify: channel '${expected_channel}' NOT found on screen"
		fi
	fi

	if [[ -n "$expected_version" ]]; then
		if echo "$full_screen" | grep -q "$expected_version"; then
			log_pass "ISC verify: version '${expected_version}' found"
		else
			log_fail "ISC verify: version '${expected_version}' NOT found on screen"
		fi
	fi

	if [[ -n "$expect_operators" ]]; then
		# Dialog textbox wraps lines with │ box-drawing chars, so match
		# "operators:" anywhere on the line, excluding commented lines
		if echo "$full_screen" | grep -v '#.*operators:' | grep -q 'operators:'; then
			log_pass "ISC verify: operators section present"
		else
			log_fail "ISC verify: operators section NOT found on screen"
		fi
	fi

	if [[ -n "$expect_no_operators" ]]; then
		if echo "$full_screen" | grep -v '#.*operators:' | grep -q 'operators:'; then
			log_fail "ISC verify: operators section found but expected none"
		else
			log_pass "ISC verify: no operators section (as expected)"
		fi
	fi

	local op
	for op in "${must_have[@]}"; do
		if echo "$full_screen" | grep -qi "$op"; then
			log_pass "ISC verify: operator '$op' found"
		else
			log_fail "ISC verify: operator '$op' NOT found on screen"
		fi
	done

	for op in "${must_not_have[@]}"; do
		if echo "$full_screen" | grep -qi "$op"; then
			log_fail "ISC verify: operator '$op' found but should be absent"
		else
			log_pass "ISC verify: operator '$op' absent (as expected)"
		fi
	done

	screenshot "isconf-verify"

	send Escape
	sleep 1

	if ! wait_for "$TUI_TITLE_ACTION_MENU" 10; then
		log_fail "ISC verify: did not return to action menu"
	fi
}

# Toggle a specific item in a dialog checklist by name.
# Captures the screen, finds the item's position among [*]/[ ] entries,
# sends the appropriate number of Down keys, then Space.
# Usage: checklist_toggle "operator-name"
checklist_toggle() {
	local target="$1"
	local lines pos

	lines=$(capture | grep '\[.\]')
	pos=$(echo "$lines" | grep -n "$target" | head -1 | cut -d: -f1)

	if [[ -z "$pos" ]]; then
		log_fail "checklist_toggle: '$target' not found in checklist"
		return 1
	fi

	for (( _i=1; _i < pos; _i++ )); do
		send Down
	done
	send Space
}

# Assert that the current screen does NOT contain text
# Usage: assert_screen_not "text" "description"
assert_screen_not() {
	local unexpected="$1"
	local desc="${2:-Screen does not contain '$unexpected'}"

	if capture | grep -qi "$unexpected"; then
		log_fail "$desc"
	else
		log_pass "$desc"
	fi
}

# ============================================================
# Config backup/restore helpers (shared across test files)
# ============================================================

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

# Check if tmux session is alive
session_alive() {
	tmux has-session -t "$SESSION" 2>/dev/null || return 1
	# With remain-on-exit, session exists even after the command exits.
	# Check if the pane is still running (not "dead").
	local pane_dead
	pane_dead=$(tmux display-message -t "$SESSION" -p '#{pane_dead}' 2>/dev/null) || return 1
	[[ "$pane_dead" != "1" ]]
}

# Navigate to action menu from TUI start (resume flow)
# After reset, background tasks (version fetch, oc-mirror download, catalog
# prefetch) all restart from scratch, so the first launch can take 60-90s
# before the Resume dialog appears.
reach_action_menu() {
	if session_alive; then
		stop_tui
		sleep 1
	fi
	start_tui
	dismiss_welcome || { log_fail "Could not dismiss welcome"; return 1; }

	# Wait for either Resume dialog or action menu directly (some flows skip resume)
	if wait_for "$TUI_TITLE_RESUME\|$TUI_TITLE_ACTION_MENU" 120; then
		# If we landed on Resume, press Enter to continue to action menu
		if capture | grep -q "$TUI_TITLE_RESUME"; then
			send_enter
			sleep 1
		fi
	fi

	if ! wait_for "$TUI_TITLE_ACTION_MENU" 60; then
		log_fail "Could not reach action menu"
		return 1
	fi
	log_pass "reach_action_menu: at action menu"
}

# Ensure we're at action menu, restarting TUI if needed
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

# Select an action menu item by tag letter
select_action() {
	local item="$1"
	send_input "$item"
	sleep 1
}

# Exit TUI from the action menu via the Exit button (cancel-label)
# Dialog cancel button is reached by pressing Escape, which triggers
# confirm_quit; we then confirm by pressing Enter (the "Exit" yes-label).
exit_tui() {
	send Escape
	sleep 1
	if wait_for "Exit ABA TUI" 5; then
		send_enter
		sleep 1
	fi
}

# At confirm_and_execute, select "Run in TUI", wait for start,
# Ctrl-C, and verify result dialog.
# Usage: run_and_interrupt "label" ["expected_cmd_pattern"]
# If expected_cmd_pattern is given, asserts it appears on the confirm screen.
run_and_interrupt() {
	local action_name="$1"
	local expected_cmd="${2:-}"

	if ! wait_for "$TUI_TITLE_CONFIRM_EXEC" 15; then
		log_fail "$action_name: confirm_and_execute dialog did not appear"
		screenshot "${action_name}-no-confirm"
		return 1
	fi
	log_pass "$action_name: confirm_and_execute dialog appeared"

	screenshot "${action_name}-confirm"

	# Verify the confirm dialog shows the expected command
	if [[ -n "$expected_cmd" ]]; then
		if capture | grep -qi "$expected_cmd"; then
			log_pass "$action_name: confirm dialog shows '$expected_cmd'"
		else
			log_fail "$action_name: confirm dialog missing '$expected_cmd'"
			screenshot "${action_name}-confirm-mismatch"
		fi
	fi

	sleep 1
	send "1"
	send_enter
	sleep 2

	# Result dialog detection: match the result dialog title OR its buttons.
	# Title patterns: "Command Output (Success)" / "Command Output (Failed"
	# But Ctrl-C can corrupt the title rendering, so also match the buttons
	# that only appear in result dialogs: "Back to Menu" / "Exit TUI" / "Retry"
	local _result_pat="Output (Success)\|Output (Failed\|Back to Menu\|Exit TUI"

	# Wait up to 30s for the command to start, fail fast, or succeed
	local _state="" _elapsed=0
	while [[ $_elapsed -lt 30 ]]; do
		local _screen
		_screen=$(capture)
		if echo "$_screen" | grep -q "$_result_pat"; then
			if echo "$_screen" | grep -q "Output (Success)"; then
				_state="success"
			else
				_state="failed"
			fi
			break
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
			# Wait for meaningful output (e.g. oc-mirror "Success copying")
			# before sending Ctrl-C. No need to let it run the full duration.
			log_info "$action_name: command executing, waiting for output..."
			local _run_wait=0 _got_output=0
			while [[ $_run_wait -lt 90 ]]; do
				sleep 2
				_run_wait=$((_run_wait + 2))
				local _scr
				_scr=$(capture)
				if echo "$_scr" | grep -q "$_result_pat"; then
					log_info "$action_name: command finished after ${_run_wait}s"
					_got_output=2
					break
				fi
				if echo "$_scr" | grep -qi "Success\|copying\|mirror complete"; then
					log_info "$action_name: output detected after ${_run_wait}s, interrupting"
					_got_output=1
					break
				fi
			done
			screenshot "${action_name}-running"

			# Send Ctrl-C unless the command already finished on its own
			if [[ $_got_output -ne 2 ]] && ! capture | grep -q "$_result_pat"; then
				send C-c
				sleep 2
			fi

			if wait_for "$_result_pat\|$TUI_TITLE_CONFIRM_EXEC" 30; then
				if capture | grep -q "$_result_pat"; then
					log_pass "$action_name: result dialog appeared"
					screenshot "${action_name}-result"
				else
					log_pass "$action_name: command completed (back at confirm)"
					screenshot "${action_name}-result"
				fi
			else
				log_fail "$action_name: no result dialog appeared after Ctrl-C"
				screenshot "${action_name}-no-result"
				send Escape
				sleep 1
				return 1
			fi
			;;
		*)
			log_fail "$action_name: no Executing/Failed/Success appeared (timeout)"
			screenshot "${action_name}-timeout"
			return 1
			;;
	esac

	# Dismiss result/confirm dialogs back to action menu.
	# May need multiple Escapes: result -> confirm -> action menu
	local _dismiss=0
	while [[ $_dismiss -lt 3 ]]; do
		if capture | grep -q "$TUI_TITLE_ACTION_MENU"; then
			break
		fi
		send Escape
		sleep 1
		_dismiss=$((_dismiss + 1))
	done

	if wait_for "$TUI_TITLE_ACTION_MENU" 10; then
		log_pass "$action_name: returned to action menu"
	else
		log_info "$action_name: not at action menu after dismiss (may need restart)"
	fi

	# Ctrl-C during oc-mirror can corrupt its working-dir, causing subsequent
	# commands (save, bundle, sync) to fail.  Clean up after every interrupt.
	clean_oc_mirror_workdirs
}

# Navigate through wizard accepting defaults to reach operators screen
# Expects to start at channel screen (or pull secret if no valid PS)
# Usage: wizard_to_operators
wizard_to_operators() {
	if wait_for "$TUI_TITLE_CHANNEL" 10; then
		log_pass "wizard_to_operators: Channel screen appeared"
		send_enter
		sleep 1
	else
		log_fail "wizard_to_operators: Channel screen did not appear"
		return 1
	fi

	if wait_for "$TUI_TITLE_VERSION" 20; then
		log_pass "wizard_to_operators: Version screen appeared"
		send_enter
		sleep 1
	else
		log_fail "wizard_to_operators: Version screen did not appear"
		return 1
	fi

	if wait_for "$TUI_TITLE_CONFIRM" 15; then
		log_pass "wizard_to_operators: Version confirmation appeared"
		send_enter
		sleep 1
	elif wait_for "Verifying" 5; then
		if wait_for "$TUI_TITLE_CONFIRM" 30; then
			log_pass "wizard_to_operators: Version confirmation appeared (after verify)"
			send_enter
			sleep 1
		else
			log_fail "wizard_to_operators: Version confirmation did not appear after verify"
			return 1
		fi
	else
		log_fail "wizard_to_operators: Version confirmation did not appear"
		return 1
	fi

	if wait_for "$TUI_TITLE_PLATFORM" 120; then
		log_pass "wizard_to_operators: Platform screen appeared"
		send_tab_enter
		sleep 1
	else
		log_fail "wizard_to_operators: Platform screen did not appear"
		return 1
	fi

	# 300s: cold catalog download (3 indexes) can take 2-3 min after aba reset
	if ! wait_for "$TUI_TITLE_OPERATORS" 300; then
		log_fail "wizard_to_operators: Operators screen did not appear"
		return 1
	fi
	log_pass "wizard_to_operators: Operators screen appeared"
}

# Navigate from operators through to action menu (skip operators)
# Usage: operators_to_action_menu
operators_to_action_menu() {
	send_tab_enter
	sleep 1

	if wait_for "$TUI_TITLE_EMPTY_BASKET" 5; then
		log_info "Empty basket warning, accepting"
		send_enter
		sleep 1
	fi

	if ! wait_for "$TUI_TITLE_ACTION_MENU" 60; then
		log_fail "operators_to_action_menu: did not reach action menu"
		return 1
	fi
	log_pass "operators_to_action_menu: reached action menu"
}

# Keystroke helpers — centralise the "sleep before Enter" pattern.
# Each pauses 1s right before Enter so the viewer sees which
# button / field is highlighted.  Adjust the sleep here when tuning.

send_enter() {
	sleep 1
	send Enter
}

send_tab_enter() {
	send Tab
	sleep 1
	send Enter
}

send_input() {
	send "$1"
	sleep 1
	send Enter
}

send_tab_tab_enter() {
	send Tab Tab
	sleep 1
	send Enter
}

send_tab_tab_tab_enter() {
	send Tab Tab Tab
	sleep 1
	send Enter
}

# Clear a dialog inputbox field (send End + 25 Backspaces).
# Uses raw tmux to avoid --slow delays on each keystroke.
# Usage: clear_input
clear_input() {
	tmux send-keys -t "$SESSION" End
	tmux send-keys -t "$SESSION" \
		BSpace BSpace BSpace BSpace BSpace \
		BSpace BSpace BSpace BSpace BSpace \
		BSpace BSpace BSpace BSpace BSpace \
		BSpace BSpace BSpace BSpace BSpace \
		BSpace BSpace BSpace BSpace BSpace
	[[ $TUI_SLOW -eq 1 ]] && sleep 1 || true
}

# Read a value from aba.conf, stripping comments and whitespace
# Usage: conf_value "key_name"
conf_value() {
	local key="$1"
	grep "^${key}=" aba.conf 2>/dev/null | cut -d= -f2 | sed 's/#.*//' | tr -d '[:space:]'
}

# ============================================================
# Results
# ============================================================

report_results() {
	echo ""
	echo "========================================"
	echo -e "Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"
	echo "========================================"

	[[ $FAIL -eq 0 ]] && return 0 || return 1
}
