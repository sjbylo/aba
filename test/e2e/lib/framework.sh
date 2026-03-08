#!/usr/bin/env bash
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
# 10b. disN has NO INTERNET by design.
#      All artifacts (images, tarballs, CLI tools) must arrive via the ABA
#      bundle transfer from conN.  If something is missing on disN, the
#      bundle creation failed -- never try to fetch from the internet.
#
# ===========================  TEST HYGIENE  =================================
#
# 10c. Tests MUST NEVER create ABA-internal or ABA-generated files directly.
#      Use 'aba' or 'make' targets to generate files.  Exception: creating a
#      minimal/custom config that has no aba/make equivalent (must have comment).
#
# 10d. Tests MUST NEVER call ABA-internal functions directly
#      (e.g. run_once(), download_all_catalogs()).  Use 'aba' CLI or 'make'.
#
# 10e. Tests MUST NOT use 'aba reset' as a mid-process cleanup mechanism.
#      Only use when a 100% fresh repo is needed (e.g. setup_aba_from_scratch)
#      or for dedicated reset regression tests.  For mid-process cleanup use
#      'aba clean', 'aba uninstall', or 'aba delete'.
#
# ===========================  RESOURCE LIFECYCLE  ===========================
#
# 11. A suite ALWAYS cleans up the resources it created (clusters AND mirrors).
#     Before suite_end, explicitly:
#       - SNO clusters: DELETE (free resources for other suites)
#       - Compact / Standard clusters: DELETE (large, hold VIPs)
#       - Mirrors on disN: uninstall
#     Do not rely on external cleanup or snapshot revert.
#
# 12. A suite NEVER installs a resource and leaves it for another suite.
#     Each suite is self-contained: create, test, destroy.
#
# 13. Only the OOB (out-of-band) pre-populated registry may be shared
#     across suites.  It is managed by setup-pool-registry.sh, NOT suites.
#     Suites must NEVER register or uninstall the OOB registry.
#
# 14. Add every cluster (e2e_add_to_cluster_cleanup) and mirror
#     (e2e_add_to_mirror_cleanup) to the cleanup list immediately before the install command.
#     This enables crash recovery: runner.sh _pre_suite_cleanup iterates
#     ALL leftover .cleanup/.mirror-cleanup files before the next suite.
#
# 15. Every suite that creates clusters or mirrors MUST have an explicit
#     test_begin "Cleanup: ..." block at the end that runs aba delete /
#     aba uninstall / aba unregister for every resource created.  The EXIT
#     trap and _pre_suite_cleanup are safety nets for crashes -- they are
#     NOT the primary cleanup path.  Explicit cleanup also serves as a
#     test of aba delete, aba uninstall, and aba unregister.
#
# ============================================================================

# Resolve the directory this library lives in
_E2E_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_E2E_DIR="$(cd "$_E2E_LIB_DIR/.." && pwd)"

source "$_E2E_LIB_DIR/constants.sh"

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

# Skip-suite flag: when set, ALL remaining test blocks and e2e_run calls are no-ops
_E2E_SUITE_SKIPPED=""

# User-skip flag: set when user picks [s]kip from interactive menu; test_end records SKIP
_E2E_USER_SKIPPED=""

# Progress plan -- parallel arrays
declare -a _E2E_PLAN_NAMES=()
declare -a _E2E_PLAN_STATUS=()  # PENDING | RUNNING | PASS | FAIL | SKIP | DONE

# --- Duration formatting ----------------------------------------------------

_e2e_fmt_duration() {
	local secs=$1
	if [ $secs -ge 3600 ]; then
		printf '%dh %dm %ds' $((secs/3600)) $((secs%3600/60)) $((secs%60))
	elif [ $secs -ge 60 ]; then
		printf '%dm %ds' $((secs/60)) $((secs%60))
	else
		printf '%ds' "$secs"
	fi
}

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
# All notifications:
#   - Prefixed with [e2e] for easy filtering
#   - Include pool number and hostname (never "localhost")
#   - Failure notifications include last ~20 lines of suite log for context

_e2e_notify_suffix() {
    echo "(pool${POOL_NUM:-?}/$(hostname -s))"
}

_e2e_notify() {
    if [ -n "$NOTIFY_CMD" ]; then
        $NOTIFY_CMD "[e2e] $* $(_e2e_notify_suffix)" < /dev/null >/dev/null 2>&1
    fi
}

