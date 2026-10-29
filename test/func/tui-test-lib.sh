#!/bin/bash
# TUI test harness — reusable helpers for testing abatui via tmux
#
# Usage: source this file, then call tui_* functions.
# Requires: SSH access to the test host, tmux on the test host.
#
# All functions operate on a remote tmux session via SSH.

_TUI_HOST="${TUI_TEST_HOST:-conno.example.com}"
_TUI_SESSION="${TUI_TEST_SESSION:-tui-test}"
_TUI_SSH="ssh -F $HOME/.aba/ssh.conf $_TUI_HOST"
_TUI_PASS=0
_TUI_FAIL=0
_TUI_WIDTH=160
_TUI_HEIGHT=45

# Per-run screenshot directory: /tmp/tui-test/<testname>-<timestamp>/
_TUI_TEST_NAME="$(basename "${BASH_SOURCE[1]:-unknown}" .sh)"
_TUI_RUN_DIR="/tmp/tui-test/${_TUI_TEST_NAME}-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$_TUI_RUN_DIR"

# --- Core helpers ---

# Check if the tmux session is still alive
tui_session_alive() {
	$_TUI_SSH "tmux has-session -t $_TUI_SESSION 2>/dev/null" 2>/dev/null
}

# Capture the current tmux pane content
tui_capture() {
	$_TUI_SSH "tmux capture-pane -t $_TUI_SESSION -p" 2>/dev/null
}

# Send keys to the tmux session
tui_keys() {
	$_TUI_SSH "tmux send-keys -t $_TUI_SESSION $*" 2>/dev/null
}

# Wait for a pattern to appear on screen (polls every 0.5s)
# Usage: tui_wait_for "pattern" [timeout_seconds]
# On failure, auto-captures a screenshot for debugging.
tui_wait_for() {
	local pattern="$1"
	local timeout="${2:-10}"
	local i
	for (( i=0; i<timeout*2; i++ )); do
		if ! tui_session_alive; then
			echo "  SESSION DEAD waiting for: $pattern" >&2
			tui_screenshot "DEAD-$(date +%H%M%S)"
			return 1
		fi
		if tui_capture | grep -qi "$pattern"; then
			return 0
		fi
		sleep 0.5
	done
	echo "  TIMEOUT (${timeout}s) waiting for: $pattern" >&2
	tui_screenshot "TIMEOUT-$(date +%H%M%S)"
	return 1
}

# Confirm a --defaultno yesno dialog by pressing the Yes/OK button.
# --defaultno focuses the No/Cancel button; Left arrow moves to Yes.
tui_confirm_yes() {
	tui_keys Left
	sleep 0.3
	tui_keys Enter
}

# Dismiss post-command result screens (terminal, progress, or TUI mode).
# Terminal mode: "Press ENTER to continue" or "Press R to retry, ENTER to return"
# Progress mode: "All steps completed successfully" with Done button
# Returns 0 if a prompt was found and dismissed, 1 otherwise.
tui_dismiss_result() {
	local _scr
	_scr=$(tui_capture)
	if echo "$_scr" | grep -qi "Press.*ENTER\|ENTER to return\|Press R to retry\|steps completed\|Succeeded"; then
		tui_keys Enter
		sleep 2
		return 0
	fi
	return 1
}

# Wait for pattern to disappear (e.g. after pressing Enter on a dialog)
# Usage: tui_wait_gone "pattern" [timeout_seconds]
tui_wait_gone() {
	local pattern="$1"
	local timeout="${2:-10}"
	local i
	for (( i=0; i<timeout*2; i++ )); do
		if ! tui_session_alive; then
			return 0
		fi
		if ! tui_capture | grep -qi "$pattern"; then
			return 0
		fi
		sleep 0.5
	done
	echo "  TIMEOUT waiting for disappearance of: $pattern" >&2
	return 1
}

# Send keys and wait for expected content to appear
# Usage: tui_keys_wait "keys" "expected_pattern" [timeout]
tui_keys_wait() {
	local keys="$1"
	local pattern="$2"
	local timeout="${3:-10}"
	tui_keys "$keys"
	tui_wait_for "$pattern" "$timeout"
}

# --- Screen parsing ---

