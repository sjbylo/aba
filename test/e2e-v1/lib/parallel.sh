#!/bin/bash
# =============================================================================
# E2E Test Framework -- Parallel Dispatch
# =============================================================================
# Work-queue dispatcher for running suites across pools in parallel.
#
# Reads pools.conf, builds a work queue (longest suites first), and
# dispatches jobs to available pools via tmux sessions on conN hosts.
# Each suite runs inside a detached tmux session so it survives SSH
# disconnections.  The dispatcher polls for completion and retrieves
# exit codes from rc files written on the remote host.
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

# --- _wait_ssh ---------------------------------------------------------------
#
# Wait for SSH to become available on a host. Lightweight poll loop.
# Usage: _wait_ssh HOST [TIMEOUT_SECS]
#
_wait_ssh() {
    local host="$1"
    local timeout="${2:-120}"
    local elapsed=0
    local interval=5

    while [ $elapsed -lt $timeout ]; do
        if ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no \
              -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$host" true 2>/dev/null; then
            return 0
        fi
        sleep $interval
        elapsed=$(( elapsed + interval ))
    done
    echo "  WARNING: SSH to $host not ready after ${timeout}s" >&2
    return 1
}

# --- _reset_pool -------------------------------------------------------------
#
# Revert pool VMs to the "pool-ready" snapshot (created by clone-and-check
# after all validations pass), power them on, and wait for SSH.
# This gives every suite a guaranteed clean starting state.
#
# Skip when E2E_RESET_POOL_BEFORE_SUITE=0 (for later: run without reset).
#
_reset_pool() {
    local pool_idx="$1"
    local pool_name="${_POOL_NAMES[$pool_idx]}"

    [ "${E2E_RESET_POOL_BEFORE_SUITE:-1}" = "0" ] && return 0

    local overrides="${_POOL_OVERRIDES[$pool_idx]}"
    local pool_num=""
    for ov in $overrides; do
        case "$ov" in POOL_NUM=*) pool_num="${ov#POOL_NUM=}" ;; esac
    done
    if [ -z "$pool_num" ]; then
        echo "  WARNING: No POOL_NUM for $pool_name -- skipping snapshot reset" >&2
        return 1
    fi

    local con_vm="con${pool_num}"
    local dis_vm="dis${pool_num}"
    local snapshot="pool-ready"

    # Verify snapshot exists before reverting
    if ! govc snapshot.tree -vm "$con_vm" 2>/dev/null | grep -q "$snapshot"; then
        echo "  ERROR: Snapshot '$snapshot' not found on $con_vm." >&2
        echo "         Run clone-and-check first (all validations must pass)." >&2
        return 1
    fi

    echo "  Resetting pool $pool_name: reverting $con_vm + $dis_vm to '$snapshot' ..."

    govc snapshot.revert -vm "$con_vm" "$snapshot" || { echo "  ERROR: revert $con_vm failed" >&2; return 1; }
    govc snapshot.revert -vm "$dis_vm" "$snapshot" || { echo "  ERROR: revert $dis_vm failed" >&2; return 1; }

    govc vm.power -on "$con_vm" 2>/dev/null || true
    govc vm.power -on "$dis_vm" 2>/dev/null || true

    sleep "${VM_BOOT_DELAY:-8}"

    local con_host="${_POOL_CONN_HOSTS[$pool_idx]}"
    local int_host="${_POOL_INT_HOSTS[$pool_idx]:--}"

    echo "  Waiting for SSH on $con_host ..."
    _wait_ssh "$con_host" 120 || return 1

    if [ -n "$int_host" ] && [ "$int_host" != "-" ]; then
        echo "  Waiting for SSH on $int_host ..."
        _wait_ssh "$int_host" 120 || return 1
    fi

    echo "  Pool $pool_name reset complete."
}

