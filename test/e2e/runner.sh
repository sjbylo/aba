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

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
	echo "Usage: runner.sh [--resume] POOL_NUM suite_name [retry]"
	exit 1
fi

POOL_NUM="$1"; shift
export POOL_NUM
SUITE="$1"; shift
E2E_IS_RETRY="${1:-}"   # optional: "retry" when run.sh re-dispatched this suite after failure

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

# Source config.env (set -a exports all variables so child processes -- suites -- inherit them)
if [ -f "$_RUNNER_DIR/config.env" ]; then
	set -a
	source "$_RUNNER_DIR/config.env"
	set +a
fi

# Setup framework environment
e2e_setup

# Notify when suite starts (conN has notify.sh deployed by run.sh; bastion may not)
# #region agent log
printf '{"sessionId":"23cf03","hypothesisId":"H5","location":"runner.sh:start_notify","message":"suite start notify check","data":{"NOTIFY_CMD":"%s","SUITE":"%s","POOL_NUM":"%s"},"timestamp":%s}\n' \
	"${NOTIFY_CMD:-EMPTY}" "$SUITE" "$POOL_NUM" "$(date +%s%3N)" >> /tmp/e2e-debug-23cf03.log 2>/dev/null
# #endregion
if [ -n "${NOTIFY_CMD:-}" ]; then
	_label="STARTED"
	[ "$E2E_IS_RETRY" = "retry" ] && _label="RETRY"
	# #region agent log
	_dbg_start_rc=0
	$NOTIFY_CMD "[e2e] ${_label}: $SUITE -> con${POOL_NUM}" < /dev/null 2>/tmp/e2e-debug-start-stderr.log; _dbg_start_rc=$?
	printf '{"sessionId":"23cf03","hypothesisId":"H5","location":"runner.sh:start_notify:post","message":"start notify result","data":{"rc":%d,"label":"%s","stderr":"%s"},"timestamp":%s}\n' \
		"$_dbg_start_rc" "$_label" "$(head -1 /tmp/e2e-debug-start-stderr.log 2>/dev/null | tr '"' "'")" "$(date +%s%3N)" >> /tmp/e2e-debug-23cf03.log 2>/dev/null
	# #endregion
fi

# Interactive mode always on
export _E2E_INTERACTIVE=1

# --- Bootstrap: ensure govc is available -------------------------------------
# Set E2E_SKIP_SNAPSHOT_REVERT=1 for lightweight suites (e.g. dummy-pass/fail)
# that don't need VMware infrastructure.
# govc is needed for: snapshot revert (opt-in via E2E_USE_SNAPSHOT_REVERT=1),
# and cluster VM operations (aba delete uses govc underneath).

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

	local dis_host="${DIS_SSH_USER}@${DIS_VM}.${VM_BASE_DOMAIN}"
	echo "  Waiting for SSH on $dis_host ..."
	local elapsed=0
	while [ $elapsed -lt 120 ]; do
		if _essh -o BatchMode=yes -o ConnectTimeout=5 "$dis_host" -- "date" 2>/dev/null; then
			echo "  SSH ready on $dis_host"
			# Fix VC_FOLDER on disN after snapshot revert (snapshot has base value,
			# not pool-specific). The bundle/tar only copies aba repo files, not ~/.vmware.conf.
			if [ -n "${VC_FOLDER:-}" ]; then
				_essh "$dis_host" "sed -i \"s#^VC_FOLDER=.*#VC_FOLDER=${VC_FOLDER}#g\" ~/.vmware.conf" 2>/dev/null \
					&& echo "  Set VC_FOLDER=${VC_FOLDER} on $dis_host" \
					|| echo "  WARNING: could not set VC_FOLDER on $dis_host"
			fi
			if [ -n "${VM_DATASTORE:-}" ]; then
				_essh "$dis_host" "sed -i \"s#^GOVC_DATASTORE=.*#GOVC_DATASTORE=${VM_DATASTORE}#g\" ~/.vmware.conf" 2>/dev/null \
					&& echo "  Set GOVC_DATASTORE=${VM_DATASTORE} on $dis_host" \
					|| echo "  WARNING: could not set GOVC_DATASTORE on $dis_host"
			fi
			return 0
		fi
		sleep 5
		elapsed=$(( elapsed + 5 ))
	done
	echo "  WARNING: SSH to $dis_host not ready after 120s" >&2
	return 1
}

