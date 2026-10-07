#!/bin/bash
# demo.sh — ABA TUI Progress Dialog Demo (Make-based, menu-driven)
#
# Demonstrates the progress architecture that will be ported to ABA's TUI.
#
# ─── Key design decisions ───────────────────────────────────────────
#
# 1. SEPARATION OF CONCERNS — each _progress_plan-* target only knows its OWN steps.
#    _progress_plan-install emits install PLANs.  _progress_plan-sync emits sync PLANs.
#    When "make sync" triggers install as a dependency, _progress_plan-install fires
#    first (it's a prereq of install), then _progress_plan-sync fires later.
#    The dialog GROWS as new PLANs arrive — two visible batches.
#
# 2. CONSISTENCY — _progress_plan-install is ALWAYS a prereq of install.
#    The TUI just calls "make install" or "make sync".  No need to
#    manually chain "_progress_plan-install install" from the caller.
#
# 3. OVER-GENEROUS PLANs — every step that MIGHT run is declared.
#    Steps that don't actually execute (Make skips them, or the script
#    has a conditional path) never get START/DONE events.
#    At the end, _sweep_skipped() marks them as "Skipped".
#
# 4. PLAN ORDER = EXECUTION ORDER — the PLAN list must match the order
#    Make will actually execute the steps.  Auto-complete marks
#    predecessors of the active step.  If PLAN order is wrong,
#    a not-yet-run step gets marked "Skipped" prematurely, then
#    flips to "In Progress" when it actually starts (confusing).
#    Example: preflight is a Make prereq (runs before sync-images.sh),
#    so its PLAN must come before catalogs_dl (which is inside
#    sync-images.sh).
#
# 5. REAL-TIME Skipped vs Succeeded — auto-complete checks _real_done[]
#    to decide the label.  If a step got real FIFO events (START/DONE),
#    it's "Succeeded".  If not, it's "Skipped" — immediately, not just
#    at the end.  This avoids showing "Succeeded" for steps that never
#    ran (the user would see a misleading label until the sweep).
#
# 6. LATE PLANs — a PLAN can arrive AFTER its START/DONE events.
#    This happens when Make runs a script (emits START/DONE) before
#    the plan target fires (emits PLAN).  Example: .rpmsint runs
#    before _progress_plan-sync fires.  The engine handles this: _text[] is
#    used as the dedup key (not _status[]), so the step is added to
#    _order even if it already has a status.
#
# 7. set -e SAFETY — never use "[ test ] && action" as the last command
#    in a function or case branch.  If the test is false, && returns 1,
#    and set -e kills the script.  Always use "if [ test ]; then ... fi".
#    Same class of bug as (( var++ )) crashing when var is 0.
#
# 8. BACKGROUND TASKS — a step can be In Progress while later steps also
#    progress (e.g. CLI download running in parallel with sync).
#    The masking algorithm handles this by finding the LAST step with
#    real activity (the "frontier") and only masking steps BEYOND it.
#    This replaces the old "mask below first active" algorithm, which
#    would hide sequential progress when a background step was active.
#
# ─── Architecture ───────────────────────────────────────────────────
#
#   ┌──────────────────────────────────────────────────────┐
#   │                      demo.sh (this script)           │
#   │                                                      │
#   │  ┌──────────┐    ┌────────────┐    ┌──────────────┐  │
#   │  │  dialog   │    │ FIFO drain │    │ PTY (python) │  │
#   │  │  menu /   │◄───│ in-memory  │    │              │  │
#   │  │ mixedgauge│    │ arrays     │    │  make target │  │
#   │  └──────────┘    └─────▲──────┘    │  stdout→file │  │
#   │                        │           │  FIFO→events │  │
#   │                        │           └──────┬───────┘  │
#   │                        └──────────────────┘          │
#   └──────────────────────────────────────────────────────┘

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
#
# _order[]     — step IDs in display order (arrival order of PLANs)
# _text[]      — human-readable label per step ID (also used as dedup key)
# _status[]    — dialog status code per step ID (see mixedgauge codes below)
# _real_done[] — tracks which steps got REAL FIFO events (START/DONE/FAIL)
#                Empty = step was auto-completed or never ran.
#                Used by auto-complete to decide Skipped vs Succeeded,
#                and by _sweep_skipped() at the end.
# _exit_code   — exit code from the Make process.  Non-zero = crash.
#                Used to distinguish a graceful FAIL (script emits FAIL event)
#                from an unexpected crash (syntax error, command not found, etc.)
declare -A _status _text _real_done
declare -a _order _errors _details _nexts _failed
_prompt_msg=""
_abort=""
_aba_exited=0
_exit_code=0
_done=0
_interrupted=0

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
		PLAN)
			# Dedup: _text[] is the "already planned" flag.
			# A PLAN can arrive AFTER START/DONE for the same ID (late PLAN).
			# This happens when Make runs a script before its plan target fires.
			# In that case, _status[] is already set but _text[] is empty.
			# We add to _order and set _text, but keep the existing status.
			if [ -z "${_text[$id]:-}" ]; then
				_order+=("$id")
				_text[$id]="$arg1"
				# Only set initial N/A status if no START/DONE has arrived yet.
				# Use if/then — NOT "[ ] && cmd" which returns 1 under set -e.
				if [ -z "${_status[$id]:-}" ]; then
					_status[$id]="9"
				fi
			fi
			;;
		START)       [ "${_status[$id]:-9}" != "0" ] && _status[$id]="77"; _real_done[$id]="started" ;;
		DONE)        _status[$id]="0"; _real_done[$id]="done" ;;
		FAIL)        _status[$id]="1"; _real_done[$id]="fail"; _failed+=("${_text[$id]:-$id}") ;;
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
	# Detect process exit and drain any final buffered events
	if [ "$_aba_exited" -eq 0 ] && ! kill -0 "$script_pid" 2>/dev/null; then
		_aba_exited=1
		while read -t 0.2 -r -u 8 _line; do
			_parse_event "$_line"
		done
		# Capture exit code — non-zero means the Make process crashed
		_exit_code=0
		wait "$script_pid" 2>/dev/null || _exit_code=$?
		_done=1
	fi
}

