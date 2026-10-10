#!/bin/bash
# tui-progress.sh — TUI progress dialog engine
#
# Provides _exec_with_progress() for running ABA commands with a
# dialog --mixedgauge progress display driven by FIFO events.
#
# Architecture:
#   Caller (tui-mirror.sh etc.)
#     → _exec_with_progress "aba -d mirror save" "Mirror Save"
#       → creates FIFO + input FIFO
#       → launches command in a real PTY (pty-run.py)
#       → main loop: drain FIFO → draw progress → auto-complete → handle prompts
#       → shows outcome dialog (success/error/abort)
#       → cleans up
#
# The command's scripts call aba_progress() (defined in include_all.sh)
# which writes structured events to the FIFO.  When ABA_PROGRESS_FIFO
# is unset (CLI mode), aba_progress() is a no-op — zero overhead.
#
# Sourced by abatui2.sh alongside tui-lib.sh.

# Guard against double-sourcing
[[ -n "${_TUI_PROGRESS_LOADED:-}" ]] && return 0
_TUI_PROGRESS_LOADED=1

# ============================================================
# Internal state — reset per workflow run
# ============================================================

declare -A _tp_status _tp_text _tp_real_done _tp_weight
declare -a _tp_order _tp_errors _tp_details _tp_nexts _tp_failed
_tp_prompt_msg=""
_tp_abort=""
_tp_aba_exited=0
_tp_exit_code=0
_tp_done=0
_tp_script_pid=""
_tp_tail_pid=""

# FIFOs and paths — set by _tp_init, cleaned by _tp_cleanup
_tp_tmpdir=""
_tp_progress_fifo=""
_tp_input_fifo=""
_tp_output_log=""

# ============================================================
# Init / Cleanup
# ============================================================

_tp_init() {
	# Clean up stale temp dirs from previous crashed/interrupted runs
	local _stale
	for _stale in /tmp/aba-tui-progress.*/; do
		[ -d "$_stale" ] && rm -rf "$_stale" 2>/dev/null || true
	done

	_tp_tmpdir=$(mktemp -d /tmp/aba-tui-progress.XXXXXX)
	_tp_progress_fifo="$_tp_tmpdir/progress"
	_tp_input_fifo="$_tp_tmpdir/input"
	_tp_output_log="$_tp_tmpdir/output.log"

	mkfifo "$_tp_progress_fifo"
	mkfifo "$_tp_input_fifo"
	: > "$_tp_output_log"

	# Auto-allocate FDs to avoid collision with TUI (FD 5/6) and run_once (FD 9).
	# Read-write open prevents blocking on FIFO.
	exec {_tp_input_fd}<>"$_tp_input_fifo"
	exec {_tp_progress_fd}<>"$_tp_progress_fifo"
}

_tp_cleanup() {
	[ -n "${_tp_tail_pid:-}" ] && kill "$_tp_tail_pid" 2>/dev/null || true
	[ -n "${_tp_script_pid:-}" ] && kill "$_tp_script_pid" 2>/dev/null || true
	# Guard: only close FDs if the variable holds a valid number
	[[ "${_tp_progress_fd:-}" =~ ^[0-9]+$ ]] && exec {_tp_progress_fd}>&- 2>/dev/null || true
	[[ "${_tp_input_fd:-}" =~ ^[0-9]+$ ]] && exec {_tp_input_fd}>&- 2>/dev/null || true
	[ -n "${_tp_script_pid:-}" ] && wait "$_tp_script_pid" 2>/dev/null || true
	_tp_tail_pid=""
	_tp_script_pid=""
	rm -rf "${_tp_tmpdir:?}" 2>/dev/null || true
	rm -rf "$(dirname "${BASH_SOURCE[0]}")/__pycache__" 2>/dev/null || true
	_tp_tmpdir=""
}

_tp_reset_state() {
	_tp_status=()
	_tp_text=()
	_tp_real_done=()
	_tp_weight=()
	_tp_order=()
	_tp_errors=()
	_tp_details=()
	_tp_nexts=()
	_tp_failed=()
	_tp_prompt_msg=""
	_tp_abort=""
	_tp_aba_exited=0
	_tp_exit_code=0
	_tp_done=0
	# Drain any leftover FIFO data
	local _line
	while read -t 0.05 -r -u "$_tp_progress_fd" _line 2>/dev/null; do :; done
}

