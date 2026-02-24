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
#   4. Distribute suites across pools (round-robin, shuffled)
#   5. Send runner command into persistent tmux on each conN
#   6. Monitor completion, collect results
#   7. Print final combined summary
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

# --- CLI Variables -----------------------------------------------------------

CLI_SUITE=""
CLI_ALL=""
CLI_POOLS=1
CLI_RECREATE_GOLDEN=""
CLI_RECREATE_VMS=""
CLI_QUIET=""
CLI_CLEAN=""
CLI_DRY_RUN=""
CLI_FORCE=""
CLI_POOL=""
CLI_LAST=""
CLI_DESTROY=""
CLI_STOP=""
CLI_LIST=""
CLI_ATTACH=""
CLI_VERIFY=""
CLI_POOLS_FILE="$_RUN_DIR/pools.conf"

# --- Usage (defined before arg parsing so --help works) ----------------------

_usage() {
	cat <<-'USAGE'
	E2E Test Framework v2 -- Coordinator

	Usage:
	  run.sh --all                   Run all suites (1 pool, default)
	  run.sh --all --pools 3         Run all suites across 3 pools
	  run.sh --suite NAME            Run one suite
	  run.sh --suite X --pool 2      Run suite on a specific pool
	  run.sh --last --pool 3         Re-run last suite(s) on a pool
	  run.sh --list                  List available suites
	  run.sh stop                    Kill all runners on all pools
	  run.sh --destroy               Destroy all pool VMs
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
	  --last                 Re-run the last suite(s) dispatched to --pool N
	  -f, --force            Kill any running runner on conN before dispatching
	  -q, --quiet            CI mode: no interactive prompts
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
		-p|--pools)           CLI_POOLS="$2"; shift 2 ;;
		-G|--recreate-golden) CLI_RECREATE_GOLDEN=1; shift ;;
		-R|--recreate-vms)    CLI_RECREATE_VMS=1; shift ;;
		-q|--quiet)        CLI_QUIET=1; shift ;;
		--clean)           CLI_CLEAN=1; shift ;;
		--dry-run)         CLI_DRY_RUN=1; shift ;;
		-f|--force)        CLI_FORCE=1; shift ;;
		--pool)            CLI_POOL="$2"; shift 2 ;;
		--last)            CLI_LAST=1; shift ;;
		--destroy)         CLI_DESTROY=1; shift ;;
		--verify)          CLI_VERIFY=1; shift ;;
		--list|-l)         CLI_LIST=1; shift ;;
		--pools-file)      CLI_POOLS_FILE="$2"; shift 2 ;;
		attach)            CLI_ATTACH="$2"; shift 2 ;;
		live)              shift; CLI_LIVE=""
		                   if [[ "${1:-}" =~ ^[0-9]+$ ]]; then CLI_LIVE="$1"; shift; fi ;;
		stop)              CLI_STOP=1; shift ;;
		dash)              shift; CLI_DASHBOARD=""; CLI_DASH_LOG="summary.log"
		                   if [[ "${1:-}" =~ ^[0-9]+$ ]]; then CLI_DASHBOARD="$1"; shift; fi
		                   if [[ "${1:-}" == "log" ]]; then CLI_DASH_LOG="latest.log"; shift; fi ;;
		--help|-h)         _usage; exit 0 ;;
		*) echo "Unknown option: $1" >&2; _usage; exit 1 ;;
	esac
done

# --- Pool flag adjustment ----------------------------------------------------

[ -n "$CLI_POOL" ] && [ "$CLI_POOL" -gt "$CLI_POOLS" ] && CLI_POOLS="$CLI_POOL"

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

	echo "Attaching to tmux session on ${user}@${host} ..."
	exec ssh -t -o LogLevel=ERROR "${user}@${host}" "tmux attach -t e2e-run 2>/dev/null || echo 'No e2e-run session found on ${host}.'"
fi

# --- Stop mode ---------------------------------------------------------------

