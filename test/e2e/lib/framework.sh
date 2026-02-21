#!/bin/bash
# =============================================================================
# E2E Test Framework -- Core Library
# =============================================================================
# Provides: e2e_run, e2e_run_remote, e2e_run_must_fail, suite/test lifecycle,
#           live progress display, interactive retry/skip/abort, checkpoint/resume,
#           assertions, guards, and notification support.
#
# Usage: source this file from suite scripts or run.sh
# =============================================================================
#
# ===========================  E2E GOLDEN RULES  =============================
#
#  1. Tests MUST fail on error.  Never mask underlying issues.
#     If something breaks, the test must stop and report it.
#
#  2. Never use '2>/dev/null' in test commands.
#     Stderr output is diagnostic gold.  Suppressing it hides root causes.
#
#  3. Never use '|| true' in test commands.
#     If a command can legitimately fail, use 'e2e_diag' or embed an explicit
#     precondition check (e.g. if [ -f X ]; then ...; fi).
#
#  4. When a test fails, check if the fix belongs in ABA code FIRST.
#     Tests exercise the product -- don't paper over product bugs.
#
#  5. Never "fix" a test just to make it pass.
#     A passing test that hides a real failure is worse than a failing test.
#
#  6. Uninstall from the same host that installed.
#     If the registry was installed from conN, uninstall from conN -- not disN.
#
#  7. Never remove tools before operations that need them.
#     E.g. don't 'dnf remove make' before 'aba reset -f' (which needs make).
#
#  8. Verify cleanup actually worked.
#     After uninstall, assert the service is down (e.g. curl check).
#     After cleanup, assert the directory is gone.
#
#  9. Use 'e2e_diag' for diagnostic/informational commands whose exit code
#     does not matter.  Never use it for steps that must succeed.
#
# 10. Prefer 'aba' commands over raw 'make' / scripts.
#     Eat your own dog food.  Use the product's CLI for setup and teardown.
#
# ============================================================================

# Resolve the directory this library lives in
_E2E_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_E2E_DIR="$(cd "$_E2E_LIB_DIR/.." && pwd)"

# --- Globals ----------------------------------------------------------------

# Interactive mode: prompt on failure (retry/skip/abort). Set by run.sh.
_E2E_INTERACTIVE="${_E2E_INTERACTIVE:-}"

# Notification command (e.g. notify.sh). Empty = disabled.
NOTIFY_CMD="${NOTIFY_CMD:-}"

# Checkpoint / resume state files
E2E_STATE_FILE=""      # Written during a run: logs pass/fail per test
E2E_RESUME_FILE="${E2E_RESUME_FILE:-}"  # If set, skip tests already passed in a previous run

# Log file for the current suite run
E2E_LOG_DIR="${_E2E_DIR}/logs"
E2E_LOG_FILE=""
E2E_SUMMARY_FILE=""   # Summary log: only test names, PASS/FAIL, commands (no verbose output)

# Current suite / test tracking
_E2E_SUITE_NAME=""
_E2E_CURRENT_TEST=""
_E2E_TEST_COUNT=0
_E2E_PASS_COUNT=0
_E2E_FAIL_COUNT=0
_E2E_SKIP_COUNT=0
_E2E_START_TIME=""

# Resume skip-block: when set, test_begin/e2e_run skip commands until test_end
_E2E_SKIP_BLOCK=""

# Progress plan -- parallel arrays
declare -a _E2E_PLAN_NAMES=()
declare -a _E2E_PLAN_STATUS=()  # PENDING | RUNNING | PASS | FAIL | SKIP | DONE

# --- Color helpers ----------------------------------------------------------

_e2e_color() {
    local code="$1"; shift
    # Always emit ANSI colors -- output is viewed via 'tail -f' on log files
    printf '\033[%sm%s\033[0m' "$code" "$*"
}

# Force ANSI colors regardless of TTY (for log files viewed via tail -f)
_e2e_color_always() {
    local code="$1"; shift
    printf '\033[%sm%s\033[0m' "$code" "$*"
}

_e2e_red()    { _e2e_color "0;31" "$@"; }
_e2e_green()  { _e2e_color "0;32" "$@"; }
_e2e_yellow() { _e2e_color "0;33" "$@"; }
_e2e_cyan()   { _e2e_color "0;36" "$@"; }
_e2e_bold()   { _e2e_color "1"    "$@"; }

# Always-colored variants (for summary log, always readable via tail -f)
_e2e_Red()    { _e2e_color_always "1;31" "$@"; }
_e2e_Green()  { _e2e_color_always "1;32" "$@"; }
_e2e_Yellow() { _e2e_color_always "1;33" "$@"; }
_e2e_Cyan()   { _e2e_color_always "1;36" "$@"; }
_e2e_Bold()   { _e2e_color_always "1"    "$@"; }

# --- Logging ----------------------------------------------------------------

_e2e_log() {
    local ts
    ts="$(date '+%b %e %H:%M:%S')"
    echo "$ts  $*" >> "${E2E_LOG_FILE:-/dev/null}"
}

_e2e_log_and_print() {
    local ts
    ts="$(date '+%b %e %H:%M:%S')"
    echo "$ts  $*" | tee -a "${E2E_LOG_FILE:-/dev/null}"
}

_e2e_draw_line() {
    local char="${1:--}"
    local cols
    cols=$(tput cols 2>/dev/null || echo 80)
    printf '%*s\n' "$cols" '' | tr ' ' "$char"
}

# --- Summary Log ------------------------------------------------------------
# A tidy summary file showing only test names, commands, PASS/FAIL, and timing.
# Colors are forced on (ANSI) so "tail -f" is always readable.
# This mirrors the "test/test.log" pattern from the old test-cmd framework.

_e2e_summary() {
    # Write a color-coded line to the summary log (always with ANSI colors)
    [ -z "${E2E_SUMMARY_FILE:-}" ] && return
    local ts
    ts="$(date '+%H:%M:%S')"
    echo "$ts  $*" >> "$E2E_SUMMARY_FILE"
}

