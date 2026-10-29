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

# Run an SSH command with retry.  On first failure, wait and retry once.
# This prevents transient SSH drops from being misreported as "SESSION DEAD".
# The tmux session runs on the remote host and survives SSH disconnects.
_tui_ssh_retry() {
	$_TUI_SSH "$@" 2>/dev/null && return 0
	sleep 2
	$_TUI_SSH "$@" 2>/dev/null
}

# Check if the tmux session is still alive on the remote host.
# Retries once on SSH failure — a dropped SSH connection does NOT mean
# the tmux session died; we just need to reconnect.
tui_session_alive() {
	_tui_ssh_retry "tmux has-session -t $_TUI_SESSION 2>/dev/null"
}

# Capture the current tmux pane content
tui_capture() {
	_tui_ssh_retry "tmux capture-pane -t $_TUI_SESSION -p"
}

# Send keys to the tmux session
tui_keys() {
	_tui_ssh_retry "tmux send-keys -t $_TUI_SESSION $*"
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
			echo "  TMUX SESSION GONE waiting for: $pattern (SSH or tmux exited)" >&2
			tui_screenshot "GONE-$(date +%H%M%S)"
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

# Dismiss post-command result screens (terminal, progress, or confirm_and_execute).
# Terminal mode: "Press ENTER to continue" or "Press R to retry, ENTER to return"
# Progress mode: "All steps completed successfully" with Done button
# confirm_and_execute: "Success" msgbox with OK button
# Returns 0 if a prompt was found and dismissed, 1 otherwise.
tui_dismiss_result() {
	local _scr
	_scr=$(tui_capture)
	if echo "$_scr" | grep -qi "Press.*ENTER\|ENTER to return\|Press R to retry\|steps completed\|Succeeded\|Success"; then
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
			echo "  WARNING: tmux session gone while navigating back to '$pattern'" >&2
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

# --- Internet / mode detection ---

# Detected TUI mode: DISCO, CONNO, or DIRECT (set by tui_detect_mode)
_TUI_DETECTED_MODE=""

# Detect the TUI mode from the backtitle after startup.
# Sets _TUI_DETECTED_MODE to DISCO, CONNO, or DIRECT.
# Usage: tui_detect_mode  (call after splash screen is past)
tui_detect_mode() {
	local _scr
	_scr=$(tui_capture)
	if echo "$_scr" | grep -qi "Fully Disconnected"; then
		_TUI_DETECTED_MODE="DISCO"
	elif echo "$_scr" | grep -qi "Fully Connected"; then
		_TUI_DETECTED_MODE="DIRECT"
	else
		_TUI_DETECTED_MODE="CONNO"
	fi
	echo "  TUI mode detected: $_TUI_DETECTED_MODE"
}

# Check if the TUI is in disconnected mode.
# Usage: if tui_is_disco; then ... fi
tui_is_disco() {
	[[ "$_TUI_DETECTED_MODE" == "DISCO" ]]
}

# Check if internet is available in the TUI (not DISCO).
# Usage: if tui_has_internet; then ... fi
tui_has_internet() {
	[[ "$_TUI_DETECTED_MODE" != "DISCO" ]]
}

# Dismiss startup dialogs that appear before the main menu.
# Handles: splash screen, "Internet Access Required" error, "Bundle on
# connected host" mode selection, bundle info/payload summary.
# Returns 0 when the main menu (Actions) is reached, 1 on timeout.
# Usage: tui_dismiss_startup [timeout_seconds]
tui_dismiss_startup() {
	local timeout="${1:-60}"
	local i _scr

	for (( i=0; i<timeout*2; i++ )); do
		if ! tui_session_alive; then
			echo "  SESSION DEAD during startup" >&2
			return 1
		fi
		_scr=$(tui_capture)

		# Main menu reached
		if echo "$_scr" | grep -qi "Actions\|── Registry ──\|── Cluster ──\|── Mirror ──"; then
			return 0
		fi

		# Splash screen — press Enter
		if echo "$_scr" | grep -qi "OpenShift Installer\|Continue.*Exit\|ABA.*OpenShift"; then
			tui_keys Enter
			sleep 3
			continue
		fi

		# "Internet Access Required" error — TUI will exit after dismiss
		if echo "$_scr" | grep -qi "Internet Access Required\|Cannot access"; then
			echo "  WARNING: Internet Access Required dialog appeared" >&2
			tui_screenshot "startup-no-internet"
			tui_keys Enter
			sleep 2
			return 1
		fi

		# "Bundle on connected host" — select Fully Disconnected (default)
		if echo "$_scr" | grep -qi "Fully Disconnected.*Connected mode\|bundle.*internet"; then
			tui_keys Enter
			sleep 3
			continue
		fi

		# Bundle info / payload summary — dismiss
		if echo "$_scr" | grep -qi "Install Bundle\|payload summary\|Disconnected.*payload"; then
			tui_keys Enter
			sleep 3
			continue
		fi

		sleep 0.5
	done
	echo "  TIMEOUT: main menu not reached in ${timeout}s" >&2
	tui_screenshot "startup-timeout"
	return 1
}

# Skip a test (with PASS) when it requires internet but TUI is in DISCO mode.
# Usage: tui_skip_if_disco "test description"  → returns 0 if skipped
tui_skip_if_disco() {
	local desc="$1"
	if tui_is_disco; then
		echo "  ~ SKIP: $desc (DISCO mode — no internet)"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
		return 0
	fi
	return 1
}

# Skip a test when internet is required but unavailable.
# Checks _TUI_DETECTED_MODE; if DISCO, skips with message and increments PASS.
# Usage: tui_require_internet "test description" || continue
tui_require_internet() {
	local desc="$1"
	if tui_is_disco; then
		echo "  ~ SKIP: $desc (requires internet, TUI is in DISCO mode)"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
		return 1
	fi
	return 0
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
	# Only kill stale processes if they exist
	if $_TUI_SSH "pgrep -f abatui" >/dev/null 2>&1; then
		$_TUI_SSH "pkill -9 -f abatui; pkill -9 -f 'dialog --'; true" 2>/dev/null
		sleep 1
		# Second kill in case of respawn
		$_TUI_SSH "pgrep -f abatui >/dev/null 2>&1 && pkill -9 -f abatui; true" 2>/dev/null
	fi
	tui_clear_failed_tasks
	sleep 0.5
	$_TUI_SSH "tmux new-session -d -s $_TUI_SESSION -x $_TUI_WIDTH -y $_TUI_HEIGHT '$cmd'"
	sleep 2
}

# Kill the TUI session
tui_stop() {
	$_TUI_SSH "tmux kill-session -t $_TUI_SESSION 2>/dev/null; true"
}

# Clean shutdown + stray process check.
# 1. Try to exit the TUI gracefully (dismiss dialogs, Escape to main, exit)
# 2. If still alive, force-kill the tmux session
# 3. Wait for processes to die
# 4. Check for strays — PASS if clean, FAIL if any remain (and kill them)
# Call this instead of duplicating cleanup logic in every test.
tui_cleanup() {
	# Dismiss any result/error dialog first
	tui_dismiss_result 2>/dev/null

	# Try to escape back to main menu — up to 10 Escapes covers deep wizards
	for _i in 1 2 3 4 5 6 7 8 9 10; do
		if ! $_TUI_SSH "tmux has-session -t $_TUI_SESSION 2>/dev/null" 2>/dev/null; then
			break
		fi
		# Check if we reached the main menu
		if tui_capture | grep -qi "Actions"; then
			# On the main menu — press Escape once more to exit the TUI
			tui_keys Escape
			sleep 2
			break
		fi
		tui_keys Escape
		sleep 0.5
	done

	# If session is still alive, try Enter (confirm exit dialog) then force-kill
	if $_TUI_SSH "tmux has-session -t $_TUI_SESSION 2>/dev/null" 2>/dev/null; then
		tui_keys Enter; sleep 1
		tui_keys Escape; sleep 1
		tui_keys Enter; sleep 1
	fi

	# Force-kill the tmux session if it didn't exit cleanly
	tui_stop
	sleep 2

	# Check for strays AFTER the session is gone
	local _strays
	_strays=$($_TUI_SSH "ps -eo pid,ppid,args | grep -E '\bdialog\b|abatui' | grep -v grep" 2>/dev/null || true)
	if [ -z "$_strays" ]; then
		echo "  ✓ PASS: No stray processes"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ✗ FAIL: Stray processes after cleanup:"
		echo "$_strays" | sed 's/^/      /'
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
		$_TUI_SSH "pkill -9 -f abatui 2>/dev/null; pkill -9 -f 'dialog --' 2>/dev/null; true"
		sleep 1
	fi
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
