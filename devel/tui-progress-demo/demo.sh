#!/bin/bash
# demo.sh — ABA TUI Progress Dialog Demo (Make-based, menu-driven)
#
# Architecture:
#
#   ┌──────────────────────────────────────────────────────┐
#   │                      demo.sh (this script)           │
#   │                                                      │
#   │  ┌──────────┐    ┌────────────┐    ┌──────────────┐  │
#   │  │  dialog   │    │ FIFO drain │    │ PTY (python) │  │
#   │  │  menu /   │◄───│ in-memory  │    │              │  │
#   │  │ mixedgauge│    │ arrays     │    │  make save   │  │
#   │  └──────────┘    └─────▲──────┘    │  stdout→file │  │
#   │                        │           │  FIFO→events │  │
#   │                        │           └──────┬───────┘  │
#   │                        └──────────────────┘          │
#   └──────────────────────────────────────────────────────┘
#
# Flow:  Menu → select workflow → progress dialog → outcome → Menu

set -eo pipefail

DEMO_DIR="$(cd "$(dirname "$0")" && pwd)"

# Check requirements
for cmd in dialog python3 make; do
	command -v "$cmd" >/dev/null || {
		echo "Error: '$cmd' is required."
		exit 1
	}
done

# ─── Setup tmpdir and FIFOs (once, reused across workflows) ───
tmpdir=$(mktemp -d /tmp/aba-tui-demo-run.XXXXXX)

progress_fifo="$tmpdir/progress"
input_fifo="$tmpdir/input"
output_log="$tmpdir/output.log"
work_dir="$tmpdir/work"

mkfifo "$progress_fifo"
mkfifo "$input_fifo"
mkdir -p "$work_dir"
: > "$output_log"

export ABA_PROGRESS_FIFO="$progress_fifo"
export ABA_DEMO_TMP="$tmpdir"

# ─── In-memory state (reset between workflows) ───
declare -A _status _text
declare -a _order _errors _details _nexts
_prompt_msg=""
_abort=""
_aba_exited=0
_done=0

script_pid=""
tail_pid=""
_saved_stty=""

cleanup() {
	trap '' INT TTOU TTIN
	[ -n "$tail_pid" ] && kill "$tail_pid" 2>/dev/null || true
	[ -n "$script_pid" ] && kill "$script_pid" 2>/dev/null || true
	exec 8>&- 2>/dev/null || true
	exec 7>&- 2>/dev/null || true
	wait 2>/dev/null || true
	rm -rf "$tmpdir" || true
	[ -n "$_saved_stty" ] && stty "$_saved_stty" 2>/dev/null || true
	stty sane 2>/dev/null || true
	tput cnorm 2>/dev/null || true
	clear || true
	echo "Demo finished."
}
trap cleanup EXIT
trap 'exit 130' INT

_saved_stty=$(stty -g 2>/dev/null || true)
stty susp undef 2>/dev/null || true

# FD 7: keep input FIFO alive (read-write prevents blocking)
# FD 8: progress channel (read-write avoids open-blocking on FIFO)
exec 7<>"$input_fifo"
exec 8<>"$progress_fifo"

# ============================================================
# Event handling
# ============================================================

_parse_event() {
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
		PLAN)        _order+=("$id"); _text[$id]="$arg1"; _status[$id]="9" ;;
		START)       _status[$id]="77" ;;
		DONE)        _status[$id]="0" ;;
		FAIL)        _status[$id]="1" ;;
		ERROR)       _errors+=("${arg1:-$id}") ;;
		DETAIL)      _details+=("${arg1:-$id}") ;;
		NEXT)        _nexts+=("${arg1:-$id}") ;;
		ABORT)       _abort="${arg1:-$id}" ;;
		PROMPT)      _prompt_msg="${id}${arg1:+|$arg1}" ;;
		PROMPT_DONE) _prompt_msg="" ;;
	esac
}

_drain_events() {
	local _line
	while read -t 0.01 -r -u 8 _line; do
		_parse_event "$_line"
	done
	if [ "$_aba_exited" -eq 0 ] && ! kill -0 "$script_pid" 2>/dev/null; then
		_aba_exited=1
		while read -t 0.2 -r -u 8 _line; do
			_parse_event "$_line"
		done
		wait "$script_pid" 2>/dev/null || true
		_done=1
	fi
}

# ============================================================
# Progress display
# ============================================================