# ============================================================
# Progress display
# ============================================================

# dialog --mixedgauge status codes:
#   0  = Succeeded (green checkmark)
#   1  = Failed
#   2  = Passed
#   3  = Completed
#   4  = Checked
#   5  = Done
#   6  = Skipped (internally; displayed as "Satisfied" via custom text)
#   7  = In Progress
#   8  = (blank)
#   9  = N/A
#  -NNN = percentage bar (negative number = percentage)

draw_progress() {
	local _title="$1"
	local _subtitle_override="${2:-}"
	local args=() total=0 done_count=0 id text status
	local _idx=0

	# Find the last step with a non-N/A status (the "frontier").
	# Everything after the frontier is masked as N/A.
	# This replaces the old "mask everything below first active" algorithm,
	# which broke when a background task was In Progress above the main
	# sequential flow.  A background step (In Progress at position 2)
	# alongside sequential work (In Progress at position 6) is fine —
	# only steps beyond the last real activity get masked.
	local _last_real_idx=-1 _scan=0
	for id in "${_order[@]}"; do
		status="${_status[$id]:-9}"
		if [ "$status" != "9" ]; then
			_last_real_idx=$_scan
		fi
		_scan=$((_scan + 1))
	done

	for id in "${_order[@]}"; do
		text="${_text[$id]:-$id}"
		status="${_status[$id]:-9}"
		# 77 = "just received START" — display as 7 (In Progress)
		[ "$status" = "77" ] && status="7"
		# Mask steps beyond the frontier as N/A
		if [ "$_idx" -gt "$_last_real_idx" ]; then
			status="9"
		fi
		# Custom label: "Satisfied" instead of dialog's built-in "Skipped"
		[ "$status" = "6" ] && status="Satisfied"
		args+=("$text" "$status")
		total=$((total + 1))
		# Count Succeeded, Completed, Done, and Satisfied toward progress %
		case "$status" in 0|3|5|6|Satisfied) done_count=$((done_count + 1)) ;; esac
		_idx=$((_idx + 1))
	done

	[ "$total" -eq 0 ] && return

	local pct=0
	[ "$total" -gt 0 ] && pct=$((done_count * 100 / total))

	local _subtitle="\n       < Output (Space) >       < Abort (Q) >\n"
	if [ -n "$_subtitle_override" ]; then
		_subtitle="$_subtitle_override"
	elif [ -n "$_prompt_msg" ]; then
		_subtitle="\n     ⚠  ABA needs input — press < Output (Space) >\n"
	fi

	# Dynamic height: 10 rows for chrome (title, subtitle, progress bar) + 1 per step, min 18.
	# Needed because the dialog grows when sync PLANs arrive after install.
	local _height=$(( ${#_order[@]} + 10 ))
	[ "$_height" -lt 18 ] && _height=18

	dialog --title " $_title " \
		--mixedgauge "$_subtitle" \
		$_height 56 "$pct" \
		"${args[@]}" < /dev/null 2>/dev/null || true
}

# ============================================================
# Prompt handling
# ============================================================

handle_prompt() {
	local _raw="$1" rc=0
	# Extract default from "question|y" or "question|n" format
	local _prompt="${_raw%|*}"
	local _default="${_raw##*|}"
	# If no separator, prompt is the full string
	[ "$_prompt" = "$_raw" ] && _prompt="$_raw" && _default=""

	local _default_flag=""
	[ "$_default" = "n" ] && _default_flag="--defaultno"

	dialog --title " ABA " --yes-label "Yes" --no-label "No" $_default_flag \
		--yesno "\n$_prompt" 0 0 || rc=$?
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
# Auto-complete — fill in predecessors of the active step
# ============================================================
#
# When a step gets START (status 77), all pending predecessors (status 9)
# above it in _order must have already been processed by Make.
# This function marks ONE such predecessor per call, using _real_done[]
# to decide the label:
#
#   _real_done[id] is set  → step got real START/DONE → "Succeeded" (0)
#   _real_done[id] is empty → step never ran          → "Skipped"   (6)
#
# This gives the user immediate correct feedback — no misleading
# "Succeeded" for steps that were skipped.  The old approach (always
# mark Succeeded, sweep to Skipped at the end) showed wrong labels
# during execution.

_auto_complete_one() {
	local _first_pending="" id ps
	for id in "${_order[@]}"; do
		ps="${_status[$id]:-9}"
		case "$ps" in
			9)
				[ -z "$_first_pending" ] && _first_pending="$id"
				;;
			77)
				# Found the first active step.  Fill in one predecessor.
				if [ -n "$_first_pending" ]; then
					if [ -n "${_real_done[$_first_pending]:-}" ]; then
						_status[$_first_pending]="0"
					else
						_status[$_first_pending]="6"
					fi
					return 0
				fi
				# No pending predecessors — just promote 77→7
				_status[$id]="7"
				return 0
				;;
			7|0|1|6)
				if [ -n "$_first_pending" ]; then
					if [ -n "${_real_done[$_first_pending]:-}" ]; then
						_status[$_first_pending]="0"
					else
						_status[$_first_pending]="6"
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
# After the Make command finishes, any step that:
#   - has status 0 (auto-completed as Succeeded) or 9 (still N/A)
#   - has NO entry in _real_done[] (never got a real FIFO event)
# is changed to status 6 (Skipped).
#
# This catches steps that were auto-completed during execution but
# never actually ran.  In most cases, auto-complete already set them
# to Skipped (via _real_done check).  The sweep is a safety net for
# edge cases like steps that were never predecessors of any active step.

_sweep_skipped() {
	local id ps _any=0
	for id in "${_order[@]}"; do
		ps="${_status[$id]:-9}"
		if [ -z "${_real_done[$id]:-}" ]; then
			if [ "$ps" = "9" ] || [ "$ps" = "0" ]; then
				_status[$id]="6"
				_any=1
			fi
		fi
	done
	return $(( 1 - _any ))
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
	local _title="${1:-Error}"
	local _msg="\n" line

	# Show which step(s) failed
	for line in "${_failed[@]}"; do
		_msg="${_msg}  Failed: ${line}\n"
	done

	# Show only the first ERROR (the most specific/tailored one).
	# aba_abort auto-emits ERROR, so duplicates are expected — first wins.
	[ "${#_errors[@]}" -eq 0 ] && _msg="${_msg}\n  A step failed.\n"
	[ "${#_errors[@]}" -gt 0 ] && _msg="${_msg}\n  ERROR: ${_errors[0]}\n"
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
	while dialog --title " ${_title}: Error " \
		--yes-label "View Output" \
		--no-label "OK" \
		--yesno "$_msg" \
		0 0; do
		show_output
	done
}

show_abort() {
	local _title="${1:-ABA}"
	[ -n "$_abort" ] || _abort="Aborted."
	dialog --title " ${_title}: Aborted " --msgbox "\n  $_abort\n" 8 60 || true
}

show_stopped() {
	local _title="${1:-ABA}"
	dialog --title " ${_title}: Stopped " \
		--msgbox "\n  Stopped before all steps finished.\n" 8 56 || true
}

show_success() {
	local _title="${1:-ABA}"
	local _body id text status _label _color _pad
	local _max_len=34

	# Build colored status text from the step arrays
	_body="\n"
	for id in "${_order[@]}"; do
		text="${_text[$id]:-$id}"
		status="${_status[$id]:-9}"
		case "$status" in
			0)  _label=" Succeeded "; _color="\\Z2" ;;
			1)  _label="  Failed   "; _color="\\Z1" ;;
			6)  _label=" Satisfied "; _color="\\Z2" ;;
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

	local _height=$(( ${#_order[@]} + 8 ))
	[ "$_height" -lt 14 ] && _height=14

	local _default_btn=""
	while true; do
		local _rc=0
		dialog --colors $_default_btn \
			--title " $_title " \
			--yes-label "Done" --no-label "Output" \
			--yesno "$_body" \
			"$_height" 56 || _rc=$?
		case "$_rc" in
			0|255) break ;;
			1) _default_btn="--defaultno"; show_output ;;
		esac
	done
}

