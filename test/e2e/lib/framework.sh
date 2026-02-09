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
E2E_RESUME_FILE=""     # If set, skip tests already passed in a previous run

# Log file for the current suite run
E2E_LOG_DIR="${_E2E_DIR}/logs"
E2E_LOG_FILE=""

# Current suite / test tracking
_E2E_SUITE_NAME=""
_E2E_CURRENT_TEST=""
_E2E_TEST_COUNT=0
_E2E_PASS_COUNT=0
_E2E_FAIL_COUNT=0
_E2E_SKIP_COUNT=0
_E2E_START_TIME=""

# Progress plan -- parallel arrays
declare -a _E2E_PLAN_NAMES=()
declare -a _E2E_PLAN_STATUS=()  # PENDING | RUNNING | PASS | FAIL | SKIP | DONE

# --- Color helpers ----------------------------------------------------------

_e2e_color() {
    local code="$1"; shift
    if [ -t 1 ] && [ "${TERM:-}" ]; then
        printf '\033[%sm%s\033[0m' "$code" "$*"
    else
        printf '%s' "$*"
    fi
}

_e2e_red()    { _e2e_color "0;31" "$@"; }
_e2e_green()  { _e2e_color "0;32" "$@"; }
_e2e_yellow() { _e2e_color "0;33" "$@"; }
_e2e_cyan()   { _e2e_color "0;36" "$@"; }
_e2e_bold()   { _e2e_color "1"    "$@"; }

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

# --- Notification -----------------------------------------------------------

_e2e_notify() {
    if [ -n "$NOTIFY_CMD" ]; then
        echo "$@" | $NOTIFY_CMD "$@" 2>/dev/null || true
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

    echo ""
    _e2e_draw_line "="
    printf "  %-50s %s\n" "TEST" "STATUS"
    _e2e_draw_line "-"

    local i status_str
    for i in "${!_E2E_PLAN_NAMES[@]}"; do
        case "${_E2E_PLAN_STATUS[$i]}" in
            PASS)    status_str="$(_e2e_green "PASS")" ;;
            FAIL)    status_str="$(_e2e_red "FAIL")" ;;
            SKIP)    status_str="$(_e2e_yellow "SKIP")" ;;
            RUNNING) status_str="$(_e2e_cyan "RUNNING...")" ;;
            DONE)    status_str="$(_e2e_green "DONE (resumed)")" ;;
            *)       status_str="  --" ;;
        esac
        printf "  %-50s %s\n" "${_E2E_PLAN_NAMES[$i]}" "$status_str"
    done

    _e2e_draw_line "="
    echo ""
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

    # Set up log file
    mkdir -p "$E2E_LOG_DIR"
    E2E_LOG_FILE="${E2E_LOG_DIR}/${suite_name}-$(date +%Y%m%d-%H%M%S).log"

    # Initialize state file for checkpointing
    E2E_STATE_FILE="${E2E_LOG_DIR}/${suite_name}.state"
    : > "$E2E_STATE_FILE"

    _e2e_draw_line "="
    _e2e_log_and_print "$(_e2e_bold "SUITE: $suite_name")"
    _e2e_draw_line "="
    _e2e_notify "Suite started: $suite_name ($(date))"
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
        _e2e_notify "FAILED: $_E2E_SUITE_NAME -- $_E2E_FAIL_COUNT failures ($(date))"
        return 1
    else
        _e2e_notify "PASSED: $_E2E_SUITE_NAME -- $_E2E_PASS_COUNT passed (${mins}m ${secs}s)"
        return 0
    fi
}

# --- Test Lifecycle ---------------------------------------------------------

test_begin() {
    local test_name="$1"
    _E2E_CURRENT_TEST="$test_name"
    (( _E2E_TEST_COUNT++ )) || true

    _update_plan "$test_name" "RUNNING"
    _e2e_draw_line "-"
    _e2e_log_and_print "$(_e2e_cyan "TEST [$_E2E_TEST_COUNT]: $test_name")"
}

test_end() {
    local result="${1:-0}"  # 0 = pass, non-zero = fail
    local test_name="$_E2E_CURRENT_TEST"

    if [ "$result" -eq 0 ]; then
        (( _E2E_PASS_COUNT++ )) || true
        _update_plan "$test_name" "PASS"
        _e2e_log_and_print "$(_e2e_green "  PASS: $test_name")"
    else
        (( _E2E_FAIL_COUNT++ )) || true
        _update_plan "$test_name" "FAIL"
        _e2e_log_and_print "$(_e2e_red "  FAIL: $test_name")"
    fi

    _checkpoint_write "$test_name" "$result"
    _E2E_CURRENT_TEST=""
}