# --- Notification -----------------------------------------------------------

_e2e_notify() {
    if [ -n "$NOTIFY_CMD" ]; then
        # Pass message as args only (not also via stdin, which caused duplicates)
        $NOTIFY_CMD "$@" < /dev/null 2>/dev/null || true
    fi
}

_e2e_notify_stdin() {
    local subject="$1"
    if [ -n "$NOTIFY_CMD" ]; then
        $NOTIFY_CMD "$subject" 2>/dev/null || true
    else
        cat > /dev/null  # drain stdin
    fi
}

# --- Progress Table ---------------------------------------------------------

plan_tests() {
    # Register test names for the progress display
    # Usage: plan_tests "test1" "test2" "test3"
    _E2E_PLAN_NAMES=("$@")
    _E2E_PLAN_STATUS=()
    local i
    for i in "${!_E2E_PLAN_NAMES[@]}"; do
        _E2E_PLAN_STATUS[$i]="PENDING"
    done
    _print_progress
}

_update_plan() {
    local name="$1" status="$2"
    local i
    for i in "${!_E2E_PLAN_NAMES[@]}"; do
        if [ "${_E2E_PLAN_NAMES[$i]}" = "$name" ]; then
            _E2E_PLAN_STATUS[$i]="$status"
            break
        fi
    done
    _print_progress
}

_print_progress() {
    [ ${#_E2E_PLAN_NAMES[@]} -eq 0 ] && return

    # Calculate column width from longest test name (min 40, +4 padding)
    local _col=40
    for i in "${!_E2E_PLAN_NAMES[@]}"; do
        local _len=${#_E2E_PLAN_NAMES[$i]}
        (( _len + 4 > _col )) && _col=$(( _len + 4 ))
    done

    # Print to screen
    echo ""
    _e2e_draw_line "="
    if [ -n "${_E2E_SUITE_NAME:-}" ]; then
        local _pi=""
        [ -n "${POOL_NUM:-}" ] && _pi="  [pool${POOL_NUM} @ $(hostname -s)]"
        printf "  %s\n" "$(_e2e_bold "Suite: $_E2E_SUITE_NAME${_pi}")"
    fi
    printf "  %-${_col}s %s\n" "TEST" "STATUS"
    _e2e_draw_line "-"

    local i status_str status_str_color
    for i in "${!_E2E_PLAN_NAMES[@]}"; do
        case "${_E2E_PLAN_STATUS[$i]}" in
            PASS)    status_str="$(_e2e_green "PASS")";          status_str_color="$(_e2e_Green "PASS")" ;;
            FAIL)    status_str="$(_e2e_red "FAIL")";            status_str_color="$(_e2e_Red "FAIL")" ;;
            SKIP)    status_str="$(_e2e_yellow "SKIP")";         status_str_color="$(_e2e_Yellow "SKIP")" ;;
            RUNNING) status_str="$(_e2e_cyan "RUNNING...")";     status_str_color="$(_e2e_Cyan "RUNNING...")" ;;
            DONE)    status_str="$(_e2e_green "DONE (resumed)")"; status_str_color="$(_e2e_Green "DONE (resumed)")" ;;
            *)       status_str="  --";                          status_str_color="  --" ;;
        esac
        printf "  %-${_col}s %s\n" "${_E2E_PLAN_NAMES[$i]}" "$status_str"
    done

    _e2e_draw_line "="
    echo ""

    # Also write the progress table to the summary log (with forced colors for tail -f)
    local _line
    printf -v _line '%*s' $(( _col + 20 )) '' ; _line="${_line// /=}"
    _e2e_summary ""
    _e2e_summary "  $_line"
    if [ -n "${_E2E_SUITE_NAME:-}" ]; then
        local _si=""
        [ -n "${POOL_NUM:-}" ] && _si="  [pool${POOL_NUM} @ $(hostname -s)]"
        _e2e_summary "  $(_e2e_Bold "Suite: $_E2E_SUITE_NAME${_si}")"
    fi
    _e2e_summary "  $(printf "%-${_col}s %s" "TEST" "STATUS")"
    printf -v _line '%*s' $(( _col + 20 )) '' ; _line="${_line// /-}"
    _e2e_summary "  $_line"
    for i in "${!_E2E_PLAN_NAMES[@]}"; do
        case "${_E2E_PLAN_STATUS[$i]}" in
            PASS)    status_str_color="$(_e2e_Green "PASS")" ;;
            FAIL)    status_str_color="$(_e2e_Red "FAIL")" ;;
            SKIP)    status_str_color="$(_e2e_Yellow "SKIP")" ;;
            RUNNING) status_str_color="$(_e2e_Cyan "RUNNING...")" ;;
            DONE)    status_str_color="$(_e2e_Green "DONE (resumed)")" ;;
            *)       status_str_color="  --" ;;
        esac
        _e2e_summary "  $(printf "%-${_col}s" "${_E2E_PLAN_NAMES[$i]}") $status_str_color"
    done
    printf -v _line '%*s' $(( _col + 20 )) '' ; _line="${_line// /=}"
    _e2e_summary "  $_line"
    _e2e_summary ""

    # Append to the full log too (plain text, no colors)
    if [ -n "${E2E_LOG_FILE:-}" ]; then
        {
            echo ""
            if [ -n "${_E2E_SUITE_NAME:-}" ]; then
                local _li=""
                [ -n "${POOL_NUM:-}" ] && _li="  [pool${POOL_NUM} @ $(hostname -s)]"
                echo "  Suite: $_E2E_SUITE_NAME${_li}"
            fi
            printf "  %-${_col}s %s\n" "TEST" "STATUS"
            printf -v _line '%*s' $(( _col + 20 )) '' ; _line="${_line// /-}"
            echo "  $_line"
            for i in "${!_E2E_PLAN_NAMES[@]}"; do
                printf "  %-${_col}s %s\n" "${_E2E_PLAN_NAMES[$i]}" "${_E2E_PLAN_STATUS[$i]}"
            done
            echo ""
        } >> "$E2E_LOG_FILE"
    fi
}

