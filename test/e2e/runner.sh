#!/usr/bin/env bash
# =============================================================================
# E2E Test Framework v2 -- Suite Runner (runs on conN inside tmux)
# =============================================================================
# Runs a SINGLE suite.  run.sh dispatches one suite at a time to each pool;
# when the suite finishes, run.sh dispatches the next one.
#
# This script runs INSIDE a tmux session on conN (session: e2e-suite, same on all hosts).
# Interactive mode is always on -- failures pause and wait for user input.
#
# Usage (sent by run.sh via tmux send-keys):
#   bash ~/aba/test/e2e/runner.sh POOL_NUM suite_name
#
# Exit code is written to $E2E_RC_PREFIX-<suite>.rc so run.sh can poll it.
#
# Environment:
#   Config files (config.env, pools.conf) are scp'd to conN by run.sh.
# =============================================================================

set -u

_RUNNER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ABA_ROOT="$(cd "$_RUNNER_DIR/../.." && pwd)"

source "$_RUNNER_DIR/lib/constants.sh"

# --- Parse arguments ----------------------------------------------------------

_RUNNER_RESUME=""
while [ $# -gt 0 ]; do
	case "$1" in
		--resume) _RUNNER_RESUME=1; shift ;;
		*) break ;;
	esac
done

if [ $# -ne 2 ]; then
	echo "Usage: runner.sh [--resume] POOL_NUM suite_name"
	exit 1
fi

POOL_NUM="$1"; shift
export POOL_NUM
SUITE="$1"; shift

LOCK_FILE="${E2E_RC_PREFIX}-${SUITE}.lock"
RC_FILE="${E2E_RC_PREFIX}-${SUITE}.rc"

# --- Concurrent run protection -----------------------------------------------

_LOCK_MAX_AGE=86400  # 24 hours

if [ -f "$LOCK_FILE" ]; then
	read -r _lock_pid _lock_ts _ < "$LOCK_FILE" 2>/dev/null || true
	if [ -n "$_lock_pid" ] && kill -0 "$_lock_pid" 2>/dev/null; then
		echo "ERROR: runner.sh for suite '$SUITE' already executing on $(hostname) (pid $_lock_pid). Aborting."
		echo "255" > "$RC_FILE"
		exit 1
	fi
	# Auto-expire: if lock is older than 24h, treat as stale regardless
	_now=$(date +%s)
	if [ -n "$_lock_ts" ] && [ $(( _now - _lock_ts )) -lt "$_LOCK_MAX_AGE" ] 2>/dev/null; then
		: # Lock is recent but PID is dead -- fall through to stale removal
	fi
	echo "  Stale lock file found (pid ${_lock_pid:-unknown} dead) -- removing."
	rm -f "$LOCK_FILE"
fi

echo "$$ $(date +%s)" > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT
rm -f "$RC_FILE"

echo "$SUITE" > /tmp/e2e-last-suites

echo ""
echo "========================================"
echo "  E2E Runner on $(hostname) (pool $POOL_NUM)"
echo "  Suite: $SUITE"
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
# Set E2E_SKIP_SNAPSHOT_REVERT=1 for lightweight suites (e.g. dummy-pass/fail)
# that don't need VMware infrastructure.

if [ "${E2E_SKIP_SNAPSHOT_REVERT:-}" != "1" ]; then
	if ! command -v govc &>/dev/null; then
		echo "  Bootstrapping govc ..."
		cd "$_ABA_ROOT" && aba --dir cli govc || {
			echo "  ERROR: Failed to bootstrap govc. Cannot revert snapshots without it." >&2
			exit 1
		}
		export PATH="$HOME/bin:$PATH"
		command -v govc &>/dev/null || {
			echo "  ERROR: govc not found in PATH after bootstrap." >&2
			exit 1
		}
	fi

	# Source VMware credentials for snapshot revert
	_vmconf="$(eval echo "${VMWARE_CONF:-~/.vmware.conf}")"
	if [ -f "$_vmconf" ]; then
		set -a; source "$_vmconf"; set +a
	fi
else
	echo "  (Skipping govc bootstrap -- E2E_SKIP_SNAPSHOT_REVERT=1)"
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

	local snap_out
	if ! snap_out=$(govc snapshot.tree -vm "$DIS_VM" 2>&1); then
		echo "  ERROR: govc snapshot.tree failed for $DIS_VM:" >&2
		echo "  $snap_out" >&2
		return 1
	fi

	if ! echo "$snap_out" | grep -q "$snapshot"; then
		echo "  ERROR: Snapshot '$snapshot' not found on $DIS_VM." >&2
		echo "  Available snapshots: $snap_out" >&2
		return 1
	fi

	govc snapshot.revert -vm "$DIS_VM" "$snapshot" || { echo "  ERROR: revert $DIS_VM failed" >&2; return 1; }
	# Power on may fail if VM is already on after revert — that's benign
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

# --- Execute suite ------------------------------------------------------------

_start_time=$(date +%s)

suite_file="$_RUNNER_DIR/suites/suite-${SUITE}.sh"
if [ ! -f "$suite_file" ]; then
	echo "  ERROR: Suite file not found: $suite_file"
	echo "1" > "$RC_FILE"
	exit 1
fi

# Resume mode: point E2E_RESUME_FILE at the previous run's state file
_STATE_FILE_PATH="${_RUNNER_DIR}/logs/${SUITE}.state"
if [ -n "$_RUNNER_RESUME" ] && [ -f "$_STATE_FILE_PATH" ]; then
	export E2E_RESUME_FILE="$_STATE_FILE_PATH"
	echo "  Resuming from state file: $_STATE_FILE_PATH"
	echo "  Tests previously passed will be skipped."
else
	unset E2E_RESUME_FILE 2>/dev/null || true
	if [ -n "$_RUNNER_RESUME" ]; then
		echo "  --resume requested but no state file found at $_STATE_FILE_PATH"
		echo "  Running suite from the beginning."
	fi
fi

# Reset terminal state
printf '\033c'
tmux clear-history 2>/dev/null

printf '%0.s#' {1..80}; echo
printf '%0.s#' {1..80}; echo
printf '##  %-74s##\n' ""
printf '##  %-74s##\n' "SUITE: $SUITE"
printf '##  %-74s##\n' "Pool $POOL_NUM  ($(hostname))    $(date '+%Y-%m-%d %H:%M:%S')"
printf '##  %-74s##\n' ""
printf '%0.s#' {1..80}; echo
printf '%0.s#' {1..80}; echo
echo ""

if [ "${E2E_SKIP_SNAPSHOT_REVERT:-}" != "1" ]; then
	# Revert disN to clean state before each suite
	_revert_dis_snapshot "pool-ready" || {
		echo ""
		echo "  ERROR: disN revert failed -- cannot proceed."
		echo "  $DIS_VM must have a 'pool-ready' snapshot. Create it by running"
		echo "  clone-and-check (or setup-infra Phase 3) for this pool."
		echo ""
		echo "1" > "$RC_FILE"
		exit 1
	}

	# Clean up any stale Quay/registry state on conN from previous suite
	_cleanup_con_quay
else
	echo "  (Skipping snapshot revert and Quay cleanup -- E2E_SKIP_SNAPSHOT_REVERT=1)"
fi

_rc=0

while true; do
	cd "$_ABA_ROOT"
	_suite_start=$(date +%s)

	_rc=0
	bash "$suite_file" || _rc=$?

	if [ $_rc -eq 4 ]; then
		echo ""
		echo "  Suite $SUITE: RESTARTING by user request (resuming from last checkpoint) ..."
		echo ""
		# Enable resume: skip previously-passed tests on restart
		if [ -f "$_STATE_FILE_PATH" ]; then
			export E2E_RESUME_FILE="$_STATE_FILE_PATH"
			echo "  Will skip $(grep -c '^0 ' "$_STATE_FILE_PATH" 2>/dev/null || echo 0) previously-passed test(s)."
		fi
		if [ "${E2E_SKIP_SNAPSHOT_REVERT:-}" != "1" ]; then
			_revert_dis_snapshot "pool-ready" || {
				echo "  ERROR: disN revert failed -- cannot restart. Fix snapshot then re-run."
				echo "1" > "$RC_FILE"
				exit 1
			}
			_cleanup_con_quay
		fi
		continue
	fi
	break
done

_elapsed=$(( $(date +%s) - _start_time ))
_mins=$(( _elapsed / 60 ))
_secs=$(( _elapsed % 60 ))

if [ $_rc -eq 0 ]; then
	echo ""
	echo "  Suite $SUITE: PASS (${_mins}m ${_secs}s)"
elif [ $_rc -eq 3 ]; then
	echo ""
	echo "  Suite $SUITE: SKIPPED by user (${_mins}m ${_secs}s)"
else
	echo ""
	echo "  Suite $SUITE: FAIL (exit=$_rc, ${_mins}m ${_secs}s)"
fi

echo ""
echo "========================================"
echo "  Pool $POOL_NUM Result: $SUITE"
echo "  Exit code: $_rc  Time: ${_mins}m ${_secs}s"
echo "========================================"
echo ""

# Write exit code for run.sh to read
echo "$_rc" > "$RC_FILE"
exit "$_rc"
