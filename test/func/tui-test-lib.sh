#!/bin/bash
# TUI test harness — reusable helpers for testing abatui via tmux
#
# Usage: source this file, then call tui_* functions.
# Requires: SSH access to the test host, tmux on the test host.
#
# All functions operate on a remote tmux session via SSH.

_TUI_HOST="${TUI_TEST_HOST:-conno.example.com}"
_TUI_SESSION="${TUI_TEST_SESSION:-tui-test}"
_TUI_SSH_CFG="$HOME/.aba/ssh.conf"
_TUI_SSH="ssh -F $_TUI_SSH_CFG $_TUI_HOST"
_TUI_PASS=0
_TUI_FAIL=0
_TUI_WIDTH=160
_TUI_HEIGHT=45

# ---------------------------------------------------------------------------
# Throwaway-cluster lab defaults
# Source of truth: .cursor/skills/throwaway-cluster/SKILL.md
# ---------------------------------------------------------------------------
TUI_LAB_DOMAIN="example.com"
TUI_LAB_DNS_NTP="10.0.1.8"		# cluster-node DNS+NTP (NOT bastion 192.168.2.38)
TUI_LAB_MACHINE_NETWORK="10.0.0.0/20"
TUI_LAB_GATEWAY="10.0.0.1"
TUI_LAB_PORTS="ens160"

# Resolve IPs for a throwaway cluster name (10.0.1.0/24 allocation).
# Sets: _lab_starting_ip _lab_api_ip _lab_apps_ip _lab_type
# Usage: tui_lab_cluster_ips sno || exit 1
tui_lab_cluster_ips() {
	local name="$1"
	case "$name" in
		sno)      _lab_starting_ip=10.0.1.201; _lab_api_ip=10.0.1.201; _lab_apps_ip=10.0.1.201; _lab_type=sno ;;
		sno2)     _lab_starting_ip=10.0.1.202; _lab_api_ip=10.0.1.202; _lab_apps_ip=10.0.1.202; _lab_type=sno ;;
		sno3)     _lab_starting_ip=10.0.1.203; _lab_api_ip=10.0.1.203; _lab_apps_ip=10.0.1.203; _lab_type=sno ;;
		sno4)     _lab_starting_ip=10.0.1.204; _lab_api_ip=10.0.1.204; _lab_apps_ip=10.0.1.204; _lab_type=sno ;;
		compact)  _lab_starting_ip=10.0.1.71;  _lab_api_ip=10.0.1.216; _lab_apps_ip=10.0.1.226; _lab_type=compact ;;
		compact2) _lab_starting_ip=10.0.1.91;  _lab_api_ip=10.0.1.212; _lab_apps_ip=10.0.1.222; _lab_type=compact ;;
		standard) _lab_starting_ip=10.0.1.81;  _lab_api_ip=10.0.1.217; _lab_apps_ip=10.0.1.227; _lab_type=standard ;;
		ocp)      _lab_starting_ip=10.0.1.100; _lab_api_ip=10.0.1.100; _lab_apps_ip=10.0.1.100; _lab_type=sno ;;
		*)
			echo "  ERROR: unknown throwaway cluster '$name' (see throwaway-cluster skill)" >&2
			echo "  Valid: sno sno2 sno3 sno4 compact compact2 standard ocp" >&2
			return 1
			;;
	esac
	return 0
}

# Verify lab DNS A record for api.<name> matches the skill API column.
# Usage: tui_lab_verify_api_dns sno 10.0.1.201
tui_lab_verify_api_dns() {
	local name="$1" expect="$2"
	local got
	got=$(dig +short "api.${name}.${TUI_LAB_DOMAIN}" "@${TUI_LAB_DNS_NTP}" 2>/dev/null | head -1)
	if [[ -z "$got" ]]; then
		echo "  ERROR: No DNS A record for api.${name}.${TUI_LAB_DOMAIN} on ${TUI_LAB_DNS_NTP}" >&2
		return 1
	fi
	if [[ "$got" != "$expect" ]]; then
		echo "  ERROR: api.${name}.${TUI_LAB_DOMAIN} is $got (expected $expect per throwaway-cluster skill)" >&2
		return 1
	fi
	return 0
}

# Resolve + verify throwaway-cluster lab IPs for TUI_CLUSTER_NAME.
# Sets: _lab_starting_ip _lab_api_ip _lab_apps_ip _lab_type
# Plus aliases used by older tests: _api_ip _starting_ip _machine_network _gateway _cluster_dns
# Usage: tui_lab_resolve_cluster "${TUI_CLUSTER_NAME:-sno}" || exit 1
tui_lab_resolve_cluster() {
	local name="${1:?cluster name required}"
	tui_lab_cluster_ips "$name" || return 1
	tui_lab_verify_api_dns "$name" "$_lab_api_ip" || return 1
	_starting_ip="$_lab_starting_ip"
	_api_ip="$_lab_api_ip"
	_apps_ip="$_lab_apps_ip"
	_machine_network="$TUI_LAB_MACHINE_NETWORK"
	_gateway="$TUI_LAB_GATEWAY"
	_cluster_dns="$TUI_LAB_DNS_NTP"
	_cluster_ntp="$TUI_LAB_DNS_NTP"
	_ports="$TUI_LAB_PORTS"
	_domain="$TUI_LAB_DOMAIN"
	echo "  Lab IPs ($name): type=$_lab_type starting=$_lab_starting_ip api=$_lab_api_ip apps=$_lab_apps_ip dns/ntp=$TUI_LAB_DNS_NTP"
	return 0
}

# True if the Basics "Cluster name:" field equals $1 exactly.
# "Cluster name:.*sno" must NOT match sno4 — use this instead of a prefix grep.
# Usage: tui_cluster_name_is sno [optional_screen_text]
tui_cluster_name_is() {
	local want="${1:?}"
	local scr="${2:-}"
	[ -n "$scr" ] || scr=$(tui_capture)
	# Name is followed by spaces (padding to the box edge) or end-of-line
	echo "$scr" | grep -qiE "Cluster name:[[:space:]]*${want}([[:space:]]|$)"
}

# Set a networking-page field via hotkey → clear → type → Enter.
# Usage: tui_set_net_field S 10.0.1.201
tui_set_net_field() {
	local key="$1" value="$2"
	tui_keys "$key"; sleep 0.4
	tui_keys Enter; sleep 0.5
	tui_keys C-u; sleep 0.3
	$_TUI_SSH "tmux send-keys -t $_TUI_SESSION -l '$value'" 2>/dev/null
	sleep 0.3
	tui_keys Enter; sleep 1
}

