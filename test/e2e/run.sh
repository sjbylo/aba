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
#          [--dry-run] [--sync]
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
CLI_REBUILD_GOLDEN=""
CLI_MATRIX=""
CLI_INTERACTIVE=""
CLI_CI=""
CLI_RESUME=""
CLI_CLEAN=""
CLI_NOTIFY=""
CLI_NO_NOTIFY=""
CLI_DRY_RUN=""
CLI_SYNC=""
CLI_LIST=""
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
            --rebuild-golden)
                CLI_REBUILD_GOLDEN=1; shift ;;
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
            --sync)
                CLI_SYNC=1; shift ;;
            --list|-l)
                CLI_LIST=1; shift ;;
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
	  run.sh --list                 List available suites
	  run.sh --destroy-pools        Power off all pool VMs
	
	Suite selection:
	  --suite NAME          Run suite by name (e.g. cluster-ops)
	  --suites N1,N2,...    Run multiple suites (comma-separated)
	  --all                 Run all suites found in suites/
	  -l, --list            List available suite names and exit
	
	Parallel execution:
	  --parallel            Dispatch suites to remote pools via SSH
	  --pools FILE          Pool configuration file (default: pools.conf)
	  --create-pools N      Create N pools from VM templates before running
	  --destroy-pools       Power off all pool VMs and exit
	  --rebuild-golden      Destroy and recreate the golden VM from scratch
	  --matrix              Expand parameter combinations across pools
	  --dry-run             Show dispatch plan without executing
	  --sync                Rsync local aba tree to conN before dispatch (dev convenience)
	
	Test parameters (override config.env defaults):
	  -c, --channel CHAN    Channel: stable, fast, candidate
	  -v, --version VER     Version: l (latest), p (previous), or x.y.z
	  -r, --rhel VER        RHEL version: rhel8, rhel9, rhel10
	  -u, --user USER       DIS_SSH_USER (user on disconnected bastion)
	
	Execution modes:
	  -i, --interactive     Prompt on failure: retry, skip, or abort
	  --ci                  Non-interactive, no prompts (default for --parallel)
	  --resume              Resume from last checkpoint (skip passed tests)
	  --clean               Delete checkpoint state files before running
	
	Notifications:
	  --notify              Enable notifications (uses NOTIFY_CMD from config.env)
	  --no-notify           Disable notifications
	
	Examples:
	  run.sh --list                                  # Show available suites
	  run.sh --suite cluster-ops                     # Run one suite
	  run.sh --suite cluster-ops -i                  # Interactive: prompt on failure
	  run.sh --suite cluster-ops --resume            # Resume, skip already-passed tests
	  run.sh --suites cluster-ops,mirror-sync        # Run two suites
	  run.sh --all --dry-run                         # Show execution plan
	  run.sh --all                                   # Run all suites sequentially
	  run.sh --parallel --all                        # Run all suites across pools
	  run.sh -c fast -v l --suite cluster-ops        # Override channel and version
	
	USAGE
}

# --- Apply Parameters -------------------------------------------------------

