#!/usr/bin/env bash
# =============================================================================
# E2E Test Framework -- Pool Operations (Orchestration)
# =============================================================================
# Pool-level orchestration: golden VM prep, pool creation/destruction, and
# bastion composition functions. Sources vm-ops.sh for individual _vm_* helpers.
#
# Merged from vm-helpers.sh and pool-lifecycle.sh (Phase 4).
# =============================================================================

_E2E_LIB_DIR_POOLOPS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the building blocks
source "$_E2E_LIB_DIR_POOLOPS/vm-ops.sh"

# =============================================================================
# Composition functions
# =============================================================================

# --- configure_connected_bastion --------------------------------------------
# Configure a VM as an internet-connected registry host (bastion).
# The connected bastion bridges the internet (ens256) to the private VLAN
# (ens224.10) so the disconnected bastion can reach it via NAT masquerade.

configure_connected_bastion() {
	local host="$1"
	local user="${2:-$VM_DEFAULT_USER}"
	local clone_name="${3:-$host}"

	echo "=== Configuring connected bastion: $host (clone: $clone_name) ==="

	_vm_wait_ssh "$host" "$user"
	_vm_setup_ssh_keys "$host" "$user"

	_vm_setup_network "$host" "$user" "$clone_name"
	_vm_setup_firewall "$host" "$user"
	_vm_setup_dnsmasq "$host" "$user" "$clone_name"

	_vm_dnf_update "$host" "$user"
	_vm_wait_ssh "$host" "$user"

	_vm_cleanup_caches "$host" "$user"
	_vm_cleanup_podman "$host" "$user"
	_vm_cleanup_home "$host" "$user"

	_vm_setup_vmware_conf "$host" "$user"
	_vm_setup_kvm_conf "$host" "$user"
	_vm_set_aba_testing "$host" "$user"
	_vm_install_aba "$host" "$user"

	echo "=== Connected bastion ready: $host ==="
}

# --- configure_internal_bastion ---------------------------------------------
# Configure a VM as an air-gapped internal bastion.

configure_internal_bastion() {
	local host="$1"
	local user="${2:-$VM_DEFAULT_USER}"
	local test_user="${3:-${TEST_USER:-$VM_DEFAULT_USER}}"
	local clone_name="${4:-$host}"

	echo "=== Configuring internal bastion: $host (clone: $clone_name) ==="

	_vm_wait_ssh "$host" "$user"
	_vm_setup_ssh_keys "$host" "$user"

	_vm_setup_network "$host" "$user" "$clone_name"
	_vm_setup_firewall "$host" "$user"

	_vm_dnf_update "$host" "$user"
	_vm_wait_ssh "$host" "$user"

	_vm_cleanup_caches "$host" "$user"
	_vm_cleanup_podman "$host" "$user"
	_vm_cleanup_home "$host" "$user"

	_vm_setup_vmware_conf "$host" "$user"
	_vm_setup_kvm_conf "$host" "$user"

	_vm_remove_pull_secret "$host" "$user"
	_vm_disable_proxy_autoload "$host" "$user"

	_vm_set_aba_testing "$host" "$user"

	_vm_disconnect_internet "$host" "$user"

	echo "=== Internal bastion ready: $host ==="
}

# =============================================================================
# Golden VM management
# =============================================================================

# --- prepare_golden_vm ------------------------------------------------------
# Prepare (or refresh) a golden VM with all common config baked in.
# Skips refresh if the snapshot is less than GOLDEN_MAX_AGE_HOURS old.

