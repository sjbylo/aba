#!/usr/bin/env bash
# =============================================================================
# E2E Test Framework v2 -- Thin Coordinator
# =============================================================================
# The user always runs this script. It figures out what to do.
#
# Responsibilities:
#   1. Parse args
#   2. Ensure VMs are ready (call setup-infra.sh if needed)
#   3. scp config files to each conN
#   4. Dynamic work-queue dispatch: one suite at a time per pool
#   5. When a pool finishes, dispatch the next queued suite
#   6. Monitor completion, collect results
#   7. Print final combined summary
#
# Ctrl-C safe: suites run in tmux sessions on conN.  Restart run.sh
# and it detects running/completed suites, resumes dispatching.
#
# Usage:
#   run.sh --all [--pools N] [--recreate-golden] [--recreate-vms]
#   run.sh --suite X,Y [--pools N]
#   run.sh --list
#   run.sh --destroy
#   run.sh --dry-run
#   run.sh attach conN
#   run.sh [-q] [--clean]
# =============================================================================

set -u

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 2) )); then
    echo "ERROR: Bash 4.2+ is required (you have $BASH_VERSION)." >&2
    echo "       On macOS: brew install bash, then run with /opt/homebrew/bin/bash $0" >&2
    exit 1
fi

_RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ABA_ROOT="$(cd "$_RUN_DIR/../.." && pwd)"

source "$_RUN_DIR/lib/constants.sh"

# --- CLI Variables -----------------------------------------------------------

CLI_COMMAND=""
CLI_SUITE=""
CLI_ALL=""
CLI_POOLS=1
CLI_RECREATE_GOLDEN=""
CLI_RECREATE_VMS=""
CLI_YES=""
CLI_QUIET=""
CLI_CLEAN=""
CLI_DRY_RUN=""
CLI_FORCE=""
CLI_POOL=""
CLI_RESUME=""
CLI_DESTROY=""
CLI_STOP=""
CLI_LIST=""
CLI_ATTACH=""
CLI_DEPLOY=""
CLI_RESTART=""
CLI_RESCHEDULE=""
CLI_STATUS=""
CLI_START=""
_CLI_POOLS_SET=""
CLI_VERIFY=""
CLI_DEV=""
CLI_POOLS_FILE="$_RUN_DIR/pools.conf"
CLI_OS=""

# --- Usage (defined before arg parsing so --help works) ----------------------

_usage() {
	cat <<-'USAGE'
	E2E Test Framework v2 -- Coordinator

	Commands:
	  run.sh run [--suite X] [--pools N]   Run suites (default: --all)
	  run.sh run --pools 3                 Run all suites across 3 pools
	  run.sh run --suite X --pool 2        Run suite on a specific pool
	  run.sh run --suite X --pool 2 --force -y  Force onto pool (works with running dispatcher)
	  run.sh run --pool 3 --resume         Re-run last suite, skip passed tests
	  run.sh run --all --pools 3 --dev     Push local source to ~/aba, then run
	  run.sh reschedule [--suite X] [--pools N]  Re-queue completed suites
	  run.sh deploy [--pool N] [--force]   Push source code + harness to conN
	  run.sh restart [--pool N] [--resume] Stop + harness deploy + re-run last suite
	  run.sh restart --pool N --dev        Stop + source deploy + harness + re-run
	  run.sh restart --suite X --pool N    Stop + deploy + run suite X on pool N
	  run.sh stop [--pool N]               Kill runner(s) (--pool: keep dispatcher)
	  run.sh start [--pool N]              Power on pool VMs (conN + disN)
	  run.sh status [--pool N]             Show what's running
	  run.sh verify [--pools N|--pool N]   Verify pool VMs (no dispatch)
	  run.sh list                          List available suites
	  run.sh destroy [--clean]             Destroy pool VMs (--clean: delete clusters first)
	  run.sh attach conN                   Attach to conN's tmux session
	  run.sh live [N]                      Interactive multi-pane dashboard
	  run.sh dash [N] [log]                Read-only summary dashboard

	Options (modifiers):
	  --suite X,Y          Select specific suite(s)
	  --all                Select all suites (default for run/reschedule)
	  --pools N            Number of pools (default: 1)
	  --pool N             Target a specific pool
	  --force              Wipe suite state before dispatching / hot-deploy
	  --dev                Developer mode: push local source to ~/aba on conN
	                       instead of letting the suite install ABA from internet
	  --resume             Skip previously-passed tests (run, restart)
	  --dry-run            Show dispatch plan, don't execute
	  --clean              Clear checkpoints before running
	  --recreate-golden    Force rebuild golden VM from template
	  --recreate-vms       Force reclone all conN/disN from golden
	  -y, --yes            Auto-accept prompts
	  -q, --quiet          CI mode: no interactive prompts (implies -y)
	  --os rhel8|rhel9     RHEL version for pool VMs (default: config.env)
	  --pools-file F       Custom pools.conf path

	The script auto-detects VM state and only creates/configures
	what's missing. No --setup flag needed.
	USAGE
}

# --- Parse Arguments ---------------------------------------------------------

# Detect subcommand (first non-flag argument)
if [ $# -gt 0 ]; then
	case "$1" in
		run|reschedule|deploy|restart|stop|start|status|verify|list|destroy|attach|live|dash)
			CLI_COMMAND="$1"; shift ;;
	esac
fi

# Parse flags
while [ $# -gt 0 ]; do
	case "$1" in
		--suite|--suites)     CLI_SUITE="$2"; shift 2 ;;
		--all)                CLI_ALL=1; shift ;;
		-p|--pools)           CLI_POOLS="$2"; _CLI_POOLS_SET=1; shift 2 ;;
		-G|--recreate-golden) CLI_RECREATE_GOLDEN=1; shift ;;
		-R|--recreate-vms)    CLI_RECREATE_VMS=1; shift ;;
		-y|--yes)             CLI_YES=1; shift ;;
		-q|--quiet)           CLI_QUIET=1; CLI_YES=1; shift ;;
		--clean)              CLI_CLEAN=1; shift ;;
		--dry-run)            CLI_DRY_RUN=1; shift ;;
		-f|--force)           CLI_FORCE=1; shift ;;
		--dev)                CLI_DEV=1; shift ;;
		--pool)               CLI_POOL="$2"; shift 2 ;;
		--resume)             CLI_RESUME=1; shift ;;
		--os)                 CLI_OS="$2"; shift 2 ;;
		--pools-file)         CLI_POOLS_FILE="$2"; shift 2 ;;
		--help|-h)            _usage; exit 0 ;;
		# Deprecated flag-as-subcommand forms (backwards compat)
		--destroy)  echo "Note: use 'run.sh destroy' (--destroy is deprecated)" >&2
		            CLI_COMMAND="destroy"; shift ;;
		--verify)   echo "Note: use 'run.sh verify' (--verify is deprecated)" >&2
		            CLI_COMMAND="verify"; shift ;;
		--list|-l)  echo "Note: use 'run.sh list' (--list is deprecated)" >&2
		            CLI_COMMAND="list"; shift ;;
		*) echo "Unknown option: $1" >&2; _usage; exit 1 ;;
	esac
done

# Infer "run" when --all/--suite/--resume used without a subcommand
if [ -z "$CLI_COMMAND" ]; then
	if [ -n "$CLI_ALL" ] || [ -n "$CLI_SUITE" ] || [ -n "$CLI_RESUME" ]; then
		CLI_COMMAND="run"
	fi
fi

# Map subcommand to CLI_* variables (bridges to existing execution blocks)
case "${CLI_COMMAND:-}" in
	run)          ;;
	reschedule)   CLI_RESCHEDULE=1 ;;
	deploy)       CLI_DEPLOY=1 ;;
	restart)      CLI_RESTART=1 ;;
	stop)         CLI_STOP=1 ;;
	start)        CLI_START=1 ;;
	status)       CLI_STATUS=1 ;;
	verify)       CLI_VERIFY=1 ;;
	list)         CLI_LIST=1 ;;
	destroy)      CLI_DESTROY=1 ;;
	attach)       if [ $# -lt 1 ]; then echo "ERROR: attach requires a host (e.g. con1)" >&2; exit 1; fi
	              CLI_ATTACH="$1"; shift ;;
	live)         CLI_LIVE=""
	              if [ $# -gt 0 ] && [[ "$1" =~ ^[0-9]+$ ]]; then CLI_LIVE="$1"; shift; fi ;;
	dash)         CLI_DASHBOARD=""; CLI_DASH_LOG="summary.log"
	              if [ $# -gt 0 ] && [[ "$1" =~ ^[0-9]+$ ]]; then CLI_DASHBOARD="$1"; shift; fi
	              if [ $# -gt 0 ] && [[ "$1" == "log" ]]; then CLI_DASH_LOG="latest.log"; shift; fi ;;
	"")           echo "ERROR: No command specified. Use: run, reschedule, deploy, status, list, etc." >&2
	              _usage; exit 1 ;;
esac

# For "run" and "reschedule": default to --all when no suite selector given
if [ "$CLI_COMMAND" = "run" ] || [ "$CLI_COMMAND" = "reschedule" ]; then
	if [ -z "$CLI_ALL" ] && [ -z "$CLI_SUITE" ] && [ -z "$CLI_RESUME" ]; then
		CLI_ALL=1
	fi
fi

# --- Pool flag adjustment ----------------------------------------------------

[ -n "$CLI_POOL" ] && [ "$CLI_POOL" -gt "$CLI_POOLS" ] && CLI_POOLS="$CLI_POOL"

# Auto-detect pool count from pools.conf for operational commands (stop, deploy,
# restart) when --pools was not explicitly given.  Dispatch commands (--all,
# --suite) keep the CLI_POOLS default of 1.
_pool_count_from_conf() {
	grep -c '^[^#]' "$CLI_POOLS_FILE" 2>/dev/null || echo "$CLI_POOLS"
}
if [ -z "$_CLI_POOLS_SET" ]; then
	if [ -n "$CLI_POOL" ]; then
		# --pool N without --pools: limit scope to pool N (avoid touching higher pools)
		_OP_POOLS="$CLI_POOL"
	else
		_OP_POOLS=$(_pool_count_from_conf)
	fi
else
	_OP_POOLS="$CLI_POOLS"
fi
CLI_POOLS="$_OP_POOLS"

# --- Source config -----------------------------------------------------------

if [ -f "$_RUN_DIR/config.env" ]; then
	set -a
	source "$_RUN_DIR/config.env"
	set +a
fi

# --os overrides INT_BASTION_RHEL_VER from config.env
[ -n "$CLI_OS" ] && export INT_BASTION_RHEL_VER="$CLI_OS"

# --- Auto-detect git branch and repo from the developer's local checkout ------
_ABA_ROOT="$(cd "$_RUN_DIR/../.." && pwd)"
export E2E_GIT_BRANCH="${E2E_GIT_BRANCH:-$(git -C "$_ABA_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo dev)}"
export E2E_GIT_REPO="${E2E_GIT_REPO:-$(git -C "$_ABA_ROOT" remote get-url origin 2>/dev/null || echo https://github.com/sjbylo/aba.git)}"
# user/repo slug for curl one-liner install (strip protocol + host + .git suffix)
export E2E_GIT_REPO_SLUG="${E2E_GIT_REPO_SLUG:-$(echo "$E2E_GIT_REPO" | sed 's|.*github.com[:/]||; s|\.git$||')}"

# --- Ensure govc when we will use it (destroy or infra check / setup) ---------
_ensure_govc() {
	if command -v govc &>/dev/null; then
		return 0
	fi
	if [ -f "$_ABA_ROOT/scripts/include_all.sh" ]; then
		source "$_ABA_ROOT/scripts/include_all.sh"
		if ensure_govc; then
			return 0
		fi
		echo "ERROR: govc installation failed." >&2
		exit 1
	fi
	echo "ERROR: govc not found. Install govc (e.g. from ABA: ensure_govc) or add it to PATH." >&2
	exit 1
}

