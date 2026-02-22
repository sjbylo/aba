#!/bin/bash
# =============================================================================
# E2E Test Framework v2 -- Infrastructure Setup
# =============================================================================
# Replaces clone-and-check suite and create_pools orchestration.
# Called by run.sh before test dispatch. Also usable standalone.
#
# Responsibilities:
#   1. Ensure golden VM (template -> golden -> snapshot)
#   2. Clone conN/disN from golden (reuse if exist + SSH works)
#   3. Configure all VMs (network, DNS, firewall, users, etc.)
#   4. Create pool-ready snapshots
#   5. Install ABA on each conN (git clone + ./install)
#
# Reuse-first: only destroys/recreates when explicitly told to.
#
# Usage:
#   setup-infra.sh -p N [-G] [-R]
#   setup-infra.sh --pools N [--recreate-golden] [--recreate-vms]
#
# All commands are visible (set -x for infra operations).
# =============================================================================

set -u

_INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ABA_ROOT="$(cd "$_INFRA_DIR/../.." && pwd)"

# Source libraries
source "$_INFRA_DIR/lib/config-helpers.sh"
source "$_INFRA_DIR/lib/vm-helpers.sh"
source "$_INFRA_DIR/lib/remote.sh"

# Source config.env
if [ -f "$_INFRA_DIR/config.env" ]; then
	source "$_INFRA_DIR/config.env"
fi

# Source VMware credentials
_vmconf="$(eval echo "${VMWARE_CONF:-~/.vmware.conf}")"
if [ -f "$_vmconf" ]; then
	set -a; source "$_vmconf"; set +a
else
	echo "ERROR: VMware config not found: $_vmconf" >&2
	exit 1
fi

# =============================================================================
# Reusable VM configuration functions
# =============================================================================

_configure_con_vm() {
	local vm="$1" user="$2"

	_vm_wait_ssh "$vm" "$user"
	_vm_setup_network "$vm" "$user" "$vm"
	_vm_setup_firewall "$vm" "$user"
	_vm_setup_dnsmasq "$vm" "$user" "$vm"
	_vm_setup_time "$vm" "$user"
	_vm_dnf_update "$vm" "$user"
	_vm_wait_ssh "$vm" "$user"
	_vm_cleanup_caches "$vm" "$user"
	_vm_cleanup_podman "$vm" "$user"
	_vm_cleanup_home "$vm" "$user"
	_vm_setup_vmware_conf "$vm" "$user"
	_vm_create_test_user "$vm" "$user"
	_vm_set_aba_testing "$vm" "$user"
	_vm_install_aba "$vm" "$user"
	_escp ~/.ssh/testy_rsa "${user}@${vm}:.ssh/testy_rsa"

	echo "  $vm configured."
}

_configure_dis_vm() {
	local vm="$1" user="$2" con_vm="$3"

	_vm_wait_ssh "$vm" "$user"
	_vm_setup_network "$vm" "$user" "$vm"
	_vm_setup_firewall "$vm" "$user"
	_vm_setup_time "$vm" "$user"

	echo "  [$vm] Waiting for internet via $con_vm NAT ..."
	local waited=0
	while ! _essh "${user}@${vm}" -- "ping -c1 -W3 8.8.8.8" &>/dev/null; do
		sleep 5
		waited=$(( waited + 5 ))
		if [ $waited -ge 300 ]; then
			echo "  [$vm] ERROR: No internet after ${waited}s (is $con_vm NAT/dnsmasq up?)" >&2
			return 1
		fi
	done
	[ "$waited" -gt 0 ] && echo "  [$vm] Internet reachable (waited ${waited}s)"

	_vm_dnf_update "$vm" "$user"
	_vm_wait_ssh "$vm" "$user"
	_vm_cleanup_caches "$vm" "$user"
	_vm_cleanup_podman "$vm" "$user"
	_vm_cleanup_home "$vm" "$user"
	_vm_setup_vmware_conf "$vm" "$user"
	_vm_remove_pull_secret "$vm" "$user"
	_vm_remove_proxy "$vm" "$user"
	_vm_create_test_user "$vm" "$user"
	_vm_set_aba_testing "$vm" "$user"
	_vm_disconnect_internet "$vm" "$user"

	echo "  [$vm] Verifying NTP sync (server: ${NTP_SERVER:-10.0.1.8}) ..."
	for ((_ntp=0; _ntp<20; _ntp++)); do
		if _essh "${user}@${vm}" -- "chronyc sources 2>/dev/null" | grep -q "^\^\*.*${NTP_SERVER:-10.0.1.8}"; then
			echo "  [$vm] NTP synced to ${NTP_SERVER:-10.0.1.8}."
			break
		fi
		sleep 5
	done

	echo "  $vm configured."
}