prepare_golden_vm() {
	local vm_template="$1"
	local golden_name="$2"
	local folder="${3:-${VC_FOLDER:-/Datacenter/vm/aba-e2e}}"
	local user="${4:-$VM_DEFAULT_USER}"
	local snapshot_name="golden-ready"
	local max_age_hours="${GOLDEN_MAX_AGE_HOURS:-24}"

	local stamp_dir="${HOME}/.cache/aba-e2e"
	mkdir -p "$stamp_dir"
	local stamp_file="${stamp_dir}/${golden_name}.stamp"

	echo ""
	echo "=== Phase 0: Preparing golden VM ($golden_name) ==="

	if vm_exists "$golden_name"; then
		if [ -f "$stamp_file" ]; then
			local stamp_epoch now_epoch age_hours
			stamp_epoch=$(cat "$stamp_file")
			now_epoch=$(date +%s)
			age_hours=$(( (now_epoch - stamp_epoch) / 3600 ))
			if [ "$age_hours" -lt "$max_age_hours" ]; then
				echo "  Snapshot is ${age_hours}h old (max: ${max_age_hours}h) -- reusing."
				return 0
			fi
			echo "  Snapshot is ${age_hours}h old (max: ${max_age_hours}h) -- stale, destroying ..."
		elif govc snapshot.tree -vm "$golden_name" 2>&1 | grep -q "$snapshot_name"; then
			echo "  No stamp file but '$snapshot_name' snapshot exists -- reusing (recreating stamp)."
			date +%s > "$stamp_file"
			return 0
		else
			echo "  No stamp file and no '$snapshot_name' snapshot -- destroying ..."
		fi
		govc vm.power -off "$golden_name" || true
		govc vm.destroy "$golden_name" || return 1
		rm -f "$stamp_file"
	fi

	echo "  Creating from $vm_template ..."

	clone_vm "$vm_template" "$golden_name" "$folder" || return 1

	local ip
	ip=$(govc vm.ip -wait 5m "$golden_name") || return 1
	echo "  Golden VM IP: $ip"

	_vm_wait_ssh "$ip" "$user"            || return 1
	_vm_setup_ssh_keys "$ip" "$user"      || return 1
	_vm_wait_ssh "$ip" "$user"            || return 1
	_vm_setup_default_route "$ip" "$user" || return 1
	_vm_fix_proxy_noproxy "$ip" "$user"   || return 1
	_vm_disable_proxy_autoload "$ip" "$user"        || return 1
	_vm_setup_firewall "$ip" "$user"      || return 1
	_vm_wait_ssh "$ip" "$user"            || return 1
	_vm_install_packages "$ip" "$user"    || return 1
	_vm_setup_time "$ip" "$user"          || return 1
	_vm_dnf_update "$ip" "$user"          || return 1
	_vm_wait_ssh "$ip" "$user"            || return 1
	_vm_cleanup_caches "$ip" "$user"      || return 1
	_vm_cleanup_podman "$ip" "$user"      || return 1
	_vm_cleanup_home "$ip" "$user"        || return 1
	_vm_create_test_user_and_key_on_host "$ip" "$user" || return 1
	_vm_provision_root_user "$ip" "$user" || return 1
	_vm_deploy_tmux_conf "$ip" "$user"    || return 1
	_vm_authorize_root_on_kvm_host "$ip" "$user" || return 1
	_vm_set_aba_testing "$ip" "$user"     || return 1
	_vm_verify_golden "$ip" "$user"       || return 1

	_essh "${user}@${ip}" -- "sudo poweroff" || true
	sleep 10
	govc vm.power -off "$golden_name" || true
	govc snapshot.create -vm "$golden_name" "$snapshot_name" || return 1
	_vm_annotate "$golden_name" "Ready ($snapshot_name snapshot created)"
	date +%s > "$stamp_file"

	echo "  Golden VM created and snapshotted."
	echo "=== Phase 0 complete ==="
}

# =============================================================================
# Pool creation / destruction
# =============================================================================

# --- create_pools -----------------------------------------------------------
# Create N VM pools: Phase 0 prepares a golden VM, Phase 1 clones from it
# in parallel, Phase 2 applies per-pool config in parallel.