# --- Suite Lifecycle --------------------------------------------------------

suite_begin() {
    local suite_name="$1"
    _E2E_SUITE_NAME="$suite_name"
    _E2E_TEST_COUNT=0
    _E2E_PASS_COUNT=0
    _E2E_FAIL_COUNT=0
    _E2E_SKIP_COUNT=0
    _E2E_START_TIME=$(date +%s)

    # Set up log files (timestamped for history, symlinks for easy access)
    mkdir -p "$E2E_LOG_DIR"
    local ts_stamp
    ts_stamp="$(date +%Y%m%d-%H%M%S)"
    E2E_LOG_FILE="${E2E_LOG_DIR}/${suite_name}-${ts_stamp}.log"
    E2E_SUMMARY_FILE="${E2E_LOG_DIR}/${suite_name}-${ts_stamp}-summary.log"

    # Per-suite symlinks: <suite>-latest.log, <suite>-summary.log
    ln -sf "$(basename "$E2E_LOG_FILE")" "${E2E_LOG_DIR}/${suite_name}-latest.log"
    ln -sf "$(basename "$E2E_SUMMARY_FILE")" "${E2E_LOG_DIR}/${suite_name}-summary.log"

    # Global symlinks: latest.log, summary.log  (always point to the active suite)
    ln -sf "$(basename "$E2E_LOG_FILE")" "${E2E_LOG_DIR}/latest.log"
    ln -sf "$(basename "$E2E_SUMMARY_FILE")" "${E2E_LOG_DIR}/summary.log"

    # Initialize state file for checkpointing
    E2E_STATE_FILE="${E2E_LOG_DIR}/${suite_name}.state"

    # Bug 2 fix: if resuming and the resume file IS our state file, copy it
    # to a .resume backup so truncating the state file doesn't destroy it
    if [ -n "$E2E_RESUME_FILE" ] && [ -f "$E2E_RESUME_FILE" ]; then
        local resume_backup="${E2E_STATE_FILE}.resume"
        cp "$E2E_RESUME_FILE" "$resume_backup"
        E2E_RESUME_FILE="$resume_backup"
    fi

    : > "$E2E_STATE_FILE"

    local _host_info=""
    [ -n "${POOL_NUM:-}" ] && _host_info="pool${POOL_NUM} @ $(hostname -s)"

    _e2e_draw_line "="
    _e2e_log_and_print "$(_e2e_bold "SUITE: $suite_name${_host_info:+  [$_host_info]}")"
    _e2e_draw_line "="
    _e2e_summary "$(_e2e_Bold "========== SUITE: $suite_name${_host_info:+  [$_host_info]} ==========")"
    _e2e_notify "Suite started: $suite_name${_host_info:+ ($_host_info)} ($(date))"
}

suite_end() {
    local elapsed=$(( $(date +%s) - _E2E_START_TIME ))
    local mins=$(( elapsed / 60 ))
    local secs=$(( elapsed % 60 ))

    echo ""
    _e2e_draw_line "="
    _e2e_log_and_print "SUITE COMPLETE: $_E2E_SUITE_NAME"
    _e2e_log_and_print "  Total: $_E2E_TEST_COUNT  Pass: $_E2E_PASS_COUNT  Fail: $_E2E_FAIL_COUNT  Skip: $_E2E_SKIP_COUNT"
    _e2e_log_and_print "  Duration: ${mins}m ${secs}s"
    _e2e_draw_line "="

    _print_progress

    if [ "$_E2E_FAIL_COUNT" -gt 0 ]; then
        _e2e_summary "$(_e2e_Red "========== FAILED: $_E2E_SUITE_NAME  (${_E2E_FAIL_COUNT} failures, ${mins}m ${secs}s) ==========")"
        _e2e_notify "FAILED: $_E2E_SUITE_NAME -- $_E2E_FAIL_COUNT failures ($(date))"
        return 1
    else
        _e2e_summary "$(_e2e_Green "========== PASSED: $_E2E_SUITE_NAME  (${_E2E_PASS_COUNT} passed, ${mins}m ${secs}s) ==========")"
        _e2e_notify "PASSED: $_E2E_SUITE_NAME -- $_E2E_PASS_COUNT passed (${mins}m ${secs}s)"
        return 0
    fi
}

# --- Test Lifecycle ---------------------------------------------------------

test_begin() {
    local test_name="$1"
    _E2E_CURRENT_TEST="$test_name"
    (( _E2E_TEST_COUNT++ )) || true

    # Bug 3 fix: check resume checkpoint for test_begin/test_end pattern
    if should_skip_checkpoint "$test_name"; then
        _E2E_SKIP_BLOCK=1
        _update_plan "$test_name" "DONE"
        _e2e_log_and_print "$(_e2e_green "  DONE (resumed): $test_name")"
        _e2e_summary "$(_e2e_Green "  DONE (resumed): $test_name")"
        return 0
    fi

    _E2E_SKIP_BLOCK=""
    _update_plan "$test_name" "RUNNING"
    _e2e_draw_line "-"
    _e2e_log_and_print "$(_e2e_cyan "TEST [$_E2E_TEST_COUNT]: $test_name")"
    _e2e_summary ""
    _e2e_summary "$(_e2e_Cyan "--- TEST [$_E2E_TEST_COUNT]: $test_name ---")"
}

