#!/bin/bash
#
# continuous.sh -- Continuous E2E runner that cycles through parameter combinations.
#
# Runs all suites for every combination of:
#   OS:       rhel8, rhel9
#   VMware:   each config file in VMWARE_CONFIGS
#   User:     steve, root, steve->root (mixed), root->steve (mixed)
#
# Never stops: after completing all combinations, loops back to round 1.
#
# Usage:
#   ./continuous.sh                    # Run with defaults (pools 1-4, --dev)
#   ./continuous.sh -p 2-4             # Only use pools 2-4
#   ./continuous.sh --no-dev           # Use git clone instead of --dev
#   ./continuous.sh --dry-run          # Print the round matrix and exit
#
# Requires: run.sh in the same directory.

set -u -o pipefail

_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_RUN_SH="${_SELF_DIR}/run.sh"
_LOG_DIR="${_SELF_DIR}/logs"
_LOG_FILE="${_LOG_DIR}/continuous.log"
_STATE_FILE="/tmp/e2e-dispatch-state.txt"

mkdir -p "$_LOG_DIR"

# ---------------------------------------------------------------------------
# Configuration -- edit these arrays to change the parameter matrix
# ---------------------------------------------------------------------------

OS_LIST=(rhel8 rhel9)

VMWARE_CONFIGS=(
    ~/.vmware.conf
    ~/.vmware.conf.esxi
)

# Each user spec is: "--flag value [--flag value ...]"
# The label is for logging; the flags are passed to run.sh.
USER_SPECS=(
    "steve|--user steve"
    "root|--user root"
    "steve-to-root|--con-user steve --dis-user root"
    "root-to-steve|--con-user root --dis-user steve"
)

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

POOL_SPEC="1-4"
USE_DEV=1
DRY_RUN=""
POLL_INTERVAL=60

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

while [[ "${1:-}" == -* ]]; do
    case "$1" in
        -p|--pool)      POOL_SPEC="$2"; shift 2 ;;
        --no-dev)       USE_DEV=""; shift ;;
        --dry-run|-n)   DRY_RUN=1; shift ;;
        --poll)         POLL_INTERVAL="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,/^$/{ s/^# \?//; p }' "$0"
            exit 0 ;;
        *)  echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

_log() {
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] $*" | tee -a "$_LOG_FILE"
}

_notify() {
    local msg="$1"
    _log "NOTIFY: $msg"
    if [ -x ~/bin/notify.sh ]; then
        ~/bin/notify.sh "[continuous] $msg" < /dev/null >/dev/null 2>&1 &
    fi
}

# ---------------------------------------------------------------------------
# Build round matrix
# ---------------------------------------------------------------------------

declare -a ROUND_LABELS=()
declare -a ROUND_FLAGS=()

_prev_os=""
for _os in "${OS_LIST[@]}"; do
    for _vmconf in "${VMWARE_CONFIGS[@]}"; do
        _vmconf_expanded="${_vmconf/#\~/$HOME}"
        if [ ! -f "$_vmconf_expanded" ]; then
            echo "SKIP: vmware config not found: $_vmconf" >&2
            continue
        fi
        _vmconf_name="$(basename "$_vmconf" .conf)"

        for _uspec in "${USER_SPECS[@]}"; do
            _ulabel="${_uspec%%|*}"
            _uflags="${_uspec#*|}"

            _label="${_os}/${_vmconf_name}/${_ulabel}"
            _flags="--os $_os -v $_vmconf $_uflags -p $POOL_SPEC --all --yes"
            [ -n "$USE_DEV" ] && _flags="$_flags --dev"

            ROUND_LABELS+=("$_label")
            ROUND_FLAGS+=("$_flags")
        done
    done
done

