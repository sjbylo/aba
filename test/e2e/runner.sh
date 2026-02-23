#!/bin/bash
# =============================================================================
# E2E Test Framework v2 -- Suite Runner (runs on conN inside tmux)
# =============================================================================
# Receives a list of suites from run.sh (via tmux send-keys), executes them
# sequentially, reverts disN snapshot before each suite, prints per-pool
# summary at the end.
#
# This script runs INSIDE the persistent tmux session on conN.
# Interactive mode is always on -- failures pause and wait for user input.
#
# Usage (sent by run.sh via tmux send-keys):
#   bash ~/aba/test/e2e/runner.sh POOL_NUM suite1 suite2 ...
#
# Environment:
#   Config files (config.env, pools.conf) are scp'd to conN by run.sh.
# =============================================================================

set -u

_RUNNER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ABA_ROOT="$(cd "$_RUNNER_DIR/../.." && pwd)"

LOCK_FILE="/tmp/e2e-runner.lock"
RC_FILE="/tmp/e2e-runner.rc"

# --- Concurrent run protection -----------------------------------------------

if [ -f "$LOCK_FILE" ]; then
	_lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
	if [ -n "$_lock_pid" ] && kill -0 "$_lock_pid" 2>/dev/null; then
		echo "ERROR: runner.sh already executing on $(hostname) (pid $_lock_pid). Aborting."
		echo "255" > "$RC_FILE"
		exit 1
	fi
	echo "  Stale lock file found (pid ${_lock_pid:-unknown} dead) -- removing."
	rm -f "$LOCK_FILE"
fi

echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT
rm -f "$RC_FILE"

# --- Parse arguments ----------------------------------------------------------