_SSH_OPTS="-o LogLevel=ERROR -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

_ssh_con() {
	local pool_num="$1"; shift
	local user="${CON_SSH_USER:-steve}"
	local host="con${pool_num}.${VM_BASE_DOMAIN}"
	ssh $_SSH_OPTS "${user}@${host}" "$@"
}

_sweep_pool_orphan_vms() {
	local pool_num="$1"
	local _base="${VC_FOLDER_BASE:-/Datacenter/vm/aba-e2e}"
	local _pfolder="${_base}/pool${pool_num}"
	local _known_vms="con${pool_num} dis${pool_num}"

	local _all_vms
	_all_vms=$(govc find "$_pfolder" -type m) || return 0
	[ -z "$_all_vms" ] && return 0

	while IFS= read -r _vm; do
		[ -z "$_vm" ] && continue
		local _vmname; _vmname=$(basename "$_vm")
		local _is_known=""
		for _k in $_known_vms; do
			[ "$_vmname" = "$_k" ] && _is_known=1 && break
		done
		[ -n "$_is_known" ] && continue

		echo "    Destroying orphan VM: $_vm"
		govc vm.power -off "$_vm" || true
		govc vm.destroy "$_vm" || true
	done <<< "$_all_vms"
}

# Process .cleanup and .mirror-cleanup files on a pool before wiping state.
_process_pool_cleanup_files() {
	local pool_num="$1"
	_ssh_con "$pool_num" "
		_logs=\"\$HOME/.e2e-harness/logs\"
		for f in \"\$_logs\"/*.cleanup \"\$_logs\"/*.mirror-cleanup; do
			[ -f \"\$f\" ] || continue
			echo \"    Processing \$(basename \"\$f\") ...\"
			_ssh_opts='-o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR'
			while IFS=' ' read -r target abs_path; do
				[ -z \"\$abs_path\" ] && continue
				if echo \"\$f\" | grep -q '\.cleanup$'; then
					echo \"      \$target: aba -y -d \$abs_path delete\"
					ssh \$_ssh_opts \"\$target\" \"[ -d '\$abs_path' ] && aba -y -d '\$abs_path' delete\" 2>&1 || true
				else
					echo \"      \$target: aba -y -d \$abs_path uninstall\"
					ssh \$_ssh_opts \"\$target\" \"[ -d '\$abs_path' ] && aba -y -d '\$abs_path' uninstall\" 2>&1 || true
				fi
			done < \"\$f\"
			rm -f \"\$f\"
		done
	" 2>/dev/null || true
	_sweep_pool_orphan_vms "$pool_num"
}

# --- Shared: create a tmux dashboard with one tail pane per pool --------------
# Usage: _create_tmux_dashboard SESSION_NAME NUM_POOLS LOG_FILE
_create_tmux_dashboard() {
	local _sess="$1" _np="$2" _logfile="${3:-summary.log}"
	local _user="${CON_SSH_USER:-steve}"
	local _domain="${VM_BASE_DOMAIN}"

	_dash_pane_cmd() {
		local _p=$1
		local _h="con${_p}.${_domain}"
		echo "while true; do if ssh $_SSH_OPTS ${_user}@${_h} 'tmux has-session -t ${E2E_TMUX_SESSION:-e2e-suite} 2>/dev/null' 2>/dev/null; then _s=\$(ssh $_SSH_OPTS ${_user}@${_h} 'cat /tmp/e2e-last-suites 2>/dev/null' 2>/dev/null); printf '\\033]2;dashboard | Pool ${_p} (con${_p})%s\\033\\\\' \"\${_s:+ | \$_s}\"; ssh $_SSH_OPTS ${_user}@${_h} 'tail -F -n 500 ~/.e2e-harness/logs/${_logfile}' 2>/dev/null; else printf '\\033]2;dashboard | Pool ${_p} (con${_p})\\033\\\\'; clear; echo 'No e2e session on con${_p}. Waiting for suite to start...'; sleep 5; fi; done"
	}

	tmux kill-session -t "$_sess" 2>/dev/null || true

	if [ "$_np" -le 2 ]; then
		tmux new-session -d -s "$_sess" "$(_dash_pane_cmd 1)"
		for (( _dp=2; _dp<=_np; _dp++ )); do
			tmux split-window -t "$_sess" -v "$(_dash_pane_cmd $_dp)"
		done
		tmux select-layout -t "$_sess" even-vertical 2>/dev/null
	else
		tmux new-session -d -s "$_sess" "$(_dash_pane_cmd 1)"
		local _tl
		_tl=$(tmux list-panes -t "$_sess" -F '#{pane_id}' | head -1)
		tmux split-window -h -t "$_tl" "$(_dash_pane_cmd 2)"
		local _tr
		_tr=$(tmux list-panes -t "$_sess" -F '#{pane_id}' | tail -1)
		tmux split-window -v -t "$_tl" "$(_dash_pane_cmd 3)"
		if [ "$_np" -ge 4 ]; then
			tmux split-window -v -t "$_tr" "$(_dash_pane_cmd 4)"
		fi
	fi
	tmux set-option -t "$_sess" allow-rename on 2>/dev/null
	tmux set-option -t "$_sess" pane-border-status top 2>/dev/null
	tmux set-option -t "$_sess" pane-border-format " #{pane_title} " 2>/dev/null
}

# --- Attach mode -------------------------------------------------------------

if [ -n "$CLI_ATTACH" ]; then
	host="${CLI_ATTACH}"
	user="${CON_SSH_USER:-steve}"
	domain="${VM_BASE_DOMAIN}"

	# Accept "conN" or "conN.domain"
	case "$host" in
		*.*) ;; # already FQDN
		*)   host="${host}.${domain}" ;;
	esac

	echo "Attaching to tmux on ${user}@${host} ..."
	exec ssh -t -o LogLevel=ERROR "${user}@${host}" \
		"if tmux has-session -t '$E2E_TMUX_SESSION' 2>/dev/null; then \
		   tmux attach -t '$E2E_TMUX_SESSION'; \
		 else echo 'No e2e session found on ${host}.'; tmux list-sessions 2>/dev/null || echo '(no tmux sessions)'; fi"
fi

# --- Deploy mode (developer quick-fix: source-only push) ----------------------