_e2e_notify_stdin() {
    local subject="$1"
    if [ -n "$NOTIFY_CMD" ]; then
        $NOTIFY_CMD "[e2e] $subject $(_e2e_notify_suffix)" >/dev/null 2>&1
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

    # State file for checkpoint/resume. Caller may set E2E_STATE_FILE for a per-run path
    # (e.g. clone-and-check.pool2.state) so multiple runs don't share one file.
    E2E_STATE_FILE="${E2E_STATE_FILE:-${E2E_LOG_DIR}/${suite_name}.state}"

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
}

suite_end() {
    local elapsed=$(( $(date +%s) - _E2E_START_TIME ))
    local mins=$(( elapsed / 60 ))
    local secs=$(( elapsed % 60 ))
    local _total_dur; _total_dur=$(_e2e_fmt_duration $elapsed)

    echo ""
    _e2e_draw_line "="
    _e2e_log_and_print "SUITE COMPLETE: $_E2E_SUITE_NAME"
    _e2e_log_and_print "  Total: $_E2E_TEST_COUNT  Pass: $_E2E_PASS_COUNT  Fail: $_E2E_FAIL_COUNT  Skip: $_E2E_SKIP_COUNT"
    _e2e_log_and_print "  Duration: $_total_dur"
    _e2e_draw_line "="

    _print_progress

    if [ "$_E2E_FAIL_COUNT" -gt 0 ]; then
        _e2e_summary "$(_e2e_Red "========== FAILED: $_E2E_SUITE_NAME  (${_E2E_FAIL_COUNT} failures, $_total_dur) ==========")"
        # #region agent log
        printf '{"sessionId":"23cf03","hypothesisId":"H2","location":"framework.sh:finalize_suite:FAIL","message":"about to send suite FAIL notification","data":{"suite":"%s","fail_count":%d,"NOTIFY_CMD":"%s"},"timestamp":%s}\n' \
            "$_E2E_SUITE_NAME" "$_E2E_FAIL_COUNT" "${NOTIFY_CMD:-EMPTY}" "$(date +%s%3N)" >> /tmp/e2e-debug-23cf03.log 2>/dev/null
        # #endregion
        _e2e_notify "FAILED: $_E2E_SUITE_NAME -- ${_E2E_FAIL_COUNT} failures ($_total_dur)"
        return 1
    else
        _e2e_summary "$(_e2e_Green "========== PASSED: $_E2E_SUITE_NAME  (${_E2E_PASS_COUNT} passed, $_total_dur) ==========")"
        _e2e_notify "PASSED: $_E2E_SUITE_NAME -- ${_E2E_PASS_COUNT} tests ($_total_dur)"
        return 0
    fi
}

# --- Test Lifecycle ---------------------------------------------------------