# --- Clean disN via ABA commands (replaces snapshot revert) -------------------
# Instead of reverting disN to a VMware snapshot, use ABA's own cleanup to
# return disN to a clean state.  This exercises aba uninstall/reset code paths
# and is faster (no VM reboot + SSH wait).
#
# Covers: registry uninstall, filesystem cleanup, podman prune, cache removal,
#         firewalld baseline restore, VC_FOLDER/GOVC_DATASTORE patch.
#
# Prerequisite: _pre_suite_cleanup has already run (deletes clusters/mirrors
#               via .cleanup/.mirror-cleanup files).

_cleanup_dis_aba() {
	local dis_host="${DIS_SSH_USER}@${DIS_VM}.${VM_BASE_DOMAIN}"
	echo ""
	echo "  Cleaning disN ($dis_host) via ABA commands ..."

	# 1. Clean up any registry from conN (Rule 6: uninstall from installer host)
	#    Skip if .installed exists but state.sh is missing -- the marker is stale
	#    (e.g. shipped via deploy tarball from the bastion) and aba would prompt.
	#    Use 'unregister' for externally-managed registries, 'uninstall' for ABA-installed.
	local _regcreds="$HOME/.aba/mirror/mirror"
	for _dir in "$_ABA_ROOT"; do
		if [ -f "$_dir/mirror/.installed" ]; then
			if [ ! -f "$_regcreds/state.sh" ]; then
				echo "  Removing stale .installed marker in $_dir (no state.sh)"
				rm -f "$_dir/mirror/.installed"
				continue
			fi
			source "$_regcreds/state.sh"
			if [ "${REG_VENDOR:-}" = "existing" ]; then
				echo "  Deregistering existing registry (from $_dir) ..."
				( cd "$_dir" && aba -y -d mirror unregister ) 2>&1 || echo "  WARNING: aba unregister failed in $_dir (rc=$?)"
			else
				echo "  Uninstalling registry via aba (from $_dir) ..."
				( cd "$_dir" && aba -y -d mirror uninstall ) 2>&1 || echo "  WARNING: aba uninstall failed in $_dir (rc=$?)"
			fi
		fi
	done

	# 2. Stop containers first, then clean disN filesystem
	echo "  Cleaning disN filesystem ..."
	_essh "$dis_host" "podman stop -a 2>/dev/null; podman rm -a -f 2>/dev/null; podman system prune --all --force 2>/dev/null; podman rmi --all --force 2>/dev/null" 2>&1 || true
	_essh "$dis_host" "rm -rf ~/aba" 2>&1 || true
	_essh "$dis_host" "rm -rf ~/.aba/mirror ~/.cache/agent ~/.oc-mirror" 2>&1 || true
	_essh "$dis_host" "sudo rm -rf ~/.local/share/containers/storage" 2>&1 || true
	# Remove stale CA trust anchors from previous registry installs
	_essh "$dis_host" "sudo rm -f /etc/pki/ca-trust/source/anchors/rootCA.pem && sudo update-ca-trust" 2>&1 || true

	# 3. Restore baseline system state (firewalld on, as created by setup-infra)
	_essh "$dis_host" "sudo systemctl enable firewalld 2>/dev/null; sudo systemctl start firewalld 2>/dev/null" 2>&1 || true

	# 4. Ensure VC_FOLDER / GOVC_DATASTORE are correct on disN
	if [ -n "${VC_FOLDER:-}" ]; then
		_essh "$dis_host" "sed -i \"s#^VC_FOLDER=.*#VC_FOLDER=${VC_FOLDER}#g\" ~/.vmware.conf" 2>/dev/null \
			&& echo "  Set VC_FOLDER=${VC_FOLDER} on $dis_host" \
			|| echo "  WARNING: could not set VC_FOLDER on $dis_host"
	fi
	if [ -n "${VM_DATASTORE:-}" ]; then
		_essh "$dis_host" "sed -i \"s#^GOVC_DATASTORE=.*#GOVC_DATASTORE=${VM_DATASTORE}#g\" ~/.vmware.conf" 2>/dev/null \
			&& echo "  Set GOVC_DATASTORE=${VM_DATASTORE} on $dis_host" \
			|| echo "  WARNING: could not set GOVC_DATASTORE on $dis_host"
	fi

	# 5. Verify clean state
	if _essh "$dis_host" "[ ! -d ~/aba ] && ! podman ps -q 2>/dev/null | grep -q ." 2>/dev/null; then
		echo "  disN cleanup verified: clean state"
	else
		echo "  WARNING: disN cleanup may be incomplete -- check manually"
	fi

	echo "  disN cleanup complete."
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

# --- Pre-suite cleanup: delete leftover clusters/mirrors from crashed/abandoned runs
# Iterates ALL .cleanup and .mirror-cleanup files, not just the current suite's.
# Each conN is a separate host and only one suite runs per pool, so any leftover
# file is from a previously finished/crashed suite and is safe to process.
_pre_suite_cleanup() {
	local found=""

	# Kill stale oc-mirror processes from previous suite (they hold port 55000)
	if pkill -f 'oc-mirror' 2>/dev/null; then
		echo "  Killed stale oc-mirror process(es)"
		sleep 2
	fi

	# Purge all oc-mirror caches (can grow to many GB across nested dirs)
	sudo find ~/ -type d -name .oc-mirror 2>/dev/null | xargs sudo rm -rf
	echo "  Purged oc-mirror caches"

	for cleanup_file in "${_RUNNER_DIR}"/logs/*.cleanup; do
		[ -f "$cleanup_file" ] || continue
		found=1
		echo "  Found leftover: $(basename "$cleanup_file") -- deleting registered clusters ..."
		local target abs_path _cleanup_ok=1
		while IFS=' ' read -r target abs_path; do
			[ -z "$abs_path" ] && continue
			echo "    $target: aba -y -d $abs_path delete"
			if ! ( _essh "$target" \
				"[ -d '$abs_path' ] && aba -y -d '$abs_path' delete || echo '  (dir not found -- already cleaned)'" \
				2>&1 ); then
				echo "  WARNING: cleanup SSH failed for $target:$abs_path"
				_cleanup_ok=""
			fi
		done < "$cleanup_file"
		if [ -n "$_cleanup_ok" ]; then
			rm -f "$cleanup_file"
		else
			echo "  WARNING: keeping $(basename "$cleanup_file") -- some entries failed"
		fi
	done

	for cleanup_file in "${_RUNNER_DIR}"/logs/*.mirror-cleanup; do
		[ -f "$cleanup_file" ] || continue
		found=1
		echo "  Found leftover: $(basename "$cleanup_file") -- uninstalling registered mirrors ..."
		local target abs_path _mirror_ok=1
		while IFS=' ' read -r target abs_path; do
			[ -z "$abs_path" ] && continue
			echo "    $target: aba -y -d $abs_path uninstall"
			if ! ( _essh "$target" \
				"[ -d '$abs_path' ] && aba -y -d '$abs_path' uninstall || echo '  (dir not found -- already cleaned)'" \
				2>&1 ); then
				echo "  WARNING: cleanup SSH failed for $target:$abs_path"
				_mirror_ok=""
			fi
		done < "$cleanup_file"
		if [ -n "$_mirror_ok" ]; then
			rm -f "$cleanup_file"
		else
			echo "  WARNING: keeping $(basename "$cleanup_file") -- some entries failed"
		fi
	done

	[ -n "$found" ] && echo "  Pre-suite cleanup complete."
	return 0
}

_pre_suite_cleanup

if [ "${E2E_SKIP_SNAPSHOT_REVERT:-}" != "1" ]; then
	if [ "${E2E_USE_SNAPSHOT_REVERT:-}" = "1" ]; then
		# Legacy path: VMware snapshot revert (opt-in via E2E_USE_SNAPSHOT_REVERT=1)
		_revert_dis_snapshot "pool-ready" || {
			echo ""
			echo "  ERROR: disN revert failed -- cannot proceed."
			echo "  $DIS_VM must have a 'pool-ready' snapshot. Create it by running"
			echo "  clone-and-check (or setup-infra Phase 3) for this pool."
			echo ""
			echo "1" > "$RC_FILE"
			exit 1
		}
	else
		# Default: clean disN using ABA's own commands (exercises product code paths)
		_cleanup_dis_aba
	fi

	# Clean up any stale Quay/registry state on conN from previous suite
	_cleanup_con_quay
else
	echo "  (Skipping disN cleanup and Quay cleanup -- E2E_SKIP_SNAPSHOT_REVERT=1)"
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
		# Cleanup clusters BEFORE disN reset -- aba delete needs cluster dir
		_pre_suite_cleanup
		if [ "${E2E_SKIP_SNAPSHOT_REVERT:-}" != "1" ]; then
			if [ "${E2E_USE_SNAPSHOT_REVERT:-}" = "1" ]; then
				_revert_dis_snapshot "pool-ready" || {
					echo "  ERROR: disN revert failed -- cannot restart. Fix snapshot then re-run."
					echo "1" > "$RC_FILE"
					exit 1
				}
			else
				_cleanup_dis_aba
			fi
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