# Apply throwaway-cluster skill network values on Install Cluster page 2.
# Requires _lab_* vars from tui_lab_resolve_cluster / tui_lab_cluster_ips.
# Usage: tui_apply_lab_network
tui_apply_lab_network() {
	local pane
	pane=$(tui_capture)

	if ! echo "$pane" | grep -qE "Machine network:[[:space:]]*${TUI_LAB_MACHINE_NETWORK}"; then
		echo "  Setting machine network to ${TUI_LAB_MACHINE_NETWORK}"
		tui_set_net_field M "$TUI_LAB_MACHINE_NETWORK"
		pane=$(tui_capture)
	fi

	if ! echo "$pane" | grep -qE "Starting IP:[[:space:]]*${_lab_starting_ip}"; then
		echo "  Setting starting IP to ${_lab_starting_ip}"
		tui_set_net_field S "$_lab_starting_ip"
		pane=$(tui_capture)
	fi

	# compact/standard: set VIPs explicitly (SNO has no VIP fields)
	if [[ "${_lab_type:-sno}" != "sno" ]]; then
		if ! echo "$pane" | grep -qE "API VIP:[[:space:]]*${_lab_api_ip}"; then
			echo "  Setting API VIP to ${_lab_api_ip}"
			tui_set_net_field A "$_lab_api_ip"
			pane=$(tui_capture)
		fi
		if ! echo "$pane" | grep -qE "Ingress VIP:[[:space:]]*${_lab_apps_ip}"; then
			echo "  Setting Ingress VIP to ${_lab_apps_ip}"
			tui_set_net_field I "$_lab_apps_ip"
			pane=$(tui_capture)
		fi
	fi

	if ! echo "$pane" | grep -qiE "DNS servers:[[:space:]]*${TUI_LAB_DNS_NTP}"; then
		echo "  Setting DNS servers to ${TUI_LAB_DNS_NTP}"
		tui_set_net_field D "$TUI_LAB_DNS_NTP"
		pane=$(tui_capture)
	fi

	if ! echo "$pane" | grep -qE "Gateway:[[:space:]]*${TUI_LAB_GATEWAY}"; then
		echo "  Setting gateway to ${TUI_LAB_GATEWAY}"
		tui_set_net_field G "$TUI_LAB_GATEWAY"
		pane=$(tui_capture)
	fi

	if ! echo "$pane" | grep -qiE "NTP servers:[[:space:]]*${TUI_LAB_DNS_NTP}"; then
		echo "  Setting NTP servers to ${TUI_LAB_DNS_NTP}"
		tui_set_net_field N "$TUI_LAB_DNS_NTP"
		pane=$(tui_capture)
	fi

	# Assert critical fields
	pane=$(tui_capture)
	if echo "$pane" | grep -qiE "DNS servers:[[:space:]]*${TUI_LAB_DNS_NTP}"; then
		echo "  ✓ PASS: DNS servers set to ${TUI_LAB_DNS_NTP}"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ✗ FAIL: DNS servers not ${TUI_LAB_DNS_NTP} (got: $(echo "$pane" | grep -oiE 'DNS servers:[^│]*' | head -1))"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	fi
	if echo "$pane" | grep -qE "Starting IP:[[:space:]]*${_lab_starting_ip}"; then
		echo "  ✓ PASS: Starting IP set to ${_lab_starting_ip}"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ✗ FAIL: Starting IP not ${_lab_starting_ip}"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	fi
}

# Ensure Interfaces page ports match skill (ens160 for VMware).
# Usage: tui_apply_lab_ports
tui_apply_lab_ports() {
	local pane
	pane=$(tui_capture)
	if echo "$pane" | grep -qE "Ports:[[:space:]]*${TUI_LAB_PORTS}"; then
		return 0
	fi
	echo "  Setting ports to ${TUI_LAB_PORTS}"
	tui_keys P; sleep 0.4
	tui_keys Enter; sleep 0.5
	tui_keys C-u; sleep 0.3
	$_TUI_SSH "tmux send-keys -t $_TUI_SESSION -l '$TUI_LAB_PORTS'" 2>/dev/null
	sleep 0.3
	tui_keys Enter; sleep 1
}

# Per-run screenshot directory: /tmp/tui-test/<testname>-<timestamp>/
_TUI_TEST_NAME="$(basename "${BASH_SOURCE[1]:-unknown}" .sh)"
_TUI_RUN_DIR="/tmp/tui-test/${_TUI_TEST_NAME}-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$_TUI_RUN_DIR"

# Prune old screenshot dirs for this test, keeping the 3 most recent
_tui_old_dirs=$(ls -dt /tmp/tui-test/${_TUI_TEST_NAME}-* 2>/dev/null | tail -n +4)
[ -n "$_tui_old_dirs" ] && rm -rf $_tui_old_dirs
unset _tui_old_dirs

# --- Per-host exclusive lock ---
# Only one TUI test may run against a given host at a time.
# Uses flock with a per-host lock file; a second test on the same host
# fails immediately instead of silently conflicting.
# Skip if test-tui-all.sh already holds the outer lock (_TUI_LOCK_HELD=1).
if [[ "${_TUI_LOCK_HELD:-}" != "1" ]]; then
	_TUI_LOCK_FILE="/tmp/tui-test-${_TUI_HOST}.lock"
	_tui_lock_holder=$(cat "$_TUI_LOCK_FILE" 2>/dev/null || true)
	exec 9>"$_TUI_LOCK_FILE"
	if ! flock -n 9; then
		echo "FATAL: Another TUI test is already running on $_TUI_HOST"
		echo "  Lock file: $_TUI_LOCK_FILE"
		echo "  Holder:    ${_tui_lock_holder:-unknown}"
		echo ""
		echo "  If no test is running, remove the lock file:"
		echo "    rm -f $_TUI_LOCK_FILE"
		exit 99
	fi
	echo "PID=$$ test=$_TUI_TEST_NAME started=$(date +%Y%m%d-%H%M%S)" >&9
	unset _tui_lock_holder
fi