# --- _pool_ssh_target -------------------------------------------------------
#
# Return user@host for SSHing to a pool's connected bastion.
#
_pool_ssh_target() {
    local pool_idx="$1"
    local host="${_POOL_CONN_HOSTS[$pool_idx]}"
    local overrides="${_POOL_OVERRIDES[$pool_idx]}"
    local ssh_user="${CON_SSH_USER:-}"
    for override in $overrides; do
        case "$override" in CON_SSH_USER=*) ssh_user="${override#CON_SSH_USER=}" ;; esac
    done
    echo "${ssh_user:+${ssh_user}@}${host}"
}

# --- _build_remote_cmd ------------------------------------------------------
#
# Build the shell command that runs a suite on the remote conN host.
# Returns only the command string -- no SSH wrapper.
#
_build_remote_cmd() {
    local suite="$1"
    local pool_idx="$2"

    local overrides="${_POOL_OVERRIDES[$pool_idx]}"

    local env_exports="export E2E_ON_BASTION=1; "
    [ -n "${ABA_TESTING:-}" ] && env_exports+="export ABA_TESTING=1; "

    for override in $overrides; do
        env_exports+="export $override; "
    done

    local pass_vars=""
    for var in TEST_CHANNEL OCP_VERSION INT_BASTION_RHEL_VER CON_SSH_USER DIS_SSH_USER OC_MIRROR_VER; do
        if [ -n "${!var:-}" ] && ! echo "$overrides" | grep -q "^${var}="; then
            pass_vars+="export $var='${!var}'; "
        fi
    done

    local extra_flags=""
    [ -n "${NOTIFY_CMD:-}" ] && extra_flags+=" --notify"
    [ -n "${CLI_RESUME:-}" ] && extra_flags+=" --resume"
    [ -n "${CLI_CLEAN:-}" ] && extra_flags+=" --clean"

    echo "${env_exports}${pass_vars}cd ~/aba && test/e2e/run.sh --suite $suite --ci${extra_flags}"
}

# SSH options used for all dispatcher-to-conN connections
_DISPATCH_SSH_OPTS="-o LogLevel=ERROR -o ConnectTimeout=30 -o BatchMode=yes"

# Polling interval (seconds) for checking tmux session status
_TMUX_POLL_INTERVAL=30