if [ -n "$CLI_STOP" ]; then
	_num_pools=$(grep -c '^[^#]' "$CLI_POOLS_FILE" 2>/dev/null || echo "$CLI_POOLS")
	_stop_ssh="-o LogLevel=ERROR -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
	_user="${CON_SSH_USER:-steve}"
	_domain="${VM_BASE_DOMAIN:-example.com}"

	echo "Stopping all runners on $_num_pools pool(s) ..."
	for (( p=1; p<=_num_pools; p++ )); do
		_host="con${p}.${_domain}"
		printf "  con${p}: "
		if ssh $_stop_ssh "${_user}@${_host}" \
			"kill \$(cat /tmp/e2e-runner.lock 2>/dev/null) 2>/dev/null; rm -f /tmp/e2e-runner.lock /tmp/e2e-runner.rc; tmux kill-session -t e2e-run 2>/dev/null; echo stopped" 2>/dev/null; then
			:
		else
			echo "unreachable"
		fi
	done
	echo "Done."
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
			echo 'while true; do'
			echo "  if ssh $_so ${_user}@${_h} tmux has-session -t e2e-run 2>/dev/null; then"
			echo "    ssh -t $_so ${_user}@${_h} tmux attach -d -t e2e-run"
			echo '  else'
			echo "    echo 'No e2e-run session on con${p}. Tailing summary...'"
			echo "    ssh $_so ${_user}@${_h} 'tail -n 50 ~/aba/test/e2e/logs/summary.log 2>/dev/null' || echo '(con${p} unreachable)'"
			echo '  fi'
			echo '  echo "Reconnecting in 5s ..."'
			echo '  sleep 5'
			echo 'done'
		} > "$_script"
		chmod +x "$_script"
		echo "$_script"
	}

	if [ "$_num_pools" -le 3 ]; then
		tmux new-session -d -s "$LIVE_SESSION" "$(_live_create_script 1)"
		for (( p=2; p<=_num_pools; p++ )); do
			tmux split-window -t "$LIVE_SESSION" -v "$(_live_create_script $p)"
		done
		tmux select-layout -t "$LIVE_SESSION" even-vertical 2>/dev/null
	else
		# 4-pool grid: ensure pane index N runs pool N+1 (0=pool1, 1=pool2, 2=pool3, 3=pool4)
		tmux new-session -d -s "$LIVE_SESSION" "$(_live_create_script 1)"
		tmux split-window -t "$LIVE_SESSION" -h "$(_live_create_script 2)"
		tmux split-window -t "${LIVE_SESSION}.0" -v "$(_live_create_script 3)"
		tmux split-window -t "${LIVE_SESSION}.1" -v "$(_live_create_script 4)"
		tmux select-layout -t "$LIVE_SESSION" tiled 2>/dev/null
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
	_SSH_OPTS="-o LogLevel=ERROR -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
	DASH_SESSION="e2e-dashboard"

	tmux kill-session -t "$DASH_SESSION" 2>/dev/null || true

	_dash_tail_cmd() {
		local p=$1
		local user="${CON_SSH_USER:-steve}"
		local host="con${p}.${VM_BASE_DOMAIN:-example.com}"
		echo "printf '\\033]2;dashboard | Pool $p (con${p})\\033\\\\'; echo '=== Pool $p (con${p}) [${CLI_DASH_LOG}] ==='; while true; do ssh $_SSH_OPTS ${user}@${host} 'tail -F -n 500 ~/aba/test/e2e/logs/${CLI_DASH_LOG}' 2>/dev/null && break; echo 'Waiting for con${p} ...'; sleep 10; done"
	}

	if [ "$_num_pools" -le 3 ]; then
		# 1-3 pools: horizontal stack (split vertically)
		tmux new-session -d -s "$DASH_SESSION" "$(_dash_tail_cmd 1)"
		for (( p=2; p<=_num_pools; p++ )); do
			tmux split-window -t "$DASH_SESSION" -v "$(_dash_tail_cmd $p)"
		done
		tmux select-layout -t "$DASH_SESSION" even-vertical 2>/dev/null
	else
		# 4-pool grid: pane index N = pool N+1 (0=pool1, 1=pool2, 2=pool3, 3=pool4)
		tmux new-session -d -s "$DASH_SESSION" "$(_dash_tail_cmd 1)"
		tmux split-window -t "$DASH_SESSION" -h "$(_dash_tail_cmd 2)"
		tmux split-window -t "${DASH_SESSION}.0" -v "$(_dash_tail_cmd 3)"
		tmux split-window -t "${DASH_SESSION}.1" -v "$(_dash_tail_cmd 4)"
		tmux select-layout -t "$DASH_SESSION" tiled 2>/dev/null
	fi
	tmux set-option -t "$DASH_SESSION" allow-rename on 2>/dev/null
	tmux set-option -t "$DASH_SESSION" pane-border-status top 2>/dev/null
	tmux set-option -t "$DASH_SESSION" pane-border-format " #{pane_title} " 2>/dev/null
	echo "Attaching to dashboard (${_num_pools} pools) ..."
	exec tmux attach -t "$DASH_SESSION"
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

