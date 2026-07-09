#!/usr/bin/env bash
# =============================================================================
# E2E Framework -- Infrastructure Provisioning
# =============================================================================
# Pool VM readiness checks, OS change detection, selective reclone,
# infra provisioning, and snapshot revert.
#
# Depends on:
#   lib/remote.sh        -- _essh, _ssh_con, _con_target, _wait_for_ssh
#   lib/vm-ops.sh        -- govc wrappers
#   lib/config-helpers.sh -- pool_domain
#   lib/cli.sh           -- _pool_rhel_ver
#   lib/dispatcher.sh    -- _print_box
#
# Caller must declare these before calling:
#   declare -A _pool_os_map=()
# =============================================================================

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

# Populate _pool_os_map, check VM readiness, reclone if OS changed,
# and run setup-infra.sh if needed.
# Globals: CLI_POOL_LIST, CLI_OS, CLI_RECREATE_GOLDEN, CLI_RECREATE_VMS,
#          CLI_YES, _RUN_DIR, VC_FOLDER, VM_BASE_DOMAIN, _pool_os_map
_ensure_pool_infrastructure() {
	_ensure_govc
	local _vmconf="$HOME/.vmware.conf"
	# Save E2E-specific vars that vmware.conf might clobber (vmware.conf has its
	# own VC_FOLDER for ABA production use -- we need the E2E one from config.env).
	local _saved_vc_folder="${VC_FOLDER:-}"
	[ -f "$_vmconf" ] && { set -a; source "$_vmconf"; set +a; }
	[ -n "$_saved_vc_folder" ] && VC_FOLDER="$_saved_vc_folder"

	echo ""
	echo "=== E2E Test Run ==="
	echo "  Suites: ${suites_to_run[*]}"
	echo "  Pools: ${CLI_POOL_LIST}"
	echo ""

	# Check VM readiness and OS changes for each pool
	local _POOL_OS_DIR="$_RUN_DIR/.pool-os"
	mkdir -p "$_POOL_OS_DIR"
	local -a _pools_needing_reclone=()
	local _need_infra=""

	# Per-pool RHEL version: CLI --os wins over pools.conf when explicitly set
	local _default_os="${INT_BASTION_RHEL_VER:-rhel8}"
	local _p
	for _p in $CLI_POOL_LIST; do
		if [ -n "${CLI_OS:-}" ]; then
			_pool_os_map[$_p]="$CLI_OS"
		else
			_pool_os_map[$_p]=$(_pool_rhel_ver "${_RUN_DIR}/pools.conf" "$_p" 2>/dev/null) || true
			[ -z "${_pool_os_map[$_p]:-}" ] && _pool_os_map[$_p]="$_default_os"
		fi
	done

	if [ -n "${CLI_RECREATE_GOLDEN:-}" ]; then
		echo "  --recreate-golden: all VMs will be rebuilt from new golden"
		_need_infra=1
	else
		for _p in $CLI_POOL_LIST; do
			local _pool_os_file="$_POOL_OS_DIR/pool-${_p}"
			local _cur_os="${_pool_os_map[$_p]}"
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
	fi

	# Selective reclone: destroy only pools that changed OS (not global --recreate-vms)
	if [ ${#_pools_needing_reclone[@]} -gt 0 ] && [ -z "${CLI_RECREATE_VMS:-}" ]; then
		_print_box "1;43;30" "⟳  OS RECLONE: Rebuilding pools ${_pools_needing_reclone[*]}"
		for _p in "${_pools_needing_reclone[@]}"; do
			local _pool_folder="${VC_FOLDER:-/Datacenter/vm/aba-e2e}/pool${_p}"

			# Process cleanup files first (delete clusters/mirrors via aba)
			local _try_user _try_host _has_cleanup
			for _try_user in "${CON_SSH_USER:-steve}" root steve; do
				_try_host="${_try_user}@con${_p}.${VM_BASE_DOMAIN}"
				_essh "$_try_host" "true" 2>/dev/null || continue
				_has_cleanup=""
				_has_cleanup=$(_essh "$_try_host" "ls \$HOME/.e2e-harness/logs/*.cleanup \$HOME/.e2e-harness/logs/*.mirror-cleanup 2>/dev/null" 2>/dev/null) || true
				[ -z "$_has_cleanup" ] && continue
				echo "  Pool $_p: processing cleanup files for $_try_user before OS reclone ..."
				_run_cleanup_on_host "$_try_host" "    " "con${_p}.${VM_BASE_DOMAIN} dis${_p}.${VM_BASE_DOMAIN}" 2>&1 || true
				break
			done

			# Destroy ALL VMs in the pool folder (clusters, conN, disN, etc.)
			echo "  Destroying all VMs in pool $_p folder ..."
			if [ -n "${VC_FOLDER:-}" ]; then
				local _vm_path _vm_name
				while IFS= read -r _vm_path; do
					[ -z "$_vm_path" ] && continue
					_vm_name="${_vm_path##*/}"
					echo "  Destroying $_vm_name (OS mismatch) ..."
					govc vm.power -off "$_vm_path" 2>/dev/null || true
					govc vm.destroy "$_vm_path" 2>/dev/null || true
				done < <(govc find "$_pool_folder" -type m 2>/dev/null)
			else
				# ESXi: no pool folders, destroy conN/disN by name
				local _pfx _vm
				for _pfx in con dis; do
					_vm="${_pfx}${_p}"
					govc vm.power -off "$_vm" 2>/dev/null || true
					govc vm.destroy "$_vm" 2>/dev/null || true
				done
			fi
		done
	fi

	# When recreating VMs, destroy orphaned cluster VMs in pool folders first
	if [ -n "${CLI_RECREATE_VMS:-}" ]; then
		for _p in $CLI_POOL_LIST; do
			local _pool_folder="${VC_FOLDER:-/Datacenter/vm/aba-e2e}/pool${_p}"
			local _orphans
			_orphans=$(govc find "$_pool_folder" -type m 2>/dev/null | grep -v "/con${_p}$" | grep -v "/dis${_p}$") || true
			if [ -n "$_orphans" ]; then
				echo "  Pool $_p: destroying orphaned VMs before recreate ..."
				local _vm_path _vm_name
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

	# Recreating golden implies recreating pool VMs (the whole point is to pick up golden changes)
	[ -n "${CLI_RECREATE_GOLDEN:-}" ] && CLI_RECREATE_VMS=1

	if [ -n "$_need_infra" ] || [ -n "${CLI_RECREATE_GOLDEN:-}" ] || [ -n "${CLI_RECREATE_VMS:-}" ]; then
		echo ""
		_print_box "1;46;30" "⟳  INFRA: Provisioning pool VMs (pools: $CLI_POOL_LIST)"
		local _base_infra_flags="--pools-file ${_RUN_DIR}/pools.conf"
		[ -n "${CLI_RECREATE_GOLDEN:-}" ] && _base_infra_flags+=" --recreate-golden"
		[ -n "${CLI_RECREATE_VMS:-}" ]    && _base_infra_flags+=" --recreate-vms"
		[ -n "${CLI_YES:-}" ]             && _base_infra_flags+=" --yes"

		# Group pools by RHEL version and call setup-infra once per group.
		# Each group gets its own golden VM (e.g. aba-e2e-golden-rhel8, aba-e2e-golden-rhel10).
		local -A _os_pool_groups=()
		local _pos _grp_os _grp_pools
		for _p in $CLI_POOL_LIST; do
			_pos="${_pool_os_map[$_p]}"
			_os_pool_groups[$_pos]+="${_os_pool_groups[$_pos]:+,}${_p}"
		done

		for _grp_os in "${!_os_pool_groups[@]}"; do
			_grp_pools="${_os_pool_groups[$_grp_os]}"
			echo "  --- RHEL group: $_grp_os (pools: $_grp_pools) ---"
			INT_BASTION_RHEL_VER="$_grp_os" \
			"$BASH" "$_RUN_DIR/setup-infra.sh" --pool-list "$_grp_pools" $_base_infra_flags 9>&- \
				|| { echo "FATAL: Infrastructure setup failed for $_grp_os group (pools: $_grp_pools)" >&2; exit 1; }
		done

		for _p in $CLI_POOL_LIST; do
			echo "${_pool_os_map[$_p]}" > "$_POOL_OS_DIR/pool-${_p}"
		done

		_print_box "1;46;30" "✔  INFRA: Pool VMs ready (pools: $CLI_POOL_LIST)"
	fi
}

# Revert pool VMs to pool-ready snapshot and wait for SSH.
# Globals: CLI_POOL_LIST, _RUN_DIR, VC_FOLDER, VM_BASE_DOMAIN, CON_SSH_USER, E2E_TMUX_SESSION
_revert_pool_snapshots() {
	echo ""
	echo "  Processing cleanup files before revert (cluster VMs live on hypervisor) ..."
	local _p
	for _p in $CLI_POOL_LIST; do
		local _try_user _try_host _has_cleanup
		for _try_user in "${CON_SSH_USER:-steve}" root steve; do
			_try_host="${_try_user}@con${_p}.${VM_BASE_DOMAIN}"
			_essh "$_try_host" "true" 2>/dev/null || continue
			_has_cleanup=""
			_has_cleanup=$(_essh "$_try_host" "ls \$HOME/.e2e-harness/logs/*.cleanup \$HOME/.e2e-harness/logs/*.mirror-cleanup 2>/dev/null" 2>/dev/null) || true
			[ -z "$_has_cleanup" ] && continue
			echo "    Pool $_p: found cleanup files for $_try_user -- running aba delete/uninstall ..."
			_run_cleanup_on_host "$_try_host" "      " "con${_p}.${VM_BASE_DOMAIN} dis${_p}.${VM_BASE_DOMAIN}" 2>&1 || echo "    WARNING: cleanup for pool $_p user $_try_user had errors (continuing)"
		done
	done

	echo ""
	echo "  Reverting pool VMs to pool-ready snapshot ..."
	local prefix vm target
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
}