test_begin() {
    local test_name="$1"
    _E2E_CURRENT_TEST="$test_name"
    (( _E2E_TEST_COUNT++ )) || true

    # If suite was skipped via interactive prompt, mark remaining tests SKIP
    if [ -n "$_E2E_SUITE_SKIPPED" ]; then
        _E2E_SKIP_BLOCK=1
        (( _E2E_SKIP_COUNT++ )) || true
        _update_plan "$test_name" "SKIP"
        _e2e_log_and_print "$(_e2e_yellow "  SKIP (suite skipped): $test_name")"
        _e2e_summary "$(_e2e_Yellow "  SKIP (suite skipped): $test_name")"
        return 0
    fi

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

    # If suite was skipped during this test, record as FAIL
    if [ -n "$_E2E_SUITE_SKIPPED" ] && [ "$result" -eq 0 ]; then
        result=1
    fi

    # If user picked [s]kip from interactive menu, record as SKIP
    if [ -n "$_E2E_USER_SKIPPED" ]; then
        _E2E_USER_SKIPPED=""
        (( _E2E_SKIP_COUNT++ )) || true
        _update_plan "$test_name" "SKIP"
        _e2e_log_and_print "$(_e2e_yellow "  SKIP: $test_name")"
        _e2e_summary "$(_e2e_Yellow "  SKIP: $test_name")"
        _checkpoint_write "$test_name" "SKIP"
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

# --- Cluster Cleanup List ---------------------------------------------------
#
# Suites add clusters to the cleanup list RIGHT BEFORE the install command so
# cleanup knows which clusters exist and where to delete them.  The .cleanup file
# stores one entry per line: "user@fqdn /absolute/path/to/cluster_dir".
# Cleanup SSHs to the stored target and runs 'aba -d <path> delete'.

_E2E_CLEANUP_FILE=""

# Add a cluster to the cluster cleanup list.  Call DIRECTLY before the install command.
# The "local"/"remote" perspective is ALWAYS from conN (the host running the
# suite script).  "local" = cleanup on conN, "remote" = cleanup on disN
# (INTERNAL_BASTION) via SSH.
#   e2e_add_to_cluster_cleanup "$PWD/$SNO"              # local cluster (on conN)
#   e2e_add_to_cluster_cleanup "$PWD/$COMPACT" remote   # remote cluster (on disN)
e2e_add_to_cluster_cleanup() {
	local abs_path="$1"
	local location="${2:-local}"

	if [ -z "$_E2E_CLEANUP_FILE" ]; then
		_E2E_CLEANUP_FILE="${E2E_LOG_DIR}/${_E2E_SUITE_NAME}.cleanup"
	fi

	local target
	if [ "$location" = "remote" ]; then
		target="${INTERNAL_BASTION:?INTERNAL_BASTION not set}"
	else
		target="$(whoami)@$(hostname -f)"
	fi

	local entry="$target $abs_path"
	grep -qxF "$entry" "$_E2E_CLEANUP_FILE" 2>/dev/null || \
		echo "$entry" >> "$_E2E_CLEANUP_FILE"

	_e2e_log "  Added cluster to cleanup list: $entry"
}

# Delete all clusters in the cleanup list.  Safe to call multiple times.
# SSHs to each stored user@fqdn and runs 'aba -d <path> delete'.
e2e_cleanup_clusters() {
	local cleanup_file="${_E2E_CLEANUP_FILE:-${E2E_LOG_DIR}/${_E2E_SUITE_NAME}.cleanup}"
	[ -f "$cleanup_file" ] || return 0

	_e2e_log_and_print "  Cleaning up clusters (from cleanup list) ..."
	local target abs_path _all_ok=1
	while IFS=' ' read -r target abs_path; do
		[ -z "$abs_path" ] && continue
		_e2e_log_and_print "    $target: aba -y -d $abs_path delete"
		if ! ( _essh "$target" \
			"[ -d '$abs_path' ] && aba -y -d '$abs_path' delete || echo '  (dir not found -- already cleaned)'" \
			2>&1 ) | tee -a "${E2E_LOG_FILE:-/dev/null}"; then
			_e2e_log_and_print "  WARNING: cleanup SSH failed for $target:$abs_path"
			_all_ok=""
		fi
	done < "$cleanup_file"
	if [ -n "$_all_ok" ]; then
		rm -f "$cleanup_file"
	else
		_e2e_log_and_print "  WARNING: keeping $(basename "$cleanup_file") -- some entries failed"
	fi
	_e2e_log_and_print "  Cleanup complete."
}

# --- Mirror Cleanup List ----------------------------------------------------
#
# Same pattern as cluster cleanup list but for mirrors installed on disN.
# The .mirror-cleanup file stores one entry per line: "user@fqdn /abs/path".
# Cleanup SSHs to the target and runs 'aba -d <path> uninstall'.
# NOTE: This is for mirrors the SUITE installed (on disN).  The OOB pool
#       registry on conN is managed by setup-pool-registry.sh and must
#       NEVER be added to mirror cleanup here.

_E2E_MIRROR_CLEANUP_FILE=""

# Add a mirror to the mirror cleanup list.  Call DIRECTLY before the install/load/sync.
# The "local"/"remote" perspective is ALWAYS from conN (the host running the
# suite script).  "local" = cleanup on conN, "remote" = cleanup on disN
# (INTERNAL_BASTION) via SSH.
#   e2e_add_to_mirror_cleanup "$PWD/mirror"              # local mirror (on conN)
#   e2e_add_to_mirror_cleanup "$PWD/mirror" remote       # remote mirror (on disN)
e2e_add_to_mirror_cleanup() {
	local abs_path="$1"
	local location="${2:-local}"

	if [ -z "$_E2E_MIRROR_CLEANUP_FILE" ]; then
		_E2E_MIRROR_CLEANUP_FILE="${E2E_LOG_DIR}/${_E2E_SUITE_NAME}.mirror-cleanup"
	fi

	local target
	if [ "$location" = "remote" ]; then
		target="${INTERNAL_BASTION:?INTERNAL_BASTION not set}"
	else
		target="$(whoami)@$(hostname -f)"
	fi

	local entry="$target $abs_path"
	grep -qxF "$entry" "$_E2E_MIRROR_CLEANUP_FILE" 2>/dev/null || \
		echo "$entry" >> "$_E2E_MIRROR_CLEANUP_FILE"

	_e2e_log "  Added mirror to cleanup list: $entry"
}

# Uninstall all mirrors in the cleanup list.  Safe to call multiple times.
e2e_cleanup_mirrors() {
	local cleanup_file="${_E2E_MIRROR_CLEANUP_FILE:-${E2E_LOG_DIR}/${_E2E_SUITE_NAME}.mirror-cleanup}"
	[ -f "$cleanup_file" ] || return 0

	_e2e_log_and_print "  Cleaning up mirrors (from cleanup list) ..."
	local target abs_path _all_ok=1
	while IFS=' ' read -r target abs_path; do
		[ -z "$abs_path" ] && continue
		_e2e_log_and_print "    $target: aba -y -d $abs_path uninstall"
		if ! ( _essh "$target" \
			"[ -d '$abs_path' ] && aba -y -d '$abs_path' uninstall || echo '  (dir not found -- already cleaned)'" \
			2>&1 ) | tee -a "${E2E_LOG_FILE:-/dev/null}"; then
			_e2e_log_and_print "  WARNING: cleanup SSH failed for $target:$abs_path"
			_all_ok=""
		fi
	done < "$cleanup_file"
	if [ -n "$_all_ok" ]; then
		rm -f "$cleanup_file"
	else
		_e2e_log_and_print "  WARNING: keeping $(basename "$cleanup_file") -- some entries failed"
	fi
	_e2e_log_and_print "  Mirror cleanup complete."
}

# --- Interactive Prompt -----------------------------------------------------

_interactive_prompt() {
    local cmd="$1"
    local ret="$2"
    local description="${3:-}"

    if [ -z "$_E2E_INTERACTIVE" ]; then
        return 1
    fi

    local _paused_file="/tmp/e2e-paused-${_E2E_SUITE_NAME:-unknown}"
    echo "${_E2E_CURRENT_TEST:-$description}" > "$_paused_file"
    local _clock_stopped=""

    while true; do
        echo ""
        local _ctx=""
        [ -n "${_E2E_SUITE_NAME:-}" ] && _ctx="Suite: $_E2E_SUITE_NAME"
        [ -n "${_E2E_CURRENT_TEST:-}" ] && _ctx="${_ctx:+$_ctx | }TEST [$_E2E_TEST_COUNT]: $_E2E_CURRENT_TEST"
        [ -n "$description" ] && _ctx="${_ctx:+$_ctx | }Step: $description"
        [ -n "$_ctx" ] && _e2e_log_and_print "$(_e2e_yellow "$_ctx")"
        _e2e_log_and_print "FAILED: \"$(_e2e_exit_info $ret)\" $cmd"
        read -t 0 -n 10000 </dev/tty 2>/dev/null || true
        if [ "$_clock_stopped" ]; then
            printf "%s" "$(_e2e_red "PAUSED [R]etry [s]kip [S]kip-suite [0]restart-suite [c]leanup [a]bort [!cmd]: ")"
            read -r ans </dev/tty
        else
            printf "%s" "$(_e2e_red "[R]etry [s]kip [S]kip-suite [0]restart-suite [c]leanup [a]bort [p]ause [!cmd] (20m timeout): ")"
            if ! read -t 1200 -r ans </dev/tty; then
                rm -f "$_paused_file"
                _e2e_log_and_print "  >> $(_e2e_red "No input for 20 mins -- auto-aborting suite")"
                e2e_cleanup_clusters
                e2e_cleanup_mirrors
                exit 1
            fi
        fi

        case "$ans" in
            p|P)
                _clock_stopped=1
                _e2e_log_and_print "  >> $(_e2e_yellow "PAUSED -- clock stopped. Pick any option to continue.")"
                continue
                ;;
            r|R|"")
                rm -f "$_paused_file"
                _e2e_log_and_print "  >> $(_e2e_cyan "Retrying ...")"
                return 2
                ;;
            s)
                rm -f "$_paused_file"
                _e2e_log_and_print "  >> $(_e2e_yellow "Skipping test -- cleaning up ...")"
                e2e_cleanup_clusters
                e2e_cleanup_mirrors
                return 0
                ;;
            S)
                rm -f "$_paused_file"
                _e2e_log_and_print "  >> $(_e2e_yellow "Skipping entire suite -- cleaning up ...")"
                e2e_cleanup_clusters
                e2e_cleanup_mirrors
                return 3
                ;;
            0)
                rm -f "$_paused_file"
                _e2e_log_and_print "  >> $(_e2e_cyan "Restarting suite -- cleaning up first ...")"
                e2e_cleanup_clusters
                e2e_cleanup_mirrors
                return 4
                ;;
            c|C)
                _e2e_log_and_print "  >> $(_e2e_yellow "Running cleanup ...")"
                e2e_cleanup_clusters
                e2e_cleanup_mirrors
                ;;
            a|A)
                rm -f "$_paused_file"
                _e2e_log_and_print "  >> $(_e2e_red "Aborting -- cleaning up ...")"
                e2e_cleanup_clusters
                e2e_cleanup_mirrors
                exit 1
                ;;
            !*)
                local user_cmd="${ans#!}"
                _e2e_log "User entered command: $user_cmd"
                echo "Running: $user_cmd"
                ( eval "$user_cmd" ) 2>&1 | tee -a "${E2E_LOG_FILE:-/dev/null}"
                local new_rc=${PIPESTATUS[0]}
                if [ $new_rc -eq 0 ]; then
                    _e2e_log "User command succeeded"
                    rm -f "$_paused_file"
                    return 0
                else
                    _e2e_log "User command failed (exit=$new_rc)"
                    echo "Command failed with exit code $new_rc"
                fi
                ;;
            *)
                echo "Unknown option '$ans'. Prefix with ! to run a command (e.g. !ls -la)"
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
# Usage: e2e_run [-r RETRIES BACKOFF] [-d INITIAL_DELAY] [-m MAX_DELAY]
#                [-h HOST] "description" command...
#
# All output is shown on screen AND logged (verbose by default, no -q flag).
#
# Flags:
#   -r RETRIES BACKOFF   Retry on failure (default: 5 retries, 1.5x backoff)
#   -d INITIAL_DELAY     Initial delay before first retry in seconds (default: 5)
#   -m MAX_DELAY         Maximum delay between retries in seconds (default: 60)
#   -h HOST              Run command on remote HOST via SSH
#   "description"        First non-flag argument = human-readable description
#   command...           Remaining arguments = the command to run
#
e2e_run() {
    [ -n "$_E2E_SKIP_BLOCK" ] && return 0
    [ -n "$_E2E_SUITE_SKIPPED" ] && return 0

    local tot_cnt=5
    local backoff=1.5
    local initial_delay=5
    local max_delay=60
    local host=""
    local quiet=""
    local mark="L"

    while [[ "${1:-}" == -* ]]; do
        case "$1" in
            -r) tot_cnt="$2"; backoff="$3"; shift 3 ;;
            -d) initial_delay="$2"; shift 2 ;;
            -m) max_delay="$2"; shift 2 ;;
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

    local _step_start
    _step_start=$(date +%s)

    # Per-command output capture: write to a temp file so failure notifications
    # can read the last 20 lines without the tee-reading-own-log truncation bug.
    local _cmd_output_file="/tmp/e2e-cmd-output.$$.tmp"

    while true; do
        local sleep_time="$initial_delay"
        local attempt=1

        while true; do
            local ret=0
            : > "$_cmd_output_file"

            if [ -n "$host" ]; then
                _e2e_log "  Running on $host (attempt $attempt/$tot_cnt): $cmd"
                if [ -n "$quiet" ]; then
                    ssh -n -o LogLevel=ERROR -o ConnectTimeout=30 -o BatchMode=yes "$host" -- ". \$HOME/.bash_profile 2>/dev/null; $cmd" \
                        >> "$_lf" 2>&1 || ret=$?
                else
                    ssh -n -o LogLevel=ERROR -o ConnectTimeout=30 -o BatchMode=yes "$host" -- ". \$HOME/.bash_profile 2>/dev/null; $cmd" \
                        2>&1 | tee -a "$_lf" "$_cmd_output_file"; ret=${PIPESTATUS[0]}
                fi
            else
                _e2e_log "  Running locally (attempt $attempt/$tot_cnt): $cmd"
                if [ -n "$quiet" ]; then
                    ( eval "$cmd" ) < /dev/null >> "$_lf" 2>&1 || ret=$?
                else
                    ( eval "$cmd" ) < /dev/null 2>&1 | tee -a "$_lf" "$_cmd_output_file"; ret=${PIPESTATUS[0]}
                fi
            fi

            # Ctrl-C (SIGINT=130): skip retry loop, go straight to interactive prompt
            if [ $ret -eq 130 ]; then
                _e2e_log_and_print "    $(_e2e_yellow "Interrupted (Ctrl-C)")"
                _e2e_summary "    $(_e2e_Yellow "Interrupted (Ctrl-C): $description")"
                break
            fi

            if [ $ret -eq 0 ]; then
                local _elapsed=$(( $(date +%s) - _step_start ))
                local _dur; _dur=$(_e2e_fmt_duration $_elapsed)
                if [ $attempt -gt 1 ]; then
                    _e2e_summary "    $(_e2e_Green "RECOVERED") on attempt $attempt: $description ($_dur)"
                fi
                _e2e_log_and_print "    $(_e2e_green "OK") ($_dur)"
                _e2e_summary "    $(_e2e_Green "OK ($_dur)")"
                _e2e_log "  OK (attempt $attempt, $_dur)"
                rm -f "$_cmd_output_file"
                return 0
            fi

            local _exi; _exi="$(_e2e_exit_info $ret)"
            _e2e_log "  Attempt $attempt/$tot_cnt failed ($_exi)"

            # Notify on the very first failure (before exhausted check so tot_cnt=1 still fires)
            # #region agent log
            printf '{"sessionId":"23cf03","hypothesisId":"H1","location":"framework.sh:retry_loop","message":"failure in retry loop","data":{"attempt":%d,"tot_cnt":%d,"description":"%s","ret":%d},"timestamp":%s}\n' \
                "$attempt" "$tot_cnt" "$description" "$ret" "$(date +%s%3N)" >> /tmp/e2e-debug-23cf03.log 2>/dev/null
            # #endregion
            if [ $attempt -eq 1 ]; then
                (
                    echo "$(date '+%H:%M:%S') FIRST FAILURE"
                    echo "Suite: $_E2E_SUITE_NAME"
                    echo "Test: ${_E2E_CURRENT_TEST:-$description}"
                    echo "Command: $cmd"
                    echo "Host: ${host:-$(hostname -s)}"
                    echo ""
                    echo "--- Last 20 lines of suite log ---"
                    echo ""
                    tail -20 "$E2E_LOG_FILE" 2>/dev/null
                ) | _e2e_notify_stdin "FIRST FAIL: $description"
            fi

            if [ $attempt -ge $tot_cnt ]; then
                _e2e_log "  All $tot_cnt attempts exhausted"
                _e2e_log_and_print "    $(_e2e_red "Attempt ($attempt/$tot_cnt) FAILED ($_exi): $description")"
                _e2e_summary "    $(_e2e_Red "Attempt ($attempt/$tot_cnt) FAILED ($_exi): $description")"
                _e2e_summary "    $(_e2e_Red "EXHAUSTED $tot_cnt attempts: $description")"
                if [ $tot_cnt -gt 1 ]; then
                    (
                        echo "$(date '+%H:%M:%S') EXHAUSTED $tot_cnt attempts"
                        echo "Suite: $_E2E_SUITE_NAME"
                        echo "Test: ${_E2E_CURRENT_TEST:-$description}"
                        echo "Command: $cmd"
                        echo "Host: ${host:-$(hostname -s)}"
                        echo ""
                        echo "--- Last 20 lines of suite log ---"
                        echo ""
                        tail -20 "$E2E_LOG_FILE" 2>/dev/null
                    ) | _e2e_notify_stdin "EXHAUSTED: $description"
                fi
                break
            fi

            _e2e_log_and_print "    $(_e2e_red "Attempt ($attempt/$tot_cnt) failed ($_exi): $description") -- retrying ..."
            _e2e_summary "    $(_e2e_Red "Attempt ($attempt/$tot_cnt) failed ($_exi)") $description -- retrying ..."

            (( attempt++ ))
            echo "    Next attempt ($attempt/$tot_cnt) in ${sleep_time}s ..."
            sleep "$sleep_time"
            sleep_time=$(awk -v s="$sleep_time" -v b="$backoff" 'BEGIN {print int(s * b)}')
            [ "$sleep_time" -gt "$max_delay" ] && sleep_time="$max_delay"
        done

        _interactive_prompt "$cmd" "$ret" "$description"
        local prompt_rc=$?

        if [ $prompt_rc -eq 2 ]; then
            _e2e_log "  Restarting retry cycle (user requested)"
            continue
        elif [ $prompt_rc -eq 0 ]; then
            local _elapsed=$(( $(date +%s) - _step_start ))
            local _dur; _dur=$(_e2e_fmt_duration $_elapsed)
            _e2e_log_and_print "    $(_e2e_yellow "SKIP (user)") ($_dur)"
            _e2e_summary "    $(_e2e_Yellow "SKIP (user): $description") ($_dur)"
            _E2E_USER_SKIPPED=1
            rm -f "$_cmd_output_file"
            return 0
        elif [ $prompt_rc -eq 3 ]; then
            _E2E_SUITE_SKIPPED=1
            rm -f "$_cmd_output_file"
            return 3
        elif [ $prompt_rc -eq 4 ]; then
            rm -f "$_cmd_output_file"
            return 4
        else
            local _exf; _exf="$(_e2e_exit_info $ret)"
            _e2e_log "  FAILED: $description ($_exf)"
            _e2e_log_and_print "  $(_e2e_red "FATAL: $description ($_exf) -- aborting suite")"
            _e2e_summary "    $(_e2e_Red "FATAL: $description ($_exf) -- aborting suite")"
            if [ -n "$_E2E_CURRENT_TEST" ]; then
                test_end "$ret"
            fi
            rm -f "$_cmd_output_file"
            e2e_cleanup_clusters
            e2e_cleanup_mirrors
            exit 1
        fi
    done
}