test_end() {
    local result="${1:-0}"  # 0 = pass, non-zero = fail
    local test_name="$_E2E_CURRENT_TEST"

    # Bug 3 fix: if this test was skipped via resume, just clear state and return
    if [ -n "$_E2E_SKIP_BLOCK" ]; then
        _E2E_SKIP_BLOCK=""
        _E2E_CURRENT_TEST=""
        return 0
    fi

    if [ "$result" -eq 0 ]; then
        (( _E2E_PASS_COUNT++ )) || true
        _update_plan "$test_name" "PASS"
        _e2e_log_and_print "$(_e2e_green "  PASS: $test_name")"
        _e2e_summary "$(_e2e_Green "  PASS: $test_name")"
    else
        (( _E2E_FAIL_COUNT++ )) || true
        _update_plan "$test_name" "FAIL"
        _e2e_log_and_print "$(_e2e_red "  FAIL: $test_name")"
        _e2e_summary "$(_e2e_Red "  FAIL: $test_name")"
    fi

    _checkpoint_write "$test_name" "$result"
    _E2E_CURRENT_TEST=""
}

test_skip() {
    local test_name="${1:-$_E2E_CURRENT_TEST}"
    (( _E2E_SKIP_COUNT++ )) || true
    _update_plan "$test_name" "SKIP"
    _e2e_log_and_print "$(_e2e_yellow "  SKIP: $test_name")"
    _e2e_summary "$(_e2e_Yellow "  SKIP: $test_name")"
    _checkpoint_write "$test_name" "SKIP"
    _E2E_CURRENT_TEST=""
}

# Convenience: wrap a test name + body in begin/end
run_test() {
    local test_name="$1"; shift

    # Check checkpoint/resume -- skip if already passed
    if should_skip_checkpoint "$test_name"; then
        (( _E2E_TEST_COUNT++ )) || true
        _update_plan "$test_name" "DONE"
        _e2e_log_and_print "$(_e2e_green "  DONE (resumed): $test_name")"
        _e2e_summary "$(_e2e_Green "  DONE (resumed): $test_name")"
        return 0
    fi

    test_begin "$test_name"
    local rc=0
    eval "$@" || rc=$?
    test_end "$rc"
    return "$rc"
}

# --- Checkpoint / Resume ---------------------------------------------------

_checkpoint_write() {
    local test_name="$1" result="$2"
    if [ -n "$E2E_STATE_FILE" ]; then
        echo "$result $test_name" >> "$E2E_STATE_FILE"
    fi
}

should_skip_checkpoint() {
    local test_name="$1"
    # Only skip if we are in resume mode and test previously passed
    if [ -n "$E2E_RESUME_FILE" ] && [ -f "$E2E_RESUME_FILE" ]; then
        if grep -q "^0 ${test_name}$" "$E2E_RESUME_FILE"; then
            return 0  # yes, skip
        fi
    fi
    return 1  # no, don't skip
}

# --- Interactive Prompt -----------------------------------------------------

_interactive_prompt() {
    # Called when a command has failed and all retries are exhausted.
    # In interactive mode, prompt the user; otherwise, return 1 (fail).
    local cmd="$1"
    local ret="$2"

    if [ -z "$_E2E_INTERACTIVE" ]; then
        return 1  # non-interactive: just fail
    fi

    # Send notification about the failure
    (
        echo "Log tail:"
        tail -20 "${E2E_LOG_FILE:-/dev/null}" 2>/dev/null
    ) | _e2e_notify_stdin "Command failed: $cmd"

    while true; do
        echo ""
        _e2e_log_and_print "COMMAND FAILED ($(_e2e_exit_info $ret)): $cmd"
        printf "%s" "$(_e2e_red "[r] Retry  [s] Skip  [a] Abort  [or type a new command] > ")"
        read -r ans </dev/tty

        case "$ans" in
            r|R|"")
                _e2e_log "User chose: retry"
                return 2  # signal: retry
                ;;
            s|S)
                _e2e_log "User chose: skip"
                return 0  # signal: skip (success)
                ;;
            a|A)
                _e2e_log "User chose: abort"
                echo "Aborting."
                exit 1
                ;;
            *)
                # User typed a replacement command -- run it
                _e2e_log "User entered new command: $ans"
                echo "Running: $ans"
                ( eval "$ans" ) >> "${E2E_LOG_FILE:-/dev/null}" 2>&1
                local new_rc=$?
                if [ $new_rc -eq 0 ]; then
                    _e2e_log "User command succeeded"
                    return 0
                else
                    _e2e_log "User command failed (exit=$new_rc)"
                    echo "Command failed with exit code $new_rc"
                    # loop again to re-prompt
                fi
                ;;
        esac
    done
}

# Format an exit code for display: appends signal name for codes > 128.
#   _e2e_exit_info 141  =>  "exit=141/SIGPIPE"
#   _e2e_exit_info 1    =>  "exit=1"
_e2e_exit_info() {
    local rc="$1"
    if [ "$rc" -gt 128 ] 2>/dev/null; then
        local sig=$((rc - 128))
        local name
        name=$(kill -l "$sig" 2>/dev/null) || name=""
        if [ -n "$name" ]; then
            echo "exit=${rc}/SIG${name}"
            return
        fi
    fi
    echo "exit=${rc}"
}

