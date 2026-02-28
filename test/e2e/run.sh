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
CLI_STATUS=""
CLI_START=""
_CLI_POOLS_SET=""
CLI_VERIFY=""
CLI_POOLS_FILE="$_RUN_DIR/pools.conf"

# --- Usage (defined before arg parsing so --help works) ----------------------

_usage() {
	cat <<-'USAGE'
	E2E Test Framework v2 -- Coordinator

	Usage:
	  run.sh --all                   Run all suites (1 pool, work-queue dispatch)
	  run.sh --all --pools 3         Run all suites across 3 pools
	  run.sh --suite NAME            Run one suite on a free pool
	  run.sh --suite X --pool 2      Run suite on a specific pool
	  run.sh --resume --pool 3       Reconnect and start scheduling again for a specific pool
	  run.sh --list                  List available suites
	  run.sh stop                    Kill all runners on all pools
	  run.sh start [--pools N]       Power on pool VMs (conN + disN)
	  run.sh --destroy               Destroy all pool VMs
	  run.sh deploy [--pools N]      Sync local ABA repo to all conN hosts
	  run.sh restart [--pools N]     Stop + deploy + re-run last suite(s) on all pools
	  run.sh restart --pool N        Stop + deploy + re-run last suite on one pool
	  run.sh status [--pools N]      Show what's running on each pool
	  run.sh attach conN             Attach to conN's tmux session
	  run.sh live [N]                Interactive multi-pane dashboard (read-write, handles prompts)
	  run.sh dash [N]                Open multi-pane summary dashboard (auto-detects from pools.conf)
	  run.sh dash [N] log            Open multi-pane full log dashboard
	  run.sh --verify                Verify all pool VMs (no suite dispatch)
	  run.sh --verify --pools 3     Verify pools 1-3
	  run.sh --dry-run               Show plan without executing

	Options:
	  --pools N              Number of pools (default: 1)
	  --recreate-golden      Force rebuild golden VM from template
	  --recreate-vms         Force reclone all conN/disN from golden
	  --clean                Clear checkpoints before running
	  --pool N               Target a specific pool (default: round-robin)
	  --resume               Reconnect to running suite(s) and continue scheduling on --pool N
	  -y, --yes              Auto-accept prompts (e.g. broken VM replacement)
	  -f, --force            Clean slate: wipe suite state on conN before dispatching
	                         Combine with --pool N or --suite X for targeted cleanup
	  -q, --quiet            CI mode: no interactive prompts (implies -y)
	  --dry-run              Show dispatch plan, don't execute

	The script auto-detects VM state and only creates/configures
	what's missing. No --setup flag needed.
	USAGE
}

# --- Parse Arguments ---------------------------------------------------------

while [ $# -gt 0 ]; do
	case "$1" in
		--suite|--suites)  CLI_SUITE="$2"; shift 2 ;;
		--all)             CLI_ALL=1; shift ;;
		-p|--pools)           CLI_POOLS="$2"; _CLI_POOLS_SET=1; shift 2 ;;
		-G|--recreate-golden) CLI_RECREATE_GOLDEN=1; shift ;;
		-R|--recreate-vms)    CLI_RECREATE_VMS=1; shift ;;
		-y|--yes)          CLI_YES=1; shift ;;
		-q|--quiet)        CLI_QUIET=1; CLI_YES=1; shift ;;
		--clean)           CLI_CLEAN=1; shift ;;
		--dry-run)         CLI_DRY_RUN=1; shift ;;
		-f|--force)        CLI_FORCE=1; shift ;;
		--pool)            CLI_POOL="$2"; shift 2 ;;
		--resume)          CLI_RESUME=1; shift ;;
		--destroy)         CLI_DESTROY=1; shift ;;
		--verify)          CLI_VERIFY=1; shift ;;
		--list|-l)         CLI_LIST=1; shift ;;
		--pools-file)      CLI_POOLS_FILE="$2"; shift 2 ;;
		attach)            CLI_ATTACH="$2"; shift 2 ;;
		deploy)            CLI_DEPLOY=1; shift ;;
		restart)           CLI_RESTART=1; shift ;;
		status)            CLI_STATUS=1; shift ;;
		live)              shift; CLI_LIVE=""
		                   if [[ "${1:-}" =~ ^[0-9]+$ ]]; then CLI_LIVE="$1"; shift; fi ;;
		stop)              CLI_STOP=1; shift ;;
		start)             CLI_START=1; shift ;;
		dash)              shift; CLI_DASHBOARD=""; CLI_DASH_LOG="summary.log"
		                   if [[ "${1:-}" =~ ^[0-9]+$ ]]; then CLI_DASHBOARD="$1"; shift; fi
		                   if [[ "${1:-}" == "log" ]]; then CLI_DASH_LOG="latest.log"; shift; fi ;;
		--help|-h)         _usage; exit 0 ;;
		*) echo "Unknown option: $1" >&2; _usage; exit 1 ;;
	esac