# ============================================================
# Event parsing — FIFO lines into bash arrays
# ============================================================

_tp_parse_event() {
	local _line="$1" event _tail id arg1
	[ -z "$_line" ] && return
	event=${_line%%|*}
	_tail=${_line#*|}
	id="" arg1=""
	if [ "$_tail" != "$_line" ]; then
		id=${_tail%%|*}
		[ "$id" != "$_tail" ] && arg1=${_tail#*|}
	fi
	case "$event" in
		PLAN)
			# Dedup: _tp_text[] is the "already planned" flag.
			# A PLAN can arrive AFTER START/DONE for the same ID (late PLAN).
			# This happens when Make runs a script before its plan target fires.
			# In that case, _tp_status[] is already set but _tp_text[] is empty.
			# We add to _tp_order and set _tp_text, but keep the existing status.
			if [ -z "${_tp_text[$id]:-}" ]; then
				# arg1 is "text" or "text|weight" — split on last |
				local _plan_text="${arg1%|*}" _plan_weight="${arg1##*|}"
				# If no weight field, text==weight (no | separator)
				if [ "$_plan_text" = "$_plan_weight" ]; then
					_plan_weight=1
				fi
				_tp_order+=("$id")
				_tp_text[$id]="$_plan_text"
				_tp_weight[$id]="$_plan_weight"
				# Only set initial N/A status if no START/DONE has arrived yet.
				# Use if/then — NOT "[ ] && cmd" which returns 1 under set -e.
				if [ -z "${_tp_status[$id]:-}" ]; then
					_tp_status[$id]="9"
				fi
			fi
			;;
		START)       [ "${_tp_status[$id]:-9}" != "0" ] && _tp_status[$id]="77"; _tp_real_done[$id]="started" ;;
		DONE)        _tp_status[$id]="0"; _tp_real_done[$id]="done" ;;
		FAIL)        _tp_status[$id]="1"; _tp_real_done[$id]="fail"; _tp_failed+=("${_tp_text[$id]:-$id}") ;;
		ERROR)       _tp_errors+=("${arg1:-$id}") ;;
		DETAIL)      _tp_details+=("${arg1:-$id}") ;;
		NEXT)        _tp_nexts+=("${arg1:-$id}") ;;
		ABORT)       _tp_abort="${arg1:-$id}" ;;
		PROMPT)      _tp_prompt_msg="${id}${arg1:+|$arg1}" ;;
		PROMPT_DONE) _tp_prompt_msg="" ;;
	esac
}

# Non-blocking drain: read all pending FIFO events
_tp_drain_events() {
	local _line
	while read -t 0.01 -r -u "$_tp_progress_fd" _line 2>/dev/null; do
		_tp_parse_event "$_line"
	done
	if [ "$_tp_aba_exited" -eq 0 ] && ! kill -0 "$_tp_script_pid" 2>/dev/null; then
		_tp_aba_exited=1
		while read -t 0.2 -r -u "$_tp_progress_fd" _line 2>/dev/null; do
			_tp_parse_event "$_line"
		done
		# Capture exit code — non-zero means the command crashed
		_tp_exit_code=0
		wait "$_tp_script_pid" 2>/dev/null || _tp_exit_code=$?
		_tp_done=1
	fi
}

# ============================================================
# Progress display
# ============================================================

# Use TUI's dlg() when available (handles flags, flock FD, terminal state).
# Falls back to raw dialog for standalone test scripts.
_tp_dlg() {
	if type dlg &>/dev/null; then
		dlg "$@"
	else
		dialog "$@"
	fi
}