# =============================================================================
# Internal sub-command: --_run-pane (used by tmux panes, not user-facing)
# =============================================================================

if [ "${1:-}" = "--_run-pane" ]; then
	_pane_role="$2"       # con or dis
	_pane_vm="$3"         # e.g. con1
	_pane_other="$4"      # e.g. dis1 (for last-to-finish logic)
	_pane_signal="$5"     # signal directory (for RC files + prompt coordination)
	_pane_log="$6"        # pool log file
	_pane_folder="$7"     # VC_FOLDER for this pool
	_pane_user="$8"       # VM user
	_pane_con="${9:-}"    # con VM name (needed by dis for internet wait)

	export VC_FOLDER="$_pane_folder"

	_pane_rc=0
	(
		set -e
		if [ "$_pane_role" = "con" ]; then
			_configure_con_vm "$_pane_vm" "$_pane_user"
		else
			_configure_dis_vm "$_pane_vm" "$_pane_user" "$_pane_con"
		fi
	) 2>&1 | tee -a "$_pane_log"
	_pane_rc=${PIPESTATUS[0]}

	echo "$_pane_rc" > "${_pane_signal}/${_pane_vm}.rc"

	if [ "$_pane_rc" -ne 0 ]; then
		echo "  $_pane_vm: configuration FAILED (rc=$_pane_rc)"
	fi

	# Last-to-finish: show prompt and detach tmux
	_pane_other_rc="${_pane_signal}/${_pane_other}.rc"
	for ((_pw=0; _pw<120; _pw++)); do
		if [ -f "$_pane_other_rc" ] && mkdir "${_pane_signal}/prompt-lock" 2>/dev/null; then
			echo ""
			echo "=== Pool 1 configuration complete ==="
			read -t 30 -p "Press Enter to continue..." _ || true
			touch "${_pane_signal}/continue"
			tmux detach-client -s e2e-infra 2>/dev/null || true
			exit "$_pane_rc"
		fi
		[ -f "${_pane_signal}/continue" ] && exit "$_pane_rc"
		sleep 1
	done
	tmux detach-client -s e2e-infra 2>/dev/null || true
	exit "$_pane_rc"
fi

# =============================================================================
# Normal flow: parse arguments
# =============================================================================

_POOLS=1
_RECREATE_GOLDEN=""
_RECREATE_VMS=""
_POOLS_FILE="$_INFRA_DIR/pools.conf"

while [ $# -gt 0 ]; do
	case "$1" in
		-p|--pools)           _POOLS="$2"; shift 2 ;;
		-G|--recreate-golden) _RECREATE_GOLDEN=1; shift ;;
		-R|--recreate-vms)    _RECREATE_VMS=1; shift ;;
		--pools-file)         _POOLS_FILE="$2"; shift 2 ;;
		*) echo "setup-infra.sh: unknown flag: $1" >&2; exit 1 ;;
	esac
done

# --- Parse per-pool overrides from pools.conf --------------------------------

declare -A _pool_datastores=()
declare -A _pool_folders=()

if [ -f "$_POOLS_FILE" ]; then
	while IFS= read -r _line; do
		[[ "$_line" =~ ^[[:space:]]*# ]] && continue
		[[ -z "${_line// }" ]] && continue
		local_pnum="" ; local_pds="" ; local_pfolder=""
		for _token in $_line; do
			case "$_token" in
				POOL_NUM=*)     local_pnum="${_token#POOL_NUM=}" ;;
				VM_DATASTORE=*) local_pds="${_token#VM_DATASTORE=}" ;;
				VC_FOLDER=*)    local_pfolder="${_token#VC_FOLDER=}" ;;
			esac
		done
		if [ -n "$local_pnum" ]; then
			[ -n "$local_pds" ] && _pool_datastores[$local_pnum]="$local_pds"
			[ -n "$local_pfolder" ] && _pool_folders[$local_pnum]="$local_pfolder"
		fi
	done < "$_POOLS_FILE"
fi

# --- Derived variables -------------------------------------------------------