# ============================================================
# Reset state between workflow runs
# ============================================================

_reset_state() {
	_status=()
	_text=()
	_real_done=()
	_order=()
	_errors=()
	_details=()
	_nexts=()
	_failed=()
	_prompt_msg=""
	_abort=""
	_aba_exited=0
	_exit_code=0
	_done=0
	_interrupted=0
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
	# Pre-create marker files based on mode.
	# "cached" = prereqs exist, Make skips their recipes.
	# "fresh"  = nothing exists, Make builds everything.
	case "$mode" in
		fresh)
			# Nothing cached — all Make prereqs will run
			;;
		cached)
			# Prereqs cached — install-rpms.sh etc. are skipped by Make
			mkdir -p "$work_dir/data"
			touch "$work_dir/.init" "$work_dir/.rpmsext" "$work_dir/.rpmsint"
			touch "$work_dir/data/imageset-config.yaml"
			;;
		cached-installed)
			# All prereqs + registry installed (.available exists)
			# _progress_plan-install checks .available and emits nothing → no install PLANs
			mkdir -p "$work_dir/data"
			touch "$work_dir/.init" "$work_dir/.rpmsext" "$work_dir/.rpmsint"
			touch "$work_dir/.available"
			touch "$work_dir/data/imageset-config.yaml"
			;;
	esac
	: > "$output_log"
}