if [ -n "$CLI_DEPLOY" ]; then
	# --pool N targets a single pool; --pools N targets 1..N
	if [ -n "$CLI_POOL" ]; then
		_deploy_list=("$CLI_POOL")
	else
		_deploy_list=()
		for (( _dp=1; _dp<=_OP_POOLS; _dp++ )); do _deploy_list+=("$_dp"); done
	fi
	echo ""
	echo "  Developer deploy: source-only push to conN (${_deploy_list[*]}) ..."

	# Whitelist: only ABA source code (no binaries, data, configs, dot-flags)
	_deploy_tar=$(mktemp /tmp/aba-deploy.XXXXXX.tar.gz)
	tar czf "$_deploy_tar" -C "$_ABA_ROOT" \
		--exclude='*/.*' \
		scripts/ \
		templates/ \
		Makefile \
		cli/Makefile \
		aba \
		install
	_deploy_size=$(du -h "$_deploy_tar" | cut -f1)
	echo "  Source tarball: $_deploy_size"
	echo ""
	for i in "${_deploy_list[@]}"; do
		user="${CON_SSH_USER:-steve}"
		host="con${i}.${VM_BASE_DOMAIN}"
		target="${user}@${host}"
		echo -n "    con${i}: "

		# Skip pools with running suites unless --force is used
		_running_sess=$(ssh $_SSH_OPTS "${target}" \
			"tmux has-session -t '$E2E_TMUX_SESSION' 2>/dev/null && echo yes" 2>/dev/null || true)
		if [ "$_running_sess" = "yes" ]; then
			if [ -z "$CLI_FORCE" ]; then
				echo "RUNNING (skipped -- use --force to deploy anyway)"
				continue
			fi
			echo -n "RUNNING (hot-deploy) "
		fi

		# Source deploy always overlays on existing ~/aba (never wipes)
		if ssh $_SSH_OPTS "${target}" "mkdir -p ~/aba" &&
		   scp $_SSH_OPTS "$_deploy_tar" "${target}:/tmp/aba-deploy.tar.gz" &&
		   ssh $_SSH_OPTS "${target}" "tar xzf /tmp/aba-deploy.tar.gz -C ~/aba && rm -f /tmp/aba-deploy.tar.gz"; then
			echo -n "source "
		else
			echo "FAILED (source deploy)"
			continue
		fi

		# Also push test harness to ~/.e2e-harness/
		if ssh $_SSH_OPTS "${target}" "rm -rf ~/.e2e-harness && mkdir -p ~/.e2e-harness/{lib,suites,scripts,logs}" &&
		   scp -q $_SSH_OPTS "$_ABA_ROOT/test/e2e/runner.sh"        "${target}:~/.e2e-harness/runner.sh" &&
		   scp -q $_SSH_OPTS "$_ABA_ROOT/test/e2e/config.env"       "${target}:~/.e2e-harness/config.env" &&
		   scp -q $_SSH_OPTS "$_ABA_ROOT/test/e2e/pools.conf"       "${target}:~/.e2e-harness/pools.conf" &&
		   scp -q $_SSH_OPTS "$_ABA_ROOT/test/e2e"/lib/*.sh          "${target}:~/.e2e-harness/lib/" &&
		   scp -q $_SSH_OPTS "$_ABA_ROOT/test/e2e"/suites/suite-*.sh "${target}:~/.e2e-harness/suites/" &&
		   scp -q $_SSH_OPTS "$_ABA_ROOT/test/e2e"/scripts/*.sh      "${target}:~/.e2e-harness/scripts/"; then
			echo "+ harness done"
		else
			echo "+ harness FAILED"
		fi
	done
	rm -f "$_deploy_tar"
	echo ""
	echo "  Deploy complete. Retry failed steps with: run.sh attach conN"
	exit 0
fi

# --- Stop mode ---------------------------------------------------------------

if [ -n "$CLI_STOP" ]; then
	_stop_ssh="-o LogLevel=ERROR -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
	_user="${CON_SSH_USER:-steve}"
	_domain="${VM_BASE_DOMAIN}"

	# Kill the dispatcher only when stopping ALL pools (no --pool flag).
	# When stopping a single pool, leave the dispatcher running so it can
	# detect the freed pool and dispatch the next queued suite.
	if [ -z "$CLI_POOL" ]; then
		if [ -f "$E2E_DISPATCHER_PID" ]; then
			_dpid=$(cat "$E2E_DISPATCHER_PID" 2>/dev/null)
			if [ -n "$_dpid" ] && kill -0 "$_dpid" 2>/dev/null; then
				kill "$_dpid" 2>/dev/null && echo "Dispatcher (pid $_dpid) stopped."
			fi
			rm -f "$E2E_DISPATCHER_PID" "$E2E_DISPATCH_STATE"
		fi
	fi

	# --pool N targets a single pool; --pools N targets 1..N
	if [ -n "$CLI_POOL" ]; then
		_stop_list=("$CLI_POOL")
	else
		_stop_list=()
		for (( _sp=1; _sp<=_OP_POOLS; _sp++ )); do _stop_list+=("$_sp"); done
	fi
	echo "Stopping runners on pool(s) ${_stop_list[*]} ..."
	for p in "${_stop_list[@]}"; do
		_host="con${p}.${_domain}"
		printf "  con${p}: "
		if ssh $_stop_ssh "${_user}@${_host}" "
			tmux kill-session -t '$E2E_TMUX_SESSION' 2>/dev/null || true
			rm -f ${E2E_RC_PREFIX}-*.rc ${E2E_RC_PREFIX}-*.lock /tmp/e2e-runner.rc /tmp/e2e-runner.lock /tmp/e2e-paused-*
			echo stopped
		" 2>/dev/null; then
			:
		else
			echo "unreachable"
		fi
	done
	echo "Done."
	exit 0
fi

# --- Start mode: power on pool VMs ------------------------------------------

if [ -n "$CLI_START" ]; then
	_ensure_govc
	_vmconf="$(eval echo "${VMWARE_CONF:-~/.vmware.conf}")"
	[ -f "$_vmconf" ] && { set -a; source "$_vmconf"; set +a; }

	# --pool N targets a single pool; --pools N targets 1..N
	if [ -n "$CLI_POOL" ]; then
		_start_list=("$CLI_POOL")
	else
		_start_list=()
		for (( _stp=1; _stp<=_OP_POOLS; _stp++ )); do _start_list+=("$_stp"); done
	fi
	echo ""
	echo "  Powering on pool VMs (pool(s) ${_start_list[*]}) ..."
	for p in "${_start_list[@]}"; do
		for prefix in con dis; do
			vm="${prefix}${p}"
			_state=$(govc vm.info -json "$vm" | grep -o '"powerState":"[^"]*"' | head -1 || true)
			if [[ "$_state" == *"poweredOn"* ]]; then
				echo "    ${vm}: already on"
			elif govc vm.info "$vm" &>/dev/null; then
				govc vm.power -on "$vm" || true
				echo "    ${vm}: powered on"
			else
				echo "    ${vm}: not found (skipped)"
			fi
		done
	done
	echo ""
	echo "  Done. Wait ~30s for SSH, then: run.sh deploy --pools $_OP_POOLS"
	exit 0
fi

# --- Restart mode: stop + deploy + re-launch last suite(s) -------------------

if [ -n "$CLI_RESTART" ]; then
	_restart_ssh="-o LogLevel=ERROR -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
	_user="${CON_SSH_USER:-steve}"
	_domain="${VM_BASE_DOMAIN}"

	# Determine target pools (--pool N = single, --pools N / auto-detect)
	if [ -n "$CLI_POOL" ]; then
		_restart_pools=("$CLI_POOL")
	else
		_restart_pools=()
		for (( p=1; p<=_OP_POOLS; p++ )); do _restart_pools+=("$p"); done
	fi

	echo ""
	echo "=== Restart: pool(s) ${_restart_pools[*]} ==="

	# 1) Stop
	echo ""
	echo "  [1/4] Stopping suites ..."
	for p in "${_restart_pools[@]}"; do
		_host="con${p}.${_domain}"
		printf "    con${p}: "
		if ssh $_restart_ssh "${_user}@${_host}" "
			tmux kill-session -t '$E2E_TMUX_SESSION' 2>/dev/null || true
			rm -f ${E2E_RC_PREFIX}-*.rc ${E2E_RC_PREFIX}-*.lock /tmp/e2e-runner.rc /tmp/e2e-runner.lock
			echo stopped
		" 2>/dev/null; then
			:
		else
			echo "unreachable"
		fi
	done

	# 2) Process cleanup files BEFORE wiping the tree -- clusters get deleted
	#    and mirrors get uninstalled via `aba` while the aba tree (and its
	#    mirror.conf / cluster dirs) still exists on conN.
	echo ""
	echo "  [2/4] Cleaning up resources in cleanup lists ..."
	for p in "${_restart_pools[@]}"; do
		_host="con${p}.${_domain}"
		_target="${_user}@${_host}"
		printf "    con${p}: "
		ssh $_restart_ssh "${_target}" 'set -f
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
					$_ssh "$tgt" "[ -d '\''$path'\'' ] && aba -y -d '\''$path'\'' delete || echo '\''  (dir not found)'\''" 2>&1 || { echo "  WARNING: cleanup failed: $tgt $path"; _file_ok=""; }
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
					$_ssh "$tgt" "[ -d '\''$path'\'' ] && aba -y -d '\''$path'\'' uninstall || echo '\''  (dir not found)'\''" 2>&1 || { echo "  WARNING: cleanup failed: $tgt $path"; _file_ok=""; }
				done < "$f"
				[ -n "$_file_ok" ] && rm -f "$f" || echo "  WARNING: keeping $(basename $f) -- some entries failed"
			done

			[ -n "$_found" ] && echo "done" || echo "nothing to clean"
		' 2>/dev/null || echo "unreachable"
	done

	# 3) Deploy harness (always) + source (only with --dev)
	echo ""
	if [ -n "$CLI_DEV" ]; then
		echo "  [3/4] Developer deploy: source + harness ..."
		_deploy_tar=$(mktemp /tmp/aba-deploy.XXXXXX.tar.gz)
		tar czf "$_deploy_tar" -C "$_ABA_ROOT" \
			--exclude='*/.*' \
			scripts/ \
			templates/ \
			Makefile \
			cli/Makefile \
			aba \
			install
		_deploy_size=$(du -h "$_deploy_tar" | cut -f1)
		echo "    Source tarball: $_deploy_size"
		for p in "${_restart_pools[@]}"; do
			_host="con${p}.${_domain}"
			_target="${_user}@${_host}"
			echo -n "    con${p}: "
			if ssh $_restart_ssh "${_target}" "mkdir -p ~/aba" &&
			   scp $_restart_ssh "$_deploy_tar" "${_target}:/tmp/aba-deploy.tar.gz" &&
			   ssh $_restart_ssh "${_target}" "tar xzf /tmp/aba-deploy.tar.gz -C ~/aba && rm -f /tmp/aba-deploy.tar.gz"; then
				echo "source done"
			else
				echo "FAILED (unreachable?)"
			fi
		done
		rm -f "$_deploy_tar"
	else
		echo "  [3/4] Deploying harness only (suite installs ABA from internet) ..."
	fi

	for p in "${_restart_pools[@]}"; do
		_host="con${p}.${_domain}"
		_target="${_user}@${_host}"
		echo -n "    con${p} harness: "
		if ssh $_restart_ssh "${_target}" "rm -rf ~/.e2e-harness && mkdir -p ~/.e2e-harness/{lib,suites,scripts,logs}" &&
		   scp -q $_restart_ssh "$_ABA_ROOT/test/e2e/runner.sh"        "${_target}:~/.e2e-harness/runner.sh" &&
		   scp -q $_restart_ssh "$_ABA_ROOT/test/e2e/config.env"       "${_target}:~/.e2e-harness/config.env" &&
		   scp -q $_restart_ssh "$_ABA_ROOT/test/e2e/pools.conf"       "${_target}:~/.e2e-harness/pools.conf" &&
		   scp -q $_restart_ssh "$_ABA_ROOT/test/e2e"/lib/*.sh          "${_target}:~/.e2e-harness/lib/" &&
		   scp -q $_restart_ssh "$_ABA_ROOT/test/e2e"/suites/suite-*.sh "${_target}:~/.e2e-harness/suites/" &&
		   scp -q $_restart_ssh "$_ABA_ROOT/test/e2e"/scripts/*.sh      "${_target}:~/.e2e-harness/scripts/"; then
			echo "done"
		else
			echo "FAILED"
		fi
	done

	# 4) Re-launch last suite on each pool
	echo ""
	echo "  [4/4] Re-launching last suite(s) ..."
	_restart_ok=0
	_restart_fail=0
	for p in "${_restart_pools[@]}"; do
		_host="con${p}.${_domain}"
		if [ -n "$CLI_SUITE" ]; then
			_last="$CLI_SUITE"
		else
			_last=$(ssh $_restart_ssh "${_user}@${_host}" "cat /tmp/e2e-last-suites 2>/dev/null" 2>/dev/null || true)
		fi
		if [ -z "$_last" ]; then
			echo "    con${p}: skipped (no previous suite or unreachable)"
			(( _restart_fail++ ))
			continue
		fi
		read -ra _last_suites <<< "$_last"
		for suite in "${_last_suites[@]}"; do
			_resume_flag=""
			[ -n "${CLI_RESUME:-}" ] && _resume_flag="--resume"
			_runner_cmd="bash ~/.e2e-harness/runner.sh $_resume_flag $p $suite"
			if ssh $_restart_ssh "${_user}@${_host}" "tmux new-session -d -s '$E2E_TMUX_SESSION' '$_runner_cmd'; tmux rename-window -t '$E2E_TMUX_SESSION' '$suite'" 2>/dev/null; then
				echo "    con${p}: dispatched $suite (tmux: $E2E_TMUX_SESSION)"
				(( _restart_ok++ ))
			else
				echo "    con${p}: FAILED to dispatch $suite"
				(( _restart_fail++ ))
			fi
		done
	done

	echo ""
	echo "  Restart complete: ${_restart_ok} suite(s) launched, ${_restart_fail} pool(s) skipped."
	echo "  Monitor: run.sh dash ${#_restart_pools[@]}"
	echo "  Attach:  run.sh attach conN"
	exit 0
fi

# --- Status mode --------------------------------------------------------------

if [ -n "$CLI_STATUS" ]; then
	_status_ssh="-o LogLevel=ERROR -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
	_user="${CON_SSH_USER:-steve}"
	_domain="${VM_BASE_DOMAIN}"

	# --pool N targets a single pool; --pools N targets 1..N
	if [ -n "$CLI_POOL" ]; then
		_status_list=("$CLI_POOL")
	else
		_status_list=()
		for (( _ssp=1; _ssp<=_OP_POOLS; _ssp++ )); do _status_list+=("$_ssp"); done
	fi

	printf "  %-6s  %-10s  %-40s  %s\n" "POOL" "STATE" "SUITE" "LAST OUTPUT"
	printf "  %-6s  %-10s  %-40s  %s\n" "------" "----------" "----------------------------------------" "--------------------"

	for p in "${_status_list[@]}"; do
		_host="con${p}.${_domain}"
		_info=$(ssh $_status_ssh "${_user}@${_host}" "
			suite=\$(cat /tmp/e2e-last-suites 2>/dev/null || true)
			if tmux has-session -t '$E2E_TMUX_SESSION' 2>/dev/null; then
				suite=\${suite:-unknown}
				rc_file=\"${E2E_RC_PREFIX}-\${suite}.rc\"
				last=\$(tail -1 ~/.e2e-harness/logs/summary.log 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
				if [ -f \"\$rc_file\" ]; then
					rc=\$(cat \"\$rc_file\" 2>/dev/null)
					echo \"DONE|\${suite}|exit=\${rc}\"
				elif [ -f \"/tmp/e2e-paused-\${suite}\" ]; then
					echo \"PAUSED|\${suite}|\${last}\"
				else
					echo \"RUNNING|\${suite}|\${last}\"
				fi
			else
				if [ -n \"\$suite\" ]; then
					rc_file=\"${E2E_RC_PREFIX}-\${suite}.rc\"
					if [ -f \"\$rc_file\" ]; then
						rc=\$(cat \"\$rc_file\" 2>/dev/null)
						echo \"FINISHED|\${suite}|exit=\${rc}\"
					else
						echo \"IDLE|\${suite}|(no result)\"
					fi
				else
					echo \"IDLE|-|-\"
				fi
			fi
			echo '|||TABLE|||'
			tac ~/.e2e-harness/logs/summary.log 2>/dev/null \
				| awk 'BEGIN{p=0} /====/{if(p)exit; p=1; next} p{print}' \
				| tac \
				| sed 's/\x1b\[[0-9;]*m//g' \
				| grep -E 'PASS|FAIL|SKIP|RUNNING|PENDING|  --' \
				| sed 's/^[0-9: ]*//'
		" 2>/dev/null || echo "UNREACHABLE|-|-")

		_status_line="${_info%%|||TABLE|||*}"
		_table_data="${_info#*|||TABLE|||}"
		# Trim leading/trailing whitespace from table data
		_table_data="$(echo "$_table_data" | sed '/^[[:space:]]*$/d')"

		IFS='|' read -r _state _suite _detail <<< "$_status_line"
		case "$_state" in
			RUNNING)     _sc="\033[1;32m" ;;  # bold green
			PAUSED)      _sc="\033[1;33m" ;;  # bold yellow
			DONE)        if [[ "$_detail" == *"exit=0"* ]]; then
			                 _sc="\033[1;32m"  # bold green (pass)
			             else
			                 _sc="\033[1;31m"  # bold red (fail)
			             fi ;;
			FINISHED)    if [[ "$_detail" == *"exit=0"* ]]; then
			                 _sc="\033[32m"    # green (pass)
			             else
			                 _sc="\033[1;31m"  # bold red (fail)
			             fi ;;
			IDLE)        _sc="\033[0m" ;;      # default
			UNREACHABLE) _sc="\033[90m" ;;     # dim grey
			*)           _sc="\033[0m" ;;
		esac
		# Show detail on header for DONE/FINISHED/IDLE (exit code). RUNNING/PAUSED put detail on the RUNNING... table line.
		if [[ "$_state" == "RUNNING" || "$_state" == "PAUSED" ]]; then
			printf "  con%-3s  ${_sc}%-10s\033[0m  %s\033[0m\n" "$p" "$_state" "$_suite"
		else
			printf "  con%-3s  ${_sc}%-10s\033[0m  %-40s  %s\033[0m\n" "$p" "$_state" "$_suite" "$_detail"
		fi

		if [ -n "$_table_data" ]; then
			# For FINISHED (failed) suites, replace stale RUNNING... with FAIL
			if [[ "$_state" == "FINISHED" && "$_detail" != *"exit=0"* ]]; then
				_table_data="${_table_data//RUNNING.../FAIL}"
			fi
			# For IDLE pools with stale data, replace RUNNING... with INT (interrupted)
			if [[ "$_state" == "IDLE" ]]; then
				_table_data="${_table_data//RUNNING.../INT}"
			fi
			while IFS= read -r _tline; do
				[[ "$_tline" == *---* ]] && continue
				if [[ "$_tline" == *PASS* ]]; then
					_tline="${_tline/PASS/$'\033[32mPASS\033[0m'}"
				elif [[ "$_tline" == *FAIL* ]]; then
					_tline="${_tline/FAIL/$'\033[1;31mFAIL\033[0m'}"
				elif [[ "$_tline" == *RUNNING* ]]; then
					if [[ "$_state" == "PAUSED" ]]; then
						_tline="${_tline/RUNNING.../$'\033[1;33mPAUSED...\033[0m'}"
					else
						_tline="${_tline/RUNNING.../$'\033[1;36mRUNNING...\033[0m'}"
					fi
					# Append the last command output to the RUNNING/PAUSED line
					if [[ ( "$_state" == "RUNNING" || "$_state" == "PAUSED" ) && -n "$_detail" ]]; then
						_tline+="  $_detail"
						_detail=""
					fi
				elif [[ "$_tline" == *SKIP* ]]; then
					_tline="${_tline/SKIP/$'\033[33mSKIP\033[0m'}"
				elif [[ "$_tline" == *INT* ]]; then
					_tline="${_tline/INT/$'\033[90mINT\033[0m'}"
				fi
				printf "           %s\n" "$_tline"
			done <<< "$_table_data"
		fi
	done

	if [ -f "$E2E_DISPATCHER_PID" ] && kill -0 "$(cat "$E2E_DISPATCHER_PID" 2>/dev/null)" 2>/dev/null; then
		printf "  Dispatcher: \033[1;32mRUNNING\033[0m (pid %s)" "$(cat "$E2E_DISPATCHER_PID")"
		if [ -f "$E2E_DISPATCH_STATE" ]; then
			_ds_pending=$(grep '^PENDING=' "$E2E_DISPATCH_STATE" 2>/dev/null | cut -d= -f2-)
			_ds_running=$(grep '^RUNNING=' "$E2E_DISPATCH_STATE" 2>/dev/null | cut -d= -f2-)
			_ds_done=$(grep '^DONE=' "$E2E_DISPATCH_STATE" 2>/dev/null | cut -d= -f2-)
			_ds_done_list=$(grep '^DONE_LIST=' "$E2E_DISPATCH_STATE" 2>/dev/null | cut -d= -f2-)
			echo ""
		if [ -n "$_ds_running" ]; then
			# shellcheck disable=SC2086
			set -- $_ds_running; _n_active=$#
			printf "    Active (%d):  %s\n" "$_n_active" "${_ds_running// /  |  }"
		fi
		# Merge any externally injected suites (from reschedule) into Pending
		_ds_injected=""
		if [ -f "$E2E_INJECT_QUEUE" ] && [ -s "$E2E_INJECT_QUEUE" ]; then
			_ds_injected=$(tr '\n' ' ' < "$E2E_INJECT_QUEUE" | sed 's/ *$//')
		fi
		if [ -n "$_ds_injected" ] && [ -n "$_ds_pending" ]; then
			_ds_pending="$_ds_injected $_ds_pending"
		elif [ -n "$_ds_injected" ]; then
			_ds_pending="$_ds_injected"
		fi
		if [ -n "$_ds_pending" ]; then
			# shellcheck disable=SC2086
			set -- $_ds_pending; _n_pending=$#
			printf "    Pending (%d): %s\n" "$_n_pending" "${_ds_pending// /  |  }"
		fi
		if [ -n "$_ds_done" ] && [ "$_ds_done" -gt 0 ] 2>/dev/null; then
				_done_summary=""
				for _entry in $_ds_done_list; do
					_s="${_entry%%:*}"
					_rc_pool="${_entry#*:}"
					_rc="${_rc_pool%%@*}"
					_pool="${_rc_pool#*@}"
					if [ "$_rc" = "0" ]; then
						_done_summary+="$_s (\033[32mPASS\033[0m) "
					else
						_done_summary+="$_s (\033[1;31mFAIL\033[0m/exit=$_rc,con$_pool) "
					fi
				done
				printf "    Done (%s):    %b\n" "$_ds_done" "${_done_summary% }"
			fi
		else
			echo ""
		fi
	else
		printf "  Dispatcher: \033[90mnot running\033[0m"
		_last_cmd="./run.sh --all --pools $_OP_POOLS"
		printf " -- reconnect with: %s\n" "$_last_cmd"
	fi
	exit 0