# --- _dispatch_job ----------------------------------------------------------
#
# Start a suite inside a tmux session on the remote conN host.
# A background subshell polls for completion and exits with the suite's
# exit code (read from an rc file on conN).  This makes the suite survive
# SSH disconnections between the dispatcher and conN.
#
_dispatch_job() {
    local pool_name="$1"
    local pool_idx="$2"
    local suite="$3"

    local host="${_POOL_CONN_HOSTS[$pool_idx]}"
    local ssh_target
    ssh_target="$(_pool_ssh_target "$pool_idx")"
    local log_file="${_E2E_DIR_PA}/logs/${pool_name}-suite-${suite}.log"

    local tmux_name="e2e-${pool_name}-${suite}"
    local rc_file="/tmp/${tmux_name}.rc"
    local remote_log="/tmp/${tmux_name}.log"
    local wrapper_script="/tmp/${tmux_name}-run.sh"

    echo "  DISPATCH: $suite -> $pool_name ($host)"

    _JOB_SUITES[$pool_name]="$suite"
    _JOB_START[$pool_name]=$(date +%s)
    _JOB_LOG[$pool_name]="$log_file"

    local remote_cmd
    remote_cmd="$(_build_remote_cmd "$suite" "$pool_idx")"

    # Upload a wrapper script to conN (avoids quoting issues with tmux)
    ssh $_DISPATCH_SSH_OPTS "$ssh_target" \
        "cat > $wrapper_script && chmod +x $wrapper_script" <<-WRAPPER
	#!/bin/bash
	rm -f $rc_file
	(
	$remote_cmd
	)
	_rc=\$?
	echo "\$_rc" > $rc_file
	exit \$_rc
	WRAPPER

    # Kill any stale tmux session, start a new one
    ssh $_DISPATCH_SSH_OPTS "$ssh_target" \
        "tmux kill-session -t $tmux_name 2>/dev/null || true; \
         touch $remote_log; \
         tmux new-session -d -s $tmux_name '$wrapper_script >> $remote_log 2>&1'"

    # Background subshell: stream log + poll for tmux session completion
    (
        # Best-effort log streaming from conN to local log file
        ssh -T $_DISPATCH_SSH_OPTS "$ssh_target" \
            "tail -f -n +1 $remote_log 2>/dev/null" \
            > "$log_file" 2>&1 &
        local tail_pid=$!

        # Poll until the tmux session ends
        while ssh $_DISPATCH_SSH_OPTS "$ssh_target" \
              "tmux has-session -t $tmux_name 2>/dev/null"; do
            sleep "$_TMUX_POLL_INTERVAL"
        done

        sleep 2
        kill $tail_pid 2>/dev/null; wait $tail_pid 2>/dev/null

        # Retrieve exit code from rc file on conN
        local rc
        rc=$(ssh $_DISPATCH_SSH_OPTS "$ssh_target" "cat $rc_file 2>/dev/null") || rc=255
        rc="${rc//[^0-9]/}"
        exit "${rc:-255}"
    ) &
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
        # Pause on first failure (unless E2E_PAUSE_ON_FAILURE=0 or --ci)
        if [ "${E2E_PAUSE_ON_FAILURE:-1}" != "0" ]; then
            _DISPATCH_PAUSED=1
            _DISPATCH_PAUSED_POOL="$pool_name"
            _DISPATCH_PAUSED_SUITE="$suite"
        fi
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

# --- tmux_cleanup_pools -----------------------------------------------------
#
# Kill all e2e-* tmux sessions and remove rc/log/wrapper files on conN hosts.
# Called by --clean and --destroy-pools for hygiene.
#
# Usage: tmux_cleanup_pools POOLS_FILE
#
tmux_cleanup_pools() {
    local pools_file="${1:-$_E2E_DIR_PA/pools.conf}"
    load_pools "$pools_file" 2>/dev/null || return 0

    local i
    for i in "${!_POOL_NAMES[@]}"; do
        local ssh_target
        ssh_target="$(_pool_ssh_target "$i")"
        echo "  Cleaning tmux sessions on ${_POOL_CONN_HOSTS[$i]} ..."
        ssh $_DISPATCH_SSH_OPTS "$ssh_target" \
            "tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^e2e-' | \
             while read -r s; do tmux kill-session -t \"\$s\" 2>/dev/null; done; \
             rm -f /tmp/e2e-*.rc /tmp/e2e-*.log /tmp/e2e-*-run.sh" 2>/dev/null || true
    done
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

    # Pause on first failure (set in _record_result unless E2E_PAUSE_ON_FAILURE=0)
    _DISPATCH_PAUSED=""
    _DISPATCH_PAUSED_POOL=""
    _DISPATCH_PAUSED_SUITE=""

    # Dispatch loop: assign work to free pools
    while [ $queue_idx -lt ${#work_queue[@]} ] || [ ${#_JOB_PIDS[@]} -gt 0 ]; do

        # Try to dispatch to free pools (skip new work when paused so we can debug)
        while [ $queue_idx -lt ${#work_queue[@]} ] && [ -z "${_DISPATCH_PAUSED:-}" ]; do
            local free_idx
            free_idx=$(_find_free_pool) || break
            [ "$free_idx" -eq -1 ] && break

            local pool_name="${_POOL_NAMES[$free_idx]}"
            local suite="${work_queue[$queue_idx]}"

            _reset_pool "$free_idx"
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

    if [ -n "${_DISPATCH_PAUSED:-}" ]; then
        echo ""
        echo "  Paused due to failure: ${_DISPATCH_PAUSED_SUITE} on ${_DISPATCH_PAUSED_POOL}."
        echo "  Debug and add pool cleanup as needed, then re-run when ready."
        echo "  (Set E2E_PAUSE_ON_FAILURE=0 or use --ci to run to completion without pausing.)"
        echo ""
        return 1
    fi
}