_tp_draw() {
	local _title="$1"
	local _subtitle_override="${2:-}"
	local args=() total=0 done_weight=0 total_weight=0 id text status
	local _idx=0

	# Find the last step with a non-N/A status (the "frontier").
	# Everything after the frontier is masked as N/A.
	# This handles background tasks: a bg step (In Progress near the top)
	# alongside sequential work (In Progress further down) is fine —
	# only steps beyond the last real activity get masked.
	local _last_real_idx=-1 _scan=0
	for id in "${_tp_order[@]}"; do
		status="${_tp_status[$id]:-9}"
		if [ "$status" != "9" ]; then
			_last_real_idx=$_scan
		fi
		_scan=$((_scan + 1))
	done

	for id in "${_tp_order[@]}"; do
		text="${_tp_text[$id]:-$id}"
		status="${_tp_status[$id]:-9}"
		# 77 = "just received START" — display as 7 (In Progress)
		[ "$status" = "77" ] && status="7"
		# Mask steps beyond the frontier as N/A
		if [ "$_idx" -gt "$_last_real_idx" ]; then
			status="9"
		fi
		# Custom label: "No-op" instead of dialog's built-in "Skipped"
		[ "$status" = "6" ] && status="No-op"
		args+=("$text" "$status")
		total=$((total + 1))
		# Accumulate weighted progress for completed steps
		local _w="${_tp_weight[$id]:-1}"
		case "$status" in 0|3|5|6|No-op) done_weight=$((done_weight + _w)) ;; esac
		total_weight=$((total_weight + _w))
		_idx=$((_idx + 1))
	done

	[ "$total" -eq 0 ] && return

	local pct=0
	[ "$total_weight" -gt 0 ] && pct=$((done_weight * 100 / total_weight))

	local _subtitle="\n       < Output (Space) >        < Quit (Q) >\n"
	if [ -n "$_subtitle_override" ]; then
		_subtitle="$_subtitle_override"
	elif [ -n "$_tp_prompt_msg" ]; then
		_subtitle="\n     ⚠  ABA needs input — press < Output (Space) >\n"
	fi

	# Dynamic height: 10 rows for chrome (title, subtitle, progress bar) + 1 per step, min 18
	local _height=$(( ${#_tp_order[@]} + 10 ))
	[ "$_height" -lt 18 ] && _height=18

	_tp_dlg --title " $_title " \
		--mixedgauge "$_subtitle" \
		$_height 56 "$pct" \
		"${args[@]}" < /dev/null 2>/dev/null || true
}

# ============================================================
# Auto-complete — one predecessor per call
# ============================================================
#
# When a step gets START (status 77), all pending predecessors (status 9)
# above it in _tp_order must have already been processed.
# This function marks ONE such predecessor per call, using _tp_real_done[]
# to decide the label:
#
#   _tp_real_done[id] is set  → step got real START/DONE → "Succeeded" (0)
#   _tp_real_done[id] is empty → step never ran           → "Skipped"   (6)

_tp_auto_complete_one() {
	local _first_pending="" id ps
	for id in "${_tp_order[@]}"; do
		ps="${_tp_status[$id]:-9}"
		case "$ps" in
			9)
				[ -z "$_first_pending" ] && _first_pending="$id"
				;;
			77)
				if [ -n "$_first_pending" ]; then
					if [ -n "${_tp_real_done[$_first_pending]:-}" ]; then
						_tp_status[$_first_pending]="0"
					else
						_tp_status[$_first_pending]="6"
					fi
					return 0
				fi
				_tp_status[$id]="7"
				return 0
				;;
			7|0|1|6)
				if [ -n "$_first_pending" ]; then
					if [ -n "${_tp_real_done[$_first_pending]:-}" ]; then
						_tp_status[$_first_pending]="0"
					else
						_tp_status[$_first_pending]="6"
					fi
					return 0
				fi
				;;
		esac
	done
	return 1
}

# ============================================================
# Skipped sweep — final pass after command exits
# ============================================================
#
# After the command finishes, any step that:
#   - has status 0 (auto-completed as Succeeded) or 9 (still N/A)
#   - has NO entry in _tp_real_done[] (never got a real FIFO event)
# is changed to status 6 (Skipped).

_tp_sweep_skipped() {
	local id ps _any=0
	for id in "${_tp_order[@]}"; do
		ps="${_tp_status[$id]:-9}"
		if [ -z "${_tp_real_done[$id]:-}" ]; then
			if [ "$ps" = "9" ] || [ "$ps" = "0" ]; then
				_tp_status[$id]="6"
				_any=1
			fi
		fi
	done
	return $(( 1 - _any ))
}