test_skip() {
    local test_name="${1:-$_E2E_CURRENT_TEST}"
    (( _E2E_SKIP_COUNT++ )) || true
    _update_plan "$test_name" "SKIP"
    _e2e_log_and_print "$(_e2e_yellow "  SKIP: $test_name")"
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
        if grep -q "^0 ${test_name}$" "$E2E_RESUME_FILE" 2>/dev/null; then
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
        _e2e_log_and_print "COMMAND FAILED (exit=$ret): $cmd"
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
#   -i                   Ignore result (return actual exit code, don't fail suite)
#   -q                   Quiet: log output to file only (don't show on screen)
#   "description"        First non-flag argument = human-readable description
#   command...           Remaining arguments = the command to run
#
e2e_run() {
    local tot_cnt=5
    local backoff=1.5
    local host=""
    local ignore_result=""
    local quiet=""
    local mark="L"

    # Parse flags
    while [[ "${1:-}" == -* ]]; do
        case "$1" in
            -r) tot_cnt="$2"; backoff="$3"; shift 3 ;;
            -h) host="$2"; mark="R"; shift 2 ;;
            -i) ignore_result=1; shift ;;
            -q) quiet=1; shift ;;
            *)  break ;;
        esac
    done

    local description="$1"; shift
    local cmd="$*"
    local _lf="${E2E_LOG_FILE:-/dev/null}"

    _e2e_draw_line "."
    _e2e_log_and_print "  $mark $(_e2e_green "$description") $(_e2e_cyan "($cmd)") $(_e2e_yellow "[$PWD -> ${host:-localhost}]")"

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
                    ssh -o LogLevel=ERROR "$host" -- ". \$HOME/.bash_profile 2>/dev/null; $cmd" \
                        2>&1 | tee -a "$_lf" || ret=$?
                fi
            else
                _e2e_log "  Running locally (attempt $attempt/$tot_cnt): $cmd"
                if [ -n "$quiet" ]; then
                    ( eval "$cmd" ) >> "$_lf" 2>&1 || ret=$?
                else
                    ( eval "$cmd" ) 2>&1 | tee -a "$_lf" || ret=$?
                fi
            fi

            # Ctrl-C during execution
            [ $ret -eq 130 ] && return 130

            # Success
            if [ $ret -eq 0 ]; then
                if [ $attempt -gt 1 ]; then
                    _e2e_notify "Command recovered: $description ($(date))"
                fi
                _e2e_log "  OK (attempt $attempt)"
                return 0
            fi

            # Ignore result mode: return actual exit code
            if [ -n "$ignore_result" ]; then
                _e2e_log "  Failed (exit=$ret), returning actual result (-i flag)"
                return $ret
            fi

            _e2e_log "  Attempt $attempt/$tot_cnt failed (exit=$ret)"
            _e2e_log_and_print "    $(_e2e_yellow "Attempt ($attempt/$tot_cnt) failed (exit=$ret): $description")"

            # Exhausted retries?
            if [ $attempt -ge $tot_cnt ]; then
                _e2e_log "  All $tot_cnt attempts exhausted"
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
            # Non-interactive failure or abort
            _e2e_log "  FAILED: $description (exit=$ret)"
            return $ret
        fi
    done
}

# --- e2e_run_remote ---------------------------------------------------------
#
# Shorthand for e2e_run -h $INTERNAL_BASTION
# The INTERNAL_BASTION variable must be set by the suite or config.
#
e2e_run_remote() {
    if [ -z "${INTERNAL_BASTION:-}" ]; then
        echo "ERROR: INTERNAL_BASTION not set. Cannot run remote command." >&2
        return 1
    fi
    e2e_run -h "$INTERNAL_BASTION" "$@"
}

# --- e2e_run_must_fail ------------------------------------------------------
#
# Assert that a command fails (non-zero exit). If the command succeeds, this
# is treated as a test failure.
#
# Usage: e2e_run_must_fail "description" command...
#
e2e_run_must_fail() {
    local description="$1"; shift
    local cmd="$*"

    _e2e_draw_line "."
    _e2e_log_and_print "  L $description (expect failure)"
    _e2e_log "    CMD (must-fail): $cmd"

    local ret=0
    ( eval "$cmd" ) >> "${E2E_LOG_FILE:-/dev/null}" 2>&1 || ret=$?

    if [ $ret -ne 0 ]; then
        _e2e_log "  OK: command failed as expected (exit=$ret)"
        return 0
    else
        _e2e_log_and_print "    $(_e2e_red "EXPECTED FAILURE but command succeeded: $description")"
        return 1
    fi
}

# --- e2e_run_must_fail_remote -----------------------------------------------
#
# Like e2e_run_must_fail but runs on INTERNAL_BASTION
#
e2e_run_must_fail_remote() {
    local description="$1"; shift
    local cmd="$*"

    if [ -z "${INTERNAL_BASTION:-}" ]; then
        echo "ERROR: INTERNAL_BASTION not set." >&2
        return 1
    fi

    _e2e_draw_line "."
    _e2e_log_and_print "  R $description (expect failure)"
    _e2e_log "    CMD (must-fail on $INTERNAL_BASTION): $cmd"

    local ret=0
    ssh -t -o LogLevel=ERROR "$INTERNAL_BASTION" -- \
        ". \$HOME/.bash_profile 2>/dev/null; $cmd" \
        >> "${E2E_LOG_FILE:-/dev/null}" 2>&1 || ret=$?

    if [ $ret -ne 0 ]; then
        _e2e_log "  OK: command failed as expected (exit=$ret)"
        return 0
    else
        _e2e_log_and_print "    $(_e2e_red "EXPECTED FAILURE but command succeeded: $description")"
        return 1
    fi
}