fi

# --- Live (interactive) mode -------------------------------------------------

if [ -n "${CLI_LIVE+set}" ]; then
	if [ -n "$CLI_LIVE" ]; then
		_num_pools="$CLI_LIVE"
	else
		_num_pools=$(grep -c '^[^#]' "$_RUN_DIR/pools.conf" 2>/dev/null || echo 3)
	fi
	_user="${CON_SSH_USER:-steve}"
	_domain="${VM_BASE_DOMAIN}"
	LIVE_SESSION="e2e-live"

	tmux kill-session -t "$LIVE_SESSION" 2>/dev/null || true

	# Claim ownership: write a unique ID to /tmp/e2e-live-owner on each conN.
	# Pane scripts check this before re-attaching — if another live dashboard
	# has taken over (different ID), the old pane exits instead of fighting.
	_live_id="$$-$(date +%s)"
	_live_so="-o LogLevel=ERROR -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
	for (( _lp=1; _lp<=_num_pools; _lp++ )); do
		ssh $_live_so "${_user}@con${_lp}.${_domain}" \
			"echo '$_live_id' > /tmp/e2e-live-owner" 2>/dev/null || true
	done

	_live_script_dir=$(mktemp -d /tmp/e2e-live.XXXXXX)
	_live_create_script() {
		local p=$1
		local _h="con${p}.${_domain}"
		local _so="-o LogLevel=ERROR -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
		local _script="${_live_script_dir}/pool${p}.sh"
		{
			echo '#!/bin/bash'
			echo 'stty -ixon 2>/dev/null'
			echo "_MY_ID='${_live_id}'"
		echo 'while true; do'
		echo "  _owner=\$(ssh $_so ${_user}@${_h} 'cat /tmp/e2e-live-owner 2>/dev/null' 2>/dev/null)"
		echo '  if [ -n "$_owner" ] && [ "$_owner" != "$_MY_ID" ]; then'
		echo "    echo 'Another live dashboard took over con${p}. Exiting.'"
		echo '    exit 0'
		echo '  fi'
		echo "  _suite=\$(ssh $_so ${_user}@${_h} 'cat /tmp/e2e-last-suites 2>/dev/null' 2>/dev/null)"
		printf "  printf '\\\\033]2;live | Pool %d (con%d)%%s\\\\033\\\\\\\\' \"\${_suite:+ | \$_suite}\"\n" "$p" "$p"
		echo '  clear'
		echo "  ssh -t $_so ${_user}@${_h} \"tmux has-session -t '$E2E_TMUX_SESSION' 2>/dev/null && exec tmux attach -d -t '$E2E_TMUX_SESSION'\" 2>/dev/null || {"
		echo "    echo 'No e2e session on con${p}. Waiting for suite to start...'"
		echo '  }'
		echo '  sleep 5'
			echo 'done'
		} > "$_script"
		chmod +x "$_script"
		echo "$_script"
	}

	if [ "$_num_pools" -le 2 ]; then
		tmux new-session -d -s "$LIVE_SESSION" "$(_live_create_script 1)"
		for (( p=2; p<=_num_pools; p++ )); do
			tmux split-window -t "$LIVE_SESSION" -v "$(_live_create_script $p)"
		done
		tmux select-layout -t "$LIVE_SESSION" even-vertical 2>/dev/null
	else
		# 3-4 pool 2x2 grid: 1|2 / 3|4  (target by pane ID for cross-platform reliability)
		tmux new-session -d -s "$LIVE_SESSION" "$(_live_create_script 1)"
		_p_tl=$(tmux list-panes -t "$LIVE_SESSION" -F '#{pane_id}' | head -1)
		tmux split-window -h -t "$_p_tl" "$(_live_create_script 2)"
		_p_tr=$(tmux list-panes -t "$LIVE_SESSION" -F '#{pane_id}' | tail -1)
		tmux split-window -v -t "$_p_tl" "$(_live_create_script 3)"
		if [ "$_num_pools" -ge 4 ]; then
			tmux split-window -v -t "$_p_tr" "$(_live_create_script 4)"
		fi
	fi
	tmux set-option -t "$LIVE_SESSION" alternate-screen off 2>/dev/null
	tmux set-option -t "$LIVE_SESSION" allow-rename on 2>/dev/null
	tmux set-option -t "$LIVE_SESSION" pane-border-status top 2>/dev/null
	tmux set-option -t "$LIVE_SESSION" pane-border-format " #{pane_title} " 2>/dev/null
	echo "Live dashboard (${_num_pools} pools) -- Ctrl-b + arrow to switch panes"
	exec tmux attach -t "$LIVE_SESSION"
fi

# --- Dashboard mode ----------------------------------------------------------

if [ -n "${CLI_DASHBOARD+set}" ]; then
	if [ -n "$CLI_DASHBOARD" ]; then
		_num_pools="$CLI_DASHBOARD"
	else
		_num_pools=$(grep -c '^[^#]' "$_RUN_DIR/pools.conf" 2>/dev/null || echo 3)
	fi
	_create_tmux_dashboard "e2e-dashboard" "$_num_pools" "$CLI_DASH_LOG"
	echo "Attaching to dashboard (${_num_pools} pools) ..."
	exec tmux attach -t "e2e-dashboard"