_RHEL_VER="${INT_BASTION_RHEL_VER:-rhel8}"
_VM_TEMPLATE="${VM_TEMPLATES[$_RHEL_VER]:-aba-e2e-template-$_RHEL_VER}"
_GOLDEN_NAME="aba-e2e-golden-${_RHEL_VER}"
_BASE_FOLDER="${VC_FOLDER:-/Datacenter/vm/abatesting}"
_SNAPSHOT_NAME="pool-ready"
_LOG_DIR="$_INFRA_DIR/logs"

mkdir -p "$_LOG_DIR"

echo ""
echo "=== E2E Infrastructure Setup ==="
echo "  Pools: $_POOLS"
echo "  RHEL: $_RHEL_VER"
echo "  Golden: $_GOLDEN_NAME"
echo "  Template: $_VM_TEMPLATE"
echo "  Base folder: $_BASE_FOLDER"
echo ""

# =============================================================================
# Phase 0: Golden VM
# =============================================================================

_prepare_golden() {
	local snapshot_name="golden-ready"

	echo "=== Phase 0: Preparing golden VM ($_GOLDEN_NAME) ==="

	if [ -n "$_RECREATE_GOLDEN" ]; then
		echo "  -G/--recreate-golden: destroying existing golden VM ..."
		if vm_exists "$_GOLDEN_NAME"; then
			govc vm.power -off "$_GOLDEN_NAME" 2>/dev/null || true
			govc vm.destroy "$_GOLDEN_NAME"
		fi
	fi

	if vm_exists "$_GOLDEN_NAME"; then
		if govc snapshot.tree -vm "$_GOLDEN_NAME" 2>/dev/null | grep -q "$snapshot_name"; then
			echo "  Golden VM exists with '$snapshot_name' snapshot -- reusing."
			echo "  (Use -G/--recreate-golden to force rebuild)"
			echo "=== Phase 0 complete ==="
			return 0
		fi
		echo "  Golden VM exists but no '$snapshot_name' snapshot -- rebuilding ..."
		govc vm.power -off "$_GOLDEN_NAME" 2>/dev/null || true
		govc vm.destroy "$_GOLDEN_NAME" || return 1
	fi

	echo "  Cloning from template: $_VM_TEMPLATE ..."

	clone_vm "$_VM_TEMPLATE" "$_GOLDEN_NAME" "$_BASE_FOLDER" || return 1

	local ip
	ip=$(govc vm.ip -wait 5m "$_GOLDEN_NAME") || return 1
	echo "  Golden VM IP: $ip"

	local user="$VM_DEFAULT_USER"
	_vm_wait_ssh "$ip" "$user"            || return 1
	_vm_setup_ssh_keys "$ip" "$user"      || return 1
	_vm_wait_ssh "$ip" "$user"            || return 1
	_vm_setup_default_route "$ip" "$user" || return 1
	_vm_fix_proxy_noproxy "$ip" "$user"   || return 1
	_vm_remove_proxy "$ip" "$user"        || return 1
	_vm_setup_firewall "$ip" "$user"      || return 1
	_vm_wait_ssh "$ip" "$user"            || return 1
	_vm_setup_time "$ip" "$user"          || return 1
	_vm_dnf_update "$ip" "$user"          || return 1
	_vm_wait_ssh "$ip" "$user"            || return 1
	_vm_cleanup_caches "$ip" "$user"      || return 1
	_vm_cleanup_podman "$ip" "$user"      || return 1
	_vm_cleanup_home "$ip" "$user"        || return 1
	_vm_create_test_user "$ip" "$user"    || return 1
	_vm_set_aba_testing "$ip" "$user"     || return 1
	_vm_verify_golden "$ip" "$user"       || return 1

	_essh "${user}@${ip}" -- "sudo poweroff" || true
	sleep 10
	govc vm.power -off "$_GOLDEN_NAME" 2>/dev/null || true
	govc snapshot.create -vm "$_GOLDEN_NAME" "$snapshot_name" || return 1

	echo "  Golden VM created and snapshotted."
	echo "=== Phase 0 complete ==="
}

_golden_log="$_LOG_DIR/golden-${_RHEL_VER}.log"
_prepare_golden 2>&1 | tee -a "$_golden_log" || { echo "FATAL: Golden VM preparation failed" >&2; exit 1; }

# =============================================================================
# Phase 1: Clone conN and disN
# =============================================================================

echo ""
echo "=== Phase 1: Ensure conN/disN VMs (pools 1..$_POOLS) ==="

