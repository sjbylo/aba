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

# --- Parse args + load config ------------------------------------------------

_parse_args "$_RUN_DIR" "$@"
_load_config "$_RUN_DIR"
_detect_git_metadata "$_ABA_ROOT"
_generate_deploy_config "$_RUN_DIR"

_DEPLOY_CONFIG_ENV="$_RUN_DIR/.config.env.deploy"

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
	list)
		cmd_list "$_RUN_DIR"
		exit 0
		;;
	status)
		cmd_status "$CLI_POOL_LIST"
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
esac

# =============================================================================
# From here on: only "run" and "restart" reach this code.
# =============================================================================

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

	# 2) Cleanup
	echo ""
	echo "  [2/4] Cleaning up resources in cleanup lists ..."
	for p in $CLI_POOL_LIST; do
		target=$(_con_target "$p")
		printf "    con${p}: "
		_essh "$target" 'set -f
			_found=""
			_log_dir="$HOME/.e2e-harness/logs"
			_ssh="ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

			for f in "$_log_dir"/*.cleanup; do
				[ -f "$f" ] || continue
				_found=1
				_file_ok=1
				while IFS=" " read -r tgt path; do
					[ -z "$path" ] && continue
					echo "  cluster: $tgt $path"
					$_ssh "$tgt" "[ -d '\''$path'\'' ] && { command -v aba >/dev/null 2>&1 && aba -y -d '\''$path'\'' delete || make -C '\''$path'\'' delete; } || echo '\''  (dir not found)'\''" < /dev/null 2>&1 || { echo "  WARNING: cleanup failed: $tgt $path"; _file_ok=""; }
				done < "$f"
				[ -n "$_file_ok" ] && rm -f "$f" || echo "  WARNING: keeping $(basename $f) -- some entries failed"
			done

			for f in "$_log_dir"/*.mirror-cleanup; do
				[ -f "$f" ] || continue
				_found=1
				_file_ok=1
				while IFS=" " read -r tgt path; do
					[ -z "$path" ] && continue
					echo "  mirror: $tgt $path"
					$_ssh "$tgt" "[ -d '\''$path'\'' ] && { command -v aba >/dev/null 2>&1 && aba -y -d '\''$path'\'' uninstall || make -C '\''$path'\'' uninstall; } || echo '\''  (dir not found)'\''" < /dev/null 2>&1 || { echo "  WARNING: cleanup failed: $tgt $path"; _file_ok=""; }
				done < "$f"
				[ -n "$_file_ok" ] && rm -f "$f" || echo "  WARNING: keeping $(basename $f) -- some entries failed"
			done

			[ -n "$_found" ] && echo "done" || echo "nothing to clean"
		' 2>/dev/null || echo "unreachable"
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

# --- Ensure infrastructure ---------------------------------------------------

_ensure_govc
_vmconf="$HOME/.vmware.conf"
[ -f "$_vmconf" ] && { set -a; source "$_vmconf"; set +a; }

echo ""
echo "=== E2E Test Run ==="
echo "  Suites: ${suites_to_run[*]}"
echo "  Pools: ${CLI_POOL_LIST}"
echo ""

# Check VM readiness and OS changes for each pool
_POOL_OS_DIR="$_RUN_DIR/.pool-os"
mkdir -p "$_POOL_OS_DIR"
_cur_os="${INT_BASTION_RHEL_VER:-rhel8}"
declare -a _pools_needing_reclone=()
_need_infra=""

_vms_ready() {
	local pool_num="$1"
	local user="${CON_SSH_USER:-steve}"
	local con="con${pool_num}.${VM_BASE_DOMAIN}"

	if ! _essh "${user}@${con}" "true" 2>/dev/null; then
		echo "  Pool $pool_num: not ready (SSH to ${con} failed)" >&2
		return 1
	fi

	if ! govc snapshot.tree -vm "con${pool_num}" | grep -q "pool-ready"; then
		echo "  Pool $pool_num: not ready (con${pool_num} missing pool-ready snapshot)" >&2
		return 1
	fi

	if ! govc snapshot.tree -vm "dis${pool_num}" | grep -q "pool-ready"; then
		echo "  Pool $pool_num: not ready (dis${pool_num} missing pool-ready snapshot)" >&2
		return 1
	fi
}

for _p in $CLI_POOL_LIST; do
	_pool_os_file="$_POOL_OS_DIR/pool-${_p}"
	if [ -n "${CLI_RECREATE_VMS:-}" ]; then
		echo "  Pool $_p: will be recreated (--recreate-vms)"
		_need_infra=1
	elif [ -f "$_pool_os_file" ] && [ "$(cat "$_pool_os_file")" != "$_cur_os" ]; then
		echo "  Pool $_p: OS changed ($(cat "$_pool_os_file") -> $_cur_os) -- VMs will be recloned"
		_pools_needing_reclone+=("$_p")
		_need_infra=1
	elif _vms_ready "$_p"; then
		echo "  Pool $_p: ready"
		echo "$_cur_os" > "$_pool_os_file"
	else
		_need_infra=1
	fi
done

# Selective reclone: destroy only pools that changed OS (not global --recreate-vms)
if [ ${#_pools_needing_reclone[@]} -gt 0 ] && [ -z "${CLI_RECREATE_VMS:-}" ]; then
	for _p in "${_pools_needing_reclone[@]}"; do
		_pool_folder="${VC_FOLDER:-/Datacenter/vm/aba-e2e}/pool${_p}"

		# Process cleanup files first (delete clusters/mirrors via aba)
		for _try_user in "${CON_SSH_USER:-steve}" root steve; do
			_try_host="${_try_user}@con${_p}.${VM_BASE_DOMAIN}"
			_essh "$_try_host" "true" 2>/dev/null || continue
			_has_cleanup=""
			_has_cleanup=$(_essh "$_try_host" "ls \$HOME/.e2e-harness/logs/*.cleanup \$HOME/.e2e-harness/logs/*.mirror-cleanup 2>/dev/null" 2>/dev/null) || true
			[ -z "$_has_cleanup" ] && continue
			echo "  Pool $_p: processing cleanup files for $_try_user before OS reclone ..."
			_essh "$_try_host" bash -s <<-'CLEANUP_EOF' 2>&1 || true
			_logs="$HOME/.e2e-harness/logs"
			_ssh_opts='-o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR'
			for f in "$_logs"/*.cleanup "$_logs"/*.mirror-cleanup; do
				[ -f "$f" ] || continue
				echo "    Processing $(basename "$f") ..."
				while IFS=' ' read -r target abs_path; do
					[ -z "$abs_path" ] && continue
					if echo "$f" | grep -q '\.cleanup$'; then
						echo "      $target: delete $abs_path"
						ssh $_ssh_opts "$target" "[ -d '$abs_path' ] && { command -v aba >/dev/null 2>&1 && aba -y -d '$abs_path' delete || make -C '$abs_path' delete; }" < /dev/null 2>&1 || true
					else
						echo "      $target: uninstall $abs_path"
						ssh $_ssh_opts "$target" "[ -d '$abs_path' ] && { command -v aba >/dev/null 2>&1 && aba -y -d '$abs_path' uninstall || make -C '$abs_path' uninstall; }" < /dev/null 2>&1 || true
					fi
				done < "$f"
				rm -f "$f"
			done
			CLEANUP_EOF
			break
		done

		# Destroy ALL VMs in the pool folder (clusters, conN, disN, etc.)
		echo "  Destroying all VMs in pool $_p folder ..."
		while IFS= read -r _vm_path; do
			[ -z "$_vm_path" ] && continue
			_vm_name="${_vm_path##*/}"
			echo "  Destroying $_vm_name (OS mismatch) ..."
			govc vm.power -off "$_vm_path" 2>/dev/null || true
			govc vm.destroy "$_vm_path" 2>/dev/null || true
		done < <(govc find "$_pool_folder" -type m 2>/dev/null)
	done