create_pools() {
	local count="$1"; shift
	local rhel_ver="${INT_BASTION_RHEL_VER:-rhel9}"
	local connected_only=""
	local start_at=1
	local pools_file=""
	local rebuild_golden=""
	local skip_phase2=""

	while [ $# -gt 0 ]; do
		case "$1" in
			--rhel) rhel_ver="$2"; shift 2 ;;
			--connected-only) connected_only=1; shift ;;
			--start) start_at="$2"; shift 2 ;;
			--pools-file) pools_file="$2"; shift 2 ;;
			--rebuild-golden) rebuild_golden=1; shift ;;
			--skip-phase2) skip_phase2=1; shift ;;
			*) echo "create_pools: unknown flag: $1" >&2; return 1 ;;
		esac
	done

	local vm_template="${VM_TEMPLATES[$rhel_ver]:-bastion-internal-$rhel_ver}"
	local golden_name="aba-e2e-golden-${rhel_ver}"
	local end_at=$(( start_at + count - 1 ))
	local signal_dir
	signal_dir=$(mktemp -d /tmp/e2e-pool-signals.XXXXXX)

	local base_folder="${VC_FOLDER:-/Datacenter/vm/aba-e2e}"

	# --- Parse per-pool overrides from pools.conf ---------------------------
	local -A _pool_datastores=()
	local -A _pool_folders=()
	if [ -n "$pools_file" ] && [ -f "$pools_file" ]; then
		while IFS= read -r _line; do
			[[ "$_line" =~ ^[[:space:]]*# ]] && continue
			[[ -z "${_line// }" ]] && continue
			local _pnum="" _pds="" _pfolder=""
			for _token in $_line; do
				case "$_token" in
					POOL_NUM=*)      _pnum="${_token#POOL_NUM=}" ;;
					VM_DATASTORE=*)  _pds="${_token#VM_DATASTORE=}" ;;
					VC_FOLDER=*)     _pfolder="${_token#VC_FOLDER=}" ;;
				esac
			done
			if [ -n "$_pnum" ]; then
				[ -n "$_pds" ] && _pool_datastores[$_pnum]="$_pds"
				[ -n "$_pfolder" ] && _pool_folders[$_pnum]="$_pfolder"
			fi
		done < "$pools_file"
	fi

	local pool_log_dir="${E2E_LOG_DIR:-${_E2E_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/logs}"
	mkdir -p "$pool_log_dir"

	echo "=== Creating pool(s) ${start_at}..${end_at} from golden VM ($golden_name) ==="

	# --- Phase 0: Prepare (or refresh) the golden VM ------------------------

	if [ -n "$rebuild_golden" ]; then
		echo "  Rebuilding golden VM (--rebuild-golden) ..."
		if vm_exists "$golden_name"; then
			govc vm.power -off "$golden_name" || true
			govc vm.destroy "$golden_name"
		fi
		rm -f "${HOME}/.cache/aba-e2e/${golden_name}.stamp"
	fi

	local golden_log="${pool_log_dir}/golden-${rhel_ver}.log"
	local golden_rc=0
	prepare_golden_vm "$vm_template" "$golden_name" "$base_folder" 2>&1 | tee -a "$golden_log" || golden_rc=$?
	if [ "$golden_rc" -ne 0 ]; then
		echo "--- Phase 0 FAILED (rc=$golden_rc): see $golden_log ---"
		rm -rf "$signal_dir"
		return 1
	fi

	# --- Create per-pool subfolders (idempotent) ------------------------------
	for (( i=start_at; i<=end_at; i++ )); do
		local pool_folder="${_pool_folders[$i]:-${base_folder}/pool${i}}"
		govc folder.create "$pool_folder" || true
	done

	if [ -n "$skip_phase2" ]; then
		echo "--- Skipping Phase 1 & 2 (--skip-phase2) ---"
		rm -rf "$signal_dir"
		echo "=== Golden VM ready; run clone-and-check per pool ==="
		return 0
	fi

	# --- Phase 1a: Clone connected (conN) VMs first ---------------------------
	echo "--- Phase 1a: Cloning connected VMs from $golden_name ---"

	local -a clone_pids=()
	local -a clone_labels=()
	local i

	for (( i=start_at; i<=end_at; i++ )); do
		local pool_folder="${_pool_folders[$i]:-${base_folder}/pool${i}}"
		local pool_ds="${_pool_datastores[$i]:-$VM_DATASTORE}"
		local pool_log="${pool_log_dir}/create-pool${i}.log"

		echo "=== Cloning VMs for pool ${i} ===" > "$pool_log"

		VM_DATASTORE="$pool_ds" clone_vm "$golden_name" "con${i}" "$pool_folder" "golden-ready" >> "$pool_log" 2>&1 &
		clone_pids+=($!)
		clone_labels+=("clone con${i}")
	done

	local clone_failed=0
	for idx in "${!clone_pids[@]}"; do
		if wait "${clone_pids[$idx]}"; then
			echo "  OK: ${clone_labels[$idx]}"
		else
			echo "  FAILED: ${clone_labels[$idx]} (exit=$?)" >&2
			clone_failed=$(( clone_failed + 1 ))
		fi
	done

	if [ $clone_failed -gt 0 ]; then
		echo "--- Phase 1a FAILED: $clone_failed conN clone(s) failed ---"
		rm -rf "$signal_dir"
		return 1
	fi
	echo "--- Phase 1a complete: connected VMs booting ---"

	# --- Phase 1b: Clone disconnected (disN) VMs ----------------------------
	if [ -z "$connected_only" ]; then
		echo "--- Phase 1b: Cloning disconnected VMs from $golden_name ---"

		clone_pids=()
		clone_labels=()

		for (( i=start_at; i<=end_at; i++ )); do
			local pool_folder="${_pool_folders[$i]:-${base_folder}/pool${i}}"
			local pool_ds="${_pool_datastores[$i]:-$VM_DATASTORE}"
			local pool_log="${pool_log_dir}/create-pool${i}.log"

			VM_DATASTORE="$pool_ds" clone_vm "$golden_name" "dis${i}" "$pool_folder" "golden-ready" >> "$pool_log" 2>&1 &
			clone_pids+=($!)
			clone_labels+=("clone dis${i}")
		done

		clone_failed=0
		for idx in "${!clone_pids[@]}"; do
			if wait "${clone_pids[$idx]}"; then
				echo "  OK: ${clone_labels[$idx]}"
			else
				echo "  FAILED: ${clone_labels[$idx]} (exit=$?)" >&2
				clone_failed=$(( clone_failed + 1 ))
			fi
		done

		if [ $clone_failed -gt 0 ]; then
			echo "--- Phase 1b FAILED: $clone_failed disN clone(s) failed ---"
			rm -rf "$signal_dir"
			return 1
		fi
		echo "--- Phase 1b complete: disconnected VMs booting ---"
	fi

	echo "--- Phase 1 complete: all clones booting ---"

	# --- Phase 2: Per-pool configuration (parallel) -------------------------
	echo "--- Phase 2: Per-pool configuration ---"

	local -a pids=()
	local -a labels=()

	for (( i=start_at; i<=end_at; i++ )); do
		local conn_vm="con${i}"
		local user="${VM_DEFAULT_USER}"
		local pool_folder="${_pool_folders[$i]:-${base_folder}/pool${i}}"
		local pool_log="${pool_log_dir}/create-pool${i}.log"

		(
			set -e
			export VC_FOLDER="$pool_folder"

			echo "=== Configuring $conn_vm (connected) ==="

			_vm_wait_ssh "$conn_vm" "$user"
			_vm_setup_network "$conn_vm" "$user" "$conn_vm"
			_vm_setup_dnsmasq "$conn_vm" "$user" "$conn_vm"

			touch "${signal_dir}/${conn_vm}.ready"

			_vm_setup_vmware_conf "$conn_vm" "$user"
			_vm_setup_kvm_conf "$conn_vm" "$user"
			_vm_cleanup_caches "$conn_vm" "$user"
			_vm_verify_golden "$conn_vm" "$user"
			_vm_install_aba "$conn_vm" "$user"

			echo "  $conn_vm ready"
		) >> "$pool_log" 2>&1 &
		pids+=($!)
		labels+=("configure $conn_vm")

		if [ -z "$connected_only" ]; then
			local int_vm="dis${i}"
			(
				set -e
				export VC_FOLDER="$pool_folder"

				echo "=== Configuring $int_vm (disconnected) ==="

				_vm_wait_ssh "$int_vm" "$user"
				_vm_setup_network "$int_vm" "$user" "$int_vm"

				echo "  [$int_vm] Waiting for $conn_vm dnsmasq ..."
				local waited=0
				while [ ! -f "${signal_dir}/${conn_vm}.ready" ]; do
					sleep 5
					waited=$(( waited + 5 ))
					if [ $waited -ge 600 ]; then
						echo "  [$int_vm] ERROR: Timed out waiting for $conn_vm (${waited}s)" >&2
						return 1
					fi
				done
				echo "  [$int_vm] $conn_vm is ready (waited ${waited}s), continuing ..."

				_vm_setup_vmware_conf "$int_vm" "$user"
				_vm_setup_kvm_conf "$int_vm" "$user"
				_vm_cleanup_caches "$int_vm" "$user"
				_vm_verify_golden "$int_vm" "$user"
				_vm_remove_pull_secret "$int_vm" "$user"
				_vm_disable_proxy_autoload "$int_vm" "$user"
				_vm_disconnect_internet "$int_vm" "$user"

				echo "  $int_vm ready"
			) >> "$pool_log" 2>&1 &
			pids+=($!)
			labels+=("configure $int_vm")
		fi
	done

	local failed=0
	for idx in "${!pids[@]}"; do
		if wait "${pids[$idx]}"; then
			echo "  OK: ${labels[$idx]}"
		else
			echo "  FAILED: ${labels[$idx]} (exit=$?)" >&2
			failed=$(( failed + 1 ))
		fi
	done

	rm -rf "$signal_dir"

	if [ $failed -gt 0 ]; then
		echo "=== $failed configuration(s) FAILED ==="
		return 1
	fi
	echo "=== Pool(s) ${start_at}..${end_at} created ==="
}