# --- Assertions -------------------------------------------------------------

assert_file_exists() {
    local file="$1"
    local msg="${2:-File should exist: $file}"
    if [ -f "$file" ]; then
        _e2e_log "  ASSERT OK: file exists: $file"
        return 0
    else
        _e2e_log_and_print "    $(_e2e_red "ASSERT FAIL: $msg")"
        return 1
    fi
}

assert_dir_exists() {
    local dir="$1"
    local msg="${2:-Directory should exist: $dir}"
    if [ -d "$dir" ]; then
        _e2e_log "  ASSERT OK: dir exists: $dir"
        return 0
    else
        _e2e_log_and_print "    $(_e2e_red "ASSERT FAIL: $msg")"
        return 1
    fi
}

assert_file_not_exists() {
    local file="$1"
    local msg="${2:-File should not exist: $file}"
    if [ ! -f "$file" ]; then
        _e2e_log "  ASSERT OK: file does not exist: $file"
        return 0
    else
        _e2e_log_and_print "    $(_e2e_red "ASSERT FAIL: $msg")"
        return 1
    fi
}

assert_contains() {
    local file="$1"
    local pattern="$2"
    local msg="${3:-File $file should contain: $pattern}"
    if grep -q "$pattern" "$file" 2>/dev/null; then
        _e2e_log "  ASSERT OK: '$pattern' found in $file"
        return 0
    else
        _e2e_log_and_print "    $(_e2e_red "ASSERT FAIL: $msg")"
        return 1
    fi
}

assert_not_contains() {
    local file="$1"
    local pattern="$2"
    local msg="${3:-File $file should NOT contain: $pattern}"
    if ! grep -q "$pattern" "$file" 2>/dev/null; then
        _e2e_log "  ASSERT OK: '$pattern' not found in $file (expected)"
        return 0
    else
        _e2e_log_and_print "    $(_e2e_red "ASSERT FAIL: $msg")"
        return 1
    fi
}

assert_eq() {
    local actual="$1"
    local expected="$2"
    local msg="${3:-Expected '$expected', got '$actual'}"
    if [ "$actual" = "$expected" ]; then
        _e2e_log "  ASSERT OK: '$actual' == '$expected'"
        return 0
    else
        _e2e_log_and_print "    $(_e2e_red "ASSERT FAIL: $msg")"
        return 1
    fi
}

assert_ne() {
    local actual="$1"
    local unexpected="$2"
    local msg="${3:-Expected NOT '$unexpected', but got it}"
    if [ "$actual" != "$unexpected" ]; then
        _e2e_log "  ASSERT OK: '$actual' != '$unexpected'"
        return 0
    else
        _e2e_log_and_print "    $(_e2e_red "ASSERT FAIL: $msg")"
        return 1
    fi
}

assert_command_exists() {
    local cmd_name="$1"
    local msg="${2:-Command should exist: $cmd_name}"
    if command -v "$cmd_name" &>/dev/null; then
        _e2e_log "  ASSERT OK: command exists: $cmd_name"
        return 0
    else
        _e2e_log_and_print "    $(_e2e_red "ASSERT FAIL: $msg")"
        return 1
    fi
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

# --- Environment Setup (called by run.sh or suites directly) ---------------

e2e_setup() {
    # Navigate to aba root
    local aba_root
    aba_root="$(cd "$_E2E_DIR/../.." && pwd)"
    cd "$aba_root" || { echo "Cannot cd to $aba_root"; exit 1; }

    export ABA_TESTING=1
    hash -r  # Forget cached command paths

    # Load config.env defaults (if it exists)
    if [ -f "$_E2E_DIR/config.env" ]; then
        # Source config.env, but don't overwrite variables already set (by CLI or pool overrides)
        set -a
        while IFS='=' read -r key val; do
            # Skip comments and empty lines
            [[ "$key" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$key" ]] && continue
            key=$(echo "$key" | xargs)  # trim whitespace
            # Only set if not already defined
            if [ -z "${!key+x}" ]; then
                eval "export $key=$val"
            fi
        done < "$_E2E_DIR/config.env"
        set +a
    fi

    # Source aba's own include files if available
    if [ -f "scripts/include_all.sh" ]; then
        source scripts/include_all.sh no-trap 2>/dev/null || true
    fi

    # Log the active parameter set
    _e2e_log "=== E2E Environment ==="
    _e2e_log "  ABA_ROOT=$aba_root"
    _e2e_log "  TEST_CHANNEL=${TEST_CHANNEL:-unset}"
    _e2e_log "  VER_OVERRIDE=${VER_OVERRIDE:-unset}"
    _e2e_log "  INTERNAL_BASTION_RHEL_VER=${INTERNAL_BASTION_RHEL_VER:-unset}"
    _e2e_log "  TEST_USER=${TEST_USER:-unset}"
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