# --- e2e_run_remote ---------------------------------------------------------
#
# Shorthand for e2e_run -h $INTERNAL_BASTION
# The INTERNAL_BASTION variable must be set by the suite or config.
#
# Shorthand for e2e_run -h $INTERNAL_BASTION (all flags pass through)
e2e_run_remote() {
    [ -n "$_E2E_SKIP_BLOCK" ] && return 0
    [ -n "$_E2E_SUITE_SKIPPED" ] && return 0
    if [ -z "${INTERNAL_BASTION:-}" ]; then
        _e2e_log_and_print "  $(_e2e_red "FATAL: INTERNAL_BASTION not set -- aborting suite")"
        exit 1
    fi
    e2e_run -h "$INTERNAL_BASTION" "$@"
}

# --- e2e_poll ---------------------------------------------------------------
#
# Time-bounded polling: repeat a condition command every INTERVAL seconds
# until it succeeds or TIMEOUT seconds have elapsed (wall-clock).
#
# Usage: e2e_poll TIMEOUT INTERVAL "description" "condition_cmd"
#
# Unlike e2e_run retries (count-based), this is wall-clock bounded:
# the total time includes both sleep intervals AND command execution time.
#
e2e_poll() {
    local timeout="$1" interval="$2"; shift 2
    e2e_run "$1 (max $((timeout/60))m)" \
        "end=\$((SECONDS + $timeout)); while [ \$SECONDS -lt \$end ]; do ( $2 ) && exit 0; sleep $interval; done; exit 1"
}