# --- destroy_pools ----------------------------------------------------------

destroy_pools() {
	local all_pools=""
	local pools=()

	while [ $# -gt 0 ]; do
		case "$1" in
			--all) all_pools=1; shift ;;
			*) pools+=("$1"); shift ;;
		esac
	done

	if [ -n "$all_pools" ]; then
		echo "=== Destroying all pool clone VMs ==="
		local i
		for (( i=1; i<=10; i++ )); do
			destroy_vm "con${i}"
			destroy_vm "dis${i}"
		done
	else
		for pool in "${pools[@]}"; do
			echo "  Destroying clone: $pool"
			destroy_vm "$pool"
		done
	fi

	echo "=== Pool clones destroyed ==="
}

# --- list_pools -------------------------------------------------------------

list_pools() {
	echo "=== Pool Status (Clones) ==="
	echo ""
	printf "  %-25s %-10s\n" "CLONE NAME" "POWER"
	echo "  $(printf '%0.s-' {1..40})"

	local i
	for (( i=1; i<=10; i++ )); do
		for prefix in con dis; do
			local vm="${prefix}${i}"
			if vm_exists "$vm"; then
				local power
				power=$(govc vm.info -json "$vm" | grep -o '"powerState":"[^"]*"' | head -1 | cut -d'"' -f4)
				printf "  %-25s %-10s\n" "$vm" "${power:-unknown}"
			fi
		done
	done

	echo ""
}

# --- pool_ready -------------------------------------------------------------

pool_ready() {
	_essh -o ConnectTimeout=5 -o BatchMode=yes "$1" -- "test -d ~/aba"
}