# Extract menu items from screen capture.
# Returns lines of "KEY<tab>LABEL" for each item with a shortcut key.
# Format on screen: │ │   K  Some Label   │ │
tui_menu_items() {
	tui_capture | sed -n 's/.*│[[:space:]]*\([A-Z]\)  \(.*\)│.*/\1\t\2/p' \
		| sed 's/[[:space:]]*│[[:space:]]*$//; s/[[:space:]]*$//'
}

# Find the shortcut key for a menu item by label substring (case-insensitive).
# Usage: tui_find_key "Day-2"  → prints "D"
tui_find_key() {
	local label="$1"
	tui_menu_items | grep -i "$label" | head -1 | cut -f1
}

# Extract button labels from screen capture.
# Buttons look like: < Label > or <Label>
# Returns one label per line, in left-to-right order.
tui_buttons() {
	tui_capture | grep -oE '<[^>]+>' | sed 's/^< *//; s/ *>$//; s/^<//; s/>$//'
}

# Count buttons on screen
tui_button_count() {
	tui_buttons | wc -l
}

# Navigate to a specific button by label and press Enter.
# Reads the screen to find button positions, calculates Tab count.
# Assumes focus starts on the first button (OK/Select/Continue).
# Usage: tui_press_button "Help"
tui_press_button() {
	local target="$1"
	local -a btns
	mapfile -t btns < <(tui_buttons)
	local idx=-1
	local i
	for i in "${!btns[@]}"; do
		if [[ "${btns[$i]}" == *"$target"* ]]; then
			idx=$i
			break
		fi
	done
	if [[ $idx -lt 0 ]]; then
		echo "  WARNING: button '$target' not found on screen (buttons: ${btns[*]})" >&2
		return 1
	fi
	for (( i=0; i<idx; i++ )); do
		tui_keys Tab
		sleep 0.3
	done
	tui_keys Enter
}

# Select a menu item by label substring (case-insensitive).
# Finds the shortcut key, sends it, then presses Enter.
# Usage: tui_select_item "Day-2"
tui_select_item() {
	local label="$1"
	local key
	key=$(tui_find_key "$label")
	if [[ -z "$key" ]]; then
		echo "  WARNING: menu item '$label' not found on screen" >&2
		tui_menu_items | sed 's/^/    available: /' >&2
		tui_screenshot "ITEM-NOT-FOUND-$(date +%H%M%S)"
		return 1
	fi
	tui_keys "$key"
	sleep 0.5
	tui_keys Enter
}

