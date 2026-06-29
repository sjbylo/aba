#!/bin/bash
# VM provider driver -- the explicit seam between ABA and a hypervisor.
#
# ABA supports two hypervisors (libvirt and vSphere). Historically each was a
# parallel family of ~11 scripts (kvm-*.sh / vmw-*.sh) matched only by naming
# convention: there was no place that declared "a VM provider must implement
# these operations", and the shared lifecycle flow (config resolution, host
# iteration, confirmation, waiting) was copy-pasted into every script.
#
# This driver names that seam. It:
#   - loads the platform-specific adapter (scripts/vm-<platform>.sh), which
#     defines the vmp_* primitive contract (the genuinely different virsh/govc
#     calls); see those files for the contract.
#   - owns the shared flow each verb repeats: resolving the cluster's VM names
#     and iterating over them.
#
# Adapters provide WHAT differs per hypervisor; the driver provides the flow
# that is identical across hypervisors. A new hypervisor implements the
# primitives only -- it does not copy the lifecycle scripts.
#
# Requires include_all.sh to be sourced first (for aba_debug, vm_name, ...).

# Load the adapter for a platform. Aborts (non-zero) for platforms that have no
# VM provider (bm) or are unknown. Mirrors the platform handling in
# aba.sh:_ensure_hv_ready, but as a single grep-able decision.
vm_provider_load() {
	local platform=$1
	# Relative path: per project invariant, scripts other than aba.sh/abatui2.sh
	# never depend on $ABA_ROOT. cwd already contains scripts/ (same place this
	# file and include_all.sh were sourced from).
	case "$platform" in
		kvm) source scripts/vm-kvm.sh ;;
		vmw) source scripts/vm-vmw.sh ;;
		bm)  aba_abort "VM operations require platform=vmw or platform=kvm in aba.conf" ;;
		*)   aba_abort "Unknown platform '$platform' in aba.conf" ;;
	esac
}

# The cluster's VM host list, in install order (control plane first). Reads the
# same env that cluster-config.sh exports: CLUSTER_NAME, CP_NAMES, WORKER_NAMES.
# Honours workers=/masters= scoping the way the start/stop scripts do.
_vm_hosts() {
	local scope=${1:-all} hosts
	case "$scope" in
		workers) hosts="$WORKER_NAMES" ;;
		masters) hosts="$CP_NAMES" ;;
		*)       hosts="$CP_NAMES $WORKER_NAMES" ;;
	esac
	[ "$hosts" ] || hosts="$CP_NAMES"
	echo "$hosts"
}

# Resolve a host short-name to its full VM name (SNO-aware; see vm_name).
_vm_full_name() { vm_name "$CLUSTER_NAME" "$1"; }

# Exit 0 if at least one of the cluster's VMs exists.
vm_exists_any() {
	local name
	for name in $(_vm_hosts all); do
		vmp_exists "$(_vm_full_name "$name")" && return 0
	done
	return 1
}

# Exit 0 if at least one of the cluster's VMs is powered on / running.
vm_on_any() {
	local name
	for name in $(_vm_hosts all); do
		vmp_is_on "$(_vm_full_name "$name")" && return 0
	done
	return 1
}

# Print a "Name CPU Memory State" table for the cluster's VMs (skips absent VMs).
vm_ls() {
	local name vm info output= header="Name CPU Memory State"
	for name in $(_vm_hosts all); do
		vm=$(_vm_full_name "$name")
		info=$(vmp_info "$vm") || continue
		output="$output\n$vm $info"
	done
	if [ "$output" ]; then
		echo -e "$header\n$output" | column -t
	else
		echo "No resources"
	fi
}

# Print the full VM names for a scope, one per line (used for confirmation).
_vm_list_names() {
	local name
	for name in $(_vm_hosts "$1"); do echo "$(_vm_full_name "$name")"; done
}

# Start every VM in scope (default: control plane + workers). Honours the 'ask'
# confirmation. With wait=1 in the environment, blocks until all are running.
# Exit 1 if no cluster VM exists. Scope: all|workers|masters.
vm_start() {
	local scope=${1:-all} name
	vm_exists_any || return 1
	_vm_list_names "$scope"
	ask "Start the above virtual machine(s)" || return 1
	for name in $(_vm_hosts "$scope"); do
		vmp_power_on "$(_vm_full_name "$name")"
	done
	[ "${wait:-}" ] && _vm_wait_all "$scope" on "Waiting for VMs to be running"
	return 0
}

# Gracefully stop every VM in scope. Honours 'ask'. With wait=1, blocks until
# all are off. No-op if no VMs are powered on. Scope: all|workers|masters.
vm_stop() {
	local scope=${1:-all} name
	# Nothing to stop if no VMs are running
	vm_on_any || return 0
	if [ "${ask:-}" ]; then
		echo
		_vm_list_names "$scope"
		ask "Stop the above virtual machine(s)" || return 1
	fi
	for name in $(_vm_hosts "$scope"); do
		vmp_power_off "$(_vm_full_name "$name")"
	done
	[ "${wait:-}" ] && _vm_wait_all "$scope" off "Waiting for VMs to shut off (Ctrl-C to abort)"
	return 0
}

# Immediately power off every cluster VM. Honours 'ask'.
# No-op (return 0) if no VMs exist or none are powered on.
vm_kill() {
	local name
	# Nothing to kill if no VMs are running
	vm_on_any || return 0
	if [ "${ask:-}" ]; then
		echo
		_vm_list_names all
		ask "Immediately power down the above virtual machine(s)" || return 1
	fi
	for name in $(_vm_hosts all); do
		vmp_kill "$(_vm_full_name "$name")"
	done
	return 0
}

# Block until every VM in scope reaches the desired power state (on|off), or the
# 40-minute timeout elapses. A Ctrl-C during the wait is reported, not fatal.
_vm_wait_all() {
	local scope=$1 want=$2 msg=$3 timeout=$(( 60 * 40 )) rc=0
	_vm_state_reached() {
		local name on
		for name in $(_vm_hosts "$scope"); do
			vmp_is_on "$(_vm_full_name "$name")" && on=1 || on=
			[ "$want" = "on" ]  && [ ! "$on" ] && return 1
			[ "$want" = "off" ] && [ "$on" ]  && return 1
		done
		return 0
	}
	aba_wait_show "$msg" 10 "$timeout" _vm_state_reached || rc=$?
	if [ "$rc" -eq 130 ] || [ "$rc" -eq 143 ]; then
		aba_info "Aborted. VMs may still be changing state in the background."
	elif [ "$rc" -ne 0 ]; then
		aba_abort "Timed out after ${timeout}s waiting: $msg"
	fi
}