# Shorthand: e2e_poll on $INTERNAL_BASTION
e2e_poll_remote() {
    local timeout="$1" interval="$2"; shift 2
    e2e_run_remote "$1 (max $((timeout/60))m)" \
        "end=\$((SECONDS + $timeout)); while [ \$SECONDS -lt \$end ]; do ( $2 ) && exit 0; sleep $interval; done; exit 1"
}

# --- Operator readiness helpers ---------------------------------------------
#
# Reusable wait functions for OpenShift cluster operator stabilization.
# Both use wall-clock-bounded polling (e2e_poll / e2e_poll_remote).
#
# Usage:
#   e2e_wait_operators_available $SNO           # local, AVAILABLE=True only
#   e2e_wait_operators_available $SNO remote    # remote (disN)
#   e2e_wait_operators_ready $SNO remote        # remote, strict 3-column check
#

# Loose check: all operators have AVAILABLE=True (ignores PROGRESSING/DEGRADED).
# 10 min timeout, 30s interval.
e2e_wait_operators_available() {
	local cluster_dir="$1"
	local location="${2:-local}"
	local _cmd="cd ~/aba && aba --dir $cluster_dir run | tail -n +2 | awk '{print \$3}' | tail -n +2 | grep -v '^True\$' | wc -l | grep ^0\$"

	if [ "$location" = "remote" ]; then
		e2e_poll_remote 600 30 "Wait for all operators available" "$_cmd"
	else
		e2e_poll 600 30 "Wait for all operators available" "$_cmd"
	fi
}