# --- Core Execution: e2e_run -----------------------------------------------
#
# Usage: e2e_run [-r RETRIES BACKOFF] [-h HOST] [-i] [-q] "description" command...
#
# By default, command output is shown on screen AND logged to the suite log
# file (like the original test-cmd). Use -q to suppress screen output.
#
# Flags:
#   -r RETRIES BACKOFF   Retry on failure (default: 5 retries, 1.5x backoff)
#   -h HOST              Run command on remote HOST via SSH
#   -q                   Quiet: log output to file only (don't show on screen)
#   "description"        First non-flag argument = human-readable description
#   command...           Remaining arguments = the command to run
#
e2e_run() {
    # Bug 3 fix: skip commands inside a resumed test block
    if [ -n "$_E2E_SKIP_BLOCK" ]; then
        return 0
    fi

    local tot_cnt=5
    local backoff=1.5
    local host=""
    local quiet=""
    local mark="L"

    # Parse flags
    while [[ "${1:-}" == -* ]]; do
        case "$1" in
            -r) tot_cnt="$2"; backoff="$3"; shift 3 ;;
            -h) host="$2"; mark="R"; shift 2 ;;
            -q) quiet=1; shift ;;
            *)  break ;;
        esac
    done

    local description="$1"; shift
    local cmd="$*"
    local _lf="${E2E_LOG_FILE:-/dev/null}"

    local _display_host="${host:-$USER@$(hostname -s)}"

    _e2e_log_and_print "  $mark $(_e2e_green "$description") $(_e2e_yellow "[$_display_host:$PWD]")"
    _e2e_log_and_print "    $(_e2e_cyan "$cmd")"
    _e2e_summary "  $mark $(_e2e_Green "$description") $(_e2e_Yellow "[$_display_host:$PWD]")"
    _e2e_summary "    $(_e2e_Cyan "$cmd")"

    # Outer loop: interactive retry wraps the automatic retry loop
    while true; do
        local sleep_time=5
        local attempt=1

        # Inner loop: automatic retries with backoff
        while true; do
            local ret=0

            if [ -n "$host" ]; then
                _e2e_log "  Running on $host (attempt $attempt/$tot_cnt): $cmd"
                if [ -n "$quiet" ]; then
                    ssh -t -o LogLevel=ERROR "$host" -- ". \$HOME/.bash_profile 2>/dev/null; $cmd" \
                        >> "$_lf" 2>&1 || ret=$?
                else
                    # Use PIPESTATUS to capture ssh exit code, not tee's
                    ssh -o LogLevel=ERROR "$host" -- ". \$HOME/.bash_profile 2>/dev/null; $cmd" \
                        2>&1 | tee -a "$_lf"; ret=${PIPESTATUS[0]}
                fi
            else
                _e2e_log "  Running locally (attempt $attempt/$tot_cnt): $cmd"
                if [ -n "$quiet" ]; then
                    ( eval "$cmd" ) >> "$_lf" 2>&1 || ret=$?
                else
                    # Use PIPESTATUS to capture command exit code, not tee's
                    ( eval "$cmd" ) 2>&1 | tee -a "$_lf"; ret=${PIPESTATUS[0]}
                fi
            fi

            # Ctrl-C during execution
            [ $ret -eq 130 ] && return 130

            # Success
            if [ $ret -eq 0 ]; then
                if [ $attempt -gt 1 ]; then
                    _e2e_summary "    $(_e2e_Green "RECOVERED") on attempt $attempt: $description"
                    _e2e_notify "Command recovered: $description ($(date))"
                fi
                _e2e_log "  OK (attempt $attempt)"
                return 0
            fi

            local _exi; _exi="$(_e2e_exit_info $ret)"
            _e2e_log "  Attempt $attempt/$tot_cnt failed ($_exi)"
            _e2e_log_and_print "    $(_e2e_yellow "Attempt ($attempt/$tot_cnt) failed ($_exi): $description")"
            _e2e_summary "    $(_e2e_Yellow "Attempt ($attempt/$tot_cnt) failed ($_exi)") $description"

            # Exhausted retries?
            if [ $attempt -ge $tot_cnt ]; then
                _e2e_log "  All $tot_cnt attempts exhausted"
                _e2e_summary "    $(_e2e_Red "EXHAUSTED $tot_cnt attempts: $description")"
                break  # fall through to interactive prompt
            fi

            # Notify on first failure
            if [ $attempt -eq 1 ]; then
                (
                    echo "Command: $cmd"
                    echo "Host: ${host:-localhost}"
                    echo "Log tail:"
                    tail -20 "${E2E_LOG_FILE:-/dev/null}" 2>/dev/null
                ) | _e2e_notify_stdin "Attempt $attempt failed: $description"
            fi

            (( attempt++ ))
            echo "    Next attempt ($attempt/$tot_cnt) in ${sleep_time}s ..."
            sleep "$sleep_time"
            sleep_time=$(awk -v s="$sleep_time" -v b="$backoff" 'BEGIN {print int(s * b)}')
            [ "$sleep_time" -gt 40 ] && sleep_time=40
        done

        # All retries exhausted -- try interactive prompt
        _interactive_prompt "$cmd" "$ret"
        local prompt_rc=$?

        if [ $prompt_rc -eq 2 ]; then
            # User chose retry -- loop back to outer while
            _e2e_log "  Restarting retry cycle (user requested)"
            continue
        elif [ $prompt_rc -eq 0 ]; then
            # User chose skip or replacement command succeeded
            return 0
        else
            # Non-interactive failure or abort -- fail the current test and stop the suite
            local _exf; _exf="$(_e2e_exit_info $ret)"
            _e2e_log "  FAILED: $description ($_exf)"
            _e2e_log_and_print "  $(_e2e_red "FATAL: $description ($_exf) -- aborting suite")"
            _e2e_summary "    $(_e2e_Red "FATAL: $description ($_exf) -- aborting suite")"
            if [ -n "$_E2E_CURRENT_TEST" ]; then
                test_end "$ret"
            fi
            _e2e_notify "FATAL: $description ($_exf) -- suite aborted"
            exit 1
        fi
    done
}

# --- e2e_run_remote ---------------------------------------------------------
#
# Shorthand for e2e_run -h $INTERNAL_BASTION
# The INTERNAL_BASTION variable must be set by the suite or config.
#
e2e_run_remote() {
    [ -n "$_E2E_SKIP_BLOCK" ] && return 0
    if [ -z "${INTERNAL_BASTION:-}" ]; then
        _e2e_log_and_print "  $(_e2e_red "FATAL: INTERNAL_BASTION not set -- aborting suite")"
        exit 1
    fi
    e2e_run -h "$INTERNAL_BASTION" "$@"
}