# ============================================================
# Menu
# ============================================================

show_menu() {
	local _choice
	_choice=$(dialog --title " ABA TUI Progress Demo " \
		--cancel-label "Exit" \
		--menu "\n  PHONY _plan targets · Skipped sweep · PTY + FIFO\n" \
		26 68 14 \
		"install"       "Install registry (cached — RPMs skipped)" \
		"install-fresh" "Install registry (fresh — all steps run)" \
		"sync"          "Sync images (cached — RPMs & catalogs skipped)" \
		"sync-catalogs" "Sync images (catalogs need downloading)" \
		"sync-bg"       "Sync + background CLI download (parallel)" \
		"save"          "Save images (cached, no prompt)" \
		"save-prompt"   "Save images (with interactive prompt)" \
		"save-error"    "Save images (fails during save step)" \
		"bundle"        "Create bundle (shared IDs — dedup demo)" \
		"bundle-error"  "Create bundle (save fails mid-way)" \
		"sync-crash"    "Sync crash (script dies, no FAIL event)" \
		"uninstall"     "Uninstall registry (all steps run)" \
		"fresh-all"     "Sync (mirror not installed — installs first)" \
		"fresh-bg"      "Sync fresh + background CLI download" \
		3>&1 1>&2 2>&3) || _choice="quit"
	printf '%s' "$_choice"
}

