#!/bin/bash
# =============================================================================
# E2E Test Framework -- Main Runner
# =============================================================================
# Entry point for running E2E test suites, either locally (sequential) or
# across remote pools (parallel).
#
# Usage:
#   run.sh [--suite NAME | --all]
#          [--parallel [--pools FILE] [--create-pools N] [--destroy-pools]]
#          [--matrix --channel c1,c2 --rhel r1,r2 --user u1,u2]
#          [--interactive | -i | --ci]
#          [--resume | --clean]
#          [--notify | --no-notify]
#          [--dry-run]
#          [-c CHANNEL] [-v VERSION] [-r RHEL] [-u USER]
# =============================================================================

set -u

# Resolve paths
_RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ABA_ROOT="$(cd "$_RUN_DIR/../.." && pwd)"

# --- Source libraries -------------------------------------------------------

source "$_RUN_DIR/lib/framework.sh"
source "$_RUN_DIR/lib/config-helpers.sh"
source "$_RUN_DIR/lib/remote.sh"
source "$_RUN_DIR/lib/pool-lifecycle.sh"

# --- CLI Variables ----------------------------------------------------------

CLI_SUITE=""
CLI_ALL=""
CLI_PARALLEL=""
CLI_POOLS_FILE="$_RUN_DIR/pools.conf"
CLI_CREATE_POOLS=""
CLI_DESTROY_POOLS=""
CLI_MATRIX=""
CLI_INTERACTIVE=""
CLI_CI=""
CLI_RESUME=""
CLI_CLEAN=""
CLI_NOTIFY=""
CLI_NO_NOTIFY=""
CLI_DRY_RUN=""
CLI_CHANNEL=""
CLI_VERSION=""
CLI_RHEL=""
CLI_USER=""

# Matrix parameters (comma-separated lists for expansion)
CLI_MATRIX_CHANNEL=""
CLI_MATRIX_RHEL=""
CLI_MATRIX_USER=""

# --- Parse Arguments --------------------------------------------------------

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --suite)
                CLI_SUITE="$2"; shift 2 ;;
            --suites)
                CLI_SUITE="$2"; shift 2 ;;  # alias: comma-separated list
            --all)
                CLI_ALL=1; shift ;;
            --parallel)
                CLI_PARALLEL=1; shift ;;
            --pools)
                CLI_POOLS_FILE="$2"; shift 2 ;;
            --create-pools)
                CLI_CREATE_POOLS="$2"; shift 2 ;;
            --destroy-pools)
                CLI_DESTROY_POOLS=1; shift ;;
            --matrix)
                CLI_MATRIX=1; shift ;;
            --interactive|-i)
                CLI_INTERACTIVE=1; shift ;;
            --ci)
                CLI_CI=1; shift ;;
            --resume)
                CLI_RESUME=1; shift ;;
            --clean)
                CLI_CLEAN=1; shift ;;
            --notify)
                CLI_NOTIFY=1; shift ;;
            --no-notify)
                CLI_NO_NOTIFY=1; shift ;;
            --dry-run)
                CLI_DRY_RUN=1; shift ;;
            -c|--channel)
                CLI_CHANNEL="$2"; shift 2 ;;
            -v|--version)
                CLI_VERSION="$2"; shift 2 ;;
            -r|--rhel)
                CLI_RHEL="$2"; shift 2 ;;
            -u|--user)
                CLI_USER="$2"; shift 2 ;;
            --help|-h)
                usage; exit 0 ;;
            *)
                echo "Unknown option: $1" >&2
                usage; exit 1 ;;
        esac
    done
}

# --- Usage ------------------------------------------------------------------

usage() {
    cat <<-'USAGE'
	E2E Test Framework -- Runner
	
	Usage:
	  run.sh --suite NAME           Run a specific suite
	  run.sh --all                  Run all suites sequentially
	  run.sh --parallel --all       Run all suites across pools in parallel
	  run.sh --destroy-pools        Power off all pool VMs
	
	Suite selection:
	  --suite NAME          Run suite by name (e.g. connected-sync)
	  --suites N1,N2,...    Run multiple suites (comma-separated)
	  --all                 Run all suites found in suites/
	
	Parallel execution:
	  --parallel            Dispatch suites to remote pools via SSH
	  --pools FILE          Pool configuration file (default: pools.conf)
	  --create-pools N      Create N pools from VM templates before running
	  --destroy-pools       Power off all pool VMs and exit
	  --matrix              Expand parameter combinations across pools
	  --dry-run             Show dispatch plan without executing
	
	Test parameters (override config.env defaults):
	  -c, --channel CHAN    Channel: stable, fast, candidate
	  -v, --version VER     Version: l (latest), p (previous), or x.y.z
	  -r, --rhel VER        RHEL version: rhel8, rhel9, rhel10
	  -u, --user USER       Test user on internal bastion
	
	Execution modes:
	  -i, --interactive     Prompt on failure: retry, skip, or abort
	  --ci                  Non-interactive, no prompts (default for --parallel)
	  --resume              Resume from last checkpoint (skip passed tests)
	  --clean               Delete checkpoint state files before running
	
	Notifications:
	  --notify              Enable notifications (uses NOTIFY_CMD from config.env)
	  --no-notify           Disable notifications
	
	USAGE
}