# ============================================================
# Prompt handling
# ============================================================

_tp_handle_prompt() {
	local _raw="$1" rc=0
	# Extract default from "question|y" or "question|n" format
	local _prompt="${_raw%|*}"
	local _default="${_raw##*|}"
	# If no separator, prompt is the full string
	[ "$_prompt" = "$_raw" ] && _prompt="$_raw" && _default=""

	local _default_flag=""
	[ "$_default" = "n" ] && _default_flag="--defaultno"

	_tp_dlg --title " ABA " --yes-label "Yes" --no-label "No" $_default_flag \
		--yesno "\n$_prompt" 0 0 || rc=$?
	case "$rc" in
		0) printf 'y\r' > "$_tp_input_fifo" ;;
		1) printf 'n\r' > "$_tp_input_fifo" ;;
		*) return 1 ;;
	esac
}

# ============================================================
# Output view
# ============================================================

_tp_show_output() {
	clear
	printf '\033[1;33m'
	echo "═══════════════════════════════════════════════════════"
	echo "  ABA Live Output         (press any key to return)"
	echo "═══════════════════════════════════════════════════════"
	printf '\033[0m\n'
	cat "$_tp_output_log" 2>/dev/null
	tail -n 0 -f "$_tp_output_log" 2>/dev/null &
	_tp_tail_pid=$!
	read -rsn1 || true
	kill "$_tp_tail_pid" 2>/dev/null || true
	wait "$_tp_tail_pid" 2>/dev/null || true
	_tp_tail_pid=""
}

# ============================================================
# Outcome determination and display
# ============================================================

_tp_finish_outcome() {
	local id status outcome=success
	[ -n "$_tp_abort" ] && outcome=abort
	for id in "${_tp_order[@]}"; do
		status="${_tp_status[$id]:-9}"
		case "$status" in
			1) outcome=error ;;
			7|9|77)
				[ "$outcome" = success ] && outcome=stopped
				;;
		esac
	done
	[ "${#_tp_errors[@]}" -gt 0 ] && outcome=error
	printf '%s' "$outcome"
}

_tp_show_error() {
	local _title="${1:-Error}"
	local _msg="\n" line id
	local _btn_rc

	# Show which step(s) failed
	for line in "${_tp_failed[@]}"; do
		_msg="${_msg}  Failed: ${line}\n"
	done

	# Show only the first ERROR (the most specific/tailored one).
	# aba_abort auto-emits ERROR, so duplicates are expected — first wins.
	[ "${#_tp_errors[@]}" -eq 0 ] && _msg="${_msg}\n  A step failed.\n"
	[ "${#_tp_errors[@]}" -gt 0 ] && _msg="${_msg}\n  ERROR: ${_tp_errors[0]}\n"
	if [ "${#_tp_details[@]}" -gt 0 ]; then
		_msg="${_msg}\n"
		for line in "${_tp_details[@]}"; do
			_msg="${_msg}  ${line}\n"
		done
	fi
	if [ "${#_tp_nexts[@]}" -gt 0 ]; then
		_msg="${_msg}\n  Possible next steps:\n"
		for line in "${_tp_nexts[@]}"; do
			_msg="${_msg}    • ${line}\n"
		done
	fi
	_msg="${_msg}\n  Press 'View Output' for full output.\n"
	while true; do
		_btn_rc=0
		_tp_dlg --title " ${_title}: Error " \
			--ok-label "View Output" \
			--extra-button --extra-label "Retry" \
			--cancel-label "OK" \
			--yesno "$_msg" \
			0 0 || _btn_rc=$?
		case "$_btn_rc" in
			0) _tp_show_output ;;
			3) _TP_RETRY=1; return ;;
			*) return ;;
		esac
	done
}

_tp_show_abort() {
	local _title="${1:-ABA}"
	local _why="${_tp_abort:-Aborted.}"
	_tp_dlg --title " ${_title}: Aborted " --msgbox "\n  $_why\n" 8 60 || true
}

_tp_show_stopped() {
	local _title="${1:-ABA}"
	_tp_dlg --title " ${_title}: Stopped " \
		--msgbox "\n  Stopped before all steps finished.\n" 8 56 || true
}

