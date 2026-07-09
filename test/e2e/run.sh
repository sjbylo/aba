#!/usr/bin/env bash
# =============================================================================
# E2E Test Framework v2 -- Coordinator
# =============================================================================
# Slim orchestrator: parses CLI, routes to command modules, runs dispatcher.
#
# All command logic lives in lib/ modules:
#   lib/remote.sh    -- SSH wrappers (_essh, _escp, _con_target, ...)
#   lib/cli.sh       -- Argument parsing (_parse_args, _parse_pools, ...)
#   lib/deploy.sh    -- Harness sync (sync_harness, sync_source, deploy_pool)
#   lib/commands.sh  -- One-shot commands (stop, start, status, verify, ...)
#   lib/tmux-ui.sh   -- Dashboard / live / attach
#   lib/constants.sh -- Shared constants
#   lib/dispatcher.sh -- Work-queue dispatcher
# =============================================================================

set -u

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 2) )); then
	echo "ERROR: Bash 4.2+ is required (you have $BASH_VERSION)." >&2
	exit 1
fi

_RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ABA_ROOT="$(cd "$_RUN_DIR/../.." && pwd)"

# --- Source modules -----------------------------------------------------------

source "$_RUN_DIR/lib/constants.sh"
source "$_RUN_DIR/lib/remote.sh"
source "$_RUN_DIR/lib/cli.sh"
source "$_RUN_DIR/lib/deploy.sh"
source "$_RUN_DIR/lib/commands.sh"
source "$_RUN_DIR/lib/tmux-ui.sh"
source "$_RUN_DIR/lib/dispatcher.sh"
source "$_RUN_DIR/lib/infra.sh"

# --- Parse args + load config ------------------------------------------------

_ORIGINAL_ARGS=("$@")
_parse_args "$_RUN_DIR" "$@"
_load_config "$_RUN_DIR"
_detect_git_metadata "$_ABA_ROOT"
_generate_deploy_config "$_RUN_DIR"

_DEPLOY_CONFIG_ENV="$_RUN_DIR/.config.env.deploy"

# --- Acquire per-pool locks for mutating commands -----------------------------
# Per-pool locks allow concurrent run.sh instances targeting different pools.
# Global lock is only taken for --recreate-golden (shared golden VM resource).
# Read-only / UI commands skip locks entirely.

# Lock fds tracked globally so _essh/_escp can close them before exec,
# preventing child processes from inheriting (and holding) the flocks.
_LOCK_FDS=()

_acquire_pool_locks() {
	local _fd=10
	for _p in $CLI_POOL_LIST; do
		local _lockfile="${E2E_POOL_LOCK_PREFIX}-${_p}.lock"
		eval "exec ${_fd}>\"$_lockfile\""
		if ! flock -n "$_fd"; then
			echo "FATAL: Pool $_p is locked by another run.sh instance" >&2
			exit 1
		fi
		echo $$ >&$_fd
		_LOCK_FDS+=("$_fd")
		_fd=$(( _fd + 1 ))
	done
}

_release_pool_locks() {
	for _fd in "${_LOCK_FDS[@]}"; do
		eval "exec ${_fd}>&-" 2>/dev/null
	done
	_LOCK_FDS=()
}
trap _release_pool_locks EXIT

case "$CLI_COMMAND" in
	stop|status|attach|list|live|dash|daemon|reschedule|deploy|verify|destroy|logs|kill)
		;;
	run)
		# Skip locks when not daemonized: the foreground process will either
		# inject suites into a running daemon or launch a new one (which acquires
		# locks itself via the inner "run" child).
		if [ -n "${_E2E_DAEMONIZED:-}" ]; then
			if [ -n "${CLI_RECREATE_GOLDEN:-}" ]; then
				exec 9>"$E2E_GLOBAL_LOCK"
				if ! flock -n 9; then
					echo "FATAL: Another run.sh instance is rebuilding the golden VM" >&2
					exit 1
				fi
				echo $$ >&9
				_LOCK_FDS+=(9)
			fi
			_acquire_pool_locks
		fi
		;;
	*)
		if [ -n "${CLI_RECREATE_GOLDEN:-}" ]; then
			exec 9>"$E2E_GLOBAL_LOCK"
			if ! flock -n 9; then
				echo "FATAL: Another run.sh instance is rebuilding the golden VM" >&2
				exit 1
			fi
			echo $$ >&9
			_LOCK_FDS+=(9)
		fi
		_acquire_pool_locks
		;;
esac