# --- Apply Parameters -------------------------------------------------------

apply_params() {
    # Apply CLI overrides to environment variables
    [ -n "$CLI_CHANNEL" ] && export TEST_CHANNEL="$CLI_CHANNEL"
    [ -n "$CLI_VERSION" ] && export VER_OVERRIDE="$CLI_VERSION"
    [ -n "$CLI_RHEL" ]    && export INTERNAL_BASTION_RHEL_VER="$CLI_RHEL"
    [ -n "$CLI_USER" ]    && export TEST_USER="$CLI_USER"

    # Interactive mode
    if [ -n "$CLI_CI" ]; then
        export _E2E_INTERACTIVE=""
    elif [ -n "$CLI_INTERACTIVE" ]; then
        export _E2E_INTERACTIVE=1
    elif [ -n "$CLI_PARALLEL" ]; then
        export _E2E_INTERACTIVE=""  # non-interactive for parallel
    else
        # Default: interactive for local runs if on a TTY
        [ -t 0 ] && export _E2E_INTERACTIVE=1 || export _E2E_INTERACTIVE=""
    fi

    # Notifications
    if [ -n "$CLI_NO_NOTIFY" ]; then
        export NOTIFY_CMD=""
    elif [ -n "$CLI_NOTIFY" ]; then
        export NOTIFY_CMD="${NOTIFY_CMD:-notify.sh}"
    fi
}

# --- Suite Discovery --------------------------------------------------------

all_suites() {
    # Find all suite files and return their names (without path and prefix)
    local suite_dir="$_RUN_DIR/suites"
    local suites=()

    if [ -d "$suite_dir" ]; then
        for f in "$suite_dir"/suite-*.sh; do
            [ -f "$f" ] || continue
            local name
            name="$(basename "$f" .sh)"
            name="${name#suite-}"
            suites+=("$name")
        done
    fi

    # Sort: longest suites first for optimal parallel scheduling
    # Order: airgapped-local-reg, airgapped-existing-reg, connected-sync,
    #        connected-public, network-advanced, bundle-disk
    local ordered=()
    for s in airgapped-local-reg airgapped-existing-reg connected-sync \
             connected-public network-advanced bundle-disk; do
        for found in "${suites[@]}"; do
            [ "$found" = "$s" ] && ordered+=("$found")
        done
    done

    # Add any suites not in the predefined order
    for found in "${suites[@]}"; do
        local in_ordered=""
        for o in "${ordered[@]}"; do
            [ "$found" = "$o" ] && in_ordered=1
        done
        [ -z "$in_ordered" ] && ordered+=("$found")
    done

    echo "${ordered[@]}"
}

resolve_suite_file() {
    local name="$1"
    local file="$_RUN_DIR/suites/suite-${name}.sh"
    if [ -f "$file" ]; then
        echo "$file"
    else
        echo "ERROR: Suite not found: $file" >&2
        return 1
    fi
}

# --- Run a Suite on the Connected Bastion -----------------------------------
#
# Dispatches the suite to conN via SSH. The coordinator only orchestrates;
# all L commands execute on conN, all R commands SSH from conN to disN.
#
# If E2E_ON_BASTION is already set, we're running on conN (dispatched by a
# previous coordinator call) -- run the suite directly, no re-dispatch.
#