_tp_show_success() {
	local _title="${1:-ABA}"
	local _body id text status _label _color _pad
	local _max_len=34

	# Build colored status text from the step arrays
	_body="\n"
	for id in "${_tp_order[@]}"; do
		text="${_tp_text[$id]:-$id}"
		status="${_tp_status[$id]:-9}"
		case "$status" in
			0)  _label=" Succeeded "; _color="\\Z2" ;;
			1)  _label="  Failed   "; _color="\\Z1" ;;
			6)  _label="   No-op   "; _color="\\Z2" ;;
			7)  _label="In Progress"; _color="\\Z5" ;;
			9)  _label="    N/A    "; _color="" ;;
			*)  _label="$status"; _color="" ;;
		esac
		_pad=$(( _max_len - ${#text} ))
		[ "$_pad" -lt 1 ] && _pad=1
		if [ -n "$_color" ]; then
			_body="${_body}  ${text}$(printf '%*s' "$_pad" '')${_color}[${_label}]\\Zn\n"
		else
			_body="${_body}  ${text}$(printf '%*s' "$_pad" '')[${_label}]\n"
		fi
	done
	_body="${_body}\n  \\Z2✓  All steps completed successfully.\\Zn\n "

	local _height=$(( ${#_tp_order[@]} + 8 ))
	[ "$_height" -lt 14 ] && _height=14

	local _default_btn=""
	while true; do
		local _rc=0
		_tp_dlg --colors $_default_btn \
			--title " $_title " \
			--yes-label "Done" --no-label "Output" \
			--yesno "$_body" \
			"$_height" 56 || _rc=$?
		case "$_rc" in
			0|255) break ;;
			1) _default_btn="--defaultno"; _tp_show_output ;;
		esac
	done
}

# ============================================================
# Main entry point — run a command with progress dialog
# ============================================================
#
# Usage:
#   _exec_with_progress "aba -d mirror save" "Mirror Save" [post_hook]
#
# The command inherits ABA_PROGRESS_FIFO in its environment.
# Scripts call aba_progress() to emit events.
# Returns 0 on success, 1 on error/abort/stopped.

_exec_with_progress() {
	local cmd="$1"
	local title="${2:-ABA}"
	local post_cmd_hook="${3:-}"
	local _rc=0
	local _tp_interrupted=0
	local _TP_RETRY=0

	# Restore terminal for progress display (TUI redirects stdout/stderr to log).
	# Clear _TUI_REDIRECT_ACTIVE so dlg() uses its simple path (no per-call
	# restore/activate cycling during the tight draw loop).
	local _tp_saved_redirect="${_TUI_REDIRECT_ACTIVE:-}"
	_tui_redirect_restore 2>/dev/null || true
	_TUI_REDIRECT_ACTIVE=""

	# Override INT handler: flag interrupt so main loop exits cleanly
	# (the previous handler may be 'exit 0' from _exec_in_terminal, which
	# would skip cleanup entirely)
	trap '_tp_interrupted=1' INT

	while true; do
	_TP_RETRY=0
	_tp_interrupted=0
	_tp_init
	_tp_reset_state

	export ABA_PROGRESS_FIFO="$_tp_progress_fifo"

	local _pty_run
	_pty_run="$(dirname "${BASH_SOURCE[0]}")/pty-run.py"

	# Write the command being executed to the output log header
	printf 'Executing: %s\n\n' "$cmd" > "$_tp_output_log"

	# Launch command in a real PTY
	# Close flock FD so child processes don't hold the TUI lock
	# Unset KUBECONFIG so child resolves from cluster dir
	if [[ -n "${ABA_TUI_FLOCK_FD:-}" ]]; then
		eval 'KUBECONFIG= python3 "$_pty_run" --input-fifo "$_tp_input_fifo" "$_tp_output_log" \
			bash -c "$cmd" '"${ABA_TUI_FLOCK_FD}"'>&- &'
	else
		KUBECONFIG= python3 "$_pty_run" --input-fifo "$_tp_input_fifo" "$_tp_output_log" \
			bash -c "$cmd" &
	fi
	_tp_script_pid=$!

	# Show immediate feedback while waiting for the command to emit PLAN events
	_tp_dlg --title " $title " --infobox "\n  One moment please ..." 5 30 2>/dev/null || true

	# Wait for PLAN events before first draw (10s timeout — aba.sh startup takes ~4s)
	local _wait=100
	while [ "${#_tp_order[@]}" -eq 0 ] && [ "$_wait" -gt 0 ] && [ "$_tp_done" -eq 0 ] && [ "$_tp_interrupted" -eq 0 ]; do
		_tp_drain_events
		sleep 0.1
		_wait=$((_wait - 1))
	done

	# If no PLAN events arrived, fall back (command doesn't use progress)
	if [ "${#_tp_order[@]}" -eq 0 ]; then
		unset ABA_PROGRESS_FIFO
		_tp_cleanup
		_TUI_REDIRECT_ACTIVE="$_tp_saved_redirect"
		_tui_redirect_activate 2>/dev/null || true
		# Fall back to progressbox mode
		return 2
	fi

	# Main event loop
	while true; do
		_tp_drain_events
		_tp_draw "$title"

		# Check for Ctrl+C (INT signal)
		[ "$_tp_interrupted" -eq 1 ] && break

		if [ "$_tp_done" -eq 1 ]; then
			while _tp_auto_complete_one; do
				_tp_draw "$title"
				sleep 0.2
			done

			# Crash detection: if the process exited non-zero and no step
			# emitted FAIL, mark the last active step as Failed.
			# Must run HERE (main shell), not inside _tp_finish_outcome
			# which runs in a subshell $(...) — array changes would be lost.
			if [ "$_tp_exit_code" -ne 0 ]; then
				local _has_fail=0 _last_active="" _cid _cst
				for _cid in "${_tp_order[@]}"; do
					_cst="${_tp_status[$_cid]:-9}"
					case "$_cst" in
						1) _has_fail=1 ;;
						7|77) _last_active="$_cid" ;;
					esac
				done
				if [ "$_has_fail" -eq 0 ] && [ -n "$_last_active" ]; then
					_tp_status[$_last_active]="1"
					_tp_real_done[$_last_active]="fail"
					_tp_failed+=("${_tp_text[$_last_active]:-$_last_active}")
					if [ "${#_tp_errors[@]}" -eq 0 ]; then
						_tp_errors+=("${_tp_text[$_last_active]:-$_last_active} failed (exit code $_tp_exit_code)")
						_tp_nexts+=("Check the live output for details")
					fi
				fi
			fi

			# Final sweep: mark steps that were PLANned but never ran
			if _tp_sweep_skipped; then
				_tp_draw "$title"
				sleep 1.5
			fi
			sleep 0.5

			_tp_draw "$title"
			case "$(_tp_finish_outcome)" in
				error)   _tp_show_error "$title"; _rc=1 ;;
				abort)   _tp_show_abort "$title"; _rc=1 ;;
				stopped) _tp_show_stopped "$title"; _rc=1 ;;
				*)       _tp_show_success "$title"; _rc=0 ;;
			esac
			break
		fi

		if _tp_auto_complete_one; then
			sleep 0.2
			continue
		fi

		if [ -n "$_tp_prompt_msg" ]; then
			_tp_handle_prompt "$_tp_prompt_msg" || break
			continue
		fi

		if IFS= read -rsn1 -t 0.4 key; then
			case "$key" in
				o|O|' ') _tp_show_output ;;
				q|Q) break ;;
			esac
		fi
	done

	unset ABA_PROGRESS_FIFO
	_tp_cleanup

	# If user pressed Retry, loop; otherwise break out
	[[ "$_TP_RETRY" -eq 1 ]] && continue
	break
	done  # retry loop

	# Run post-command hook (mirror cache invalidation, etc.)
	if [ -n "$post_cmd_hook" ]; then
		"$post_cmd_hook"
	fi

	# Restore TUI's global INT handler and redirect state
	trap 'exit 0' HUP TERM INT
	_TUI_REDIRECT_ACTIVE="$_tp_saved_redirect"
	_tui_redirect_activate 2>/dev/null || true
	return $_rc
}