# Strict check: all operators AVAILABLE=True, PROGRESSING=False, DEGRADED=False.
# 10 min timeout, 30s interval.
e2e_wait_operators_ready() {
	local cluster_dir="$1"
	local location="${2:-local}"
	local _cmd="cd ~/aba && aba --dir $cluster_dir run | tail -n +2 | awk '{print \$3,\$4,\$5}' | tail -n +2 | grep -v '^True False False\$' | wc -l | grep ^0\$"

	if [ "$location" = "remote" ]; then
		e2e_poll_remote 600 30 "Wait for all operators fully ready" "$_cmd"
	else
		e2e_poll 600 30 "Wait for all operators fully ready" "$_cmd"
	fi
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
    [ -n "$_E2E_SUITE_SKIPPED" ] && return 0

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
        ssh -n -o LogLevel=ERROR -o ConnectTimeout=30 -o BatchMode=yes "$host" -- ". \$HOME/.bash_profile 2>/dev/null; $cmd" \
            2>&1 | tee -a "$_lf"; ret=${PIPESTATUS[0]}
    else
        ( eval "$cmd" ) < /dev/null 2>&1 | tee -a "$_lf"; ret=${PIPESTATUS[0]}
    fi

    if [ $ret -ne 0 ]; then
        _e2e_log "  [diag] $description exited $ret (informational only)"
    fi

    return 0  # Always succeed -- this is diagnostic only
}