_total_rounds=${#ROUND_LABELS[@]}

if [ "$_total_rounds" -eq 0 ]; then
    echo "ERROR: No valid rounds (check VMWARE_CONFIGS paths)" >&2
    exit 1
fi

_log "=== Continuous E2E Runner ==="
_log "Rounds per cycle: $_total_rounds"
_log "Pools: $POOL_SPEC"
_log "Dev mode: ${USE_DEV:+yes}"
for (( i=0; i<_total_rounds; i++ )); do
    _log "  Round $((i+1)): ${ROUND_LABELS[$i]}"
    [ -n "$DRY_RUN" ] && echo "    flags: ${ROUND_FLAGS[$i]}"
done

if [ -n "$DRY_RUN" ]; then
    echo ""
    echo "Dry run -- $_total_rounds rounds per cycle. Exiting."
    exit 0
fi

# ---------------------------------------------------------------------------
# Signal handling -- clean stop on Ctrl-C / SIGTERM
# ---------------------------------------------------------------------------

_cleanup() {
    echo ""
    _log "Caught signal -- stopping daemon ..."
    "$_RUN_SH" stop -p "$POOL_SPEC" --no-clean --yes 2>/dev/null || true
    _notify "Continuous runner stopped (signal)"
    exit 0
}
trap _cleanup INT TERM

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_extract_os() {
    local flags="$1"
    echo "$flags" | grep -oP '(?<=--os )\S+'
}

_wait_for_completion() {
    local round_label="$1"
    local start_time=$SECONDS

    _log "Waiting for all suites to complete ..."

    while true; do
        sleep "$POLL_INTERVAL"

        if [ ! -f "$_STATE_FILE" ]; then
            continue
        fi

        local pending running done_count done_list
        pending=$(grep '^PENDING=' "$_STATE_FILE" 2>/dev/null | cut -d= -f2-)
        running=$(grep '^RUNNING=' "$_STATE_FILE" 2>/dev/null | cut -d= -f2-)
        done_count=$(grep '^DONE=' "$_STATE_FILE" 2>/dev/null | cut -d= -f2-)
        done_list=$(grep '^DONE_LIST=' "$_STATE_FILE" 2>/dev/null | cut -d= -f2-)

        # Still have work to do
        if [ -n "$pending" ] || [ -n "$running" ]; then
            local elapsed=$(( SECONDS - start_time ))
            local elapsed_hr=$(( elapsed / 3600 ))
            local elapsed_min=$(( (elapsed % 3600) / 60 ))
            _log "  ... ${done_count:-0} done, running=[${running:-}], pending=[${pending:-}] (${elapsed_hr}h${elapsed_min}m)"
            continue
        fi

        # Check if dispatcher is still alive (it might be between suites)
        if [ -f /tmp/e2e-dispatcher.pid ] && kill -0 "$(cat /tmp/e2e-dispatcher.pid 2>/dev/null)" 2>/dev/null; then
            # Dispatcher alive but nothing running/pending -- might be finishing up
            if [ -z "$pending" ] && [ -z "$running" ] && [ "${done_count:-0}" -gt 0 ]; then
                # Give it a moment to exit cleanly
                sleep 5
                if kill -0 "$(cat /tmp/e2e-dispatcher.pid 2>/dev/null)" 2>/dev/null; then
                    continue
                fi
            else
                continue
            fi
        fi

        # Dispatcher exited -- round is done
        local elapsed=$(( SECONDS - start_time ))
        local pass=0 fail=0 total=0
        if [ -n "$done_list" ]; then
            for entry in $done_list; do
                local rc="${entry#*:}"
                rc="${rc%%@*}"
                total=$(( total + 1 ))
                if [ "$rc" = "0" ]; then
                    pass=$(( pass + 1 ))
                else
                    fail=$(( fail + 1 ))
                fi
            done
        fi

        local dur_hr=$(( elapsed / 3600 ))
        local dur_min=$(( (elapsed % 3600) / 60 ))
        _log "Round complete: $round_label -- ${pass} PASS, ${fail} FAIL (${dur_hr}h${dur_min}m)"

        if [ "$fail" -gt 0 ]; then
            _notify "DONE: $round_label -- ${pass} PASS, ${fail} FAIL (${dur_hr}h${dur_min}m)"
        else
            _notify "DONE: $round_label -- ALL ${pass} PASSED (${dur_hr}h${dur_min}m)"
        fi

        return "$fail"
    done
}

# ---------------------------------------------------------------------------
# Main loop -- never stops
# ---------------------------------------------------------------------------

_cycle=0
_prev_os=""

while true; do
    _cycle=$(( _cycle + 1 ))
    _log ""
    _log "================================================================"
    _log "=== CYCLE $_cycle ==="
    _log "================================================================"
    _notify "Starting cycle $_cycle ($_total_rounds rounds)"

    for (( _ri=0; _ri<_total_rounds; _ri++ )); do
        _label="${ROUND_LABELS[$_ri]}"
        _flags="${ROUND_FLAGS[$_ri]}"
        _round_num=$(( _ri + 1 ))
        _cur_os=$(_extract_os "$_flags")

        _log ""
        _log "--- Round $_round_num/$_total_rounds: $_label ---"

        # Stop previous daemon
        _log "Stopping previous daemon ..."
        "$_RUN_SH" stop -p "$POOL_SPEC" --yes 2>&1 | tee -a "$_LOG_FILE" || true
        sleep 3

        # Build run.sh flags
        _run_flags="$_flags"

        # Add --revert when OS changes (triggers reclone)
        if [ -n "$_prev_os" ] && [ "$_cur_os" != "$_prev_os" ]; then
            _log "OS changed: $_prev_os -> $_cur_os (adding --revert)"
            _run_flags="$_run_flags --revert"
        fi
        _prev_os="$_cur_os"

        _notify "Round $_round_num/$_total_rounds: $_label"
        _log "Running: $_RUN_SH run $_run_flags"

        # Launch the daemon with this round's parameters.
        # run.sh will auto-daemonize and return immediately if a daemon starts.
        "$_RUN_SH" run $_run_flags 2>&1 | tee -a "$_LOG_FILE"

        # Wait for all suites to complete
        _wait_for_completion "$_label"
        _round_rc=$?

        _log "Round $_round_num result: exit=$_round_rc"
    done

    _log ""
    _log "=== CYCLE $_cycle COMPLETE ==="
    _notify "Cycle $_cycle complete. Starting next cycle ..."

    sleep 10
done