fi

# --- List mode ---------------------------------------------------------------

if [ -n "$CLI_LIST" ]; then
	echo "Available suites:"
	echo ""
	for f in "$_RUN_DIR"/suites/suite-*.sh; do
		[ -f "$f" ] || continue
		name="$(basename "$f" .sh)"
		name="${name#suite-}"
		desc="$(grep -m1 '^# Suite:' "$f" 2>/dev/null | sed 's/^# Suite: *//')"
		printf "  %-35s %s\n" "$name" "$desc"
	done
	echo ""
	echo "Run:  test/e2e/run.sh --suite <name>"
	echo "      test/e2e/run.sh --all --pools 3"
	exit 0
fi

# --- Destroy mode ------------------------------------------------------------

if [ -n "$CLI_DESTROY" ]; then
	_ensure_govc
	_vmconf="$(eval echo "${VMWARE_CONF:-~/.vmware.conf}")"
	if [ -f "$_vmconf" ]; then
		set -a; source "$_vmconf"; set +a
	fi
	source "$_RUN_DIR/lib/remote.sh"

	# --clean: SSH to each conN and delete test clusters / uninstall mirrors
	# before destroying VMs. Processes .cleanup and .mirror-cleanup files
	# that suites leave in ~/.e2e-harness/logs/.
	if [ -n "$CLI_CLEAN" ]; then
		echo "=== Cleaning up test clusters and mirrors on pool VMs ==="
		_cssh="-o LogLevel=ERROR -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
		_user="${CON_SSH_USER:-steve}"
		_domain="${VM_BASE_DOMAIN}"
		_e2e_logs=".e2e-harness/logs"

		for (( i=1; i<=10; i++ )); do
			_host="con${i}.${_domain}"
			# Skip unreachable hosts or hosts with no cleanup files
			_has_files=$(ssh $_cssh "${_user}@${_host}" \
				"ls ~/$_e2e_logs/*.cleanup ~/$_e2e_logs/*.mirror-cleanup 2>/dev/null | head -1" 2>/dev/null) || continue
			[ -z "$_has_files" ] && continue

			echo "  con${i}: processing cleanup files ..."

			ssh $_cssh "${_user}@${_host}" bash <<-REMOTE
				_ssh_opts="-o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
				_logs="\$HOME/$_e2e_logs"

				for f in "\$_logs"/*.cleanup; do
					[ -f "\$f" ] || continue
					echo "    Processing \$(basename "\$f") ..."
					_ok=1
					while IFS=' ' read -r target abs_path; do
						[ -z "\$abs_path" ] && continue
						echo "      \$target: aba -y -d \$abs_path delete"
					ssh \$_ssh_opts "\$target" \
						"[ -d '\$abs_path' ] && aba -y -d '\$abs_path' delete || echo '      (dir not found)'" \
						2>&1 || { echo "      WARNING: SSH failed"; _ok=; }
					done < "\$f"
					[ -n "\$_ok" ] && rm -f "\$f"
				done

				for f in "\$_logs"/*.mirror-cleanup; do
					[ -f "\$f" ] || continue
					echo "    Processing \$(basename "\$f") ..."
					_ok=1
					while IFS=' ' read -r target abs_path; do
						[ -z "\$abs_path" ] && continue
						echo "      \$target: aba -y -d \$abs_path uninstall"
						ssh \$_ssh_opts "\$target" \
							"[ -d '\$abs_path' ] && aba -y -d '\$abs_path' uninstall || echo '      (dir not found)'" \
							2>&1 || { echo "      WARNING: SSH failed"; _ok=; }
					done < "\$f"
					[ -n "\$_ok" ] && rm -f "\$f"
				done
			REMOTE
			echo "  con${i}: cleanup done."
		done
		echo "=== Cleanup complete ==="
		echo ""
	fi

	echo "=== Destroying all pool VMs ==="
	for (( i=1; i<=10; i++ )); do
		for prefix in con dis; do
			vm="${prefix}${i}"
			if govc vm.info "$vm" | grep "Name:"; then
				echo "  Destroying $vm ..."
				govc vm.power -off "$vm" || true
				govc vm.destroy "$vm" || true
			fi
		done
	done

	# Sweep pool folders for orphaned cluster VMs (e.g. e2e-sno1-e2e-sno1, e2e-compact1-master1)
	# that were not cleaned up by the --clean step or aba delete.
	_base="/Datacenter/vm/aba-e2e"
	echo ""
	echo "=== Sweeping pool folders for orphaned cluster VMs ==="
	_all_orphans=""
	for (( i=1; i<=10; i++ )); do
		_pfolder="${_base}/pool${i}"
		_orphans=$(govc find "$_pfolder" -type m) || continue
		[ -z "$_orphans" ] && continue
		_all_orphans+="$_orphans"$'\n'
	done
	_all_orphans="${_all_orphans%$'\n'}"

	if [ -z "$_all_orphans" ]; then
		echo "  No orphaned VMs found in pool folders."
	else
		echo "  The following VMs will be DESTROYED:"
		while IFS= read -r _ovm; do
			[ -z "$_ovm" ] && continue
			echo "    $_ovm"
		done <<< "$_all_orphans"
		echo ""

		_answer=""
		if [ -n "$CLI_YES" ]; then
			_answer="y"
		else
			printf "  Destroy these VMs? (Y/n): "
			read -r -t 60 _answer || _answer="n"
		fi

		if [[ "$_answer" =~ ^[Yy]?$ ]]; then
			while IFS= read -r _ovm; do
				[ -z "$_ovm" ] && continue
				echo "  Destroying $_ovm ..."
				govc vm.power -off "$_ovm" || true
				govc vm.destroy "$_ovm" || true
			done <<< "$_all_orphans"
		else
			echo "  Skipped orphan cleanup."
		fi
	fi

	echo "=== Done ==="
	exit 0
fi

# --- Verify mode -------------------------------------------------------------

if [ -n "$CLI_VERIFY" ]; then
	_ver_pools="$_OP_POOLS"
	_infra_flags="--verify --pools $_ver_pools --pools-file $CLI_POOLS_FILE"
	if [ -n "$CLI_POOL" ]; then
		_infra_flags+=" --pool $CLI_POOL"
		echo ""
		echo "=== Verifying pool $CLI_POOL ==="
	else
		echo ""
		echo "=== Verifying pool VMs (pools 1..$_ver_pools) ==="
	fi
	"$BASH" "$_RUN_DIR/setup-infra.sh" $_infra_flags || { echo "FATAL: Verification failed" >&2; exit 1; }
	exit 0
fi

# --- Determine suites --------------------------------------------------------

_all_suites() {
	local suites=()
	for f in "$_RUN_DIR"/suites/suite-*.sh; do
		[ -f "$f" ] || continue
		local name
		name="$(basename "$f" .sh)"
		name="${name#suite-}"
		suites+=("$name")
	done
	echo "${suites[@]}"
}

suites_to_run=()

if [ -n "$CLI_RESUME" ]; then
	if [ -z "$CLI_POOL" ]; then
		echo "ERROR: --resume requires --pool N" >&2
		exit 1
	fi
	_last_host="con${CLI_POOL}.${VM_BASE_DOMAIN}"
	_last_user="${CON_SSH_USER:-steve}"
	_last_ssh="-o LogLevel=ERROR -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
	_last=$(ssh $_last_ssh "${_last_user}@${_last_host}" "cat /tmp/e2e-last-suites 2>/dev/null" || true)
	if [ -z "$_last" ]; then
		echo "ERROR: No previous suite record on con${CLI_POOL} (/tmp/e2e-last-suites not found)" >&2
		exit 1
	fi
	read -ra suites_to_run <<< "$_last"
	echo "  Re-running last suite(s) from con${CLI_POOL}: ${suites_to_run[*]}"
elif [ -n "$CLI_ALL" ]; then
	read -ra suites_to_run <<< "$(_all_suites)"
elif [ -n "$CLI_SUITE" ]; then
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
if [ -z "$CLI_RESUME" ]; then
	for _s in "${suites_to_run[@]}"; do
		if [ ! -f "$_RUN_DIR/suites/suite-${_s}.sh" ]; then
			echo "ERROR: Unknown suite '$_s' (no file: suites/suite-${_s}.sh)" >&2
			echo "  Available suites:" >&2
			for _sf in "$_RUN_DIR"/suites/suite-*.sh; do
				echo "    $(basename "$_sf" .sh | sed 's/^suite-//')" >&2
			done
			exit 1
		fi
	done
fi

# --- Reschedule: inject suites into the running dispatcher's queue -----------
# Lightweight command: writes to the inject-queue file and exits immediately.
# The running dispatcher polls this file and picks up injected suites.
if [ -n "$CLI_RESCHEDULE" ]; then
	echo ""
	echo "=== Reschedule: injecting into dispatcher queue ==="
	for suite in "${suites_to_run[@]}"; do
		# Prepend to inject queue (front of queue = dispatched first)
		if [ -f "$E2E_INJECT_QUEUE" ] && [ -s "$E2E_INJECT_QUEUE" ]; then
			_existing=$(cat "$E2E_INJECT_QUEUE")
			printf '%s\n%s\n' "$suite" "$_existing" > "$E2E_INJECT_QUEUE"
		else
			echo "$suite" > "$E2E_INJECT_QUEUE"
		fi
		printf "  Queued: \033[1;36m%s\033[0m (front)\n" "$suite"
	done
	echo ""
	if [ -f "$E2E_DISPATCHER_PID" ] && kill -0 "$(cat "$E2E_DISPATCHER_PID" 2>/dev/null)" 2>/dev/null; then
		echo "  Dispatcher is running -- will pick this up on its next cycle (~30s)."
	else
		echo "  WARNING: No dispatcher running. Start one with: run.sh run --all"
	fi
	echo "  Tip: if you changed suite code, run 'deploy --force' first."
	echo ""
	exit 0
fi

# --- Check if VMs are ready --------------------------------------------------

_vms_ready() {
	local pool_num="$1"
	local user="${CON_SSH_USER:-steve}"
	local con="con${pool_num}.${VM_BASE_DOMAIN}"
	local _reason=""

	if ! ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no \
		-o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
		"${user}@${con}" -- "true"; then
		_reason="SSH to ${con} failed"
		echo "  Pool $pool_num: not ready ($_reason)" >&2
		return 1
	fi

	if ! govc snapshot.tree -vm "con${pool_num}" | grep -q "pool-ready"; then
		_reason="con${pool_num} missing pool-ready snapshot"
		echo "  Pool $pool_num: not ready ($_reason)" >&2
		return 1
	fi

	if ! govc snapshot.tree -vm "dis${pool_num}" | grep -q "pool-ready"; then
		_reason="dis${pool_num} missing pool-ready snapshot"
		echo "  Pool $pool_num: not ready ($_reason)" >&2
		return 1
	fi
}

# --- Dry run (before infra check -- no side effects) -------------------------

if [ -n "$CLI_DRY_RUN" ]; then
	echo ""
	echo "=== DRY RUN (work-queue dispatch) ==="
	echo "  Pools available: $CLI_POOLS"
	echo "  Suites (${#suites_to_run[@]}): ${suites_to_run[*]}"
	echo ""
	echo "  Dispatch order (one suite at a time to free pools):"
	for (( i=0; i<${#suites_to_run[@]}; i++ )); do
		printf "    %2d. %s\n" "$(( i+1 ))" "${suites_to_run[$i]}"
	done
	echo ""
	echo "  With $CLI_POOLS pool(s), up to $CLI_POOLS suites run concurrently."
	echo "  Each pool receives the next suite when it finishes."
	echo ""
	exit 0
fi

# --- Ensure infrastructure ---------------------------------------------------

_ensure_govc
_vmconf="$(eval echo "${VMWARE_CONF:-~/.vmware.conf}")"
[ -f "$_vmconf" ] && { set -a; source "$_vmconf"; set +a; }

echo ""
echo "=== E2E Test Run ==="
echo "  Suites: ${suites_to_run[*]}"
echo "  Pools: $CLI_POOLS"
echo ""

_need_infra=""
for (( i=1; i<=CLI_POOLS; i++ )); do
	if [ -n "$CLI_RECREATE_VMS" ]; then
		echo "  Pool $i: will be recreated (--recreate-vms)"
		_need_infra=1
	elif _vms_ready "$i"; then
		echo "  Pool $i: ready"
	else
		_need_infra=1
	fi
done

if [ -n "$_need_infra" ] || [ -n "$CLI_RECREATE_GOLDEN" ] || [ -n "$CLI_RECREATE_VMS" ]; then
	echo ""
	echo "  Running setup-infra.sh ..."
	_infra_flags="--pools $CLI_POOLS --pools-file $CLI_POOLS_FILE"
	[ -n "$CLI_RECREATE_GOLDEN" ] && _infra_flags+=" --recreate-golden"
	[ -n "$CLI_RECREATE_VMS" ]    && _infra_flags+=" --recreate-vms"
	[ -n "$CLI_YES" ]             && _infra_flags+=" --yes"
	"$BASH" "$_RUN_DIR/setup-infra.sh" $_infra_flags || { echo "FATAL: Infrastructure setup failed" >&2; exit 1; }
fi

# --- scp test harness to ~/.e2e-harness/ on each conN -------------------------

echo ""
echo "  Deploying test harness to conN hosts ..."
for (( i=1; i<=CLI_POOLS; i++ )); do
	user="${CON_SSH_USER:-steve}"
	host="con${i}.${VM_BASE_DOMAIN}"
	target="${user}@${host}"

	if ssh -q $_SSH_OPTS "$target" "rm -rf ~/.e2e-harness && mkdir -p ~/.e2e-harness/{lib,suites,scripts,logs}" &&
	   scp -q $_SSH_OPTS "$_RUN_DIR/config.env" "$target:~/.e2e-harness/config.env" &&
	   scp -q $_SSH_OPTS "$_RUN_DIR/pools.conf" "$target:~/.e2e-harness/pools.conf" &&
	   scp -q $_SSH_OPTS "$_RUN_DIR/runner.sh"  "$target:~/.e2e-harness/runner.sh" &&
	   scp -q $_SSH_OPTS "$_RUN_DIR"/lib/*.sh   "$target:~/.e2e-harness/lib/" &&
	   scp -q $_SSH_OPTS "$_RUN_DIR"/suites/suite-*.sh "$target:~/.e2e-harness/suites/" &&
	   scp -q $_SSH_OPTS "$_RUN_DIR"/scripts/*.sh "$target:~/.e2e-harness/scripts/"; then
		# Deploy notify.sh if available locally (contains secrets, not in git)
		if [ -x ~/bin/notify.sh ]; then
			ssh -q $_SSH_OPTS "$target" "mkdir -p ~/bin" &&
			scp -q $_SSH_OPTS ~/bin/notify.sh "$target:~/bin/notify.sh" &&
			ssh -q $_SSH_OPTS "$target" "chmod +x ~/bin/notify.sh" || true
		fi
		# Ensure rootless podman's pause process survives between SSH sessions
		ssh -q $_SSH_OPTS "$target" "sudo loginctl enable-linger $user 2>/dev/null || true"
		echo "    con${i}: harness deployed to ~/.e2e-harness/"
	else
		echo "    con${i}: FAILED to deploy harness (skipping)" >&2
	fi
done

# --- Developer mode: push source to ~/aba on each conN -----------------------
if [ -n "$CLI_DEV" ]; then
	echo ""
	echo "  Developer mode: pushing ABA source to conN hosts ..."
	_deploy_tar=$(mktemp /tmp/aba-deploy.XXXXXX.tar.gz)
	tar czf "$_deploy_tar" -C "$_ABA_ROOT" \
		--exclude='*/.*' \
		scripts/ \
		templates/ \
		Makefile \
		cli/Makefile \
		aba \
		install
	_deploy_size=$(du -h "$_deploy_tar" | cut -f1)
	echo "  Source tarball: $_deploy_size"
	for (( i=1; i<=CLI_POOLS; i++ )); do
		user="${CON_SSH_USER:-steve}"
		host="con${i}.${VM_BASE_DOMAIN}"
		target="${user}@${host}"
		echo -n "    con${i}: "
		if ssh -q $_SSH_OPTS "$target" "mkdir -p ~/aba" &&
		   scp -q $_SSH_OPTS "$_deploy_tar" "${target}:/tmp/aba-deploy.tar.gz" &&
		   ssh -q $_SSH_OPTS "$target" "tar xzf /tmp/aba-deploy.tar.gz -C ~/aba && rm -f /tmp/aba-deploy.tar.gz"; then
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
# Dispatches one suite at a time to free pools.  When a pool finishes, the
# next queued suite is sent.  All state lives on conN (rc files + tmux
# sessions), making the dispatcher Ctrl-C safe: restart run.sh and it
# reconnects to running suites and resumes dispatching.
#
# rc file convention:  $E2E_RC_PREFIX-<suite>.rc  (contains exit code)
# tmux session name:   $E2E_TMUX_SESSION (static, same on all conN hosts)
# lock file:           $E2E_RC_PREFIX-<suite>.lock
# All constants defined in lib/constants.sh (single source of truth).
# =============================================================================