fi

# When recreating VMs, destroy orphaned cluster VMs in pool folders first
if [ -n "${CLI_RECREATE_VMS:-}" ]; then
	for _p in $CLI_POOL_LIST; do
		_pool_folder="${VC_FOLDER:-/Datacenter/vm/aba-e2e}/pool${_p}"
		_orphans=$(govc find "$_pool_folder" -type m 2>/dev/null | grep -v "/con${_p}$" | grep -v "/dis${_p}$") || true
		if [ -n "$_orphans" ]; then
			echo "  Pool $_p: destroying orphaned VMs before recreate ..."
			while IFS= read -r _vm_path; do
				[ -z "$_vm_path" ] && continue
				_vm_name="${_vm_path##*/}"
				echo "    Destroying $_vm_name ..."
				govc vm.power -off "$_vm_path" 2>/dev/null || true
				govc vm.destroy "$_vm_path" 2>/dev/null || true
			done <<< "$_orphans"
		fi
	done
fi

if [ -n "$_need_infra" ] || [ -n "${CLI_RECREATE_GOLDEN:-}" ] || [ -n "${CLI_RECREATE_VMS:-}" ]; then
	echo ""
	echo "  Running setup-infra.sh for pools: $CLI_POOL_LIST ..."
	_base_infra_flags="--pools-file ${_RUN_DIR}/pools.conf"
	[ -n "${CLI_RECREATE_GOLDEN:-}" ] && _base_infra_flags+=" --recreate-golden"
	[ -n "${CLI_RECREATE_VMS:-}" ]    && _base_infra_flags+=" --recreate-vms"
	[ -n "${CLI_YES:-}" ]             && _base_infra_flags+=" --yes"
	for _p in $CLI_POOL_LIST; do
		"$BASH" "$_RUN_DIR/setup-infra.sh" --pool "$_p" $_base_infra_flags || { echo "FATAL: Infrastructure setup failed for pool $_p" >&2; exit 1; }
	done
	for _p in $CLI_POOL_LIST; do
		echo "$_cur_os" > "$_POOL_OS_DIR/pool-${_p}"
	done