done

# --- Pool flag adjustment ----------------------------------------------------

[ -n "$CLI_POOL" ] && [ "$CLI_POOL" -gt "$CLI_POOLS" ] && CLI_POOLS="$CLI_POOL"

# Auto-detect pool count from pools.conf for operational commands (stop, deploy,
# restart) when --pools was not explicitly given.  Dispatch commands (--all,
# --suite) keep the CLI_POOLS default of 1.
_pool_count_from_conf() {
	grep -c '^[^#]' "$CLI_POOLS_FILE" 2>/dev/null || echo "$CLI_POOLS"
}
_OP_POOLS="$CLI_POOLS"
[ -z "$_CLI_POOLS_SET" ] && _OP_POOLS=$(_pool_count_from_conf)

# --- Source config -----------------------------------------------------------

if [ -f "$_RUN_DIR/config.env" ]; then
	source "$_RUN_DIR/config.env"
fi

# --- Ensure govc when we will use it (destroy or infra check / setup) ---------
_ABA_ROOT="$(cd "$_RUN_DIR/../.." && pwd)"
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

# --- Shared: create a tmux dashboard with one tail pane per pool --------------
# Usage: _create_tmux_dashboard SESSION_NAME NUM_POOLS LOG_FILE
_create_tmux_dashboard() {
	local _sess="$1" _np="$2" _logfile="${3:-summary.log}"
	local _user="${CON_SSH_USER:-steve}"
	local _domain="${VM_BASE_DOMAIN:-example.com}"

	_dash_pane_cmd() {
		local _p=$1
		local _h="con${_p}.${_domain}"
		echo "printf '\\033]2;dashboard | Pool ${_p} (con${_p})\\033\\\\'; echo '=== Pool ${_p} (con${_p}) [${_logfile}] ==='; while true; do ssh $_SSH_OPTS ${_user}@${_h} 'tail -F -n 500 ~/aba/test/e2e/logs/${_logfile}' 2>/dev/null && break; echo 'Waiting for con${_p} ...'; sleep 10; done"
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
	domain="${VM_BASE_DOMAIN:-example.com}"

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

# --- Deploy mode --------------------------------------------------------------

if [ -n "$CLI_DEPLOY" ]; then
	echo ""
	echo "  Deploying ABA repo to conN hosts ..."
	# Build a clean tarball once (excludes binaries, tarballs, IDE/test state)
	_deploy_tar=$(mktemp /tmp/aba-deploy.XXXXXX.tar.gz)
	tar czf "$_deploy_tar" -C "$_ABA_ROOT" \
		--exclude='.git' \
		--exclude='.backup' \
		--exclude='.cursor' \
		--exclude='*.swp' \
		--exclude='images' \
		--exclude='test/e2e/logs' \
		--exclude='*/iso-agent-based*' \
		--exclude='bundles*' \
		--exclude='ai' \
		--exclude='demo*' \
		--exclude='sno' \
		--exclude='*.tar' \
		--exclude='*.tar.gz' \
		--exclude='.dnf-install.log' \
		--exclude='*.bk' \
		.
	_deploy_size=$(du -h "$_deploy_tar" | cut -f1)
	echo "  Tarball: $_deploy_size"
	echo ""
	for (( i=1; i<=_OP_POOLS; i++ )); do
		user="${CON_SSH_USER:-steve}"
		host="con${i}.${VM_BASE_DOMAIN:-example.com}"
		target="${user}@${host}"
		echo -n "    con${i}: "

		# Skip pools with running suites unless --force is used
		if [ -z "$CLI_FORCE" ]; then
			_running_sess=$(ssh $_SSH_OPTS "${target}" \
				"tmux has-session -t '$E2E_TMUX_SESSION' 2>/dev/null && echo yes" 2>/dev/null || true)
			if [ "$_running_sess" = "yes" ]; then
				echo "RUNNING (skipped -- use --force to deploy anyway)"
				continue
			fi
		fi

		if ssh $_SSH_OPTS "${target}" "rm -rf ~/aba && mkdir ~/aba" 2>/dev/null &&
		   scp $_SSH_OPTS "$_deploy_tar" "${target}:/tmp/aba-deploy.tar.gz" 2>/dev/null &&
		   ssh $_SSH_OPTS "${target}" "tar xzf /tmp/aba-deploy.tar.gz -C ~/aba && rm -f /tmp/aba-deploy.tar.gz" 2>/dev/null; then
			echo "done"
		else
			echo "FAILED (unreachable?)"
		fi
	done
	rm -f "$_deploy_tar"
	echo ""
	echo "  Deploy complete. Retry failed steps with: run.sh attach conN"
	exit 0
fi

# --- Stop mode ---------------------------------------------------------------

if [ -n "$CLI_STOP" ]; then
	_num_pools="$_OP_POOLS"
	_stop_ssh="-o LogLevel=ERROR -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
	_user="${CON_SSH_USER:-steve}"
	_domain="${VM_BASE_DOMAIN:-example.com}"

	echo "Stopping all runners on $_num_pools pool(s) ..."
	for (( p=1; p<=_num_pools; p++ )); do
		_host="con${p}.${_domain}"
		printf "  con${p}: "
		if ssh $_stop_ssh "${_user}@${_host}" "
			tmux kill-session -t '$E2E_TMUX_SESSION' 2>/dev/null || true
			rm -f ${E2E_RC_PREFIX}-*.rc ${E2E_RC_PREFIX}-*.lock /tmp/e2e-runner.rc /tmp/e2e-runner.lock
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

	echo ""
	echo "  Powering on pool VMs (pools 1..$_OP_POOLS) ..."
	for (( p=1; p<=_OP_POOLS; p++ )); do
		for prefix in con dis; do
			vm="${prefix}${p}"
			_state=$(govc vm.info -json "$vm" 2>/dev/null | grep -o '"powerState":"[^"]*"' | head -1 || true)
			if [[ "$_state" == *"poweredOn"* ]]; then
				echo "    ${vm}: already on"
			elif govc vm.info "$vm" &>/dev/null; then
				govc vm.power -on "$vm" 2>/dev/null || true
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
	_domain="${VM_BASE_DOMAIN:-example.com}"

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
	echo "  [1/3] Stopping suites ..."
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

	# 2) Deploy
	echo ""
	echo "  [2/3] Deploying ..."
	_deploy_tar=$(mktemp /tmp/aba-deploy.XXXXXX.tar.gz)
	tar czf "$_deploy_tar" -C "$_ABA_ROOT" \
		--exclude='.git' \
		--exclude='.backup' \
		--exclude='.cursor' \
		--exclude='*.swp' \
		--exclude='images' \
		--exclude='test/e2e/logs' \
		--exclude='*/iso-agent-based*' \
		--exclude='bundles*' \
		--exclude='ai' \
		--exclude='demo*' \
		--exclude='sno' \
		--exclude='*.tar' \
		--exclude='*.tar.gz' \
		--exclude='.dnf-install.log' \
		--exclude='*.bk' \
		.
	_deploy_size=$(du -h "$_deploy_tar" | cut -f1)
	echo "    Tarball: $_deploy_size"
	for p in "${_restart_pools[@]}"; do
		_host="con${p}.${_domain}"
		_target="${_user}@${_host}"
		echo -n "    con${p}: "
		if ssh $_restart_ssh "${_target}" "rm -rf ~/aba && mkdir ~/aba" 2>/dev/null &&
		   scp $_restart_ssh "$_deploy_tar" "${_target}:/tmp/aba-deploy.tar.gz" 2>/dev/null &&
		   ssh $_restart_ssh "${_target}" "tar xzf /tmp/aba-deploy.tar.gz -C ~/aba && rm -f /tmp/aba-deploy.tar.gz" 2>/dev/null; then
			echo "done"
		else
			echo "FAILED (unreachable?)"
		fi
	done
	rm -f "$_deploy_tar"

	# 3) Re-launch last suite on each pool
	echo ""
	echo "  [3/3] Re-launching last suite(s) ..."
	_restart_ok=0
	_restart_fail=0
	for p in "${_restart_pools[@]}"; do
		_host="con${p}.${_domain}"
		_last=$(ssh $_restart_ssh "${_user}@${_host}" "cat /tmp/e2e-last-suites 2>/dev/null" 2>/dev/null || true)
		if [ -z "$_last" ]; then
			echo "    con${p}: skipped (no previous suite or unreachable)"
			(( _restart_fail++ ))
			continue
		fi
		read -ra _last_suites <<< "$_last"
		for suite in "${_last_suites[@]}"; do
			_runner_cmd="bash ~/aba/test/e2e/runner.sh $p $suite"
			if ssh $_restart_ssh "${_user}@${_host}" "tmux new-session -d -s '$E2E_TMUX_SESSION' '$_runner_cmd'" 2>/dev/null; then
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
	_domain="${VM_BASE_DOMAIN:-example.com}"

	printf "\n  %-6s  %-10s  %-40s  %s\n" "POOL" "STATE" "SUITE" "LAST OUTPUT"
	printf "  %-6s  %-10s  %-40s  %s\n" "------" "----------" "----------------------------------------" "--------------------"

	for (( p=1; p<=_OP_POOLS; p++ )); do
		_host="con${p}.${_domain}"
		_info=$(ssh $_status_ssh "${_user}@${_host}" "
			suite=\$(cat /tmp/e2e-last-suites 2>/dev/null || true)
			if tmux has-session -t '$E2E_TMUX_SESSION' 2>/dev/null; then
				suite=\${suite:-unknown}
				rc_file=\"${E2E_RC_PREFIX}-\${suite}.rc\"
				if [ -f \"\$rc_file\" ]; then
					rc=\$(cat \"\$rc_file\" 2>/dev/null)
					echo \"DONE|\${suite}|exit=\${rc}\"
				else
					last=\$(tail -1 ~/aba/test/e2e/logs/summary.log 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
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
		" 2>/dev/null || echo "UNREACHABLE|-|-")

		IFS='|' read -r _state _suite _detail <<< "$_info"
		case "$_state" in
			RUNNING)     _sc="\033[1;32m" ;;  # bold green
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
		printf "  con%-3s  ${_sc}%-10s\033[0m  %-40s  %s\033[0m\n" "$p" "$_state" "$_suite" "$_detail"
	done

	if [ -f "$E2E_DISPATCHER_PID" ] && kill -0 "$(cat "$E2E_DISPATCHER_PID" 2>/dev/null)" 2>/dev/null; then
		printf "\n  Dispatcher: \033[1;32mRUNNING\033[0m (pid %s)\n" "$(cat "$E2E_DISPATCHER_PID")"
	else
		printf "\n  Dispatcher: \033[90mnot running\033[0m"
		_last_cmd="./run.sh --all --pools $_OP_POOLS"
		printf " -- reconnect with: %s\n" "$_last_cmd"
	fi
	echo ""
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
	_domain="${VM_BASE_DOMAIN:-example.com}"
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
			printf "printf '\\\\033]2;live | Pool %d (con%d)\\\\033\\\\\\\\'\n" "$p" "$p"
			echo 'stty -ixon 2>/dev/null'
			echo "_MY_ID='${_live_id}'"
		echo 'while true; do'
		echo "  _owner=\$(ssh $_so ${_user}@${_h} 'cat /tmp/e2e-live-owner 2>/dev/null' 2>/dev/null)"
		echo '  if [ -n "$_owner" ] && [ "$_owner" != "$_MY_ID" ]; then'
		echo "    echo 'Another live dashboard took over con${p}. Exiting.'"
		echo '    exit 0'
		echo '  fi'
		echo "  ssh -t $_so ${_user}@${_h} \"tmux has-session -t '$E2E_TMUX_SESSION' 2>/dev/null && exec tmux attach -d -t '$E2E_TMUX_SESSION'\" 2>/dev/null || {"
		echo "    echo 'No e2e session on con${p}. Tailing summary...'"
		echo "    ssh $_so ${_user}@${_h} 'tail -n 50 ~/aba/test/e2e/logs/summary.log 2>/dev/null' || echo '(con${p} unreachable)'"
		echo '  }'
			echo '  echo "Reconnecting in 5s ..."'
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

	echo "=== Destroying all pool VMs ==="
	for (( i=1; i<=10; i++ )); do
		for prefix in con dis; do
			vm="${prefix}${i}"
			if govc vm.info "$vm" 2>/dev/null | grep "Name:"; then
				echo "  Destroying $vm ..."
				govc vm.power -off "$vm" 2>/dev/null || true
				govc vm.destroy "$vm" || true
			fi
		done
	done
	echo "=== Done ==="
	exit 0
fi

# --- Verify mode -------------------------------------------------------------

if [ -n "$CLI_VERIFY" ]; then
	_infra_flags="--verify --pools $CLI_POOLS --pools-file $CLI_POOLS_FILE"
	echo ""
	echo "=== Verifying pool VMs (pools 1..$CLI_POOLS) ==="
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
	_last_host="con${CLI_POOL}.${VM_BASE_DOMAIN:-example.com}"
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
	echo "ERROR: Specify --suite NAME, --all, --resume, or --list" >&2
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

# --- SSH helpers --------------------------------------------------------------

_SSH_OPTS="-o LogLevel=ERROR -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
_ssh_con() {
	local pool_num="$1"; shift
	local user="${CON_SSH_USER:-steve}"
	local host="con${pool_num}.${VM_BASE_DOMAIN:-example.com}"
	ssh $_SSH_OPTS "${user}@${host}" "$@"
}

# --- Check if VMs are ready --------------------------------------------------

_vms_ready() {
	local pool_num="$1"
	local user="${CON_SSH_USER:-steve}"
	local con="con${pool_num}.${VM_BASE_DOMAIN:-example.com}"
	local _reason=""

	if ! ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no \
		-o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
		"${user}@${con}" -- "test -d ~/aba"; then
		_reason="SSH to ${con} failed or ~/aba missing"
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

# --- scp test framework + config to each conN --------------------------------

echo ""
echo "  Deploying test framework to conN hosts ..."
for (( i=1; i<=CLI_POOLS; i++ )); do
	user="${CON_SSH_USER:-steve}"
	host="con${i}.${VM_BASE_DOMAIN:-example.com}"
	target="${user}@${host}"

	if scp -q $_SSH_OPTS "$_RUN_DIR/config.env" "$target:~/aba/test/e2e/config.env" &&
	   scp -q $_SSH_OPTS "$_RUN_DIR/pools.conf" "$target:~/aba/test/e2e/pools.conf" &&
	   scp -q $_SSH_OPTS "$_RUN_DIR/runner.sh"  "$target:~/aba/test/e2e/runner.sh" &&
	   scp -q $_SSH_OPTS "$_RUN_DIR"/lib/*.sh   "$target:~/aba/test/e2e/lib/" &&
	   scp -q $_SSH_OPTS "$_RUN_DIR"/suites/suite-*.sh "$target:~/aba/test/e2e/suites/"; then
		echo "    con${i}: framework + config deployed"
	else
		echo "    con${i}: FAILED to deploy framework" >&2
		exit 1
	fi
done

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

	# Kill any stale session
	_ssh_con "$pool_num" "tmux kill-session -t '$_TMUX_SESSION' 2>/dev/null || true"
	# Remove old rc/lock files
	_ssh_con "$pool_num" "rm -f '${_RC_PREFIX}-${suite}.rc' '${_RC_PREFIX}-${suite}.lock'"

	local runner_cmd="bash ~/aba/test/e2e/runner.sh $pool_num $suite"
	_ssh_con "$pool_num" "tmux new-session -d -s '$_TMUX_SESSION' '$runner_cmd'"

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
	fi
}

# --- Find a free pool (no active suite) ---------------------------------------

_find_free_pool() {
	for (( p=1; p<=CLI_POOLS; p++ )); do
		if [ -z "${_busy_pools[$p]:-}" ]; then
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

	_results[$suite]="$rc"

	if [ "$rc" -eq 0 ]; then
		printf "  COMPLETED: %-35s pool %-2s  \033[1;32mPASS\033[0m\n" "$suite" "$pool_num"
	elif [ "$rc" -eq 3 ]; then
		printf "  COMPLETED: %-35s pool %-2s  \033[1;33mSKIP\033[0m\n" "$suite" "$pool_num"
	else
		printf "  COMPLETED: %-35s pool %-2s  \033[1;31mFAIL\033[0m (exit=%s)\n" "$suite" "$pool_num" "$rc"
	fi
}

# --- Detect running and completed suites on all conN (stateless reconnect) ----

_detect_running_and_completed() {
	echo "  Scanning pools for existing suite state ..."
	local _rc_base
	_rc_base=$(basename "$_RC_PREFIX")

	for (( p=1; p<=CLI_POOLS; p++ )); do
		# Check for completed suites (rc files)
		local rc_files
		rc_files=$(_ssh_con "$p" "ls ${_RC_PREFIX}-*.rc 2>/dev/null" 2>/dev/null || true)
		if [ -n "$rc_files" ]; then
			while IFS= read -r rc_file; do
				[ -z "$rc_file" ] && continue
				local fname
				fname=$(basename "$rc_file" .rc)
				local suite="${fname#${_rc_base}-}"
				local rc
				rc=$(_ssh_con "$p" "cat '$rc_file' 2>/dev/null" 2>/dev/null || true)
				rc="${rc//[^0-9]/}"
				_completed[$suite]="${rc:-255}"
				_result_pool[$suite]="$p"
				echo "    con${p}: $suite completed (exit=${_completed[$suite]})"
			done <<< "$rc_files"
		fi

		# Check for running suite (static tmux session)
		local sess_exists
		sess_exists=$(_ssh_con "$p" "tmux has-session -t '$_TMUX_SESSION' 2>/dev/null && echo yes" 2>/dev/null || true)
		if [ "$sess_exists" = "yes" ]; then
			local suite
			suite=$(_ssh_con "$p" "cat /tmp/e2e-last-suites 2>/dev/null" 2>/dev/null || true)
			if [ -n "$suite" ] && [ -z "${_completed[$suite]:-}" ]; then
				_busy_pools[$p]="$suite"
				_result_pool[$suite]="$p"
				echo "    con${p}: $suite still running"
			fi
		fi
	done
}

# --- Force-clean: wipe rc files and tmux sessions -----------------------------

_force_clean_all() {
	echo "  --force: wiping all suite state on all pools ..."
	for (( p=1; p<=CLI_POOLS; p++ )); do
		_ssh_con "$p" "
			tmux kill-session -t '$_TMUX_SESSION' 2>/dev/null || true
			rm -f ${_RC_PREFIX}-*.rc ${_RC_PREFIX}-*.lock
		" 2>/dev/null || true
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
		rm -f ${_RC_PREFIX}-*.rc ${_RC_PREFIX}-*.lock
	" 2>/dev/null || true

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
			rm -f '${_RC_PREFIX}-${suite}.rc' '${_RC_PREFIX}-${suite}.lock'
		" 2>/dev/null || true
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
		echo "  All suites already completed (use --force to re-run)."
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

echo $$ > "$E2E_DISPATCHER_PID"
trap 'rm -f "$E2E_DISPATCHER_PID"' EXIT

while [ $_queue_idx -lt ${#_work_queue[@]} ] || [ ${#_busy_pools[@]} -gt 0 ]; do

	# Check all busy pools for completion
	for p in "${!_busy_pools[@]}"; do
		local_suite="${_busy_pools[$p]}"
		rc=$(_check_pool "$p" "$local_suite")
		if [ -n "$rc" ]; then
			_record_result "$local_suite" "$rc"
			unset '_busy_pools[$p]'
		fi
	done

	# Dispatch to free pools
	while [ $_queue_idx -lt ${#_work_queue[@]} ]; do
		free=$(_find_free_pool) || break
		suite="${_work_queue[$_queue_idx]}"
		_dispatch_suite "$free" "$suite"
		(( _queue_idx++ ))
	done

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

# --- Collect logs from each conN ----------------------------------------------

echo ""
echo "  Collecting logs ..."
mkdir -p "$_RUN_DIR/logs"

declare -A _pools_used=()
for s in "${!_result_pool[@]}"; do
	_pools_used[${_result_pool[$s]}]=1
done

for p in "${!_pools_used[@]}"; do
	user="${CON_SSH_USER:-steve}"
	host="con${p}.${VM_BASE_DOMAIN:-example.com}"
	local_dir="$_RUN_DIR/logs/pool-${p}"
	mkdir -p "$local_dir"
	if scp -r $_SSH_OPTS "${user}@${host}:~/aba/test/e2e/logs/*" "$local_dir/" 2>/dev/null; then
		echo "    Pool $p logs -> $local_dir/"
	else
		echo "    Pool $p: WARNING: log collection failed"
	fi
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

# Cleanup dashboard
if [ -n "$DASH_SESSION" ]; then
	tmux kill-session -t "$DASH_SESSION" 2>/dev/null || true
fi

exit "$_overall_rc"