# ============================================================
# Run a workflow
# ============================================================

run_workflow() {
	local scenario="$1"

	_reset_state

	# Parse scenario into make target + env + workdir mode.
	# The TUI just calls "make <target>" — _progress_plan-* targets are Make prereqs,
	# so the TUI never needs to chain them manually.
	local make_target="" wdir_mode="cached" title="" envs=""
	case "$scenario" in
		install)
			make_target="install"
			wdir_mode="cached"
			title="Install Mirror"
			;;
		install-fresh)
			make_target="install"
			wdir_mode="fresh"
			title="Install Mirror"
			envs="FORCE_RPM_INSTALL=1"
			;;
		sync)
			make_target="sync"
			wdir_mode="cached-installed"
			title="Sync Images to Mirror"
			envs="SKIP_OC_MIRROR=1"
			;;
		sync-catalogs)
			make_target="sync"
			wdir_mode="cached-installed"
			title="Sync Images to Mirror"
			envs="SKIP_OC_MIRROR=1 FORCE_CATALOG_DOWNLOAD=1"
			;;
		sync-bg)
			# Sync with a real run_once download running in parallel.
			# "Download CLI tools" stays In Progress beside the sync steps.
			# "Wait for CLI tools" is the run_once -w at the end.
			# The frontier mask leaves the background row visible while
			# later steps are also in progress.
			make_target="sync"
			wdir_mode="cached-installed"
			title="Sync Images to Mirror"
			envs="SKIP_OC_MIRROR=1 SIMULATE_BG_DOWNLOAD=1"
			;;
		save)
			make_target="save"
			wdir_mode="cached"
			title="Save Images"
			envs="SKIP_ASK=1 SKIP_OC_MIRROR=1"
			;;
		save-prompt)
			make_target="save"
			wdir_mode="cached"
			title="Save Images"
			envs="SKIP_OC_MIRROR=1"
			;;
		save-error)
			make_target="save"
			wdir_mode="cached"
			title="Save Images"
			envs="SKIP_ASK=1 SKIP_OC_MIRROR=1 SIMULATE_FAIL=1"
			;;
		bundle)
			make_target="bundle"
			wdir_mode="cached"
			title="Create Install Bundle"
			envs="SKIP_ASK=1 SKIP_OC_MIRROR=1"
			;;
		bundle-error)
			make_target="bundle"
			wdir_mode="cached"
			title="Create Install Bundle"
			envs="SKIP_ASK=1 SKIP_OC_MIRROR=1 SIMULATE_FAIL=1"
			;;
		sync-crash)
			# Unexpected crash: oc-mirror (or any tool) dies with no FAIL event.
			# The TUI detects non-zero exit, marks the active step as Failed,
			# and shows an error dialog pointing to the output log.
			make_target="sync"
			wdir_mode="cached-installed"
			title="Sync Images to Mirror"
			envs="SKIP_OC_MIRROR=1 SIMULATE_CRASH=1"
			;;
		uninstall)
			make_target="uninstall"
			wdir_mode="cached-installed"
			title="Uninstall Mirror"
			;;
		fresh-all)
			# Sync on a fresh system — Make resolves install as a dependency.
			# _progress_plan-install fires first (install PLANs), install runs,
			# then _progress_plan-sync fires (sync PLANs) and the dialog grows.
			# Title is just "Sync" — the TUI doesn't predict dependencies.
			# The install steps appearing in the dialog tell the user what's happening.
			make_target="sync"
			wdir_mode="fresh"
			title="Sync Images to Mirror"
			envs="FORCE_RPM_INSTALL=1 FORCE_CATALOG_DOWNLOAD=1 SKIP_OC_MIRROR=1"
			;;
		fresh-bg)
			# Fresh sync + background CLI download — both features together.
			# Install PLANs arrive first, then sync PLANs (with bg download steps).
			# The bg task runs in parallel with sequential sync work.
			make_target="sync"
			wdir_mode="fresh"
			title="Sync Images to Mirror"
			envs="FORCE_RPM_INSTALL=1 FORCE_CATALOG_DOWNLOAD=1 SKIP_OC_MIRROR=1 SIMULATE_BG_DOWNLOAD=1"
			;;
	esac

	_setup_workdir "$wdir_mode"

	# Launch Make in a real PTY with scenario-specific env vars
	eval "$envs python3 \"$DEMO_DIR/pty-run.py\" --input-fifo \"$input_fifo\" \"$output_log\" \
		make -C \"$work_dir\" $make_target &"
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
		draw_progress "$title"

		[ "$_interrupted" -eq 1 ] && break

		if [ "$_done" -eq 1 ]; then
			# Process exited.  Auto-complete any lagging predecessors.
			while _auto_complete_one; do
				draw_progress "$title"
				sleep 0.2
			done

			# Crash detection: if the process exited non-zero and no step
			# emitted FAIL, this is an unexpected crash (syntax error, segfault,
			# set -e, etc.).  Mark the last active step as Failed and add a
			# generic error pointing to the output log.
			# Must run HERE (main shell), not inside finish_outcome which runs
			# in a subshell $(...) — array changes would be lost.
			if [ "$_exit_code" -ne 0 ]; then
				local _has_fail=0 _last_active="" _cid _cst
				for _cid in "${_order[@]}"; do
					_cst="${_status[$_cid]:-9}"
					case "$_cst" in
						1) _has_fail=1 ;;
						7|77) _last_active="$_cid" ;;
					esac
				done
				if [ "$_has_fail" -eq 0 ] && [ -n "$_last_active" ]; then
					_status[$_last_active]="1"
					_real_done[$_last_active]="fail"
					_failed+=("${_text[$_last_active]:-$_last_active}")
					if [ "${#_errors[@]}" -eq 0 ]; then
						_errors+=("${_text[$_last_active]:-$_last_active} failed (exit code $_exit_code)")
						_nexts+=("Check the live output for details")
					fi
				fi
			fi

			# Final sweep: mark steps that were PLANned but never ran
			if _sweep_skipped; then
				draw_progress "$title"
				sleep 1.5
			fi
			sleep 0.5

			draw_progress "$title"
			case "$(finish_outcome)" in
				error)   show_error "$title" ;;
				abort)   show_abort "$title" ;;
				stopped) show_stopped "$title" ;;
				*)       show_success "$title" ;;
			esac
			break
		fi

		# During execution: auto-complete one predecessor per loop iteration
		# (animated fill-in, one step at a time)
		if _auto_complete_one; then
			sleep 0.2
			continue
		fi

		# If the running script is waiting for input, show a prompt dialog
		if [ -n "$_prompt_msg" ]; then
			handle_prompt "$_prompt_msg" || break
			continue
		fi

		# Poll for user keypresses (Space=output view, Q=quit)
		if IFS= read -rsn1 -t 0.4 key; then
			case "$key" in
				o|O|' ') show_output ;;
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
		install|install-fresh|sync|sync-catalogs|sync-bg|save|save-prompt|save-error|bundle|bundle-error|sync-crash|uninstall|fresh-all|fresh-bg)
			run_workflow "$choice" ;;
		quit|"")
			break ;;
	esac
done
