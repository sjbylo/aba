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

# --- Config ---
SESSION="${SESSION:-tui-test-$$}"
TUI_CMD="${TUI_CMD:-tui/abatui.sh}"
TIMEOUT="${TIMEOUT:-30}"
POLL_INTERVAL="${POLL_INTERVAL:-1}"

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

	log_info "Starting TUI in tmux session: $SESSION"
	tmux new-session -d -s "$SESSION" -x 192 -y 60 "$cmd"
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
	tmux capture-pane -t "$SESSION" -p 2>/dev/null
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
	tmux send-keys -t "$SESSION" "$@"
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
	send Enter
	sleep 2
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
# Usage: paste_pull_secret /path/to/pull-secret.json
paste_pull_secret() {
	local ps_file="$1"
	if [[ ! -f "$ps_file" ]]; then
		log_fail "Pull secret file not found: $ps_file"
		return 1
	fi
	tmux load-buffer "$ps_file"
	tmux paste-buffer -t "$SESSION"
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
# Results
# ============================================================

report_results() {
	echo ""
	echo "========================================"
	echo -e "Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"
	echo "========================================"

	[[ $FAIL -eq 0 ]] && return 0 || return 1
}