_TMUX_SESSION="$E2E_TMUX_SESSION"
_RC_PREFIX="$E2E_RC_PREFIX"

# Tracking arrays (populated by _detect_running_and_completed)
declare -A _completed=()    # suite -> exit_code
declare -A _busy_pools=()   # pool_num -> suite
declare -a _work_queue=()   # remaining suites to dispatch
declare -A _results=()      # suite -> exit_code (accumulates during run)
declare -A _result_pool=()  # suite -> pool_num (which pool ran it)

# --- Dispatch helper: send a single suite to a pool --------------------------

_dispatch_suite() {
	local pool_num="$1"
	local suite="$2"

	echo "  DISPATCH: $suite -> pool $pool_num (con${pool_num})"

	# Kill any stale session and orphaned runner processes
	_ssh_con "$pool_num" "tmux kill-session -t '$_TMUX_SESSION' 2>/dev/null || true"
	_ssh_con "$pool_num" "pkill -f 'runner\.sh.*$pool_num' 2>/dev/null || true"
	# Remove old rc/lock/pause files (stale pause files cause false PAUSED status)
	_ssh_con "$pool_num" "rm -f '${_RC_PREFIX}-${suite}.rc' '${_RC_PREFIX}-${suite}.lock' /tmp/e2e-paused-*"

	# Sync latest test harness to ~/.e2e-harness/ on conN before launching
	local _user="${CON_SSH_USER:-steve}"
	local _host="con${pool_num}.${VM_BASE_DOMAIN}"
	local _target="${_user}@${_host}"
	if ! { _ssh_con "$pool_num" "rm -rf ~/.e2e-harness && mkdir -p ~/.e2e-harness/{lib,suites,scripts,logs}" &&
	       scp -q $_SSH_OPTS "$_ABA_ROOT/test/e2e/runner.sh"        "${_target}:~/.e2e-harness/runner.sh" &&
	       scp -q $_SSH_OPTS "$_ABA_ROOT/test/e2e/config.env"       "${_target}:~/.e2e-harness/config.env" &&
	       scp -q $_SSH_OPTS "$_ABA_ROOT/test/e2e/pools.conf"       "${_target}:~/.e2e-harness/pools.conf" &&
	       scp -q $_SSH_OPTS "$_ABA_ROOT/test/e2e"/lib/*.sh          "${_target}:~/.e2e-harness/lib/" &&
	       scp -q $_SSH_OPTS "$_ABA_ROOT/test/e2e"/suites/suite-*.sh "${_target}:~/.e2e-harness/suites/" &&
	       scp -q $_SSH_OPTS "$_ABA_ROOT/test/e2e"/scripts/*.sh      "${_target}:~/.e2e-harness/scripts/"; }; then
		echo "    ERROR: scp to con${pool_num} failed -- skipping dispatch"
		return 1
	fi

	local _retry_arg=""
	[ -n "${_retried[$suite]:-}" ] && _retry_arg=" retry"
	local runner_cmd="bash ~/.e2e-harness/runner.sh $pool_num $suite$_retry_arg"
	_ssh_con "$pool_num" "tmux new-session -d -s '$_TMUX_SESSION' '$runner_cmd'; tmux rename-window -t '$_TMUX_SESSION' '$suite'"

	_busy_pools[$pool_num]="$suite"
	_result_pool[$suite]="$pool_num"
	echo "    tmux session '$_TMUX_SESSION' started on con${pool_num}"
}

# --- Check if a pool's suite has completed ------------------------------------

_check_pool() {
	local pool_num="$1"
	local suite="$2"
	local rc_content

	rc_content=$(_ssh_con "$pool_num" "cat '${_RC_PREFIX}-${suite}.rc' 2>/dev/null" 2>/dev/null || true)
	if [ -n "$rc_content" ]; then
		rc_content="${rc_content//[^0-9]/}"
		echo "${rc_content:-255}"
		return
	fi

	# No .rc file -- check if the tmux session is still alive.
	# If the session is gone, the suite crashed or was killed (e.g. Ctrl-C).
	local sess_alive
	sess_alive=$(_ssh_con "$pool_num" "tmux has-session -t '$_TMUX_SESSION' 2>/dev/null && echo yes" 2>/dev/null || true)
	if [ "$sess_alive" != "yes" ]; then
		# Grace period: a manual restart (kill + relaunch) creates a brief
		# window with no tmux session.  Wait and re-check before declaring crash.
		sleep 5
		sess_alive=$(_ssh_con "$pool_num" "tmux has-session -t '$_TMUX_SESSION' 2>/dev/null && echo yes" 2>/dev/null || true)
		if [ "$sess_alive" = "yes" ]; then
			return
		fi
		echo "  WARNING: Suite '$suite' on con${pool_num} died without writing .rc (killed/crashed)" >&2
		echo "255"
	fi
}

# --- Find a free pool (no active suite) ---------------------------------------

_find_free_pool() {
	# Dynamic ceiling: use the larger of CLI_POOLS and pools.conf count so
	# pools that come online after startup are discovered automatically.
	local _max_pools
	_max_pools=$(_pool_count_from_conf)
	[ "$CLI_POOLS" -gt "$_max_pools" ] 2>/dev/null && _max_pools="$CLI_POOLS"
	for (( p=1; p<=_max_pools; p++ )); do
		if [ -z "${_busy_pools[$p]:-}" ]; then
			# Fast reachability probe (5s) -- skip unreachable pools instead of
			# letting _dispatch_suite burn ~2 min on SSH timeouts per attempt.
			local _user="${CON_SSH_USER:-steve}"
			local _host="con${p}.${VM_BASE_DOMAIN}"
			ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no \
				-o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
				"${_user}@${_host}" "true" 2>/dev/null || continue
			# Also check for tmux sessions the dispatcher doesn't track
			# (e.g. manual launches via ssh + tmux new-session)
			local _has_sess
			_has_sess=$(_ssh_con "$p" "tmux has-session -t '$_TMUX_SESSION' 2>/dev/null && echo yes" 2>/dev/null || true)
			[ "$_has_sess" = "yes" ] && continue
			echo "$p"
			return 0
		fi
	done
	return 1
}

# --- Record a completed result ------------------------------------------------

_record_result() {
	local suite="$1"
	local rc="$2"
	local pool_num="${_result_pool[$suite]:-?}"
	local _status

	_results[$suite]="$rc"

	if [ "$rc" -eq 0 ]; then
		_status="PASS"
		printf "  COMPLETED: %-35s pool %-2s  \033[1;32mPASS\033[0m\n" "$suite" "$pool_num"
	elif [ "$rc" -eq 3 ]; then
		_status="SKIP"
		printf "  COMPLETED: %-35s pool %-2s  \033[1;33mSKIP\033[0m\n" "$suite" "$pool_num"
	else
		_status="FAIL (exit=$rc)"
		printf "  COMPLETED: %-35s pool %-2s  \033[1;31mFAIL\033[0m (exit=%s)\n" "$suite" "$pool_num" "$rc"
	fi

	# Only notify from dispatcher for non-pass results (framework already notifies on PASS)
	if [ "$rc" -ne 0 ] && [ -n "${NOTIFY_CMD:-}" ] && [ -x "${NOTIFY_CMD%% *}" ]; then
		$NOTIFY_CMD "[e2e] ${_status}: ${suite} (pool ${pool_num})" < /dev/null >/dev/null 2>&1 &
	fi
}

# --- Collect logs from conN and disN for a pool --------------------------------

_collect_pool_logs() {
	local pool_num="$1"
	local user="${CON_SSH_USER:-steve}"
	local con_host="con${pool_num}.${VM_BASE_DOMAIN}"
	local dis_host="dis${pool_num}.${VM_BASE_DOMAIN}"
	local log_dir="$_RUN_DIR/logs"

	mkdir -p "$log_dir"
	scp -q -r $_SSH_OPTS "${user}@${con_host}:~/.e2e-harness/logs/*" "$log_dir/" 2>/dev/null || true
	scp -q -r $_SSH_OPTS "${user}@${dis_host}:~/.e2e-harness/logs/*" "$log_dir/" 2>/dev/null || true
}

# --- Detect running and completed suites on all conN (stateless reconnect) ----

_detect_running_and_completed() {
	echo "  Scanning pools for existing suite state ..."
	local _rc_base
	_rc_base=$(basename "$_RC_PREFIX")

	# Dynamic ceiling: discover all pools defined in pools.conf
	local _max_pools
	_max_pools=$(_pool_count_from_conf)
	[ "$CLI_POOLS" -gt "$_max_pools" ] 2>/dev/null && _max_pools="$CLI_POOLS"

	# Pass 1: detect running suites (live tmux takes precedence over stale .rc)
	local -A _running_suites=()
	for (( p=1; p<=_max_pools; p++ )); do
		local sess_exists
		sess_exists=$(_ssh_con "$p" "tmux has-session -t '$_TMUX_SESSION' 2>/dev/null && echo yes" 2>/dev/null || true)
		if [ "$sess_exists" = "yes" ]; then
			local suite
			suite=$(_ssh_con "$p" "cat /tmp/e2e-last-suites 2>/dev/null" 2>/dev/null || true)
			if [ -n "$suite" ]; then
				_busy_pools[$p]="$suite"
				_result_pool[$suite]="$p"
				_running_suites[$suite]=1
				echo "    con${p}: $suite still running"
			fi
		fi
	done

	# Pass 2: detect completed suites (.rc files), skipping any that are running
	for (( p=1; p<=_max_pools; p++ )); do
		local rc_files
		rc_files=$(_ssh_con "$p" "ls ${_RC_PREFIX}-*.rc 2>/dev/null" 2>/dev/null || true)
		if [ -n "$rc_files" ]; then
			while IFS= read -r rc_file; do
				[ -z "$rc_file" ] && continue
				local fname
				fname=$(basename "$rc_file" .rc)
				local suite="${fname#${_rc_base}-}"
				if [ -n "${_running_suites[$suite]:-}" ]; then
					echo "    con${p}: $suite .rc ignored (suite is running on another pool)"
					continue
				fi
				local rc
				rc=$(_ssh_con "$p" "cat '$rc_file' 2>/dev/null" 2>/dev/null || true)
				rc="${rc//[^0-9]/}"
				_completed[$suite]="${rc:-255}"
				_result_pool[$suite]="$p"
				echo "    con${p}: $suite completed (exit=${_completed[$suite]})"
			done <<< "$rc_files"
		fi
	done
}

# --- Force-clean: wipe rc files and tmux sessions -----------------------------

_force_clean_all() {
	echo "  --force: wiping all suite state on all pools ..."
	local _max_pools
	_max_pools=$(_pool_count_from_conf)
	[ "$CLI_POOLS" -gt "$_max_pools" ] 2>/dev/null && _max_pools="$CLI_POOLS"
	for (( p=1; p<=_max_pools; p++ )); do
		_ssh_con "$p" "
			tmux kill-session -t '$_TMUX_SESSION' 2>/dev/null || true
			rm -f ${_RC_PREFIX}-*.rc ${_RC_PREFIX}-*.lock /tmp/e2e-paused-*
		" 2>/dev/null || true
		_process_pool_cleanup_files "$p"
		echo "    con${p}: cleaned"
	done
	_completed=()
	_busy_pools=()
}

_force_clean_pool() {
	local pool_num="$1"
	echo "  --force --pool $pool_num: wiping suite state on con${pool_num} ..."
	_ssh_con "$pool_num" "
		tmux kill-session -t '$_TMUX_SESSION' 2>/dev/null || true
		rm -f ${_RC_PREFIX}-*.rc ${_RC_PREFIX}-*.lock /tmp/e2e-paused-*
	" 2>/dev/null || true
	_process_pool_cleanup_files "$pool_num"

	# Remove any entries associated with this pool
	local suite_on_pool="${_busy_pools[$pool_num]:-}"
	if [ -n "$suite_on_pool" ]; then
		unset '_busy_pools[$pool_num]'
	fi
	# Also remove completed entries from this pool
	for s in "${!_completed[@]}"; do
		if [ "${_result_pool[$s]:-}" = "$pool_num" ]; then
			unset '_completed[$s]'
			unset '_result_pool[$s]'
		fi
	done
	echo "    con${pool_num}: cleaned"
}

_force_clean_suite() {
	local suite="$1"
	echo "  --force --suite $suite: wiping state for suite '$suite' ..."

	for (( p=1; p<=CLI_POOLS; p++ )); do
		# Only kill the tmux session if this pool is running the target suite
		_ssh_con "$p" "
			running=\$(cat /tmp/e2e-last-suites 2>/dev/null || true)
			if [ \"\$running\" = '$suite' ]; then
				tmux kill-session -t '$_TMUX_SESSION' 2>/dev/null || true
			fi
			rm -f '${_RC_PREFIX}-${suite}.rc' '${_RC_PREFIX}-${suite}.lock' '/tmp/e2e-paused-${suite}'
		" 2>/dev/null || true
		# Skip cleanup on pools running a different suite to avoid destroying their resources
		if [ -n "${_busy_pools[$p]:-}" ] && [ "${_busy_pools[$p]}" != "$suite" ]; then
			echo "    Skipping con${p}: running ${_busy_pools[$p]}"
			continue
		fi
		_process_pool_cleanup_files "$p"
	done

	unset '_completed[$suite]'
	for p in "${!_busy_pools[@]}"; do
		if [ "${_busy_pools[$p]}" = "$suite" ]; then
			unset '_busy_pools[$p]'
		fi
	done
	echo "    $suite: cleaned"
}

# --- Build work queue (filter out completed and running) ----------------------

_build_work_queue() {
	_work_queue=()
	for suite in "${suites_to_run[@]}"; do
		if [ -n "${_completed[$suite]:-}" ]; then
			continue
		fi
		# Check if already running on some pool
		local running=""
		for p in "${!_busy_pools[@]}"; do
			if [ "${_busy_pools[$p]}" = "$suite" ]; then
				running=1
				break
			fi
		done
		[ -n "$running" ] && continue
		_work_queue+=("$suite")
	done
}

# =============================================================================
# --- Execute dispatch ---------------------------------------------------------
# =============================================================================

# Apply --force scoping
if [ -n "$CLI_FORCE" ]; then
	if [ -n "$CLI_POOL" ] && [ -n "$CLI_SUITE" ]; then
		# --force --suite X --pool N: clean just that suite
		_detect_running_and_completed
		_force_clean_suite "$CLI_SUITE"
	elif [ -n "$CLI_POOL" ]; then
		# --force --pool N: clean just that pool
		_detect_running_and_completed
		_force_clean_pool "$CLI_POOL"
	elif [ -n "$CLI_SUITE" ]; then
		# --force --suite X: clean just that suite
		_detect_running_and_completed
		_force_clean_suite "$CLI_SUITE"
	else
		# --force alone: clean everything
		_force_clean_all
	fi
else
	# Normal start or resume: detect existing state
	_detect_running_and_completed
fi

# (reschedule is handled earlier -- exits before reaching this point)

# Seed _results with already-completed suites
for s in "${!_completed[@]}"; do
	_results[$s]="${_completed[$s]}"
done

# Build the work queue (excluding completed and running)
_build_work_queue

_num_completed=${#_completed[@]}
_num_running=0
for _ in "${!_busy_pools[@]}"; do (( _num_running++ )); done

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
	if [ ${#_work_queue[@]} -gt 0 ]; then
		echo "  Queue: ${_work_queue[*]}"
	fi
	if [ $_num_running -gt 0 ]; then
		echo "  Running:"
		for p in "${!_busy_pools[@]}"; do
			echo "    con${p}: ${_busy_pools[$p]}"
		done
	fi
fi
echo ""

# Send "DISPATCHER STARTED" notification only on a 100% clean start
# (nothing completed, nothing running — a real fresh test run).
# Exceptional events (retries, reschedules) send their own notifications.
if [ $_num_completed -eq 0 ] && [ $_num_running -eq 0 ] && [ ${#_work_queue[@]} -gt 0 ]; then
	if [ -n "${NOTIFY_CMD:-}" ] && [ -x "${NOTIFY_CMD%% *}" ]; then
		_notify_detail="
Queued:"
		for _qs in "${_work_queue[@]}"; do
			_notify_detail+="
  ${_qs}"
		done
		_notify_msg="[e2e] DISPATCHER STARTED: ${#_work_queue[@]} suites queued${_notify_detail}"
		$NOTIFY_CMD "$_notify_msg" < /dev/null >/dev/null 2>&1
	fi
fi

# Open summary dashboard (if not quiet mode and multiple pools)
DASH_SESSION=""
if [ -z "$CLI_QUIET" ] && [ "$CLI_POOLS" -gt 1 ] && { [ ${#_work_queue[@]} -gt 0 ] || [ $_num_running -gt 0 ]; }; then
	DASH_SESSION="e2e-dashboard"
	_create_tmux_dashboard "$DASH_SESSION" "$CLI_POOLS" "summary.log"
	echo "  Summary dashboard opened (run.sh dash to reattach)"
	echo ""
fi

# --- Main dispatch loop -------------------------------------------------------

_queue_idx=0

if [ ${#_work_queue[@]} -gt 0 ] || [ $_num_running -gt 0 ]; then
	echo "  Dispatching ... (Ctrl-C safe: restart run.sh to reconnect)"
	echo "  (Monitor: run.sh live | Single pool: run.sh attach conN)"
	echo ""
fi

_write_dispatch_state() {
	local _queued_left=$(( ${#_work_queue[@]} - _queue_idx ))
	{
		echo "REQUESTED=${_work_queue[*]:-}"
		echo "QUEUED_IDX=$_queue_idx"
		echo "QUEUED_TOTAL=${#_work_queue[@]}"
		local _q_remaining=()
		for (( _qi=_queue_idx; _qi<${#_work_queue[@]}; _qi++ )); do
			_q_remaining+=("${_work_queue[$_qi]}")
		done
		echo "PENDING=${_q_remaining[*]:-}"
		local _bp_str=""
		for _bp in "${!_busy_pools[@]}"; do
			_bp_str+="${_busy_pools[$_bp]} "
		done
		echo "RUNNING=${_bp_str% }"
		echo "DONE=${#_results[@]}"
		local _done_str=""
		for _ds in "${!_results[@]}"; do
			_done_str+="${_ds}:${_results[$_ds]}@${_result_pool[$_ds]:-?} "
		done
		echo "DONE_LIST=${_done_str% }"
	} > "$E2E_DISPATCH_STATE"
}

# --- One-shot force dispatch: --suite X --pool N --force with running dispatcher
# Instead of replacing the dispatcher, dispatch directly and signal it.
if [ -n "$CLI_FORCE" ] && [ -n "$CLI_POOL" ] && [ -n "$CLI_SUITE" ]; then
	if [ -f "$E2E_DISPATCHER_PID" ]; then
		_old_dpid=$(cat "$E2E_DISPATCHER_PID" 2>/dev/null)
		if [ -n "$_old_dpid" ] && [ "$_old_dpid" != "$$" ] && kill -0 "$_old_dpid" 2>/dev/null; then
			echo ""
			echo "  Dispatcher running (pid $_old_dpid) -- performing one-shot dispatch"
			echo "  FORCE DISPATCH: $CLI_SUITE -> pool $CLI_POOL"

			declare -A _retried=()
			_dispatch_suite "$CLI_POOL" "$CLI_SUITE"

			echo "$CLI_POOL $CLI_SUITE" >> "$E2E_FORCED_DISPATCH"
			echo ""
			echo "  Done. Dispatcher notified via $E2E_FORCED_DISPATCH."
			echo "  Monitor: run.sh status --pools $_OP_POOLS"
			echo "  Attach:  run.sh attach con${CLI_POOL}"
			exit 0
		fi
	fi
fi

# Check for an existing dispatcher
if [ -f "$E2E_DISPATCHER_PID" ]; then
	_old_dpid=$(cat "$E2E_DISPATCHER_PID" 2>/dev/null)
	if [ -n "$_old_dpid" ] && [ "$_old_dpid" != "$$" ] && kill -0 "$_old_dpid" 2>/dev/null; then
		echo ""
		printf "  \033[1;33mWARNING: Another dispatcher is already running (pid %s)\033[0m\n" "$_old_dpid"
		if [ -n "$CLI_YES" ]; then
			_answer="y"
		else
			printf "  Kill it and take over? (Y/n): "
			read -r -t 30 _answer || _answer="n"
		fi
		if [[ "$_answer" =~ ^[Yy]?$ ]]; then
			kill "$_old_dpid" 2>/dev/null || true
			sleep 1
			echo "  Killed old dispatcher."
		else
			echo "  Aborted. Existing dispatcher left running."
			exit 1
		fi
	fi
fi
echo $$ > "$E2E_DISPATCHER_PID"
trap 'rm -f "$E2E_DISPATCHER_PID" "$E2E_DISPATCH_STATE" "$E2E_INJECT_QUEUE" "$E2E_FORCED_DISPATCH"' EXIT

declare -A _retried=()
_MAX_RETRIES=2

while [ $_queue_idx -lt ${#_work_queue[@]} ] || [ ${#_busy_pools[@]} -gt 0 ]; do

	# Check all busy pools for completion
	for p in "${!_busy_pools[@]}"; do
		local_suite="${_busy_pools[$p]}"
		rc=$(_check_pool "$p" "$local_suite")
		if [ -n "$rc" ]; then
			_record_result "$local_suite" "$rc"
			_collect_pool_logs "$p"
			unset '_busy_pools[$p]'
		fi
	done

	# Check for externally injected suites (from "reschedule" command)
	if [ -f "$E2E_INJECT_QUEUE" ] && [ -s "$E2E_INJECT_QUEUE" ]; then
		_inj_count=0
		_inj_list=""
		while IFS= read -r _inj_suite; do
			[ -z "$_inj_suite" ] && continue
			_work_queue+=("$_inj_suite")
			_inj_list+="  ${_inj_suite}
"
			(( _inj_count++ ))
			printf "  [%s] INJECTED: %s (from reschedule)\n" "$(date '+%H:%M:%S')" "$_inj_suite"
		done < "$E2E_INJECT_QUEUE"
		> "$E2E_INJECT_QUEUE"
		if [ "$_inj_count" -gt 0 ] && [ -n "${NOTIFY_CMD:-}" ] && [ -x "${NOTIFY_CMD%% *}" ]; then
			$NOTIFY_CMD "[e2e] RESCHEDULE: ${_inj_count} suite(s) injected into queue:
${_inj_list}" < /dev/null >/dev/null 2>&1
		fi
	fi

	# Pick up one-shot forced dispatches (from "run --suite X --pool N --force")
	if [ -f "$E2E_FORCED_DISPATCH" ] && [ -s "$E2E_FORCED_DISPATCH" ]; then
		while IFS=' ' read -r _fd_pool _fd_suite; do
			[ -z "$_fd_pool" ] && continue
			_busy_pools[$_fd_pool]="$_fd_suite"
			_result_pool[$_fd_suite]="$_fd_pool"
			printf "  [%s] EXTERNAL: %s dispatched to pool %s\n" \
				"$(date '+%H:%M:%S')" "$_fd_suite" "$_fd_pool"
		done < "$E2E_FORCED_DISPATCH"
		> "$E2E_FORCED_DISPATCH"
	fi

	# Dispatch to free pools
	while [ $_queue_idx -lt ${#_work_queue[@]} ]; do
		free=$(_find_free_pool) || break
		suite="${_work_queue[$_queue_idx]}"
		if ! _dispatch_suite "$free" "$suite"; then
			_record_result "$suite" "99"
		fi
		(( _queue_idx++ ))
	done

	# Inline retry: when queue is drained and a free pool exists, re-queue
	# failed suites so idle pools pick them up immediately.
	if [ $_queue_idx -ge ${#_work_queue[@]} ] && _find_free_pool >/dev/null; then
		_retry_added=0
		for _rs in "${!_results[@]}"; do
			_rrc="${_results[$_rs]}"
			if [ "$_rrc" -ne 0 ] 2>/dev/null && [ "$_rrc" -ne 3 ] 2>/dev/null && [ "${_retried[$_rs]:-0}" -lt "$_MAX_RETRIES" ]; then
				_retried[$_rs]=$(( ${_retried[$_rs]:-0} + 1 ))
				_rp="${_result_pool[$_rs]:-}"
				if [ -n "$_rp" ]; then
					_ssh_con "$_rp" "rm -f '${_RC_PREFIX}-${_rs}.rc'" 2>/dev/null || true
				fi
				unset '_results[$_rs]'
				_work_queue+=("$_rs")
				printf "  [%s] RETRY %d/%d: queuing %s (was exit=%s)\n" "$(date '+%H:%M:%S')" "${_retried[$_rs]}" "$_MAX_RETRIES" "$_rs" "$_rrc"
				(( _retry_added++ ))
			fi
		done
		# Notify on retries (exceptional circumstance)
		if [ "$_retry_added" -gt 0 ] && [ -n "${NOTIFY_CMD:-}" ] && [ -x "${NOTIFY_CMD%% *}" ]; then
			_retry_list=""
			for (( _ri = _queue_idx; _ri < ${#_work_queue[@]}; _ri++ )); do
				_retry_list+="  ${_work_queue[$_ri]} (retry ${_retried[${_work_queue[$_ri]}]:-?}/${_MAX_RETRIES})
"
			done
			$NOTIFY_CMD "[e2e] RETRY: ${_retry_added} failed suite(s) re-queued:
${_retry_list}" < /dev/null >/dev/null 2>&1
		fi
		# Dispatch newly queued retries immediately
		if [ "$_retry_added" -gt 0 ]; then
			while [ $_queue_idx -lt ${#_work_queue[@]} ]; do
				free=$(_find_free_pool) || break
				suite="${_work_queue[$_queue_idx]}"
				if ! _dispatch_suite "$free" "$suite"; then
					_record_result "$suite" "99"
				fi
				(( _queue_idx++ ))
			done
		fi
	fi

	_write_dispatch_state

	# Print status only when something changed
	if [ ${#_busy_pools[@]} -gt 0 ]; then
		_queued_remaining=$(( ${#_work_queue[@]} - _queue_idx ))
		_status_line="${#_results[@]}d ${#_busy_pools[@]}r ${_queued_remaining}q"
		for p in "${!_busy_pools[@]}"; do
			_status_line+=" con${p}:${_busy_pools[$p]}"
		done
		if [ "${_status_line}" != "${_prev_status:-}" ]; then
			printf "  [%s] %d done, %d running" "$(date '+%H:%M:%S')" "${#_results[@]}" "${#_busy_pools[@]}"
			if [ "$_queued_remaining" -gt 0 ]; then
				printf ", %d queued" "$_queued_remaining"
			fi
			printf " |"
			for p in "${!_busy_pools[@]}"; do
				printf " con%s:%s" "$p" "${_busy_pools[$p]}"
			done
			echo ""
			_prev_status="$_status_line"
		fi
		sleep 30
	fi
done

# --- Collect logs from each conN and disN --------------------------------------

echo ""
echo "  Collecting final logs ..."

declare -A _pools_used=()
for s in "${!_result_pool[@]}"; do
	_pools_used[${_result_pool[$s]}]=1
done

for p in "${!_pools_used[@]}"; do
	_collect_pool_logs "$p" && echo "    Pool $p: logs collected" || echo "    Pool $p: WARNING: log collection failed"
done

# --- Final summary ------------------------------------------------------------

echo ""
echo "========================================"
echo "  Final Summary"
echo "========================================"

_overall_rc=0
_total=0
_passed=0
_failed=0
_skipped=0

for suite in "${suites_to_run[@]}"; do
	rc="${_results[$suite]:-}"
	pool="${_result_pool[$suite]:-?}"
	(( _total++ ))

	if [ -z "$rc" ]; then
		printf "  \033[1;33m????\033[0m  %-35s pool %-2s (no result)\n" "$suite" "$pool"
		_overall_rc=1
	elif [ "$rc" -eq 0 ]; then
		printf "  \033[1;32mPASS\033[0m  %-35s pool %-2s\n" "$suite" "$pool"
		(( _passed++ ))
	elif [ "$rc" -eq 3 ]; then
		printf "  \033[1;33mSKIP\033[0m  %-35s pool %-2s\n" "$suite" "$pool"
		(( _skipped++ ))
	else
		printf "  \033[1;31mFAIL\033[0m  %-35s pool %-2s (exit=%s)\n" "$suite" "$pool" "$rc"
		(( _failed++ ))
		_overall_rc=1
	fi
done

echo ""
echo "  Total: $_total  Passed: $_passed  Failed: $_failed  Skipped: $_skipped"
echo "  Logs: $_RUN_DIR/logs/"
echo "========================================"

if [ -n "${NOTIFY_CMD:-}" ] && [ -x "${NOTIFY_CMD%% *}" ]; then
	$NOTIFY_CMD "[e2e] ALL DONE: ${_passed} passed, ${_failed} failed, ${_skipped} skipped (of ${_total})" < /dev/null >/dev/null 2>&1
fi

# Cleanup dashboard
if [ -n "$DASH_SESSION" ]; then
	tmux kill-session -t "$DASH_SESSION" 2>/dev/null || true
fi

exit "$_overall_rc"