# --- Pre-test disk cleanup ---
# Removes expendable artifacts to prevent "disk full" during tests.
# Conservative: keeps oc-mirror cache (saves network downloads) and only
# removes tar files that have already been loaded into the registry.
# Call tui_pre_cleanup before any long-running test (sync, install, upgrade).
tui_pre_cleanup() {
	echo "  Pre-test disk cleanup on $_TUI_HOST..."
	local _before _after

	_before=$($_TUI_SSH "df --output=avail /home 2>/dev/null | tail -1 | tr -d ' '" 2>/dev/null || echo 0)
	_before=$(( _before / 1024 / 1024 ))  # GB
	echo "  Disk free before: ${_before} GB"

	# 1. Podman: prune unused images (old operator catalog indexes, etc.)
	echo "  Pruning podman images..."
	$_TUI_SSH "podman image prune -af 2>/dev/null" >/dev/null 2>&1 || true

	# 2. Keep ~/.oc-mirror — it's a download cache that reduces network traffic.

	# 3. Mirror tar archives — only delete if already loaded into the registry.
	#    Check: .oc-mirror-exit-code == 0 means the last sync/load succeeded,
	#    so the tar contents are in the registry and the tars are expendable.
	local _tar_size _oc_rc
	_tar_size=$($_TUI_SSH "du -sm ~/aba/mirror/data/mirror_*.tar 2>/dev/null | awk '{s+=\$1} END{print s+0}'" 2>/dev/null || echo 0)
	_tar_size=${_tar_size//[^0-9]/}
	: "${_tar_size:=0}"
	if [[ "$_tar_size" -gt 500 ]]; then
		_oc_rc=$($_TUI_SSH "cat ~/aba/mirror/.oc-mirror-exit-code 2>/dev/null" 2>/dev/null || echo "")
		_oc_rc=${_oc_rc//[^0-9]/}
		if [[ "$_oc_rc" == "0" ]]; then
			echo "  Removing loaded mirror tar files ($(( _tar_size / 1024 )) GB)..."
			$_TUI_SSH "rm -f ~/aba/mirror/data/mirror_*.tar" 2>/dev/null || true
		else
			echo "  Keeping mirror tar files (not yet loaded, exit code: ${_oc_rc:-unknown})"
		fi
	fi

	# 4. Podman container storage cleanup (stopped containers, build cache)
	$_TUI_SSH "podman system prune -f 2>/dev/null" >/dev/null 2>&1 || true

	_after=$($_TUI_SSH "df --output=avail /home 2>/dev/null | tail -1 | tr -d ' '" 2>/dev/null || echo 0)
	_after=$(( _after / 1024 / 1024 ))  # GB
	local _freed=$(( _after - _before ))
	echo "  Disk free after: ${_after} GB (freed ${_freed} GB)"
}

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
	# Skip yesno dialogs (Yes/No buttons) — caller must handle those explicitly
	if echo "$_scr" | grep -qi "Yes.*No\|apply now.*later"; then
		return 1
	fi
	if echo "$_scr" | grep -qi "Press.*ENTER\|ENTER to return\|Press R to retry\|steps completed\|Succeeded\|Success"; then
		tui_keys Enter
		sleep 2
		return 0
	fi
	return 1
}

# Dismiss a TUI error/failure dialog and return to the main menu.
# Handles: "Failed" / "Error" progress dialogs, "View Output" button,
# terminal "Press ENTER" prompts.
# Returns 0 when back at Actions menu, 1 on failure.
tui_dismiss_error() {
	local _scr _i
	for (( _i=0; _i<5; _i++ )); do
		_scr=$(tui_capture)
		# Already at main menu
		if echo "$_scr" | grep -qi "Actions"; then
			return 0
		fi
		# Error dialog with buttons — press Back/Done/Enter to dismiss
		if echo "$_scr" | grep -qi "FAILED\|Error.*step\|failed"; then
			tui_keys Enter; sleep 2
			continue
		fi
		# Terminal prompt
		if echo "$_scr" | grep -qi "Press.*ENTER\|ENTER to return"; then
			tui_keys Enter; sleep 2
			continue
		fi
		# Progress result with Done button
		if echo "$_scr" | grep -qi "steps completed\|Done"; then
			tui_press_button "Done" 2>/dev/null || tui_keys Enter
			sleep 2
			continue
		fi
		tui_keys Escape; sleep 1
	done
	tui_back_to "Actions" 5
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
# Letter menus: │ │   K  Some Label   │ │
# Numbered menus (delete list): │ │   1  sno4.example.com   │ │
tui_menu_items() {
	tui_capture | sed -n 's/.*│[[:space:]]*\([A-Z0-9]\)  \(.*\)│.*/\1\t\2/p' \
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
		sleep 0.2
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

# Assert the dialog title matches a pattern (case-insensitive).
# Usage: tui_assert_title "Cluster – Basics" "Basics page title"
tui_assert_title() {
	local pattern="$1"
	local desc="$2"
	local title
	title=$(tui_dialog_title)
	if echo "$title" | grep -qi "$pattern"; then
		echo "  ✓ PASS: $desc (title: '$title')"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
		return 0
	else
		echo "  ✗ FAIL: $desc (expected title matching '$pattern', got '$title')"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
		return 1
	fi
}

# Navigate back to a known screen (by title/pattern), pressing Escape as needed.
# Usage: tui_back_to "Actions" [max_attempts]
tui_back_to() {
	local pattern="$1"
	local max="${2:-5}"
	local i _scr
	for (( i=0; i<max; i++ )); do
		if ! tui_session_alive; then
			echo "  WARNING: tmux session gone while navigating back to '$pattern'" >&2
			return 1
		fi
		_scr=$(tui_capture)
		if echo "$_scr" | grep -qi "$pattern"; then
			return 0
		fi
		# Protect against exit confirmation — pressing Escape at the main
		# menu opens "Confirm Exit" with buttons "Exit" (Yes) and "Continue" (No).
		# Tab to the "Continue" button and press Enter to stay in the TUI.
		if echo "$_scr" | grep -qi "Exit ABA\|Confirm Exit\|Are you sure.*exit\|Really exit\|Quit ABA"; then
			echo "  (exit dialog detected — pressing Continue to stay)" >&2
			tui_press_button "Continue" 2>/dev/null || { tui_keys Tab Enter; }
			sleep 1
			continue
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
			sleep 1
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
			sleep 1
			continue
		fi

		# Bundle info / payload summary — dismiss
		if echo "$_scr" | grep -qi "Install Bundle\|payload summary\|Disconnected.*payload"; then
			tui_keys Enter
			sleep 1
			continue
		fi

		# Post-install auto-dialogs (e.g., "Configure OperatorHub") — escape them
		if echo "$_scr" | grep -qi "Configure OperatorHub\|OperatorHub\|day2\|Day-2:"; then
			tui_keys Escape
			sleep 2
			continue
		fi

		# Any progress dialog during startup — wait
		if echo "$_scr" | grep -qi "In Progress\|Succeeded\|N/A.*│\|steps completed"; then
			tui_keys Enter 2>/dev/null
			sleep 1
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

# --- Common patterns (DRY helpers) ---

# Deploy ALL ABA core + TUI code to the test host.
# Uses git ls-files to build a tarball of tracked (+ untracked-not-ignored)
# files, matching the same approach as the e2e deploy framework.
# Copies: scripts/, templates/, tools/, others/, tui/, Makefile, aba, abatui,
#         install, mirror/Makefile — everything needed for a working ABA.
# Usage: tui_deploy_code
tui_deploy_code() {
	# Top-level docs required by 'aba bundle' / backup.sh tar (CHANGELOG, LICENSE, …).
	local _paths=(scripts/ templates/ tools/ others/ tui/ Makefile aba abatui install mirror/Makefile
		CHANGELOG.md LICENSE Troubleshooting.md README.md VERSION AGENTS.md)
	local _tar
	_tar=$(mktemp /tmp/tui-deploy.XXXXXX.tar.gz)

	# Build tarball from disk using git ls-files (respects .gitignore)
	git ls-files --cached --others --exclude-standard -- "${_paths[@]}" \
		| tar czf "$_tar" -T - 2>/dev/null

	# Upload and extract on remote host (overlay, never wipe)
	scp -q -F "$_TUI_SSH_CFG" "$_tar" "$_TUI_HOST:/tmp/tui-deploy.tar.gz" 2>/dev/null
	$_TUI_SSH "tar xzf /tmp/tui-deploy.tar.gz -C ~/aba && rm -f /tmp/tui-deploy.tar.gz" 2>/dev/null

	rm -f "$_tar"
	echo "  Code deployed ($(git ls-files --cached --others --exclude-standard -- "${_paths[@]}" | wc -l) files)"

	# Host leftovers that poison later suites (stale op_sets, bad DC, dead NTP).
	tui_sanitize_op_sets
	tui_ensure_install_prereqs
}

# --- Conf helpers (keep callers thin; edit these when ABA conf shape changes) ---

# Set key=value in remote ~/aba/aba.conf (create the key if missing).
# Usage: tui_set_aba_conf excl_additional false
tui_set_aba_conf() {
	local key="$1" val="$2"
	$_TUI_SSH "cd ~/aba || exit 1
		if grep -q '^${key}=' aba.conf 2>/dev/null; then
			sed -i 's/^${key}=.*/${key}=${val}/' aba.conf
		else
			echo '${key}=${val}' >> aba.conf
		fi
	" 2>/dev/null
}

# Read first token of key= from remote ~/aba/aba.conf (empty if unset).
# Usage: _v=$(tui_get_aba_conf excl_additional)
tui_get_aba_conf() {
	local key="$1"
	$_TUI_SSH "grep '^${key}=' ~/aba/aba.conf 2>/dev/null | cut -d= -f2 | awk '{print \$1}'" || true
}

# Set key=value in a remote ~/aba/<file> (quoted values preserved as-is).
# Usage: tui_set_conf_file vmware.conf GOVC_DATACENTER Datacenter
tui_set_conf_file() {
	local file="$1" key="$2" val="$3"
	$_TUI_SSH "cd ~/aba || exit 1
		[ -f '$file' ] || exit 0
		if grep -q '^${key}=' '$file' 2>/dev/null; then
			sed -i \"s|^${key}=.*|${key}='${val}'\\t\\t#|\" '$file'
		else
			echo \"${key}='${val}'\" >> '$file'
		fi
	" 2>/dev/null
}

# Drop op_sets entries whose templates/operator-set-* files are missing.
# Keeps valid entries; clears the key only when nothing remains.
# Does NOT delete template files (callers that create custom sets own cleanup).
tui_sanitize_op_sets() {
	local _out
	_out=$($_TUI_SSH 'cd ~/aba || exit 0
		[ -f aba.conf ] || exit 0
		_sets=$(grep "^op_sets=" aba.conf 2>/dev/null | cut -d= -f2 | sed "s/#.*//;s/[[:space:]]//g")
		[ -n "$_sets" ] || exit 0
		_keep=""
		_bad=""
		_IFS="$IFS"; IFS=,
		for _s in $_sets; do
			[ -n "$_s" ] || continue
			if [ -f "templates/operator-set-$_s" ]; then
				[ -n "$_keep" ] && _keep="$_keep,$_s" || _keep="$_s"
			else
				_bad="$_bad $_s"
			fi
		done
		IFS="$_IFS"
		[ -z "$_bad" ] && exit 0
		sed -i "s/^op_sets=.*/op_sets=$_keep/" aba.conf
		echo "FIX:$_bad -> ${_keep:-(cleared)}"
	' 2>/dev/null) || true
	if [[ "$_out" == FIX:* ]]; then
		echo "  Sanitized stale op_sets:${_out#FIX:}"
	fi
}

# Make the test host installable: valid vSphere DC + reachable NTP.
# Safe to call on every deploy — only rewrites when current values fail checks.
tui_ensure_install_prereqs() {
	local _out
	_out=$($_TUI_SSH 'cd ~/aba || exit 0
		# --- vSphere datacenter ---
		# A bad GOVC_DATACENTER makes ALL govc ls/find calls fail, so probe with
		# GOVC_DATACENTER unset, then rewrite conf if the configured DC is wrong.
		if [ -f vmware.conf ]; then
			# shellcheck disable=SC1091
			set -a; source vmware.conf 2>/dev/null; set +a
			_dc=$(echo "$GOVC_DATACENTER" | tr -d "\"'\''")
			if [ -n "$GOVC_URL" ] && command -v govc >/dev/null 2>&1; then
				export GOVC_URL GOVC_USERNAME GOVC_PASSWORD GOVC_INSECURE
				_real=$(GOVC_DATACENTER= govc ls / 2>/dev/null | head -1 | sed "s|^/||")
				_dc_ok=
				if [ -n "$_dc" ] && [ -n "$_real" ]; then
					GOVC_DATACENTER=$_dc govc ls / >/dev/null 2>&1 && _dc_ok=1
				fi
				if [ -n "$_real" ] && [ -z "$_dc_ok" ]; then
					sed -i "s|^GOVC_DATACENTER=.*|GOVC_DATACENTER='\''$_real'\''\\t\\t#|" vmware.conf
					[ -f "$HOME/.vmware.conf" ] && \
						sed -i "s|^GOVC_DATACENTER=.*|GOVC_DATACENTER='\''$_real'\''\\t\\t#|" "$HOME/.vmware.conf"
					echo "DC:${_dc:-empty}->$_real"
				fi
			fi
		fi
		# --- NTP: prefer a chronyd-reachable server ---
		_ntp=$(grep "^ntp_servers=" aba.conf 2>/dev/null | cut -d= -f2 | sed "s/#.*//;s/[[:space:]]//g")
		_ok=
		if [ -n "$_ntp" ] && command -v chronyd >/dev/null 2>&1; then
			_IFS="$IFS"; IFS=,
			for _h in $_ntp; do
				[ -n "$_h" ] || continue
				timeout 5 chronyd -Q "server $_h iburst" >/dev/null 2>&1 && { _ok=1; break; }
			done
			IFS="$_IFS"
		fi
		if [ -z "$_ok" ]; then
			# Lab DNS (10.0.1.8) is also a working chrony source on conno
			_fallback=10.0.1.8
			if timeout 5 chronyd -Q "server $_fallback iburst" >/dev/null 2>&1 \
				|| timeout 3 bash -c "echo >/dev/udp/$_fallback/123" 2>/dev/null; then
				if grep -q "^ntp_servers=" aba.conf; then
					sed -i "s/^ntp_servers=.*/ntp_servers=$_fallback\\t\\t#/" aba.conf
				else
					echo "ntp_servers=$_fallback" >> aba.conf
				fi
				echo "NTP:${_ntp:-empty}->$_fallback"
			fi
		fi
		# --- DNS for cluster nodes (not bastion) ---
		# Bastion may auto-detect dns_servers on a secondary NIC (e.g. 192.168.2.38
		# via ens192). VMs on Lab Network (10.0.0.0/20) cannot reach that DNS —
		# agent then fails: "lookup disco.example.com on 192.168.2.38:53: i/o timeout".
		# Force lab DNS on the machine network when configured DNS is off-net.
		_lab_dns=10.0.1.8
		_dns=$(grep "^dns_servers=" aba.conf 2>/dev/null | cut -d= -f2 | sed "s/#.*//;s/[[:space:]]//g")
		_dns_ok=
		case ",$_dns," in
			*,10.0.*) _dns_ok=1 ;;
		esac
		if [ -z "$_dns_ok" ] && dig +time=1 +tries=1 +short disco.example.com "@$_lab_dns" 2>/dev/null | grep -q .
		then
			if grep -q "^dns_servers=" aba.conf; then
				sed -i "s/^dns_servers=.*/dns_servers=$_lab_dns\\t\\t#/" aba.conf
			else
				echo "dns_servers=$_lab_dns" >> aba.conf
			fi
			echo "DNS:${_dns:-empty}->$_lab_dns"
		fi
	' 2>/dev/null) || true
	if [[ -n "$_out" ]]; then
		echo "  Ensured install prereqs: $_out"
	fi
}

# Mirror is installed when mirror/.available exists on the test host.
tui_mirror_available() {
	$_TUI_SSH "test -f ~/aba/mirror/.available && echo yes || echo no" 2>/dev/null
}

# Fallback when TUI delete cannot run: aba -d <cluster> delete --yes.
# Requires the cluster directory (cluster.conf + agent-config). Never rm -rf
# that dir before delete — that orphans VMs from ABA/TUI.
# Usage: tui_aba_delete_cluster sno
tui_aba_delete_cluster() {
	local cluster="$1"
	if ! $_TUI_SSH "test -d ~/aba/$cluster" 2>/dev/null; then
		echo "  Pre-cleanup: no ~/aba/$cluster — cannot aba delete"
		return 1
	fi
	echo "  Pre-cleanup: aba -d $cluster delete --yes (fallback)"
	$_TUI_SSH "cd ~/aba && aba -d $cluster delete --yes" 2>&1 | tail -20
	return 0
}

# Wait until IP stops answering arping (VM destroy settling).
# Usage: tui_ensure_ip_free 10.0.1.201
# Returns 0 if free, 1 if still held.
tui_ensure_ip_free() {
	local ip="$1"
	local _try
	for _try in $(seq 1 30); do
		if ! $_TUI_SSH "arping -c 1 -w 2 $ip 2>&1" | grep -qi "reply"; then
			echo "  Pre-cleanup: IP $ip is free"
			return 0
		fi
		echo "  Pre-cleanup: IP $ip still in use, waiting... ($_try/30)"
		sleep 10
	done
	echo "  ERROR: IP $ip still in use after delete/wait"
	return 1
}

# Cycle Cluster Basics Type toggle until Type matches $1 (T + Select).
# Returns 0 on match, 1 otherwise. Does not touch pass/fail counters.
# Usage: tui_force_type sno|compact|standard
tui_force_type() {
	local want="${1:-sno}"
	local _scr _try
	_scr=$(tui_capture)
	echo "$_scr" | grep -qiE "Type:[[:space:]]*${want}\\b" && return 0
	for _try in 1 2 3 4 5 6; do
		tui_keys T; sleep 0.4
		tui_keys Enter; sleep 0.8
		_scr=$(tui_capture)
		if echo "$_scr" | grep -qiE "Type:[[:space:]]*${want}\\b"; then
			echo "  Type set to $want (attempt $_try)"
			return 0
		fi
	done
	return 1
}

# Convenience wrapper — prefer tui_force_type "$_lab_type".
tui_force_type_sno() {
	tui_force_type sno
}

# Start TUI, dismiss startup dialogs, detect mode, land on main menu.
# Combines: tui_start + splash dismiss + mode detection.
# On failure (e.g. "Internet Access Required" exit), stops TUI and returns 1.
# Usage: tui_start_to_menu [start_cmd] || { tui_summary; exit 1; }
tui_start_to_menu() {
	local cmd="${1:-cd ~/aba && abatui}"
	tui_start "$cmd"
	tui_dismiss_startup 60 || { tui_stop; return 1; }
	tui_detect_mode
	return 0
}

# Dismiss a cluster selection dialog if present.
# Many TUI actions prompt "Select cluster" when multiple clusters exist.
# Usage: tui_dismiss_cluster_select
tui_dismiss_cluster_select() {
	local _scr
	_scr=$(tui_capture)
	if echo "$_scr" | grep -qi "select.*cluster"; then
		tui_keys Enter
		tui_wait_gone "select.*cluster" 5
	fi
}

# Wait out "Detecting installation status…" then pick $1 from a Select-cluster
# menu when multiple leftovers exist. Prefer name match over first entry.
# Returns once the picker is gone or a post-select screen appears.
# Usage: tui_pick_cluster sno
tui_pick_cluster() {
	local cluster="${1:?}"
	local _scr _i
	for _i in $(seq 1 60); do
		_scr=$(tui_capture)
		# Splash while TUI probes leftover cluster dirs (e.g. after BM tests)
		if echo "$_scr" | grep -qi "Detecting installation status"; then
			sleep 2
			continue
		fi
		if echo "$_scr" | grep -qiE "Select cluster|select.*cluster|choose.*cluster"; then
			if echo "$_scr" | grep -qi "$cluster"; then
				tui_select_item "$cluster" 2>/dev/null || tui_keys Enter
			else
				echo "  WARNING: cluster '$cluster' not in picker — accepting default" >&2
				tui_keys Enter
			fi
			sleep 1
			tui_wait_gone "Select cluster|select.*cluster|Detecting installation status" 10 || true
			return 0
		fi
		# Already past the picker (do NOT match Day-2 "── Configuration ──" —
		# that is the menu behind the dialog and caused early return before Select).
		if echo "$_scr" | grep -qiE "Choose execution mode|Run in Terminal|Run in TUI|Executing|Progress.*step|Overall Progress|In Progress|── Success ──|── FAILED ──|Current:.*\[|Select target version|Cluster Operators|One moment please"; then
			return 0
		fi
		sleep 1
	done
	echo "  WARNING: tui_pick_cluster timed out waiting for picker/progress" >&2
	return 1
}

# Dismiss an execution mode dialog if present.
# TUI shows "Run in Terminal" / "Run in TUI" before certain commands.
# Usage: tui_dismiss_exec_mode
tui_dismiss_exec_mode() {
	local _scr
	_scr=$(tui_capture)
	if echo "$_scr" | grep -qi "Terminal\|Execution\|Run in"; then
		tui_keys Enter
		sleep 1
	fi
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
	# Safety net: ensure tmux session is killed on unexpected exit
	trap 'tui_stop 2>/dev/null' EXIT
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
		tui_keys Enter; sleep 0.5
		tui_keys Escape; sleep 0.5
		tui_keys Enter; sleep 0.5
	fi

	# Force-kill the tmux session if it didn't exit cleanly
	tui_stop
	sleep 2

	# Check for strays AFTER the session is gone
	# Exclude tmux itself (its cmdline contains "abatui" from new-session args)
	local _strays
	_strays=$($_TUI_SSH "ps -eo pid,ppid,args | grep -E '\bdialog\b|abatui' | grep -v grep | grep -v 'tmux '" 2>/dev/null || true)
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

# Delete a test cluster. ALWAYS prefer the TUI; fall back to
# `aba -d <cluster> delete --yes` only if TUI cannot complete.
#
# Important: do NOT rm -rf the cluster dir before delete — ABA/TUI need
# cluster.conf + agent-config.yaml to find and destroy VMs. Removing the
# dir first is what orphans powered-on VMs.
#
# For sno/compact (and any named test cluster): always attempt delete when
# the cluster directory exists — installed OR in-progress OR failed.
#
# Navigates: Actions → Day-2 → Delete → select → confirm → wait.
# Usage: tui_delete_cluster "sno"
tui_delete_cluster() {
	local cluster="$1"
	local _has_dir _scr _tui_ok=0

	echo "  Pre-cleanup: deleting leftover '$cluster' (TUI first)..."

	_has_dir=$($_TUI_SSH "test -d ~/aba/$cluster && echo yes || echo no")
	if [[ "$_has_dir" != "yes" ]]; then
		echo "  Pre-cleanup: no ~/aba/$cluster directory — nothing for TUI/aba to delete"
		return 0
	fi

	# --- Primary: TUI Day-2 → Delete ---
	if tui_session_alive 2>/dev/null; then
		tui_back_to "Actions" 5
		tui_select_item "Day-2"
		sleep 1
		tui_select_item "Delete"
		sleep 1
		tui_screenshot "pre-delete-start"
		_scr=$(tui_capture)

		if echo "$_scr" | grep -qi "No clusters\|no cluster"; then
			echo "  Pre-cleanup: TUI reports no clusters — will try aba delete"
			tui_keys Enter 2>/dev/null || true
			tui_back_to "Actions" 5
		else
			# Cluster selection menu (multiple) or straight confirm (single)
			if echo "$_scr" | grep -qi "select.*cluster\|choose.*cluster\|Select cluster"; then
				# Prefer the matching cluster name if listed; else first entry
				if echo "$_scr" | grep -qi "$cluster"; then
					tui_select_item "$cluster" 2>/dev/null || tui_keys Enter
				else
					tui_keys Enter
				fi
				sleep 2
				_scr=$(tui_capture)
			fi

			# Confirm: --defaultno, yes-label is "Delete"
			if echo "$_scr" | grep -qi "Delete cluster\|destroy\|sure\|remove\|Are you sure\|cannot be undone"; then
				tui_confirm_yes
				sleep 1
			fi

			_scr=$(tui_capture)
			if echo "$_scr" | grep -qi "Choose execution mode\|Run in Terminal\|Run in TUI"; then
				tui_keys Enter
				sleep 1
			fi

			if tui_wait_for_progress "pre-delete" 300; then
				echo "  Pre-cleanup: '$cluster' delete completed via TUI"
				_tui_ok=1
			else
				echo "  Pre-cleanup: TUI delete did not complete cleanly"
			fi
			tui_dismiss_result 2>/dev/null || true
			tui_back_to "Actions" 5
		fi
	else
		echo "  Pre-cleanup: TUI session not alive — skipping TUI delete"
	fi

	# --- Fallback: aba delete (keeps cluster dir; destroys VMs) ---
	if [[ "$_tui_ok" -ne 1 ]]; then
		tui_aba_delete_cluster "$cluster" || true
	fi

	return 0
}

# --- ISC (ImageSetConfiguration) verification helpers ---

# Read the ISC YAML from the remote host.  Caller captures output.
tui_read_isc() {
	$_TUI_SSH "cat ~/aba/mirror/data/imageset-config.yaml 2>/dev/null"
}

# Wait for background ISC regeneration to finish, then force-regenerate.
# Waits for any running isconf process to complete, then forces a
# synchronous regeneration to ensure the ISC reflects current config.
#   tui_wait_isc_file [timeout_seconds]
tui_wait_isc_file() {
	local _timeout="${1:-30}" _i

	# Wait for any currently running ISC generation to finish
	for _i in $(seq 1 "$_timeout"); do
		if ! $_TUI_SSH "pgrep -f 'isconf\|imageset-config' >/dev/null 2>&1"; then
			break
		fi
		sleep 1
	done

	# Force synchronous ISC regeneration: touch .created to be newer than
	# the ISC file so make considers it stale, then regenerate
	$_TUI_SSH "cd ~/aba && source scripts/include_all.sh 2>/dev/null && \
		run_once -r -i 'aba:isconf:generate' 2>/dev/null; \
		touch mirror/data/.created; \
		make -sC mirror isconf 2>/dev/null" >/dev/null 2>&1 || true
}

# Assert that the ISC contains a pattern (grep -qiE).
# Waits for ISC regeneration to finish first.
#   tui_assert_isc_contains  <pattern>  <label>
tui_assert_isc_contains() {
	local _pat="$1" _label="$2"
	local _isc
	tui_wait_isc_file 30
	_isc=$(tui_read_isc)
	if echo "$_isc" | grep -qiE "$_pat"; then
		echo "  ✓ PASS: ISC contains $_label"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ✗ FAIL: ISC missing $_label (pattern: $_pat)"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	fi
}

# Assert that the ISC does NOT contain a pattern.
# Waits for ISC regeneration to finish first.
#   tui_assert_isc_not_contains  <pattern>  <label>
tui_assert_isc_not_contains() {
	local _pat="$1" _label="$2"
	local _isc
	tui_wait_isc_file 30
	_isc=$(tui_read_isc)
	if echo "$_isc" | grep -qiE "$_pat"; then
		echo "  ✗ FAIL: ISC still contains $_label (should have been removed)"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	else
		echo "  ✓ PASS: ISC no longer contains $_label"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	fi
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

# Wait for a TUI progress/execution dialog to finish, with automatic retry.
#
# Every long-running TUI operation (sync, install, load, save, …) follows
# the same lifecycle:
#   1. Progress dialog runs until completion or error
#   2. On success  → "All steps completed" / "Done" / back to Actions menu
#   3. On error    → "FAILED" / "Error" dialog with <Dismiss> <Retry> <View Output>
#
# This function handles that lifecycle once, so callers don't duplicate it.
#
# Usage:
#   tui_wait_for_progress <label> [timeout_sec] [screenshot_interval_sec]
#
#   label          - Short name for screenshots (e.g. "sync", "install")
#   timeout_sec    - Max wait time (default 3600 = 60 min)
#   ss_interval    - Seconds between periodic screenshots (default 300 = 5 min)
#
# Returns:
#   0 = success (completed / back at menu)
#   1 = failed (error detected, no Retry available or retries exhausted)
#   2 = session died
#   3 = timeout
#
# The function uses the TUI's built-in Retry button when available.
# After exhausting inner retries it returns 1 so the caller can decide
# whether to do a full outer retry (dismiss + re-navigate + call again).
#
# Press "View Output" on a progress/error dialog and screenshot the output.
# If the button isn't present, this is a no-op.
_tui_capture_output() {
	local label="${1:-output}"
	local _scr
	_scr=$(tui_capture)
	if echo "$_scr" | grep -qi "View Output\|Output"; then
		tui_press_button "View Output" 2>/dev/null || tui_press_button "Output" 2>/dev/null || return 0
		sleep 2
		tui_screenshot "${label}-output"
		# Return from output view (Q to quit less/viewer, or Escape)
		tui_keys q 2>/dev/null; sleep 1
		tui_keys Escape 2>/dev/null; sleep 1
	fi
}

tui_wait_for_progress() {
	local label="${1:-progress}"
	local timeout="${2:-600}"
	local ss_interval="${3:-120}"
	local _start _elapsed _last_ss _scr _inner_retries=0 _max_inner=3
	local _saw_progress=0
	local _ever_in_progress=0
	local _saw_error=0
	local _menu_pat="── Mirror ──\|── Registry ──\|── Cluster ──\|── Advanced ──\|── Configuration ──\|── Lifecycle ──\|── Cleanup ──\|── Transfer ──\|── Status ──"

	_start=$(date +%s)
	_last_ss=0

	while true; do
		_elapsed=$(( $(date +%s) - _start ))
		if [[ $_elapsed -ge $timeout ]]; then
			echo "  TIMEOUT waiting for '$label' (${timeout}s)"
			tui_screenshot "${label}-timeout"
			return 3
		fi

		if ! tui_session_alive; then
			echo "  SESSION DEAD during '$label'"
			return 2
		fi

		_scr=$(tui_capture)

		# Bail immediately if we accidentally exited the TUI
		if echo "$_scr" | grep -qi "Exit ABA TUI\|Confirm Exit"; then
			echo "  WARNING: '$label' — accidental exit dialog detected, pressing Continue"
			tui_press_button "Continue" 2>/dev/null || tui_keys Right Enter 2>/dev/null
			sleep 1
			continue
		fi

		# Periodic screenshots
		if (( _elapsed - _last_ss >= ss_interval )); then
			tui_screenshot "${label}-progress-${_elapsed}s"
			_last_ss=$_elapsed
		fi

		# Detecting / Select-cluster are NOT progress. Auto-clear them or we
		# sit for the full timeout (seen in upgrade day-2 OperatorHub).
		if echo "$_scr" | grep -qi "Detecting installation status"; then
			echo "  ... '$label' waiting out installation-status detect (${_elapsed}s)"
			sleep 2
			continue
		fi
		if echo "$_scr" | grep -qiE "Select cluster|select.*cluster|choose.*cluster"; then
			# Prefer the test cluster when known; bare Enter picks the first radiolist row.
			echo "  Dismissing cluster select during '$label' (${_elapsed}s)"
			if [[ -n "${TUI_CLUSTER_NAME:-${_CLUSTER:-}}" ]]; then
				tui_pick_cluster "${TUI_CLUSTER_NAME:-$_CLUSTER}" || tui_keys Enter
			else
				tui_keys Enter
			fi
			sleep 1
			tui_wait_gone "Select cluster|select.*cluster" 8 || true
			# Do not mark _saw_progress — wait for a real execution dialog.
			continue
		fi

		# Version picker / fetching splash are NOT progress (upgrade hang:
		# wait treated "Upgrade Cluster" menu as in-progress for 90 min).
		if echo "$_scr" | grep -qi "Fetching available upgrade versions\|Select target version"; then
			if [[ $_saw_progress -eq 1 ]]; then
				echo "  WARNING: '$label' — still on version picker (${_elapsed}s); not real progress"
				_saw_progress=0
			fi
			if (( _elapsed >= 45 )); then
				echo "  ERROR: '$label' stuck on version picker after ${_elapsed}s"
				tui_screenshot "${label}-stuck-version-picker"
				return 3
			fi
			sleep 2
			continue
		fi

		# Phase 1: wait for the screen to leave the menu (progress/dialog appears)
		# Use specific execution keywords — avoid generic words like "Upgrade"
		# that appear in menus and buttons.
		if [[ $_saw_progress -eq 0 ]]; then
			if echo "$_scr" | grep -qi "Executing\|Progress.*step\|Running.*step\|Syncing.*mirror\|Installing\|Graceful.*shut\|Shutdown.*progress\|Startup.*progress\|All steps completed\|steps completed successfully\|Press.*ENTER.*return\|ENTER to return\|── Success ──\|── FAILED ──\|In Progress\|Overall Progress"; then
				_saw_progress=1
			elif ! echo "$_scr" | grep -q "$_menu_pat"; then
				_saw_progress=1
			else
				# Still on menu — do NOT soft-PASS. Wait until timeout.
				if (( _elapsed >= 10 )); then
					echo "  WARNING: '$label' — still on menu after ${_elapsed}s"
					tui_screenshot "${label}-still-on-menu"
				fi
				sleep 2
				continue
			fi
		fi

		# Error/failure dialog first — titles like "…: Error ───" must not be
		# mistaken for success (and must win over later menu/success checks).
		if echo "$_scr" | grep -qiE '(:[[:space:]]*Error[[:space:]])|Error.*─|─.*Error|─.*FAILED|FAILED.*─|A step failed'; then
			_saw_error=1
			echo "  Error detected during '$label' (${_elapsed}s)"
			tui_screenshot "${label}-error"

			# Retry only when the Retry button is actually pressable.
			if echo "$_scr" | grep -qi "Retry" && [[ $_inner_retries -lt $_max_inner ]]; then
				_inner_retries=$(( _inner_retries + 1 ))
				echo "  Pressing TUI Retry button ($_inner_retries/$_max_inner)..."
				if tui_press_button "Retry"; then
					sleep 3
					continue
				fi
				echo "  Retry button not pressable — treating as failure"
			fi
			_tui_capture_output "$label"
			return 1
		fi

		# Success: completed dialog (progress or confirm_and_execute)
		if echo "$_scr" | grep -qi "All steps completed\|steps completed successfully\|─── Success ───\|── Success ──\|installed successfully"; then
			echo "  Progress '$label' completed successfully (${_elapsed}s)"
			_tui_capture_output "$label"
			# Dismiss OK/success dialog — but NOT post-install yesno dialogs
			# ("Configure OperatorHub" has Yes/No, not OK)
			if echo "$_scr" | grep -qi "── Success ──" && ! echo "$_scr" | grep -qi "Yes.*No\|apply now\|later"; then
				tui_keys Enter; sleep 1
			fi
			return 0
		fi

		# Track real execution so we never q-quit on the first paint.
		if echo "$_scr" | grep -qi "In Progress"; then
			_ever_in_progress=1
		fi

		# Completed with errors: progress dialog done, "Quit" button visible.
		# Do not quit while a step is In Progress, or while a later step is
		# still N/A. Review can already say No-op in the gap after the ISO
		# step finishes and before stage/boot leave N/A. q in that gap aborts
		# the install. A Failed step leaves the rest N/A on purpose, so that
		# case still quits.
		#
		# Also: never q in the first ~25s. day2 OperatorHub was aborted at
		# ~14s (Stopped) when an early frame matched No-op/Succeeded.
		if echo "$_scr" | grep -qi "Quit.*Q\|Q.*ESC"; then
			if echo "$_scr" | grep -qi "Failed\|No-op\|Done\|Skipped\|Succeeded"; then
				if echo "$_scr" | grep -qi "In Progress"; then
					sleep 5
					continue
				fi
				if echo "$_scr" | grep -q "N/A" && ! echo "$_scr" | grep -qi "Failed"; then
					sleep 5
					continue
				fi
				if (( _elapsed < 25 )); then
					echo "  ... '$label' Quit visible too early (${_elapsed}s, in_progress=${_ever_in_progress:-0}) — waiting"
					sleep 3
					continue
				fi
				local _has_fail=0
				echo "$_scr" | grep -qi "Failed" && _has_fail=1
				tui_keys q; sleep 1
				if [[ $_has_fail -eq 1 ]]; then
					echo "  Progress '$label' completed with step failures (${_elapsed}s)"
					tui_screenshot "${label}-completed-with-errors"
					return 1
				else
					echo "  Progress '$label' completed (${_elapsed}s)"
					return 0
				fi
			fi
		fi

		# Back at menu after starting progress is NOT success (soft-PASS removed).
		# Error dialogs often dismiss to the menu; that must remain a failure.
		if echo "$_scr" | grep -q "$_menu_pat"; then
			if [[ $_saw_error -eq 1 ]]; then
				echo "  Progress '$label' returned to menu after error (${_elapsed}s)"
				tui_screenshot "${label}-menu-after-error"
				return 1
			fi
			if [[ $_saw_progress -eq 1 ]] && (( _elapsed >= 10 )); then
				echo "  Progress '$label' returned to menu without verified success (${_elapsed}s)"
				tui_screenshot "${label}-menu-without-success"
				return 1
			fi
			# Brief menu flash before progress starts
			sleep 2
			continue
		fi

		# Explicit stop (user quit / harness interrupted) — exit promptly so
		# callers can fall back to marker checks instead of waiting full timeout.
		if echo "$_scr" | grep -qi "Stopped before all steps\|──.*Stopped.*──\|Install.*Stopped\|Sync.*Stopped"; then
			echo "  Progress '$label' stopped before completion (${_elapsed}s)"
			tui_screenshot "${label}-stopped"
			_tui_capture_output "$label"
			return 1
		fi

		# Execution mode dialog (appears after Retry or re-run)
		if echo "$_scr" | grep -qi "Choose execution mode\|Run in Terminal\|Run in TUI"; then
			echo "  Dismissing execution mode dialog during '$label'"
			tui_keys Enter
			sleep 2
			continue
		fi

		# Warning/confirmation dialogs (e.g. OSUS Warning, Continue anyway?)
		if echo "$_scr" | grep -qi "Continue anyway\|Warning.*Continue\|Continue.*Cancel"; then
			echo "  Dismissing warning dialog during '$label'"
			tui_keys Enter
			sleep 2
			continue
		fi

		# "Press ENTER to return" terminal prompt
		if echo "$_scr" | grep -qi "Press.*ENTER\|ENTER to return"; then
			tui_keys Enter
			sleep 1
			continue
		fi

		# Log progress every 30s so user sees activity
		(( _elapsed % 30 == 0 && _elapsed > 0 )) && echo "  ... '$label' running (${_elapsed}s)"

		sleep 2
	done
}

# Run a TUI operation with full outer retry: dismiss errors, re-navigate, retry.
#
# This is the top-level helper that tests should call for any long-running
# TUI action.  It wraps tui_wait_for_progress with an outer retry loop
# that handles session recovery and re-navigation.
#
# Usage:
#   tui_run_operation <label> <nav_func> [max_retries] [timeout_sec]
#
#   label        - Short name for log/screenshots (e.g. "sync", "reg-install")
#   nav_func     - Shell function/commands to navigate to and start the operation.
#                  Called once per attempt.  Should leave TUI in the progress dialog.
#   max_retries  - Outer retry limit (default 3)
#   timeout_sec  - Per-attempt timeout (default 3600)
#
# Returns 0 on success, 1 on failure after all retries exhausted.
#
tui_run_operation() {
	local label="$1"
	local nav_func="$2"
	local max_retries="${3:-2}"
	local timeout="${4:-600}"
	local _attempt=0 _rc

	while [[ $_attempt -lt $max_retries ]]; do
		_attempt=$(( _attempt + 1 ))
		[[ $_attempt -gt 1 ]] && echo "  Outer retry $_attempt/$max_retries for '$label'..."

		if ! tui_session_alive; then
			echo "  Session dead — restarting TUI for '$label' retry..."
			tui_stop 2>/dev/null; sleep 1
			tui_start_to_menu || { echo "  Failed to restart TUI"; continue; }
		fi

		eval "$nav_func"

		tui_wait_for_progress "$label" "$timeout"
		_rc=$?

		case $_rc in
			0) return 0 ;;
			2) echo "  Session died during '$label' — will retry"; sleep 1; continue ;;
			3) echo "  '$label' timed out — not retrying"; tui_dismiss_error; return 1 ;;
			1) echo "  '$label' failed (attempt $_attempt) — dismissing error"
			   tui_dismiss_error; sleep 1; continue ;;
		esac
	done

	echo "  '$label' failed after $max_retries attempts"
	return 1
}