apply_params() {
    # Apply CLI overrides to environment variables
    [ -n "$CLI_CHANNEL" ] && export TEST_CHANNEL="$CLI_CHANNEL"
    [ -n "$CLI_VERSION" ] && export OCP_VERSION="$CLI_VERSION"
    [ -n "$CLI_RHEL" ]    && export INT_BASTION_RHEL_VER="$CLI_RHEL"
    [ -n "$CLI_USER" ]    && export DIS_SSH_USER="$CLI_USER"

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

    # clone-and-check must run first (creates VMs); then longest suites for optimal parallel scheduling
    local ordered=()
    for s in clone-and-check \
             airgapped-local-reg airgapped-existing-reg mirror-sync \
             cluster-ops connected-public network-advanced create-bundle-to-disk; do
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

# Returns 0 if the suite must run on the coordinator (e.g. clone-and-check with govc).
suite_is_coordinator_only() {
    local name="$1"
    local file="$_RUN_DIR/suites/suite-${name}.sh"
    [ -f "$file" ] && grep -q '^E2E_COORDINATOR_ONLY=true' "$file" 2>/dev/null
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
    # Suites like clone-and-check create VMs and need govc on the coordinator.
    if grep -q '^E2E_COORDINATOR_ONLY=true' "$suite_file" 2>/dev/null; then
        if [ -z "${E2E_SUPPRESS_COORDINATOR_BANNER:-}" ]; then
            echo ""
            echo "========================================"
            echo "  Running suite: $suite_name (coordinator-only, running locally)"
            echo "========================================"
            echo ""
        fi

        # Load pool-specific overrides from pools.conf so VC_FOLDER etc. are correct.
        # These must be exported BEFORE the suite runs, because config.env uses
        # ${VAR:-default} and will respect pre-existing environment values.
        local _pool_num="${POOL_NUM:-1}"
        if [ -n "${CLI_POOLS_FILE:-}" ] && [ -f "$CLI_POOLS_FILE" ]; then
            while IFS= read -r _pline; do
                [[ "$_pline" =~ ^[[:space:]]*# ]] && continue
                [[ -z "${_pline// }" ]] && continue
                local _found_num=""
                for _tok in $_pline; do
                    case "$_tok" in POOL_NUM=*) _found_num="${_tok#POOL_NUM=}" ;; esac
                done
                if [ "$_found_num" = "$_pool_num" ]; then
                    for _tok in $_pline; do
                        case "$_tok" in *=*) export "$_tok" ;; esac
                    done
                    break
                fi
            done < "$CLI_POOLS_FILE"
        fi

        # State file: use caller-set E2E_STATE_FILE (e.g. per-pool) or default
        local _state_file="${E2E_STATE_FILE:-${E2E_LOG_DIR}/${suite_name}.state}"
        if [ -n "$CLI_RESUME" ]; then
            if [ -f "$_state_file" ]; then
                export E2E_RESUME_FILE="$_state_file"
                echo "  Resuming from checkpoint: $_state_file"
            fi
        fi
        if [ -n "$CLI_CLEAN" ]; then
            rm -f "$_state_file"
            echo "  Cleaned checkpoint state for $suite_name"
        fi

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

        local _state_file="${E2E_STATE_FILE:-${E2E_LOG_DIR}/${suite_name}.state}"
        if [ -n "$CLI_RESUME" ]; then
            if [ -f "$_state_file" ]; then
                export E2E_RESUME_FILE="$_state_file"
                echo "  Resuming from checkpoint: $_state_file"
            fi
        fi
        if [ -n "$CLI_CLEAN" ]; then
            rm -f "$_state_file"
            echo "  Cleaned checkpoint state for $suite_name"
        fi

        bash "$suite_file"
        return $?
    fi

    # --- Dispatch to connected bastion via SSH -----------------------------

    local ssh_target
    ssh_target="$(pool_connected_bastion)"
    local con_host="$ssh_target"

    echo ""
    echo "========================================"
    echo "  Running suite: $suite_name (dispatching to $con_host)"
    echo "========================================"
    echo ""

    # --sync: rsync local aba working tree to conN (dev convenience for testing
    # uncommitted changes). Without --sync, conN uses whatever _vm_install_aba
    # cloned from git, which matches the real user workflow.
    if [ -n "$CLI_SYNC" ]; then
        local _dirty
        _dirty="$(git -C "$_ABA_ROOT" status --porcelain 2>/dev/null)"
        if [ -n "$_dirty" ]; then
            echo "  WARNING: aba tree has uncommitted changes -- syncing working tree as-is"
            git -C "$_ABA_ROOT" status --short 2>/dev/null | head -15 | while IFS= read -r _l; do
                echo "    $_l"
            done
            echo ""
        fi

        echo "  Syncing aba tree to $con_host (scripts only, max 3MB per file) ..."
        rsync -avz --max-size=3m \
            --exclude='mirror/' \
            --exclude='cli/' \
            --exclude='images/' \
            --exclude='demo1/' \
            --exclude='.git/' \
            --exclude='sno/' \
            --exclude='sno2/' \
            --exclude='compact/' \
            --exclude='standard/' \
            --exclude='*.tar' \
            --exclude='*.tar.gz' \
            --exclude='*.tgz' \
            --exclude='*.iso' \
            "$_ABA_ROOT/" "$ssh_target:~/aba/"

        local _notify_src
        _notify_src="$(eval echo "$NOTIFY_CMD" 2>/dev/null)"
        if [ -n "$_notify_src" ] && [ -x "$_notify_src" ]; then
            echo "  Syncing $(basename "$_notify_src") to $con_host ..."
            rsync -az "$_notify_src" "$ssh_target:$(dirname "$_notify_src")/"
        fi
    fi

    # Build environment variable exports (same pattern as parallel.sh)
    local env_exports="export E2E_ON_BASTION=1; "
    local var
    for var in TEST_CHANNEL OCP_VERSION INT_BASTION_RHEL_VER \
               DIS_SSH_USER OC_MIRROR_VER POOL_NUM ABA_TESTING \
               VC_FOLDER VM_DATASTORE; do
        [ -n "${!var:-}" ] && env_exports+="export $var='${!var}'; "
    done

    # Pass resume/clean/sync flags
    local extra_flags=""
    [ -n "$CLI_RESUME" ] && extra_flags+=" --resume"
    [ -n "$CLI_CLEAN" ]  && extra_flags+=" --clean"
    [ -n "$CLI_SYNC" ]   && extra_flags+=" --sync"

    # Interactive flag
    [ -n "${_E2E_INTERACTIVE:-}" ] && extra_flags+=" -i"

    # Dispatch to conN inside a tmux session so the suite survives SSH drops.
    # The user attaches to the session for live output; if SSH drops they
    # can re-run the same command to re-attach.
    local tmux_name="e2e-single-${suite_name}"
    local rc_file="/tmp/${tmux_name}.rc"
    local wrapper_script="/tmp/${tmux_name}-run.sh"
    local remote_cmd="${env_exports}cd ~/aba && test/e2e/run.sh --suite $suite_name $extra_flags"
    local _ssh_opts="-o LogLevel=ERROR -o ConnectTimeout=30 -o BatchMode=yes"

    echo "  Dispatching suite '$suite_name' to $con_host (tmux: $tmux_name) ..."

    # Check if a tmux session already exists (re-attach scenario)
    if ssh $_ssh_opts "$ssh_target" "tmux has-session -t $tmux_name 2>/dev/null"; then
        echo "  Found existing tmux session '$tmux_name' -- re-attaching ..."
    else
        # Upload wrapper script
        ssh $_ssh_opts "$ssh_target" \
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

        # Start tmux session
        ssh $_ssh_opts "$ssh_target" \
            "tmux kill-session -t $tmux_name 2>/dev/null || true; \
             tmux new-session -d -s $tmux_name $wrapper_script"
    fi

    # Attach so the user sees live output (-t for TTY)
    ssh -t -o LogLevel=ERROR -o ConnectTimeout=30 \
        -o ServerAliveInterval=60 -o ServerAliveCountMax=10 \
        "$ssh_target" \
        "tmux attach-session -t $tmux_name 2>/dev/null || echo 'Session already ended.'"

    # Session ended or user detached -- wait for suite to finish either way.
    # Without this, the sequential loop would start the next suite while this one
    # is still running (multiple suites on the same host, stepping on each other).
    while ssh $_ssh_opts "$ssh_target" "tmux has-session -t $tmux_name 2>/dev/null"; do
        echo ""
        echo "  Suite still running in tmux '$tmux_name' (SSH dropped or detached)."
        echo "  Waiting for it to finish ... (re-attach: ssh $ssh_target -t 'tmux attach -t $tmux_name')"
        # Poll every 30s until the tmux session exits
        while ssh $_ssh_opts "$ssh_target" "tmux has-session -t $tmux_name 2>/dev/null"; do
            sleep 30
        done
        echo "  Session '$tmux_name' finished."
    done

    # Retrieve exit code
    local rc
    rc=$(ssh $_ssh_opts "$ssh_target" "cat $rc_file 2>/dev/null") || rc=255
    rc="${rc//[^0-9]/}"
    return "${rc:-255}"
}

# --- Main -------------------------------------------------------------------

main() {
    parse_args "$@"

    # Initialize the framework (sources config.env defaults)
    e2e_setup

    # Apply CLI overrides AFTER config.env so they take precedence
    apply_params

    # List suites and exit if requested
    if [ -n "$CLI_LIST" ]; then
        echo "Available suites:"
        echo ""
        local _suites _file _desc _tag
        read -ra _suites <<< "$(all_suites)"
        for s in "${_suites[@]}"; do
            _file="$_RUN_DIR/suites/suite-${s}.sh"
            _desc="$(grep -m1 '^# Suite:' "$_file" 2>/dev/null | sed 's/^# Suite: *//')"
            # Tag coordinator-only suites (infra/provisioning)
            _tag=""
            grep -q '^E2E_COORDINATOR_ONLY=true' "$_file" 2>/dev/null && _tag=" [infra]"
            printf "  %-30s %s%s\n" "$s" "$_desc" "$_tag"
        done
        echo ""
        echo "Note: [infra] suites provision pool VMs (run via --create-pools or manually)."
        echo ""
        echo "Run:  test/e2e/run.sh --suite <name>"
        echo "      test/e2e/run.sh --suite <name> -i   # interactive (prompt on failure)"
        exit 0
    fi

    # Destroy pools and exit if requested
    if [ -n "$CLI_DESTROY_POOLS" ]; then
        local _vmconf
        _vmconf="$(eval echo "${VMWARE_CONF:-~/.vmware.conf}")"
        if [ -f "$_vmconf" ]; then
            set -a; source "$_vmconf"; set +a
        fi
        source "$_RUN_DIR/lib/parallel.sh"
        tmux_cleanup_pools "$CLI_POOLS_FILE"
        destroy_pools --all
        exit 0
    fi

    # Create pools if requested
    if [ -n "$CLI_CREATE_POOLS" ]; then
        local _vmconf
        _vmconf="$(eval echo "${VMWARE_CONF:-~/.vmware.conf}")"
        if [ -f "$_vmconf" ]; then
            set -a; source "$_vmconf"; set +a
        else
            echo "ERROR: VMware config not found: $_vmconf" >&2
            exit 1
        fi
        local _cp_flags=(--pools-file "$CLI_POOLS_FILE")
        [ -n "$CLI_REBUILD_GOLDEN" ] && _cp_flags+=(--rebuild-golden)
        # Always skip Phase 1/2 when creating pools so clone-and-check is the only cloner (one clone per VM, no double-clone).
        [ -n "$CLI_CREATE_POOLS" ] && _cp_flags+=(--skip-phase2)
        create_pools "$CLI_CREATE_POOLS" "${_cp_flags[@]}" || { echo "ERROR: create_pools failed" >&2; exit 1; }
    fi

    # Determine which suites to run
    local suites_to_run=()

    if [ -n "$CLI_ALL" ]; then
        read -ra suites_to_run <<< "$(all_suites)"
        # Skip clone-and-check when --create-pools is not used (VMs already exist with pool-ready)
        if [ -z "$CLI_CREATE_POOLS" ]; then
            local filtered=()
            for s in "${suites_to_run[@]}"; do
                [ "$s" = "clone-and-check" ] && echo "  Skipping clone-and-check (no --create-pools; VMs assumed ready)" && continue
                filtered+=("$s")
            done
            suites_to_run=("${filtered[@]}")
        fi
    elif [ -n "$CLI_SUITE" ]; then
        # Handle comma-separated suite list
        IFS=',' read -ra suites_to_run <<< "$CLI_SUITE"
    else
        echo "ERROR: Specify --suite NAME, --all, or --list to see available suites" >&2
        usage
        exit 1
    fi

    if [ ${#suites_to_run[@]} -eq 0 ]; then
        echo "No suites found to run."
        exit 0
    fi

    echo "Suites to run: ${suites_to_run[*]}"
    echo "Parameters: channel=${TEST_CHANNEL:-?} version=${OCP_VERSION:-?} rhel=${INT_BASTION_RHEL_VER:-?} con_user=${CON_SSH_USER:-?} dis_user=${DIS_SSH_USER:-?}"
    echo ""

    # Dry run: just show the plan
    if [ -n "$CLI_DRY_RUN" ]; then
        echo "=== DRY RUN ==="
        for s in "${suites_to_run[@]}"; do
            echo "  Would run: $s"
        done
        exit 0
    fi

    # Parallel mode: run coordinator-only suites locally, dispatch the rest to pools
    if [ -n "$CLI_PARALLEL" ]; then
        source "$_RUN_DIR/lib/parallel.sh"
        # Source vmware.conf so govc is available for snapshot revert in _reset_pool
        local _vmconf
        _vmconf="$(eval echo "${VMWARE_CONF:-~/.vmware.conf}")"
        if [ -f "$_vmconf" ]; then
            set -a; source "$_vmconf"; set +a
        fi
        # CI runs to completion; otherwise pause on first suite failure for debugging
        [ -n "$CLI_CI" ] && export E2E_PAUSE_ON_FAILURE=0 || export E2E_PAUSE_ON_FAILURE="${E2E_PAUSE_ON_FAILURE:-1}"
        if [ -n "$CLI_CLEAN" ]; then
            tmux_cleanup_pools "$CLI_POOLS_FILE"
        fi
        # Rotate previous run's log so current run gets a fresh e2e-parallel.log when teed
        if [ -f "$_ABA_ROOT/e2e-parallel.log" ]; then
            mv "$_ABA_ROOT/e2e-parallel.log" "$_ABA_ROOT/e2e-parallel.log.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
        fi
        local coordinator_suites=()
        local pool_suites=()
        local s
        for s in "${suites_to_run[@]}"; do
            if suite_is_coordinator_only "$s"; then
                coordinator_suites+=("$s")
            else
                pool_suites+=("$s")
            fi
        done
        local overall_rc=0
        if [ ${#coordinator_suites[@]} -gt 0 ]; then
            echo "Running coordinator-only suites locally: ${coordinator_suites[*]}"
            for s in "${coordinator_suites[@]}"; do
                if [ "$s" = "clone-and-check" ] && [ ${#pool_suites[@]} -gt 0 ]; then
                    # clone-and-check runs once per pool so each pool's conN/disN get pool-ready snapshot
                    load_pools "$CLI_POOLS_FILE" || { echo "ERROR: load_pools failed" >&2; exit 1; }
                    local _max_pools="${CLI_CREATE_POOLS:-${#_POOL_NAMES[@]}}"
                    [ "$_max_pools" -gt "${#_POOL_NAMES[@]}" ] && _max_pools="${#_POOL_NAMES[@]}"
                    echo "  (clone-and-check will run ${_max_pools} time(s), once per pool)"
                    echo ""
                    local i
                    for i in "${!_POOL_NAMES[@]}"; do
                        [ "$i" -ge "$_max_pools" ] && break
                        local overrides="${_POOL_OVERRIDES[$i]:-}"
                        local pool_num=""
                        local ov
                        for ov in $overrides; do
                            case "$ov" in POOL_NUM=*) pool_num="${ov#POOL_NUM=}" ;; esac
                        done
                        [ -z "$pool_num" ] && continue
                        echo ""
                        echo "  --- clone-and-check for ${_POOL_NAMES[$i]} (POOL_NUM=$pool_num) ---"
                        for ov in $overrides; do
                            case "$ov" in ?*=*) export "$ov" ;; esac
                        done
                        # Per-pool state file: clone-and-check.pool1.state, .pool2.state, etc.
                        export E2E_STATE_FILE="${E2E_LOG_DIR}/${s}.pool${pool_num}.state"
                        [ -n "$CLI_RESUME" ] && export E2E_RESUME_FILE="$E2E_STATE_FILE"
                        export E2E_SUPPRESS_COORDINATOR_BANNER=1
                        run_suite_local "$s" || overall_rc=1
                        unset E2E_SUPPRESS_COORDINATOR_BANNER 2>/dev/null || true
                        unset E2E_STATE_FILE E2E_RESUME_FILE 2>/dev/null || true
                    done
                else
                    run_suite_local "$s" || overall_rc=1
                fi
            done
            echo ""
        fi
        if [ ${#pool_suites[@]} -gt 0 ]; then
            dispatch_all "$CLI_POOLS_FILE" "${pool_suites[@]}" || overall_rc=1
        fi
        exit $overall_rc
    fi

    # Local sequential mode
    local overall_rc=0
    local start_time=$(date +%s)

    _e2e_notify "E2E started: ${suites_to_run[*]} ($(date))"

    for suite in "${suites_to_run[@]}"; do
        local rc=0
        if [ "$suite" = "clone-and-check" ] && [ -f "${CLI_POOLS_FILE:-}" ]; then
            # Run clone-and-check once per pool (same as parallel path) so all pools get VMs and pool-ready
            source "$_RUN_DIR/lib/parallel.sh"
            if ! load_pools "$CLI_POOLS_FILE"; then
                echo "ERROR: load_pools failed" >&2
                rc=1
                overall_rc=1
            else
            local _max_pools="${CLI_CREATE_POOLS:-${#_POOL_NAMES[@]}}"
            [ "$_max_pools" -gt "${#_POOL_NAMES[@]}" ] && _max_pools="${#_POOL_NAMES[@]}"
            echo "  (clone-and-check will run ${_max_pools} time(s), once per pool)"
            local i
            for i in "${!_POOL_NAMES[@]}"; do
                [ "$i" -ge "$_max_pools" ] && break
                local overrides="${_POOL_OVERRIDES[$i]:-}"
                local pool_num=""
                local ov
                for ov in $overrides; do
                    case "$ov" in POOL_NUM=*) pool_num="${ov#POOL_NUM=}" ;; esac
                done
                [ -z "$pool_num" ] && continue
                echo ""
                echo "  --- clone-and-check for ${_POOL_NAMES[$i]} (POOL_NUM=$pool_num) ---"
                for ov in $overrides; do
                    case "$ov" in ?*=*) export "$ov" ;; esac
                done
                export E2E_STATE_FILE="${E2E_LOG_DIR:-$_RUN_DIR/logs}/${suite}.pool${pool_num}.state"
                [ -n "$CLI_RESUME" ] && export E2E_RESUME_FILE="$E2E_STATE_FILE"
                run_suite_local "$suite" || rc=$?
                unset E2E_STATE_FILE E2E_RESUME_FILE 2>/dev/null || true
                if [ $rc -ne 0 ]; then
                    echo "$(_e2e_red "Suite FAILED: $suite pool $pool_num (exit=$rc)")"
                    overall_rc=1
                    break
                fi
            done
            fi
        else
            run_suite_local "$suite" || rc=$?
        fi
        if [ $rc -ne 0 ]; then
            echo ""
            [ "$suite" != "clone-and-check" ] && echo "$(_e2e_red "Suite FAILED: $suite (exit=$rc)")"
            overall_rc=1
            if [ -n "${_E2E_INTERACTIVE:-}" ]; then
                echo ""
                echo "Suite '$suite' failed (exit=$rc). What now?"
                echo "  c = continue to next suite"
                echo "  r = retry this suite"
                echo "  a = abort (stop all)"
                local _choice=""
                while true; do
                    read -r -p "  [c/r/a] > " _choice
                    case "$_choice" in
                        c) echo "  Continuing ..."; break ;;
                        r) echo "  Retrying $suite ..."; rc=0; continue 2 ;;
                        a) echo "  Aborting."; break 2 ;;
                        *) echo "  Invalid choice. Enter c, r, or a." ;;
                    esac
                done
            elif [ -z "$CLI_CI" ]; then
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