fi

# --- Optional revert to pool-ready snapshot -----------------------------------

if [ -n "${CLI_REVERT:-}" ]; then
	echo ""
	echo "  Processing cleanup files before revert (cluster VMs live on hypervisor) ..."
	for _p in $CLI_POOL_LIST; do
		for _try_user in "${CON_SSH_USER:-steve}" root steve; do
			_try_host="${_try_user}@con${_p}.${VM_BASE_DOMAIN}"
			_essh "$_try_host" "true" 2>/dev/null || continue
			_has_cleanup=""
			_has_cleanup=$(_essh "$_try_host" "ls \$HOME/.e2e-harness/logs/*.cleanup \$HOME/.e2e-harness/logs/*.mirror-cleanup 2>/dev/null" 2>/dev/null) || true
			[ -z "$_has_cleanup" ] && continue
			echo "    Pool $_p: found cleanup files for $_try_user -- running aba delete/uninstall ..."
			_essh "$_try_host" bash -s <<-'CLEANUP_EOF' 2>&1 || echo "    WARNING: cleanup for pool $_p user $_try_user had errors (continuing)"
			_logs="$HOME/.e2e-harness/logs"
			_ssh_opts='-o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR'
			for f in "$_logs"/*.cleanup "$_logs"/*.mirror-cleanup; do
				[ -f "$f" ] || continue
				echo "      Processing $(basename "$f") ..."
				while IFS=' ' read -r target abs_path; do
					[ -z "$abs_path" ] && continue
					if echo "$f" | grep -q '\.cleanup$'; then
						echo "        $target: delete $abs_path"
						ssh $_ssh_opts "$target" "[ -d '$abs_path' ] && { command -v aba >/dev/null 2>&1 && aba -y -d '$abs_path' delete || make -C '$abs_path' delete; }" < /dev/null 2>&1 || true
					else
						echo "        $target: uninstall $abs_path"
						ssh $_ssh_opts "$target" "[ -d '$abs_path' ] && { command -v aba >/dev/null 2>&1 && aba -y -d '$abs_path' uninstall || make -C '$abs_path' uninstall; }" < /dev/null 2>&1 || true
					fi
				done < "$f"
				rm -f "$f"
			done
			CLEANUP_EOF
		done
	done

	echo ""
	echo "  Reverting pool VMs to pool-ready snapshot ..."
	for _p in $CLI_POOL_LIST; do
		for prefix in con dis; do
			vm="${prefix}${_p}"
			if govc snapshot.tree -vm "$vm" 2>&1 | grep -q "pool-ready"; then
				govc snapshot.revert -vm "$vm" "pool-ready" || { echo "  FATAL: revert $vm failed" >&2; exit 1; }
				govc vm.power -on "$vm"
				echo "    ${vm}: reverted to pool-ready"
			else
				echo "    ${vm}: WARNING -- pool-ready snapshot not found, skipping" >&2
			fi
		done
	done

	echo "  Waiting for conN SSH readiness ..."
	for _p in $CLI_POOL_LIST; do
		target=$(_con_target "$_p")
		_wait_for_ssh "$target" 120 || { echo "  FATAL: con${_p} not reachable after revert" >&2; exit 1; }
		echo "    con${_p}: SSH ready"
	done
	echo "  All pool VMs reverted and ready."
fi

# --- Deploy harness to conN ---------------------------------------------------

# Pre-flight: verify notify.sh exists if NOTIFY_CMD is configured
_notify_cmd=$(grep '^NOTIFY_CMD=' "$_RUN_DIR/config.env" | head -1 | cut -d= -f2- | sed 's/[[:space:]]*#.*//')
_notify_cmd="${_notify_cmd/#\~/$HOME}"
if [ -n "$_notify_cmd" ] && ! [ -x "$_notify_cmd" ]; then
	echo "FATAL: config.env sets NOTIFY_CMD=$_notify_cmd but the file does not exist." >&2
	echo "  Create the file or clear NOTIFY_CMD in config.env." >&2
	exit 1
