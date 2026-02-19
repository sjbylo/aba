#!/bin/bash
# =============================================================================
# E2E Test Framework -- Parallel Dispatch
# =============================================================================
# Work-queue dispatcher for running suites across pools in parallel.
#
# Reads pools.conf, builds a work queue (longest suites first), and
# dispatches jobs to available pools via SSH. Streams logs in real-time
# and collects exit codes for a final summary.
# =============================================================================

_E2E_LIB_DIR_PA="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_E2E_DIR_PA="$(cd "$_E2E_LIB_DIR_PA/.." && pwd)"

# --- Pool Data Structures ---------------------------------------------------

# Parallel arrays for pool information
declare -a _POOL_NAMES=()
declare -a _POOL_CONN_HOSTS=()
declare -a _POOL_INT_HOSTS=()
declare -a _POOL_INT_VMS=()
declare -a _POOL_OVERRIDES=()   # KEY=VAL KEY=VAL ...

# Job tracking
declare -A _JOB_PIDS=()         # pool -> PID
declare -A _JOB_SUITES=()       # pool -> suite name
declare -A _JOB_RESULTS=()      # "pool:suite" -> exit code
declare -A _JOB_START=()        # pool -> start timestamp
declare -A _JOB_LOG=()          # pool -> log file

# --- load_pools -------------------------------------------------------------
#
# Parse pools.conf into the parallel arrays.
#
# Format per line:
#   POOL_NAME  CONNECTED_HOST  INTERNAL_HOST  INTERNAL_VM_NAME  [KEY=VAL ...]
#
load_pools() {
    local pools_file="${1:-$_E2E_DIR_PA/pools.conf}"

    if [ ! -f "$pools_file" ]; then
        echo "ERROR: pools.conf not found: $pools_file" >&2
        return 1
    fi

    _POOL_NAMES=()
    _POOL_CONN_HOSTS=()
    _POOL_INT_HOSTS=()
    _POOL_INT_VMS=()
    _POOL_OVERRIDES=()

    local idx=0
    while IFS= read -r line; do
        # Skip comments and blank lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue

        # Parse fields
        read -r name conn_host int_host int_vm rest <<< "$line"

        _POOL_NAMES[$idx]="$name"
        _POOL_CONN_HOSTS[$idx]="$conn_host"
        _POOL_INT_HOSTS[$idx]="${int_host:--}"
        _POOL_INT_VMS[$idx]="${int_vm:--}"
        _POOL_OVERRIDES[$idx]="${rest:-}"

        (( idx++ ))
    done < "$pools_file"

    if [ ${#_POOL_NAMES[@]} -eq 0 ]; then
        echo "ERROR: No pools defined in $pools_file" >&2
        return 1
    fi

    echo "Loaded ${#_POOL_NAMES[@]} pool(s) from $pools_file"
    local i
    for i in "${!_POOL_NAMES[@]}"; do
        printf "  %-10s %-20s %-20s %-30s %s\n" \
            "${_POOL_NAMES[$i]}" "${_POOL_CONN_HOSTS[$i]}" \
            "${_POOL_INT_HOSTS[$i]}" "${_POOL_INT_VMS[$i]}" \
            "${_POOL_OVERRIDES[$i]}"
    done
    echo ""
}

# --- _build_remote_cmd ------------------------------------------------------
#
# Construct the SSH command to run a suite on a remote pool.
#
_build_remote_cmd() {
    local suite="$1"
    local pool_idx="$2"

    local host="${_POOL_CONN_HOSTS[$pool_idx]}"
    local overrides="${_POOL_OVERRIDES[$pool_idx]}"

    # Remote must know it's on the bastion so run.sh runs the suite directly (no re-dispatch).
    local env_exports="export E2E_ON_BASTION=1; "
    [ -n "${ABA_TESTING:-}" ] && env_exports+="export ABA_TESTING=1; "

    # Per-pool overrides from pools.conf
    for override in $overrides; do
        env_exports+="export $override; "
    done

    # Pass current env vars that aren't already in overrides
    local pass_vars=""
    for var in TEST_CHANNEL OCP_VERSION INT_BASTION_RHEL_VER TEST_USER OC_MIRROR_VER; do
        if [ -n "${!var:-}" ] && ! echo "$overrides" | grep -q "^${var}="; then
            pass_vars+="export $var='${!var}'; "
        fi
    done

    # Build notify flag
    local notify_flag=""
    [ -n "${NOTIFY_CMD:-}" ] && notify_flag="--notify"

    # The remote command
    local remote_cmd="${env_exports}${pass_vars}cd ~/aba && test/e2e/run.sh --suite $suite --ci $notify_flag"

    echo "ssh -o LogLevel=ERROR -o ConnectTimeout=30 $host -- '$remote_cmd'"
}

# --- _dispatch_job ----------------------------------------------------------
#
# Start a suite running on a pool in the background.
#
_dispatch_job() {
    local pool_name="$1"
    local pool_idx="$2"
    local suite="$3"

    local host="${_POOL_CONN_HOSTS[$pool_idx]}"
    local log_file="${_E2E_DIR_PA}/logs/${pool_name}-suite-${suite}.log"

    echo "  DISPATCH: $suite -> $pool_name ($host)"

    _JOB_SUITES[$pool_name]="$suite"
    _JOB_START[$pool_name]=$(date +%s)
    _JOB_LOG[$pool_name]="$log_file"

    # Build and run the remote command
    local cmd
    cmd="$(_build_remote_cmd "$suite" "$pool_idx")"

    # Run in background, redirect output to log file
    eval "$cmd" > "$log_file" 2>&1 &
    _JOB_PIDS[$pool_name]=$!

    _e2e_notify "Dispatched: $suite -> $pool_name ($host)" 2>/dev/null || true
}

# --- _record_result ---------------------------------------------------------
#
# Record the result of a completed job.
#
_record_result() {
    local pool_name="$1"
    local suite="$2"
    local exit_code="$3"

    local elapsed=$(( $(date +%s) - ${_JOB_START[$pool_name]} ))
    local mins=$(( elapsed / 60 ))
    local secs=$(( elapsed % 60 ))

    _JOB_RESULTS["${pool_name}:${suite}"]="$exit_code"

    if [ "$exit_code" -eq 0 ]; then
        echo "  COMPLETED: $suite on $pool_name -- PASS (${mins}m ${secs}s)"
        _e2e_notify "PASS: $suite on $pool_name (${mins}m ${secs}s)" 2>/dev/null || true
    else
        echo "  COMPLETED: $suite on $pool_name -- FAIL (exit=$exit_code, ${mins}m ${secs}s)"
        _e2e_notify "FAIL: $suite on $pool_name (exit=$exit_code, ${mins}m ${secs}s)" 2>/dev/null || true
    fi

    # Clear the pool's job
    unset '_JOB_PIDS[$pool_name]'
    unset '_JOB_SUITES[$pool_name]'
}

# --- _find_free_pool --------------------------------------------------------
#
# Return the index of a pool that has no running job, or -1 if all busy.
#
_find_free_pool() {
    local i
    for i in "${!_POOL_NAMES[@]}"; do
        local name="${_POOL_NAMES[$i]}"
        if [ -z "${_JOB_PIDS[$name]:-}" ]; then
            echo "$i"
            return 0
        fi
    done
    echo "-1"
    return 1
}

# --- _wait_for_any ----------------------------------------------------------
#
# Wait for any running job to complete and record its result.
# Returns the pool index that became free.
#
_wait_for_any() {
    while true; do
        local pool_name
        for pool_name in "${!_JOB_PIDS[@]}"; do
            local pid="${_JOB_PIDS[$pool_name]}"
            if ! kill -0 "$pid" 2>/dev/null; then
                # Process has finished
                wait "$pid" 2>/dev/null
                local exit_code=$?
                local suite="${_JOB_SUITES[$pool_name]}"
                _record_result "$pool_name" "$suite" "$exit_code"

                # Return the pool index
                local i
                for i in "${!_POOL_NAMES[@]}"; do
                    [ "${_POOL_NAMES[$i]}" = "$pool_name" ] && echo "$i" && return 0
                done
            fi
        done
        sleep 2
    done
}

# --- _print_summary ---------------------------------------------------------
#
# Print the final results table.
#
_print_summary() {
    echo ""
    echo "========================================"
    echo "  PARALLEL EXECUTION SUMMARY"
    echo "========================================"
    echo ""

    local total=0 passed=0 failed=0

    printf "  %-15s %-35s %-8s %s\n" "POOL" "SUITE" "RESULT" "LOG"
    printf "  %s\n" "$(printf '%0.s-' {1..85})"

    local key
    for key in $(echo "${!_JOB_RESULTS[@]}" | tr ' ' '\n' | sort); do
        local pool="${key%%:*}"
        local suite="${key#*:}"
        local rc="${_JOB_RESULTS[$key]}"
        local result_str

        (( total++ ))
        if [ "$rc" -eq 0 ]; then
            result_str="$(_e2e_green "PASS")"
            (( passed++ ))
        else
            result_str="$(_e2e_red "FAIL($rc)")"
            (( failed++ ))
        fi

        local log="${_E2E_DIR_PA}/logs/${pool}-suite-${suite}.log"
        printf "  %-15s %-35s %-8s %s\n" "$pool" "$suite" "$result_str" "$log"
    done

    echo ""
    echo "  Total: $total  Passed: $passed  Failed: $failed"
    echo "========================================"
    echo ""

    [ $failed -gt 0 ] && return 1
    return 0
}

# --- dispatch_all -----------------------------------------------------------
#
# Main dispatcher: load pools, build work queue, dispatch jobs, collect results.
#
# Usage: dispatch_all POOLS_FILE SUITE1 [SUITE2 ...]
#
dispatch_all() {
    local pools_file="$1"; shift
    local suites=("$@")

    echo "=== Parallel Dispatch ==="
    echo ""

    # Load pools
    load_pools "$pools_file" || return 1

    # Build work queue (suites in the order given -- longest first by convention)
    local work_queue=("${suites[@]}")
    local queue_idx=0

    echo "Work queue (${#work_queue[@]} suites):"
    for s in "${work_queue[@]}"; do
        echo "  - $s"
    done
    echo ""

    # Ensure log directory exists
    mkdir -p "${_E2E_DIR_PA}/logs"

    # Dispatch loop: assign work to free pools
    while [ $queue_idx -lt ${#work_queue[@]} ] || [ ${#_JOB_PIDS[@]} -gt 0 ]; do

        # Try to dispatch to free pools
        while [ $queue_idx -lt ${#work_queue[@]} ]; do
            local free_idx
            free_idx=$(_find_free_pool) || break
            [ "$free_idx" -eq -1 ] && break

            local pool_name="${_POOL_NAMES[$free_idx]}"
            local suite="${work_queue[$queue_idx]}"

            _dispatch_job "$pool_name" "$free_idx" "$suite"
            (( queue_idx++ ))
        done

        # If there are running jobs, wait for one to finish
        if [ ${#_JOB_PIDS[@]} -gt 0 ]; then
            _wait_for_any
        fi
    done

    # Print summary
    _print_summary
}