draw_progress() {
	local args=() total=0 done_count=0 id text status
	local _past_pending=0

	for id in "${_order[@]}"; do
		text="${_text[$id]:-$id}"
		status="${_status[$id]:-9}"
		[ "$status" = "77" ] && status="9"
		# Mask everything below the first pending step as N/A.
		# Ensures fill-in animation always flows top-to-bottom.
		if [ "$_past_pending" -eq 1 ]; then
			status="9"
		elif [ "$status" = "9" ]; then
			_past_pending=1
		fi
		args+=("$text" "$status")
		total=$((total + 1))
		case "$status" in 0|3|5) done_count=$((done_count + 1)) ;; esac
	done

	[ "$total" -eq 0 ] && return

	local pct=0
	[ "$total" -gt 0 ] && pct=$((done_count * 100 / total))

	local _subtitle="\n  [O] Live output  ·  [Q] Back to menu\n"
	if [ -n "$_prompt_msg" ]; then
		_subtitle="\n  ⚠  ABA needs input — press [O] to answer\n"
	fi

	dialog --title " ABA Mirror Save " \
		--mixedgauge "$_subtitle" \
		18 56 "$pct" \
		"${args[@]}" < /dev/null 2>/dev/null || true
}

# ============================================================
# Prompt handling
# ============================================================

handle_prompt() {
	local prompt="$1" rc=0
	dialog --title " ABA " --yes-label "Yes" --no-label "No" \
		--yesno "\n$prompt" 8 56 || rc=$?
	case "$rc" in
		0) printf 'y\r' > "$input_fifo" ;;
		1) printf 'n\r' > "$input_fifo" ;;
		*) return 1 ;;
	esac
}

# ============================================================
# Output view
# ============================================================

show_output() {
	clear
	printf '\033[1;33m'
	echo "═══════════════════════════════════════════════════════"
	echo "  ABA Live Output         (press any key to return)"
	echo "═══════════════════════════════════════════════════════"
	printf '\033[0m\n'
	cat "$output_log" 2>/dev/null
	tail -n 0 -f "$output_log" 2>/dev/null &
	tail_pid=$!
	read -rsn1 || true
	kill "$tail_pid" 2>/dev/null || true
	wait "$tail_pid" 2>/dev/null || true
	tail_pid=""
}

# ============================================================
# Auto-complete — one skipped predecessor per call
# ============================================================

_auto_complete_one() {
	local _first_pending="" id ps
	for id in "${_order[@]}"; do
		ps="${_status[$id]:-9}"
		case "$ps" in
			9)
				[ -z "$_first_pending" ] && _first_pending="$id"
				;;
			77)
				if [ -n "$_first_pending" ]; then
					_status[$_first_pending]="0"
					return 0
				fi
				_status[$id]="7"
				return 0
				;;
			7|0|1)
				if [ -n "$_first_pending" ]; then
					_status[$_first_pending]="0"
					return 0
				fi
				;;
		esac
	done
	return 1
}

# ============================================================
# Outcome determination and display
# ============================================================

finish_outcome() {
	local id status outcome=success
	[ -n "$_abort" ] && outcome=abort
	for id in "${_order[@]}"; do
		status="${_status[$id]:-9}"
		case "$status" in
			1) outcome=error ;;
			7|9|77)
				[ "$outcome" = success ] && outcome=stopped
				;;
		esac
	done
	[ "${#_errors[@]}" -gt 0 ] && outcome=error
	printf '%s' "$outcome"
}

show_error() {
	local _msg="\n" line
	[ "${#_errors[@]}" -eq 0 ] && _msg="\n  A step failed.\n"
	for line in "${_errors[@]}"; do
		_msg="${_msg}  ERROR: ${line}\n"
	done
	if [ "${#_details[@]}" -gt 0 ]; then
		_msg="${_msg}\n"
		for line in "${_details[@]}"; do
			_msg="${_msg}  ${line}\n"
		done
	fi
	if [ "${#_nexts[@]}" -gt 0 ]; then
		_msg="${_msg}\n  Possible next steps:\n"
		for line in "${_nexts[@]}"; do
			_msg="${_msg}    • ${line}\n"
		done
	fi
	_msg="${_msg}\n  Press 'View Output' for full output.\n"
	# Loop: View Output → output → back to this dialog. OK exits.
	while dialog --title " ✗ Error " \
		--yes-label "View Output" \
		--no-label "OK" \
		--yesno "$_msg" \
		18 64; do
		show_output
	done
}

show_abort() {
	[ -n "$_abort" ] || _abort="Aborted."
	dialog --title " Aborted " --msgbox "\n  $_abort\n" 8 60 || true
}

show_stopped() {
	dialog --title " Stopped " \
		--msgbox "\n  Stopped before all steps finished.\n" 8 56 || true
}