# Get the dialog title from screen capture.
# Titles appear as: ┌──── Some Title ────┐
tui_dialog_title() {
	tui_capture | sed -n 's/.*┌[─ ]*\(.*[^ ─]\)[─ ]*┐.*/\1/p' | head -1 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

# Navigate back to a known screen (by title/pattern), pressing Escape as needed.
# Usage: tui_back_to "Actions" [max_attempts]
tui_back_to() {
	local pattern="$1"
	local max="${2:-5}"
	local i
	for (( i=0; i<max; i++ )); do
		if ! tui_session_alive; then
			echo "  WARNING: session dead while navigating back to '$pattern'" >&2
			return 1
		fi
		if tui_capture | grep -qi "$pattern"; then
			return 0
		fi
		tui_keys Escape
		sleep 1
	done
	echo "  WARNING: could not navigate back to '$pattern' after $max Escapes" >&2
	tui_screenshot "NAV-FAIL-$(date +%H%M%S)"
	return 1
}

# Wait for an ISC generation dialog to clear (if present).
# Also detects ISC error dialogs (catalog errors, generation failures) and
# dismisses them by pressing Enter, so the test can continue.
# Usage: tui_wait_isc_done [timeout_seconds]
tui_wait_isc_done() {
	local timeout="${1:-120}"
	local i _scr

	_scr=$(tui_capture)
	# Check for ISC error dialogs first — dismiss with Enter
	if echo "$_scr" | grep -qi "Catalog Error\|ISC.*Failed\|Failed.*catalog\|failed.*pull\|503 Service"; then
		echo "  (dismissing ISC error dialog...)"
		tui_keys Enter; sleep 1
		return 0
	fi

	if ! echo "$_scr" | grep -qi "Generating\|generating\|Please wait"; then
		return 0
	fi
	echo "  (waiting for ISC generation to complete...)"
	for (( i=0; i<timeout*2; i++ )); do
		_scr=$(tui_capture)
		# Check for error dialog that may appear during generation
		if echo "$_scr" | grep -qi "Catalog Error\|ISC.*Failed\|Failed.*catalog\|failed.*pull\|503 Service"; then
			echo "  (dismissing ISC error dialog...)"
			tui_keys Enter; sleep 1
			return 0
		fi
		if ! echo "$_scr" | grep -qi "Generating\|generating\|Please wait"; then
			return 0
		fi
		sleep 0.5
	done
	echo "  TIMEOUT: ISC generation did not complete in ${timeout}s" >&2
	return 1
}

# --- Session management ---

# Clear failed run_once tasks on the test host using ABA's native mechanism.
# This lets the TUI re-attempt ISC generation (and other tasks) cleanly
# instead of showing stale error dialogs from previous failures.
tui_clear_failed_tasks() {
	$_TUI_SSH "cd ~/aba && source scripts/include_all.sh && run_once -F 2>/dev/null; true"
}

# Start the TUI in a fresh tmux session on the test host
tui_start() {
	local cmd="${1:-cd ~/aba && abatui}"
	$_TUI_SSH "tmux kill-session -t $_TUI_SESSION 2>/dev/null; true"
	$_TUI_SSH "pkill -9 -f abatui 2>/dev/null; pkill -9 -f 'dialog --' 2>/dev/null; true"
	sleep 1
	# Verify no stale TUI left — kill again if needed
	$_TUI_SSH "pkill -9 -f abatui 2>/dev/null; true"
	tui_clear_failed_tasks
	sleep 0.5
	$_TUI_SSH "tmux new-session -d -s $_TUI_SESSION -x $_TUI_WIDTH -y $_TUI_HEIGHT '$cmd'"
	sleep 2
}

# Kill the TUI session
tui_stop() {
	$_TUI_SSH "tmux kill-session -t $_TUI_SESSION 2>/dev/null; true"
}

# --- Assertions ---

# Assert the screen contains a pattern
# Usage: tui_assert_contains "pattern" "description"
tui_assert_contains() {
	local pattern="$1"
	local desc="$2"
	if tui_capture | grep -qi "$pattern"; then
		echo "  ✓ PASS: $desc"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
		return 0
	else
		echo "  ✗ FAIL: $desc (expected: $pattern)"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
		return 1
	fi
}

# Assert the screen does NOT contain a pattern
# Usage: tui_assert_not_contains "pattern" "description"
tui_assert_not_contains() {
	local pattern="$1"
	local desc="$2"
	if ! tui_capture | grep -qi "$pattern"; then
		echo "  ✓ PASS: $desc"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
		return 0
	else
		echo "  ✗ FAIL: $desc (unexpected: $pattern)"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
		return 1
	fi
}

# Assert a pattern appears on screen within timeout
# Usage: tui_assert_appears "pattern" "description" [timeout]
tui_assert_appears() {
	local pattern="$1"
	local desc="$2"
	local timeout="${3:-10}"
	if tui_wait_for "$pattern" "$timeout"; then
		echo "  ✓ PASS: $desc"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
		return 0
	else
		echo "  ✗ FAIL: $desc (never appeared: $pattern)"
		echo "    Screen content:"
		tui_capture | head -20 | sed 's/^/      /'
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
		return 1
	fi
}

# Save a screenshot (capture) to a file for debugging.
# Files go into $_TUI_RUN_DIR for per-run isolation.
# A symlink /tmp/tui-test-<label>.txt points to the latest for quick access.
tui_screenshot() {
	local label="${1:-screenshot}"
	local file="$_TUI_RUN_DIR/${label}.txt"
	local link="/tmp/tui-test-${label}.txt"
	tui_capture > "$file"
	ln -sf "$file" "$link"
	echo "  [screenshot: $file]"
}

# --- Reporting ---

tui_summary() {
	echo ""
	echo "========================================"
	echo "  TUI Test Results"
	echo "  PASS: $_TUI_PASS"
	echo "  FAIL: $_TUI_FAIL"
	echo "  Screenshots: $_TUI_RUN_DIR/"
	echo "========================================"
	[ "$_TUI_FAIL" -eq 0 ]
}