if [ -n "$CLI_LAST" ]; then
	if [ -z "$CLI_POOL" ]; then
		echo "ERROR: --last requires --pool N" >&2
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
	echo "ERROR: Specify --suite NAME, --all, --last, or --list" >&2
	_usage
	exit 1
fi

if [ ${#suites_to_run[@]} -eq 0 ]; then
	echo "No suites found."
	exit 0
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

	if ! govc snapshot.tree -vm "con${pool_num}" | grep "pool-ready"; then
		_reason="con${pool_num} missing pool-ready snapshot"
		echo "  Pool $pool_num: not ready ($_reason)" >&2
		return 1
	fi

	if ! govc snapshot.tree -vm "dis${pool_num}" | grep "pool-ready"; then
		_reason="dis${pool_num} missing pool-ready snapshot"
		echo "  Pool $pool_num: not ready ($_reason)" >&2
		return 1
	fi
}

# --- Dry run (before infra check -- no side effects) -------------------------

if [ -n "$CLI_DRY_RUN" ]; then
	echo ""
	echo "=== DRY RUN ==="
	echo "  Pools: $CLI_POOLS"
	echo "  Suites: ${suites_to_run[*]}"
	echo ""

	if [ -n "$CLI_POOL" ]; then
		echo "  con${CLI_POOL}: (targeted)"
		for suite in "${suites_to_run[@]}"; do
			echo "    - ${suite}"
		done
	else
		_shuffled=($(printf '%s\n' "${suites_to_run[@]}" | shuf))
		for (( p=0; p<CLI_POOLS; p++ )); do
			pool_num=$(( p + 1 ))
			echo "  con${pool_num}:"
			for (( s=p; s<${#_shuffled[@]}; s+=CLI_POOLS )); do
				echo "    - ${_shuffled[$s]}"
			done
		done
	fi
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
	"$BASH" "$_RUN_DIR/setup-infra.sh" $_infra_flags || { echo "FATAL: Infrastructure setup failed" >&2; exit 1; }
fi

# --- scp config files to each conN -------------------------------------------

echo ""
echo "  Deploying config files to conN hosts ..."
for (( i=1; i<=CLI_POOLS; i++ )); do
	user="${CON_SSH_USER:-steve}"
	host="con${i}.${VM_BASE_DOMAIN:-example.com}"
	target="${user}@${host}"

	_deploy_ok=1
	scp $_SSH_OPTS "$_RUN_DIR/config.env" "$target:~/aba/test/e2e/config.env" || _deploy_ok=0
	scp $_SSH_OPTS "$_RUN_DIR/pools.conf" "$target:~/aba/test/e2e/pools.conf" || _deploy_ok=0
	if [ "$_deploy_ok" -eq 1 ]; then
		echo "    con${i}: config.env + pools.conf deployed"
	else
		echo "    con${i}: WARNING: deploy failed (SCP error above)"
	fi
done

# --- Shuffle and distribute suites across pools (round-robin) -----------------

declare -a POOL_SUITES
for (( p=1; p<=CLI_POOLS; p++ )); do
	POOL_SUITES[$p]=""
done

if [ -n "$CLI_POOL" ]; then
	POOL_SUITES[$CLI_POOL]="${suites_to_run[*]}"
else
	_shuffled=($(printf '%s\n' "${suites_to_run[@]}" | shuf))
	for (( s=0; s<${#_shuffled[@]}; s++ )); do
		pool_num=$(( (s % CLI_POOLS) + 1 ))
		if [ -n "${POOL_SUITES[$pool_num]}" ]; then
			POOL_SUITES[$pool_num]="${POOL_SUITES[$pool_num]} ${_shuffled[$s]}"
		else
			POOL_SUITES[$pool_num]="${_shuffled[$s]}"
		fi
	done
fi

echo ""
echo "  Suite distribution:"
for (( p=1; p<=CLI_POOLS; p++ )); do
	echo "    con${p}: ${POOL_SUITES[$p]}"
done
echo ""

# --- Ensure persistent tmux session on each conN and send runner command ------

TMUX_SESSION="e2e-run"
declare -A _dispatched=()

for (( p=1; p<=CLI_POOLS; p++ )); do
	pool_suites="${POOL_SUITES[$p]}"
	if [ -z "$pool_suites" ]; then
		echo "  Pool $p: no suites assigned -- skipping"
		continue
	fi

	echo "  Dispatching to con${p} (tmux: $TMUX_SESSION) ..."

	# Ensure tmux session exists
	if ! _ssh_con "$p" "tmux has-session -t $TMUX_SESSION 2>/dev/null"; then
		_ssh_con "$p" "tmux new-session -d -s $TMUX_SESSION"
		echo "    Created tmux session '$TMUX_SESSION' on con${p}"
	else
		echo "    Reusing existing tmux session '$TMUX_SESSION' on con${p}"
	fi

	# Check for active runner (lock file)
	_lock_status=$(_ssh_con "$p" "
		if [ -f /tmp/e2e-runner.lock ]; then
			pid=\$(cat /tmp/e2e-runner.lock)
			if kill -0 \$pid 2>/dev/null; then
				echo BUSY
			else
				echo STALE
			fi
		else
			echo FREE
		fi
	")

	if [ "$_lock_status" = "BUSY" ]; then
		if [ -n "$CLI_FORCE" ]; then
			echo "    --force: killing existing runner on con${p} ..."
			_ssh_con "$p" "kill \$(cat /tmp/e2e-runner.lock) 2>/dev/null; rm -f /tmp/e2e-runner.lock /tmp/e2e-runner.rc"
			_ssh_con "$p" "tmux kill-session -t $TMUX_SESSION 2>/dev/null"
			_ssh_con "$p" "tmux new-session -d -s $TMUX_SESSION"
			echo "    Killed previous runner and created fresh tmux session"
		else
			echo "    runner.sh already running on con${p} -- reattaching to poll"
			_dispatched[$p]=1
			continue
		fi
	fi
	if [ "$_lock_status" = "STALE" ]; then
		echo "    Removing stale lock on con${p}"
		_ssh_con "$p" "rm -f /tmp/e2e-runner.lock"
	fi

	# Send the runner command into the tmux session
	_runner_cmd="bash ~/aba/test/e2e/runner.sh $p $pool_suites"
	_ssh_con "$p" "tmux send-keys -t $TMUX_SESSION '$_runner_cmd' Enter"
	_dispatched[$p]=1
	echo "    Sent: $_runner_cmd"
done

# --- Monitor: poll for completion ---------------------------------------------

if [ ${#_dispatched[@]} -gt 0 ]; then
	echo ""
	echo "  ${#_dispatched[@]} pool(s) dispatched. Monitoring for completion ..."
	echo "  (Attach interactively: run.sh attach conN)"
	echo ""
fi

# Open summary dashboard (if not quiet mode and multiple pools)
if [ -z "$CLI_QUIET" ] && [ "$CLI_POOLS" -gt 1 ]; then
	DASH_SESSION="e2e-dashboard"
	tmux kill-session -t "$DASH_SESSION" 2>/dev/null

	_first=1
	for (( p=1; p<=CLI_POOLS; p++ )); do
		user="${CON_SSH_USER:-steve}"
		host="con${p}.${VM_BASE_DOMAIN:-example.com}"
		_tail_cmd="printf '\\033]2;dashboard | Pool $p (con${p})\\033\\\\'; echo '=== Pool $p (con${p}) ==='; while true; do ssh $_SSH_OPTS ${user}@${host} 'tail -F -n 500 ~/aba/test/e2e/logs/summary.log' 2>/dev/null && break; echo 'Waiting for con${p} ...'; sleep 10; done"

		if [ "$_first" -eq 1 ]; then
			tmux new-session -d -s "$DASH_SESSION" "$_tail_cmd"
			_first=0
		else
			tmux split-window -t "$DASH_SESSION" -v "$_tail_cmd"
		fi
	done

	tmux select-layout -t "$DASH_SESSION" even-vertical 2>/dev/null
	tmux set-option -t "$DASH_SESSION" allow-rename on 2>/dev/null
	tmux set-option -t "$DASH_SESSION" pane-border-status top 2>/dev/null
	tmux set-option -t "$DASH_SESSION" pane-border-format " #{pane_title} " 2>/dev/null
	echo "  Summary dashboard created: tmux attach -t $DASH_SESSION"
	echo ""
fi

# Poll each pool's RC file for completion
declare -A _pool_done
declare -A _pool_rc
_all_done=""

if [ ${#_dispatched[@]} -eq 0 ]; then
	echo ""
	echo "  No pools were dispatched. All requested pools are busy or had no suites assigned."
	echo ""
else
	while [ -z "$_all_done" ]; do
		sleep 10
		_all_done=1

		for p in "${!_dispatched[@]}"; do
			[ -n "${_pool_done[$p]:-}" ] && continue

			_rc_content=$(_ssh_con "$p" "cat /tmp/e2e-runner.rc 2>/dev/null" 2>/dev/null || true)
			if [ -n "$_rc_content" ]; then
				_rc_content="${_rc_content//[^0-9]/}"
				_pool_done[$p]=1
				_pool_rc[$p]="${_rc_content:-255}"
				echo "  Pool $p (con${p}): finished (exit=${_pool_rc[$p]})"
			else
				_all_done=""
			fi
		done
	done
fi

# --- Collect logs from each conN ----------------------------------------------

echo ""
echo "  Collecting logs ..."
mkdir -p "$_RUN_DIR/logs"

for p in "${!_dispatched[@]}"; do
	user="${CON_SSH_USER:-steve}"
	host="con${p}.${VM_BASE_DOMAIN:-example.com}"
	local_dir="$_RUN_DIR/logs/pool-${p}"
	mkdir -p "$local_dir"
	if scp -r $_SSH_OPTS "${user}@${host}:~/aba/test/e2e/logs/*" "$local_dir/"; then
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
for (( p=1; p<=CLI_POOLS; p++ )); do
	if [ -z "${_dispatched[$p]:-}" ]; then
		printf "  Pool %d (con%d):  \033[1;33mSKIP\033[0m (no suites assigned)\n" "$p" "$p"
		continue
	fi
	rc="${_pool_rc[$p]:-255}"
	if [ "$rc" -eq 0 ]; then
		printf "  Pool %d (con%d):  \033[1;32mPASS\033[0m\n" "$p" "$p"
	else
		printf "  Pool %d (con%d):  \033[1;31mFAIL\033[0m (exit=%s)\n" "$p" "$p" "$rc"
		_overall_rc=1
	fi
done

echo ""
echo "  Logs: $_RUN_DIR/logs/"
echo "========================================"

# Cleanup dashboard tmux if it exists
if [ -n "${DASH_SESSION:-}" ]; then
	tmux kill-session -t "$DASH_SESSION" 2>/dev/null || true
fi

exit "$_overall_rc"