run_suite_local() {
    local suite_name="$1"
    local suite_file
    suite_file="$(resolve_suite_file "$suite_name")" || return 1

    # --- Guard: coordinator-only suite? Run locally. -----------------------
    # Suites like clone-check create VMs and need govc on the coordinator.
    if grep -q '^E2E_COORDINATOR_ONLY=true' "$suite_file" 2>/dev/null; then
        echo ""
        echo "========================================"
        echo "  Running suite: $suite_name (coordinator-only, running locally)"
        echo "========================================"
        echo ""
        bash "$suite_file"
        return $?
    fi

    # --- Guard: already on bastion? Run directly. --------------------------
    if [ -n "${E2E_ON_BASTION:-}" ]; then
        echo ""
        echo "========================================"
        echo "  Running suite: $suite_name (on bastion)"
        echo "========================================"
        echo ""

        # Handle resume
        if [ -n "$CLI_RESUME" ]; then
            local state_file="${E2E_LOG_DIR}/${suite_name}.state"
            if [ -f "$state_file" ]; then
                export E2E_RESUME_FILE="$state_file"
                echo "  Resuming from checkpoint: $state_file"
            fi
        fi

        # Handle clean
        if [ -n "$CLI_CLEAN" ]; then
            rm -f "${E2E_LOG_DIR}/${suite_name}.state"
            echo "  Cleaned checkpoint state for $suite_name"
        fi

        bash "$suite_file"
        return $?
    fi

    # --- Dispatch to connected bastion via SSH -----------------------------

    local con_host
    con_host="$(pool_connected_bastion)"

    echo ""
    echo "========================================"
    echo "  Running suite: $suite_name (dispatching to $con_host)"
    echo "========================================"
    echo ""

    # Sync latest test framework + scripts to conN
    echo "  Syncing aba tree to $con_host ..."
    rsync -az --delete \
        --exclude='mirror/save/' \
        --exclude='mirror/.oc-mirror/' \
        --exclude='cli/' \
        --exclude='.git/' \
        "$_ABA_ROOT/" "$con_host:~/aba/"

    # Build environment variable exports (same pattern as parallel.sh)
    local env_exports="export E2E_ON_BASTION=1; "
    local var
    for var in TEST_CHANNEL VER_OVERRIDE INTERNAL_BASTION_RHEL_VER \
               TEST_USER OC_MIRROR_VER POOL_NUM ABA_TESTING; do
        [ -n "${!var:-}" ] && env_exports+="export $var='${!var}'; "
    done

    # Pass resume/clean flags
    local extra_flags=""
    [ -n "$CLI_RESUME" ] && extra_flags+=" --resume"
    [ -n "$CLI_CLEAN" ]  && extra_flags+=" --clean"

    # Interactive flag
    [ -n "${_E2E_INTERACTIVE:-}" ] && extra_flags+=" -i"

    # Dispatch to conN via SSH (-t for TTY, needed for interactive mode)
    echo "  Dispatching suite '$suite_name' to $con_host ..."
    ssh -t -o LogLevel=ERROR -o ConnectTimeout=30 "$con_host" -- \
        "${env_exports}cd ~/aba && test/e2e/run.sh --suite $suite_name $extra_flags"
}

# --- Main -------------------------------------------------------------------

main() {
    parse_args "$@"

    # Initialize the framework (sources config.env defaults)
    e2e_setup

    # Apply CLI overrides AFTER config.env so they take precedence
    apply_params

    # Destroy pools and exit if requested
    if [ -n "$CLI_DESTROY_POOLS" ]; then
        destroy_pools --all
        exit 0
    fi

    # Create pools if requested
    if [ -n "$CLI_CREATE_POOLS" ]; then
        create_pools "$CLI_CREATE_POOLS"
    fi

    # Determine which suites to run
    local suites_to_run=()

    if [ -n "$CLI_ALL" ]; then
        read -ra suites_to_run <<< "$(all_suites)"
    elif [ -n "$CLI_SUITE" ]; then
        # Handle comma-separated suite list
        IFS=',' read -ra suites_to_run <<< "$CLI_SUITE"
    else
        echo "ERROR: Specify --suite NAME or --all" >&2
        usage
        exit 1
    fi

    if [ ${#suites_to_run[@]} -eq 0 ]; then
        echo "No suites found to run."
        exit 0
    fi

    echo "Suites to run: ${suites_to_run[*]}"
    echo "Parameters: channel=${TEST_CHANNEL:-?} version=${VER_OVERRIDE:-?} rhel=${INTERNAL_BASTION_RHEL_VER:-?} user=${TEST_USER:-?}"
    echo ""

    # Dry run: just show the plan
    if [ -n "$CLI_DRY_RUN" ]; then
        echo "=== DRY RUN ==="
        for s in "${suites_to_run[@]}"; do
            echo "  Would run: $s"
        done
        exit 0
    fi

    # Parallel mode
    if [ -n "$CLI_PARALLEL" ]; then
        # Source parallel library
        source "$_RUN_DIR/lib/parallel.sh"
        dispatch_all "$CLI_POOLS_FILE" "${suites_to_run[@]}"
        exit $?
    fi

    # Local sequential mode
    local overall_rc=0
    local start_time=$(date +%s)

    _e2e_notify "E2E started: ${suites_to_run[*]} ($(date))"

    for suite in "${suites_to_run[@]}"; do
        local rc=0
        run_suite_local "$suite" || rc=$?
        if [ $rc -ne 0 ]; then
            echo ""
            echo "$(_e2e_red "Suite FAILED: $suite (exit=$rc)")"
            overall_rc=1
            # In non-CI mode, stop on first failure
            if [ -z "$CLI_CI" ] && [ -z "$CLI_ALL" ]; then
                break
            fi
        fi
    done

    local elapsed=$(( $(date +%s) - start_time ))
    local mins=$(( elapsed / 60 ))
    local secs=$(( elapsed % 60 ))

    echo ""
    echo "========================================"
    if [ $overall_rc -eq 0 ]; then
        echo "  $(_e2e_green "ALL SUITES PASSED") (${mins}m ${secs}s)"
        _e2e_notify "E2E PASSED: ${suites_to_run[*]} (${mins}m ${secs}s)"
    else
        echo "  $(_e2e_red "SOME SUITES FAILED") (${mins}m ${secs}s)"
        _e2e_notify "E2E FAILED: ${suites_to_run[*]} (${mins}m ${secs}s)"
    fi
    echo "========================================"

    exit $overall_rc
}

# Run main only if executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