# Shorthand: e2e_diag on $INTERNAL_BASTION
e2e_diag_remote() {
    [ -n "$_E2E_SKIP_BLOCK" ] && return 0
    [ -n "$_E2E_SUITE_SKIPPED" ] && return 0
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
    [ -n "$_E2E_SUITE_SKIPPED" ] && return 0

    local description="$1"; shift
    local cmd="$*"
    local _lf="${E2E_LOG_FILE:-/dev/null}"

    _e2e_log_and_print "  L $(_e2e_yellow "[EXPECT-FAIL]") $description $(_e2e_yellow "[$USER@$(hostname -s):$PWD]")"
    _e2e_log_and_print "    $(_e2e_cyan "$cmd")"
    _e2e_log "    CMD (must-fail): $cmd"
    _e2e_summary "  L $(_e2e_Yellow "[EXPECT-FAIL] $description") $(_e2e_Yellow "[$USER@$(hostname -s):$PWD]")"
    _e2e_summary "    $(_e2e_Cyan "$cmd")"

    local ret=0
    ( eval "$cmd" ) < /dev/null 2>&1 | tee -a "$_lf"; ret=${PIPESTATUS[0]}

    if [ $ret -ne 0 ]; then
        _e2e_log "  OK: command failed as expected ($(_e2e_exit_info $ret))"
        _e2e_log_and_print "    $(_e2e_green "[EXPECT-FAIL] OK: failed as expected ($(_e2e_exit_info $ret))")"
        _e2e_summary "    $(_e2e_Green "[EXPECT-FAIL] OK ($(_e2e_exit_info $ret))")"
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
    [ -n "$_E2E_SUITE_SKIPPED" ] && return 0

    local description="$1"; shift
    local cmd="$*"
    local _lf="${E2E_LOG_FILE:-/dev/null}"

    if [ -z "${INTERNAL_BASTION:-}" ]; then
        _e2e_log_and_print "  $(_e2e_red "FATAL: INTERNAL_BASTION not set -- aborting suite")"
        exit 1
    fi

    _e2e_log_and_print "  R $(_e2e_yellow "[EXPECT-FAIL]") $description"
    _e2e_log_and_print "    $(_e2e_cyan "($cmd)")"
    _e2e_log "    CMD (must-fail on $INTERNAL_BASTION): $cmd"
    _e2e_summary "  R $(_e2e_Yellow "[EXPECT-FAIL] $description")"
    _e2e_summary "    $(_e2e_Cyan "($cmd)")"

    local ret=0
    ssh -n -o LogLevel=ERROR -o ConnectTimeout=30 -o BatchMode=yes "$INTERNAL_BASTION" -- \
        ". \$HOME/.bash_profile 2>/dev/null; $cmd" \
        2>&1 | tee -a "$_lf"; ret=${PIPESTATUS[0]}

    if [ $ret -ne 0 ]; then
        _e2e_log "  OK: command failed as expected ($(_e2e_exit_info $ret))"
        _e2e_log_and_print "    $(_e2e_green "[EXPECT-FAIL] OK: failed as expected ($(_e2e_exit_info $ret))")"
        _e2e_summary "    $(_e2e_Green "[EXPECT-FAIL] OK ($(_e2e_exit_info $ret))")"
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
    if grep "$pattern" "$file"; then
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
    if ! grep "$pattern" "$file"; then
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

    # testy key lives on conN (baked into golden snapshot).
    # Verify that conN can SSH as testy to disN -- the path used by test suites.
    local _dis_host_only="${DIS_HOST:-}"
    _dis_host_only="${_dis_host_only#*@}"   # strip user@ prefix if present
    if [ -n "$_dis_host_only" ]; then
        _e2e_log "  Preflight: checking testy SSH from $host_only to $_dis_host_only ..."
        if ! ssh $_ssh_opts "$host" -- "ssh -i ~/.ssh/testy_rsa -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null testy@${_dis_host_only} whoami 2>&1 | grep testy"; then
            _e2e_log_and_print "  $(_e2e_Red "PREFLIGHT FAIL: testy cannot SSH from $host_only to $_dis_host_only")"
            _fail=1
        else
            _e2e_log "  Preflight: testy SSH from $host_only to $_dis_host_only OK"
        fi
    else
        _e2e_log "  Preflight: DIS_HOST not set -- skipping testy SSH check"
    fi

    if [ -n "$_fail" ]; then
        _e2e_log_and_print "  $(_e2e_Red "Aborting suite -- SSH preflight failed for $host.")"
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