# --- e2e_diag ---------------------------------------------------------------
#
# Run a DIAGNOSTIC command whose exit code does NOT affect the test outcome.
# Output is logged for troubleshooting, but the suite continues regardless of
# success or failure.  Use this ONLY for informational checks, never for steps
# that must succeed for the test to be valid.
#
# Flags:
#   -h HOST   Run on remote HOST via SSH
#
# Usage:
#   e2e_diag "Show firewalld status" "systemctl status firewalld"
#   e2e_diag -h "$host" "Check disk space" "df -h"
#
e2e_diag() {
    [ -n "$_E2E_SKIP_BLOCK" ] && return 0

    local host=""
    local mark="L"

    while [[ "${1:-}" == -* ]]; do
        case "$1" in
            -h) host="$2"; mark="R"; shift 2 ;;
            *)  break ;;
        esac
    done

    local description="$1"; shift
    local cmd="$*"
    local _lf="${E2E_LOG_FILE:-/dev/null}"
    local ret=0

    local _display_host="${host:-$USER@$(hostname -s)}"

    _e2e_log_and_print "  $mark $(_e2e_yellow "[diag]") $description $(_e2e_yellow "[$_display_host:$PWD]")"
    _e2e_log_and_print "    $(_e2e_cyan "$cmd")"

    if [ -n "$host" ]; then
        ssh -o LogLevel=ERROR "$host" -- ". \$HOME/.bash_profile 2>/dev/null; $cmd" \
            2>&1 | tee -a "$_lf"; ret=${PIPESTATUS[0]}
    else
        ( eval "$cmd" ) 2>&1 | tee -a "$_lf"; ret=${PIPESTATUS[0]}
    fi

    if [ $ret -ne 0 ]; then
        _e2e_log "  [diag] $description exited $ret (informational only)"
    fi

    return 0  # Always succeed -- this is diagnostic only
}

# Shorthand: e2e_diag on $INTERNAL_BASTION
e2e_diag_remote() {
    [ -n "$_E2E_SKIP_BLOCK" ] && return 0
    if [ -z "${INTERNAL_BASTION:-}" ]; then
        _e2e_log_and_print "  $(_e2e_red "FATAL: INTERNAL_BASTION not set -- aborting suite")"
        exit 1
    fi
    e2e_diag -h "$INTERNAL_BASTION" "$@"
}

# --- e2e_run_must_fail ------------------------------------------------------
#
# Assert that a command fails (non-zero exit). If the command succeeds, this
# is treated as a test failure.
#
# Usage: e2e_run_must_fail "description" command...
#
e2e_run_must_fail() {
    [ -n "$_E2E_SKIP_BLOCK" ] && return 0

    local description="$1"; shift
    local cmd="$*"

    _e2e_log_and_print "  L $description (expect failure) $(_e2e_yellow "[$USER@$(hostname -s):$PWD]")"
    _e2e_log_and_print "    $(_e2e_cyan "$cmd")"
    _e2e_log "    CMD (must-fail): $cmd"
    _e2e_summary "  L $(_e2e_Yellow "$description (expect failure)") $(_e2e_Yellow "[$USER@$(hostname -s):$PWD]")"
    _e2e_summary "    $(_e2e_Cyan "$cmd")"

    local ret=0
    ( eval "$cmd" ) >> "${E2E_LOG_FILE:-/dev/null}" 2>&1 || ret=$?

    if [ $ret -ne 0 ]; then
        _e2e_log "  OK: command failed as expected ($(_e2e_exit_info $ret))"
        _e2e_summary "    $(_e2e_Green "OK: failed as expected ($(_e2e_exit_info $ret))")"
        return 0
    else
        _e2e_log_and_print "    $(_e2e_red "EXPECTED FAILURE but command succeeded: $description")"
        _e2e_summary "    $(_e2e_Red "UNEXPECTED SUCCESS: $description -- aborting suite")"
        if [ -n "$_E2E_CURRENT_TEST" ]; then
            test_end 1
        fi
        exit 1
    fi
}

# --- e2e_run_must_fail_remote -----------------------------------------------
#
# Like e2e_run_must_fail but runs on INTERNAL_BASTION
#
e2e_run_must_fail_remote() {
    [ -n "$_E2E_SKIP_BLOCK" ] && return 0

    local description="$1"; shift
    local cmd="$*"

    if [ -z "${INTERNAL_BASTION:-}" ]; then
        _e2e_log_and_print "  $(_e2e_red "FATAL: INTERNAL_BASTION not set -- aborting suite")"
        exit 1
    fi

    _e2e_draw_line "."
    _e2e_log_and_print "  R $description (expect failure)"
    _e2e_log_and_print "    $(_e2e_cyan "($cmd)")"
    _e2e_log "    CMD (must-fail on $INTERNAL_BASTION): $cmd"
    _e2e_summary "  R $(_e2e_Yellow "$description (expect failure)")"
    _e2e_summary "    $(_e2e_Cyan "($cmd)")"

    local ret=0
    ssh -t -o LogLevel=ERROR "$INTERNAL_BASTION" -- \
        ". \$HOME/.bash_profile 2>/dev/null; $cmd" \
        >> "${E2E_LOG_FILE:-/dev/null}" 2>&1 || ret=$?

    if [ $ret -ne 0 ]; then
        _e2e_log "  OK: command failed as expected ($(_e2e_exit_info $ret))"
        _e2e_summary "    $(_e2e_Green "OK: failed as expected ($(_e2e_exit_info $ret))")"
        return 0
    else
        _e2e_log_and_print "    $(_e2e_red "EXPECTED FAILURE but command succeeded: $description")"
        _e2e_summary "    $(_e2e_Red "UNEXPECTED SUCCESS: $description -- aborting suite")"
        if [ -n "$_E2E_CURRENT_TEST" ]; then
            test_end 1
        fi
        exit 1
    fi
}

# --- Assertions -------------------------------------------------------------
#
# All assertions abort the suite on failure -- tests must not silently continue
# past a failed check (rule #1: let them fail).

_assert_fail() {
    local msg="$1"
    _e2e_log_and_print "    $(_e2e_red "ASSERT FAIL: $msg")"
    _e2e_summary "    $(_e2e_Red "ASSERT FAIL: $msg -- aborting suite")"
    if [ -n "${_E2E_CURRENT_TEST:-}" ]; then
        test_end 1
    fi
    exit 1
}