_vm_needs_clone() {
	local vm_name="$1"
	if [ -n "$_RECREATE_VMS" ]; then
		echo "recreate"
		return
	fi
	if ! vm_exists "$vm_name"; then
		echo "missing"
		return
	fi
	local user="$VM_DEFAULT_USER"
	local host="${vm_name}.${VM_BASE_DOMAIN:-example.com}"
	if _essh -o BatchMode=yes -o ConnectTimeout=10 "${user}@${host}" -- "date" 2>/dev/null; then
		echo "ok"
		return
	fi
	if govc snapshot.tree -vm "$vm_name" 2>/dev/null | grep -q "$_SNAPSHOT_NAME"; then
		echo "revert"
		return
	fi
	echo "broken"
}

declare -a _clone_pids=()
declare -a _clone_labels=()
_clone_failed=0

for (( i=1; i<=_POOLS; i++ )); do
	pool_folder="${_pool_folders[$i]:-${_BASE_FOLDER}/pool${i}}"
	pool_ds="${_pool_datastores[$i]:-$VM_DATASTORE}"
	pool_log="$_LOG_DIR/create-pool${i}.log"

	govc folder.create "$pool_folder" 2>/dev/null || true

	for prefix in con dis; do
		vm_name="${prefix}${i}"
		status=$(_vm_needs_clone "$vm_name")

		case "$status" in
			ok)
				echo "  $vm_name: exists + SSH OK -- reusing"
				;;
			revert)
				echo "  $vm_name: exists but SSH failed -- reverting to $_SNAPSHOT_NAME"
				govc snapshot.revert -vm "$vm_name" "$_SNAPSHOT_NAME" || { echo "ERROR: revert $vm_name failed" >&2; _clone_failed=1; continue; }
				govc vm.power -on "$vm_name" 2>/dev/null || true
				;;
			missing|recreate|broken)
				echo "  $vm_name: $status -- cloning from $_GOLDEN_NAME ..."
				if vm_exists "$vm_name"; then
					govc vm.power -off "$vm_name" 2>/dev/null || true
					govc vm.destroy "$vm_name" || true
				fi
				VM_DATASTORE="$pool_ds" clone_vm "$_GOLDEN_NAME" "$vm_name" "$pool_folder" "golden-ready" >> "$pool_log" 2>&1 &
				_clone_pids+=($!)
				_clone_labels+=("clone $vm_name")
				;;
		esac
	done
done

for idx in "${!_clone_pids[@]}"; do
	if wait "${_clone_pids[$idx]}"; then
		echo "  OK: ${_clone_labels[$idx]}"
	else
		echo "  FAILED: ${_clone_labels[$idx]} (exit=$?)" >&2
		_clone_failed=1
	fi
done

if [ "$_clone_failed" -ne 0 ]; then
	echo "FATAL: Some VM clones failed" >&2
	exit 1
fi

echo "=== Phase 1 complete ==="

# =============================================================================
# Phase 2: Configure VMs (parallel per pool)
# =============================================================================

echo ""
echo "=== Phase 2: Configure VMs ==="

_signal_dir=$(mktemp -d /tmp/e2e-infra-signals.XXXXXX)
declare -a _cfg_pids=()
declare -a _cfg_labels=()
_cfg_failed=0

