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
#   bash ~/.e2e-harness/runner.sh POOL_NUM suite_name
#
# Exit code is written to $E2E_RC_PREFIX-<suite>.rc so run.sh can poll it.
#
# Environment:
#   Config files (config.env, pools.conf) are scp'd to conN by run.sh.
# =============================================================================

set -u

_RUNNER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ABA_ROOT="$HOME/aba"
export _ABA_ROOT

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

# After framework.sh is sourced (below), the trap is upgraded to also
# clean up clusters/mirrors in the cleanup lists.  This ensures VMs are deleted
# even when the suite aborts, is killed, or hits an unhandled exit path.

echo "$SUITE" > /tmp/e2e-last-suites

# So the tmux window shows the suite name for all launch paths (dispatcher, restart, manual).
# Tolerate failure: runner may be invoked outside tmux (e.g. direct bash invocation)
tmux rename-window "$SUITE" 2>/dev/null || true

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

# Mirror data dirs that ABA manages (created by --data-dir or as default registry roots).
# These must ONLY be cleaned up by 'aba uninstall', never by brute-force rm -rf.
# If any survive after cleanup, that's a bug in aba uninstall that must be investigated.
_E2E_MIRROR_DATA_DIRS="quay-install my-quay-mirror-test1 mymirror-data docker-reg aba/e2e-docker-test aba/e2e-docker-neg"

# Stale firewall ports: test suites add these with --permanent; they persist
# across firewalld restarts and must be explicitly removed before each suite.
# Add new ports here when suites open them so cleanup stays in sync.
_E2E_STALE_FW_PORTS="8443/tcp 5000/tcp 80/tcp"