# --- Route one-shot commands --------------------------------------------------

case "$CLI_COMMAND" in
	attach)
		cmd_attach "$CLI_ATTACH"
		;;
	live)
		cmd_live "$CLI_POOL_LIST" "$_RUN_DIR"
		;;
	dash)
		cmd_dash "$CLI_POOL_LIST"
		;;
	logs)
		_log="$_RUN_DIR/logs/daemon.log"
		if [ ! -f "$_log" ]; then
			echo "No daemon log found at: $_log"
			exit 1
		fi
		exec tail -F "$_log"
		;;
	list)
		cmd_list "$_RUN_DIR"
		exit 0
		;;
	status)
		cmd_status "$CLI_POOL_LIST"
		exit 0
		;;
	kill)
		cmd_kill
		exit 0
		;;
	stop)
		_all_pools=$(_all_pool_numbers "${_RUN_DIR}/pools.conf") || _all_pools="$CLI_POOL_LIST"
		cmd_stop "$CLI_POOL_LIST" "$_all_pools"
		exit 0
		;;
	start)
		cmd_start "$CLI_POOL_LIST"
		exit 0
		;;
	verify)
		cmd_verify "$CLI_POOL_LIST" "$_RUN_DIR"
		exit $?
		;;
	destroy)
		cmd_destroy "$CLI_POOL_LIST"
		exit 0
		;;
	deploy)
		cmd_deploy "$CLI_POOL_LIST" "$_ABA_ROOT" "$_DEPLOY_CONFIG_ENV"
		exit 0
		;;
	reschedule)
		local_suites=()
		read -ra local_suites <<< "$(resolve_suites "$_RUN_DIR")" || exit 1
		validate_suites "$_RUN_DIR" "${local_suites[@]}" || exit 1
		cmd_reschedule "$_RUN_DIR" "${local_suites[@]}"
		exit 0
		;;
	daemon)
		_DAEMON_LOG="$_RUN_DIR/logs/daemon.log"
		_DAEMON_MAX_CRASHES=5
		_DAEMON_BACKOFF=5
		_DAEMON_BACKOFF_MAX=60
		_daemon_crashes=0
		_daemon_backoff=$_DAEMON_BACKOFF

		mkdir -p "$_RUN_DIR/logs"

		_daemon_log() { printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$_DAEMON_LOG"; }

		# Rebuild the original args, replacing "daemon" with "run"
		_daemon_args=()
		for _a in "${_ORIGINAL_ARGS[@]}"; do
			[ "$_a" = "daemon" ] && _a="run"
			_daemon_args+=("$_a")
		done
		# Only force-clean on the FIRST daemon launch (not on restart cycles).
		# Subsequent cycles inherit running suites -- force would kill them.
		_daemon_first_run=1

		# Refuse to start if another daemon is already running with overlapping pools
		if [ -f "$E2E_DAEMON_PID" ]; then
			_old_pid=$(cat "$E2E_DAEMON_PID" 2>/dev/null)
			if [ -n "$_old_pid" ] && kill -0 "$_old_pid" 2>/dev/null; then
				_old_pools=""
				[ -f "$E2E_DAEMON_META" ] && _old_pools=$(grep '^pools=' "$E2E_DAEMON_META" 2>/dev/null | cut -d= -f2-)
				_overlap=""
				for _rp in $CLI_POOL_LIST; do
					for _ep in $_old_pools; do
						[ "$_rp" = "$_ep" ] && _overlap="${_overlap} ${_rp}"
					done
				done
				if [ -n "$_overlap" ]; then
					echo "FATAL: Daemon already running (PID $_old_pid, pools: ${_old_pools:-unknown})."
					echo "       Pool overlap:${_overlap}"
					echo "       Stop the old daemon first: run.sh kill  OR  kill $_old_pid"
					exit 1
				fi
			fi
		fi

		echo $$ > "$E2E_DAEMON_PID"
		trap 'rm -f "$E2E_DAEMON_PID" "$E2E_DAEMON_META"' EXIT
		trap '' PIPE  # Ignore SIGPIPE so piping daemon output can't crash it

		# Write metadata so `status` can show daemon config
		cat > "$E2E_DAEMON_META" <<-META_EOF
		pid=$$
		pools=$CLI_POOL_LIST
		started=$(date '+%Y-%m-%d %H:%M:%S')
		args=${_daemon_args[*]}
		META_EOF

		_daemon_log "Daemon started (PID=$$, max_crashes=$_DAEMON_MAX_CRASHES, backoff=${_DAEMON_BACKOFF}s-${_DAEMON_BACKOFF_MAX}s)"
		_daemon_log "Args: ${_daemon_args[*]}"

		export _E2E_DAEMONIZED=1

		while true; do
			# Build per-cycle args: add --force only on the very first launch
			_cycle_args=("${_daemon_args[@]}")
			if [ -n "$_daemon_first_run" ]; then
				_has_force=""
				for _a in "${_cycle_args[@]}"; do
					[[ "$_a" =~ ^(-f|-F|--force|--fresh)$ ]] && _has_force=1
				done
				[ -z "$_has_force" ] && _cycle_args+=("--force")
				_daemon_first_run=""
			fi
			_daemon_log "Launching dispatcher ..."
			_drc=0
			"$BASH" "$_RUN_DIR/run.sh" "${_cycle_args[@]}" || _drc=$?

			if [ "$_drc" -eq 0 ]; then
				_daemon_log "Dispatcher exited cleanly (all suites completed). Restarting full cycle ..."
				_daemon_crashes=0
				_daemon_backoff=$_DAEMON_BACKOFF
				if [ -n "${NOTIFY_CMD:-}" ] && [ -x "${NOTIFY_CMD%% *}" ]; then
					$NOTIFY_CMD "[e2e-daemon] All suites done. Restarting cycle." < /dev/null >/dev/null &
				fi
				sleep 5
				continue
			fi

			_daemon_crashes=$(( _daemon_crashes + 1 ))
			_daemon_log "Dispatcher CRASHED (exit=$_drc, crash #${_daemon_crashes}/${_DAEMON_MAX_CRASHES})"

			if [ -n "${NOTIFY_CMD:-}" ] && [ -x "${NOTIFY_CMD%% *}" ]; then
				$NOTIFY_CMD "[e2e-daemon] Dispatcher crashed (exit=$_drc, #${_daemon_crashes}). Restarting in ${_daemon_backoff}s ..." < /dev/null >/dev/null &
			fi

			if [ "$_daemon_crashes" -ge "$_DAEMON_MAX_CRASHES" ]; then
				_daemon_log "FATAL: $_DAEMON_MAX_CRASHES consecutive crashes. Giving up."
				if [ -n "${NOTIFY_CMD:-}" ] && [ -x "${NOTIFY_CMD%% *}" ]; then
					$NOTIFY_CMD "[e2e-daemon] FATAL: ${_DAEMON_MAX_CRASHES} consecutive crashes. Daemon stopped." < /dev/null >/dev/null &
				fi
				exit 1
			fi

			_daemon_log "Sleeping ${_daemon_backoff}s before restart ..."
			sleep "$_daemon_backoff"
			_daemon_backoff=$(( _daemon_backoff * 2 ))
			[ "$_daemon_backoff" -gt "$_DAEMON_BACKOFF_MAX" ] && _daemon_backoff=$_DAEMON_BACKOFF_MAX
		done
		;;
esac

# =============================================================================
# From here on: only "run" and "restart" reach this code.
# =============================================================================

# --- Auto-daemonize "run" command ---------------------------------------------
# When invoked interactively (not already inside the daemon wrapper):
#  1. If a daemon is already running, inject the requested suites and exit.
#  2. Otherwise, launch a background daemon process (nohup + disown) and exit.
# The daemon process handles crash recovery and restarts.

_is_daemon_alive() {
	[ -f "$E2E_DAEMON_PID" ] || return 1
	local _pid
	_pid=$(cat "$E2E_DAEMON_PID" 2>/dev/null) || return 1
	[ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null
}

if [ "$CLI_COMMAND" = "run" ] && [ -z "${_E2E_DAEMONIZED:-}" ]; then

	# --- If a daemon is already running, inject suites into its queue ---------
	if _is_daemon_alive; then
		_daemon_pid=$(cat "$E2E_DAEMON_PID")

		# Check for pool overlap if the new invocation specifies pools
		if [ -f "$E2E_DAEMON_META" ]; then
			_running_pools=$(grep '^pools=' "$E2E_DAEMON_META" 2>/dev/null | cut -d= -f2-)
			if [ -n "$_running_pools" ] && [ -n "$CLI_POOL_LIST" ]; then
				_overlap=""
				for _rp in $CLI_POOL_LIST; do
					for _ep in $_running_pools; do
						[ "$_rp" = "$_ep" ] && _overlap="${_overlap} ${_rp}"
					done
				done
				_new_only=""
				for _rp in $CLI_POOL_LIST; do
					_found=""
					for _ep in $_running_pools; do [ "$_rp" = "$_ep" ] && _found=1 && break; done
					[ -z "$_found" ] && _new_only="${_new_only} ${_rp}"
				done
				if [ -n "$_new_only" ]; then
					echo ""
					echo "  WARNING: Daemon (PID $_daemon_pid) manages pools: $_running_pools"
					echo "           Your -p includes pools not in the daemon:${_new_only}"
					echo "           Those pools will NOT receive dispatched suites."
					echo "           To manage all pools, stop the daemon and restart with the correct -p range."
					echo ""
				fi
			fi
		fi

		echo ""
		echo "  Daemon already running (PID $_daemon_pid). Injecting suites ..."
		echo ""

		_inject_suites=()
		if [ -n "${CLI_ALL:-}" ]; then
			read -ra _inject_suites <<< "$(all_suite_names "$_RUN_DIR")"
		elif [ -n "${CLI_SUITE:-}" ]; then
			IFS=',' read -ra _inject_suites <<< "$CLI_SUITE"
		fi

		if [ ${#_inject_suites[@]} -eq 0 ]; then
			echo "  No suites specified. Use -s SUITE or -a/--all."
			echo "  (daemon is still running)"
			exit 0
		fi

		validate_suites "$_RUN_DIR" "${_inject_suites[@]}" || exit 1

		for _s in "${_inject_suites[@]}"; do
			(
				flock 9
				if [ -f "$E2E_INJECT_QUEUE" ] && [ -s "$E2E_INJECT_QUEUE" ]; then
					_existing=$(cat "$E2E_INJECT_QUEUE")
					printf '%s\n%s\n' "$_s" "$_existing" > "$E2E_INJECT_QUEUE"
				else
					echo "$_s" > "$E2E_INJECT_QUEUE"
				fi
			) 9>"${E2E_INJECT_QUEUE}.lock"
			printf "  Queued: \033[1;36m%s\033[0m\n" "$_s"
		done

		echo ""
		echo "  ${#_inject_suites[@]} suite(s) injected. Dispatcher will pick them up shortly."
		echo ""
		exit 0
	fi

	# --- No daemon running: launch one in the background ----------------------
	mkdir -p "$_RUN_DIR/logs"
	_DAEMON_LOG="$_RUN_DIR/logs/daemon.log"

	# Build daemon args (replacing "run" with "daemon")
	_bg_args=()
	for _a in "${_ORIGINAL_ARGS[@]}"; do
		[ "$_a" = "run" ] && _a="daemon"
		_bg_args+=("$_a")
	done

	# Export environment to a temp file so the daemon inherits GOVC_*, proxy, etc.
	_env_file=$(mktemp /tmp/e2e-daemon-env.XXXXXX)
	env -0 > "$_env_file"

	# Launch: import env, then exec into the daemon
	(
		while IFS= read -r -d '' _line; do
			[[ "$_line" =~ ^[a-zA-Z_][a-zA-Z0-9_]*= ]] && export "$_line" 2>/dev/null
		done < "$_env_file"
		rm -f "$_env_file"
		cd "$_RUN_DIR"
		export _E2E_DAEMONIZED=1
		exec "$BASH" "$_RUN_DIR/run.sh" "${_bg_args[@]}"
	) >> "$_DAEMON_LOG" 2>&1 &
	_bg_pid=$!
	disown "$_bg_pid" 2>/dev/null

	# Brief wait to confirm the daemon started and wrote its PID
	sleep 1
	if kill -0 "$_bg_pid" 2>/dev/null; then
		echo ""
		echo "  Dispatcher launched in background (PID: $_bg_pid)"
		echo ""
		echo "  Monitor with:"
		echo "    ./run.sh status                  # quick status of all pools"
		echo "    ./run.sh logs                    # tail dispatcher log"
		echo "    ./run.sh live                    # attach to pool sessions"
		echo "    ./run.sh attach conN             # attach to a single pool"
		echo ""
		echo "  Add more suites:"
		echo "    ./run.sh run -s suite-name       # inject into running daemon"
		echo "    ./run.sh run -a                  # inject all suites"
		echo "    ./run.sh reschedule -s suite-name"
		echo ""
		echo "  Stop:"
		echo "    ./run.sh stop                    # stop all pools + daemon"
		echo ""
		echo "  Logs: $_DAEMON_LOG"
		echo ""
	else
		echo "ERROR: Daemon process failed to start. Check: $_DAEMON_LOG" >&2
		rm -f "$_env_file"
		exit 1
	fi

	exit 0
fi

# --- Determine suites to run -------------------------------------------------

suites_to_run=()

if [ -n "${CLI_RESUME:-}" ]; then
	# --resume picks up from a specific pool's last suites
	if [ "$(echo "$CLI_POOL_LIST" | wc -w)" -ne 1 ]; then
		echo "ERROR: --resume requires exactly one pool (e.g. -p 2)" >&2
		exit 1
	fi
	_resume_pool=$(echo "$CLI_POOL_LIST" | tr -d ' ')
	_last=$(_ssh_con "$_resume_pool" "cat /tmp/e2e-last-suites 2>/dev/null" 2>/dev/null) || _last=""
	if [ -z "$_last" ]; then
		echo "ERROR: No previous suite record on con${_resume_pool} (/tmp/e2e-last-suites not found)" >&2
		exit 1
	fi
	read -ra suites_to_run <<< "$_last"
	echo "  Re-running last suite(s) from con${_resume_pool}: ${suites_to_run[*]}"
elif [ -n "${CLI_ALL:-}" ]; then
	read -ra suites_to_run <<< "$(all_suite_names "$_RUN_DIR")"
elif [ -n "${CLI_SUITE:-}" ]; then
	IFS=',' read -ra suites_to_run <<< "$CLI_SUITE"
else
	echo "ERROR: Specify a command (run, reschedule, list, etc.). See --help." >&2
	_usage
	exit 1
fi

if [ ${#suites_to_run[@]} -eq 0 ]; then
	echo "No suites found."
	exit 0
fi

# Validate suite names (skip for --resume since those come from the remote host)
if [ -z "${CLI_RESUME:-}" ]; then
	validate_suites "$_RUN_DIR" "${suites_to_run[@]}" || exit 1
fi

# Randomize suite order so tests don't depend on alphabetical sequencing
if [ -n "${CLI_ALL:-}" ] && [ ${#suites_to_run[@]} -gt 1 ]; then
	readarray -t suites_to_run < <(printf '%s\n' "${suites_to_run[@]}" | shuf)
fi

# --- Restart mode: stop + deploy + re-launch ----------------------------------

if [ "$CLI_COMMAND" = "restart" ]; then
	echo ""
	echo "=== Restart: pool(s) ${CLI_POOL_LIST} ==="

	# 1) Stop
	echo ""
	echo "  [1/4] Stopping suites ..."
	_rc_glob="${E2E_RC_PREFIX}-*.rc ${E2E_RC_PREFIX}-*.lock /tmp/e2e-runner.rc /tmp/e2e-runner.lock"
	for p in $CLI_POOL_LIST; do
		printf "    con${p}: "
		if _ssh_con "$p" "
			tmux kill-session -t '$E2E_TMUX_SESSION' 2>/dev/null
			sudo rm -f $_rc_glob
			echo stopped
		"; then
			:
		else
			echo "unreachable"
		fi
	done

	# 1b) Reserve pools in dispatcher so it doesn't reclaim them during deploy
	_restart_suites="${CLI_SUITE:-}"
	if [ -n "$_restart_suites" ]; then
		for p in $CLI_POOL_LIST; do
			for _rs in $_restart_suites; do
				echo "$p $_rs" >> "$E2E_FORCED_DISPATCH"
			done
		done
	fi

	# 2) Cleanup
	echo ""
	echo "  [2/4] Cleaning up resources in cleanup lists ..."
	for p in $CLI_POOL_LIST; do
		printf "    con${p}: "
		_process_pool_cleanup_files "$p" 2>/dev/null && echo "done" || echo "unreachable"
	done

	# 3) Deploy harness + source
	echo ""
	_source_tar=""
	if [ -n "${CLI_DEV:-}" ]; then
		echo "  [3/4] Developer deploy: source + harness ..."
		_source_tar=$(_make_source_tar "$_ABA_ROOT")
		_deploy_size=$(du -h "$_source_tar" | cut -f1)
		echo "    Source tarball: $_deploy_size"
	else
		echo "  [3/4] Deploying harness only (suite installs ABA from internet) ..."
	fi

	for p in $CLI_POOL_LIST; do
		deploy_pool "$p" "$_ABA_ROOT" "$_DEPLOY_CONFIG_ENV" "$_source_tar"
	done
	[ -n "$_source_tar" ] && rm -f "$_source_tar"

	# 4) Re-launch last suite on each pool
	echo ""
	echo "  [4/4] Re-launching last suite(s) ..."
	_restart_ok=0; _restart_fail=0
	for p in $CLI_POOL_LIST; do
		if [ -n "${CLI_SUITE:-}" ]; then
			_last="$CLI_SUITE"
		else
			_last=$(_ssh_con "$p" "cat /tmp/e2e-last-suites 2>/dev/null" 2>/dev/null) || _last=""
		fi
		if [ -z "$_last" ]; then
			echo "    con${p}: skipped (no previous suite or unreachable)"
			_restart_fail=$(( _restart_fail + 1 ))
			continue
		fi
		read -ra _last_suites <<< "$_last"
		for suite in "${_last_suites[@]}"; do
			_resume_flag=""
			[ -n "${CLI_RESUME:-}" ] && _resume_flag="--resume"
			_runner_cmd="bash ~/.e2e-harness/runner.sh $_resume_flag $p $suite"
			if _ssh_con "$p" "tmux set-option -g history-limit 200000 2>/dev/null; tmux new-session -d -s '$E2E_TMUX_SESSION' '$_runner_cmd'; tmux rename-window -t '$E2E_TMUX_SESSION' '$suite'" 2>/dev/null; then
				echo "    con${p}: dispatched $suite (tmux: $E2E_TMUX_SESSION)"
				_restart_ok=$(( _restart_ok + 1 ))
			else
				echo "    con${p}: FAILED to dispatch $suite"
				_restart_fail=$(( _restart_fail + 1 ))
			fi
		done
	done

	echo ""
	echo "  Restart complete: ${_restart_ok} suite(s) launched, ${_restart_fail} pool(s) skipped."
	_save_last_run "$_RUN_DIR"
	exit 0
fi

# =============================================================================
# --- "run" command: ensure infra, deploy harness, run dispatcher --------------
# =============================================================================

# --- Dry run ------------------------------------------------------------------

if [ -n "${CLI_DRY_RUN:-}" ]; then
	echo ""
	echo "=== DRY RUN (work-queue dispatch) ==="
	echo "  Pools available: ${CLI_POOL_LIST}"
	echo "  Suites (${#suites_to_run[@]}): ${suites_to_run[*]}"
	echo ""
	echo "  Dispatch order (one suite at a time to free pools):"
	for (( i=0; i<${#suites_to_run[@]}; i++ )); do
		printf "    %2d. %s\n" "$(( i+1 ))" "${suites_to_run[$i]}"
	done
	echo ""
	_npool=0
	for _p in $CLI_POOL_LIST; do _npool=$(( _npool + 1 )); done
	echo "  With ${_npool} pool(s), up to ${_npool} suites run concurrently."
	echo "  Each pool receives the next suite when it finishes."
	echo ""
	exit 0
fi

# --- Ensure infrastructure (extracted to lib/infra.sh) ------------------------

declare -A _pool_os_map=()
_ensure_pool_infrastructure

# --- Optional revert to pool-ready snapshot (extracted to lib/infra.sh) -------

if [ -n "${CLI_REVERT:-}" ]; then
	_revert_pool_snapshots
fi

# --- Deploy harness to conN (extracted to lib/deploy.sh) ----------------------

# Pre-flight: verify notify.sh exists if NOTIFY_CMD is configured
_notify_cmd=$(grep '^NOTIFY_CMD=' "$_RUN_DIR/config.env" | head -1 | cut -d= -f2- | sed "s/[[:space:]]*#.*//; s/^['\"]//; s/['\"]$//")
_notify_cmd="${_notify_cmd/#\~/$HOME}"
if [ -n "$_notify_cmd" ] && ! [ -x "$_notify_cmd" ]; then
	echo "FATAL: config.env sets NOTIFY_CMD=$_notify_cmd but the file does not exist." >&2
	echo "  Create the file or clear NOTIFY_CMD in config.env." >&2
	exit 1
fi

_save_last_run "$_RUN_DIR"
_deploy_to_pools

# =============================================================================
# --- Dynamic Work-Queue Dispatcher -------------------------------------------
# =============================================================================
# Functions from lib/dispatcher.sh. State arrays declared here (top-level).
# =============================================================================

declare -A _completed=()
declare -A _busy_pools=()
declare -A _external_running=()
declare -a _work_queue=()
declare -A _results=()
declare -A _result_pool=()
declare -A _bad_pools_map=()
declare -A _unreachable_pools=()

# Apply --fresh / --force scoping
if [ -n "${CLI_FORCE:-}" ]; then
	_pool_count=0
	for _p in $CLI_POOL_LIST; do _pool_count=$(( _pool_count + 1 )); done

	if [ "$_pool_count" -eq 1 ] && [ -n "${CLI_SUITE:-}" ]; then
		_detect_running_and_completed
		_force_clean_suite "$CLI_SUITE"
	elif [ "$_pool_count" -eq 1 ]; then
		_detect_running_and_completed
		_pool=$(echo "$CLI_POOL_LIST" | tr -d ' ')
		_force_clean_pool "$_pool"
	elif [ -n "${CLI_SUITE:-}" ]; then
		_detect_running_and_completed
		_force_clean_suite "$CLI_SUITE"
	else
		_force_clean_all
	fi
else
	_detect_running_and_completed
fi

# Seed _results with already-completed suites
for s in "${!_completed[@]}"; do
	_results[$s]="${_completed[$s]}"
done

# Consume pre-existing inject queue
if [ -f "$E2E_INJECT_QUEUE" ] && [ -s "$E2E_INJECT_QUEUE" ]; then
	_pre_injected=()
	while IFS= read -r _pi; do
		[ -z "$_pi" ] && continue
		_pre_injected+=("$_pi")
	done < "$E2E_INJECT_QUEUE"
	> "$E2E_INJECT_QUEUE"
	if [ ${#_pre_injected[@]} -gt 0 ]; then
		_new_suites=()
		for _pi in "${_pre_injected[@]}"; do
			_found=""
			for _es in "${suites_to_run[@]}"; do
				[ "$_es" = "$_pi" ] && _found=1 && break
			done
			if [ -n "$_found" ]; then
				printf "  [%s] PRIORITY: %s (from earlier reschedule, moved to front)\n" "$(date '+%H:%M:%S')" "$_pi"
			else
				printf "  [%s] PRIORITY: %s (from earlier reschedule, added to front)\n" "$(date '+%H:%M:%S')" "$_pi"
				suites_to_run+=("$_pi")
			fi
			_new_suites+=("$_pi")
		done
		for _es in "${suites_to_run[@]}"; do
			_dup=""
			for _pi in "${_pre_injected[@]}"; do
				[ "$_es" = "$_pi" ] && _dup=1 && break
			done
			[ -z "$_dup" ] && _new_suites+=("$_es")
		done
		suites_to_run=("${_new_suites[@]}")
	fi
fi

_build_work_queue

_num_completed=${#_completed[@]}
_num_running=${#_busy_pools[@]}

echo ""
echo "  Status: ${_num_completed} completed, ${_num_running} running, ${#_work_queue[@]} queued"

if [ ${#_work_queue[@]} -eq 0 ] && [ $_num_running -eq 0 ]; then
	if [ $_num_completed -gt 0 ]; then
		echo "  All suites already completed:"
		for _cs in "${!_completed[@]}"; do
			if [ "${_completed[$_cs]}" -eq 0 ] 2>/dev/null; then
				printf "    \033[32mPASS\033[0m  %s\n" "$_cs"
			else
				printf "    \033[1;31mFAIL\033[0m  %s (exit=%s)\n" "$_cs" "${_completed[$_cs]}"
			fi
		done
		echo "  Use 'reschedule' or --force to re-run."
	else
		echo "  Nothing to dispatch."
	fi
else
	[ ${#_work_queue[@]} -gt 0 ] && echo "  Queue: ${_work_queue[*]}"
	if [ $_num_running -gt 0 ]; then
		echo "  Running:"
		for _p in "${!_busy_pools[@]}"; do
			echo "    con${_p}: ${_busy_pools[$_p]}"
		done
	fi
fi
echo ""

# Notification on clean start
if [ $_num_completed -eq 0 ] && [ $_num_running -eq 0 ] && [ ${#_work_queue[@]} -gt 0 ]; then
	if [ -n "${NOTIFY_CMD:-}" ] && [ -x "${NOTIFY_CMD%% *}" ]; then
		_notify_detail="Pools: ${CLI_POOL_LIST}  Host: $(hostname -s)
Started: $(date '+%Y-%m-%d %H:%M')
Queued (${#_work_queue[@]}):"
		for _qs in "${_work_queue[@]}"; do
			_notify_detail+="
  ${_qs}"
		done
		$NOTIFY_CMD "[e2e] DISPATCHER STARTED: ${#_work_queue[@]} suites
${_notify_detail}" < /dev/null >/dev/null
	fi
fi

# Auto-open summary dashboard
DASH_SESSION=""
_npool=0
for _p in $CLI_POOL_LIST; do _npool=$(( _npool + 1 )); done
if [ -z "${CLI_QUIET:-}" ] && [ "$_npool" -gt 1 ] && { [ ${#_work_queue[@]} -gt 0 ] || [ $_num_running -gt 0 ]; }; then
	DASH_SESSION="e2e-dashboard"
	_pools_arr=()
	for _p in $CLI_POOL_LIST; do _pools_arr+=("$_p"); done
	_create_tmux_dashboard "$DASH_SESSION" "$_npool" "summary.log" "${_pools_arr[@]}"
	echo "  Summary dashboard opened (run.sh dash to reattach)"
	echo ""
fi

# --- One-shot force dispatch --------------------------------------------------

_pool_count=0
for _p in $CLI_POOL_LIST; do _pool_count=$(( _pool_count + 1 )); done
if [ -n "${CLI_FORCE:-}" ] && [ "$_pool_count" -eq 1 ] && [ -n "${CLI_SUITE:-}" ]; then
	if [ -f "$E2E_DISPATCHER_PID" ]; then
		_old_dpid=$(cat "$E2E_DISPATCHER_PID")
		if [ -n "$_old_dpid" ] && [ "$_old_dpid" != "$$" ] && kill -0 "$_old_dpid" 2>/dev/null; then
			_pool=$(echo "$CLI_POOL_LIST" | tr -d ' ')
			printf "\n  Dispatcher running (pid %s) -- one-shot dispatch\n" "$_old_dpid"
			declare -A _retried=()
			_force_suite="${suites_to_run[0]}"
			printf "  \033[1;36mFORCE DISPATCH:\033[0m \033[1;33m%s\033[0m -> pool %s\n" "$_force_suite" "$_pool"
			_dispatch_suite "$_pool" "$_force_suite"
			echo "$_pool $_force_suite" >> "$E2E_FORCED_DISPATCH"
			if [ ${#suites_to_run[@]} -gt 1 ]; then
				printf "  NOTE: Only first suite dispatched (one pool = one suite). Remaining queued:\n"
				for (( _fi=1; _fi<${#suites_to_run[@]}; _fi++ )); do
					printf "    %s\n" "${suites_to_run[$_fi]}"
					echo "${suites_to_run[$_fi]}" >> "$E2E_INJECT_QUEUE"
				done
			fi
			echo "  Done."
			exit 0
		fi
	fi
fi

# --- Dispatcher takeover check ------------------------------------------------

if [ -f "$E2E_DISPATCHER_PID" ]; then
	_old_dpid=$(cat "$E2E_DISPATCHER_PID")
	if [ -n "$_old_dpid" ] && [ "$_old_dpid" != "$$" ] && kill -0 "$_old_dpid" 2>/dev/null; then
		printf "\n  \033[1;33mWARNING: Another dispatcher is already running (pid %s)\033[0m\n" "$_old_dpid"
		if [ -n "${CLI_YES:-}" ]; then _answer="y"; else
			printf "  Kill it and take over? (Y/n): "; read -r -t 30 _answer || _answer="n"
		fi
		if [[ "$_answer" =~ ^[Yy]?$ ]]; then
			kill "$_old_dpid" 2>/dev/null; sleep 1; echo "  Killed old dispatcher."
		else
			echo "  Aborted."; exit 1
		fi
	fi
fi
echo $$ > "$E2E_DISPATCHER_PID"
trap 'rm -f "$E2E_DISPATCHER_PID" "$E2E_DISPATCH_STATE" "$E2E_FORCED_DISPATCH" "$E2E_FORCE_RERUN"' EXIT

declare -A _retried=()
declare -A _pool_dead_count=()
_MAX_RETRIES=2
_queue_idx=0
_DEAD_THRESHOLD=3
_POLL_MIN=5
_POLL_MAX=10
_poll_interval=$_POLL_MIN

if [ ${#_work_queue[@]} -gt 0 ] || [ $_num_running -gt 0 ]; then
	echo "  Dispatching ... (Ctrl-C safe: restart run.sh to reconnect)"
	echo "  (Monitor: run.sh live | Single pool: run.sh attach conN)"
	echo ""
fi

# --- Main dispatch loop (extracted to lib/dispatcher.sh) ----------------------

_dispatch_loop

# --- Final summary (from lib/dispatcher.sh) -----------------------------------

_overall_rc=0
_print_final_summary

[ -n "$DASH_SESSION" ] && tmux kill-session -t "$DASH_SESSION" 2>/dev/null

exit "$_overall_rc"