show_success() {
	dialog --title " ✓ Complete " \
		--msgbox "\n  All steps completed successfully!\n\n  Make drove the workflow with real marker files.\n  Cached targets were auto-completed by the TUI.\n  Progress was delivered via a separate FIFO.\n" \
		13 56 || true
}

# ============================================================
# Reset state between workflow runs
# ============================================================

_reset_state() {
	_status=()
	_text=()
	_order=()
	_errors=()
	_details=()
	_nexts=()
	_prompt_msg=""
	_abort=""
	_aba_exited=0
	_done=0
	# Drain any leftover FIFO data from previous run
	local _line
	while read -t 0.05 -r -u 8 _line; do :; done
}

_setup_workdir() {
	local mode="$1"
	rm -rf "$work_dir"
	mkdir -p "$work_dir"
	ln -sf "$DEMO_DIR/Makefile" "$work_dir/Makefile"
	ln -sfn "$DEMO_DIR/scripts" "$work_dir/scripts"
	# Pre-create marker files for cached mode (Make skips these targets)
	if [ "$mode" != "fresh" ]; then
		mkdir -p "$work_dir/data"
		touch "$work_dir/.init" "$work_dir/.rpmsext" "$work_dir/data/imageset-config.yaml"
	fi
	: > "$output_log"
}

# ============================================================
# Menu
# ============================================================

show_menu() {
	local _choice
	_choice=$(dialog --title " ABA TUI Demo " \
		--cancel-label "Exit" \
		--menu "\n  Real Makefile · PHONY _plan · PTY · FIFO progress\n" \
		18 64 6 \
		"quick"   "Success — fast, no prompts" \
		"prompt"  "Success — with interactive prompt" \
		"error"   "Error — catalog fails (rich error dialog)" \
		"abort"   "Abort — user says No at prompt" \
		"full"    "Full — real oc-mirror + prompt (slow)" \
		"fresh"   "Fresh build — all Make targets run" \
		3>&1 1>&2 2>&3) || _choice="quit"
	printf '%s' "$_choice"
}

# ============================================================
# Run a workflow
# ============================================================

run_workflow() {
	local mode="$1"

	_reset_state

	# Fresh mode = no cached marker files
	local _wdir_mode="cached"
	[ "$mode" = "fresh" ] && _wdir_mode="fresh"
	_setup_workdir "$_wdir_mode"

	# Set env vars for each test flow
	unset SIMULATE_FAIL SKIP_ASK SKIP_OC_MIRROR
	case "$mode" in
		quick)  export SKIP_ASK=1 SKIP_OC_MIRROR=1 ;;
		prompt) export SKIP_OC_MIRROR=1 ;;
		error)  export SKIP_ASK=1 SKIP_OC_MIRROR=1 SIMULATE_FAIL=1 ;;
		abort)  export SKIP_OC_MIRROR=1 ;;
		full)   ;;
		fresh)  ;;
	esac

	# Launch Make in a real PTY
	python3 "$DEMO_DIR/pty-run.py" --input-fifo "$input_fifo" "$output_log" \
		make -C "$work_dir" save &
	script_pid=$!

	# Wait for PLAN events before first draw
	local _wait=30
	while [ "${#_order[@]}" -eq 0 ] && [ "$_wait" -gt 0 ] && [ "$_done" -eq 0 ]; do
		_drain_events
		sleep 0.1
		_wait=$((_wait - 1))
	done

	# Main event loop
	while true; do
		_drain_events
		draw_progress

		if [ "$_done" -eq 1 ]; then
			while _auto_complete_one; do
				draw_progress
				sleep 0.2
			done
			sleep 0.8
			draw_progress
			case "$(finish_outcome)" in
				error)   show_error ;;
				abort)   show_abort ;;
				stopped) show_stopped ;;
				*)       show_success ;;
			esac
			break
		fi

		if _auto_complete_one; then
			sleep 0.2
			continue
		fi

		if [ -n "$_prompt_msg" ]; then
			handle_prompt "$_prompt_msg" || break
			continue
		fi

		if read -rsn1 -t 0.4 key; then
			case "$key" in
				o|O) show_output ;;
				q|Q) break ;;
			esac
		fi
	done

	# Ensure child is stopped
	[ -n "$script_pid" ] && kill "$script_pid" 2>/dev/null || true
	wait "$script_pid" 2>/dev/null || true
	script_pid=""
}

# ============================================================
# Main — menu loop
# ============================================================

while true; do
	choice=$(show_menu)
	case "$choice" in
		quick|prompt|error|abort|full|fresh)
			run_workflow "$choice" ;;
		quit|"")
			break ;;
	esac
done