assert_file_exists() {
    local file="$1"
    local msg="${2:-File should exist: $file}"
    if [ -f "$file" ]; then
        _e2e_log "  ASSERT OK: file exists: $file"
    else
        _assert_fail "$msg"
    fi
}

assert_dir_exists() {
    local dir="$1"
    local msg="${2:-Directory should exist: $dir}"
    if [ -d "$dir" ]; then
        _e2e_log "  ASSERT OK: dir exists: $dir"
    else
        _assert_fail "$msg"
    fi
}

assert_file_not_exists() {
    local file="$1"
    local msg="${2:-File should not exist: $file}"
    if [ ! -f "$file" ]; then
        _e2e_log "  ASSERT OK: file does not exist: $file"
    else
        _assert_fail "$msg"
    fi
}

assert_contains() {
    local file="$1"
    local pattern="$2"
    local msg="${3:-File $file should contain: $pattern}"
    if [ ! -f "$file" ]; then
        _assert_fail "File does not exist: $file (expected to contain: $pattern)"
        return
    fi
    if grep -q "$pattern" "$file"; then
        _e2e_log "  ASSERT OK: '$pattern' found in $file"
    else
        _assert_fail "$msg"
    fi
}

assert_not_contains() {
    local file="$1"
    local pattern="$2"
    local msg="${3:-File $file should NOT contain: $pattern}"
    if [ ! -f "$file" ]; then
        _assert_fail "File does not exist: $file (checking for absence of: $pattern)"
        return
    fi
    if ! grep -q "$pattern" "$file"; then
        _e2e_log "  ASSERT OK: '$pattern' not found in $file (expected)"
    else
        _assert_fail "$msg"
    fi
}

assert_eq() {
    local actual="$1"
    local expected="$2"
    local msg="${3:-Expected '$expected', got '$actual'}"
    if [ "$actual" = "$expected" ]; then
        _e2e_log "  ASSERT OK: '$actual' == '$expected'"
    else
        _assert_fail "$msg"
    fi
}

assert_ne() {
    local actual="$1"
    local unexpected="$2"
    local msg="${3:-Expected NOT '$unexpected', but got it}"
    if [ "$actual" != "$unexpected" ]; then
        _e2e_log "  ASSERT OK: '$actual' != '$unexpected'"
    else
        _assert_fail "$msg"
    fi
}

assert_command_exists() {
    local cmd_name="$1"
    local msg="${2:-Command should exist: $cmd_name}"
    if command -v "$cmd_name" &>/dev/null; then
        _e2e_log "  ASSERT OK: command exists: $cmd_name"
    else
        _assert_fail "$msg"
    fi
}

# --- YAML helpers -----------------------------------------------------------

# Normalize a YAML file (sort-free pretty-print) and write to stdout.
# Optionally strips secrets/environment-specific fields from install-config.
#   Usage: yaml_normalize FILE [--strip-secrets]
yaml_normalize() {
    local file="$1" strip="${2:-}"
    if [ "$strip" = "--strip-secrets" ]; then
        python3 -c "
import yaml, sys
d = yaml.safe_load(open('$file'))
for k in ('additionalTrustBundle', 'pullSecret'):
    d.pop(k, None)
vs = d.get('platform', {}).get('vsphere', {})
for vc in vs.get('vcenters', []):
    vc.pop('password', None)
fds = vs.get('failureDomains', [])
if fds:
    for k in ('name', 'region', 'zone'):
        fds[0].pop(k, None)
    fds[0].get('topology', {}).pop('datastore', None)
yaml.dump(d, sys.stdout, default_flow_style=False, sort_keys=False)
"
    else
        python3 -c "
import yaml, sys
yaml.dump(yaml.safe_load(open('$file')), sys.stdout, default_flow_style=False, sort_keys=False)
"
    fi
}

# Diff two YAML files after normalizing.  Returns non-zero on differences.
#   Usage: yaml_diff FILE_A FILE_B [--strip-secrets]
yaml_diff() {
    local file_a="$1" file_b="$2" strip="${3:-}"
    diff <(yaml_normalize "$file_a" $strip) <(yaml_normalize "$file_b" $strip)
}

# --- Guards -----------------------------------------------------------------

require_cluster() {
    local cluster_dir="${1:-.}"
    if [ ! -f "$cluster_dir/kubeconfig" ] && [ ! -f "$cluster_dir/auth/kubeconfig" ]; then
        _e2e_log_and_print "  $(_e2e_yellow "GUARD: No kubeconfig found in $cluster_dir -- skipping")"
        return 1
    fi
    return 0
}

require_mirror() {
    if [ ! -d "mirror" ]; then
        _e2e_log_and_print "  $(_e2e_yellow "GUARD: No mirror directory -- skipping")"
        return 1
    fi
    return 0
}

require_ssh() {
    local host="$1"
    if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$host" true 2>/dev/null; then
        _e2e_log_and_print "  $(_e2e_yellow "GUARD: Cannot SSH to $host -- skipping")"
        return 1
    fi
    return 0
}