for (( i=1; i<=_POOLS; i++ )); do
	pool_folder="${_pool_folders[$i]:-${_BASE_FOLDER}/pool${i}}"
	pool_log="$_LOG_DIR/create-pool${i}.log"
	user="$VM_DEFAULT_USER"
	con_vm="con${i}"
	dis_vm="dis${i}"

	if govc snapshot.tree -vm "$con_vm" 2>/dev/null | grep -q "$_SNAPSHOT_NAME"; then
		if [ -z "$_RECREATE_VMS" ]; then
			echo "  $con_vm + $dis_vm: pool-ready snapshot exists -- skipping config"
			continue
		fi
	fi

	echo "  Configuring pool $i ($con_vm + $dis_vm) ..."

	if [ "$i" -eq 1 ] && [ -t 0 ] && [ -t 1 ]; then
		# ------------------------------------------------------------------
		# Pool 1, interactive: tmux 2-pane (con top, dis bottom)
		# ------------------------------------------------------------------
		_self="$_INFRA_DIR/setup-infra.sh"

		tmux kill-session -t e2e-infra 2>/dev/null || true
		tmux new-session -d -s e2e-infra -x 200 -y 50
		tmux set-option -t e2e-infra remain-on-exit on

		tmux send-keys -t e2e-infra \
			"bash '$_self' --_run-pane con '$con_vm' '$dis_vm' '$_signal_dir' '$pool_log' '$pool_folder' '$user' '$con_vm'" Enter
		tmux split-window -v -t e2e-infra
		tmux send-keys -t e2e-infra \
			"bash '$_self' --_run-pane dis '$dis_vm' '$con_vm' '$_signal_dir' '$pool_log' '$pool_folder' '$user' '$con_vm'" Enter

		if [ -n "${TMUX:-}" ]; then
			tmux switch-client -t e2e-infra
		else
			tmux attach -t e2e-infra
		fi

		# Safety net: wait for both RC files even if user detached early
		for ((_w=0; _w<900; _w++)); do
			[ -f "${_signal_dir}/${con_vm}.rc" ] && [ -f "${_signal_dir}/${dis_vm}.rc" ] && break
			sleep 2
		done

		# Read exit codes
		if [ -f "${_signal_dir}/${con_vm}.rc" ]; then
			_rc=$(cat "${_signal_dir}/${con_vm}.rc")
			if [ "$_rc" -ne 0 ]; then
				echo "  FAILED: configure $con_vm (exit=$_rc)" >&2
				_cfg_failed=1
			else
				echo "  OK: configure $con_vm"
			fi
		else
			echo "  FAILED: configure $con_vm (timed out)" >&2
			_cfg_failed=1
		fi

		if [ -f "${_signal_dir}/${dis_vm}.rc" ]; then
			_rc=$(cat "${_signal_dir}/${dis_vm}.rc")
			if [ "$_rc" -ne 0 ]; then
				echo "  FAILED: configure $dis_vm (exit=$_rc)" >&2
				_cfg_failed=1
			else
				echo "  OK: configure $dis_vm"
			fi
		else
			echo "  FAILED: configure $dis_vm (timed out)" >&2
			_cfg_failed=1
		fi

		tmux kill-session -t e2e-infra 2>/dev/null || true
	else
		# ------------------------------------------------------------------
		# Pool 1 non-interactive (cron) OR pools 2-N: background, log only
		# ------------------------------------------------------------------
		(
			set -e
			export VC_FOLDER="$pool_folder"
			_configure_con_vm "$con_vm" "$user"
		) >> "$pool_log" 2>&1 &
		_cfg_pids+=($!)
		_cfg_labels+=("configure $con_vm")

		(
			set -e
			export VC_FOLDER="$pool_folder"
			_configure_dis_vm "$dis_vm" "$user" "$con_vm"
		) >> "$pool_log" 2>&1 &
		_cfg_pids+=($!)
		_cfg_labels+=("configure $dis_vm")
	fi
done

for idx in "${!_cfg_pids[@]}"; do
	if wait "${_cfg_pids[$idx]}"; then
		echo "  OK: ${_cfg_labels[$idx]}"
	else
		echo "  FAILED: ${_cfg_labels[$idx]} (exit=$?)" >&2
		_cfg_failed=1
	fi
done

rm -rf "$_signal_dir"

if [ "$_cfg_failed" -ne 0 ]; then
	echo "FATAL: VM configuration failed" >&2
	exit 1
fi

echo "=== Phase 2 complete ==="

# =============================================================================
# Phase 3: Create pool-ready snapshots
# =============================================================================

echo ""
echo "=== Phase 3: Create pool-ready snapshots ==="

for (( i=1; i<=_POOLS; i++ )); do
	for prefix in con dis; do
		vm_name="${prefix}${i}"
		if govc snapshot.tree -vm "$vm_name" 2>/dev/null | grep -q "$_SNAPSHOT_NAME"; then
			if [ -z "$_RECREATE_VMS" ]; then
				echo "  $vm_name: $_SNAPSHOT_NAME already exists -- skipping"
				continue
			fi
		fi
		echo "  Creating snapshot '$_SNAPSHOT_NAME' on $vm_name ..."
		govc snapshot.create -vm "$vm_name" "$_SNAPSHOT_NAME" || { echo "ERROR: snapshot $vm_name failed" >&2; exit 1; }
	done
done

echo "=== Phase 3 complete ==="

echo ""
echo "=== Infrastructure ready: $_POOLS pool(s) ==="
echo ""