if [ $# -lt 2 ]; then
	echo "Usage: runner.sh POOL_NUM suite1 [suite2 ...]"
	echo "1" > "$RC_FILE"
	exit 1
fi

POOL_NUM="$1"; shift
export POOL_NUM
SUITES=("$@")

echo "${SUITES[*]}" > /tmp/e2e-last-suites

echo ""
echo "========================================"
echo "  E2E Runner on $(hostname) (pool $POOL_NUM)"
echo "  Suites: ${SUITES[*]}"
echo "  PID: $$"
echo "========================================"
echo ""

# --- Source libraries ---------------------------------------------------------

source "$_RUNNER_DIR/lib/framework.sh"
source "$_RUNNER_DIR/lib/config-helpers.sh"
source "$_RUNNER_DIR/lib/vm-helpers.sh"
source "$_RUNNER_DIR/lib/setup.sh"

# Source config.env
if [ -f "$_RUNNER_DIR/config.env" ]; then
	source "$_RUNNER_DIR/config.env"
fi

# Setup framework environment
e2e_setup

# Interactive mode always on
export _E2E_INTERACTIVE=1

# --- Bootstrap: ensure govc is available -------------------------------------

if ! command -v govc &>/dev/null; then
	echo "  Bootstrapping govc ..."
	cd "$_ABA_ROOT" && aba --dir cli ~/bin/govc
	export PATH="$HOME/bin:$PATH"
fi

# Source VMware credentials for snapshot revert
_vmconf="$(eval echo "${VMWARE_CONF:-~/.vmware.conf}")"
if [ -f "$_vmconf" ]; then
	set -a; source "$_vmconf"; set +a
fi

# --- Load per-pool overrides from pools.conf ----------------------------------

if [ -f "$_RUNNER_DIR/pools.conf" ]; then
	while IFS= read -r _line; do
		[[ "$_line" =~ ^[[:space:]]*# ]] && continue
		[[ -z "${_line// }" ]] && continue
		_found_num=""
		for _tok in $_line; do
			case "$_tok" in POOL_NUM=*) _found_num="${_tok#POOL_NUM=}" ;; esac
		done
		if [ "$_found_num" = "$POOL_NUM" ]; then
			for _tok in $_line; do
				case "$_tok" in ?*=*) export "$_tok" ;; esac
			done
			break
		fi
	done < "$_RUNNER_DIR/pools.conf"
fi

# --- Resolve pool variables ---------------------------------------------------

DIS_VM="dis${POOL_NUM}"
INTERNAL_BASTION="$(pool_internal_bastion "$POOL_NUM")"
export INTERNAL_BASTION

# --- Revert disN snapshot helper ----------------------------------------------

_revert_dis_snapshot() {
	local snapshot="${1:-pool-ready}"
	echo ""
	echo "  Reverting $DIS_VM to snapshot '$snapshot' ..."

	if ! govc snapshot.tree -vm "$DIS_VM" 2>/dev/null | grep -q "$snapshot"; then
		echo "  WARNING: Snapshot '$snapshot' not found on $DIS_VM -- skipping revert"
		return 0
	fi

	govc snapshot.revert -vm "$DIS_VM" "$snapshot" || { echo "  ERROR: revert $DIS_VM failed" >&2; return 1; }
	govc vm.power -on "$DIS_VM" 2>/dev/null || true
	sleep "${VM_BOOT_DELAY:-8}"

	local dis_host="${DIS_SSH_USER:-steve}@${DIS_VM}.${VM_BASE_DOMAIN:-example.com}"
	echo "  Waiting for SSH on $dis_host ..."
	local elapsed=0
	while [ $elapsed -lt 120 ]; do
		if _essh -o BatchMode=yes -o ConnectTimeout=5 "$dis_host" -- "date" 2>/dev/null; then
			echo "  SSH ready on $dis_host"
			return 0
		fi
		sleep 5
		elapsed=$(( elapsed + 5 ))
	done
	echo "  WARNING: SSH to $dis_host not ready after 120s" >&2
	return 1
}

# --- Execute suites -----------------------------------------------------------

_overall_rc=0
_start_time=$(date +%s)

declare -a _suite_names=()
declare -a _suite_results=()
declare -a _suite_durations=()

for suite in "${SUITES[@]}"; do
	suite_file="$_RUNNER_DIR/suites/suite-${suite}.sh"
	if [ ! -f "$suite_file" ]; then
		echo "  ERROR: Suite file not found: $suite_file"
		_suite_names+=("$suite")
		_suite_results+=("FAIL")
		_suite_durations+=("0")
		_overall_rc=1
		continue
	fi

	echo ""
	echo "========================================"
	echo "  Suite: $suite  (pool $POOL_NUM)"
	echo "========================================"

	# Revert disN to clean state before each suite
	_revert_dis_snapshot "pool-ready" || {
		echo "  WARNING: disN revert failed -- proceeding anyway"
	}

	# Clean up any stale Quay/registry state on conN from previous suite
	_cleanup_con_quay

	cd "$_ABA_ROOT"
	_suite_start=$(date +%s)

	_rc=0
	bash "$suite_file" || _rc=$?

	_suite_elapsed=$(( $(date +%s) - _suite_start ))
	_suite_mins=$(( _suite_elapsed / 60 ))
	_suite_secs=$(( _suite_elapsed % 60 ))

	_suite_names+=("$suite")
	_suite_durations+=("${_suite_mins}m ${_suite_secs}s")

	if [ $_rc -eq 0 ]; then
		_suite_results+=("PASS")
		echo ""
		echo "  Suite $suite: PASS (${_suite_mins}m ${_suite_secs}s)"
	elif [ $_rc -eq 3 ]; then
		_suite_results+=("SKIP")
		echo ""
		echo "  Suite $suite: SKIPPED by user (${_suite_mins}m ${_suite_secs}s)"
	else
		_suite_results+=("FAIL")
		_overall_rc=1
		echo ""
		echo "  Suite $suite: FAIL (exit=$_rc, ${_suite_mins}m ${_suite_secs}s)"
	fi
done

# --- Per-pool summary ---------------------------------------------------------

_total_elapsed=$(( $(date +%s) - _start_time ))
_total_mins=$(( _total_elapsed / 60 ))
_total_secs=$(( _total_elapsed % 60 ))

_passed=0
_failed=0
_skipped=0

echo ""
echo "========================================"
echo "  Pool $POOL_NUM Summary ($(hostname))"
echo "========================================"

for i in "${!_suite_names[@]}"; do
	_status="${_suite_results[$i]}"
	_dur="${_suite_durations[$i]}"
	case "$_status" in
		PASS)  printf "  \033[1;32mPASS\033[0m  %-35s (%s)\n" "${_suite_names[$i]}" "$_dur"; (( _passed++ )) ;;
		FAIL)  printf "  \033[1;31mFAIL\033[0m  %-35s (%s)\n" "${_suite_names[$i]}" "$_dur"; (( _failed++ )) ;;
		SKIP)  printf "  \033[1;33mSKIP\033[0m  %-35s (%s)\n" "${_suite_names[$i]}" "$_dur"; (( _skipped++ )) ;;
	esac
done

echo ""
echo "  Result: $_passed/${#_suite_names[@]} passed"
[ $_failed -gt 0 ] && echo "  Failed: $_failed"
[ $_skipped -gt 0 ] && echo "  Skipped: $_skipped"
echo "  Total time: ${_total_mins}m ${_total_secs}s"
echo "========================================"
echo ""

# Write exit code for run.sh to read
echo "$_overall_rc" > "$RC_FILE"
exit "$_overall_rc"