fi

# Save last-run state for read-only commands
_save_last_run "$_RUN_DIR"

echo ""
echo "  Deploying test harness to conN hosts ..."
for _p in $CLI_POOL_LIST; do
	target=$(_con_target "$_p")

	if sync_harness "$target" "$_ABA_ROOT" "$_DEPLOY_CONFIG_ENV"; then
		sync_extras "$target" "${CON_SSH_USER:-steve}"
		# Ensure rootless podman's pause process survives between SSH sessions
		_essh "$target" "sudo loginctl enable-linger ${CON_SSH_USER:-steve}"
		echo "    con${_p}: harness deployed to ~/.e2e-harness/"
	else
		echo "    con${_p}: FAILED to deploy harness (skipping)" >&2
	fi
done

# --- Developer mode: push source ---------------------------------------------

if [ -n "${CLI_DEV:-}" ]; then
	echo ""
	echo "  Developer mode: pushing ABA source to conN hosts ..."
	_deploy_tar=$(_make_source_tar "$_ABA_ROOT")
	_deploy_size=$(du -h "$_deploy_tar" | cut -f1)
	echo "  Source tarball: $_deploy_size"
	for _p in $CLI_POOL_LIST; do
		target=$(_con_target "$_p")
		echo -n "    con${_p}: "
		if sync_source "$target" "$_deploy_tar"; then
			echo "done"
		else
			echo "FAILED"
		fi
	done
	rm -f "$_deploy_tar"
fi

# =============================================================================
# --- Dynamic Work-Queue Dispatcher -------------------------------------------
# =============================================================================
# Functions from lib/dispatcher.sh. State arrays declared here (top-level).
# =============================================================================

declare -A _completed=()
declare -A _busy_pools=()
declare -a _work_queue=()
declare -A _results=()
declare -A _result_pool=()

# Apply --force scoping
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
trap 'rm -f "$E2E_DISPATCHER_PID" "$E2E_DISPATCH_STATE" "$E2E_INJECT_QUEUE" "$E2E_FORCED_DISPATCH"' EXIT