_cleanup_non_mirror_local() {
	# ABA CLI tools only (preserve ~/bin/notify.sh and other non-ABA files)
	rm -f ~/bin/{oc,kubectl,oc-mirror,openshift-install,govc,butane,aba}
	# oc-mirror cache and stale mirror state (same cleanup as disN gets)
	rm -rf ~/.oc-mirror ~/.cache/agent
	# Stale bundle tarballs from create-bundle-to-disk suite (can be ~10 GB)
	rm -rf ~/tmp/*
}

# Verify no mirror data dirs survive on a host after cleanup.
# If any exist, aba uninstall has a bug -- stop the suite so it can be investigated.
# Usage: _verify_no_mirror_data_dirs "disN" "$dis_host"   (remote via _essh)
#        _verify_no_mirror_data_dirs "conN"                (local)
_verify_no_mirror_data_dirs() {
	local label="$1"
	local remote_target="${2:-}"
	local _leftovers=""

	for _dir in $_E2E_MIRROR_DATA_DIRS; do
		if [ -n "$remote_target" ]; then
			_essh "$remote_target" "test -d ~/$_dir" && _leftovers+="  ~/$_dir"$'\n' || true
		else
			[ -d "$HOME/$_dir" ] && _leftovers+="  ~/$_dir"$'\n' || true
		fi
	done

	if [ -n "$_leftovers" ]; then
		echo ""
		echo "  FATAL: Mirror data dir(s) still exist on $label after cleanup:"
		echo "$_leftovers"
		echo "  These should have been removed by 'aba uninstall'."
		echo "  Investigate and fix the uninstall bug before re-running."
		return 1
	fi
	echo "  $label: no leftover mirror data dirs"
	return 0
}

# Verify no orphan cluster VMs exist in this pool's vCenter folder after cleanup.
# If any are found, the .cleanup mechanism failed -- stop so the root cause can
# be investigated.  Never silently destroy them.
# NOTE: VC_FOLDER from pools.conf already includes the pool path
#       (e.g. /Datacenter/vm/aba-e2e/pool2) -- do NOT append /pool${POOL_NUM}.
_verify_no_orphan_vms() {
	command -v govc >/dev/null || return 0
	[ -z "${VC_FOLDER:-}" ] && return 0

	# conN and disN are pool infrastructure VMs, not orphans
	local _known="con${POOL_NUM} dis${POOL_NUM}"
	local _all_vms
	_all_vms=$(govc find "$VC_FOLDER" -type m) || _all_vms=""
	[ -z "$_all_vms" ] && echo "  No VMs in $VC_FOLDER" && return 0

	local _real_orphans=""
	while IFS= read -r _ovm; do
		[ -z "$_ovm" ] && continue
		local _vmname
		_vmname=$(basename "$_ovm")
		local _is_infra=""
		for _k in $_known; do
			[ "$_vmname" = "$_k" ] && _is_infra=1 && break
		done
		[ -n "$_is_infra" ] && continue
		_real_orphans="${_real_orphans}${_real_orphans:+$'\n'}$_ovm"
	done <<< "$_all_vms"

	[ -z "$_real_orphans" ] && echo "  No orphan VMs in $VC_FOLDER" && return 0

	echo ""
	echo "  FATAL: Orphan VMs found in $VC_FOLDER after cleanup:"
	while IFS= read -r _o; do
		[ -z "$_o" ] && continue
		echo "    $_o"
	done <<< "$_real_orphans"
	echo ""
	echo "  The .cleanup mechanism should have deleted these via 'aba delete'."
	echo "  Investigate why cleanup failed before re-running."
	return 1
}

# Reset firewall on conN: remove stale test ports, preserve pool registry (8443).
_reset_con_firewall() {
	echo "  Resetting firewall ports on conN ..."
	local _removed=""
	for _port in $_E2E_STALE_FW_PORTS; do
		case "$_port" in
			8443/tcp|22/tcp) continue ;;  # pool registry + ssh — do not touch
		esac
		if sudo firewall-cmd --query-port="$_port" --permanent &>/dev/null; then
			sudo firewall-cmd --remove-port="$_port" --permanent
			_removed="$_removed $_port"
		fi
	done
	if [ -n "$_removed" ]; then
		sudo firewall-cmd --reload
		echo "  Removed stale ports:$_removed"
	fi

	# Verify: only pool registry port should remain
	local _ports _unexpected=""
	_ports=$(sudo firewall-cmd --list-ports)
	for _p in $_ports; do
		case "$_p" in 8443/tcp|22/tcp) ;; *) _unexpected="$_unexpected $_p" ;; esac
	done
	if [ -n "$_unexpected" ]; then
		echo "  WARNING: conN has unexpected firewall ports after reset:$_unexpected"
	else
		echo "  conN firewall verified: clean"
	fi
}

# Ensure the pool-registry container is running on conN.
# If a suite (e.g. create-bundle-to-disk) removed it, restart from existing data.
_ensure_pool_registry() {
	[ -d "$POOL_REG_DIR" ] || return 0

	if podman ps --format '{{.Names}}' | grep -q '^pool-registry$'; then
		echo "  pool-registry: running"
		return 0
	fi

	echo "  pool-registry: NOT running -- restarting from $POOL_REG_DIR ..."

	# Remove stale container entry if it exists (stopped/dead)
	podman rm -f pool-registry || true

	local _reg_host
	_reg_host="$(hostname -f)"

	podman run -d \
		-p 8443:5000 \
		--restart=always \
		--name pool-registry \
		-v "${POOL_REG_DIR}/data:/var/lib/registry:Z" \
		-v "${POOL_REG_DIR}/certs:/certs:Z" \
		-v "${POOL_REG_DIR}/auth:/auth:Z" \
		-e REGISTRY_HTTP_ADDR=0.0.0.0:5000 \
		-e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/registry.crt \
		-e REGISTRY_HTTP_TLS_KEY=/certs/registry.key \
		-e REGISTRY_AUTH=htpasswd \
		-e "REGISTRY_AUTH_HTPASSWD_REALM=Registry Realm" \
		-e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd \
		docker.io/library/registry:latest

	sleep 2
	if curl -sfk -o /dev/null -u "init:p4ssw0rd" "https://${_reg_host}:8443/v2/"; then
		echo "  pool-registry: restarted successfully"
	else
		echo "  WARNING: pool-registry restart failed -- curl check unsuccessful"
	fi
}

# Upgrade EXIT trap: clean up clusters/mirrors in cleanup lists on ANY exit.
# _E2E_SUITE_NAME is set inside the child bash process (the suite script),
# so we must set cleanup file paths explicitly from runner.sh's $SUITE var.
# If cleanup fails, override the suite result to signal the failure.
_runner_cleanup() {
	_E2E_CLEANUP_FILE="${E2E_LOG_DIR}/${SUITE}.cleanup"
	_E2E_MIRROR_CLEANUP_FILE="${E2E_LOG_DIR}/${SUITE}.mirror-cleanup"
	local _cleanup_failed=""
	if ! e2e_cleanup_clusters; then
		echo "ERROR: cluster cleanup failed -- investigate before re-running"
		_cleanup_failed=1
	fi
	if ! e2e_cleanup_mirrors; then
		echo "ERROR: mirror cleanup failed -- investigate before re-running"
		_cleanup_failed=1
	fi
	if [ -n "$_cleanup_failed" ] && [ -f "$RC_FILE" ]; then
		local _cur_rc
		_cur_rc=$(cat "$RC_FILE" 2>/dev/null)
		# Only override if the suite didn't already pass -- never mask a PASS
		if [ "${_cur_rc:-0}" -ne 0 ]; then
			echo "1" > "$RC_FILE"
		else
			echo "WARNING: cleanup issue detected but suite PASSED -- preserving PASS result" >&2
		fi
	fi
	rm -f "$LOCK_FILE"
}
trap '_runner_cleanup' EXIT

# Source config.env (set -a exports all variables so child processes -- suites -- inherit them)
if [ -f "$_RUNNER_DIR/config.env" ]; then
	set -a
	source "$_RUNNER_DIR/config.env"
	set +a
fi

# Git variables for suites (curl/git-clone install paths).
# Primary source: config.env (run.sh injects auto-detected values before deploy).
# Fallbacks here are safe defaults only -- never trust the VM's local git state.
export E2E_GIT_BRANCH="${E2E_GIT_BRANCH:-dev}"
export E2E_GIT_REPO="${E2E_GIT_REPO:-https://github.com/sjbylo/aba.git}"
export E2E_GIT_REPO_SLUG="${E2E_GIT_REPO_SLUG:-sjbylo/aba}"

# Setup framework environment
e2e_setup

# Interactive mode always on
export _E2E_INTERACTIVE=1

# --- Bootstrap: ensure govc is available -------------------------------------
# Set E2E_SKIP_SNAPSHOT_REVERT=1 for lightweight suites (e.g. dummy-pass/fail)
# that don't need VMware infrastructure.
# govc is needed for: snapshot revert (opt-in via E2E_USE_SNAPSHOT_REVERT=1),
# and cluster VM operations (aba delete uses govc underneath).

if [ "${E2E_SKIP_SNAPSHOT_REVERT:-}" != "1" ]; then
	if ! command -v govc &>/dev/null; then
		if [ -f "$_ABA_ROOT/cli/Makefile" ] && [ -f "$_ABA_ROOT/aba.conf" ]; then
			echo "  Bootstrapping govc ..."
			make -sC "$_ABA_ROOT/cli" govc || {
				echo "  ERROR: Failed to bootstrap govc. Cannot revert snapshots without it." >&2
				exit 1
			}
			export PATH="$HOME/bin:$PATH"
			command -v govc &>/dev/null || {
				echo "  ERROR: govc not found in PATH after bootstrap." >&2
				exit 1
			}
		else
			echo "  WARNING: ABA not fully initialized (missing cli/Makefile or aba.conf)."
			echo "           Suite will install/configure ABA before using govc."
		fi
	fi

	# Source VMware credentials for snapshot revert
	_vmconf="$(eval echo "${VMWARE_CONF:-~/.vmware.conf}")"
	if [ -f "$_vmconf" ]; then
		set -a; source "$_vmconf"; set +a
	fi
	# Source KVM credentials (if present)
	_kvmconf="$(eval echo "${KVM_CONF:-~/.kvm.conf}")"
	if [ -f "$_kvmconf" ]; then
		set -a; source "$_kvmconf"; set +a
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
	govc vm.power -on "$DIS_VM" || true
	sleep "${VM_BOOT_DELAY:-8}"

	local dis_host="${DIS_SSH_USER}@${DIS_VM}.${VM_BASE_DOMAIN}"
	echo "  Waiting for SSH on $dis_host ..."
	local elapsed=0
	while [ $elapsed -lt 120 ]; do
		if _essh -o BatchMode=yes -o ConnectTimeout=5 "$dis_host" -- "date"; then
			echo "  SSH ready on $dis_host"
			# Remove stale firewall ports that may have been baked into the snapshot
			echo "  Resetting firewall ports on $DIS_VM ..."
			for _port in $_E2E_STALE_FW_PORTS; do
				_essh "$dis_host" "sudo firewall-cmd --query-port=$_port --permanent &>/dev/null && sudo firewall-cmd --remove-port=$_port --permanent" 2>&1 || true
			done
			_essh "$dis_host" "sudo firewall-cmd --reload" 2>&1 || true
			# Fix VC_FOLDER on disN after snapshot revert (snapshot has base value,
			# not pool-specific). The bundle/tar only copies aba repo files, not ~/.vmware.conf.
			if [ -n "${VC_FOLDER:-}" ]; then
				_essh "$dis_host" "sed -i \"s#^VC_FOLDER=.*#VC_FOLDER=${VC_FOLDER}#g\" ~/.vmware.conf" \
					&& echo "  Set VC_FOLDER=${VC_FOLDER} on $dis_host" \
					|| echo "  WARNING: could not set VC_FOLDER on $dis_host"
			fi
			if [ -n "${VM_DATASTORE:-}" ]; then
				_essh "$dis_host" "sed -i \"s#^GOVC_DATASTORE=.*#GOVC_DATASTORE=${VM_DATASTORE}#g\" ~/.vmware.conf" \
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

	# Registry cleanup on conN is handled by _cleanup_con_quay() -- not here.
	# This function only cleans the disN filesystem and firewall.

	# 1. Clean disN non-mirror filesystem (aba code, CLI tools, caches)
	echo "  Cleaning disN filesystem (non-mirror artifacts) ..."
	_essh "$dis_host" "rm -rf ~/aba ~/bin" 2>&1 || true
	_essh "$dis_host" "rm -rf ~/.aba/mirror ~/.cache/agent ~/.oc-mirror" 2>&1 || true
	# Remove stale CA trust anchors from previous registry installs
	_essh "$dis_host" "sudo rm -f /etc/pki/ca-trust/source/anchors/rootCA.pem && sudo update-ca-trust" 2>&1 || true

	# 3. Restore baseline system state (firewalld on, as created by setup-infra)
	_essh "$dis_host" "sudo systemctl enable firewalld; sudo systemctl start firewalld" 2>&1 || true

	# 4. Remove stale firewall ports from permanent config (survive restart)
	echo "  Resetting firewall ports on disN ..."
	for _port in $_E2E_STALE_FW_PORTS; do
		_essh "$dis_host" "sudo firewall-cmd --query-port=$_port --permanent &>/dev/null && sudo firewall-cmd --remove-port=$_port --permanent" 2>&1 || true
	done
	_essh "$dis_host" "sudo firewall-cmd --reload" 2>&1 || true

	# Verify no stale ports remain on disN
	local _dis_fw_ports
	_dis_fw_ports=$(_essh "$dis_host" "sudo firewall-cmd --list-ports") || true
	if [ -n "$_dis_fw_ports" ]; then
		echo "  WARNING: disN still has firewall ports after reset: $_dis_fw_ports"
	else
		echo "  disN firewall verified: no test ports"
	fi

	# 5. Ensure VC_FOLDER / GOVC_DATASTORE are correct on disN
	if [ -n "${VC_FOLDER:-}" ]; then
		_essh "$dis_host" "sed -i \"s#^VC_FOLDER=.*#VC_FOLDER=${VC_FOLDER}#g\" ~/.vmware.conf" \
			&& echo "  Set VC_FOLDER=${VC_FOLDER} on $dis_host" \
			|| echo "  WARNING: could not set VC_FOLDER on $dis_host"
	fi
	if [ -n "${VM_DATASTORE:-}" ]; then
		_essh "$dis_host" "sed -i \"s#^GOVC_DATASTORE=.*#GOVC_DATASTORE=${VM_DATASTORE}#g\" ~/.vmware.conf" \
			&& echo "  Set GOVC_DATASTORE=${VM_DATASTORE} on $dis_host" \
			|| echo "  WARNING: could not set GOVC_DATASTORE on $dis_host"
	fi

	# 6. Verify clean state
	if _essh "$dis_host" "[ ! -d ~/aba ] && ! podman ps -q | grep -q ."; then
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

# Reset terminal visually (keeps tmux scrollback so 'live' view can scroll to previous suites)
printf '\033c'

printf '%0.s#' {1..80}; echo
printf '%0.s#' {1..80}; echo
printf '##  %-74s##\n' ""
printf '##  %-74s##\n' "SUITE START: $SUITE"
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
	if pkill -f 'oc-mirror'; then
		echo "  Killed stale oc-mirror process(es)"
		sleep 2
	fi

	# Purge all oc-mirror caches (can grow to many GB across nested dirs)
	sudo find ~/ -type d -name .oc-mirror | xargs sudo rm -rf
	echo "  Purged oc-mirror caches"

	for cleanup_file in "${_RUNNER_DIR}"/logs/*.cleanup; do
		[ -f "$cleanup_file" ] || continue
		found=1
		echo "  Found leftover: $(basename "$cleanup_file") -- deleting clusters from cleanup list ..."
		local target abs_path _cleanup_ok=1
		while IFS=' ' read -r target abs_path; do
			[ -z "$abs_path" ] && continue
			echo "    $target: aba -y -d $abs_path delete"
			if ! ( _essh "$target" \
				"if [ -d '$abs_path' ]; then
					aba -y -d '$abs_path' delete
				else
					echo '  FATAL: cluster dir $abs_path not found -- cannot run aba delete.'
					echo '  The dir was likely rm -rf'\''d before cleanup could run.'
					echo '  Orphan VMs may exist. Investigate the root cause.'
					exit 1
				fi" \
				2>&1 ); then
				echo "  WARNING: cleanup failed for $target:$abs_path"
				_cleanup_ok=""
			fi
		done < "$cleanup_file"
		if [ -n "$_cleanup_ok" ]; then
			rm -f "$cleanup_file"
		else
			echo "  ERROR: cluster cleanup FAILED for $(basename "$cleanup_file") -- cannot proceed"
			echo "  Investigate why 'aba delete' failed before re-running the suite."
			return 1
		fi
	done

	for cleanup_file in "${_RUNNER_DIR}"/logs/*.mirror-cleanup; do
		[ -f "$cleanup_file" ] || continue
		found=1
		echo "  Found leftover: $(basename "$cleanup_file") -- uninstalling mirrors from cleanup list ..."
		local target abs_path _mirror_ok=1
		while IFS=' ' read -r target abs_path; do
			[ -z "$abs_path" ] && continue
			echo "    $target: aba -y -d $abs_path uninstall"
			_mirror_rc=0
			_essh "$target" \
				"if [ -d '$abs_path' ]; then aba -y -d '$abs_path' uninstall; else echo '  (dir not found -- already cleaned)'; fi" \
				2>&1 || _mirror_rc=$?
			if [ "$_mirror_rc" -ne 0 ]; then
				echo "  ERROR: mirror cleanup failed for $target:$abs_path (exit=$_mirror_rc)"
				_mirror_ok=""
			fi
		done < "$cleanup_file"
		if [ -n "$_mirror_ok" ]; then
			rm -f "$cleanup_file"
		else
			echo "  ERROR: mirror cleanup FAILED for $(basename "$cleanup_file") -- cannot proceed"
			echo "  Investigate why 'aba uninstall' failed before re-running the suite."
			return 1
		fi
	done

	[ -n "$found" ] && echo "  Pre-suite cleanup complete."
	return 0
}

if [ -n "$_RUNNER_RESUME" ]; then
	echo "  (Skipping pre-suite cleanup -- --resume mode)"
elif [ "${E2E_SKIP_SNAPSHOT_REVERT:-}" != "1" ]; then
	if ! _pre_suite_cleanup; then
		echo ""
		echo "  FATAL: pre-suite cleanup failed. Stale clusters/mirrors could not be deleted."
		echo "  Investigate the failure above, fix it manually, then re-run the suite."
		echo ""
		echo "1" > "$RC_FILE"
		exit 1
	fi
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
	_cleanup_non_mirror_local
	_reset_con_firewall

	# Verify no mirror data dirs survived cleanup on either host.
	# If any exist, aba uninstall has a bug -- stop before starting the suite.
	_dis_host="${DIS_SSH_USER}@${DIS_VM}.${VM_BASE_DOMAIN}"
	if ! _verify_no_mirror_data_dirs "disN" "$_dis_host"; then
		echo "1" > "$RC_FILE"
		exit 1
	fi
	if ! _verify_no_mirror_data_dirs "conN"; then
		echo "1" > "$RC_FILE"
		exit 1
	fi

	if ! _verify_no_orphan_vms; then
		echo "1" > "$RC_FILE"
		exit 1
	fi

	_ensure_pool_registry
else
	echo "  (Skipping disN cleanup and Quay cleanup -- E2E_SKIP_SNAPSHOT_REVERT=1)"
fi

# Ensure conN ~/.vmware.conf has the correct pool-specific VC_FOLDER + GOVC_DATASTORE.
# The golden template bakes in default values; suites cp ~/.vmware.conf → ./vmware.conf,
# so the source must be correct before any suite starts.
if [ -f ~/.vmware.conf ]; then
	if [ -n "${VC_FOLDER:-}" ]; then
		sed -i "s#^VC_FOLDER=.*#VC_FOLDER=${VC_FOLDER}#g" ~/.vmware.conf
		echo "  conN vmware.conf: VC_FOLDER=${VC_FOLDER}"
	fi
	if [ -n "${VM_DATASTORE:-}" ]; then
		sed -i "s#^GOVC_DATASTORE=.*#GOVC_DATASTORE=${VM_DATASTORE}#g" ~/.vmware.conf
		echo "  conN vmware.conf: GOVC_DATASTORE=${VM_DATASTORE}"
	fi
fi

# Post-cleanup filesystem snapshot (debug: catch leftover files before suite starts)
echo ""
echo "  === Pre-suite filesystem snapshot (conN: $(hostname)) ==="
echo "  --- ls -ltr ~/ ---"
ls -ltr ~/
echo "  --- ls -ltr ~/* ---"
ls -ltr ~/* || true
echo "  --- sudo du -am ~/ | sort -rn | head -30 ---"
sudo du -am ~/ | sort -rn | head -30
if [ -n "${DIS_VM:-}" ]; then
	_dis="${DIS_SSH_USER}@${DIS_VM}.${VM_BASE_DOMAIN}"
	echo ""
	echo "  === Pre-suite filesystem snapshot (disN: ${DIS_VM}) ==="
	echo "  --- ls -ltr ~/ ---"
	_essh "$_dis" "ls -ltr ~/" 2>&1 || true
	echo "  --- ls -ltr ~/* ---"
	_essh "$_dis" "ls -ltr ~/*" 2>&1 || true
	echo "  --- sudo du -am ~/ | sort -rn | head -30 ---"
	_essh "$_dis" "sudo du -am ~/ | sort -rn | head -30" 2>&1 || true
fi
echo ""

_rc=0

while true; do
	mkdir -p "$_ABA_ROOT"
	cd "$_ABA_ROOT"
	_suite_start=$(date +%s)

	_rc=0
	bash "$suite_file" || _rc=$?

	if [ $_rc -eq 4 ]; then
		echo ""
		echo "  Suite $SUITE: RESTARTING by user request (from scratch) ..."
		echo ""
		# Full restart: do NOT resume -- cleanup tears down everything,
		# so previously-passed setup steps must run again.
		unset E2E_RESUME_FILE 2>/dev/null || true
		rm -f "$_STATE_FILE_PATH"
		# Cleanup clusters BEFORE disN reset -- aba delete needs cluster dir
		if ! _pre_suite_cleanup; then
			echo "  FATAL: pre-suite cleanup failed during restart. Cannot proceed."
			echo "1" > "$RC_FILE"
			exit 1
		fi
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
			_cleanup_non_mirror_local
			_reset_con_firewall

			# Verify no mirror data dirs survived cleanup
			_dis_host="${DIS_SSH_USER}@${DIS_VM}.${VM_BASE_DOMAIN}"
			if ! _verify_no_mirror_data_dirs "disN" "$_dis_host"; then
				echo "1" > "$RC_FILE"
				exit 1
			fi
			if ! _verify_no_mirror_data_dirs "conN"; then
				echo "1" > "$RC_FILE"
				exit 1
			fi

			if ! _verify_no_orphan_vms; then
				echo "1" > "$RC_FILE"
				exit 1
			fi

			_ensure_pool_registry
		fi
		# Re-apply pool-specific vmware.conf on conN (same as initial path)
		if [ -f ~/.vmware.conf ]; then
			[ -n "${VC_FOLDER:-}" ] && sed -i "s#^VC_FOLDER=.*#VC_FOLDER=${VC_FOLDER}#g" ~/.vmware.conf
			[ -n "${VM_DATASTORE:-}" ] && sed -i "s#^GOVC_DATASTORE=.*#GOVC_DATASTORE=${VM_DATASTORE}#g" ~/.vmware.conf
		fi
		# Post-cleanup filesystem snapshot (debug: catch leftover files on restart)
		echo ""
		echo "  === Pre-suite filesystem snapshot (conN: $(hostname)) ==="
		echo "  --- ls -ltr ~/ ---"
		ls -ltr ~/
		echo "  --- ls -ltr ~/* ---"
		ls -ltr ~/* || true
		echo "  --- sudo du -am ~/ | sort -rn | head -30 ---"
		sudo du -am ~/ | sort -rn | head -30
		if [ -n "${DIS_VM:-}" ]; then
			_dis="${DIS_SSH_USER}@${DIS_VM}.${VM_BASE_DOMAIN}"
			echo ""
			echo "  === Pre-suite filesystem snapshot (disN: ${DIS_VM}) ==="
			echo "  --- ls -ltr ~/ ---"
			_essh "$_dis" "ls -ltr ~/" 2>&1 || true
			echo "  --- ls -ltr ~/* ---"
			_essh "$_dis" "ls -ltr ~/*" 2>&1 || true
			echo "  --- sudo du -am ~/ | sort -rn | head -30 ---"
			_essh "$_dis" "sudo du -am ~/ | sort -rn | head -30" 2>&1 || true
		fi
		echo ""
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

# --- Post-suite integrity checks -------------------------------------------
# Detect leftover resources that the suite's cleanup should have removed.
# If anything is found, STOP so we can investigate the root cause.

# 2a. Check for orphan cluster VMs in this pool's vCenter folder
# VC_FOLDER from pools.conf already includes the pool path -- do NOT append /pool${POOL_NUM}
if command -v govc >/dev/null && [ -n "${VC_FOLDER:-}" ]; then
	_known_vms="con${POOL_NUM} dis${POOL_NUM}"
	_all_vms=$(govc find "$VC_FOLDER" -type m) || _all_vms=""
	_orphan_vms=""
	while IFS= read -r _ovm; do
		[ -z "$_ovm" ] && continue
		_vmname=$(basename "$_ovm")
		_is_infra=""
		for _k in $_known_vms; do
			[ "$_vmname" = "$_k" ] && _is_infra=1 && break
		done
		[ -n "$_is_infra" ] && continue
		_orphan_vms="${_orphan_vms}${_orphan_vms:+$'\n'}$_ovm"
	done <<< "$_all_vms"

	if [ -n "$_orphan_vms" ]; then
		echo ""
		echo "  *** POST-SUITE INTEGRITY FAILURE: orphan VMs found in $VC_FOLDER ***"
		while IFS= read -r _ovm; do
			[ -z "$_ovm" ] && continue
			echo "    $_ovm"
		done <<< "$_orphan_vms"
		echo ""
		echo "  Suite cleanup left VMs behind. Stopping for investigation."
		echo "  To proceed: manually destroy the VMs and re-run the suite."
		_rc=5
	fi
fi

# 2b. Check for leftover registry/mirror containers on disN
if [ -n "${DIS_VM:-}" ]; then
	_dis="${DIS_SSH_USER}@${DIS_VM}.${VM_BASE_DOMAIN}"
	_containers=$(_essh "$_dis" "podman ps --format '{{.Names}}'" 2>&1) || _containers=""
	_reg_containers=$(echo "$_containers" | grep -iE 'quay|registry|mirror' || true)
	if [ -n "$_reg_containers" ]; then
		echo ""
		echo "  *** POST-SUITE INTEGRITY FAILURE: registry/mirror containers still running on $_dis ***"
		echo "$_reg_containers"
		echo ""
		echo "  Suite cleanup did not uninstall the mirror. Stopping for investigation."
		_rc=5
	fi
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