# Pre-flight SSH connectivity check.  Call at the top of any suite that
# relies on a remote bastion (INTERNAL_BASTION).  Verifies all three
# identities (default user, root, testy) so key mismatches are caught
# before the suite wastes time.
#
# Usage: preflight_ssh           (uses $INTERNAL_BASTION)
#        preflight_ssh HOST      (explicit host)
#
preflight_ssh() {
    local host="${1:-${INTERNAL_BASTION:-}}"
    if [ -z "$host" ]; then
        _e2e_log_and_print "  $(_e2e_Red "PREFLIGHT FAIL: INTERNAL_BASTION not set")"
        exit 1
    fi

    # For root@ and testy@ checks we need host-only (INTERNAL_BASTION is user@host)
    local host_only="${host#*@}"

    local _ssh_opts="-o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
    local _fail=""

    _e2e_log "  Preflight: checking SSH to $host (default user) ..."
    if ! ssh $_ssh_opts "$host" true 2>/dev/null; then
        _e2e_log_and_print "  $(_e2e_Red "PREFLIGHT FAIL: Cannot SSH to $host (default user)")"
        _fail=1
    else
        _e2e_log "  Preflight: SSH to $host (default user) OK"
    fi

    _e2e_log "  Preflight: checking SSH to root@$host_only ..."
    if ! ssh $_ssh_opts "root@$host_only" true 2>/dev/null; then
        _e2e_log_and_print "  $(_e2e_Red "PREFLIGHT FAIL: Cannot SSH to root@$host_only")"
        _fail=1
    else
        _e2e_log "  Preflight: SSH to root@$host_only OK"
    fi

    _e2e_log "  Preflight: checking SSH to testy@$host_only (testy_rsa) ..."
    if ! ssh $_ssh_opts -i ~/.ssh/testy_rsa "testy@$host_only" true 2>/dev/null; then
        _e2e_log_and_print "  $(_e2e_Red "PREFLIGHT FAIL: Cannot SSH to testy@$host_only with testy_rsa")"
        _fail=1
    else
        _e2e_log "  Preflight: SSH to testy@$host_only (testy_rsa) OK"
    fi

    if [ -n "$_fail" ]; then
        _e2e_log_and_print "  $(_e2e_Red "Aborting suite -- SSH preflight failed for $host.")"
        _e2e_notify "PREFLIGHT FAIL: SSH check failed for $host -- suite aborted"
        exit 1
    fi
}

require_govc() {
    if ! command -v govc &>/dev/null; then
        _e2e_log_and_print "  $(_e2e_yellow "GUARD: govc not found -- skipping")"
        return 1
    fi
    return 0
}

require_var() {
    local var_name="$1"
    if [ -z "${!var_name:-}" ]; then
        _e2e_log_and_print "  $(_e2e_yellow "GUARD: $var_name is not set -- skipping")"
        return 1
    fi
    return 0
}

# --- SSH config ownership fix -----------------------------------------------
# OpenSSH refuses to use system config files not owned by root (exit 255).
# Container/sandbox environments sometimes map /etc as nobody:nobody.
# This fix is idempotent and only runs sudo when needed.
_e2e_fix_ssh_config_ownership() {
    local dir="/etc/ssh/ssh_config.d"
    [ -d "$dir" ] || return 0
    local needs_fix=""
    for f in "$dir" "$dir"/*.conf; do
        [ -e "$f" ] || continue
        if [ "$(stat -c '%u' "$f" 2>/dev/null)" != "0" ]; then
            needs_fix=1
            break
        fi
    done
    if [ -n "$needs_fix" ]; then
        echo "  Fixing SSH config ownership in $dir ..."
        sudo chown root:root "$dir" 2>/dev/null || true
        sudo chmod 755 "$dir" 2>/dev/null || true
        for f in "$dir"/*.conf; do
            [ -f "$f" ] || continue
            sudo chown root:root "$f" 2>/dev/null || true
            sudo chmod 644 "$f" 2>/dev/null || true
        done
    fi
}

# --- Environment Setup (called by run.sh or suites directly) ---------------

e2e_setup() {
    # Navigate to aba root
    local aba_root
    aba_root="$(cd "$_E2E_DIR/../.." && pwd)"
    cd "$aba_root" || { echo "Cannot cd to $aba_root"; exit 1; }

    export ABA_TESTING=1
    hash -r  # Forget cached command paths

    # Fix SSH config ownership -- RHEL/Fedora ssh_config.d files must be root:root
    # or SSH refuses to run (exit 255). Container/sandbox environments sometimes
    # reset ownership to nobody:nobody.
    _e2e_fix_ssh_config_ownership

    # Load config.env defaults (if it exists)
    # Source it directly so declare -A and multi-line constructs work.
    if [ -f "$_E2E_DIR/config.env" ]; then
        source "$_E2E_DIR/config.env"
    fi

    # Source aba's own include files if available
    if [ -f "scripts/include_all.sh" ]; then
        source scripts/include_all.sh no-trap
    fi

    # Log git state so we know exactly what was tested
    local _git_head _git_dirty
    _git_head="$(git -C "$aba_root" log -1 --format='%h %s' 2>/dev/null || echo 'unknown')"
    _git_dirty="$(git -C "$aba_root" status --porcelain 2>/dev/null | head -20)"

    _e2e_log "=== E2E Environment ==="
    _e2e_log "  ABA_ROOT=$aba_root"
    _e2e_log "  GIT_HEAD=$_git_head"
    if [ -n "$_git_dirty" ]; then
        _e2e_log "  GIT_STATE=DIRTY (uncommitted changes):"
        while IFS= read -r _line; do
            _e2e_log "    $_line"
        done <<< "$_git_dirty"
    else
        _e2e_log "  GIT_STATE=clean"
    fi
    _e2e_log "  TEST_CHANNEL=${TEST_CHANNEL:-unset}"
    _e2e_log "  OCP_VERSION=${OCP_VERSION:-unset}"
    _e2e_log "  INT_BASTION_RHEL_VER=${INT_BASTION_RHEL_VER:-unset}"
    _e2e_log "  DIS_SSH_USER=${DIS_SSH_USER:-unset}"
    _e2e_log "  OC_MIRROR_VER=${OC_MIRROR_VER:-unset}"
    _e2e_log "  NOTIFY_CMD=${NOTIFY_CMD:-disabled}"
    _e2e_log "  _E2E_INTERACTIVE=${_E2E_INTERACTIVE:-off}"
}

e2e_teardown() {
    _e2e_log "=== E2E Teardown ==="
    _e2e_log "  Log file: $E2E_LOG_FILE"

    # Print final summary if suite was started
    if [ -n "$_E2E_SUITE_NAME" ]; then
        suite_end || true
    fi
}