declare -A _retried=()
_MAX_RETRIES=2
_queue_idx=0

if [ ${#_work_queue[@]} -gt 0 ] || [ $_num_running -gt 0 ]; then
	echo "  Dispatching ... (Ctrl-C safe: restart run.sh to reconnect)"
	echo "  (Monitor: run.sh live | Single pool: run.sh attach conN)"
	echo ""
fi

# --- Main dispatch loop -------------------------------------------------------

while [ $_queue_idx -lt ${#_work_queue[@]} ] || [ ${#_busy_pools[@]} -gt 0 ]; do

	for _p in "${!_busy_pools[@]}"; do
		local_suite="${_busy_pools[$_p]}"
		rc=$(_check_pool "$_p" "$local_suite")
		if [ -n "$rc" ]; then
			_record_result "$local_suite" "$rc"
			_collect_pool_logs "$_p"
			_ssh_con "$_p" "tmux capture-pane -t '$_TMUX_SESSION' -p -S - >> ~/.e2e-harness/logs/tmux-history.log 2>/dev/null" 2>/dev/null
			_ssh_con "$_p" "tmux kill-session -t '$_TMUX_SESSION' 2>/dev/null"
			unset '_busy_pools[$_p]'
		fi
	done

	# Inject queue (from reschedule)
	if [ -f "$E2E_INJECT_QUEUE" ] && [ -s "$E2E_INJECT_QUEUE" ]; then
		_inj_count=0
		while IFS= read -r _inj_suite; do
			[ -z "$_inj_suite" ] && continue
			_already_running=""
			for _bp in "${!_busy_pools[@]}"; do
				[ "${_busy_pools[$_bp]}" = "$_inj_suite" ] && _already_running=1 && break
			done
			[ -n "$_already_running" ] && { printf "  [%s] SKIPPED: %s (running)\n" "$(date '+%H:%M:%S')" "$_inj_suite"; continue; }
			_already_queued=""
			for (( _qi=_queue_idx; _qi<${#_work_queue[@]}; _qi++ )); do
				[ "${_work_queue[$_qi]}" = "$_inj_suite" ] && _already_queued=1 && break
			done
			[ -n "$_already_queued" ] && { printf "  [%s] SKIPPED: %s (queued)\n" "$(date '+%H:%M:%S')" "$_inj_suite"; continue; }
			_work_queue+=("$_inj_suite"); suites_to_run+=("$_inj_suite")
			_inj_count=$(( _inj_count + 1 ))
			printf "  [%s] INJECTED: %s (from reschedule)\n" "$(date '+%H:%M:%S')" "$_inj_suite"
		done < "$E2E_INJECT_QUEUE"
		> "$E2E_INJECT_QUEUE"
		if [ "$_inj_count" -gt 0 ] && [ -n "${NOTIFY_CMD:-}" ] && [ -x "${NOTIFY_CMD%% *}" ]; then
			$NOTIFY_CMD "[e2e] RESCHEDULE: ${_inj_count} suite(s) injected" < /dev/null >/dev/null
		fi
	fi

	# Forced dispatch pickup
	if [ -f "$E2E_FORCED_DISPATCH" ] && [ -s "$E2E_FORCED_DISPATCH" ]; then
		while IFS=' ' read -r _fd_pool _fd_suite; do
			[ -z "$_fd_pool" ] && continue
			_busy_pools[$_fd_pool]="$_fd_suite"; _result_pool[$_fd_suite]="$_fd_pool"
			printf "  [%s] EXTERNAL: %s -> pool %s\n" "$(date '+%H:%M:%S')" "$_fd_suite" "$_fd_pool"
		done < "$E2E_FORCED_DISPATCH"
		> "$E2E_FORCED_DISPATCH"
	fi

	# Dispatch to free pools
	while [ $_queue_idx -lt ${#_work_queue[@]} ]; do
		free=$(_find_free_pool) || break
		suite="${_work_queue[$_queue_idx]}"
		_dup=""
		for _dp in "${!_busy_pools[@]}"; do
			[ "${_busy_pools[$_dp]}" = "$suite" ] && _dup=1 && break
		done
		if [ -n "$_dup" ]; then
			printf "  [%s] DEFER: %s (running on pool %s)\n" "$(date '+%H:%M:%S')" "$suite" "$_dp"
			_queue_idx=$(( _queue_idx + 1 )); continue
		fi
		_dispatch_suite "$free" "$suite" || _record_result "$suite" "99"
		_queue_idx=$(( _queue_idx + 1 ))
	done

	# Inline retry
	if [ $_queue_idx -ge ${#_work_queue[@]} ] && _find_free_pool >/dev/null; then
		_retry_added=0
		for _rs in "${!_results[@]}"; do
			_rrc="${_results[$_rs]}"
			if [ "$_rrc" -ne 0 ] 2>/dev/null && [ "$_rrc" -ne 3 ] 2>/dev/null && [ "${_retried[$_rs]:-0}" -lt "$_MAX_RETRIES" ]; then
				_retried[$_rs]=$(( ${_retried[$_rs]:-0} + 1 ))
				_rp="${_result_pool[$_rs]:-}"
				[ -n "$_rp" ] && _ssh_con "$_rp" "sudo rm -f '${_RC_PREFIX}-${_rs}.rc'"
				unset '_results[$_rs]'; _work_queue+=("$_rs")
				printf "  [%s] RETRY %d/%d: %s (was exit=%s)\n" "$(date '+%H:%M:%S')" "${_retried[$_rs]}" "$_MAX_RETRIES" "$_rs" "$_rrc"
				_retry_added=$(( _retry_added + 1 ))
			fi
		done
		if [ "$_retry_added" -gt 0 ]; then
			[ -n "${NOTIFY_CMD:-}" ] && [ -x "${NOTIFY_CMD%% *}" ] && $NOTIFY_CMD "[e2e] RETRY: ${_retry_added} re-queued" < /dev/null >/dev/null
			while [ $_queue_idx -lt ${#_work_queue[@]} ]; do
				free=$(_find_free_pool) || break
				suite="${_work_queue[$_queue_idx]}"
				_dispatch_suite "$free" "$suite" || _record_result "$suite" "99"
				_queue_idx=$(( _queue_idx + 1 ))
			done
		fi
	fi

	_write_dispatch_state
	_notify_periodic_status

	_queued_remaining=$(( ${#_work_queue[@]} - _queue_idx ))
	if [ ${#_busy_pools[@]} -gt 0 ]; then
		_status_line="${#_results[@]}d ${#_busy_pools[@]}r ${_queued_remaining}q"
		for _p in "${!_busy_pools[@]}"; do _status_line+=" con${_p}:${_busy_pools[$_p]}"; done
		for (( _qi=_queue_idx; _qi<${#_work_queue[@]}; _qi++ )); do _status_line+=" q:${_work_queue[$_qi]}"; done
		if [ "${_status_line}" != "${_prev_status:-}" ]; then
			printf "  [%s] %d done, %d running" "$(date '+%H:%M:%S')" "${#_results[@]}" "${#_busy_pools[@]}"
			[ "$_queued_remaining" -gt 0 ] && printf ", %d queued" "$_queued_remaining"
			printf " |"; for _p in "${!_busy_pools[@]}"; do printf " con%s:%s" "$_p" "${_busy_pools[$_p]}"; done
			if [ "$_queued_remaining" -gt 0 ]; then
				printf " ||"; for (( _qi=_queue_idx; _qi<${#_work_queue[@]}; _qi++ )); do printf " %s" "${_work_queue[$_qi]}"; done
			fi
			echo ""; _prev_status="$_status_line"
		fi
	fi
	sleep 30
done

# --- Final summary (from lib/dispatcher.sh) -----------------------------------

_overall_rc=0
_print_final_summary

[ -n "$DASH_SESSION" ] && tmux kill-session -t "$DASH_SESSION" 2>/dev/null

exit "$_overall_rc"
